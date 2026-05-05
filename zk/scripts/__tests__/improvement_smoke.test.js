/**
 * improvement_smoke.test.js
 * Layer 2 — quick witness-only sanity check.
 *
 * This test does NOT generate a Groth16 proof (no .zkey is required). It
 * only runs `snarkjs wtns calculate` against the compiled .wasm to confirm
 * that our witness builder produces an input the circuit accepts. Real
 * positive/negative proof tests live in `improvement_proof.test.js`.
 *
 * Why split? wtns calculate is fast (<1 s); a full groth16 fullProve takes
 * several seconds and requires the trusted-setup .zkey. Splitting lets the
 * smoke test run in CI without the ceremony output.
 */

'use strict';

const path = require('path');
const fs = require('fs');
const { WitnessCalculatorBuilder } = require('circom_runtime');

const { buildImprovementWitness } = require('../build_improvement_witness');
const { buildTestLeafV2 } = require('../hash_leaf');

const ZK_ROOT = path.join(__dirname, '..', '..');
const WASM = path.join(ZK_ROOT, 'build/improvement/improvement_js/improvement.wasm');

// Default circuit: AverageImprovementProof(2, 2, 7, 2, 2)
const N = 2;
const M = 2;
const DEPTH = 7;
const METRIC_CHUNK_IDX = 2;
const METRIC_BYTE_OFFSET_IN_CHUNK = 2;   // VO2 max

function vo2Leaf(dayId, vo2max) {
  // vo2max stored as u16 ×10 (e.g. 425 = 42.5 ml/kg/min)
  return buildTestLeafV2({ dayId, vo2max });
}

describe('AverageImprovementProof witness smoke', () => {
  beforeAll(() => {
    if (!fs.existsSync(WASM)) {
      throw new Error(
        `improvement.wasm missing — run:\n` +
        `  cd zk && circom circuits/improvement/improvement.circom --r1cs --wasm --sym -o build/improvement -l node_modules`
      );
    }
  });

  test('positive 10% VO2 max improvement', async () => {
    // Baseline: VO2 max 40.0, 41.0  → mean 40.5
    // Finish:   VO2 max 44.0, 45.1  → mean 44.55
    // Improvement = (44.55 - 40.5) / 40.5 = 10.000% (1000 bp)
    const baseline = [vo2Leaf(1, 400), vo2Leaf(2, 410)];
    const finish   = [vo2Leaf(50, 440), vo2Leaf(51, 451)];

    const { input, meta } = buildImprovementWitness({
      baselineLeaves: baseline,
      finishLeaves:   finish,
      baselineIndices: [0, 1],
      finishIndices:   [0, 1],
      metricChunkIdx: METRIC_CHUNK_IDX,
      metricByteOffsetInChunk: METRIC_BYTE_OFFSET_IN_CHUNK,
      N, M, depth: DEPTH
    });

    expect(meta.baselineSum).toBe('810');   // 400 + 410
    expect(meta.finishSum).toBe('891');     // 440 + 451
    expect(meta.signFlag).toBe(0);
    expect(meta.improvementBp).toBe('1000');
    expect(meta.metricPointer).toBe(64);    // 2*31 + 2

    await calculateWitness(input);          // throws if circuit rejects
  });

  test('zero improvement (flat)', async () => {
    const baseline = [vo2Leaf(1, 400), vo2Leaf(2, 400)];
    const finish   = [vo2Leaf(50, 400), vo2Leaf(51, 400)];

    const { input, meta } = buildImprovementWitness({
      baselineLeaves: baseline, finishLeaves: finish,
      baselineIndices: [0, 1], finishIndices: [0, 1],
      metricChunkIdx: METRIC_CHUNK_IDX, metricByteOffsetInChunk: METRIC_BYTE_OFFSET_IN_CHUNK,
      N, M, depth: DEPTH
    });

    expect(meta.improvementBp).toBe('0');
    expect(meta.signFlag).toBe(0);

    await calculateWitness(input);
  });

  test('negative 5% decline', async () => {
    // Baseline: 40.0, 40.0 → 40.0
    // Finish:   38.0, 38.0 → 38.0
    // Decline = (40 - 38) / 40 = 5.000% (5000 bp magnitude, signFlag=1)
    const baseline = [vo2Leaf(1, 400), vo2Leaf(2, 400)];
    const finish   = [vo2Leaf(50, 380), vo2Leaf(51, 380)];

    const { input, meta } = buildImprovementWitness({
      baselineLeaves: baseline, finishLeaves: finish,
      baselineIndices: [0, 1], finishIndices: [0, 1],
      metricChunkIdx: METRIC_CHUNK_IDX, metricByteOffsetInChunk: METRIC_BYTE_OFFSET_IN_CHUNK,
      N, M, depth: DEPTH
    });

    expect(meta.signFlag).toBe(1);
    expect(meta.improvementBp).toBe('-500');     // 5.00% magnitude with negative sign

    await calculateWitness(input);
  });

  test('rejects wrong claimed magnitude', async () => {
    const baseline = [vo2Leaf(1, 400), vo2Leaf(2, 410)];
    const finish   = [vo2Leaf(50, 440), vo2Leaf(51, 451)];

    const { input } = buildImprovementWitness({
      baselineLeaves: baseline, finishLeaves: finish,
      baselineIndices: [0, 1], finishIndices: [0, 1],
      metricChunkIdx: METRIC_CHUNK_IDX, metricByteOffsetInChunk: METRIC_BYTE_OFFSET_IN_CHUNK,
      N, M, depth: DEPTH
    });

    // Inflate the claim by 1 bp — should fail the SignedImprovementCheck eq
    input.claimedMagnitudeBp = (BigInt(input.claimedMagnitudeBp) + 1n).toString(10);

    await expect(calculateWitness(input)).rejects.toThrow();
  });

  test('rejects wrong metricPointer (asserts compile-time pointer binding)', async () => {
    const baseline = [vo2Leaf(1, 400), vo2Leaf(2, 410)];
    const finish   = [vo2Leaf(50, 440), vo2Leaf(51, 451)];

    const { input } = buildImprovementWitness({
      baselineLeaves: baseline, finishLeaves: finish,
      baselineIndices: [0, 1], finishIndices: [0, 1],
      metricChunkIdx: METRIC_CHUNK_IDX, metricByteOffsetInChunk: METRIC_BYTE_OFFSET_IN_CHUNK,
      N, M, depth: DEPTH
    });

    // Lie about which metric we're claiming. Default circuit binds pointer
    // to chunkIdx*31 + offsetInChunk = 64 (vo2max).
    input.metricPointer = '50';   // exerciseMins offset

    await expect(calculateWitness(input)).rejects.toThrow();
  });

  test('rejects swapped finishRoot (Merkle inclusion fails)', async () => {
    const baseline = [vo2Leaf(1, 400), vo2Leaf(2, 410)];
    const finish   = [vo2Leaf(50, 440), vo2Leaf(51, 451)];

    const { input } = buildImprovementWitness({
      baselineLeaves: baseline, finishLeaves: finish,
      baselineIndices: [0, 1], finishIndices: [0, 1],
      metricChunkIdx: METRIC_CHUNK_IDX, metricByteOffsetInChunk: METRIC_BYTE_OFFSET_IN_CHUNK,
      N, M, depth: DEPTH
    });

    // Tamper: swap finishRoot for a different unrelated value.
    input.finishRoot = (BigInt(input.finishRoot) ^ 1n).toString(10);

    await expect(calculateWitness(input)).rejects.toThrow();
  });

  test('rejects wrong leaf chunks (strong-binding check)', async () => {
    const baseline = [vo2Leaf(1, 400), vo2Leaf(2, 410)];
    const finish   = [vo2Leaf(50, 440), vo2Leaf(51, 451)];

    const { input } = buildImprovementWitness({
      baselineLeaves: baseline, finishLeaves: finish,
      baselineIndices: [0, 1], finishIndices: [0, 1],
      metricChunkIdx: METRIC_CHUNK_IDX, metricByteOffsetInChunk: METRIC_BYTE_OFFSET_IN_CHUNK,
      N, M, depth: DEPTH
    });

    // Tamper: claim leaf bytes are different from what hashes to leafHash.
    // Should fail the Poseidon4(chunks) === leafHash binding inside
    // MetricExtraction.
    input.baselineChunks[0][0] = (BigInt(input.baselineChunks[0][0]) + 1n).toString(10);

    await expect(calculateWitness(input)).rejects.toThrow();
  });
});

// Drive the wasm witness calculator directly so we don't depend on
// snarkjs's wtns.calculate file-handle path, which leaks an open fd if the
// circuit's `===` constraint asserts during witness calculation. The
// circom-2 witness calculator throws on constraint violation, which is
// exactly the behaviour we want for negative-test assertions.
let cachedWasmBuf;
async function calculateWitness(input) {
  if (!cachedWasmBuf) {
    cachedWasmBuf = fs.readFileSync(WASM);
  }
  const wc = await WitnessCalculatorBuilder(cachedWasmBuf);
  // calculateWitness throws synchronously inside the wasm if any constraint
  // fails. We don't need the binary witness output for these tests; just
  // running the calc to completion is enough to confirm "circuit accepts".
  await wc.calculateWitness(unstringify(input), true);
}

function unstringify(o) {
  if (typeof o === 'string') {
    if (/^[0-9]+$/.test(o)) return BigInt(o);
    return o;
  }
  if (Array.isArray(o)) return o.map(unstringify);
  if (o && typeof o === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(o)) out[k] = unstringify(v);
    return out;
  }
  return o;
}
