#!/usr/bin/env bash
# wait-for-pods.sh — Poll until all pods in the otel-demo namespace are Running.
#
# Usage:
#   ./wait-for-pods.sh           # default: poll every 5 s, no timeout
#   ./wait-for-pods.sh 10 300    # poll every 10 s, give up after 300 s

set -euo pipefail

INTERVAL="${1:-5}"
TIMEOUT="${2:-0}"   # 0 = wait forever

CONTEXT="kind-kind-aegis"
NAMESPACE="otel-demo"

elapsed=0
prev_lines=0

echo "Watching pods in namespace '${NAMESPACE}'..."

clear_prev() {
  if [[ "$prev_lines" -gt 0 ]]; then
    printf '\033[%dA\033[J' "$prev_lines"
  fi
}

while true; do
  pods=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods --no-headers 2>/dev/null || true)

  clear_prev

  if [[ -z "$pods" ]]; then
    printf '  No pods found yet — retrying in %ss...\n' "${INTERVAL}"
    prev_lines=1
  else
    total=$(echo "$pods" | wc -l | tr -d ' ')
    not_running=$(echo "$pods" | awk '$3 != "Running" && $3 != "Completed"')
    not_running_count=$(echo "$not_running" | grep -c . || true)

    if [[ -n "$not_running" ]]; then
      printf '  %s/%s pods not yet Running:\n' "${not_running_count}" "${total}"
      echo "$not_running" | awk '{printf "    %-50s %s\n", $1, $3}'
      prev_lines=$(( not_running_count + 1 ))
    else
      echo ""
      echo "All pods running and healthy!"
      exit 0
    fi
  fi

  if [[ "$TIMEOUT" -gt 0 && "$elapsed" -ge "$TIMEOUT" ]]; then
    echo ""
    echo "Timed out after ${TIMEOUT}s — not all pods reached Running state." >&2
    exit 1
  fi

  sleep "${INTERVAL}"
  elapsed=$(( elapsed + INTERVAL ))
done
