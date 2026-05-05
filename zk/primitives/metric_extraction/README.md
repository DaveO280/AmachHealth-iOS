# MetricExtraction

Strong-binding metric extractor for the 124-byte AmachLeafV2 format.

```circom
include "../../primitives/metric_extraction/metric_extraction.circom";

// VO2 max sits at byte offset 64 (chunk 3 = bytes 62..92, offset-in-chunk 2).
component vo2 = MetricExtraction(2, 2);
for (var i = 0; i < 4; i++) {
  vo2.chunks[i] <== leafChunks[i];     // big-endian field encoding from hash_leaf.js
}
vo2.leafHash <== publicLeafHash;       // committed Poseidon4 hash
signal vo2maxValue;
vo2maxValue <== vo2.metricValue;       // u16, range [0, 2^16)
```

## What it proves

1. The four chunks really are the chunks of the leaf whose hash is
   `leafHash`. (`Poseidon4(chunks) === leafHash`.)
2. `metricValue` is the big-endian u16 at byte offset
   `chunkIndex * 31 + byteOffsetInChunk` within the 124-byte serialization.

This binds the *content* of a specific 16-bit metric field to the on-chain
commitment, with no trust in the prover beyond cryptographic assumptions.

## Compile-time parameters

The `chunkIndex` (0..3) and `byteOffsetInChunk` (0..29) are *compile-time
constants*. To support multiple metrics at runtime, the parent circuit
must either:

- compile a separate verifier per metric (the verification-factory pattern —
  one circuit template, multiple instantiations); OR
- expose the metric value but not its binding to a specific byte offset
  (the weak-binding pattern, see the parent README's "binding model"
  discussion).

`AverageImprovementProof` uses this primitive in its strong-binding
configuration; for ergonomic deployment it ships as a generic template
parameterised by `metricChunkIndex` / `metricByteOffsetInChunk`.

## Constraint cost

~984 constraints per leaf:

| Component            | Constraints |
|----------------------|-------------|
| Poseidon(4) bind     | 736         |
| Num2Bits(248) chunk  | 248         |

Bit reconstruction of the 16-bit value is linear (no extra multiplication
constraints) because the 16 selected bits fold into a single linear
combination assigned to `metricValue`.

## Metric pointer mapping (v2 leaf)

See `zk/circuits/improvement/metric-pointers.md` for the canonical table.
A summary:

| Metric          | Byte offset | Chunk index | Offset-in-chunk |
|-----------------|-------------|-------------|------------------|
| exerciseMins    | 50          | 1           | 19               |
| hrv             | 52          | 1           | 21               |
| restingHR       | 54          | 1           | 23               |
| sleepMins       | 56          | 1           | 25               |
| vo2max          | 64          | 2           | 2                |
| weight          | 66          | 2           | 4                |
| bodyFatPct      | 68          | 2           | 6                |
| leanMass        | 70          | 2           | 8                |
| deepSleepMins   | 72          | 2           | 10               |
| remSleepMins    | 74          | 2           | 12               |
| lightSleepMins  | 76          | 2           | 14               |
| awakeMins       | 78          | 2           | 16               |

Byte-offset values come from `AmachLeafV2.swift` and are unit-tested in
`zk/scripts/__tests__/v2_test_vectors.js`.
