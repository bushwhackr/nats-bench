#!/usr/bin/env bash
# Shared config for NATS JetStream vs Redis throughput benchmarks.
# Every value here must stay identical across the two systems under test —
# that parity is the entire point of the comparison.

# --- Images (pinned to latest stable as of 2026-07) ---
NATS_IMAGE="docker.io/library/nats:2.14.3-alpine3.22"
NATS_BOX_IMAGE="docker.io/natsio/nats-box:latest"   # provides `nats` CLI + `nats bench`
REDIS_IMAGE="docker.io/library/redis:8.8.0-alpine3.23"  # also provides redis-benchmark/redis-cli

# CLIENT_CPUS arrays below are reverse-indexed from the host's last core —
# 0 = last core (nproc-1), 1 = second-to-last, etc. (e.g. 0 -> CPU 15 on a
# 16-core host, CPU 7 on an 8-core host). This keeps the benchmark client
# pinned away from the server no matter how wide a CPUS_PIN entry grows,
# without needing to know the host's core count up front. See
# `reverse_cpu()` below for the resolution.

# --- Nats Environment Matrix ---
# Swept as a full cartesian product (every CPUS_PIN x every MEM x every
# CLIENT_CPUS) — nats-server is restarted fresh for each combination. NATS
# (Go) schedules goroutines across every core it's given, so widening
# NATS_CPUS_PIN can translate into real throughput gains.
NATS_CPUS_PIN=(0 0-3 0-7)   # server cpuset
# NATS_MEM must clear more than just TEST_MSG_COUNT x max(TEST_MSG_SIZES):
# run.sh sets GOMEMLIMIT to 80% of this, and nats-server's own JetStream
# memory-store admission control defaults to 75% of GOMEMLIMIT (see run.sh
# start_nats_server comment) -- so only ~60% of NATS_MEM is actually usable
# stream budget. That 60% must clear NATS_TEST_STREAM_CAP with margin.
#
# Capped at 16g here (this host has 30GB total RAM and needs headroom for
# the OS, podman, and the benchmark client) instead of the previously
# validated 34g. 34g/20GB-cap/200000-count was confirmed empirically (25g
# and 20g both OOM'd or failed stream creation); 16g has NOT been
# separately re-validated the same way. NATS_TEST_STREAM_CAP and
# TEST_MSG_COUNT below were scaled down by the same 16/34 ratio to
# reproduce the same safety margins (~13% budget-to-cap headroom, ~35%
# cap-to-actual-data headroom) — if tier2 still OOMs on this host, shrink
# TEST_MSG_COUNT further before assuming NATS itself is at fault. Sweep
# width still comes entirely from NATS_CPUS_PIN above (0 / 0-3 / 0-7) —
# memory stays fixed per run so scaling is by CPU count only. REDIS_MEM is
# kept identical for comparison parity even though Redis has no equivalent
# internal accounting quirk and doesn't need the headroom.
NATS_MEM=(16g)              # server memory limit
NATS_CLIENT_CPUS=(0)        # benchmark client cpuset, reverse-indexed (0 = last core)

# --- Redis Environment Matrix ---
# Same shape, plus IO_THREADS. Unlike NATS, Redis's command execution is
# always single-threaded no matter how many cores REDIS_CPUS_PIN grants it —
# IO_THREADS only parallelizes socket I/O (reading/writing the wire
# protocol), never command processing. 1 = upstream default (disabled).
REDIS_CPUS_PIN=(0-7)        # server cpuset -- TEMP: narrowed to backfill the missing 8-core config only; restore to (0 0-3 0-7) after this run
REDIS_MEM=(16g)             # server memory limit; kept identical to NATS_MEM for parity
REDIS_IO_THREADS=(1 4)      # io-threads count
REDIS_CLIENT_CPUS=(0)       # benchmark client cpuset, reverse-indexed (0 = last core)

# Resolves a reverse-indexed CLIENT_CPUS entry (0 = last core) to an actual
# cpuset value based on the host's total core count. Fails loudly rather
# than silently emitting a negative/invalid cpuset if the offset asks for
# more cores than the host has.
reverse_cpu() {
  local offset="$1"
  local total; total=$(nproc)
  if (( offset < 0 || offset >= total )); then
    echo "ERROR: CLIENT_CPUS offset ${offset} is out of range for a ${total}-core host (valid: 0-$((total - 1)))" >&2
    exit 1
  fi
  echo "$(( total - 1 - offset ))"
}

# Validates a server cpuset string (e.g. "0" or "0-7") doesn't reference
# more cores than the host actually has — podman/crun's own error for this
# is not always clear, so fail fast with the actual host core count.
validate_cpuset() {
  local spec="$1"
  local total; total=$(nproc)
  local max_core="${spec#*-}"
  if (( max_core > total - 1 )); then
    echo "ERROR: cpuset '${spec}' references core ${max_core} but this host only has ${total} cores (valid: 0-$((total - 1)))" >&2
    exit 1
  fi
}

# Warns (does not fail) if the resolved client core falls inside the
# server's own cpuset — that would mean client and server compete for the
# same core, undermining the "client never competes with server" design.
warn_if_cpu_overlap() {
  local server_spec="$1" client_cpu="$2"
  local lo="${server_spec%-*}" hi="${server_spec#*-}"
  if (( client_cpu >= lo && client_cpu <= hi )); then
    echo "[warn] client core ${client_cpu} overlaps server cpuset '${server_spec}' — client and server will compete for the same core" >&2
  fi
}

# JetStream stream byte cap (tier2/tier3) — must exceed TEST_MSG_COUNT x max(TEST_MSG_SIZES)
# or the stream rejects publishes mid-run once it fills up (see run.sh).
# Scaled down from 20GB in step with NATS_MEM's 34g -> 16g cut (see comment
# above NATS_MEM) to preserve the same usable-budget headroom.
NATS_TEST_STREAM_CAP="9GB"

# --- Test matrix ---
TEST_MSG_SIZES=(128 1024 8192 65536)      # bytes
TEST_CONCURRENCY=(1 10 50)                # parallel pub/sub or client connections
# Scaled down from 200000 in step with NATS_MEM's 34g -> 16g cut (see
# comment above NATS_MEM) so the largest size x count (65536B x 90000 =~
# 5.9GB) still clears NATS_TEST_STREAM_CAP with the same ~35% margin as
# before.
TEST_MSG_COUNT=90000                      # per run, scaled down for small sizes if needed
TEST_WARMUP_SECONDS=15
TEST_REPEATS=5

# --- Tiers ---
# tier1: no durability    (Core NATS pub/sub   vs Redis PUBLISH)
# tier2: durable, memory  (JetStream mem store vs Redis no-AOF)
# tier3: durable, disk    (JetStream file store on a real disk-backed podman
#                          volume vs Redis AOF everysec on the same) — real
#                          disk instead of tmpfs so tier3 reflects actual
#                          production durability (fsync cost, no RAM ceiling)
#                          rather than isolating storage-code-path overhead
TIERS=(tier1 tier2 tier3)

RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"
CSV_FILE="${RESULTS_DIR}/results.csv"
STATS_DIR="${RESULTS_DIR}/stats"
