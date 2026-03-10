# k8s-homelab-2 long-term implementation brief

## Scope and note on repo access

This file turns the earlier research into an implementation brief for an agent such as GPT-5.3-codex. It is tailored to the cluster profile you shared, your long-term goals, and the repo context that was visible from this workspace. I could confirm the repo identity (`rrumana/k8s-homelab-2`) from the connected-source context, but I could not fully crawl the GitHub manifests from this workspace. Because of that, this should be treated as:

- a repo-aligned implementation brief,
- a set of idiomatic Kubernetes defaults to apply across the repo, and
- a prioritized backlog for making the cluster more visible, more consistent, and easier to operate for years.

It is **not** a line-by-line manifest audit.

## Executive summary

Your cluster should evolve in this order:

1. **Standardize GitOps and ordering** around Argo CD as the control plane for the repo.
2. **Standardize traffic** around Gateway API instead of carrying multiple overlapping ingress patterns.
3. **Standardize observability** around metrics, logs, and traces that join together in Grafana.
4. **Harden storage conventions** so Ceph is used intentionally, not just successfully.
5. **Operationalize right-sizing and autoscaling** with VPA, Goldilocks, HPA, and KEDA.
6. **Spend idle CPU on useful automation** such as GitHub runner scale sets and batch workflows.
7. **Add a small number of high-leverage platform services**, not a random zoo of self-hosted apps.

The high-level target state is:

- **Argo CD + ApplicationSet + Notifications** for GitOps control
- **Gateway API** as the north-south traffic API
- **One service mesh story** instead of a half-used one
- **Prometheus + Grafana + Loki + Tempo + OpenTelemetry** for visibility
- **Rook Ceph** with explicit storage classes and backup/snapshot policy
- **VPA Off/Initial + Goldilocks** for rightsizing
- **HPA/KEDA** for horizontal scaling
- **Actions Runner Controller + Argo Workflows/Events** for compute utilization
- **No KubeRay for now**

## Architecture decisions to lock in

### 1) GitOps control plane

Use **Argo CD** as the source of truth for cluster deployment structure.

Keep and strengthen:

- Argo CD core controllers
- Argo CD sync waves and hooks for ordering
- App grouping by platform domain, not by random installation history

Add:

- **ApplicationSet** for repetitive app generation
- **Argo CD Notifications** for sync failures, drift, health regressions, and rollout events
- **Argo Rollouts** for progressive delivery on user-facing services
- **Argo Workflows** for batch jobs and build/test pipelines
- **Argo Events** only where event-driven automation is actually useful

### 2) Traffic model

Move to **Gateway API** as the default north-south interface.

Guideline:

- choose **one** Gateway API implementation,
- make that the long-term front door,
- and avoid running multiple ingress/gateway stacks in parallel for any longer than the migration requires.

If your current mesh is **Cilium-based**, the most natural move is:

- Cilium Gateway API
- Hubble Relay
- Hubble UI
- Cilium-native mesh visibility

If it is **not** Cilium-based, still converge on Gateway API for north-south traffic and keep only the mesh features that produce operational value.

### 3) Telemetry model

Standardize around a joined-up telemetry stack:

- **Metrics**: Prometheus
- **Dashboards**: Grafana
- **Logs**: Loki
- **Traces**: Tempo
- **Collection / routing**: OpenTelemetry Collector and/or Grafana Alloy

Important simplification:

- do **not** build a stack where logs, metrics, traces, service mesh data, and GitOps health each use a different operational pattern.
- pick one coherent telemetry path and use it everywhere.

### 4) Storage model

Keep **Rook Ceph**, but make the storage contract explicit:

- **Ceph RBD** for RWO volumes and single-writer stateful workloads
- **CephFS** for RWX/shared files where the application actually benefits from shared filesystem semantics
- **NFS** for cold data, large media, and low-performance backup-style storage
- **Snapshots and restore policy** as first-class repo objects, not ad hoc ops knowledge

### 5) Scaling model

Use these roles consistently:

- **VPA Off** or **Initial** for learning and rightsizing
- **Goldilocks** to surface VPA recommendations visually
- **HPA** for stateless and horizontally scalable workloads
- **KEDA** for event-driven, queue-based, cron-based, and job-like workloads

### 6) Compute model

Use spare CPU for things that increase cluster value:

- **Actions Runner Controller** for GitHub Actions runner scale sets
- **Argo Workflows** for builds, tests, static-site generation, data jobs, OCR, transcription, and indexing
- **KEDA** where job volume is event-driven
- **Small CPU-first ML / inference / embedding jobs** only after observability and scheduling are mature

Do **not** spend operational budget on KubeRay right now.

## Distilled findings

### What to keep

These are strong choices and should remain part of the design direction.

- **Three control-plane nodes**: good basis for long-term control plane availability.
- **GitOps mindset**: exactly the right posture for a cluster you want to run for years.
- **Rook Ceph on local NVMe**: strong fit for replicated, on-cluster storage when managed intentionally.
- **Centralizing PostgreSQL and Redis**: this makes many application pods easier to convert into stateless frontends.
- **Spare CPU capacity**: this is an opportunity, not waste, if you turn it into automation and batch throughput.
- **Desire to converge on Gateway API**: this is the right direction.
- **Desire to actually use the service mesh data**: also the right direction.

### What is acceptable but should mature

These choices are workable, but should be made more systematic.

- **All-control-plane cluster with shared responsibilities**: acceptable for a homelab, but it needs stronger prioritization, observability, and disruption discipline.
- **Mixed storage tiers (Ceph + NFS)**: good in principle, but only if every workload has a deliberate storage-class choice.
- **Using VPA mainly for recommendations**: sensible, but needs a formal workflow around adoption.
- **Existing service mesh without clear dashboards or routing ownership**: acceptable while learning, but not a good long-term steady state.

### What should change

These are the most important changes to make.

- **Visibility is too fragmented**. You need one joined-up observability stack.
- **Traffic should converge on Gateway API**. Stop carrying multiple north-south patterns long-term.
- **Service mesh must justify itself**. If it stays, it should produce real dashboards, policy value, and traffic insights.
- **Storage choices need a policy**. Ceph should not be the default answer to every persistence problem.
- **Autoscaling needs a tiered model**. Right now VPA insight exists, but the HPA/KEDA adoption model needs to be made explicit.
- **Idle CPU should be monetized operationally**. Use it to eliminate manual work and accelerate builds, indexing, and background jobs.

## Recommended platform services and pods

| Domain | Recommended service / controller | Why it fits this cluster | Guidance |
|---|---|---|---|
| GitOps | `argocd-server`, `argocd-repo-server`, `argocd-application-controller` | Core GitOps control plane | Keep as the cluster source of truth |
| GitOps | `argocd-applicationset-controller` | Reduces repetitive application definitions | Use for grouped apps, environment overlays, and generated app sets |
| GitOps | `argocd-notifications-controller` | Makes failures and drift visible | Wire to Slack / email / webhook |
| Delivery | `argo-rollouts` | Progressive delivery and safe rollout analysis | Use for external/user-facing apps first |
| Delivery | `workflow-controller`, `argo-server` | Batch automation and CI-style jobs | Use for builds, tests, OCR, indexing, backups, and one-shot ops |
| Delivery | `argo-events` controllers and EventBus | Event-driven triggers | Add only where it simplifies actual workflows |
| Networking | Gateway API CRDs + one Gateway controller | Converged traffic model | Prefer your mesh-native option if it is good enough |
| Mesh visibility | `hubble-relay`, `hubble-ui` (if on Cilium) | Immediate value from the mesh you already have | Strongest fit if the current networking stack is Cilium |
| Observability | `prometheus-operator`, `prometheus`, `alertmanager`, `grafana`, `kube-state-metrics`, `node-exporter` | Standard metrics foundation | `kube-prometheus-stack` is the practical default |
| Observability | OpenTelemetry Operator and `OpenTelemetryCollector` | Vendor-neutral telemetry collection and routing | Use DS + gateway pattern |
| Logging | `loki` | Kubernetes-native log store that works well with Grafana | Start simple, keep retention and labels disciplined |
| Logging | **Grafana Alloy** | Log collection path that avoids Promtail deprecation | Prefer Alloy over new Promtail installs |
| Tracing | `tempo` | Trace backend that correlates with logs and metrics | Add after metrics and logs are in place |
| Rightsizing | `goldilocks` | Makes VPA recommendations usable | Great fit for your current VPA workflow |
| Blackbox visibility | `blackbox-exporter` and/or `gatus` | External health and route validation | Useful for Gateway and TLS coverage |
| Storage | Rook Ceph dashboard, toolbox, ServiceMonitors | Makes Ceph observable and operable | Keep toolbox version aligned during upgrades |
| Storage | CSI `VolumeSnapshotClass` resources | Safer backup/restore workflows | Define snapshots as part of the platform |
| Backup / DR | `volsync` and/or `velero` | Restores confidence and repeatability | Use one clear backup story per data class |
| Autoscaling | HPA, VPA, KEDA | Covers resource, replica, and event scaling | Use each for the right workload type |
| Policy | `kyverno` | Enforces cluster consistency without custom admission code | Good long-term guardrails |
| Compute | Actions Runner Controller | Turns idle CPU into CI throughput | High-value first compute add |
| Optional storage expansion | Ceph ObjectStore / RGW | Gives you S3 semantics and can back other services | Good future fit for observability object storage and backups |

## Idiomatic Kubernetes defaults to codify in the repo

These are the repo-wide defaults an implementation agent should enforce.

### Cluster-wide repo conventions

1. Group apps by **platform domain**:
   - `platform/gitops`
   - `platform/networking`
   - `platform/observability`
   - `platform/storage`
   - `platform/data`
   - `platform/security`
   - `apps/...`
   - `compute/...`

2. Use **Argo sync waves** to order installation:
   - CRDs and operators first
   - namespaces / RBAC / secrets plumbing next
   - platform data plane next
   - apps last

3. Every namespace should have an explicit stance on:
   - network policy
   - rightsizing / autoscaling
   - backup / snapshot needs
   - observability onboarding

4. Prefer **one app = one clear owner directory** instead of diffusing its manifests across multiple unrelated folders.

5. Avoid manifest ambiguity:
   - explicit storage class
   - explicit ingress / route ownership
   - explicit resource policy
   - explicit labels and annotations for operations

### Per-workload defaults

For every application workload, codify the following unless there is a good reason not to:

- `resources.requests`
- `livenessProbe`, `readinessProbe`, and often `startupProbe`
- `topologySpreadConstraints` for HA-capable workloads
- `podAntiAffinity` or spread, not random placement
- `PodDisruptionBudget` when replicas > 1
- `ServiceMonitor` for workloads that export useful metrics
- `NetworkPolicy` for anything sensitive or externally reachable
- `priorityClassName` for platform-critical services
- `persistentVolumeClaimRetentionPolicy` / snapshot / backup decisions for stateful apps
- route resources via **Gateway API**, not one-off ingress styles

### Workload-type patterns

#### Stateless user-facing services

Use:

- `Deployment`
- HPA
- PDB
- topology spread
- Argo Rollouts if user-facing
- Gateway `HTTPRoute` / `GRPCRoute`
- Prometheus metrics and Tempo traces

#### Stateful single-writer services

Use:

- `StatefulSet`
- Ceph **RBD**
- VPA recommendation mode or Initial mode
- backup / snapshot policy
- no HPA unless the app explicitly supports horizontal scale

#### Shared-content / RWX services

Use:

- Ceph **CephFS** only when the app benefits from RWX
- do not default to CephFS for databases or queue backends

#### Platform controllers and operators

Use:

- fixed replica counts or very conservative scaling
- PDBs where appropriate
- priority classes
- monitoring first
- no HPA unless the controller is known to benefit from it

## Observability target state

## What enterprise clusters are doing

At a high level, mature clusters converge on the same shape:

- **Prometheus-compatible metrics**
- **centralized logs**
- **distributed traces**
- **OpenTelemetry collection and enrichment**
- **Grafana-style cross-linking** between logs, metrics, and traces
- **service mesh / gateway telemetry** fed into the same dashboards

Your cluster does not need enterprise scale, but it should absolutely adopt the same **shape**.

## What to add that synergizes with this cluster

### Core stack

1. **kube-prometheus-stack**
   - cluster metrics
   - node metrics
   - kube-state metrics
   - Alertmanager
   - Grafana

2. **OpenTelemetry Operator + Collector**
   - DaemonSet collectors for node / pod-local collection
   - gateway collector for central routing, processing, and export

3. **Loki + Grafana Alloy**
   - centralized pod logs
   - Kubernetes events
   - structured label strategy

4. **Tempo**
   - trace storage
   - trace correlation with logs and metrics

5. **Mesh-native visibility**
   - if Cilium: Hubble Relay + UI
   - expose mesh metrics into Prometheus

6. **Argo CD / Rollouts dashboards**
   - GitOps health
   - sync failures
   - canary outcomes
   - rollout analysis results

### Logging and correlation guidance

- logs should carry **namespace, app, pod, container, node, cluster, route/service** labels
- traces should carry **service.name**, **namespace**, **route**, **error status**, and **deployment version**
- metrics should expose app RED signals:
  - rate
  - errors
  - duration

### Important log collector choice

Do **not** invest in fresh Promtail-centric design now.

Prefer:

- **Grafana Alloy** for Loki-oriented log collection
- **OpenTelemetry Collector** for metrics and traces

If you want the simplest single-agent story, you can standardize more heavily on Alloy. If you want clearer vendor-neutral boundaries, use OpenTelemetry Collector for metrics/traces and Alloy primarily for logs.

## Custom visuals to build in Grafana

Build these dashboards first.

### 1) Cluster operations overview

Show:

- node CPU / memory / disk / network
- pod restarts
- evictions
- API server and etcd health if available
- cluster saturation and noisy namespaces

### 2) GitOps control-plane dashboard

Show:

- Argo app sync status
- unhealthy applications
- drift count
- failed syncs over time
- notification / webhook failures

### 3) Ceph storage dashboard

Show:

- cluster health
- mon quorum
- OSD up/in status
- PG health
- read / write throughput
- latency
- capacity by pool
- snapshot / backup status

### 4) Gateway / mesh dashboard

Show:

- request volume by route
- 4xx / 5xx by route and service
- p50 / p95 / p99 latency
- source -> destination service graph
- TLS error rate
- policy drops / denied flows if the mesh supports it

### 5) App RED dashboard per namespace

For each major app namespace show:

- request rate
- error rate
- duration percentiles
- top noisy pods
- log error search links
- trace links for slow requests

### 6) Rightsizing and autoscaling dashboard

Show:

- current requests and limits
- VPA target / lower / upper recommendations
- HPA current replicas vs desired replicas
- HPA scaling events
- workloads with no requests / limits
- workloads with consistently low utilization

### 7) Compute / CI dashboard

Show:

- ARC runner count
- queued jobs
- busy vs idle runners
- workflow success/failure duration
- build pod CPU consumption
- top namespaces by background compute usage

## Rook Ceph guidance for this cluster

Ceph is worth keeping, but it needs explicit operational rules.

### The correct mental model

Ceph should be treated as a **cluster storage platform**, not a magic persistence layer.

That means:

- define which workloads belong on RBD
- define which workloads belong on CephFS
- define what stays on NFS
- define what must be backed up independently of Ceph health

### What an agent should verify in the repo

1. **CephCluster basics**
   - 3 mons across 3 hosts
   - dashboard enabled
   - monitoring enabled
   - toolbox available
   - health and disruption settings present

2. **Block pools and filesystems**
   - `failureDomain: host`
   - replicated size aligned with the 3-host topology
   - separate RBD and CephFS storage classes with meaningful names

3. **Storage-class usage**
   - databases use **RBD**, not CephFS
   - RWX apps use **CephFS** only when RWX is really needed
   - backups / cold data do not consume expensive Ceph patterns unnecessarily

4. **Operational safety**
   - snapshots defined where supported
   - backup and restore workflows tested
   - monitoring is **not solely dependent on Ceph**

### Specific recommendations

- Keep **Prometheus / core observability state off Ceph** when possible. If Ceph is the thing failing, you do not want your primary storage observability stack to disappear with it.
- If your kernel and topology support it, consider **Ceph CSI read affinity** to better align local reads with node locality.
- Expose and actually use the **Ceph dashboard**, **toolbox**, and **ServiceMonitors**.
- If you introduce object-backed services later, **Ceph ObjectStore / RGW** is a sensible expansion because it compounds the value of your current storage platform.
- When PostgreSQL and Redis move toward their own HA modes, make a conscious decision about **where replication lives**. Do not accidentally stack application-level replication on top of Ceph replication without understanding the tradeoffs.

## VPA / HPA / KEDA guidance

## Patterns to use

### VPA pattern

Use VPA in a disciplined progression:

1. **Off mode** almost everywhere first
2. surface recommendations with **Goldilocks**
3. move selected workloads to **Initial**
4. only use **Recreate** or **InPlaceOrRecreate** where eviction behavior is acceptable

Good uses for VPA:

- controllers
- platform services
- singleton stateful apps
- databases that should be right-sized but not horizontally scaled
- anything where memory sizing is the real issue

### HPA pattern

Use HPA for workloads that get better by adding replicas.

Good HPA candidates:

- stateless web frontends
- APIs
- worker deployments
- queue consumers
- GitHub runner scale sets
- horizontally scalable internal services

When HPA owns replica count, the repo should treat HPA as authoritative.

That means:

- avoid letting GitOps continuously force a fixed `spec.replicas` on HPA-managed workloads
- use HPA behavior tuning to avoid flapping
- ensure probes reflect real readiness so HPA metrics are meaningful

### KEDA pattern

Use KEDA where demand is event-driven instead of CPU-driven.

Best fits here:

- queue consumers
- scheduled jobs
- bursty background workers
- GitHub runner scaling if you choose that pattern
- job-oriented automation

## What is HPA compatible and what is not

### Strong HPA candidates

- `Deployment`-based stateless services
- some `StatefulSet` workloads that are truly horizontally aware
- queue workers and pull-based consumers
- ARC runner scale sets / ephemeral runners

### Poor HPA candidates

- `DaemonSet` workloads
- Ceph daemons
- single-writer databases
- Redis primaries / stateful caches that do not horizontally scale the way HPA assumes
- singleton apps with local writable state
- workloads whose bottleneck is external I/O rather than pod count

## What changes as the cluster moves toward HA

The following workload classes usually need adjustment:

- apps that still assume **one writable pod**
- apps that store local state in a way that blocks replica growth
- apps missing PDBs, spread constraints, and anti-affinity
- apps whose health probes are too weak to support HPA or Rollouts
- apps exposed externally without a clean route abstraction

## Has centralized PostgreSQL and Redis helped?

Yes. In general it makes HA easier for many application tiers because:

- frontends can become stateless
- replicas no longer need embedded databases
- rollout and HPA adoption become more practical
- backup scope becomes clearer

The caveat is that the central data layer must now be treated as platform infrastructure, with stricter backup, failover, and performance discipline.

## Compute utilization plan

### Clustered compute solutions that fit this cluster

#### 1) Actions Runner Controller

This is the most obvious high-value use of spare CPU.

Use it for:

- container builds
- static-site rebuilds
- test pipelines
- release packaging
- image signing / scanning jobs

#### 2) Argo Workflows

This is the second most valuable compute investment.

Use it for:

- periodic site builds
- ETL / indexing jobs
- OCR / transcription pipelines
- backup verification jobs
- synthetic test workloads
- one-shot migration jobs

#### 3) KEDA-backed workers

Use for:

- queue-driven workloads
- webhook-triggered jobs
- bursty background processing

### Good ways to spend idle cores

Practical homelab / platform uses:

- CI builds
- container image builds
- static site generation
- media processing
- OCR and document indexing
- embeddings and search indexing
- transcription jobs
- backup compression and validation
- canary / load-test jobs in non-prod windows

### Inference / development workflows worth considering

Only after observability is in place:

- CPU-first embeddings pipelines
- small-model summarization or document enrichment
- local transcription
- code search / symbol indexing
- nightly batch jobs that enrich your own data or docs

Keep this rule:

- **automate useful work first**
- **experimental inference second**

## Worthwhile additions beyond the core plan

These are the next additions most likely to pay off.

### Highest-value additions

1. **Actions Runner Controller**
   - immediate utilization win
   - directly supports your GitHub-centric workflow

2. **Goldilocks**
   - immediate VPA quality-of-life win
   - low operational cost

3. **Kyverno**
   - raises cluster consistency over time
   - excellent for a long-lived cluster

4. **Blackbox exporter and/or Gatus**
   - validates routes, TLS, and public reachability from the outside

5. **Ceph ObjectStore / RGW**
   - useful learning path and practical object storage backend

6. **Argo Workflows + Argo Events**
   - turns spare compute into automation instead of curiosity

### Useful but not urgent

- **Authentik or Zitadel** for cluster-wide SSO patterns
- **Backstage** if you specifically want to learn internal platform / IDP concepts
- **Policy/reporting tools** like Polaris / Pluto if you want extra repo hygiene automation

## Ordered implementation backlog for an agent

This is the concrete backlog GPT-5.3-codex should work through.

### Phase 0 - establish repo standards

1. Inventory namespaces and workloads into these groups:
   - gitops
   - networking
   - observability
   - storage
   - data
   - security
   - apps
   - compute
2. Add or normalize Argo CD app definitions so platform components are grouped by domain.
3. Add sync waves so CRDs/operators install before dependents.
4. Add a repo-wide workload standard document covering probes, resources, storage choice, route choice, PDBs, spread, monitoring, and backup policy.

**Definition of done**: the repo has a visible platform structure and ordering model.

### Phase 1 - converge on Gateway API

1. Add Gateway API CRDs and your chosen controller.
2. Create one reference migration from an existing ingress to `HTTPRoute`.
3. Migrate external-facing apps incrementally.
4. Remove long-term duplicate ingress paths after cutover.
5. If the current mesh is Cilium, expose Hubble and wire its metrics into Prometheus.

**Definition of done**: Gateway API is the default front door for new work.

### Phase 2 - build the observability spine

1. Install or normalize `kube-prometheus-stack`.
2. Add OpenTelemetry Operator and collectors.
3. Install Loki.
4. Use **Grafana Alloy**, not fresh Promtail, for log collection.
5. Install Tempo.
6. Add ServiceMonitors / PodMonitors for platform services.
7. Wire mesh / gateway telemetry into the same Grafana instance.
8. Create the seven baseline dashboards listed above.

**Definition of done**: logs, metrics, and traces are correlated in Grafana.

### Phase 3 - harden Rook Ceph usage

1. Review `CephCluster`, `CephBlockPool`, `CephFilesystem`, and StorageClass manifests.
2. Ensure RBD and CephFS are both explicit and intentionally consumed.
3. Enable / validate dashboard, toolbox, and monitoring integration.
4. Add snapshot classes and documented restore flows.
5. Ensure observability state is not critically coupled to Ceph.
6. Add repo documentation that maps workload types to storage classes.

**Definition of done**: every stateful workload has a justified storage class and restore path.

### Phase 4 - operationalize rightsizing and autoscaling

1. Install Goldilocks.
2. Label target namespaces for recommendation coverage.
3. Normalize VPA to `Off` or `Initial` by workload class.
4. Add HPAs to stateless external and internal services that scale horizontally.
5. Remove fixed `spec.replicas` from HPA-authoritative manifests where appropriate.
6. Add KEDA only for queue, cron, or event-driven workloads.
7. Add dashboards for VPA recommendations and HPA activity.

**Definition of done**: scaling rules are explicit and workload-appropriate.

### Phase 5 - turn spare CPU into platform value

1. Install Actions Runner Controller and create runner scale sets.
2. Build one GitHub workflow that compiles, tests, and publishes a container image using cluster runners.
3. Add Argo Workflows for one real batch workload:
   - website build/redeploy
   - document OCR/indexing
   - transcription
   - backup verification
4. Add cost/usage dashboards for runner and workflow CPU consumption.

**Definition of done**: spare CPU is consumed by useful automation, not just experiments.

### Phase 6 - add long-term guardrails

1. Add Kyverno policies for:
   - missing requests / limits
   - missing probes
   - missing PDBs on HA services
   - missing spread / anti-affinity on multi-replica workloads
   - missing NetworkPolicies in protected namespaces
2. Add blackbox / external route checks.
3. Add notifications for Argo failures, route failures, Ceph health, and storage capacity.
4. Document standard app patterns in the repo so future additions follow the same shape.

**Definition of done**: consistency is enforced instead of remembered.

## Short version for GPT-5.3-codex

Implement the repo in this priority order:

1. Normalize Argo structure and sync waves.
2. Make Gateway API the default traffic API.
3. Install kube-prometheus-stack.
4. Install OpenTelemetry collectors.
5. Install Loki with Grafana Alloy for logs.
6. Install Tempo for traces.
7. Build Grafana dashboards for cluster, Ceph, Argo, mesh, RED, autoscaling, and runners.
8. Review and harden Rook Ceph storage classes, snapshots, dashboard, toolbox, and monitoring.
9. Install Goldilocks and formalize VPA recommendation workflow.
10. Add HPAs to stateless workloads and KEDA only where event-driven.
11. Install Actions Runner Controller.
12. Add Argo Workflows / Events for practical automation.
13. Add Kyverno and blackbox monitoring as long-term consistency guardrails.

## Selected references

These are the sources that most strongly support the recommendations above.

1. Kubernetes Gateway API docs and release repo - current Gateway API status and supported resources.  
   https://github.com/kubernetes-sigs/gateway-api

2. Cilium Gateway API support - useful if your mesh/network stack is Cilium.  
   https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api.html

3. Cilium GAMMA / mesh routing docs - relevant if you want to get more out of the service mesh.  
   https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gamma.html

4. OpenTelemetry Collector on Kubernetes - DS + gateway collection pattern.  
   https://opentelemetry.io/docs/collector/install/kubernetes/

5. OpenTelemetry Collector Helm chart docs - deployment patterns for Kubernetes.  
   https://opentelemetry.io/docs/platforms/kubernetes/helm/collector/

6. OpenTelemetry Operator for Kubernetes - operator-driven collector and instrumentation management.  
   https://opentelemetry.io/docs/kubernetes/operator/

7. Grafana Loki Kubernetes monitoring tutorial - Loki for Kubernetes logs.  
   https://grafana.com/docs/loki/latest/send-data/k8s-monitoring-helm/

8. Grafana Loki release notes and Promtail docs - Promtail deprecation and Alloy direction.  
   https://grafana.com/docs/loki/latest/release-notes/v3-6/  
   https://grafana.com/docs/loki/latest/send-data/promtail/configuration/

9. Grafana Tempo docs - trace storage and correlation model.  
   https://grafana.com/docs/tempo/latest/  
   https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/kubernetes/

10. Kubernetes HPA docs - workload compatibility, replica authority, and scaling behavior.  
    https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/

11. Kubernetes VPA docs - stable API, modes, and behavior.  
    https://kubernetes.io/docs/concepts/workloads/autoscaling/vertical-pod-autoscale/

12. KEDA concepts - event-driven autoscaling patterns.  
    https://keda.sh/docs/2.15/concepts/

13. Goldilocks docs - VPA recommendation visualization and namespace onboarding model.  
    https://goldilocks.docs.fairwinds.com/

14. Rook host cluster docs - host-based Ceph cluster patterns.  
    https://rook.io/docs/rook/latest-release/CRDs/Cluster/host-cluster/

15. Rook block pool docs - `failureDomain: host` and replicated size guidance.  
    https://rook.io/docs/rook/v1.16/CRDs/Block-Storage/ceph-block-pool-crd/

16. Rook Ceph filesystem docs - CephFS pool guidance.  
    https://rook.io/docs/rook/latest-release/CRDs/Shared-Filesystem/ceph-filesystem-crd/

17. Rook Ceph CSI docs - RBD vs CephFS roles and read affinity.  
    https://www.rook.io/docs/rook/latest-release/Storage-Configuration/Ceph-CSI/ceph-csi-drivers/

18. Rook snapshot docs - volume snapshot patterns.  
    https://rook.io/docs/rook/latest-release/Storage-Configuration/Ceph-CSI/ceph-csi-snapshot/

19. Rook monitoring and dashboard docs - operational visibility for Ceph.  
    https://rook.io/docs/rook/latest/Storage-Configuration/Monitoring/ceph-dashboard/  
    https://rook.io/docs/rook/v1.14/Troubleshooting/ceph-toolbox/

20. Argo CD notifications and sync wave docs - GitOps ordering and alerts.  
    https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/  
    https://argo-cd.readthedocs.io/en/latest/user-guide/sync-waves/

21. Argo Rollouts analysis docs - Prometheus-backed rollout analysis.  
    https://argo-rollouts.readthedocs.io/en/stable/features/analysis/  
    https://argo-rollouts.readthedocs.io/en/stable/analysis/prometheus/

22. GitHub Actions Runner Controller docs - runner scale sets and autoscaling runners on Kubernetes.  
    https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/deploy-runner-scale-sets  
    https://docs.github.com/en/actions/concepts/runners/runner-scale-sets
