# gke-deploy — opentelemetry-demo on GKE, streaming to AEGIS

Replaces `kind-deploy/` for the GCP demo. Do not copy the kind files forward:
two things in them break on GKE (details below).

| File | Purpose |
|------|---------|
| `values-aegis-gke.yaml` | Demo chart overlay: adds AEGIS traces/metrics/logs pipelines |
| `otel-events-gke.yaml`  | Single-replica collector for Kubernetes Events (namespaced objects only; its ClusterRole and binding are in `aegis-rbac.yaml`) |
| `create-cluster.sh`     | Creates `demo-cluster` (3 × e2-standard-4 on `demo-subnet`, closed control plane) |
| `deploy-gke.sh`         | One-shot deploy (credentials, secret, flag file, helm, cart probe, events collector) |
| `cart-readiness-patch.yaml` | gRPC readiness probe for the cart, applied by `deploy-gke.sh` |
| `build-push-images.sh`  | Builds services from this repo's source and pushes them to a registry |
| `source-services.txt`   | Services built from this repo and deployed by default |

## Quick start
```bash
./gke-deploy/create-cluster.sh                                  # once; DRY_RUN=1 prints the command
# someone with roles/container.admin applies gke-deploy/aegis-rbac.yaml
export IMAGE_REPO=us-central1-docker.pkg.dev/<project>/<repository>/demo
export IMAGE_TAG=$(git rev-parse --short HEAD)
./gke-deploy/build-push-images.sh                               # builds source-services.txt
AEGIS_API_KEY=<tenant key> ./gke-deploy/deploy-gke.sh
```

`create-cluster.sh` allows the AEGIS ranges and this machine's public IP through the
control plane. If your IP changes later, add it with `gcloud container clusters update
demo-cluster --enable-master-authorized-networks --master-authorized-networks <all CIDRs>`;
the flag replaces the whole list, so repeat the AEGIS ranges. `USE_SPOT=1` creates the
nodes as Spot VMs.

## What runs on the cluster

The chart pins `0.41.1` (app 3.0.0), whose published images predate several failure
scenarios. `deploy-gke.sh` therefore runs the services in `source-services.txt` from
images built from this repo, and the repo's flag file, so each flag has code behind it:

| Service | Why it is built from this repo |
|---|---|
| `frontend` | the 3.0.0 image has no OTLP log exporter, so it sends no logs |
| `cart` | `cartMetricCardinalityOverflow` |
| `checkout`, `payment` | `emitRawPii`; checkout also no longer floods Kafka for `kafkaQueueProblems` |
| `fraud-detection` | `kafkaConsumerDead` and the millisecond `kafkaQueueProblems` delay |
| `agent` | `aiSlowResponse`, `aiRunawayAgent` |
| `ad` | `adManualGc` is rate limited |

Everything else runs the chart's images. Build and push once per change; the registry
repository must exist and the cluster nodes need pull access to it. Building all of
these for linux/amd64 on an Apple Silicon laptop is slow; build a subset by naming
services (`./gke-deploy/build-push-images.sh cart ad`) and deploy with the same
`IMAGE_REPO`/`IMAGE_TAG` and a matching `SOURCE_SERVICES`.

`CHART_IMAGES=1 ./gke-deploy/deploy-gke.sh` skips the registry and runs the chart's
images with the chart's own flag file. Flags added after 3.0.0 then have no effect.

Two things in the deploy do not depend on images:

- **Flags**: `src/flagd/demo.flagd.json` is loaded as ConfigMap `flagd-config-main`
  and mounted in place of the chart's copy. flagd reads it only at pod start, so
  `deploy-gke.sh` restarts flagd; flag changes made in the flagd UI are lost on redeploy.
- **Cart readiness**: the chart's values schema only allows `httpGet` probes and the
  cart serves gRPC, so `deploy-gke.sh` patches a gRPC probe onto the Deployment.
  Setting `failedReadinessProbe` then takes the cart out of the Service endpoints.

## What changed vs kind-deploy

1. **Endpoint**: `host.docker.internal:8000` → `https://aegis.griddynamics.net` (GKE ingress → api-gateway).
2. **Events filter bug**: the kind DaemonSet kept events only from node
   `kind-aegis-control-plane`. GKE has no control-plane node, so that filter drops
   **every** event. Events now come from a 1-replica Deployment with no filter.
3. **No custom metrics DaemonSet**: chart 0.41.1 already runs its collector as a
   DaemonSet with hostMetrics + kubeletMetrics + clusterMetrics presets.
4. **Processor names are chart-specific**: this chart calls the k8s enrichment
   processor `k8s_attributes` (underscores), not upstream `k8sattributes`, and its
   traces pipeline uses `transform/sanitize_logs`. Always confirm names against the
   rendered ConfigMap before adding a pipeline:
   `helm template ... -f values-aegis-gke.yaml | yq '.. | select(.processors?)'`
5. **Collector image**: pinned to 0.160.0 for the events collector (kind used 0.100.0).

## Identifiers that MUST match AEGIS

| Attribute | Value | AEGIS record |
|-----------|-------|--------------|
| `tenant_id` | `acme-corp` | `tenants.tenant_id` |
| `service.namespace` | `opentelemetry-demo` | `registered_apps.name` |
| `k8s.cluster.name` | `demo-cluster` | `k8s_clusters.cluster_name` |

`service.namespace` must never be `aegis` — the AEGIS collector's
`filter/external_only` processor drops anything in that namespace.

## Cluster

`demo-cluster` (us-central1-a) shares `aegis-vpc` with `aegis-cluster`.
Control plane is restricted to authorized networks: the AEGIS pod CIDR
`10.1.0.0/16`, the AEGIS node subnet `10.0.0.0/20`, and the operator IP.
