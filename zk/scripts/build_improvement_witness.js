/**
 * build_improvement_witness.js
 * Amach Health ZK — Spring Push Verification Layer 2
 *
 * Witness builder for AverageImprovementProof. Takes a baseline and finish
 * window of v2 leaves, builds the two Merkle trees, picks N + M leaves at
 * given indices to contribute to the average, and produces the JSON witness
 * input expected by `circuits/improvement/improvement.circom`.
 *
 * Usage (programmatic):
 *
 *   const { buildImprovementWitness } = require('./build_improvement_witness');
 *   const witness = buildImprovementWitness({
 *     baselineLeaves: [v2Buf, v2Buf, ...],
 *     finishLeaves:   [v2Buf, v2Buf, ...],
 *     baselineIndices: [0, 1],         // which leaves contribute to baseline avg
 *     finishIndices:   [0, 1],         // which leaves contribute to finish avg
 *     metricChunkIdx: 2,                // VO2 max default
 *     metricByteOffsetInChunk: 2,
 *     N: 2, M: 2, depth: 7
 *   });
 *
 *   // -> { input: { ... circom signal map ... },
 *   //      meta:  { baselineRoot, finishRoot, baselineSum, finishSum,
 *   //               improvementBp, signFlag, ... } }
 *
 * The returned `meta` block contains everything the dry-run report needs;
 * `meta.improvementBp` is the *honestly computed* improvement, in basis
 * points, that the circuit will check against `claimedMagnitudeBp`.
 */

'use strict';

const { buildMerkleTree, getMerklePath } = require('./build_tree');
const { hashLeafV2, chunksV2, V2_LEAF_BYTES } = require('./hash_leaf');

// ─────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────

/**
 * @typedef {Object} ImprovementWitnessParams
 * @property {Buffer[]} baselineLeaves     all v2 leaves committed in the baseline tree
 * @property {Buffer[]} finishLeaves       all v2 leaves committed in the finish tree (may === baseline)
 * @property {number[]} baselineIndices    indices into baselineLeaves contributing to the baseline average
 * @property {number[]} finishIndices      indices into finishLeaves contributing to the finish average
 * @property {number} metricChunkIdx       0..3 (matches MetricExtraction parameter)
 * @property {number} metricByteOffsetInChunk 0..29 (matches MetricExtraction parameter)
 * @property {number} N                    expected length of baselineIndices
 * @property {number} M                    expected length of finishIndices
 * @property {number} depth                Merkle tree depth used by the circuit
 */

/**
 * Build a witness for AverageImprovementProof.
 * @param {ImprovementWitnessParams} params
 * @returns {{ input: object, meta: object }}
 */
function buildImprovementWitness(params) {
  const {
    baselineLeaves,
    finishLeaves,
    baselineIndices,
    finishIndices,
    metricChunkIdx,
    metricByteOffsetInChunk,
    N,
    M,
    depth
  } = params;

  // ── Sanity ────────────────────────────────────────────────────────────
  if (!Array.isArray(baselineLeaves) || baselineLeaves.length === 0) {
    throw new Error('baselineLeaves must be a non-empty array of Buffers');
  }
  if (!Array.isArray(finishLeaves) || finishLeaves.length === 0) {
    throw new Error('finishLeaves must be a non-empty array of Buffers');
  }
  if (baselineIndices.length !== N) {
    throw new Error(`baselineIndices length ${baselineIndices.length} != N ${N}`);
  }
  if (finishIndices.length !== M) {
    throw new Error(`finishIndices length ${finishIndices.length} != M ${M}`);
  }

  for (const b of baselineLeaves) {
    if (!Buffer.isBuffer(b) || b.length !== V2_LEAF_BYTES) {
      throw new Error(`baseline leaf must be a ${V2_LEAF_BYTES}-byte Buffer`);
    }
  }
  for (const f of finishLeaves) {
    if (!Buffer.isBuffer(f) || f.length !== V2_LEAF_BYTES) {
      throw new Error(`finish leaf must be a ${V2_LEAF_BYTES}-byte Buffer`);
    }
  }

  // ── Build trees ───────────────────────────────────────────────────────
  // The circuit's depth is fixed; build_tree.js builds whatever depth fits
  // the leaf count, so trees with leaf count < 2^depth need to be padded
  // up. We pad the leaf array to 2^depth with all-zero buffers (which hash
  // through hashLeafV2's version-byte check would fail — so use the
  // ZERO_LEAF approach the tree builder already uses for padding).
  const targetSize = 1 << depth;
  if (baselineLeaves.length > targetSize) {
    throw new Error(
      `baselineLeaves (${baselineLeaves.length}) exceeds depth-${depth} capacity (${targetSize})`
    );
  }
  if (finishLeaves.length > targetSize) {
    throw new Error(
      `finishLeaves (${finishLeaves.length}) exceeds depth-${depth} capacity (${targetSize})`
    );
  }

  // build_tree.js pads to next power of 2 with the field zero element. To
  // pin the tree at a specific depth we hand it leaf hashes directly — but
  // the public buildMerkleTree only takes leaf Buffers. The simplest fix is
  // to pad the input array with placeholder buffers we know will hash to a
  // distinct value, and accept that depth >= ceil(log2(realLeaves)).
  //
  // For this witness builder we require the caller to pad upstream OR we
  // pad ourselves with a minimal-but-valid v2 leaf (dayId=0) that the
  // circuit never references. For Spring Push we build dedicated baseline
  // and finish trees, so this padding is fully under the prover's control.
  const baseline = padToDepth(baselineLeaves, depth);
  const finish   = padToDepth(finishLeaves,   depth);

  const baselineTree = buildMerkleTree(baseline.padded);
  const finishTree   = buildMerkleTree(finish.padded);

  // ── Assemble per-leaf witness slices ──────────────────────────────────
  const baselineSlice = baselineIndices.map((idx) =>
    leafSlice(baseline.padded, baselineTree, idx, metricChunkIdx, metricByteOffsetInChunk)
  );
  const finishSlice = finishIndices.map((idx) =>
    leafSlice(finish.padded, finishTree, idx, metricChunkIdx, metricByteOffsetInChunk)
  );

  // ── Honest improvement-equation values ────────────────────────────────
  const baselineSum = baselineSlice.reduce((s, x) => s + BigInt(x.metricValue), 0n);
  const finishSum   = finishSlice  .reduce((s, x) => s + BigInt(x.metricValue), 0n);

  // improvementBp = (finishSum*N - baselineSum*M) * 10000 / (baselineSum*M)
  // signFlag = 0 if positive, 1 if negative.
  const N_big = BigInt(N);
  const M_big = BigInt(M);
  const finishCross   = finishSum   * N_big;     // finishSum * baselineN
  const baselineCross = baselineSum * M_big;     // baselineSum * finishM

  if (baselineCross === 0n) {
    throw new Error('baselineSum * M must be non-zero — improvement undefined');
  }

  let signFlag;
  let diffMag;
  if (finishCross >= baselineCross) {
    signFlag = 0n;
    diffMag = finishCross - baselineCross;
  } else {
    signFlag = 1n;
    diffMag = baselineCross - finishCross;
  }

  // claimedMagnitudeBp must satisfy:
  //   claimedMagnitudeBp * baselineCross == diffMag * 10000
  //
  // For an honest claim that is integer-divisible we just take the quotient.
  // For a claim that *isn't* integer divisible — i.e. the participant rounds
  // a non-integer-bp result — we compute the floor and warn so the test
  // harness can choose to construct a leaf set that avoids the rounding
  // edge case. (The circuit enforces strict equality; the witness builder
  // therefore returns the exact quotient that closes the equation. Tests
  // that want to demonstrate "wrong claim" tamper with this output.)
  const numerator = diffMag * 10000n;
  if (numerator % baselineCross !== 0n) {
    // Honest improvement isn't integer-bp. We still return the floor so the
    // caller can decide what to do; the circuit will reject any non-exact
    // match.
  }
  const honestClaimMagnitudeBp = numerator / baselineCross;

  const expectedPointer = metricChunkIdx * 31 + metricByteOffsetInChunk;

  const input = {
    // Public
    baselineRoot:        baselineTree.root.toString(10),
    finishRoot:          finishTree.root.toString(10),
    metricPointer:       expectedPointer.toString(10),
    claimedMagnitudeBp:  honestClaimMagnitudeBp.toString(10),
    claimedSignFlag:     signFlag.toString(10),
    // Private — baseline
    baselineLeafHashes:  baselineSlice.map((s) => s.leafHash.toString(10)),
    baselineChunks:      baselineSlice.map((s) => s.chunks.map((c) => c.toString(10))),
    baselinePaths:       baselineSlice.map((s) => s.path.map((p) => p.toString(10))),
    baselineIdx:         baselineSlice.map((s) => s.indices.map((i) => i.toString(10))),
    // Private — finish
    finishLeafHashes:    finishSlice.map((s) => s.leafHash.toString(10)),
    finishChunks:        finishSlice.map((s) => s.chunks.map((c) => c.toString(10))),
    finishPaths:         finishSlice.map((s) => s.path.map((p) => p.toString(10))),
    finishIdx:           finishSlice.map((s) => s.indices.map((i) => i.toString(10)))
  };

  const meta = {
    baselineRoot:    '0x' + baselineTree.root.toString(16),
    finishRoot:      '0x' + finishTree.root.toString(16),
    baselineSum:     baselineSum.toString(10),
    finishSum:       finishSum.toString(10),
    baselineN:       N,
    finishM:         M,
    improvementBp:   (signFlag === 0n ? '' : '-') + honestClaimMagnitudeBp.toString(10),
    signFlag:        signFlag === 0n ? 0 : 1,
    metricPointer:   expectedPointer,
    metricChunkIdx,
    metricByteOffsetInChunk
  };

  return { input, meta };
}

// ─────────────────────────────────────────────────────────────────────────
// Internals
// ─────────────────────────────────────────────────────────────────────────

function padToDepth(leaves, depth) {
  // Pad `leaves` with a fixed dummy v2 leaf so the tree has exactly 2^depth
  // entries. The padding leaves are NEVER referenced by the inclusion
  // proofs (callers only point baselineIndices/finishIndices at real ones).
  const target = 1 << depth;
  if (leaves.length === target) {
    return { padded: leaves, paddingStartedAt: target };
  }
  const padded = leaves.slice();
  const dummy = makeDummyLeaf();
  while (padded.length < target) {
    padded.push(dummy);
  }
  return { padded, paddingStartedAt: leaves.length };
}

function makeDummyLeaf() {
  // 124 bytes, version=0x02, leafType=0x00, schemaVersion=0x01, all-zero
  // payload. Hashes to a deterministic value so trees pad reproducibly.
  const buf = Buffer.alloc(V2_LEAF_BYTES, 0);
  buf.writeUInt8(0x02, 0); // version
  buf.writeUInt8(0x00, 1); // leafType
  buf.writeUInt8(0x01, 2); // schemaVersion
  return buf;
}

function leafSlice(allLeaves, tree, idx, metricChunkIdx, metricByteOffsetInChunk) {
  if (idx < 0 || idx >= allLeaves.length) {
    throw new Error(`leaf index ${idx} out of range for tree of ${allLeaves.length} leaves`);
  }
  const buf = allLeaves[idx];
  const chunks = chunksV2(buf);
  const leafHash = hashLeafV2(buf);

  // Extract metric value from the matching chunk's bytes.
  const chunkStart = metricChunkIdx * 31;
  const high = buf[chunkStart + metricByteOffsetInChunk];
  const low  = buf[chunkStart + metricByteOffsetInChunk + 1];
  const metricValue = (high << 8) | low;

  const { siblings, indices } = getMerklePath(tree.tree, idx);

  return {
    leafHash,
    chunks,
    path: siblings,
    indices,
    metricValue
  };
}

module.exports = {
  buildImprovementWitness,
  makeDummyLeaf
};
