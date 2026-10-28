#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
ROOT="$PWD"
STATE="${LOCAL_STATE_DIR:-$ROOT/.local}"
KIND_BIN="${KIND_BIN:-kind}"
ENGINE="${CONTAINER_ENGINE:-podman}"
export KIND_EXPERIMENTAL_PROVIDER="$ENGINE"
export KUBECONFIG="${KUBECONFIG:-$STATE/kubeconfig}"
mkdir -p "$STATE"
chmod 700 "$STATE"
umask 077
if ! "$KIND_BIN" get clusters | grep -qx recruitment; then
  "$KIND_BIN" create cluster --name recruitment --config k8s/kind.yaml --kubeconfig "$KUBECONFIG" --wait 180s
fi
"$ENGINE" build -t localhost/recruitment-cache-api:k8s .
# Preload images into kind. Existing local images are reused.
PROM_IMAGE="quay.io/prometheus/prometheus@sha256:d445d1806b38f85b5c394a1b87f94113fde0473b45245922c2e8b1bd41fa68ae"
for image in docker.io/library/redis:8-alpine mcr.microsoft.com/mssql/server:2025-latest docker.io/oliver006/redis_exporter:v1.93.0 "$PROM_IMAGE"; do
  if ! "$ENGINE" image inspect "$image" >/dev/null 2>&1; then "$ENGINE" pull "$image"; fi
done
"$ENGINE" tag "$PROM_IMAGE" localhost/recruitment-prometheus:20261028
IMAGES=(localhost/recruitment-cache-api:k8s docker.io/library/redis:8-alpine mcr.microsoft.com/mssql/server:2025-latest docker.io/oliver006/redis_exporter:v1.93.0 localhost/recruitment-prometheus:20261028)
if [[ "$ENGINE" == "podman" ]]; then
  "$ENGINE" save --multi-image-archive --format docker-archive -o "$STATE/images.tar" "${IMAGES[@]}"
else
  "$ENGINE" save -o "$STATE/images.tar" "${IMAGES[@]}"
fi
"$KIND_BIN" load image-archive --name recruitment "$STATE/images.tar"
rm -f "$STATE/images.tar"

kubectl create namespace recruitment --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n recruitment get secret recruitment-secrets >/dev/null 2>&1; then
  if [[ ! -f "$STATE/k8s-private.env" ]]; then
    node --input-type=module - "$STATE/k8s-private.env" <<'JS'
import { randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';
writeFileSync(process.argv[2], `DB_PASSWORD=Aa9!${randomBytes(24).toString('hex')}\n`, { mode: 0o600, flag: 'wx' });
JS
  fi
  kubectl -n recruitment create secret generic recruitment-secrets --from-env-file="$STATE/k8s-private.env"
fi
kubectl apply -f k8s/backend.yaml
kubectl -n recruitment rollout status statefulset/sqlserver --timeout=300s
# Restore the provided backup only into an absent DB; never replace a populated DB.
if [[ -n "${DATABASE_BACKUP:-}" ]]; then
  exists="$(kubectl -n recruitment exec sqlserver-0 -- bash -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT IIF(DB_ID(N'"'"'RecruitmentDb'"'"') IS NULL,0,1);"' | tr -d '[:space:]')"
  if [[ "$exists" == "0" ]]; then
    kubectl -n recruitment cp "$DATABASE_BACKUP" sqlserver-0:/var/opt/mssql/data/recruitment-import.bak
    kubectl -n recruitment exec sqlserver-0 -- bash -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -Q "RESTORE VERIFYONLY FROM DISK=N'"'"'/var/opt/mssql/data/recruitment-import.bak'"'"' WITH CHECKSUM; RESTORE DATABASE [RecruitmentDb] FROM DISK=N'"'"'/var/opt/mssql/data/recruitment-import.bak'"'"' WITH MOVE N'"'"'RecruitmentDb'"'"' TO N'"'"'/var/opt/mssql/data/RecruitmentDb.mdf'"'"', MOVE N'"'"'RecruitmentDb_log'"'"' TO N'"'"'/var/opt/mssql/data/RecruitmentDb_log.ldf'"'"', RECOVERY;"'
  else
    printf 'Existing Kubernetes RecruitmentDb retained; restore skipped.\n'
  fi
fi
kubectl apply -f k8s/api.yaml
kubectl -n recruitment create configmap recruitment-prometheus --from-file=prometheus.yaml=monitoring/prometheus.yaml --from-file=rules.yaml=monitoring/rules.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/prometheus.yaml
kubectl -n recruitment rollout status deployment/redis --timeout=180s
kubectl -n recruitment rollout status deployment/recruitment-api --timeout=300s
kubectl -n recruitment rollout status deployment/prometheus --timeout=180s
kubectl apply -k k8s/metrics-server
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
printf 'App: http://127.0.0.1:3103/\nPrometheus: http://127.0.0.1:9091/\n'
