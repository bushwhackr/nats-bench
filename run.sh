#!/usr/bin/env bash
# NATS JetStream vs Redis throughput benchmark — single-machine, rootless Podman.
#
# Environment decisions this script encodes (see conversation for rationale):
#   - rootless Podman, same-pod networking (client+server share netns -> loopback,
#     no virtual network device in the critical path)
#   - tier3 uses a real disk-backed podman volume (not tmpfs) for durable
#     storage — deliberately trades benchmark isolation for production
#     realism, so tier3 numbers reflect actual fsync/disk cost
#   - single host -> systems run SEQUENTIALLY, never concurrently, full pod
#     teardown between them, to avoid CPU/cache/memory-bandwidth contention
#     between the two systems under test
#
# Usage:
#   ./run.sh <nats|redis> <tier1|tier2|tier3> [dry-run]
#
# Run once per (system, tier) combination. Tear down is automatic on exit.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck source=lib/config.sh
source lib/config.sh
# shellcheck source=lib/stats.sh
source lib/stats.sh
# shellcheck source=lib/payload.sh
source lib/payload.sh

SYSTEM="${1:?usage: run.sh <nats|redis> <tier1|tier2|tier3> [dry-run]}"
TIER="${2:?usage: run.sh <nats|redis> <tier1|tier2|tier3> [dry-run]}"
DRY_RUN="${3:-}"

[[ "$SYSTEM" == "nats" || "$SYSTEM" == "redis" ]] || { echo "system must be nats|redis"; exit 1; }
[[ " ${TIERS[*]} " == *" $TIER "* ]] || { echo "tier must be one of: ${TIERS[*]}"; exit 1; }

POD_NAME="${SYSTEM}-${TIER}-pod"
DATA_VOLUME="${POD_NAME}-data"
STATS_PID=""

mkdir -p "$RESULTS_DIR" "$STATS_DIR"
[[ -f "$CSV_FILE" ]] || echo "timestamp,system,tier,cpus,mem,io_threads,client_cpus,msg_size,concurrency,run_index,duration_s,throughput_msgs_sec,throughput_mb_sec,p50_ms,p95_ms,p99_ms,raw_log" > "$CSV_FILE"

cleanup() {
  local exit_code=$?
  [[ -n "$STATS_PID" ]] && stop_stats_sampler "$STATS_PID"
  echo "[teardown] removing pod $POD_NAME"
  podman pod rm -f "$POD_NAME" >/dev/null 2>&1 || true
  # Fresh disk state per invocation, same philosophy as the pod itself.
  podman volume rm -f "$DATA_VOLUME" >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap cleanup EXIT

echo "[setup] creating pod $POD_NAME"
podman pod create --name "$POD_NAME" >/dev/null

if [[ "$TIER" == "tier3" ]]; then
  podman volume rm -f "$DATA_VOLUME" >/dev/null 2>&1 || true
  podman volume create "$DATA_VOLUME" >/dev/null
fi

start_nats_server() {
  local cpus="$1" mem="$2"
  local mounts=()
  local args=(-m 8222)
  case "$TIER" in
    tier1) : ;;  # core NATS, no JetStream at all
    tier2) args+=(-js) ;;                          # JetStream enabled, memory-storage streams
    tier3) mounts=(-v "${DATA_VOLUME}:/data")       # real disk-backed volume
           args+=(-js -sd /data) ;;
  esac
  # Root cause of the tier2 OOM kills (confirmed via jsz/varz + journalctl):
  # nats-server sizes its JetStream memory-store admission budget off the
  # HOST's total physical RAM (75% of it) when GOMEMLIMIT is unset -- it has
  # no idea the process is actually confined to $mem by the cgroup. That's
  # also why the OS-level kernel OOM-killer is the only thing that ever
  # stops it: nats-server itself never sees a reason to refuse work or GC
  # aggressively, since it believes it has far more headroom than it does.
  # Setting GOMEMLIMIT fixes both halves of this:
  #  (1) nats-server derives its default max_mem_store from 75% of
  #      GOMEMLIMIT instead of host RAM, so admission control matches the
  #      container's real ceiling.
  #  (2) Go's GC paces off GOMEMLIMIT, so it scavenges a deleted stream's
  #      memory promptly instead of lazily -- without it, a prior run's
  #      garbage was still resident (only partially reclaimed) when the
  #      next run's working set stacked on top, and the combination
  #      eventually breached the cgroup limit.
  # Set to 80% of the container's --memory, leaving headroom below the hard
  # cgroup cap for non-heap overhead (goroutine stacks, net buffers, cgo).
  # GODEBUG=madvdontneed=1 makes the scavenge return pages to the OS
  # immediately (MADV_DONTNEED) rather than lazily (default MADV_FREE).
  local gomemlimit_gib=$(( ${mem%g} * 8 / 10 ))
  podman run -d --pod "$POD_NAME" --name nats-server \
    --cpuset-cpus="$cpus" --memory="$mem" \
    -e GODEBUG=madvdontneed=1 -e GOMEMLIMIT="${gomemlimit_gib}GiB" \
    "${mounts[@]}" "$NATS_IMAGE" "${args[@]}" >/dev/null

  echo "[wait] nats-server health"
  for _ in $(seq 1 30); do
    podman run --rm --pod "$POD_NAME" "$NATS_BOX_IMAGE" \
      wget -q -O- http://127.0.0.1:8222/healthz >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "nats-server did not become healthy in time"; exit 1
}

start_redis_server() {
  local cpus="$1" mem="$2" io_threads="$3"
  local mounts=()
  local args=()
  case "$TIER" in
    tier1) args+=(--save "" --appendonly no) ;;                 # pure in-memory baseline
    tier2) args+=(--save "" --appendonly no) ;;                 # streams, no persistence
    tier3) mounts=(-v "${DATA_VOLUME}:/data")                   # real disk-backed volume
           args+=(--dir /data --appendonly yes --appendfsync everysec) ;;
  esac
  # io-threads only parallelizes socket I/O, never command execution — see
  # REDIS_RESOURCE_CONFIGS comment in lib/config.sh. Left off (upstream
  # default) unless explicitly raised above 1.
  if [[ "$io_threads" -gt 1 ]]; then
    args+=(--io-threads "$io_threads" --io-threads-do-reads yes)
  fi
  podman run -d --pod "$POD_NAME" --name redis-server \
    --cpuset-cpus="$cpus" --memory="$mem" \
    "${mounts[@]}" "$REDIS_IMAGE" redis-server "${args[@]}" >/dev/null

  echo "[wait] redis-server health"
  for _ in $(seq 1 30); do
    podman run --rm --pod "$POD_NAME" "$REDIS_IMAGE" redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -q PONG && return 0
    sleep 1
  done
  echo "redis-server did not become healthy in time"; exit 1
}

# Verified against natscli in nats-box:latest (2026-07-05):
#   - `nats bench pub <subject>` / `nats bench js pub sync <subject>` are the
#     current subcommands (the old combined `nats bench <subject> --pub --sub`
#     form no longer exists).
#   - Both write a one-line summary to stdout: "NATS ... stats: N msgs/sec ~
#     X MiB/sec ~ min: ... ~ avg: ... ~ max: ... ~ P50: Aus ~ P90: Bus ~
#     P99: Cus ~ P99.9: Dus" — parsed below, no need for the tool's own --csv
#     flag (which writes inside the ephemeral client container and is lost
#     when it exits).
#   - `js pub sync --create --purge` handles stream creation/reset per run,
#     so no separate `nats stream add`/`purge` step is needed.
# Tier1 uses `bench pub` alone (no subscriber) to match Redis PUBLISH's
# fire-and-forget semantics — both sides measure publish-call completion,
# not confirmed delivery, so the comparison stays apples-to-apples.
#
# tier2/tier3 explicitly delete the stream before every single run (not
# just once per resource config). `--purge` alone was NOT enough — it was
# still called on every invocation before this fix and nats-server was
# genuinely OOM-killed by the kernel repeatedly during long sweeps (memory
# storage retains underlying allocated blocks across purges instead of
# releasing them). A full delete + recreate actually frees that memory.
run_nats_bench() {
  local size="$1" conc="$2" idx="$3" out="$4"
  if [[ "$TIER" == "tier1" ]]; then
    podman run --rm --pod "$POD_NAME" --cpuset-cpus="$CLIENT_CPUS" "$NATS_BOX_IMAGE" \
      nats bench pub bench.load --clients="$conc" --msgs="$TEST_MSG_COUNT" \
        --size="$size" --no-progress > "$out" 2>&1 || true
  else
    local storage="memory"; [[ "$TIER" == "tier3" ]] && storage="file"
    podman run --rm --pod "$POD_NAME" --cpuset-cpus="$CLIENT_CPUS" "$NATS_BOX_IMAGE" \
      nats stream rm BENCH -f >/dev/null 2>&1 || true
    podman run --rm --pod "$POD_NAME" --cpuset-cpus="$CLIENT_CPUS" "$NATS_BOX_IMAGE" \
      nats bench js pub sync bench.load --create --storage="$storage" \
        --replicas=1 --stream=BENCH --maxbytes="$NATS_TEST_STREAM_CAP" --clients="$conc" \
        --msgs="$TEST_MSG_COUNT" --size="$size" --no-progress > "$out" 2>&1 || true
  fi
}

# Verified against redis:8.8.0's redis-benchmark (2026-07-05):
#   - `-t publish` is NOT a recognized built-in test name in this version —
#     it silently produces zero output (no error). Custom-command syntax
#     (passing PUBLISH/XADD directly as trailing args, no `--` separator)
#     is what actually works and gives full --csv output including latency
#     percentiles.
#
# tier2/tier3 explicitly delete the stream key before every single run.
# `XADD` was never reset between runs at all — the stream just grew across
# a resource config's entire 60-run sweep until it exceeded the container's
# memory limit and Redis was genuinely OOM-killed by the kernel.
run_redis_bench() {
  local size="$1" conc="$2" idx="$3" out="$4"
  local payload_file; payload_file=$(payload_file_for_size "$size")
  local payload; payload=$(cat "$payload_file")
  if [[ "$TIER" == "tier1" ]]; then
    podman run --rm --pod "$POD_NAME" --cpuset-cpus="$CLIENT_CPUS" "$REDIS_IMAGE" \
      redis-benchmark -h 127.0.0.1 -p 6379 -c "$conc" -n "$TEST_MSG_COUNT" --csv \
        PUBLISH benchchan "$payload" > "$out" 2>&1 || true
  else
    podman run --rm --pod "$POD_NAME" --cpuset-cpus="$CLIENT_CPUS" "$REDIS_IMAGE" \
      redis-cli -h 127.0.0.1 -p 6379 DEL benchstream >/dev/null 2>&1 || true
    podman run --rm --pod "$POD_NAME" --cpuset-cpus="$CLIENT_CPUS" "$REDIS_IMAGE" \
      redis-benchmark -h 127.0.0.1 -p 6379 -c "$conc" -n "$TEST_MSG_COUNT" --csv \
        XADD benchstream '*' field "$payload" > "$out" 2>&1 || true
  fi
}

# nats bench only exposes P50/P90/P99/P99.9 (microseconds); redis-benchmark
# only exposes p50/p95/p99 (milliseconds). There's no shared p95 — nats
# leaves that column blank rather than mislabeling P90 as P95.
parse_nats_output() {
  local f="$1"
  local line; line=$(grep -E 'msgs/sec' "$f" | tail -1 || true)
  local mps bw_raw bw_val bw_unit mbs p50_us p99_us
  mps=$(echo "$line" | grep -oE '[0-9,]+ msgs/sec' | grep -oE '^[0-9,]+' | tr -d ',' || true)
  # bandwidth auto-scales unit (B/KiB/MiB/GiB) depending on magnitude — normalize
  # everything to MB/sec (binary, i.e. MiB) rather than assuming MiB always.
  bw_raw=$(echo "$line" | grep -oE '[0-9.]+ [KMG]?i?B/sec' | tail -1 || true)
  bw_val=$(echo "$bw_raw" | grep -oE '^[0-9.]+' || true)
  bw_unit=$(echo "$bw_raw" | grep -oE '[KMG]?i?B/sec' | grep -oE '^[KMG]?' || true)
  if [[ -n "$bw_val" ]]; then
    case "$bw_unit" in
      G) mbs=$(awk -v v="$bw_val" 'BEGIN{printf "%.3f", v*1024}') ;;
      M) mbs="$bw_val" ;;
      K) mbs=$(awk -v v="$bw_val" 'BEGIN{printf "%.6f", v/1024}') ;;
      "") mbs=$(awk -v v="$bw_val" 'BEGIN{printf "%.9f", v/1024/1024}') ;;
    esac
  fi
  # NOTE: a plain second grep -oE '[0-9.,]+' pass here would also match the
  # "50"/"99" digits inside the "P50"/"P99" label itself (two matches, and
  # awk's numeric parse of the resulting multi-line string silently takes
  # only the leading one) -- always yielding 0.0500ms/0.0990ms regardless of
  # the real value. Anchor the substitution to the whole "P50: ...us" match
  # instead of re-scanning it for bare numbers.
  p50_us=$(echo "$line" | grep -oE 'P50: [0-9.,]+us' | sed -E 's/P50: ([0-9.,]+)us/\1/' | tr -d ',' || true)
  p99_us=$(echo "$line" | grep -oE 'P99: [0-9.,]+us' | sed -E 's/P99: ([0-9.,]+)us/\1/' | tr -d ',' || true)
  local p50_ms="" p99_ms=""
  [[ -n "$p50_us" ]] && p50_ms=$(awk -v v="$p50_us" 'BEGIN{printf "%.4f", v/1000}')
  [[ -n "$p99_us" ]] && p99_ms=$(awk -v v="$p99_us" 'BEGIN{printf "%.4f", v/1000}')
  echo "${mps:-PARSE_FAILED},${mbs:-PARSE_FAILED},${p50_ms},,${p99_ms}"
}
parse_redis_output() {
  local f="$1"
  # redis-benchmark --csv -> "test","rps","avg_latency_ms","min_latency_ms","p50_latency_ms","p95_latency_ms","p99_latency_ms","max_latency_ms"
  local row; row=$(tail -1 "$f" | tr -d '"')
  local rps p50 p95 p99
  rps=$(echo "$row" | awk -F',' '{print $2}')
  p50=$(echo "$row" | awk -F',' '{print $5}')
  p95=$(echo "$row" | awk -F',' '{print $6}')
  p99=$(echo "$row" | awk -F',' '{print $7}')
  echo "${rps:-PARSE_FAILED},,${p50:-},${p95:-},${p99:-}"
}

# Runs the full (msg_size x concurrency x repeats) test matrix once against
# one resource config. Called from the cartesian-product loops below —
# NATS_CPUS_PIN/NATS_MEM/NATS_CLIENT_CPUS and
# REDIS_CPUS_PIN/REDIS_MEM/REDIS_IO_THREADS/REDIS_CLIENT_CPUS in
# lib/config.sh are independent arrays, so every combination gets run.
run_config_matrix() {
  local cpus="$1" mem="$2" io_threads="$3"
  validate_cpuset "$cpus"
  CLIENT_CPUS=$(reverse_cpu "$4")
  warn_if_cpu_overlap "$cpus" "$CLIENT_CPUS"
  local cfg_label="cpus${cpus}-mem${mem}"
  [[ "$SYSTEM" == "redis" ]] && cfg_label="${cfg_label}-io${io_threads}"
  cfg_label="${cfg_label}-client${CLIENT_CPUS}"

  echo "[setup] starting ${SYSTEM} server (${TIER}) with config ${cfg_label}"
  podman rm -f nats-server redis-server >/dev/null 2>&1 || true
  # Fresh disk state per resource config too, same reasoning as the pod itself
  # — a config swap shouldn't inherit data written under a different config.
  if [[ "$TIER" == "tier3" ]]; then
    podman volume rm -f "$DATA_VOLUME" >/dev/null 2>&1 || true
    podman volume create "$DATA_VOLUME" >/dev/null
  fi

  if [[ "$SYSTEM" == "nats" ]]; then
    start_nats_server "$cpus" "$mem"
  else
    start_redis_server "$cpus" "$mem" "$io_threads"
  fi

  echo "[setup] warm-up ${TEST_WARMUP_SECONDS}s (discarded)"
  [[ -z "$DRY_RUN" ]] && sleep "$TEST_WARMUP_SECONDS"

  STATS_LOG="${STATS_DIR}/${SYSTEM}-${TIER}-${cfg_label}.csv"
  STATS_PID=$(start_stats_sampler "${SYSTEM}-server" "$STATS_LOG")

  for size in "${TEST_MSG_SIZES[@]}"; do
    for conc in "${TEST_CONCURRENCY[@]}"; do
      for idx in $(seq 1 "$TEST_REPEATS"); do
        run_id="${SYSTEM}-${TIER}-${cfg_label}-s${size}-c${conc}-r${idx}"
        raw_log="${RESULTS_DIR}/${run_id}.log"
        echo "[run] ${run_id}"
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        t_start=$(date +%s.%N)

        if [[ -n "$DRY_RUN" ]]; then
          echo "DRY RUN: would exec bench for ${run_id}" | tee "$raw_log" >/dev/null
          parsed="0,0,,,"
        else
          if [[ "$SYSTEM" == "nats" ]]; then
            run_nats_bench "$size" "$conc" "$idx" "$raw_log"
            parsed=$(parse_nats_output "$raw_log")
          else
            run_redis_bench "$size" "$conc" "$idx" "$raw_log"
            parsed=$(parse_redis_output "$raw_log")
          fi
        fi

        t_end=$(date +%s.%N)
        elapsed=$(awk -v a="$t_start" -v b="$t_end" 'BEGIN{printf "%.3f", b-a}')

        echo "${ts},${SYSTEM},${TIER},${cpus},${mem},${io_threads},${CLIENT_CPUS},${size},${conc},${idx},${elapsed},${parsed},${raw_log}" >> "$CSV_FILE"
      done
    done
  done

  echo "[done] resource stats in $STATS_LOG"
  stop_stats_sampler "$STATS_PID"
  STATS_PID=""
  podman rm -f "${SYSTEM}-server" >/dev/null 2>&1 || true
}

if [[ "$SYSTEM" == "nats" ]]; then
  for cpus in "${NATS_CPUS_PIN[@]}"; do
    for mem in "${NATS_MEM[@]}"; do
      for client_cpus in "${NATS_CLIENT_CPUS[@]}"; do
        run_config_matrix "$cpus" "$mem" "" "$client_cpus"
      done
    done
  done
else
  for cpus in "${REDIS_CPUS_PIN[@]}"; do
    for mem in "${REDIS_MEM[@]}"; do
      for io_threads in "${REDIS_IO_THREADS[@]}"; do
        for client_cpus in "${REDIS_CLIENT_CPUS[@]}"; do
          run_config_matrix "$cpus" "$mem" "$io_threads" "$client_cpus"
        done
      done
    done
  done
fi

echo "[done] results appended to $CSV_FILE"
