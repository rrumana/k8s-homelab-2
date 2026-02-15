# Redis Enterprise Data Definitions

This folder follows a split model:

- `rec-platform/`: a shared `RedisEnterpriseCluster` foundation.
- `redb-platform/`: workload-class databases (`redis-cache`, `redis-queue`).

All resources run in the `databases` namespace.

The operator install is managed separately at
`cluster/platform/base/data/data-operators/redis-operator`.
