pragma circom 2.0.0;

// merkle_verify.circom
// Amach Health ZK — Phase 4
//
// Template: MerklePathVerify
// Verifies that a given leaf opens to the committed Merkle root
// via a provided authentication path (siblings + indices).
//
// Parameters:
//   depth — tree depth (compile-time constant).
//           For v1: depth=8 supports up to 256 leaves.
//
// Inputs:
//   leaf         — Poseidon hash of the serialized leaf
//   path[depth]  — sibling hashes at each level, from leaf up to root
//   indices[depth] — 0 if current node is left child, 1 if right child
//   root         — the committed Merkle root (public input)
//
// The circuit enforces: recomputed_root === root
// If any sibling or index is wrong, this constraint fails.

include "../../node_modules/circomlib/circuits/poseidon.circom";

template MerklePathVerify(depth) {
    signal input leaf;
    signal input path[depth];      // sibling hashes, leaf-to-root order
    signal input indices[depth];   // 0 = node is left child, 1 = node is right child
    signal input root;

    component hashers[depth];
    signal current[depth + 1];
    signal left[depth];
    signal right[depth];
    // Intermediate signals: one multiplication per R1CS constraint (Circom rule)
    signal sel_current[depth];  // current[i] * indices[i]
    signal sel_path[depth];     // path[i]    * indices[i]

    current[0] <== leaf;

    for (var i = 0; i < depth; i++) {
        // indices[i] must be 0 or 1 — enforce boolean
        indices[i] * (1 - indices[i]) === 0;

        // Compute the two products separately (each is one quadratic constraint)
        sel_current[i] <== current[i] * indices[i];
        sel_path[i]    <== path[i]    * indices[i];

        // If indices[i] == 0: left=current, right=path
        // If indices[i] == 1: left=path,    right=current
        // left  = current[i] - sel_current[i] + sel_path[i]
        // right = path[i]    - sel_path[i]    + sel_current[i]
        left[i]  <== current[i] - sel_current[i] + sel_path[i];
        right[i] <== path[i]    - sel_path[i]    + sel_current[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== left[i];
        hashers[i].inputs[1] <== right[i];

        current[i + 1] <== hashers[i].out;
    }

    // The path must open to the committed root
    root === current[depth];
}
