# shellcheck shell=bash
# aegis-gateway.sh — sourced by start-kind.sh and setup-kind-cluster.sh.
#
# Everything these scripts ask of AEGIS goes through its API gateway
# (AEGIS_GATEWAY_URL, default http://localhost:8000) — the only AEGIS port meant
# for callers outside the stack. Internal services (iam-service, k8s-mcp, ...)
# are not published to the host and require internal auth / mutual TLS.
#
# aegis_curl METHOD PATH [curl args...] calls the gateway as the tenant admin:
# AEGIS_ADMIN_API_KEY (default: the local-dev tenants.json key, accepted only
# when AEGIS runs with AEGIS_ENV=development, as docker compose does). Call
# use_aegis_admin_key once, in the main shell, first.
#
# apply_aegis_telemetry_credentials puts an AEGIS API key with scope `agent` (POST /v1/telemetry/* only) into the
# `aegis-credentials` Secret of every namespace that pushes telemetry to AEGIS:
# otel-system (the OTel DaemonSet) and otel-demo (the demo's collector). The key
# is never committed. Which key, in order:
#   1. AEGIS_TELEMETRY_API_KEY, if set;
#   2. the agent key already in otel-system/aegis-credentials (a re-run keeps it);
#   3. a new one, minted through the gateway with the admin key.
#
# Expects CONTEXT, and log / ok / warn / die, from the calling script. Inside the
# $(...) helpers those messages go to stderr, so they never end up in the key.

AEGIS_GATEWAY_URL="${AEGIS_GATEWAY_URL:-http://localhost:8000}"
AEGIS_TELEMETRY_NAMESPACES=(otel-system otel-demo)
# The legacy shared dev key; it is admin-scoped, so it only ever mints, and is
# never handed to a workload.
_AEGIS_DEV_ADMIN_KEY="password"

use_aegis_admin_key() {
  if [[ -z "${AEGIS_ADMIN_API_KEY:-}" ]]; then
    warn "AEGIS_ADMIN_API_KEY not set — using the local-dev key (accepted only with AEGIS_ENV=development)"
    AEGIS_ADMIN_API_KEY="${_AEGIS_DEV_ADMIN_KEY}"
  fi
}

aegis_curl() {
  local method="$1" path="$2"
  shift 2
  # -H @file keeps the key off the curl command line (ps).
  curl -sS -X "${method}" "${AEGIS_GATEWAY_URL}${path}" \
    -H @<(printf 'X-AEGIS-API-KEY: %s\n' "${AEGIS_ADMIN_API_KEY:?call use_aegis_admin_key first}") "$@"
}

_aegis_existing_telemetry_key() {
  local key
  key=$(kubectl --context "${CONTEXT}" -n otel-system get secret aegis-credentials \
          -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d 2>/dev/null) || return 1
  # The old manifest shipped the shared dev key; never reuse it.
  [[ -n "${key}" && "${key}" != "${_AEGIS_DEV_ADMIN_KEY}" ]] || return 1
  printf '%s' "${key}"
}

_aegis_mint_telemetry_key() {
  local resp
  resp=$(aegis_curl POST /v1/tenants/api-keys --fail -H "Content-Type: application/json" \
           -d '{"name": "kind-aegis-telemetry", "scope": "agent"}') \
    || die "Could not mint an agent API key at ${AEGIS_GATEWAY_URL}/v1/tenants/api-keys. Is the AEGIS stack up? Or set AEGIS_TELEMETRY_API_KEY." >&2
  python3 -c 'import json, sys; print(json.load(sys.stdin)["key"], end="")' <<<"${resp}" \
    || die "Unexpected response from ${AEGIS_GATEWAY_URL}/v1/tenants/api-keys" >&2
}

apply_aegis_telemetry_credentials() {
  local key ns
  if [[ -n "${AEGIS_TELEMETRY_API_KEY:-}" ]]; then
    key="${AEGIS_TELEMETRY_API_KEY}"
  elif key=$(_aegis_existing_telemetry_key); then
    ok "Reusing the agent API key already in otel-system/aegis-credentials"
  else
    log "Minting an AEGIS API key with scope 'agent' for telemetry..."
    use_aegis_admin_key
    key=$(_aegis_mint_telemetry_key)
    ok "Minted an agent API key (shown nowhere; stored only in the cluster Secret)"
  fi
  for ns in "${AEGIS_TELEMETRY_NAMESPACES[@]}"; do
    kubectl --context "${CONTEXT}" create namespace "${ns}" --dry-run=client -o yaml \
      | kubectl --context "${CONTEXT}" apply --validate=false -f - >/dev/null
    # --from-file keeps the key off the kubectl command line (ps).
    kubectl --context "${CONTEXT}" -n "${ns}" create secret generic aegis-credentials \
      --from-file=api-key=<(printf '%s' "${key}") --dry-run=client -o yaml \
      | kubectl --context "${CONTEXT}" apply --validate=false -f - >/dev/null
  done
  ok "aegis-credentials applied in: ${AEGIS_TELEMETRY_NAMESPACES[*]}"
}
