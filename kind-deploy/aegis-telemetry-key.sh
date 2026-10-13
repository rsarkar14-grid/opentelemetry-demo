# shellcheck shell=bash
# aegis-telemetry-key.sh — sourced by start-kind.sh and setup-kind-cluster.sh.
#
# Puts an AEGIS API key with scope `agent` (POST /v1/telemetry/* only) into the
# `aegis-credentials` Secret of every namespace that pushes telemetry to AEGIS:
# otel-system (the OTel DaemonSet) and otel-demo (the demo's collector). The key
# is never committed. Which key, in order:
#   1. AEGIS_TELEMETRY_API_KEY, if set;
#   2. the agent key already in otel-system/aegis-credentials (a re-run keeps it);
#   3. a new one, minted through the gateway with an admin key:
#        AEGIS_ADMIN_API_KEY (default: the local-dev tenants.json key, accepted
#        only when AEGIS runs with AEGIS_ENV=development, as docker compose does).
# AEGIS_GATEWAY_URL defaults to http://localhost:8000.
#
# Expects CONTEXT, and log / ok / warn / die, from the calling script. Inside the
# $(...) helpers those messages go to stderr, so they never end up in the key.

AEGIS_TELEMETRY_NAMESPACES=(otel-system otel-demo)
# The legacy shared dev key; it is admin-scoped, so it only ever mints, and is
# never handed to a workload.
_AEGIS_DEV_ADMIN_KEY="password"

_aegis_existing_telemetry_key() {
  local key
  key=$(kubectl --context "${CONTEXT}" -n otel-system get secret aegis-credentials \
          -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d 2>/dev/null) || return 1
  # The old manifest shipped the shared dev key; never reuse it.
  [[ -n "${key}" && "${key}" != "${_AEGIS_DEV_ADMIN_KEY}" ]] || return 1
  printf '%s' "${key}"
}

_aegis_mint_telemetry_key() {
  local url="${AEGIS_GATEWAY_URL:-http://localhost:8000}" admin="${AEGIS_ADMIN_API_KEY:-}" resp
  if [[ -z "${admin}" ]]; then
    warn "AEGIS_ADMIN_API_KEY not set — minting with the local-dev key (works only with AEGIS_ENV=development)" >&2
    admin="${_AEGIS_DEV_ADMIN_KEY}"
  fi
  resp=$(curl -fsS -X POST "${url}/v1/tenants/api-keys" \
           -H "X-AEGIS-API-KEY: ${admin}" -H "Content-Type: application/json" \
           -d '{"name": "kind-aegis-telemetry", "scope": "agent"}') \
    || die "Could not mint an agent API key at ${url}/v1/tenants/api-keys. Is the AEGIS stack up? Or set AEGIS_TELEMETRY_API_KEY." >&2
  python3 -c 'import json, sys; print(json.load(sys.stdin)["key"], end="")' <<<"${resp}" \
    || die "Unexpected response from ${url}/v1/tenants/api-keys" >&2
}

apply_aegis_telemetry_credentials() {
  local key ns
  if [[ -n "${AEGIS_TELEMETRY_API_KEY:-}" ]]; then
    key="${AEGIS_TELEMETRY_API_KEY}"
  elif key=$(_aegis_existing_telemetry_key); then
    ok "Reusing the agent API key already in otel-system/aegis-credentials"
  else
    log "Minting an AEGIS API key with scope 'agent' for telemetry..."
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
