# NATS JetStream vs Redis Throughput Benchmark

Podman-based throughput/latency comparison between NATS (Core + JetStream) and
Redis (PUBLISH + Streams), run as rootless Podman pods on a single machine.

## Design

The comparison is split into three durability tiers so JetStream and Redis are
never compared across mismatched guarantees:

| Tier | NATS | Redis | What it measures |
|---|---|---|---|
| **tier1** | Core NATS pub (no JetStream) | `PUBLISH` | No-durability, fire-and-forget ceiling for both systems |
| **tier2** | JetStream, memory-storage stream | Streams (`XADD`), no AOF | Durable messaging, single node, no disk I/O |
| **tier3** | JetStream, file-storage stream on a **real disk-backed volume** | Streams + AOF (`appendfsync everysec`) on the **same real disk-backed volume** | Production-realistic durability, including actual fsync cost |

Tier3 deliberately uses a real disk-backed Podman volume rather than tmpfs —
that trades some benchmark isolation (you're now partly measuring host disk
speed) for realism (tmpfs has no fsync cost and no capacity ceiling tied to
disk, so it understates what tier3 is supposed to represent).

Tier1 measures `PUBLISH`/`bench pub` only, without a subscriber — this
matches Redis `PUBLISH`'s fire-and-forget semantics (command-completion
throughput, not confirmed-delivery throughput), keeping both sides
apples-to-apples.

### Environment decisions this encodes

- **Rootless Podman.** Requires `cpuset` delegated to the user cgroup slice
  (Arch's systemd default only delegates `pids memory cpu`). If
  `podman run --cpuset-cpus` fails with a cgroup controller error, add:
  ```
  sudo mkdir -p /etc/systemd/system/user@.service.d
  sudo tee /etc/systemd/system/user@.service.d/delegate.conf <<'EOF'
  [Service]
  Delegate=cpuset cpu io memory pids
  EOF
  sudo systemctl daemon-reload
  ```
  then fully log out and back in (a `daemon-reload` alone does not restart
  your already-running user session).
- **Same-pod networking.** Client and server share a network namespace and
  talk over loopback — this removes Podman's virtual network stack from the
  measurement entirely. It means results are a software throughput ceiling,
  not a real multi-host network measurement.
- **Strictly sequential execution.** Both systems run on the same machine, so
  they never run concurrently — each `run.sh` invocation fully tears down its
  pod (and, for tier3, its data volume) before the next one starts, to avoid
  CPU/cache/memory-bandwidth contention between the two systems under test.

## Usage

Run one (system, tier) combination:
```bash
./run.sh nats tier1
./run.sh nats tier2
./run.sh nats tier3
./run.sh redis tier1
./run.sh redis tier2
./run.sh redis tier3
```

Run all six, sequentially, in one go:
```bash
./run_all.sh
```

Results append to `results/results.csv` across runs (the header is written
once). Delete it first if you want a clean slate.

## Configuration

All tunables live in `lib/config.sh`:

| Variable | Purpose |
|---|---|
| `NATS_IMAGE` / `NATS_BOX_IMAGE` / `REDIS_IMAGE` | Pinned image tags |
| `NATS_CPUS_PIN` / `NATS_MEM` / `NATS_CLIENT_CPUS` | Nats Environment Matrix — arrays swept as a full cartesian product for NATS. `NATS_MEM` must exceed `TEST_MSG_COUNT x max(TEST_MSG_SIZES)` |
| `REDIS_CPUS_PIN` / `REDIS_MEM` / `REDIS_IO_THREADS` / `REDIS_CLIENT_CPUS` | Redis Environment Matrix, same shape plus `IO_THREADS` — socket read/write parallelism only, command execution is always single-threaded regardless. `1` = upstream default (disabled) |
| `NATS_TEST_STREAM_CAP` | JetStream stream byte cap — must exceed `TEST_MSG_COUNT x max(TEST_MSG_SIZES)`, or the stream rejects publishes mid-run once it fills up (independent of `NATS_MEM`; both have to be raised together) |
| `TEST_MSG_SIZES` / `TEST_CONCURRENCY` / `TEST_MSG_COUNT` / `TEST_REPEATS` | The test matrix |
| `TEST_WARMUP_SECONDS` | Discarded warm-up time after server start, before any measured run |

**If you raise `TEST_MSG_COUNT` or `TEST_MSG_SIZES`**, raise every value in
`NATS_MEM`/`REDIS_MEM` and `NATS_TEST_STREAM_CAP` to match — all are sized
for the current matrix's worst case, not enforced dynamically.

### Sweeping CPU/memory/IO allocation

The Nats/Redis Environment Matrix blocks in `lib/config.sh` are independent
arrays, not paired tuples — `run.sh` runs the full msg_size x concurrency x
repeats matrix once for **every combination** of `CPUS_PIN x MEM x
CLIENT_CPUS` (plus `IO_THREADS` for Redis), restarting the server fresh
(and, for tier3, resetting its data volume) between combinations:
```bash
NATS_CPUS_PIN=(0 0-3 0-7)   # server cpuset
NATS_MEM=(20g)              # server memory limit
NATS_CLIENT_CPUS=(0)        # benchmark client cpuset (reverse-indexed, see below)

REDIS_CPUS_PIN=(0 0-3)      # server cpuset
REDIS_MEM=(20g)             # server memory limit
REDIS_IO_THREADS=(1 4)      # io-threads count
REDIS_CLIENT_CPUS=(0)       # benchmark client cpuset (reverse-indexed, see below)
```
This is the place to widen a cpuset and test, e.g., whether NATS actually
benefits from more cores while Redis doesn't — this repo already sweeps
1/4/8-core cpusets for NATS and 1/4-core with io-threads on/off for Redis.
Adding a value to any array (e.g. `NATS_MEM+=(4g)`) multiplies the total
number of configs run, so grow these deliberately.

`*_CLIENT_CPUS` entries are reverse-indexed from the host's last core rather
than an absolute cpuset — `0` resolves to `nproc-1` (e.g. CPU 15 on a
16-core host), `1` to the second-to-last core, and so on (see
`reverse_cpu()` in `lib/config.sh`). This keeps the benchmark client pinned
away from the server automatically as `*_CPUS_PIN` sweeps wider (e.g.
`0-7`), without having to hardcode a client core that might collide with a
larger server cpuset on a different host.

The two systems are *not* equivalent in effect from the same-looking config:
NATS (Go) schedules goroutines across every core it's given, so widening its
cpuset can translate into real throughput gains. Redis's command execution
is single-threaded no matter how many CPUs it's granted — only
`IO_THREADS` (socket I/O parallelism, not command processing) lets it touch
more than one core at all, and even then only for the network-facing part of
its work. Keep that asymmetry in mind before treating "same cpuset for both"
as "equal opportunity for both." Each config's rows in `results.csv` and its
own `results/stats/<system>-<tier>-<config-label>.csv` file let you compare
configs directly.

## Output

### `results/results.csv`

| Column | Meaning |
|---|---|
| `timestamp` | UTC start time of the run |
| `system` | `nats` or `redis` |
| `tier` | `tier1` / `tier2` / `tier3` |
| `cpus` | cpuset the server was pinned to for this row's resource config |
| `mem` | memory limit the server was given for this row's resource config |
| `io_threads` | Redis I/O thread count for this row's resource config; always blank for `nats` rows (not applicable) |
| `client_cpus` | cpuset the benchmark client was pinned to for this row's resource config |
| `msg_size` | payload size in bytes |
| `concurrency` | parallel client count |
| `run_index` | repeat number for that (size, concurrency) cell |
| `duration_s` | actual measured wall-clock time for the run |
| `throughput_msgs_sec` | messages/sec |
| `throughput_mb_sec` | MB/sec, normalized to binary MiB regardless of the tool's auto-scaled unit (nats bench reports B/KiB/MiB/GiB depending on magnitude) |
| `p50_ms` / `p95_ms` / `p99_ms` | latency percentiles in ms |
| `raw_log` | path to that run's full raw tool output (kept for debugging/reparsing) |

**Caveat:** `nats bench` only exposes P50/P90/P99/P99.9; `redis-benchmark`
only exposes p50/p95/p99. There's no shared P95, so `p95_ms` is always blank
for `nats` rows rather than mislabeling P90 as P95.

### `results/stats/<system>-<tier>-<config-label>.csv`

Background resource-usage sampler, polling the server container every 5s
during each resource config's run: `cpu_perc`, `mem_usage`, `net_io`,
`block_io`. This is contextual data to help explain *why* throughput lands
where it does (e.g. CPU-bound during AOF fsync, or a Redis config pinned to
4 cores still showing ~100% on one), not the benchmark result itself.

## Tool quirks this script works around

Verified against `nats-server:2.14.3`, `natscli` in `nats-box:latest`, and
`redis:8.8.0`, as of 2026-07:

- `nats bench` no longer takes a combined `<subject> --pub --sub` form — it's
  separate subcommands (`nats bench pub`, `nats bench js pub sync`, etc.).
- `nats bench`'s own `--csv` flag writes inside the ephemeral client
  container and is lost when it exits (`--rm`) — this script parses the
  stdout summary line instead.
- `redis-benchmark -t publish` is not a recognized built-in test name in this
  version and silently produces no output. Custom-command syntax
  (`redis-benchmark ... PUBLISH <chan> <payload>`, no `--` separator) is what
  actually works.
- `podman stats` on this Podman version has no `--filter` flag — it only
  accepts explicit container names as positional arguments.
