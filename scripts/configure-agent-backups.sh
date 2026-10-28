#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
MODE="${1:-container}"
if [[ "$MODE" == "kubernetes" ]]; then
  : "${KUBECONFIG:?Set KUBECONFIG to the local recruitment cluster config}"
  RUN=(kubectl --context kind-recruitment -n recruitment exec -i sqlserver-0 --)
elif [[ "$MODE" == "container" ]]; then
  ENGINE="${CONTAINER_ENGINE:-podman}"
  TARGET="${SQL_CONTAINER:-$("$ENGINE" compose ps -q sqlserver)}"
  [[ -n "$TARGET" ]] || { printf 'No SQL container found. Set SQL_CONTAINER.\n' >&2; exit 1; }
  RUN=("$ENGINE" exec -i "$TARGET")
else
  printf 'Usage: %s [container|kubernetes]\n' "$0" >&2
  exit 1
fi
"${RUN[@]}" mkdir -p /var/opt/mssql/backups
"${RUN[@]}" bash -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -Q "DECLARE @Deadline datetime=DATEADD(second,45,GETDATE()); WHILE GETDATE()<@Deadline AND NOT EXISTS(SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE N'"'"'SQL Server Agent%'"'"' AND status_desc=N'"'"'Running'"'"') WAITFOR DELAY '"'"'00:00:01'"'"'; IF NOT EXISTS(SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE N'"'"'SQL Server Agent%'"'"' AND status_desc=N'"'"'Running'"'"') THROW 51103, '"'"'Enable SQL Server Agent and restart SQL Server first.'"'"', 1;"'
"${RUN[@]}" bash -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -w 220' < sql/agent-backups.sql
