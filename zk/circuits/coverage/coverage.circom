pragma circom 2.0.0;

// coverage.circom
// Amach Health ZK — Phase 5
//
// CoverageProof circuit: proves that at least k valid days exist in a date
// range [start_day_id, end_day_id] under the committed Merkle root, AND
// that each of those days has the required health metrics present.
//
// Compile-time parameters:
//   k     — number of days to prove (60 for "60+ active days per window")
//   depth — Merkle tree depth (10 supports up to 1024 leaves / ~3 years)
//
// Public inputs (known to verifier):
//   root           — the Merkle root committed on-chain
//   start_day_id   — beginning of the claimed date range (inclusive)
//   end_day_id     — end of the claimed date range (inclusive)
//   min_days       — minimum days claimed (must equal k at runtime)
//   required_flags — 16-bit mask of required metric presence bits
//                    (0x0039 = bits 0,3,4,5 = Steps, HRV, Resting HR, Sleep)
//
// Private witness (known only to prover):
//   leaf_day_ids[k]       — day_id values of k valid days
//   leaf_hashes[k]        — Poseidon hashes of those k leaves
//   leaf_data_flags[k]    — 16-bit dataFlags value from each leaf (bytes 56-57)
//   merkle_paths[k][depth] — sibling hashes for each leaf's Merkle path
//   path_indices[k][depth] — 0/1 direction bits for each path
//
// What the circuit proves:
//   1. Each leaf_day_id is within [start_day_id, end_day_id]
//   2. Each leaf_hash opens correctly to root via its Merkle path
//   3. All k day_ids are distinct (no double-counting a day)
//   4. min_days == k (public parameter binding)
//   5. For each leaf, (leaf_data_flags & required_flags) == required_flags
//
// Note on range checks:
//   Circom doesn't natively check a < b for field elements.
//   We use the Num2Bits approach with a 32-bit range decomposition.
//   day_ids are uint32 (max ~4.3B), safely within 32-bit range.
//
// Note on dataFlags binding:
//   leaf_data_flags[i] is a private witness alongside leaf_hashes[i].
//   Both are committed to the same Merkle leaf by an honest prover.
//   A future upgrade should compute the leaf hash in-circuit from raw fields
//   to cryptographically bind leaf_data_flags to leaf_hashes.

include "./merkle_verify.circom";
include "../../node_modules/circomlib/circuits/comparators.circom";
include "../../node_modules/circomlib/circuits/bitify.circom";

// ─────────────────────────────────────────────────
// Helper: assert a <= b for 32-bit unsigned values
// ─────────────────────────────────────────────────
template LessEqUint32() {
    signal input a;
    signal input b;

    // LessEqThan(n) from circomlib checks a <= b for n-bit values
    component cmp = LessEqThan(32);
    cmp.in[0] <== a;
    cmp.in[1] <== b;
    cmp.out === 1;
}

// ─────────────────────────────────────────────────
// Main coverage proof template
// ─────────────────────────────────────────────────
template CoverageProof(k, depth) {
    // ── Public inputs ──────────────────────────────
    signal input root;
    signal input start_day_id;
    signal input end_day_id;
    signal input min_days;       // must equal k (compile-time binding check)
    signal input required_flags; // 16-bit metric presence mask (e.g. 0x0039)

    // ── Private witness ────────────────────────────
    signal input leaf_day_ids[k];
    signal input leaf_hashes[k];
    signal input leaf_data_flags[k];    // raw dataFlags per leaf (16-bit, bytes 56-57)
    signal input merkle_paths[k][depth];
    signal input path_indices[k][depth];

    // ── Constraint 1: min_days must equal k ────────
    // This binds the public claim to the circuit's compile-time k.
    // Prevents a malicious prover from using a circuit compiled with
    // a different k than advertised in the public signal.
    min_days === k;

    // ── Constraint 2: day range validity ───────────
    // start_day_id <= end_day_id
    component rangeValid = LessEqUint32();
    rangeValid.a <== start_day_id;
    rangeValid.b <== end_day_id;

    // ── Constraint 3: each leaf is in range + valid path ──
    component pathVerifiers[k];
    component lowerBounds[k];
    component upperBounds[k];

    for (var i = 0; i < k; i++) {
        // 3a: leaf_day_ids[i] >= start_day_id
        lowerBounds[i] = LessEqUint32();
        lowerBounds[i].a <== start_day_id;
        lowerBounds[i].b <== leaf_day_ids[i];

        // 3b: leaf_day_ids[i] <= end_day_id
        upperBounds[i] = LessEqUint32();
        upperBounds[i].a <== leaf_day_ids[i];
        upperBounds[i].b <== end_day_id;

        // 3c: Merkle path opens to root
        pathVerifiers[i] = MerklePathVerify(depth);
        pathVerifiers[i].leaf <== leaf_hashes[i];
        pathVerifiers[i].root <== root;
        for (var j = 0; j < depth; j++) {
            pathVerifiers[i].path[j]    <== merkle_paths[i][j];
            pathVerifiers[i].indices[j] <== path_indices[i][j];
        }
    }

    // ── Constraint 4: all leaf_day_ids are distinct ──
    // For k=60, this is 60*59/2 = 1770 pairwise checks.
    // Each pair: (a - b) * inv == 1, where inv = 1/(a-b) provided by prover.
    // If a == b, no valid inv exists (0 has no inverse in the field).
    // Signals must be declared at template scope, not inside loops (Circom 2.x rule).
    signal diffs[k][k];
    signal inv[k][k];

    for (var i = 0; i < k; i++) {
        for (var j = i + 1; j < k; j++) {
            // Assert leaf_day_ids[i] != leaf_day_ids[j]
            diffs[i][j] <== leaf_day_ids[i] - leaf_day_ids[j];
            inv[i][j] <-- 1 / (leaf_day_ids[i] - leaf_day_ids[j]);
            diffs[i][j] * inv[i][j] === 1;
        }
    }

    // ── Constraint 5: flag coverage per leaf ───────
    // Each leaf must have all required metric bits set.
    // (leaf_data_flags[i] & required_flags) === required_flags
    //
    // Implementation via bit decomposition:
    //   1. Decompose required_flags into 16 bits (also range-checks to [0, 2^16)).
    //   2. Decompose each leaf_data_flags[i] into 16 bits.
    //   3. For each bit j: if required bit j is set, leaf bit j must also be set.
    //      Constraint: reqBit[j] * (1 - leafBit[i][j]) === 0
    //                  (reqBit implies leafBit — bitwise implication)

    component reqFlagBits = Num2Bits(16);
    reqFlagBits.in <== required_flags;

    component leafFlagBits[k];

    for (var i = 0; i < k; i++) {
        leafFlagBits[i] = Num2Bits(16);
        leafFlagBits[i].in <== leaf_data_flags[i];

        for (var j = 0; j < 16; j++) {
            // reqBit * (1 - leafBit) === 0
            // If reqBit == 0: constraint is 0 * (...) = 0 — always satisfied.
            // If reqBit == 1: constraint is 1 * (1 - leafBit) = 0 → leafBit must be 1.
            reqFlagBits.out[j] * (1 - leafFlagBits[i].out[j]) === 0;
        }
    }
}

// ─────────────────────────────────────────────────
// v2 instantiation:
//   k=60:     prove 60 valid days in range
//   depth=10: supports trees up to 1024 leaves (~3 years of daily data)
//
// Public signals: root, start_day_id, end_day_id, min_days, required_flags
//
// Trusted setup note: regenerate .zkey + CoverageVerifier.sol after any
// change to this file. See zk/scripts/rebuild_circuit.sh for the full
// ceremony commands.
// ─────────────────────────────────────────────────
component main {public [root, start_day_id, end_day_id, min_days, required_flags]} = CoverageProof(60, 10);
