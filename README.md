# nats-bench

NATS vs Redis benchmarks, run as rootless Podman pods on a single machine.
Each use case lives in its own top-level folder with its own scripts,
results, and README.

## Use cases

| Folder | Use case |
|---|---|
| [`publish-throughput/`](publish-throughput/README.md) | Publish/append throughput and latency across three durability tiers (no durability, durable in-memory, durable on-disk with fsync) |

See [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) for candidate use cases not yet implemented (work queues, object storage, KV contention, historical replay).
