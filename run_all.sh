#!/usr/bin/env bash
# Runs the full benchmark matrix for all 6 (system, tier) combinations,
# strictly sequentially (single-machine decision: never run both systems
# concurrently). Each combination's own run.sh already tears its pod down
# on exit before the next one starts.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

COMBOS=(
  "nats tier1"
  "nats tier2"
  "nats tier3"
  "redis tier1"
  "redis tier2"
  "redis tier3"
)

overall_rc=0
for combo in "${COMBOS[@]}"; do
  read -r sys tier <<< "$combo"
  echo "##### [$(date -u +%Y-%m-%dT%H:%M:%SZ)] START ${sys} ${tier} #####"
  ./run.sh "$sys" "$tier"
  rc=$?
  echo "##### [$(date -u +%Y-%m-%dT%H:%M:%SZ)] END ${sys} ${tier} (exit ${rc}) #####"
  [[ $rc -ne 0 ]] && overall_rc=1
done

echo "##### ALL COMBINATIONS DONE (overall_rc=${overall_rc}) #####"
exit "$overall_rc"
