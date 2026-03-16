This directory defines a parallel Valkey replacement for the current Redis Enterprise footprint.

Architecture:
- `valkey-cache`: 1 primary + 2 replicas, Sentinel-enabled, no persistence
- `valkey-queue`: 1 primary + 2 replicas, Sentinel-enabled, AOF-backed persistence

Why this shape:
- It matches the current logical split between cache and queue workloads.
- It avoids Redis Enterprise's REC/REDB control-plane complexity.
- It keeps a stable write endpoint by reconciling a `*-rw` Service onto the current primary pod.

Vault prerequisites:
- `apps/databases/valkey-cache-auth` with property `password`
- `apps/databases/valkey-queue-auth` with property `password`

Client migration targets:
- `valkey-cache-rw.databases.svc.cluster.local:6379`
- `valkey-queue-rw.databases.svc.cluster.local:6379`
