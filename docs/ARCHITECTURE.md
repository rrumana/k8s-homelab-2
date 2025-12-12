# k8s-homelab-2 Architecture

This document describes the **architecture, layout, and rationale** for the `k8s-homelab-2` cluster repository and the Kubernetes platform it manages.

It is written so that someone with basic Kubernetes knowledge can:

- Understand the overall design and philosophy.
- Bootstrap the cluster using this repo.
- Add new platform capabilities and apps in a consistent way.
- Reason about where any given feature “belongs” in the file tree.

> For a step‑by‑step bootstrap runbook (exact commands, phases, and checks), see `docs/cluster-bootstrap-runbook.md`. This document focuses on **structure and design decisions**, not every command.

---

## 1. Goals & Scope

### 1.1 Goals

This repository is designed to manage a **home / personal production** cluster that is:

- **GitOps-driven** – the Git repo is the source of truth.
- **Highly observable** – metrics, logs, and traces for both platform and apps.
- **Resilient** – HA control plane, replicated storage, backups and restore.
- **Secure by default** – baseline PodSecurity, Kyverno policies, secrets management.
- **Extensible** – easy to add new apps/platform components without making a mess.
- **Portfolio-worthy** – reflects industry practices (operators, service mesh, Gateway API, etc.).

### 1.2 Scope

This repo manages:

- The **cluster platform** (networking, storage, security, observability, service mesh, backup, GitOps).
- A set of **apps**:
  - Media stack (*arrs, qBittorrent, Jellyfin, Plex, Immich).
  - Productivity stack (Nextcloud, Collabora, Vaultwarden, etc.).
  - AI stack (local LLM, LibreChat, n8n, Qdrant).
  - Web (portfolio site).
- **Platform databases and caches**:
  - PostgreSQL via CloudNativePG.
  - Redis via a Redis operator.

Large **media data** remains on a TrueNAS NAS. Rook/Ceph is used for **app PVCs**, not multi‑TiB media libraries.

---

## 2. High-Level Architecture

### 2.1 Cluster Base

- OS: **Arch Linux** on all nodes.
- Kubernetes: **kubeadm**-based cluster (replacing k3s).
- Control plane: designed for **etcd-based HA** (multiple control-plane nodes).
- CNI: **Cilium** with kube‑proxy replacement (eBPF data plane).
- Nodes: mini PCs with NVMe storage; NAS provides network storage.

### 2.2 GitOps

- GitOps controller: **ArgoCD**.
- Pattern:
  - Minimal bootstrap applies:
    - Cilium (once).
    - ArgoCD and a root “app-of-apps” `Application`.
  - ArgoCD then syncs:
    - `cluster/platform/**` (platform components).
    - `cluster/apps/**` (applications).

### 2.3 Storage

- **Rook/Ceph**:
  - Backing for *app-level PVCs* (databases, app configs, small stateful data).
  - Replication and self-healing via Ceph pools.
- **TrueNAS**:
  - Hot all-NVMe pool: media libraries (Immich originals, Plex/Jellyfin libraries, etc.).
  - Cold pool: Restic, Velero backups, Longhorn legacy backups.
- StorageClasses:
  - `ceph-block` (or similar) for app PVCs.
  - `nas-media-hot` for large media libraries.
  - `nas-backup-cold` for backup targets.

### 2.4 Networking & Ingress

- CNI: Cilium (no kube-proxy).
- Load balancing: **MetalLB**, with a dedicated service IP range.
- DNS: **external-dns** with Cloudflare.
- Certificates: **cert-manager** with Let’s Encrypt (DNS‑01).
- Ingress & Gateway: **HAProxy** as a Gateway API controller:
  - A `GatewayClass` and shared `Gateway` front most HTTP traffic.
  - Apps define `HTTPRoute` or Ingress resources that bind to this gateway.

### 2.5 Service Mesh

- **Linkerd**:
  - Provides mTLS, metrics, and traffic control for selected services.
  - Injection is **selective**, not cluster-wide:
    - Normal platform and web/API apps are meshed.
    - Heavy/complex workloads (like *arr + gluetun) may remain unmeshed.

### 2.6 Observability

- Metrics: **kube-prometheus-stack** (Prometheus, Alertmanager, Grafana, node exporters, kube-state-metrics).
- Logs: **Loki** + log shipper DaemonSets (e.g., Promtail/Vector).
- Traces:
  - **Tempo** for trace storage.
  - **OpenTelemetry Collector** as a central telemetry pipeline.

### 2.7 Security & Policy

- **PodSecurity**: namespace-level labels to enforce baseline/restricted policies.
- **Kyverno**:
  - Policy engine for:
    - Blocking obviously bad pods (no `:latest`, missing resources).
    - Enforcing best practices (non-root, read-only root FS) with **exceptions** where needed.
- **external-secrets**:
  - Syncs secrets from external stores into Kubernetes Secrets.
- **NetworkPolicies**:
  - Shared and/or per-app policies allow only the necessary connectivity.

Some apps (e.g. Homarr) require root; Kyverno/PodSecurity are tuned to allow **namespace- or label-scoped exceptions** for these.

### 2.8 Databases & Caches

- **PostgreSQL**:
  - Managed by **CloudNativePG** operator.
  - One or more clusters (e.g., `platform-postgres`) defined as infrastructure.
  - Apps use Postgres as an external DB instead of bundling their own DB.
- **Redis**:
  - Managed by a **Redis operator** (e.g., OT Container Kit Redis Operator).
  - One or more Redis clusters (e.g., `redis-cache`, `redis-queue`) for:
    - Caching.
    - Job queues.
  - Apps disable bundled Redis and consume these shared services.

This pattern centralizes HA, backups, and upgrades for DB/cache, avoiding “one random DB per Helm chart”.

### 2.9 Backup & DR

- **Velero**:
  - Cluster and namespace backup/restore to NAS or S3-like storage.
  - Treats Ceph PV data via CSI snapshots or restic sidecar.
- Existing **Restic** backups (for nodes) remain in use.
- Ceph and databases also have their own backup mechanisms (e.g., Barman for Postgres).

---

## 3. Repository Layout & Conventions

At a high level:

```text
k8s-homelab-2/
  cluster/
    bootstrap/         # One-time or rare bootstrapping (kubeadm config, Argo roots)
    platform/          # Cluster-wide and platform-level components
    apps/              # Application stacks (media, productivity, ai, web, shared)
  docs/                # Runbooks and design docs (including this file)
  scripts/             # Helper scripts, not authoritative definitions
  README.md
  ARCHITECTURE.md      # This document
```

### 3.1 Core conventions

1. **Platform vs Apps**
   - `cluster/platform/**`:
     - Things you’d expect in an SRE/platform team repo: networking, storage, observability, GitOps, mesh, backup, DB operators, caches.
   - `cluster/apps/**`:
     - Individual app manifests: Deployments, Services, HPAs, PDBs, app-specific PVCs, configs, etc.

2. **Bootstrap vs GitOps**
   - `cluster/bootstrap/**` is for **initial bootstrapping**:
     - kubeadm config.
     - ArgoCD install and root Application.
     - (Cilium is installed manually, once, then managed via Helm/values as needed.)
   - After bootstrap, ArgoCD manages `cluster/platform/**` and `cluster/apps/**` exclusively.

3. **Kustomize as the local orchestrator**
   - Each logical unit (platform component or app) has a `kustomization.yaml`.
   - ArgoCD Applications point at these directories.

4. **Separation of declarative infra and data**
   - Repo stores **manifests and configs**, not backups or large datasets.
   - Actual data is on Ceph volumes and NAS datasets.

---

## 4. `cluster/bootstrap`: One-Time Initialization

```text
cluster/
  bootstrap/
    argocd/
      argocd-install.yaml
      kustomization.yaml
    kubeadm-config.yaml
    root-application/
      root-app.yaml    # ArgoCD "app of apps"
```

- `kubeadm-config.yaml`:
  - Declarative kubeadm configuration: pod/service CIDRs, controlPlaneEndpoint, etc.
  - Used once for `kubeadm init`.
- `argocd/`:
  - YAML for installing ArgoCD (CRDs + controllers) in the cluster.
  - Applied manually once after CNI is up.
- `root-application/`:
  - Defines the ArgoCD root `Application` that points at `cluster/platform/`.
  - ArgoCD then discovers AppProjects and Applications under `cluster/platform/gitops/argocd/`.

After bootstrap, changes to platform/apps are made in Git, and ArgoCD applies them.

---

## 5. `cluster/platform`: Platform Components

```text
cluster/
  platform/
    base/
      namespaces/
      storage/
        rook-ceph/
        nas/
        postgres/
        redis/
      networking/
        cert-manager/
        cilium/
        external-dns/
        metallb/
      security/
        external-secrets/
        kyverno/
        pod-security/
    ingress/
      haproxy-gateway/
    observability/
      kube-prometheus-stack/
      loki/
      tempo/
      opentelemetry-collector/
    service-mesh/
      linkerd/
        control-plane/
        viz/
    backup/
      velero/
    scheduling/
      descheduler/
    gitops/
      argocd/
        projects/
        apps/
```

### 5.1 `base/namespaces/`

Defines all namespaces used by platform and apps, including:

- `media`, `productivity`, `ai`, `web`, `monitoring`, `database`/`data`, `rook-ceph`, `linkerd`, etc.
- Each namespace includes:
  - Labels for PodSecurity (e.g. baseline/restricted).
  - Optional `rcrumana.dev/part-of` labels for grouping.

### 5.2 Storage

#### 5.2.1 `storage/rook-ceph/`

- Rook/Ceph operator and cluster definition:
  - `CephCluster`, OSD config, pools, `StorageClass` definitions (`ceph-block`, etc.).
- Ceph is used for:
  - App PVCs (databases, app state).
  - Not for huge media libraries.

#### 5.2.2 `storage/nas/`

- StorageClasses for NAS-backed volumes:
  - `nas-media-hot` for media libraries.
  - `nas-backup-cold` for backup storage.
- Optional static `PersistentVolume`s if needed.

#### 5.2.3 `storage/postgres/`

Holds **CloudNativePG** operator and platform Postgres clusters.

Example structure:

```text
cluster/platform/base/storage/postgres/
  cloudnativepg-operator/
    kustomization.yaml       # Installs CNPG operator CRDs + controller
  platform-postgres/
    kustomization.yaml
    cluster.yaml             # CloudNativePG Cluster spec (e.g. 3 instances)
    secret-superuser.yaml    # Superuser credentials
    secret-appuser.yaml      # Default app user
    secret-backup-s3.yaml    # TrueNAS S3 credentials for Barman
    scheduled-backup.yaml    # Daily backup schedule
    pooler-rw.yaml           # PgBouncer pooler (Pooler CR)
```

**Design decisions:**

- **Single operator, shared**:
  - One CloudNativePG operator manages multiple clusters.
- **Platform Postgres cluster**:
  - `platform-postgres` is a shared HA cluster for smaller apps.
  - Larger/critical apps can get their own Postgres cluster if needed.
- **External DB pattern**:
  - App Helm charts disable bundled DBs and point to these platform Postgres endpoints.
- **Backups**:
  - Barman object store configured to backup to TrueNAS S3 with explicit retention.
  - Daily `ScheduledBackup` objects.
- **Connection pooling**:
  - PgBouncer pooler (`Pooler` CR) reduces connection churn and centralizes tuning.

#### 5.2.4 `storage/redis/` (or `database/redis/`)

Holds the **Redis operator** and platform Redis clusters.

Example structure:

```text
cluster/platform/base/database/
  redis-operator/
    kustomization.yaml          # Installs Redis operator CRDs + controller
  redis/
    kustomization.yaml
    redis-auth-secret.yaml      # Shared password
    redis-cache-cluster.yaml    # RedisCluster for caching / sessions
    redis-queue-cluster.yaml    # RedisCluster for job queues
```

**Design decisions:**

- **Single Redis operator**:
  - One operator manages all Redis clusters.
- **Two primary clusters**:
  - `redis-cache` – ephemeral cache/session store.
  - `redis-queue` – job/queue store with appropriate persistence.
- **External Redis pattern**:
  - Apps disable bundled Redis in Helm charts.
  - They consume `redis-cache` or `redis-queue` via stable Services.
- **HA & metrics**:
  - Multi-node Redis clusters for HA.
  - Exporters enabled so Prometheus can scrape metrics.

---

### 5.3 Networking

#### 5.3.1 `networking/cilium/`

- Cilium Helm values/config and documentation.
- Cilium is initially installed manually (one-time) using the CLI, then configuration is tracked here.
- Provides:
  - eBPF-based networking.
  - Kube-proxy replacement.
  - Optional Hubble for network observability.

#### 5.3.2 `networking/metallb/`

- MetalLB IP pools (`IPAddressPool`) and L2 advertisements.
- Defines a dedicated LoadBalancer IP range for the cluster.

#### 5.3.3 `networking/external-dns/`

- external-dns deployment configuration:
  - Cloudflare provider.
  - Domain filters (e.g. `rcrumana.xyz`).
  - Source types (Ingress, Service, Gateway).

#### 5.3.4 `networking/cert-manager/`

- cert-manager deployment and CRDs.
- ClusterIssuers:
  - Production Let’s Encrypt using DNS‑01 with Cloudflare.
  - Optional staging issuer for testing.

---

### 5.4 Security

#### 5.4.1 `security/pod-security/`

- Namespace labels and/or supporting resources for enforcing PodSecurity:
  - `restricted` by default where possible.
  - `baseline` or `privileged` only for namespaces that truly need it (e.g. Homarr, low-level infra).

#### 5.4.2 `security/kyverno/`

- Kyverno installation and policies:
  - Start in **audit mode**.
  - Policies to:
    - Disallow `:latest`.
    - Require requests/limits.
    - Encourage non-root containers.
  - Exceptions:
    - Namespaces or workloads that must run as root are carved out via labels/annotations.

#### 5.4.3 `security/external-secrets/`

- external-secrets operator installation.
- `ClusterSecretStore` definitions pointing at external secret backends (Vault, TrueNAS S3, etc).
- Shared patterns for app `ExternalSecret`s.

---

### 5.5 Ingress & Gateway

```text
cluster/platform/ingress/haproxy-gateway/
```

- HAProxy Gateway/Ingress controller deployment.
- `GatewayClass` and shared `Gateway`:
  - Public HTTP/HTTPS endpoints.
  - Backed by a LoadBalancer Service that MetalLB assigns an IP to.
- ArgoCD Application for this directory ensures gateway config is declarative.

Apps then define `HTTPRoute`s (or Ingress) that bind to this shared Gateway.

---

### 5.6 Observability

```text
cluster/platform/observability/
  kube-prometheus-stack/
  loki/
  tempo/
  opentelemetry-collector/
```

- **kube-prometheus-stack**:
  - Prometheus, Alertmanager, Grafana, exporters.
- **Loki**:
  - Central log store.
  - DaemonSets (e.g. Promtail) to ship logs.
- **Tempo**:
  - Trace store for distributed tracing.
- **OpenTelemetry Collector**:
  - Central pipeline that receives OTLP data from apps / Linkerd and exports to Tempo, Prometheus, etc.

---

### 5.7 Service Mesh: Linkerd

```text
cluster/platform/service-mesh/linkerd/
  control-plane/
  viz/
```

- Control plane:
  - Core Linkerd components.
- Viz:
  - Dashboards, Tap, metrics UI.

**Design decisions:**

- Mesh is **opt-in per namespace or app**:
  - Add `linkerd.io/inject: enabled` label/annotation where needed.
- Some workloads (e.g. *arr + gluetun*) remain **unmeshed**:
  - They already have complex networking (VPN sidecars).
  - Avoid conflicts between VPN and mesh sidecars.

---

### 5.8 Backup

```text
cluster/platform/backup/velero/
```

- Velero deployment and configuration:
  - BackupStorageLocation pointing to NAS/S3.
  - Schedules for regular namespace/cluster backups.
  - CSI integration for Ceph snapshots, if enabled.

Backups complement:

- CloudNativePG’s own Barman backups.
- Restic-based node backups.

---

### 5.9 Scheduling

```text
cluster/platform/scheduling/descheduler/
```

- Descheduler configuration:
  - Policies to nudge pods off overutilized or imbalanced nodes.
  - Conservative settings at first, to avoid destabilizing workloads.

PodDisruptionBudgets in app directories control how Disruptions and descheduling affect each app.

---

### 5.10 GitOps Configuration

```text
cluster/platform/gitops/argocd/
  projects/
  apps/
```

- `projects/`:
  - ArgoCD `AppProject` definitions for logical groupings:
    - platform, media, productivity, ai, web, etc.
- `apps/`:
  - ArgoCD `Application` resources that point at:
    - Platform components (namespaces, storage, networking, security, etc.).
    - App stacks (Plex, Nextcloud, Immich, etc.).
- ArgoCD root `Application` (in `bootstrap/root-application/`) references this area.

---

## 6. `cluster/apps`: Applications

Top-level structure:

```text
cluster/
  apps/
    ai/
      local-llm/
      n8n/
      qdrant/
    media/
      arr/
      arr-lts/
      arr-lts2/
      immich/
      jellyfin/
      plex/             # expect to add
    productivity/
      collabora/
      elasticsearch/
      homarr/
      nextcloud/
      unifi-controller/
      uptime-kuma/
      vaultwarden/
      whiteboard/
    web/
      portfolio/
        prod/
        staging/
    shared/
      config/
      ingress/
      networkpolicies/
```

### 6.1 General app layout

Each app directory follows a similar pattern. Example (Plex):

```text
cluster/apps/media/plex/
  kustomization.yaml
  deployment.yaml
  service.yaml
  hpa.yaml
  pdb.yaml
  configmap.yaml
  externalsecret.yaml         # or secret.yaml / externalsecret.yaml
  pvc-config.yaml             # small Ceph-backed config PVC
  pvc-cache.yaml              # optional cache/transcode PVC
  servicemonitor.yaml         # for Prometheus (if used)
  linkerd-serviceprofile.yaml # if meshed
  networkpolicy.yaml          # if app-specific NP needed
```

**Key app-level resources:**

- **Deployment / StatefulSet**:
  - Pod spec, resource requests/limits, node affinity (e.g. GPU node).
  - SecurityContext overrides specific to app.
- **Service (ClusterIP)**:
  - Internal service used by Gateway/Ingress and other apps.
- **HPA (HorizontalPodAutoscaler)**:
  - CPU/memory/custom metrics-based scaling.
- **PDB (PodDisruptionBudget)**:
  - Controls minimum availability during node drains and descheduler evictions.
- **PVCs**:
  - Ceph-backed volumes for app configs/state.
  - NAS-backed volumes for large media where needed (e.g. Plex libraries).
- **ConfigMap / Secret / ExternalSecret**:
  - Configuration and credentials.
  - ExternalSecret used where secrets come from external stores.

### 6.2 Shared app-layer resources: `apps/shared/`

```text
cluster/apps/shared/
  config/
  ingress/
  networkpolicies/
```

- `config/`:
  - Shared configuration fragments used by multiple apps (if any).
- `ingress/`:
  - Shared Ingress/HTTPRoute resources for multiple apps.
  - For example:
    - `media-plex.yaml` for Plex.
    - `media-jellyfin.yaml`, `media-immich.yaml`, etc.
  - These bind hostnames and paths to the HAProxy `Gateway`.
- `networkpolicies/`:
  - Shared NetworkPolicy definitions that apply to groups of apps (e.g. “media namespace may access NAS”).

This keeps cross-cutting app-level routing and network policy in one place, while keeping **per-app behavior** inside each app directory.

---

## 7. Platform Databases & Redis Usage Model

### 7.1 Postgres (CloudNativePG)

**Philosophy:**

- Treat Postgres as a **platform service**, not something each app manages.
- Use **one operator** and a few well-defined clusters, rather than many random DB StatefulSets.

**Pattern:**

1. Operator:
   - Installed via `cluster/platform/base/storage/postgres/cloudnativepg-operator/`.
2. Platform Cluster (e.g., `platform-postgres`):
   - Defined in `platform-postgres/cluster.yaml`.
   - Provides HA Postgres for multiple apps.
3. Pooler:
   - PgBouncer `Pooler` CR for connection pooling.
4. Backups:
   - Barman object store configured to backup to TrueNAS S3.
   - Daily `ScheduledBackup` CRs.
5. Apps:
   - Disable bundled DBs in Helm charts (`postgresql.enabled=false`, etc.).
   - Use external DB settings pointing to `platform-postgres` or app-specific clusters.
   - Credentials provided via Secrets/ExternalSecrets created by operator or manually.

This yields:

- One consistent HA and backup story for most relational data.
- Easier upgrades (change `imageName` → rolling minor upgrade).
- Cleaner GitOps: DB lifecycle is defined separately from app Deployments.

### 7.2 Redis

**Philosophy:**

- Same as Postgres: **one operator, multiple shared Redis clusters**.
- Redis is mostly used for **caches and queues**, so:
  - We care more about availability and performance than about perfect durability (for cache).
  - Queues get a slightly more conservative persistence profile.

**Pattern:**

1. Operator:
   - Installed via `cluster/platform/base/database/redis-operator/`.
2. Redis clusters:
   - `redis-cache`:
     - General cache/session store.
   - `redis-queue`:
     - Job/queue workloads.
   - Defined under `cluster/platform/base/database/redis/`.
3. Authentication:
   - Shared `redis-auth-secret.yaml` or per-cluster secrets.
4. Apps:
   - Disable embedded Redis (`redis.enabled=false` in charts).
   - Use external Redis host/port/password pointing at these clusters.

This avoids a zoo of tiny Redis instances and centralizes HA + monitoring.

---

## 8. Special Cases: Workloads that Don’t Fit the Mesh

### 8.1 *arr + gluetun stack

For the media stack (*arr apps + qBittorrent + gluetun), the networking is non-trivial:

- gluetun runs as a sidecar or main container owning the pod’s routing.
- All external egress (trackers, peers, indexers) flows through the VPN.

**Design decision:**

- Keep the **arr + gluetun** workloads **unmeshed**:
  - They run in their own namespaces (e.g. `media`).
  - They use Services/Ingress like any other app.
  - Linkerd injection is disabled for these namespaces/pods.

Mesh is applied **selectively** to app stacks where:

- We want mTLS and golden signals (portfolio, APIs, Nextcloud, etc.).
- Sidecar proxies will not conflict with VPN/networking tricks.

---

## 9. How to Add New Platform Features or Apps

### 9.1 Adding a new platform feature (e.g., a new operator)

1. Create a new directory under `cluster/platform/`:
   - E.g. `cluster/platform/base/security/some-operator/`.
2. Add a `kustomization.yaml` and resources.
3. Create an ArgoCD `Application` under `cluster/platform/gitops/argocd/apps/` that points to this path.
4. Commit and push; ArgoCD will sync it.

### 9.2 Adding a new app

1. Pick a logical area (media/productivity/ai/web).
2. Create a directory under `cluster/apps/<area>/<app-name>/`:
   - Add `kustomization.yaml`, `deployment.yaml`, `service.yaml`, PVCs, HPA, PDB, etc.
3. Add a `HTTPRoute`/Ingress under `cluster/apps/shared/ingress/` (or keep it in the app directory if you prefer).
4. Add an ArgoCD `Application` under `cluster/platform/gitops/argocd/apps/` targeting the app directory.
5. If the app needs Postgres or Redis:
   - Use the platform clusters (external DB/Redis patterns in Helm values).
6. Commit + push; ArgoCD deploys the app.

---

## 10. Design Philosophy Summary

- **GitOps first**: the repo defines everything; ad‑hoc changes are avoided or later codified.
- **Clear separation of concerns**:
  - `platform` for shared infra, `apps` for workload-specific manifests.
- **Operators for complex infra**:
  - CloudNativePG and Redis operator for DB and cache, instead of ad‑hoc StatefulSets.
- **Selective complexity**:
  - Observability, service mesh, Ceph, and GitOps are powerful but add overhead.
  - They are applied thoughtfully (e.g., not forcing Linkerd into VPN-driven pods).
- **NAS + Ceph hybrid model**:
  - Ceph for important app state.
  - NAS for bulk media and backups.
- **Real-world practices**:
  - Gateway API, external-dns, cert-manager, ArgoCD, Kyverno, Linkerd – all common in modern platforms.
  - This homelab doubles as a learning and portfolio platform.

Armed with this document and the repo tree, an engineer should be able to:

- Recreate the base platform.
- Understand where to add or modify components.
- Keep the architecture coherent as the cluster evolves.
