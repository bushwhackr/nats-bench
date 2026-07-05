# Future Improvements

Additional use cases worth benchmarking beyond the current matrix (Publish +
Stream, KV static, KV with expiry). Not yet implemented — candidates for a
future round.

| Use case | Why it matters | NATS mechanism | Redis mechanism |
|---|---|---|---|
| Work queue / competing consumers | Different code path than plain publish — tests ack/nack, redelivery on failure, and load distribution across multiple workers pulling from the same backlog | JetStream durable consumer (pull-based, `--ack=explicit`) | Streams consumer groups (`XREADGROUP`/`XACK`) |
| Object/blob storage | Common for larger payloads (images, file caching, serialized blobs) — different memory/chunking behavior than small messages | JetStream Object Store | Redis string values (or just large `SET`/`GET`) |
| KV under contention (CAS / optimistic locking) | Tests the distributed-lock pattern — how each system handles concurrent writers racing on the same key | JetStream KV revision-based CAS | `WATCH`/`MULTI` or Lua script |
| Historical replay / cold consumption | Tests reading already-stored data from an offset, not just append throughput — relevant for event-sourcing consumers catching up | JetStream consumer starting from an old sequence/time | `XRANGE` over a Stream |
