#!/usr/bin/env bash
# Background podman stats sampler. Started before a run, killed after.
# Usage: start_stats_sampler <container_name> <out_file>   -> prints background PID
#        stop_stats_sampler <pid>
#
# `podman stats` on this version has no --filter flag (pod-based filtering
# doesn't exist) — it only accepts explicit container names as positional
# args, so this targets the known server container name directly.

start_stats_sampler() {
  local container_name="$1"
  local out_file="$2"
  mkdir -p "$(dirname "$out_file")"
  echo "timestamp,name,cpu_perc,mem_usage,net_io,block_io" > "$out_file"
  (
    while true; do
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      podman stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}}" \
        "$container_name" 2>/dev/null \
        | sed "s/^/${ts},/" >> "$out_file"
      sleep 5
    done
  ) >/dev/null 2>&1 &
  echo $!
}

stop_stats_sampler() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
