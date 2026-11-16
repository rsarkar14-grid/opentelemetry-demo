# gke-deploy — opentelemetry-demo on GKE, streaming to AEGIS

Replaces `kind-deploy/` for the GCP demo. Do not copy the kind files forward:
two things in them break on GKE (details below).

| File | Purpose |
|------|---------|
| `values-aegis-gke.yaml` | Demo chart overlay: adds AEGIS traces/metrics/logs pipelines |
| `otel-events-gke.yaml`  | Single-replica collector for Kubernetes Events |
| `create-cluster.sh`     | Creates `demo-cluster` (3 × e2-standard-4 on `demo-subnet`, closed control plane) |
| `deploy-gke.sh`         | One-shot deploy (credentials, secret, flag file, helm, cart probe, events collector) |
| `cart-readiness-patch.yaml` | gRPC readiness probe for the cart, applied by `deploy-gke.sh` |
| `build-push-images.sh`  | Builds services from this repo's source and pushes them to a registry |

## Quick start
```bash
./gke-deploy/create-cluster.sh                                  # once; DRY_RUN=1 prints the command
# someone with roles/container.admin applies gke-deploy/aegis-rbac.yaml
AEGIS_API_KEY=<tenant key> ./gke-deploy/deploy-gke.sh
```

`create-cluster.sh` allows the AEGIS ranges and this machine's public IP through the
control plane. If your IP changes later, add it with `gcloud container clusters update
demo-cluster --enable-master-authorized-networks --master-authorized-networks <all CIDRs>`;
the flag replaces the whole list, so repeat the AEGIS ranges. `USE_SPOT=1` creates the
nodes as Spot VMs.

## What runs on the cluster

The chart pins `0.41.1` (app 3.0.0). Without further steps the cluster runs the
chart's published images, not this repo's source. Two things do come from this repo:

- **Flags**: `src/flagd/demo.flagd.json` is loaded as ConfigMap `flagd-config-main`
  and mounted in place of the chart's copy. flagd reads it only at pod start, so
  `deploy-gke.sh` restarts flagd; flag changes made in the flagd UI are lost on redeploy.
- **Cart readiness**: the chart's values schema only allows `httpGet` probes and the
  cart serves gRPC, so `deploy-gke.sh` patches a gRPC probe onto the Deployment.
  Setting `failedReadinessProbe` then takes the cart out of the Service endpoints.

To run services built from this repo's source, push them and deploy with the same
repository and tag. The frontend must come from this repo: the chart's 3.0.0 frontend
predates its OTLP log exporter, so it sends no logs.

```bash
export IMAGE_REPO=us-central1-docker.pkg.dev/<project>/<repository>/demo
export IMAGE_TAG=$(git rev-parse --short HEAD)
./gke-deploy/build-push-images.sh frontend
SOURCE_SERVICES="frontend" AEGIS_API_KEY=<tenant key> ./gke-deploy/deploy-gke.sh
```

The registry repository must exist and the cluster nodes need pull access to it.

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
