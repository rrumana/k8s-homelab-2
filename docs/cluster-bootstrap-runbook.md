# Cluster Bootstrap and Platform Runbook

This document is a 0→1 guide for bringing up the new Kubernetes platform cluster from scratch, using the `k8s-homelab-2` repo layout.

It assumes:

- You are migrating from an existing k3s + Longhorn cluster.
- You will stand up a new kubeadm-based cluster first on a new node, then later fold in the existing machines.
- You want: Rook/Ceph for app PVCs, NAS for media + backups, Cilium, MetalLB, HAProxy (Gateway API), Linkerd, Prometheus/Grafana, Loki, Tempo, OpenTelemetry, Kyverno, external-secrets, Velero, and ArgoCD GitOps.

---

## 0. Design Decisions (Write These Down First)

Before touching the new node, record these choices in `docs/networking.md` and `docs/storage-layout.md`.

- Pod CIDR (CNI): e.g. `10.42.0.0/16`.
- Service CIDR: e.g. `10.43.0.0/16`.
- Kubernetes API endpoint: DNS + port, e.g. `k8s-api.lab.home:6443`.
- MetalLB IP range for this cluster (non-overlapping with old cluster).
- Public domain(s): `rcrumana.xyz`, plus which hostnames will be “new cluster first” (staging) vs “old cluster until cutover”.
- NAS layout: which datasets are “hot media” vs “cold backups”; how they will be exposed (NFS, S3).

---

## 1. OS Prep on the New Node

On the new node (future control-plane):

- Install Arch Linux as usual.
- Enable required kernel settings:
  - `br_netfilter` module.
  - `net.bridge.bridge-nf-call-iptables=1`, `net.ipv4.ip_forward=1`.
- Disable swap.
- Install container runtime (containerd).
- Install `kubeadm`, `kubelet`, `kubectl`.
- Set hostname and static IP.
- Ensure NTP/time sync is working.

Optional: document exact commands in `docs/os-prep.md`.

---

## 2. Bootstrap Kubernetes with kubeadm

Goal: single control-plane node, no workloads yet.

- Fill in `cluster/bootstrap/kubeadm-config.yaml` with:
  - `ClusterConfiguration`:
    - `kubernetesVersion`.
    - `networking.podSubnet` and `serviceSubnet`.
    - `controlPlaneEndpoint` = `k8s-api.lab.home:6443`.
  - `InitConfiguration`:
    - `nodeRegistration.criSocket` pointing at containerd.

- Run `kubeadm init` with that config on the new node.
- Configure `~/.kube/config` from `/etc/kubernetes/admin.conf`.
- Verify `kubectl get nodes` (node should be `NotReady` until CNI exists).

---

## 3. Install Cilium CNI

Goal: bring pod networking online with Cilium (eBPF, kube-proxy replacement).

- Decide Cilium options and record in `cluster/platform/base/networking/cilium/values.yaml`:
  - `kubeProxyReplacement` mode.
  - Routing mode (e.g. native).
  - Hubble settings.
  - IPAM mode.
- Install Cilium **manually** (one-time) using CLI or Helm with those values.
- Verify:
  - `kubectl get pods -n kube-system` → Cilium + core system pods running.
  - `kubectl get nodes` → node is `Ready`.
- Note the exact install command in `cluster/platform/base/networking/cilium/README.md`.

Later you can reconcile Cilium via Argo using the same values.

---

## 4. Bootstrap ArgoCD and Root Application

Goal: let GitOps drive everything beyond Cilium.

### 4.1 Install ArgoCD

- In `cluster/bootstrap/argocd/`:
  - `argocd-install.yaml` holds the ArgoCD install.
  - `kustomization.yaml` references it.
- Apply with `kubectl apply -k cluster/bootstrap/argocd`.
- Wait for `argocd` namespace pods to become Ready.

### 4.2 Root app-of-apps

- In `cluster/bootstrap/root-application/`, create `root-app.yaml` that:
  - Points to this repo (`k8s-homelab-2`).
  - Uses `path: cluster/platform`.
  - Targets `https://kubernetes.default.svc`.
  - Enables automated sync and `CreateNamespace=true`.
- Apply it with `kubectl apply -f ...`.
- ArgoCD will now see AppProjects and Applications under `cluster/platform/gitops/argocd/`.

---

## 5. Namespaces and Storage

### 5.1 Namespaces

Goal: define logical groupings (media, productivity, ai, web, monitoring, rook-ceph, linkerd, etc.).

- In `cluster/platform/base/namespaces/`, create Namespace manifests for each area.
- Add PodSecurity labels (`enforce=baseline` or `restricted`) on each namespace.
- Create an Argo Application in `cluster/platform/gitops/argocd/apps/` pointing here.
- Sync via Argo and verify namespaces exist.

### 5.2 Rook/Ceph for App PVCs

- In `cluster/platform/base/storage/rook-ceph/`, define:
  - Rook operator deployment.
  - `CephCluster` and OSD config (NVMe on nodes).
  - Pools and StorageClasses:
    - `ceph-block` (RBD, default for app PVCs).
- Add an Argo Application for Rook/Ceph and sync.
- Verify:
  - Ceph pods healthy; `kubectl get sc` shows `ceph-block`.
  - Ceph reports healthy status.

### 5.3 NAS Storage for Media and Backups

- In `cluster/platform/base/storage/nas/`, define:
  - `nas-media-hot` StorageClass (NFS to TrueNAS hot pool).
  - `nas-backup-cold` StorageClass (NFS or S3 to cold pool).
- Add an Argo Application and sync.
- Test by running a tiny Pod that mounts each SC and reads/writes a file.

---

## 6. Networking: MetalLB, external-dns, cert-manager, HAProxy

### 6.1 MetalLB

- In `cluster/platform/base/networking/metallb/`, define:
  - `IPAddressPool` with your reserved LB range.
  - `L2Advertisement`.
- Sync via Argo.
- Test with a temporary `LoadBalancer` service; ensure it gets an IP and responds.

### 6.2 external-dns

- In `cluster/platform/base/networking/external-dns/`, configure external-dns:
  - Provider: Cloudflare.
  - `domainFilters`: `rcrumana.xyz`.
  - Sources: `ingress` / `gateway` as desired.
- Initially, create the Cloudflare API token Secret manually; later replace with external-secrets.
- Sync via Argo.
- Test by creating a dummy Ingress/HTTPRoute annotated for DNS; confirm record appears in Cloudflare.

### 6.3 cert-manager

- In `cluster/platform/base/networking/cert-manager/`:
  - Install cert-manager.
  - Create a production `ClusterIssuer` for Let’s Encrypt using DNS-01 and Cloudflare.
  - Optional staging issuer.
- Sync via Argo.
- Test by creating a Certificate resource and verifying it becomes Ready.

### 6.4 HAProxy Gateway

- In `cluster/platform/ingress/haproxy-gateway/`:
  - Install HAProxy controller.
  - Define `GatewayClass` and `Gateway` (HTTP/HTTPS listeners, exposed by LoadBalancer).
- Sync via Argo.
- Create a simple HTTPRoute to a test service; verify:
  - DNS record exists.
  - TLS is valid.
  - Requests succeed via browser or curl.

---

## 7. Observability Stack

### 7.1 kube-prometheus-stack

- In `cluster/platform/observability/kube-prometheus-stack/`:
  - Define Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter.
- Sync via Argo into `monitoring` namespace.
- Expose Grafana via Gateway or port-forward.
- Import basic dashboards and confirm cluster metrics (nodes, pods, etc.) appear.

### 7.2 Loki

- In `cluster/platform/observability/loki/`:
  - Deploy Loki.
  - Deploy log shippers (Promtail/Vector) as DaemonSets.
- Sync via Argo.
- Configure Grafana data source for Loki and confirm logs from at least one namespace.

### 7.3 Tempo and OpenTelemetry Collector

- In `cluster/platform/observability/tempo/`:
  - Deploy Tempo, backed by Ceph or NAS as desired.
- In `cluster/platform/observability/opentelemetry-collector/`:
  - Deploy OTel collector with OTLP receivers and exporters to Tempo (traces) and Prometheus (metrics).
- Sync via Argo.
- Later, instrument services or rely on Linkerd to generate traces.

---

## 8. Service Mesh: Linkerd

This repo installs Linkerd with:

- Linkerd CNI (`linkerd2-cni`) so meshed workloads can stay under PodSecurity `restricted` (no `NET_ADMIN` init container).
- cert-manager-managed identity issuer certs (no private keys in Git).

### 8.1 Generate and apply the trust anchor (one-time, out-of-band)

- Run `scripts/linkerd/generate-trust-anchor.sh`.
- Apply the generated Secret manifest under `secrets/linkerd/`:
  - `kubectl apply -f secrets/linkerd/linkerd-trust-anchor-secret.yaml`
- Copy the printed trust-anchor *public* certificate PEM into:
  - `cluster/platform/service-mesh/linkerd/control-plane/values.yaml` (`identityTrustAnchorsPEM`)

### 8.2 Sync Linkerd via ArgoCD

- Sync Argo Applications (in order):
  - `linkerd-crds`
  - `linkerd2-cni`
  - `linkerd-identity` (creates `linkerd-identity-issuer` via cert-manager)
  - `linkerd-control-plane`
  - `linkerd-viz`

### 8.3 Mesh a test namespace first

- Create a dedicated namespace (e.g. `mesh-test`) and add:
  - `linkerd.io/inject: enabled`
- Deploy a small echo service and validate:
  - `linkerd check`
  - Viz UI shows traffic + mTLS

### Troubleshooting: `linkerd-network-validator` init failures

If Linkerd control-plane pods fail during init with logs like:
`Failed to validate networking configuration ... ensure iptables rules are rewriting traffic`
it usually means the Linkerd CNI plugin is not being invoked for pods (i.e. the
CNI chain was not installed on the node).

Run:

- `scripts/linkerd/verify-cni.sh service-mesh`

Things to look for:

- `/etc/cni/net.d` contains a `*.conflist` (or `*.conf`) that includes `"type": "linkerd-cni"`.
- `/opt/cni/bin/linkerd-cni` exists on the node (the script checks via hostPath mounts).

If those are missing, adjust `cluster/platform/service-mesh/linkerd/cni/values.yaml`
to match your kubelet CNI paths, then re-sync `linkerd2-cni`.

If `linkerd2-cni` reports it installed/updated `05-cilium.conflist` but that file
does not actually contain `"type": "linkerd-cni"`, Cilium may be overwriting the
CNI config on restart/upgrade.

Recommended Cilium setting for Linkerd CNI:

- Set `cni.customConf: true` in your Cilium Helm release so Cilium stops rewriting
  `/etc/cni/net.d/05-cilium.conflist`.

After updating Cilium:

- Re-sync `linkerd2-cni` (or restart its DaemonSet pods) so it can patch the
  conflist again.


---

## 9. Security Baseline

### 9.1 PodSecurity

- In `cluster/platform/base/security/pod-security/`, define PodSecurity settings:
  - Labels for each namespace indicating `enforce` level (`baseline`, `restricted`, etc.).
- Sync via Argo.
- Ensure namespaces that host “weird” apps (e.g. Homarr requiring root) either:
  - Have a different enforcement level, or
  - Are excluded via labels in policy engines.

### 9.2 Kyverno

- In `cluster/platform/base/security/kyverno/`:
  - Deploy Kyverno via Argo.
  - Add initial **audit-only** policies:
    - Disallow `:latest`.
    - Require resource requests/limits.
    - Require non-root containers, with namespace/label-based exceptions for unavoidable cases.
- Validate by deploying a known bad pod and checking Kyverno’s reports.
- When comfortable, set selected rules to Enforce.

### 9.3 external-secrets

- In `cluster/platform/base/security/external-secrets/`:
  - Deploy external-secrets operator.
  - Define `ClusterSecretStore` pointing at Vault, TrueNAS S3, or other backend.
  - Migrate a low-risk secret using `ExternalSecret`.
- Sync via Argo and confirm the corresponding Kubernetes Secret is created automatically.

### 9.4 Descheduler

- In `cluster/platform/scheduling/descheduler/`:
  - Deploy descheduler via Argo with conservative policies (e.g. clean up duplicates, respect evictable pods).
- Confirm it runs and logs activity without causing chaos.

---

## 10. Backup & DR: Velero

- In `cluster/platform/backup/velero/`:
  - Deploy Velero via Argo.
  - Configure BackupStorageLocation:
    - TrueNAS S3 endpoint **or** NFS-backed restic repo on the cold pool.
  - Configure VolumeSnapshotLocation for Ceph CSI if using snapshots.
- Test:
  - Create a small test namespace with an app + PVC.
  - Run a Velero backup for that namespace.
  - Delete the namespace.
  - Restore from backup and confirm app and data return.

---

## 11. Onboarding Applications

Pattern: one Application per app stack, manifests grouped by app.

- Under `cluster/apps/**`, keep each stack mostly self-contained:
  - Deployments/StatefulSets.
  - Services.
  - PVCs (using `ceph-block` or NAS SCs).
  - ConfigMaps/Secrets (or ExternalSecrets).
  - Ingress/HTTPRoutes.
- Use Kustomize in each app directory and set `namespace` to the appropriate logical namespace (`media`, `productivity`, `ai`, `web`).
- In `cluster/platform/gitops/argocd/apps/`, create Argo Applications pointing at each app directory.

Suggested onboarding order for safety:

1. Low-risk/staging apps (e.g. `uptime-kuma`, `portfolio/staging`).
2. Medium complexity (media stack, `arr`, `jellyfin`, etc.).
3. High-value stateful apps (`nextcloud`, `immich`, `vaultwarden`, `unifi-controller`).

For each app:

- Let Argo sync.
- Confirm PVCs are bound correctly (Ceph vs NAS).
- Confirm it’s reachable via HAProxy + DNS + TLS.
- Check logs and metrics for obvious errors.

---

## 12. Validation Checklist

After everything is up, run through this:

- **Cluster health:**
  - `kubectl get nodes` → all `Ready`.
  - `kubectl get pods -A` → no critical system pods crashlooping.
- **Networking:**
  - Cilium healthy (`cilium status`).
  - MetalLB allocates IPs.
  - HAProxy Gateway serves at least one HTTPRoute.
- **Storage:**
  - Ceph `HEALTH_OK` (or close).
  - PVCs using `ceph-block` and NAS SCs work (read/write test).
- **Observability:**
  - Grafana shows node and cluster metrics.
  - Loki has logs from multiple namespaces.
  - Tempo contains at least some traces (via Linkerd or app instrumentation).
- **Service mesh:**
  - Linkerd Viz shows traffic for at least one injected namespace.
- **Security:**
  - PodSecurity enforces expected levels.
  - Kyverno reports/blocks bad configs while allowing documented exceptions.
  - external-secrets successfully syncs at least one secret.
- **Backups:**
  - Velero backup and restore tested successfully for a small namespace.
- **Apps:**
  - Each deployed app responds on its expected hostname with valid TLS.
  - Basic workflows (login, upload, play media, etc.) work.

This runbook, plus the directory structure in `k8s-homelab-2`, should be enough for Future You to rebuild the platform from bare OS to a fully functional, GitOps-driven, observable, and secure cluster.
