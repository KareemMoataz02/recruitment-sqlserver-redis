# Local Kubernetes verification — 2026-10-28

The `recruitment` kind cluster runs on rootless Podman. All four workloads are ready: SQL Server, Redis with exporter, API, and Prometheus. SQL Server has an 8 GiB PVC; Prometheus has a 2 GiB PVC.

- Application: http://127.0.0.1:3103/
- Prometheus: http://127.0.0.1:9091/
- Existing local Grafana, new dashboard: http://127.0.0.1:3000/d/recruitment-kubernetes

A checksum-verified backup of the original database was restored into the new SQL Server. The restored database contains 30 applicants, 69 applications, and 159 status events. The original database was retained.

Live checks: `/health` reports API, SQL Server, and Redis ready. Two successive count requests for applicant 1 returned 11 applications with `X-Cache: MISS`, then `HIT`. Both Prometheus scrape targets are UP. SQL and Redis health metrics equal 1. Grafana loaded the 16-panel Recruitment Kubernetes dashboard; its three service health panels displayed 1.

Validation: all 12 integration tests passed after the dependency fix; npm audit reported zero vulnerabilities. The deployment script passed Bash syntax validation and `git diff --check` passed. The complete deployment script was prepared; this deployment used its equivalent steps interactively to work around local image-loading and network restrictions.

This is a single-node local lab. Persistent volumes survive pod restarts, but deleting the kind cluster deletes its local storage. Redis is intentionally ephemeral. Alert rules are installed; external alert notifications are not configured. Kubernetes changes remain local and uncommitted.

## Metrics-server and cache lab follow-up

Installed metrics-server v0.9.0 with the local-kind overlay. Its deployment reached 1/1 Ready. Verified `kubectl top nodes` and `kubectl top pods -n recruitment` returned CPU and memory readings for all four workloads. Observed sample: API 5m CPU / 44Mi memory, SQL Server 24m / 617Mi, Redis 6m / 18Mi, Prometheus 2m / 28Mi. Values change with load. Restarted the external K9s terminal to rediscover the Metrics API. The cache lab at port 3103 reports all dependencies ready and returned MISS then HIT for the same application-count request. Opened the lab in Firefox.
