/**
 * AverageImprovementProofV1Verifier.test.js
 * Hardhat unit tests for the snarkJS-generated Groth16 verifier.
 *
 * These tests run against the local hardhat EVM (NOT zkSync Sepolia) so we
 * can iterate quickly. Pre-built proofs come from
 *   `<zk>/data/improvement_proofs/<label>.json`
 * which is populated by `improvement_proof.test.js`. Run that test first:
 *
 *   cd zk && npx jest scripts/__tests__/improvement_proof.test.js
 *
 * Then:
 *
 *   cd zk/deploy && npx hardhat test --network hardhat
 */

'use strict';

const path = require('path');
const fs = require('fs');
const { expect } = require('chai');
const hre = require('hardhat');

const PROOF_DIR = path.join(__dirname, '../../data/improvement_proofs');

function loadProof(label) {
  const p = path.join(PROOF_DIR, `${label}.json`);
  if (!fs.existsSync(p)) {
    throw new Error(
      `Pre-built proof not found at ${p}. Run improvement_proof.test.js first.`
    );
  }
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

// snarkjs.groth16.exportSolidityCallData returns a single string; the
// verifier expects [pA, pB, pC, pubSignals]. The string is just JSON-style
// but with bigint hex literals, so a permissive parse works.
function parseCalldata(calldataStr) {
  // calldata format: "[\"0x...\",\"0x...\"],[[\"0x...\",\"0x...\"],[...]],[\"0x...\",\"0x...\"],[\"...\",...]"
  // Surround with brackets and run JSON.parse.
  return JSON.parse(`[${calldataStr}]`);
}

describe('AverageImprovementProofV1Verifier', function () {
  let verifier;

  before(async function () {
    const Verifier = await hre.ethers.getContractFactory('Groth16Verifier');
    verifier = await Verifier.deploy();
    await verifier.waitForDeployment();
  });

  describe('positive proofs verify on-chain', function () {
    const positiveLabels = [
      '5pct_vo2max',
      '10pct_vo2max',
      '15pct_vo2max',
      '25pct_vo2max',
      '50pct_vo2max',
      '0pct_flat',
      '0.25pct_tiny',
      '75pct_huge',
      '5pct_decline'
    ];

    for (const label of positiveLabels) {
      it(`verifies ${label}`, async function () {
        const { calldata } = loadProof(label);
        const [pA, pB, pC, pubSignals] = parseCalldata(calldata);
        const ok = await verifier.verifyProof(pA, pB, pC, pubSignals);
        expect(ok).to.equal(true);
      });
    }
  });

  describe('rejects tampered proofs', function () {
    it('rejects a flipped public signal (claimedMagnitudeBp)', async function () {
      const { calldata } = loadProof('10pct_vo2max');
      const [pA, pB, pC, pubSignals] = parseCalldata(calldata);
      // claimedMagnitudeBp is the 4th public signal (index 3), per the
      // circuit's public-signal order:
      //   [baselineRoot, finishRoot, metricPointer,
      //    claimedMagnitudeBp, claimedSignFlag]
      const tampered = [...pubSignals];
      tampered[3] = '0x' + (BigInt(tampered[3]) + 1n).toString(16);
      const ok = await verifier.verifyProof(pA, pB, pC, tampered);
      expect(ok).to.equal(false);
    });

    it('rejects a flipped public signal (metricPointer)', async function () {
      const { calldata } = loadProof('10pct_vo2max');
      const [pA, pB, pC, pubSignals] = parseCalldata(calldata);
      const tampered = [...pubSignals];
      tampered[2] = '0x' + (BigInt(tampered[2]) + 1n).toString(16);
      const ok = await verifier.verifyProof(pA, pB, pC, tampered);
      expect(ok).to.equal(false);
    });

    it('rejects a tampered proof component (pA[0])', async function () {
      const { calldata } = loadProof('10pct_vo2max');
      const [pA, pB, pC, pubSignals] = parseCalldata(calldata);
      const tampered = ['0x' + (BigInt(pA[0]) + 1n).toString(16), pA[1]];
      // Tampering pA can either revert (point not on curve) or return
      // false. Both are valid rejection paths — accept either.
      let ok;
      try {
        ok = await verifier.verifyProof(tampered, pB, pC, pubSignals);
      } catch (_) {
        ok = false;
      }
      expect(ok).to.equal(false);
    });

    it('rejects swapped proofs across distinct claims', async function () {
      // Take the proof for "10% improvement" but try to verify it against
      // the public signals from "25% improvement". The pairing equation
      // is bound to its public signals so this must fail.
      const tenPct = loadProof('10pct_vo2max');
      const twentyFive = loadProof('25pct_vo2max');
      const [pA, pB, pC] = parseCalldata(tenPct.calldata);
      const [, , , otherSignals] = parseCalldata(twentyFive.calldata);
      const ok = await verifier.verifyProof(pA, pB, pC, otherSignals);
      expect(ok).to.equal(false);
    });
  });

  describe('gas cost', function () {
    it('verifyProof gas is under 500k (brief target)', async function () {
      const { calldata } = loadProof('10pct_vo2max');
      const [pA, pB, pC, pubSignals] = parseCalldata(calldata);

      // Use estimateGas for a view function — Hardhat returns the call gas.
      const gas = await verifier.verifyProof.estimateGas(pA, pB, pC, pubSignals);
      // eslint-disable-next-line no-console
      console.log(`        verifyProof gas: ${gas.toString()}`);
      expect(Number(gas)).to.be.lessThan(500_000);
    });
  });
});
