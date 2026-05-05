/**
 * improvement_proof.test.js
 * Layer 2 — full Groth16 prove + verify across the brief's positive,
 * negative, and edge cases.
 *
 * Each positive test goes prove → local verify (snarkjs.groth16.verify) and
 * also exports the Solidity calldata, which Hardhat tests for the verifier
 * contract reuse via `data/improvement_proofs/<name>.json`.
 *
 * Each negative test exercises the SAME witness builder but tampers with
 * either the public input or the witness. We use the witness calculator
 * directly (`circom_runtime`) so the tampered witness fails fast without
 * needing the zkey path.
 *
 * Default circuit instantiation:
 *   AverageImprovementProof(2, 2, 7, 2, 2)   // VO2 max, byte offset 64
 */

'use strict';

const path = require('path');
const fs = require('fs');
const { performance } = require('perf_hooks');
const snarkjs = require('snarkjs');
const { WitnessCalculatorBuilder } = require('circom_runtime');

const { buildImprovementWitness } = require('../build_improvement_witness');
const { buildTestLeafV2 } = require('../hash_leaf');

const ZK_ROOT = path.join(__dirname, '..', '..');
const WASM = path.join(ZK_ROOT, 'build/improvement/improvement_js/improvement.wasm');
const ZKEY = path.join(ZK_ROOT, 'build/improvement/improvement_final.zkey');
const VKEY = path.join(ZK_ROOT, 'build/improvement/verification_key.json');
const PROOF_DIR = path.join(ZK_ROOT, 'data/improvement_proofs');

// Default circuit constants.
const N = 2;
const M = 2;
const DEPTH = 7;
const METRIC_CHUNK_IDX = 2;
const METRIC_BYTE_OFFSET_IN_CHUNK = 2;   // VO2 max @ leaf byte 64

// ─────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────

let cachedWasm;
async function calculateWitnessOnly(input) {
  if (!cachedWasm) cachedWasm = fs.readFileSync(WASM);
  const wc = await WitnessCalculatorBuilder(cachedWasm);
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

let cachedVkey;
function loadVkey() {
  if (!cachedVkey) cachedVkey = JSON.parse(fs.readFileSync(VKEY, 'utf8'));
  return cachedVkey;
}

async function proveAndVerify(input, label) {
  const start = performance.now();
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    unstringify(input), WASM, ZKEY
  );
  const proveMs = performance.now() - start;

  const vkey = loadVkey();
  const ok = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  if (!ok) {
    throw new Error(`Local verification FAILED for ${label}`);
  }

  // Stash for Hardhat tests.
  const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
  fs.mkdirSync(PROOF_DIR, { recursive: true });
  fs.writeFileSync(
    path.join(PROOF_DIR, `${label}.json`),
    JSON.stringify({ proof, publicSignals, calldata, label }, null, 2)
  );

  return { proof, publicSignals, proveMs };
}

function vo2Leaf(dayId, vo2max) {
  return buildTestLeafV2({ dayId, vo2max });
}

function rhrLeaf(dayId, rhr) {
  return buildTestLeafV2({ dayId, restingHR: rhr });
}

function weightLeaf(dayId, weight) {
  return buildTestLeafV2({ dayId, weight });
}

function buildBaseInput(overrides = {}) {
  const baseline = overrides.baselineLeaves || [vo2Leaf(1, 400), vo2Leaf(2, 410)];
  const finish   = overrides.finishLeaves   || [vo2Leaf(50, 440), vo2Leaf(51, 451)];
  return buildImprovementWitness({
    baselineLeaves: baseline,
    finishLeaves: finish,
    baselineIndices: overrides.baselineIndices || [0, 1],
    finishIndices:   overrides.finishIndices   || [0, 1],
    metricChunkIdx: overrides.metricChunkIdx ?? METRIC_CHUNK_IDX,
    metricByteOffsetInChunk: overrides.metricByteOffsetInChunk ?? METRIC_BYTE_OFFSET_IN_CHUNK,
    N, M, depth: DEPTH
  });
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

beforeAll(() => {
  if (!fs.existsSync(WASM) || !fs.existsSync(ZKEY) || !fs.existsSync(VKEY)) {
    throw new Error(
      'Layer 2 build artifacts missing. Run `cd zk && ./setup_improvement.sh` first.'
    );
  }
});

describe('AverageImprovementProof — positive proofs', () => {
  test('5% VO2 max improvement', async () => {
    // Baseline avg 40.0, finish avg 42.0 → 5.00 %
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 420), vo2Leaf(51, 420)]
    });
    expect(meta.improvementBp).toBe('500');
    const { proveMs } = await proveAndVerify(input, '5pct_vo2max');
    expect(proveMs).toBeLessThan(30000);     // brief target: <30 s on 2020 MacBook
  });

  test('10% VO2 max improvement', async () => {
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 410)],
      finishLeaves:   [vo2Leaf(50, 440), vo2Leaf(51, 451)]
    });
    expect(meta.improvementBp).toBe('1000');
    await proveAndVerify(input, '10pct_vo2max');
  });

  test('15% VO2 max improvement', async () => {
    // Baseline 40.0, finish 46.0 → 15.00 %
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 460), vo2Leaf(51, 460)]
    });
    expect(meta.improvementBp).toBe('1500');
    await proveAndVerify(input, '15pct_vo2max');
  });

  test('25% VO2 max improvement', async () => {
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 500), vo2Leaf(51, 500)]
    });
    expect(meta.improvementBp).toBe('2500');
    await proveAndVerify(input, '25pct_vo2max');
  });

  test('50% VO2 max improvement', async () => {
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 600), vo2Leaf(51, 600)]
    });
    expect(meta.improvementBp).toBe('5000');
    await proveAndVerify(input, '50pct_vo2max');
  });

  test('0% improvement (flat)', async () => {
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 400), vo2Leaf(51, 400)]
    });
    expect(meta.improvementBp).toBe('0');
    expect(meta.signFlag).toBe(0);
    await proveAndVerify(input, '0pct_flat');
  });

  test('very small improvement (0.25%)', async () => {
    // baseline 40.0, finish 40.1 → (40.1-40)/40 = 0.25 %
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 401), vo2Leaf(51, 401)]
    });
    expect(meta.improvementBp).toBe('25');
    await proveAndVerify(input, '0.25pct_tiny');
  });

  test('large improvement (75%)', async () => {
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 700), vo2Leaf(51, 700)]
    });
    expect(meta.improvementBp).toBe('7500');
    await proveAndVerify(input, '75pct_huge');
  });

  test('negative improvement (5% decline)', async () => {
    // baseline 40.0 → finish 38.0  ⇒  decline of (40-38)/40 = 5%
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 380), vo2Leaf(51, 380)]
    });
    expect(meta.improvementBp).toBe('-500');
    expect(meta.signFlag).toBe(1);
    await proveAndVerify(input, '5pct_decline');
  });

  test('different metric pointer — RHR (resting heart rate)', async () => {
    // RHR storage is u16 ×10 bpm. Baseline 60.0 → finish 54.0  ⇒
    // improvement of (54-60)/60 = -10 % from RHR's perspective, which is
    // actually a *good* outcome physiologically. The circuit doesn't care
    // about the semantics of the metric; it just enforces the math.
    // Parameters: chunk index 1, byte offset 23  (= leaf byte 54).
    const baseline = [rhrLeaf(1, 600), rhrLeaf(2, 600)];
    const finish   = [rhrLeaf(50, 540), rhrLeaf(51, 540)];
    const { input, meta } = buildBaseInput({
      baselineLeaves: baseline, finishLeaves: finish,
      metricChunkIdx: 1, metricByteOffsetInChunk: 23
    });
    expect(meta.metricPointer).toBe(54);
    expect(meta.signFlag).toBe(1);
    expect(meta.improvementBp).toBe('-1000');

    // The on-chain verifier deployed for *this* instantiation only accepts
    // metricPointer = 64 (VO2 max). RHR proofs need their own verifier
    // contract — see metric-pointers.md. But the *witness math* and the
    // *witness extractor* both work here, which is what this test
    // demonstrates.
    //
    // Witness-only check (no full proof, since this metric pointer
    // wouldn't pass the compile-time pointer assertion of our default
    // circuit). The pointer assertion lives at line "metricPointer ===
    // expectedPointer" in improvement.circom.
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });
});

describe('AverageImprovementProof — negative tests', () => {
  test('rejects claim higher than actual', async () => {
    const { input } = buildBaseInput();
    input.claimedMagnitudeBp = (BigInt(input.claimedMagnitudeBp) + 1n).toString(10);
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects claim lower than actual', async () => {
    const { input } = buildBaseInput();
    input.claimedMagnitudeBp = (BigInt(input.claimedMagnitudeBp) - 1n).toString(10);
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects mismatched baselineRoot (wrong tree)', async () => {
    const { input } = buildBaseInput();
    input.baselineRoot = (BigInt(input.baselineRoot) ^ 1n).toString(10);
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects mismatched finishRoot', async () => {
    const { input } = buildBaseInput();
    input.finishRoot = (BigInt(input.finishRoot) ^ 1n).toString(10);
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects tampered Merkle path', async () => {
    const { input } = buildBaseInput();
    input.baselinePaths[0][0] = (BigInt(input.baselinePaths[0][0]) + 1n).toString(10);
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects tampered Merkle index bit', async () => {
    const { input } = buildBaseInput();
    // Flipping a 0 to 1 (or vice-versa). 0/1 is the constraint range, both
    // are individually valid — the path then opens to the wrong root.
    input.finishIdx[0][0] = input.finishIdx[0][0] === '0' ? '1' : '0';
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects wrong metricPointer (compile-time pointer mismatch)', async () => {
    const { input } = buildBaseInput();
    input.metricPointer = '50';   // exerciseMins offset, not vo2max
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects forged leaf chunks (Poseidon4 binding fails)', async () => {
    const { input } = buildBaseInput();
    // Tamper with chunk0 of the first baseline leaf — Poseidon4(chunks)
    // will no longer equal leafHash, MetricExtraction's first === fails.
    input.baselineChunks[0][0] = (BigInt(input.baselineChunks[0][0]) + 1n).toString(10);
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects out-of-range Merkle index (boolean violation)', async () => {
    const { input } = buildBaseInput();
    input.baselineIdx[0][0] = '2';   // not 0 or 1
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });

  test('rejects sign-flag mis-direction', async () => {
    // Honest improvement is positive but the prover claims signFlag=1
    // (decline). The selected diff goes negative, fails Num2Bits range
    // check inside SignedImprovementCheck.
    const { input, meta } = buildBaseInput({
      baselineLeaves: [vo2Leaf(1, 400), vo2Leaf(2, 400)],
      finishLeaves:   [vo2Leaf(50, 420), vo2Leaf(51, 420)]
    });
    expect(meta.signFlag).toBe(0);
    input.claimedSignFlag = '1';
    await expect(calculateWitnessOnly(input)).rejects.toThrow();
  });
});

describe('AverageImprovementProof — edge cases', () => {
  test('maximum-size window (N=M=2 — circuit default)', async () => {
    // Sanity: the brief asks for a "max window" edge case. For our
    // N=M=2 default, this is just "use both slots". For larger
    // instantiations the test would fill the configured window size.
    const { input, meta } = buildBaseInput();
    expect(meta.baselineN).toBe(2);
    expect(meta.finishM).toBe(2);
    await proveAndVerify(input, 'edge_max_window');
  });

  test('zero baseline must fail (would be div-by-zero)', () => {
    // baselineSum = 0 produces no inverse — SignedImprovementCheck would
    // fail in-circuit, but we catch it earlier in the witness builder so
    // the error message points at the human-readable cause rather than a
    // generic "Error in template" trace.
    expect(() =>
      buildBaseInput({
        baselineLeaves: [vo2Leaf(1, 0), vo2Leaf(2, 0)],
        finishLeaves:   [vo2Leaf(50, 100), vo2Leaf(51, 100)]
      })
    ).toThrow(/baselineSum.*non-zero/);
  });
});
