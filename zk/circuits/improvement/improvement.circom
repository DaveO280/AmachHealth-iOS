pragma circom 2.0.0;

// improvement.circom
// Amach Health ZK — Spring Push Verification Layer 2
//
// AverageImprovementProof: a generic Groth16 circuit that proves a claimed
// average improvement percentage was honestly computed from values committed
// in v2 (124-byte) Merkle leaves.
//
// Composition (per VERIFICATION_FACTORY.md "Circuit Library"):
//   - MerkleInclusion       — inclusion proof for each contributing leaf
//   - MetricExtraction      — Poseidon4 leaf-hash binding + u16 byte read
//   - AverageComputation    — sum the per-leaf metric values
//   - ThresholdComparison.SignedImprovementCheck
//                           — encode the percent-improvement equation
//
// ─────────────────────────────────────────────────────────────────────────
// Public inputs
// ─────────────────────────────────────────────────────────────────────────
//
//   baselineRoot            Merkle root committed for the baseline window
//   finishRoot              Merkle root committed for the finishing window
//                           (may equal baselineRoot if a single tree spans
//                           both windows — the season-one default)
//   metricPointer           byte offset into the v2 leaf where the metric
//                           lives. MUST equal METRIC_CHUNK_IDX*31 +
//                           METRIC_BYTE_OFFSET_IN_CHUNK at proof time —
//                           the circuit asserts this so the on-chain
//                           verifier signs off on the metric-pointer
//                           binding, not just the math
//   claimedMagnitudeBp      claimed |improvement| in basis points (1234 =
//                           12.34 %). Always non-negative; sign carried in
//                           claimedSignFlag below
//   claimedSignFlag         0 = improvement (finish ≥ baseline)
//                           1 = decline     (finish <  baseline)
//
// ─────────────────────────────────────────────────────────────────────────
// Private witness (per leaf)
// ─────────────────────────────────────────────────────────────────────────
//
//   baselineLeafHashes[N]    Poseidon4 hash of each baseline leaf
//   baselineChunks[N][4]     four 31-byte big-endian field-element chunks
//                            of each baseline leaf (matches
//                            zk/scripts/hash_leaf.js::chunksV2)
//   baselinePaths[N][depth]  inclusion proof siblings for each baseline leaf
//   baselineIdx[N][depth]    direction bits for each baseline leaf
//
//   finishLeafHashes[M]      same shape for the finishing window
//   finishChunks[M][4]
//   finishPaths[M][depth]
//   finishIdx[M][depth]
//
// ─────────────────────────────────────────────────────────────────────────
// What it proves
// ─────────────────────────────────────────────────────────────────────────
//
//   1. Each baseline leaf is in the baseline tree under baselineRoot
//      (MerkleInclusion).
//   2. Each finish leaf is in the finish tree under finishRoot
//      (MerkleInclusion).
//   3. Each leaf's bytes are bound to its committed hash
//      (MetricExtraction → Poseidon4).
//   4. The metric value at the public `metricPointer` is the value used in
//      the average. (MetricExtraction reads bytes at the compile-time
//      offset; the circuit asserts the public pointer matches.)
//   5. baselineSum = Σ baselineMetricValues, finishSum = Σ finishMetricValues
//      (AverageComputation).
//   6. The improvement equation
//        claimedMagnitudeBp · (baselineSum · M)
//          == 10000 · |finishSum · N − baselineSum · M|
//      with the sign carried by claimedSignFlag (SignedImprovementCheck).
//
// ─────────────────────────────────────────────────────────────────────────
// Compile-time parameters
// ─────────────────────────────────────────────────────────────────────────
//
//   N                            baseline-window leaf count
//   M                            finish-window  leaf count
//   depth                        Merkle tree depth (must match the tree
//                                builder used to commit the roots)
//   METRIC_CHUNK_IDX             0..3: chunk holding the metric
//   METRIC_BYTE_OFFSET_IN_CHUNK  0..29: byte position within that chunk
//
// One verifier contract is deployed per `(N, M, depth, metric)` tuple. The
// season-one default is documented in `metric-pointers.md`. To swap the
// metric (e.g. RHR for VO2 max) we recompile the circuit with the new
// constants and ship a new verifier; all four primitives stay unchanged.
//
// ─────────────────────────────────────────────────────────────────────────
// Constraint cost (measured)
// ─────────────────────────────────────────────────────────────────────────
//
//   per leaf: MetricExtraction (~986) + MerkleInclusion(d) (~522·d)
//
//   N=M=2, depth=7  → 18,707 constraints   ← default below, under 20 k
//   N=M=2, depth=8  → 20,795 constraints
//   N=M=7, depth=8  → ~73 k                (fits pot17, exceeds 20 k target)
//
// Default instantiation below is N=M=2 / depth=7 — the smallest meaningful
// window that fits the brief's 20 k target. Larger seasons can recompile
// with bigger N/M (and matching depth) up to pot17's 131 k constraint cap.

include "../../primitives/merkle_inclusion/merkle_inclusion.circom";
include "../../primitives/metric_extraction/metric_extraction.circom";
include "../../primitives/average_computation/average_computation.circom";
include "../../primitives/threshold_comparison/threshold_comparison.circom";

template AverageImprovementProof(
    N,
    M,
    depth,
    METRIC_CHUNK_IDX,
    METRIC_BYTE_OFFSET_IN_CHUNK
) {
    // ── Public inputs ──────────────────────────────────────────────
    signal input baselineRoot;
    signal input finishRoot;
    signal input metricPointer;
    signal input claimedMagnitudeBp;
    signal input claimedSignFlag;

    // ── Private witness ────────────────────────────────────────────
    signal input baselineLeafHashes[N];
    signal input baselineChunks[N][4];
    signal input baselinePaths[N][depth];
    signal input baselineIdx[N][depth];

    signal input finishLeafHashes[M];
    signal input finishChunks[M][4];
    signal input finishPaths[M][depth];
    signal input finishIdx[M][depth];

    // ── 1. Bind metricPointer to the compile-time chunk/offset ─────
    // The on-chain verifier accepts only proofs whose declared pointer
    // matches the circuit instantiation. Without this constraint, a
    // malicious prover could submit a proof "claiming VO2 max" that
    // actually used the weight chunk.
    var expectedPointer = METRIC_CHUNK_IDX * 31 + METRIC_BYTE_OFFSET_IN_CHUNK;
    metricPointer === expectedPointer;

    // ── 2. Per-leaf strong binding + extraction (baseline) ─────────
    component baselineExtract[N];
    component baselineInclude[N];
    signal baselineMetric[N];

    for (var i = 0; i < N; i++) {
        // Extract metric value AND bind chunks <-> leaf hash.
        baselineExtract[i] = MetricExtraction(METRIC_CHUNK_IDX, METRIC_BYTE_OFFSET_IN_CHUNK);
        for (var c = 0; c < 4; c++) {
            baselineExtract[i].chunks[c] <== baselineChunks[i][c];
        }
        baselineExtract[i].leafHash <== baselineLeafHashes[i];
        baselineMetric[i] <== baselineExtract[i].metricValue;

        // Inclusion proof against baselineRoot.
        baselineInclude[i] = MerkleInclusion(depth);
        baselineInclude[i].leaf <== baselineLeafHashes[i];
        baselineInclude[i].root <== baselineRoot;
        for (var d = 0; d < depth; d++) {
            baselineInclude[i].path[d]    <== baselinePaths[i][d];
            baselineInclude[i].indices[d] <== baselineIdx[i][d];
        }
    }

    // ── 3. Per-leaf strong binding + extraction (finish) ───────────
    component finishExtract[M];
    component finishInclude[M];
    signal finishMetric[M];

    for (var j = 0; j < M; j++) {
        finishExtract[j] = MetricExtraction(METRIC_CHUNK_IDX, METRIC_BYTE_OFFSET_IN_CHUNK);
        for (var c = 0; c < 4; c++) {
            finishExtract[j].chunks[c] <== finishChunks[j][c];
        }
        finishExtract[j].leafHash <== finishLeafHashes[j];
        finishMetric[j] <== finishExtract[j].metricValue;

        finishInclude[j] = MerkleInclusion(depth);
        finishInclude[j].leaf <== finishLeafHashes[j];
        finishInclude[j].root <== finishRoot;
        for (var d = 0; d < depth; d++) {
            finishInclude[j].path[d]    <== finishPaths[j][d];
            finishInclude[j].indices[d] <== finishIdx[j][d];
        }
    }

    // ── 4. Sums via AverageComputation ─────────────────────────────
    component baselineAvg = AverageComputation(N);
    for (var i = 0; i < N; i++) {
        baselineAvg.values[i] <== baselineMetric[i];
    }

    component finishAvg = AverageComputation(M);
    for (var j = 0; j < M; j++) {
        finishAvg.values[j] <== finishMetric[j];
    }

    // ── 5. Improvement equation ────────────────────────────────────
    component check = SignedImprovementCheck(64);
    check.baselineSum      <== baselineAvg.sum;
    check.baselineN        <== baselineAvg.n;
    check.finishSum        <== finishAvg.sum;
    check.finishM          <== finishAvg.n;
    check.claimedMagnitude <== claimedMagnitudeBp;
    check.signFlag         <== claimedSignFlag;
}

// ─────────────────────────────────────────────────────────────────────────
// Default instantiation — Spring Push Season One
//
// N = M = 2  (two-day baseline / finish averages)
// depth = 7  (128-leaf trees, plenty for a single 90-day season window)
// metric: VO2 max — chunk index 2, byte offset within chunk = 2
//                   (= leaf byte offset 2*31 + 2 = 64, matching
//                   AmachLeafV2.swift's vo2max position)
//
// Public signals exposed to the verifier:
//   baselineRoot, finishRoot, metricPointer, claimedMagnitudeBp,
//   claimedSignFlag
//
// Trusted-setup note: regenerate `improvement_final.zkey` and the Solidity
// verifier (`AverageImprovementProofV1Verifier.sol`) after any change to
// this file or any of the four primitives. See
// `zk/setup_improvement.sh` for the ceremony commands.
// ─────────────────────────────────────────────────────────────────────────
component main {public [
    baselineRoot,
    finishRoot,
    metricPointer,
    claimedMagnitudeBp,
    claimedSignFlag
]} = AverageImprovementProof(2, 2, 7, 2, 2);
