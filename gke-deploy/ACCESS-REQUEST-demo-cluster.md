# Access request — `demo-cluster` RBAC for the AEGIS demo

**To:** aayyagari@griddynamics.com (holds `roles/container.admin`)
**From:** rsarkar@griddynamics.com
**Cluster:** `demo-cluster`, zone `us-central1-a`, project `gd-gcp-presales-india-auto-sre`
**Scope:** two ClusterRoles + two ClusterRoleBindings, all read-only. Nothing outside `demo-cluster`.
**Time needed:** about 5 minutes.

---

## 1. Why this request exists

I hold `roles/editor`. In GKE that role deliberately excludes RBAC writes, at **every** scope:

```
container.clusterRoles.create      denied
container.clusterRoleBindings.create denied
container.roles.create             denied   (namespaced too)
container.roleBindings.create      denied
```

I can create ServiceAccounts, Secrets, Deployments, and even update the cluster itself —
only the RBAC objects are blocked. Impersonating `aegis-github-actions` is also denied
(`iam.serviceAccounts.getAccessToken`).

Only the project owner (mboksa@) can change project IAM, so a role grant needs a separate
request. You can apply the RBAC directly, which is faster and narrower. I will raise the
IAM request separately so this does not recur.

---

## 2. What we are building

AEGIS is our autonomous SRE platform. It ingests incidents, then runs an AI agent that
investigates using logs, traces, metrics, and live Kubernetes state, and writes a root
cause report back to the Jira ticket.

The demo shows: **Jira ticket created → AEGIS RCA runs → report posted back**.

For that, AEGIS needs two independent things from the workload cluster:

| Need | Path | Status |
|------|------|--------|
| Telemetry (logs, traces, metrics) | push, out of the cluster | **working** |
| Live cluster state (pods, events, deployments) | pull, into the cluster API | **needs this request** |

Telemetry already works because it only pushes outward with an API key. Reading cluster
state needs an identity inside the cluster, which is what the RBAC creates.

---

## 3. Current deployment model, and why

### Two clusters, one VPC

```
aegis-cluster   (existing)   AEGIS platform, namespace aegis-dev
demo-cluster    (new)        opentelemetry-demo, namespace otel-demo
both in aegis-vpc, us-central1-a
```

Separate clusters because the demo is about AEGIS observing **someone else's** cluster.
Running it in `aegis-dev` would prove nothing and would crowd the platform's 4 nodes.

`demo-cluster`: 3 × e2-standard-4, subnet `demo-subnet` 10.4.0.0/20, pods 10.5.0.0/16,
services 10.6.0.0/20 — no overlap with the AEGIS ranges.

### Control plane is closed by default

Master authorized networks are restricted to:

| CIDR | Why |
|------|-----|
| `10.1.0.0/16` | AEGIS pod range — GKE does not masquerade pod IPs to RFC1918 destinations, so the API server sees the pod IP |
| `10.0.0.0/20` | AEGIS node subnet |
| `183.83.140.218/32` | my workstation |

**This blocks your kubectl.** Section 5 handles it.

### The private endpoint is the one that matters

`demo-cluster` exposes two control-plane addresses. Only one works for AEGIS, and I
verified both from inside a running AEGIS pod:

```
https://10.4.0.2/version        ->  401 Unauthorized   (reachable, needs credentials)
https://34.58.171.103/version   ->  ConnectTimeout     (NOT reachable)
```

The public endpoint fails because AEGIS pods egress through node NAT, and that address is
not in the authorized list. The private endpoint works because the AEGIS **pod** CIDR
`10.1.0.0/16` is authorized and GKE does not masquerade pod IPs to RFC1918 destinations.
TLS also validates cleanly against the GKE CA on that IP, which matters because the AEGIS
Kubernetes client runs with `verify_ssl=True`.

So AEGIS will be configured with `api_server_url: https://10.4.0.2`. Nothing needs to be
opened to the public internet.

### Telemetry goes out, never in

```
demo collector → https://aegis.griddynamics.net/v1/telemetry/{traces,metrics,logs}
                 header: X-AEGIS-API-KEY
               → AEGIS api-gateway → AEGIS collector → Loki / Tempo / Prometheus
```

The gateway resolves the tenant from the API key, so the demo cluster never declares its
own tenant. No inbound firewall rule into `demo-cluster` is required for telemetry.

---

## 4. Configuration already applied

### On `demo-cluster` (opentelemetry-demo chart 0.41.1)

Config lives in `~/opentelemetry-demo/gke-deploy/`.

| Change | Reason |
|--------|--------|
| Disabled `grafana`, `prometheus`, `jaeger`, `opensearch` subcharts | AEGIS is the backend. grafana/prometheus also ship ClusterRoles I cannot create, which failed the install. Saves about 4 vCPU. |
| Disabled presets `kubeletMetrics`, `clusterMetrics`, `kubernetesAttributes`, `annotationDiscovery` | All need cluster-scoped RBAC. Left on, they logged 403s every scrape and enriched nothing. |
| Replaced the `logsCollection` preset with a hand-written `filelog/aegis` receiver | The preset pulls in a ClusterRole. The replacement reads `/var/log/pods/...` and derives namespace, pod, and container from the **file path** using the `container` operator — no API access, so no RBAC. |
| Collector memory 400Mi → 1Gi | The default was already refusing data: `data refused due to high memory usage`. Telemetry was being dropped silently. |
| Static `resource/aegis` attributes | `tenant_id=acme-corp`, `service.namespace=opentelemetry-demo`, `k8s.cluster.name=demo-cluster`, `k8s.namespace.name=otel-demo`. AEGIS joins on these exact values. |

Several of these are workarounds for the missing RBAC. Once this request is approved, the
presets can be turned back on for richer pod-level metrics — but the demo does not block on it.

### On `aegis-cluster` (bug found and fixed)

The AEGIS collector was dropping **every** workload log line:

```
otlphttp/loki → http://loki:3100/otlp/v1/logs → HTTP 404
dropped_items: 164, 369, 136 ... every 5 seconds
```

Loki in `aegis-dev` is **2.9.4**, and native OTLP ingestion only arrived in Loki 3.0. The
docker-compose config already used the correct translating exporter; the Helm chart had
diverged. Fixed in `gd-sre-helm/aegis/templates/configmaps.yaml` and hot-patched in the
live ConfigMap. Loki went from zero labels to 14 demo services.

### Verified working right now

| Signal | State |
|--------|-------|
| Traces | all demo services visible in Tempo |
| Metrics | about 21,000 series in Prometheus |
| Logs | 14 demo services in Loki, as `job="opentelemetry-demo/<service>"` |
| Kubernetes events | **blocked — this request** |
| Live cluster state for the RCA agent | **blocked — this request** |

---

## 5. What to run

### Step 1 — allow your own IP through the control plane

Your kubectl will time out otherwise. Pick one.

**Option A — you add your IP** (you have `container.admin`):

```bash
MY_IP=$(curl -s -4 ifconfig.me)
gcloud container clusters update demo-cluster \
  --zone us-central1-a --project gd-gcp-presales-india-auto-sre \
  --enable-master-authorized-networks \
  --master-authorized-networks 10.1.0.0/16,10.0.0.0/20,183.83.140.218/32,${MY_IP}/32
```

**Option B — send me your IP** and I will add it. I hold `container.clusters.update`.

Please remove your entry afterwards, or tell me and I will.

### Step 2 — get credentials

```bash
gcloud container clusters get-credentials demo-cluster \
  --zone us-central1-a --project gd-gcp-presales-india-auto-sre
```

### Step 3 — apply the RBAC

The file is `~/opentelemetry-demo/gke-deploy/aegis-rbac.yaml` (I will send it, or pull it
from the repo).

```bash
kubectl apply -f aegis-rbac.yaml
```

It creates exactly seven objects:

| Object | Purpose |
|--------|---------|
| Namespace `aegis-access` | isolates the AEGIS identity from workloads |
| ServiceAccount `aegis-mcp-reader` | the identity AEGIS authenticates as |
| ClusterRole `aegis-mcp-reader` | **get / list / watch only**, no writes |
| ClusterRoleBinding `aegis-mcp-reader` | binds the two |
| Secret `aegis-mcp-reader-token` | long-lived token (see caveat in section 7) |
| ClusterRole `otel-events` | read events for the telemetry collector |
| ClusterRoleBinding `otel-events` | binds it to the existing `otel-events` ServiceAccount |

### Step 4 — verify

```bash
kubectl auth can-i list pods -A \
  --as=system:serviceaccount:aegis-access:aegis-mcp-reader     # expect: yes

kubectl auth can-i delete pods -A \
  --as=system:serviceaccount:aegis-access:aegis-mcp-reader     # expect: no

kubectl auth can-i get secrets -A \
  --as=system:serviceaccount:aegis-access:aegis-mcp-reader     # expect: no
```

### Step 5 — hand over the token securely

Please do **not** paste the token into chat or email. Write it to Secret Manager instead —
we both hold `roles/secretmanager.admin`:

```bash
kubectl get secret aegis-mcp-reader-token -n aegis-access \
  -o jsonpath='{.data.token}' | base64 -d | \
gcloud secrets create demo-cluster-aegis-token \
  --project gd-gcp-presales-india-auto-sre --data-file=-
```

I will read it from there and finish onboarding. The CA certificate and endpoint I can
fetch myself through the GKE API.

---

## 6. Exactly what is granted

Read verbs (`get`, `list`, `watch`) on: pods, pods/log, services, endpoints, nodes,
namespaces, events, configmaps, PVCs, PVs, service accounts, limit ranges, resource quotas,
deployments, replicasets, statefulsets, daemonsets, jobs, cronjobs, ingresses, network
policies, HPAs, storage classes, pod disruption budgets, and metrics.

**Not granted:**

- `secrets` — the AEGIS Kubernetes MCP has a secret-reading tool. Without this permission it
  gets a clean 403 instead of returning credentials. Deliberate.
- **Every write verb.** AEGIS does have write tools (`rollout_restart`, `scale_deployment`,
  `suspend_cronjob`), but they stay unusable on this cluster. They are separately gated by
  `ALLOW_WRITE_ACTIONS` in the MCP, so this is the second lock.
- Anything outside `demo-cluster`.

---

## 7. Risks and how to undo

| Risk | Mitigation |
|------|------------|
| Long-lived token does not expire | Read-only. Revoke instantly with `kubectl delete secret aegis-mcp-reader-token -n aegis-access`. The proper fix is Workload Identity — AEGIS reads the endpoint and CA from the GKE API and mints a 1-hour token per call. That needs an AEGIS code change, planned but not ready. |
| Token leaks | It grants read-only access to one demo cluster holding a synthetic shop demo. No customer data. Handed over via Secret Manager, not chat. |
| Cluster-wide read is broader than one namespace | The RCA agent correlates across namespaces (`kube-system` events explain workload failures). Can be narrowed to a RoleBinding on `otel-demo` if you prefer — say so and I will send a namespaced variant. |

**Full rollback:**

```bash
kubectl delete -f aegis-rbac.yaml
```

Nothing else on the cluster depends on these objects.

---

## 8. Summary

- One `kubectl apply`, read-only, on a throwaway demo cluster.
- Unblocks Kubernetes events and live cluster state for the AEGIS RCA agent.
- Telemetry already works and does not depend on this.
- I will request `roles/container.admin` from mboksa@ separately so this is not needed again.
- AEGIS connects to `https://10.4.0.2` (private endpoint, verified reachable from AEGIS
  pods). Nothing is exposed to the public internet.

---

## 9. What happens after you approve (no action needed from you)

For context, so you can see the access is used for exactly what is described above.

AEGIS already supports this onboarding shape — **no code changes are involved**. The
existing endpoint `POST /v1/iam/apps/register` accepts cluster credentials inline
(`api_server_url`, `ca_cert_pem`, `auth_type: token`, `bearer_token`), which is the same
call the AEGIS "Register application" UI form makes.

I run one script, `gke-deploy/onboard-demo-cluster.sh`, which:

1. reads the ServiceAccount token from Secret Manager (`demo-cluster-aegis-token`),
2. fetches the private endpoint and CA certificate from the GKE API itself,
3. POSTs them to AEGIS with the tenant API key.

AEGIS then stores the credentials **encrypted at rest** (Fernet, `ENCRYPTION_KEY`) in its
`k8s_clusters` table, registers the app as `opentelemetry-demo`, and starts building the
service dependency graph from the traces already arriving.

From that point the demo is: a Jira ticket creates an AEGIS incident, the RCA agent
investigates using logs, traces, metrics, and the **read-only** cluster view this grant
provides, and posts its report back to the ticket.

The only thing the grant adds is the read-only view. Everything else already works.
