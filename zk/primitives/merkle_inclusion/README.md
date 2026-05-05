# MerkleInclusion

Canonical Merkle inclusion primitive for Amach claim circuits.

```circom
include "../../primitives/merkle_inclusion/merkle_inclusion.circom";

component check = MerkleInclusion(8);     // depth = 8
check.leaf <== leafHash;
check.root <== publicRoot;
for (var i = 0; i < 8; i++) {
  check.path[i]    <== siblingHashes[i];
  check.indices[i] <== directionBits[i];
}
```

## What it proves

That `leaf` is one of the leaves whose Poseidon binary tree root is `root`.

## Hash binding

Internal nodes are hashed with `Poseidon(2)` (circomlib). This must match the
JS / Swift Merkle tree builders (`zk/scripts/build_tree.js`,
`AmachHealth/Sources/Services/MerkleTreeBuilder.swift`). If any of the three
diverges, proofs will silently fail to verify — there is no error path.

## Constraint cost

Approximately `depth * ~522` constraints (Poseidon(2) ≈ 517 plus three
swap-arithmetic signals per level). Measured at depth=10: 5,220 constraints.

## Caveats

`MerkleInclusion` does NOT bind the *content* of the leaf — only its hash.
Higher-level circuits that rely on specific fields inside the leaf must
either (a) take those fields as a witness and trust them (the
`CoverageProof`-style "weak binding" pattern, with the gap documented), or
(b) supply the chunked field elements and recompute `Poseidon4(chunks)`
in-circuit, then bit-decompose to extract the field. (b) is the
strong-binding option; it costs an extra ~736 (Poseidon4) +
~248 (Num2Bits) constraints per leaf.

`AverageImprovementProof` currently uses (a). See its README for the
hardening path.
