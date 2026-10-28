# Local Kubernetes deployment and Grafana monitoring

This deployment runs the API, Redis + exporter, SQL Server, and Prometheus in the `recruitment` namespace of a local kind cluster. Existing local SQL/Redis/API services remain separate. The current live database can be copied through a verified backup; source records are not modified.

## Prerequisites

Node.js 22+, kubectl, kind v0.33.0, a working Podman or Docker runtime, x86-64, and enough memory/disk for another SQL Server and a Kubernetes node. Rootless Podman may require a delegated systemd user scope and `k8s-file` container logging; see the kind rootless guide. No OpenShift credentials are used.

Install dependencies with `npm ci`. Then:

```bash
# With kind available on PATH; uses a private .local/kubeconfig by default.
CONTAINER_ENGINE=podman ./scripts/deploy-local-k8s.sh
```

The script creates the cluster if absent, builds/loads the API image, generates a namespace-local SQL Secret, deploys SQL/Redis, optionally restores a backup only when RecruitmentDb is absent, and deploys API/Prometheus. Without a backup, the API init container runs the existing sample bootstrap.

For rootless Podman, a delegated scope may be required:

```bash
systemd-run --user --scope -p Delegate=yes \
  env CONTAINER_ENGINE=podman ./scripts/deploy-local-k8s.sh
```

An optional `DATABASE_BACKUP=/absolute/path/RecruitmentDb.bak` imports the existing database. Its SQL Server version must be compatible; expected logical names are RecruitmentDb and RecruitmentDb_log. Backups, passwords and kubeconfigs are excluded from Git. Reruns never replace an existing RecruitmentDb.

## Access and storage

- Kubernetes app: http://127.0.0.1:3103/
- Prometheus: http://127.0.0.1:9091/
- SQL Server/Redis are ClusterIP-only; no host SQL/Redis ports are added.
- SQL uses an 8 GiB PVC. Prometheus uses a 2 GiB PVC with 7-day / 512 MB retention.
- Redis is disposable, with a 64 MB cache limit and no persistence.
- kind maps NodePorts only to loopback. The API binds all interfaces inside its pod, with probes and services providing cluster access.

The standard local manifests are not an OpenShift restricted-SCC profile: SQL uses its documented nonroot UID 10001. Do not apply them to a remote/shared cluster without adapting storage, security policy, authentication and image distribution.

## Application probes and metrics

`/live` checks process liveness without coupling restarts to SQL. `/health` checks SQL readiness and reports optional Redis availability. `/metrics` exposes Prometheus-format HTTP counters/latency histograms, cache hits/misses/bypasses/invalidations, count-query totals and duration, SQL availability, Redis client readiness, and Node process metrics. Applicant IDs are not used as metric labels, keeping cardinality bounded.

Prometheus statically scrapes the API service and the Redis exporter sidecar. It evaluates API-down, SQL-unavailable, and Redis-unavailable rules. These appear in Prometheus; no external Alertmanager notifications are configured.

## Existing local Grafana integration

`monitoring/grafana-datasource.yaml` defines an additional datasource pointing to localhost:9091. It does not replace the existing default datasource. `monitoring/grafana-dashboard.json` defines the Recruitment Kubernetes dashboard, including health, cache-hit ratio, HTTP rate/latency/errors, SQL query rate/latency, Redis memory/clients/evictions, and API CPU/memory.

In the local Device Insights Grafana setup, copy the datasource YAML into its provisioning/datasources directory and the JSON into its dashboards directory, then restart Grafana to load the new datasource. Existing dashboards and datasources must be retained. Dashboard URL: `http://127.0.0.1:3000/d/recruitment-kubernetes`.

## Validate

```bash
export KUBECONFIG="$PWD/.local/kubeconfig"
kubectl -n recruitment get pods,pvc,services
curl -f http://127.0.0.1:3103/health
curl -s http://127.0.0.1:3103/metrics
curl -s http://127.0.0.1:9091/api/v1/targets
```

Generate read-only traffic using the browser's cache controls. Confirm MISS then HIT, both Prometheus targets UP, and real values in Grafana. Direct SQL changes are visible after TTL/manual clearing, as in the original lab. There is one API replica: the cache locks and dirty-key state remain process-local.

## Lifecycle

The cluster persists until explicitly deleted. PVC data persists across pod restarts but lives inside the kind node; deleting the cluster destroys it. Export a verified SQL backup before deleting the cluster or its PVCs. No automatic cluster deletion or source-container removal is performed by the deployment script.

## References

- https://kind.sigs.k8s.io/docs/user/rootless/
- https://github.com/prometheus/client_js
- https://github.com/oliver006/redis_exporter
- https://grafana.com/docs/grafana/latest/administration/provisioning/

### K9s CPU and memory metrics

Install the pinned metrics-server release for this local kind lab:

```bash
kubectl --kubeconfig "$KUBECONFIG" apply -k k8s/metrics-server
kubectl --kubeconfig "$KUBECONFIG" -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl --kubeconfig "$KUBECONFIG" top pods -n recruitment
```

The local overlay uses `--kubelet-insecure-tls` because kind's kubelet serving certificate lacks an IP SAN for its InternalIP. This is scoped to metrics-server's kubelet connection in this local lab; use trusted kubelet serving certificates for a production cluster. API authentication and RBAC remain enabled. Allow initial scrapes to finish, then reopen K9s if it cached the previously absent Metrics API. Metrics-server supplies current CPU and memory to K9s and `kubectl top`; Prometheus and Grafana supply application/cache history independently.

### Scheduled database backups

The SQL StatefulSet enables SQL Server Agent. The deployment script installs daily full and 15-minute log backup jobs after database initialization. See [SQL Server Agent](SQL-AGENT.md) for schedules, storage limits, verification, and manual setup.
