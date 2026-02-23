# ARR + Jellyseerr PostgreSQL Migration Runbook

This runbook migrates:
- `sonarr`, `radarr`, `lidarr`, `prowlarr` from SQLite to PostgreSQL (`pg-media`)
- `jellyseerr` to PostgreSQL (`pg-media`) with no SQLite data migration

## 1) Prepare Vault secret values

Populate Vault key `apps/media/arr-postgres` with:
- `SONARR_PG_PASSWORD`
- `RADARR_PG_PASSWORD`
- `LIDARR_PG_PASSWORD`
- `PROWLARR_PG_PASSWORD`
- `JELLYSEERR_DB_PASS`
- `JELLYSEERR_DB_TYPE` (initial value: `sqlite`, set to `postgres` during cutover)
- `SERVARR_PG_ENABLE` (initial value: `false`, set to `true` during cutover)

## 2) Apply GitOps changes

Apply/sync:
- `cluster/apps/media/arr/externalsecret.yaml`
- `cluster/apps/media/arr/postgres-configmap.yaml`
- `cluster/apps/media/arr/servarr-postgres-bootstrap-configmap.yaml`
- `cluster/apps/media/arr/deployment.yaml`
- `cluster/apps/media/arr/kustomization.yaml`

## 3) Create PostgreSQL roles and databases

Run from a cluster-connected shell:

```bash
DB_NS=databases
PG_SU_USER=$(kubectl -n "$DB_NS" get secret pg-media-superuser -o jsonpath='{.data.username}' | base64 -d)
PG_SU_PASS=$(kubectl -n "$DB_NS" get secret pg-media-superuser -o jsonpath='{.data.password}' | base64 -d)

SONARR_PG_PASSWORD=$(kubectl -n media get secret arr-postgres-secret -o jsonpath='{.data.SONARR_PG_PASSWORD}' | base64 -d)
RADARR_PG_PASSWORD=$(kubectl -n media get secret arr-postgres-secret -o jsonpath='{.data.RADARR_PG_PASSWORD}' | base64 -d)
LIDARR_PG_PASSWORD=$(kubectl -n media get secret arr-postgres-secret -o jsonpath='{.data.LIDARR_PG_PASSWORD}' | base64 -d)
PROWLARR_PG_PASSWORD=$(kubectl -n media get secret arr-postgres-secret -o jsonpath='{.data.PROWLARR_PG_PASSWORD}' | base64 -d)
JELLYSEERR_DB_PASS=$(kubectl -n media get secret arr-postgres-secret -o jsonpath='{.data.JELLYSEERR_DB_PASS}' | base64 -d)

SONARR_PG_PASSWORD_ESC=${SONARR_PG_PASSWORD//\'/\'\'}
RADARR_PG_PASSWORD_ESC=${RADARR_PG_PASSWORD//\'/\'\'}
LIDARR_PG_PASSWORD_ESC=${LIDARR_PG_PASSWORD//\'/\'\'}
PROWLARR_PG_PASSWORD_ESC=${PROWLARR_PG_PASSWORD//\'/\'\'}
JELLYSEERR_DB_PASS_ESC=${JELLYSEERR_DB_PASS//\'/\'\'}

kubectl -n "$DB_NS" run pg-arr-bootstrap --rm -i --restart=Never --image=postgres:18 \
  --env="PGPASSWORD=$PG_SU_PASS" -- \
  psql -h pg-media-rw -U "$PG_SU_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='sonarr') THEN CREATE ROLE sonarr LOGIN PASSWORD '${SONARR_PG_PASSWORD_ESC}'; ELSE ALTER ROLE sonarr WITH PASSWORD '${SONARR_PG_PASSWORD_ESC}'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='radarr') THEN CREATE ROLE radarr LOGIN PASSWORD '${RADARR_PG_PASSWORD_ESC}'; ELSE ALTER ROLE radarr WITH PASSWORD '${RADARR_PG_PASSWORD_ESC}'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='lidarr') THEN CREATE ROLE lidarr LOGIN PASSWORD '${LIDARR_PG_PASSWORD_ESC}'; ELSE ALTER ROLE lidarr WITH PASSWORD '${LIDARR_PG_PASSWORD_ESC}'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='prowlarr') THEN CREATE ROLE prowlarr LOGIN PASSWORD '${PROWLARR_PG_PASSWORD_ESC}'; ELSE ALTER ROLE prowlarr WITH PASSWORD '${PROWLARR_PG_PASSWORD_ESC}'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='jellyseerr') THEN CREATE ROLE jellyseerr LOGIN PASSWORD '${JELLYSEERR_DB_PASS_ESC}'; ELSE ALTER ROLE jellyseerr WITH PASSWORD '${JELLYSEERR_DB_PASS_ESC}'; END IF;
END
\$\$;

SELECT 'CREATE DATABASE sonarr OWNER sonarr'      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='sonarr')      \gexec
SELECT 'CREATE DATABASE sonarr_log OWNER sonarr'  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='sonarr_log')  \gexec
SELECT 'CREATE DATABASE radarr OWNER radarr'      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='radarr')      \gexec
SELECT 'CREATE DATABASE radarr_log OWNER radarr'  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='radarr_log')  \gexec
SELECT 'CREATE DATABASE lidarr OWNER lidarr'      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='lidarr')      \gexec
SELECT 'CREATE DATABASE lidarr_log OWNER lidarr'  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='lidarr_log')  \gexec
SELECT 'CREATE DATABASE prowlarr OWNER prowlarr'  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='prowlarr')    \gexec
SELECT 'CREATE DATABASE prowlarr_log OWNER prowlarr' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='prowlarr_log') \gexec
SELECT 'CREATE DATABASE jellyseerr OWNER jellyseerr' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='jellyseerr') \gexec
SQL
```

## 4) Servarr maintenance window and data migration

Enable PostgreSQL cutover flags in Vault:

1. Set `apps/media/arr-postgres:SERVARR_PG_ENABLE=true`.
2. Set `apps/media/arr-postgres:JELLYSEERR_DB_TYPE=postgres`.
3. Force refresh ExternalSecret:

```bash
kubectl -n media annotate externalsecret arr-postgres-secret force-sync=$(date +%s) --overwrite
kubectl -n media get secret arr-postgres-secret -o jsonpath='{.data.SERVARR_PG_ENABLE}' | base64 -d; echo
kubectl -n media get secret arr-postgres-secret -o jsonpath='{.data.JELLYSEERR_DB_TYPE}' | base64 -d; echo
```

Stop writes:

```bash
kubectl -n media scale deployment/arr-stack --replicas=0
kubectl -n media rollout status deployment/arr-stack --timeout=10m
```

Bootstrap empty schema in PostgreSQL:

```bash
kubectl -n media scale deployment/arr-stack --replicas=1
kubectl -n media rollout status deployment/arr-stack --timeout=15m
sleep 120
kubectl -n media scale deployment/arr-stack --replicas=0
kubectl -n media rollout status deployment/arr-stack --timeout=10m
```

Run one-time SQLite -> PostgreSQL migration:

```bash
kubectl apply -f cluster/apps/media/arr/migrate-servarr-sqlite-to-postgres-job.yaml
kubectl -n media logs -f job/migrate-servarr-sqlite-to-postgres
kubectl -n media wait --for=condition=Complete job/migrate-servarr-sqlite-to-postgres --timeout=60m
```

Start apps:

```bash
kubectl -n media scale deployment/arr-stack --replicas=1
kubectl -n media rollout status deployment/arr-stack --timeout=15m
```

## 5) Validate

Check bootstrap init container logs (it writes Postgres settings into each Servarr `config.xml`):

```bash
kubectl -n media logs deploy/arr-stack -c servarr-postgres-bootstrap --tail=200
```

Check app logs:

```bash
kubectl -n media logs deploy/arr-stack -c sonarr --since=15m | tail -n 100
kubectl -n media logs deploy/arr-stack -c radarr --since=15m | tail -n 100
kubectl -n media logs deploy/arr-stack -c lidarr --since=15m | tail -n 100
kubectl -n media logs deploy/arr-stack -c prowlarr --since=15m | tail -n 100
kubectl -n media logs deploy/arr-stack -c jellyseerr --since=15m | tail -n 100
```

## 6) Fast rollback

1. Scale down `arr-stack`.
2. Restore each `config.xml` from `config.xml.pre-postgres.bak` on each Servarr PVC.
3. Set Vault key `apps/media/arr-postgres:SERVARR_PG_ENABLE=false`.
4. Set Vault key `apps/media/arr-postgres:JELLYSEERR_DB_TYPE=sqlite`.
5. Force-refresh `arr-postgres-secret` via ExternalSecret annotation.
6. Scale `arr-stack` back up.
