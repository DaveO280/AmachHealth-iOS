# Amach ZK Primitives

The shared Circom primitives that Amach claim circuits compose.

```
zk/primitives/
├── merkle_inclusion/        Poseidon(2) Merkle authentication path
├── metric_extraction/       Poseidon4 leaf-bind + 16-bit metric byte read
├── average_computation/     N-element sum (linear-only)
└── threshold_comparison/    Signed improvement equation + range-checked equality
```

Each subdirectory is a self-contained primitive: a `.circom` file, a
README, and (optionally) tests. Primitives are imported via relative path:

```circom
include "../../primitives/merkle_inclusion/merkle_inclusion.circom";
```

## Why primitives at all

Per VERIFICATION_FACTORY.md's "Circuit Library" section, every claim
circuit Amach ships will need at minimum:

- Merkle inclusion against an Amach-committed root,
- some way to read structured fields out of the v2 leaf,
- some math over those fields (averages, sums, thresholds, ratios),
- some honesty constraint at the end (equality, comparison, sign).

Pulling those out of `coverage.circom` and `improvement.circom` and
sharing them via a primitives library means:

- One source of truth for hash-binding constants (Poseidon(2) at
  internal nodes, Poseidon4 at leaves), so a future hash-function swap
  doesn't have to rewrite every claim circuit.
- One source of truth for the "v2 leaf chunk → field element" encoding,
  so adding a new metric only changes its byte offset, not the way the
  byte read works.
- Clean READMEs per primitive, so a new claim-circuit author can read
  the four sub-readmes in order and have everything they need.

## Primitive contracts

| Primitive                | Inputs                                    | Output / assertion |
|--------------------------|--------------------------------------------|--------------------|
| `MerkleInclusion(d)`     | `leaf`, `root`, `path[d]`, `indices[d]`   | asserts recomputed root === root |
| `MetricExtraction(c, o)` | `chunks[4]`, `leafHash`                    | output `metricValue` (u16) and asserts Poseidon4(chunks)===leafHash |
| `AverageComputation(N)`  | `values[N]`                                | output `sum`, `n` |
| `SignedImprovementCheck(b)` | `baselineSum`, `baselineN`, `finishSum`, `finishM`, `claimedMagnitude`, `signFlag` | asserts the improvement equation |
| `ThresholdEqual(b)`      | `actual`, `claimed`                        | asserts equality with range check |

## Constraint costs (BN-128, circomlib)

| Primitive                   | Constraints |
|-----------------------------|-------------|
| `Poseidon(2)`               | 517 |
| `Poseidon(4)`               | 736 |
| `Num2Bits(248)`             | 248 |
| `MerkleInclusion(d)`        | ≈ 522·d |
| `MetricExtraction(c, o)`    | ≈ 986 |
| `AverageComputation(N)`     | N − 1 |
| `SignedImprovementCheck(64)`| ≈ 140 |

Use these as a budgeting reference when sizing a new claim circuit.

## Hash binding

Two hash functions across the v2 stack:

- **Leaf hash**: Poseidon4 over the four 31-byte chunks. Implemented in
  Swift (`AmachLeafV2.swift`), JS (`hash_leaf.js::hashLeafV2`), and TS
  (`@amach/legitimacy/src/leaf.ts`).
- **Internal Merkle node hash**: Poseidon(2). Implemented in JS
  (`build_tree.js`) and Swift (`MerkleTreeBuilder.swift`).

If any of those producers diverges from the primitives, proofs silently
fail to verify. There is no error path — the verifier just returns
`false`. Any change to the hashing path requires updating ALL three
implementations + the primitives + cross-platform test vectors
(`zk/scripts/__tests__/v2_test_vectors.js`).
