# Metric Pointers — AmachLeafV2

Canonical mapping from human-readable metric names to byte offsets in the
124-byte `AmachLeafV2` serialization. The `metricPointer` public input to
`AverageImprovementProof` MUST equal one of these byte offsets, and the
circuit's compile-time constants `METRIC_CHUNK_IDX` and
`METRIC_BYTE_OFFSET_IN_CHUNK` MUST decode to the same offset
(`chunkIdx * 31 + offsetInChunk == metricPointer`). This is enforced by the
circuit and is the load-bearing assertion for the verification factory:
the metric a verifier-contract addresses is exactly the metric the proof
covers.

## Table

The byte offsets below come from `AmachHealth/Sources/Models/AmachLeafV2.swift`
and are unit-tested by `zk/scripts/__tests__/v2_test_vectors.js`.

All metrics listed are 16-bit unsigned big-endian integers (u16).

| Metric          | Byte offset | Chunk index | Offset-in-chunk | Storage scaling |
|-----------------|-------------|-------------|------------------|-----------------|
| exerciseMins    | 50          | 1           | 19               | 1× minutes |
| hrv             | 52          | 1           | 21               | 10× ms (412 = 41.2 ms) |
| restingHR       | 54          | 1           | 23               | 10× bpm (560 = 56.0 bpm) |
| sleepMins       | 56          | 1           | 25               | 1× minutes |
| vo2max          | 64          | 2           | 2                | 10× ml/kg/min (425 = 42.5) |
| weight          | 66          | 2           | 4                | 100× kg (7800 = 78.00 kg) |
| bodyFatPct      | 68          | 2           | 6                | 100× % (1850 = 18.50 %) |
| leanMass        | 70          | 2           | 8                | 100× kg (6300 = 63.00 kg) |
| deepSleepMins   | 72          | 2           | 10               | 1× minutes |
| remSleepMins    | 74          | 2           | 12               | 1× minutes |
| lightSleepMins  | 76          | 2           | 14               | 1× minutes |
| awakeMins       | 78          | 2           | 16               | 1× minutes |

## Why scaling matters for the improvement equation

`SignedImprovementCheck` works in basis points: `1234 = 12.34 %`. Because
improvement is a *ratio* of two values stored at the same scale, the
multiplicative factor cancels out:

```
   improvement_pct = (finish - baseline) / baseline
                   = (finish*scale - baseline*scale) / (baseline*scale)
                   = (storedFinish - storedBaseline) / storedBaseline
```

So the circuit can use the stored u16 values directly without
re-scaling. The legitimacy script (Layer 1) and the v2 leaf format (Layer 0)
are the single sources of truth on scaling — Layer 2 just consumes their
encoded values.

## Adding a new metric

1. Add the field to `AmachLeafV2.swift` (and the JS / TS mirrors).
2. Update `zk/scripts/__tests__/v2_test_vectors.js` with the new offset.
3. Add a row above.
4. Compile a new instantiation of `AverageImprovementProof` with the
   corresponding `(METRIC_CHUNK_IDX, METRIC_BYTE_OFFSET_IN_CHUNK)`.
5. Run a fresh Phase 2 ceremony, regenerate the verifier, deploy.

The four primitives stay unchanged across metrics — only the verifier
contract is per-metric.

## Multi-metric circuit ?

A "one circuit, all metrics" alternative would expose `metricPointer` as a
true runtime input and use a multiplexer to read any of the 248 chunk-bit
positions. The cost (~16 mults × 4 chunks per leaf, plus an `IsEqual`
selector for chunk index) puts the per-leaf budget over 1.3 k, knocking
N=M=2 over the 20 k constraint target without buying anything in practice
— there are only 12 valid metric positions and they don't change after
schema commit. We ship per-metric verifiers instead.
