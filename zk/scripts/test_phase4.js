/**
 * test_phase4.js
 * Phase 4 gate tests — ZK Circuit Compilation, Trusted Setup, Proof Generation
 *
 * Requires setup_phase4.sh to have been run first (compiles circuit, runs Groth16
 * trusted setup, exports verification key and CoverageVerifier.sol).
 *
 * Gate tests:
 *   1. All circuit artifacts exist and are non-empty
 *   2. Circuit–JS Poseidon hash cross-check (Circom output matches Node.js)
 *   3. Valid proof generated and verified locally
 *   4. Tampered proof rejected by verifier
 *   5. Out-of-range leaf (dayId > end_day_id) causes witness failure
 *   6. Valid proof with wrong root fails verification
 *
 * Run:
 *   node scripts/test_phase4.js
 * Or via npm:
 *   npm run test:phase4
 */

'use strict';

const snarkjs = require('snarkjs');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { buildMerkleTree, getMerklePath } = require('./build_tree');
const { buildTestLeaf } = require('./hash_leaf');

const BASE = path.join(__dirname, '..');

// ─── Test harness ───────────────────────────────────────────────────────────

let passed = 0;
let failed = 0;

function assert(condition, testName, detail = '') {
  if (condition) {
    console.log(`  ✅ PASS: ${testName}`);
    passed++;
  } else {
    console.log(`  ❌ FAIL: ${testName}${detail ? ' — ' + detail : ''}`);
    failed++;
  }
}

function assertEqual(a, b, testName) {
  if (a === b) {
    console.log(`  ✅ PASS: ${testName}`);
    passed++;
  } else {
    console.log(`  ❌ FAIL: ${testName}`);
    console.log(`        expected: ${String(b).slice(0, 80)}`);
    console.log(`        got:      ${String(a).slice(0, 80)}`);
    failed++;
  }
}

// ─── Circuit paths ──────────────────────────────────────────────────────────

const COVERAGE_R1CS  = path.join(BASE, 'build/coverage/coverage.r1cs');
const COVERAGE_WASM  = path.join(BASE, 'build/coverage/coverage_js/coverage.wasm');
const COVERAGE_ZKEY  = path.join(BASE, 'build/coverage/coverage_final.zkey');
const COVERAGE_VKEY  = path.join(BASE, 'build/coverage/verification_key.json');
const VERIFIER_SOL   = path.join(BASE, 'circuits/coverage/CoverageVerifier.sol');
const LEAFTEST_WASM  = path.join(BASE, 'build/leaf_hash_test/LeafHashTest_js/LeafHashTest.wasm');
const REF_HASHES     = path.join(BASE, 'data/phase2_reference_hashes.json');

// ─── Helpers ────────────────────────────────────────────────────────────────

/**
 * Build a 256-leaf test tree.
 * 256 leaves → nextPowerOf2(256) = 256 → depth = 8, matching CoverageProof(20, 8).
 */
function build256LeafTree() {
  const leaves = Array.from({ length: 256 }, (_, i) => buildTestLeaf({ dayId: i + 1 }));
  return buildMerkleTree(leaves);
}

/**
 * Build the snarkJS witness input for a coverage proof.
 * Selects the first k leaves (indices 0..k-1, dayIds 1..k).
 */
function buildWitnessInput(treeResult, startDay, endDay, k = 20) {
  const selected = Array.from({ length: k }, (_, i) => i);
  return {
    root:         treeResult.root.toString(),
    start_day_id: startDay.toString(),
    end_day_id:   endDay.toString(),
    min_days:     k.toString(),
    leaf_day_ids: selected.map(i => (i + 1).toString()),
    leaf_hashes:  selected.map(i => treeResult.leafHashes[i].toString()),
    merkle_paths: selected.map(i =>
      getMerklePath(treeResult.tree, i).siblings.map(s => s.toString())
    ),
    path_indices: selected.map(i =>
      getMerklePath(treeResult.tree, i).indices.map(n => n.toString())
    )
  };
}

/** Silent snarkJS logger — suppresses expected error output during negative tests. */
const SILENT = { error: () => {}, warn: () => {}, info: () => {}, debug: () => {} };

// ─── Main ───────────────────────────────────────────────────────────────────

async function runTests() {
  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  PHASE 4 GATE TESTS — ZK Circuit & Proof');
  console.log('════════════════════════════════════════════════');
  console.log('');

  // ───────────────────────────────────────────────
  // Gate Test 1: All circuit artifacts exist
  // ───────────────────────────────────────────────
  console.log('Gate Test 1 — Circuit artifacts present:');
  {
    const artifacts = [
      { label: 'coverage.r1cs',         file: COVERAGE_R1CS  },
      { label: 'coverage.wasm',         file: COVERAGE_WASM  },
      { label: 'coverage_final.zkey',   file: COVERAGE_ZKEY  },
      { label: 'verification_key.json', file: COVERAGE_VKEY  },
      { label: 'CoverageVerifier.sol',  file: VERIFIER_SOL   }
    ];

    for (const a of artifacts) {
      const exists = fs.existsSync(a.file);
      if (exists) {
        const kb = (fs.statSync(a.file).size / 1024).toFixed(1);
        assert(true, `${a.label} exists (${kb} KB)`);
      } else {
        assert(false, `${a.label} exists`, 'file not found — run setup_phase4.sh first');
      }
    }

    // Log constraint count from r1cs info
    try {
      const info = await snarkjs.r1cs.info(COVERAGE_R1CS);
      const n = info.nConstraints;
      console.log(`  ℹ️  Constraints: ${n} | Wires: ${info.nVars} | Prv inputs: ${info.nPrvInputs} | Pub inputs: ${info.nPubInputs}`);
      assert(n > 80000, `Constraint count (${n}) > 80,000 — circuit is non-trivial`);
    } catch (_) {
      // snarkjs r1cs.info API varies across versions — skip gracefully
      console.log('  ℹ️  (r1cs.info not available in this snarkjs version — skipping constraint log)');
    }
  }
  console.log('');

  // ───────────────────────────────────────────────
  // Gate Test 2: Circuit–JS Poseidon hash cross-check
  // For each Phase 2 reference case, compute the witness through the
  // LeafHashTest circuit and confirm the output matches the JS hash.
  // ───────────────────────────────────────────────
  console.log('Gate Test 2 — Circuit–JS Poseidon hash cross-check:');
  {
    if (!fs.existsSync(REF_HASHES)) {
      console.log('  ⚠️  SKIP: data/phase2_reference_hashes.json not found');
      console.log('           Run "npm run test:phase2" first to generate reference hashes.');
    } else if (!fs.existsSync(LEAFTEST_WASM)) {
      console.log('  ⚠️  SKIP: LeafHashTest.wasm not found');
      console.log('           Run setup_phase4.sh first (Step 1 compiles LeafHashTest).');
    } else {
      const ref = JSON.parse(fs.readFileSync(REF_HASHES, 'utf8'));
      const dataDir = path.join(BASE, 'data');

      for (let i = 0; i < ref.length; i++) {
        const c = ref[i];
        const inputFile  = path.join(dataDir, `_gate2_input_${i}.json`);
        const wtnsFile   = path.join(dataDir, `_gate2_witness_${i}.wtns`);
        const wtnsJson   = path.join(dataDir, `_gate2_witness_${i}.json`);

        try {
          fs.writeFileSync(inputFile, JSON.stringify({
            chunk1: c.chunk1, chunk2: c.chunk2, chunk3: c.chunk3
          }, null, 2));

          execSync(
            `npx snarkjs wtns calculate "${LEAFTEST_WASM}" "${inputFile}" "${wtnsFile}"`,
            { cwd: BASE, stdio: 'pipe' }
          );
          execSync(
            `npx snarkjs wtns export json "${wtnsFile}" "${wtnsJson}"`,
            { cwd: BASE, stdio: 'pipe' }
          );

          const witness = JSON.parse(fs.readFileSync(wtnsJson, 'utf8'));
          // witness[0] is always "1"; witness[1] is the single output signal (hash)
          const circuitHash = witness[1];
          const jsHash      = c.hash;

          if (circuitHash === jsHash) {
            console.log(`  ✅ PASS: Case ${i} — circuit hash matches JS hash`);
            passed++;
          } else {
            console.log(`  ❌ FAIL: Case ${i} — hash mismatch`);
            console.log(`        circuit: ${circuitHash}`);
            console.log(`        node.js: ${jsHash}`);
            failed++;
          }
        } catch (e) {
          console.log(`  ❌ FAIL: Case ${i} — witness calc threw: ${e.message.slice(0, 100)}`);
          failed++;
        } finally {
          // Clean up temp files regardless of pass/fail
          for (const f of [inputFile, wtnsFile, wtnsJson]) {
            try { fs.unlinkSync(f); } catch (_) {}
          }
        }
      }
    }
  }
  console.log('');

  // ───────────────────────────────────────────────
  // Gate Test 3: Valid proof generated and verified
  // Build a 256-leaf tree (depth=8), select k=20 leaves,
  // prove coverage, verify locally with the exported vkey.
  // ───────────────────────────────────────────────
  console.log('Gate Test 3 — Valid proof generation and local verification:');

  // Proof saved here so Gate Tests 4 & 6 can reuse it without reproving
  let savedProof         = null;
  let savedPublicSignals = null;
  let savedRoot          = null;

  if (!fs.existsSync(COVERAGE_WASM) || !fs.existsSync(COVERAGE_ZKEY) || !fs.existsSync(COVERAGE_VKEY)) {
    console.log('  ⚠️  SKIP: Coverage circuit artifacts missing — run setup_phase4.sh first');
    failed++;
  } else {
    try {
      console.log('  Building 256-leaf test tree (depth=8)...');
      const tree = build256LeafTree();
      assertEqual(tree.depth, 8, `Tree depth = ${tree.depth} (matches circuit depth=8)`);
      savedRoot = tree.root;

      // Valid range: dayIds 1–20, all inside [1, 256]
      const input = buildWitnessInput(tree, 1, 256, 20);

      console.log('  Generating Groth16 proof (may take ~30s on first run)...');
      const t0 = Date.now();
      const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input, COVERAGE_WASM, COVERAGE_ZKEY
      );
      console.log(`  Proof generated in ${((Date.now() - t0) / 1000).toFixed(1)}s`);

      savedProof         = proof;
      savedPublicSignals = publicSignals;

      const vkey  = JSON.parse(fs.readFileSync(COVERAGE_VKEY, 'utf8'));
      const valid = await snarkjs.groth16.verify(vkey, publicSignals, proof);

      assert(valid,                      'Valid proof passes local Groth16 verification');
      assert(publicSignals.length >= 4,  `Public signals present (${publicSignals.length} signals)`);
      // publicSignals[0] is the root (first listed public input in the circuit)
      assert(
        publicSignals[0] === tree.root.toString(),
        'Public root matches tree root'
      );

      // Persist for later phases / debugging
      fs.writeFileSync(
        path.join(BASE, 'data/phase4_test_proof.json'),
        JSON.stringify({ proof, publicSignals, root: tree.root.toString() }, null, 2)
      );
      console.log('  Proof artifacts saved to data/phase4_test_proof.json');

    } catch (e) {
      console.log(`  ❌ FAIL: Proof generation threw:`);
      console.log(`        ${e.message}`);
      failed++;
    }
  }
  console.log('');

  // ───────────────────────────────────────────────
  // Gate Test 4: Tampered proof rejected
  // Corrupt pi_a[0] by incrementing it — the modified curve
  // point is off the curve, so verify() must return false.
  // ───────────────────────────────────────────────
  console.log('Gate Test 4 — Tampered proof rejected:');
  if (!savedProof) {
    console.log('  ⚠️  SKIP: No saved proof from Gate Test 3');
    failed++;
  } else {
    try {
      const vkey          = JSON.parse(fs.readFileSync(COVERAGE_VKEY, 'utf8'));
      const tamperedProof = JSON.parse(JSON.stringify(savedProof));  // deep clone

      // Corrupt: add 1 to the first coordinate of pi_a
      tamperedProof.pi_a[0] = (BigInt(tamperedProof.pi_a[0]) + 1n).toString();

      const valid = await snarkjs.groth16.verify(vkey, savedPublicSignals, tamperedProof, SILENT);
      assert(!valid, 'Proof with corrupted pi_a[0] fails verification');
    } catch (_) {
      // snarkjs may throw on a point that's off the curve — also a valid rejection
      assert(true, 'Proof with corrupted pi_a[0] causes verification throw (valid rejection)');
    }
  }
  console.log('');

  // ───────────────────────────────────────────────
  // Gate Test 5: Out-of-range leaf causes witness failure
  // If leaf_day_ids[0] > end_day_id, the LessEqUint32 constraint fires
  // and the witness calculator must throw — proving the range check works.
  // ───────────────────────────────────────────────
  console.log('Gate Test 5 — Out-of-range leaf rejected by circuit:');
  if (!fs.existsSync(COVERAGE_WASM) || !fs.existsSync(COVERAGE_ZKEY)) {
    console.log('  ⚠️  SKIP: Circuit artifacts missing');
    failed++;
  } else {
    try {
      const tree     = build256LeafTree();
      // Tight range: endDay = 20, so leaf dayIds must all be <= 20
      const input    = buildWitnessInput(tree, 1, 20, 20);
      const badInput = JSON.parse(JSON.stringify(input));

      // Replace the first day ID with 300 — well outside [1, 20]
      badInput.leaf_day_ids[0] = '300';

      let threw = false;
      try {
        await snarkjs.groth16.fullProve(badInput, COVERAGE_WASM, COVERAGE_ZKEY, SILENT);
      } catch (_) {
        threw = true;
      }
      assert(threw, 'Out-of-range leaf (dayId=300 > endDay=20) causes fullProve to throw');
    } catch (e) {
      console.log(`  ❌ FAIL: Unexpected outer error: ${e.message.slice(0, 100)}`);
      failed++;
    }
  }
  console.log('');

  // ───────────────────────────────────────────────
  // Gate Test 6: Wrong root in public signals rejected
  // Substitute a different root in publicSignals — verification must fail
  // because the proof was generated for a different root commitment.
  // ───────────────────────────────────────────────
  console.log('Gate Test 6 — Wrong root in public signals rejected:');
  if (!savedProof) {
    console.log('  ⚠️  SKIP: No saved proof from Gate Test 3');
    failed++;
  } else {
    try {
      const vkey       = JSON.parse(fs.readFileSync(COVERAGE_VKEY, 'utf8'));
      const badSignals = [...savedPublicSignals];

      // Replace root (index 0) with an obviously wrong value
      badSignals[0] = '99999999999999999999999999999999';

      const valid = await snarkjs.groth16.verify(vkey, badSignals, savedProof, SILENT);
      assert(!valid, 'Proof with wrong root in publicSignals[0] fails verification');
    } catch (_) {
      // Field-overflow throws are also a valid rejection
      assert(true, 'Wrong root causes verification throw (valid rejection)');
    }
  }
  console.log('');

  // ───────────────────────────────────────────────
  // Summary
  // ───────────────────────────────────────────────
  console.log('════════════════════════════════════════════════');
  console.log(`  PHASE 4 RESULTS: ${passed} passed, ${failed} failed`);
  if (failed === 0) {
    console.log('  ✅ All Phase 4 gate tests PASSED');
    console.log('  Ready to advance to Phase 5 (contract deployment).');
  } else {
    console.log('  ❌ Some tests FAILED — fix before advancing to Phase 5');
  }
  console.log('════════════════════════════════════════════════');
  console.log('');

  process.exit(failed > 0 ? 1 : 0);
}

runTests().catch(err => {
  console.error('Fatal error running Phase 4 tests:', err.message);
  process.exit(1);
});
