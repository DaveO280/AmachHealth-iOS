pragma circom 2.0.0;

// merkle_inclusion.circom
// Amach Health ZK — Verification Factory primitive
//
// Template: MerkleInclusion(depth)
// Verifies that `leaf` opens to `root` via the provided authentication path
// (sibling hashes + 0/1 direction bits at each level).
//
// This is the canonical Merkle inclusion primitive for Amach circuits. It is
// a clean copy of the v1 `MerklePathVerify` template from
// `circuits/coverage/merkle_verify.circom`, lifted out into the primitives
// library (`zk/primitives/`) so all claim circuits share one source of truth.
//
// Hash function: Poseidon(2) at every internal node — matches
// `zk/scripts/build_tree.js` and `AmachHealth/Sources/Services/MerkleTreeBuilder.swift`.
// If you change the hash here you MUST change it in both producers, or proofs
// will silently fail to verify.
//
// Inputs:
//   leaf            Poseidon hash of the serialized leaf (a field element)
//   root            committed Merkle root (typically a public input)
//   path[depth]     sibling hashes at each level, leaf-to-root order
//   indices[depth]  0 = current node is the LEFT child, 1 = current node is RIGHT
//
// The circuit enforces: recomputed_root === root.

include "../../node_modules/circomlib/circuits/poseidon.circom";

template MerkleInclusion(depth) {
    signal input leaf;
    signal input root;
    signal input path[depth];
    signal input indices[depth];

    component hashers[depth];
    signal current[depth + 1];
    signal left[depth];
    signal right[depth];

    // Quadratic-constraint helpers for the swap (one multiplication per signal).
    signal sel_current[depth];
    signal sel_path[depth];

    current[0] <== leaf;

    for (var i = 0; i < depth; i++) {
        // indices[i] must be 0 or 1
        indices[i] * (1 - indices[i]) === 0;

        sel_current[i] <== current[i] * indices[i];
        sel_path[i]    <== path[i]    * indices[i];

        // indices[i] == 0: left = current,    right = path
        // indices[i] == 1: left = path,       right = current
        left[i]  <== current[i] - sel_current[i] + sel_path[i];
        right[i] <== path[i]    - sel_path[i]    + sel_current[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== left[i];
        hashers[i].inputs[1] <== right[i];

        current[i + 1] <== hashers[i].out;
    }

    root === current[depth];
}
