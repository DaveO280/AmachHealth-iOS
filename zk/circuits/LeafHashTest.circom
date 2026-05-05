pragma circom 2.0.0;

// LeafHashTest.circom
// Amach Health ZK — Phase 2 Cross-Implementation Check
//
// This circuit takes the three Poseidon input chunks derived from a
// 90-byte leaf serialization, and outputs the Poseidon hash.
//
// Purpose: Verify that the Node.js hash_leaf.js and this Circom circuit
// produce IDENTICAL hashes for the same inputs. This is the Phase 2 gate.
//
// Compile:
//   circom circuits/LeafHashTest.circom --r1cs --wasm --sym -o build/leaf_hash_test
//
// Test (after compile):
//   snarkjs wtns calculate build/leaf_hash_test/LeafHashTest_js/LeafHashTest.wasm \
//     data/leaf_hash_test_input.json build/leaf_hash_test/witness.wtns
//   snarkjs wtns export json build/leaf_hash_test/witness.wtns build/leaf_hash_test/witness.json
//
// Compare the output hash with the values in data/phase2_reference_hashes.json

include "../../zk/node_modules/circomlib/circuits/poseidon.circom";

// Hashes a 90-byte leaf (split into 3 chunks) using Poseidon(3)
template LeafHash() {
    signal input chunk1;   // bytes 0-30 as a field element (31 bytes, big-endian)
    signal input chunk2;   // bytes 31-61 as a field element (31 bytes, big-endian)
    signal input chunk3;   // bytes 62-89 zero-padded to 31 bytes (28 bytes + 3 zero bytes)
    signal output hash;

    component p = Poseidon(3);
    p.inputs[0] <== chunk1;
    p.inputs[1] <== chunk2;
    p.inputs[2] <== chunk3;

    hash <== p.out;
}

component main = LeafHash();
