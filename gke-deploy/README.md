# gke-deploy — opentelemetry-demo on GKE, streaming to AEGIS

Replaces `kind-deploy/` for the GCP demo. Do not copy the kind files forward:
two things in them break on GKE (details below).

| File | Purpose |
|------|---------|
| `values-aegis-gke.yaml` | Demo chart overlay: adds AEGIS traces/metrics/logs pipelines |
| `otel-events-gke.yaml`  | Single-replica collector for Kubernetes Events |
| `deploy-gke.sh`         | One-shot deploy (credentials, secret, helm, events collector) |

## Quick start
```bash
AEGIS_API_KEY=<tenant key> ./gke-deploy/deploy-gke.sh
```

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
