This directory defines a parallel Valkey replacement for the current Redis Enterprise footprint.

Architecture:
- `valkey-cache`: 1 primary + 2 replicas, no Sentinel, no persistence
- `valkey-queue`: 1 primary + 2 replicas, Sentinel-enabled, AOF-backed persistence

Why this shape:
- It matches the current logical split between cache and queue workloads.
- It avoids Redis Enterprise's REC/REDB control-plane complexity.
- `valkey-cache` uses the chart's built-in primary service for non-Sentinel-aware apps.
- `valkey-queue` keeps Sentinel because Immich can use the official Sentinel client configuration.

Vault prerequisites:
- `apps/databases/valkey-cache-auth` with property `password`
- `apps/databases/valkey-queue-auth` with property `password`

Client migration targets:
- `valkey-cache-primary.databases.svc.cluster.local:6379`
- `ioredis://<base64-json>` via Immich `REDIS_URL` pointing at `valkey-queue.databases.svc.cluster.local:26379`
