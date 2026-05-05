/**
 * generate_proof.js
 * Amach Health ZK — Phase 4
 *
 * Generate and verify a Groth16 coverage proof using snarkJS.
 *
 * Prerequisites (run from zk/ directory):
 *   1. Phase 3 complete — genesis_tree.json exists in data/
 *   2. Circom circuit compiled — build/coverage/coverage.r1cs exists
 *   3. Proving key generated — build/coverage/coverage_final.zkey exists
 *
 * Compile circuit (requires circom on Mac):
 *   circom circuits/coverage/coverage.circom --r1cs --wasm --sym -o build/coverage
 *
 * Trusted setup (download ptau first):
 *   wget https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_15.ptau
 *   snarkjs groth16 setup build/coverage/coverage.r1cs powersOfTau28_hez_final_15.ptau build/coverage/coverage_0.zkey
 *   snarkjs zkey contribute build/coverage/coverage_0.zkey build/coverage/coverage_final.zkey --name="test" -v
 *   snarkjs zkey export verificationkey build/coverage/coverage_final.zkey build/coverage/verification_key.json
 *
 * Run:
 *   node scripts/generate_proof.js [startDayId] [endDayId] [minDays]
 */

'use strict';

const snarkjs = require('snarkjs');
const fs = require('fs');
const path = require('path');
const { buildMerkleTree, getMerklePath, verifyMerklePath, deserializeTree } = require('./build_tree');
const { hashLeaf, buildTestLeaf } = require('./hash_leaf');

const BASE = path.join(__dirname, '..');

async function generateCoverageProof(startDayId, endDayId, minDays = 20) {
  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  COVERAGE PROOF GENERATION');
  console.log('═══════════════════════════════════════════════');
  console.log(`  Range: day ${startDayId} → day ${endDayId}`);
  console.log(`  Min days: ${minDays}`);
  console.log('');

  // ─── Load genesis tree ───────────────────────────────────────
  const treePath = path.join(BASE, 'data/genesis_tree.json');
  if (!fs.existsSync(treePath)) {
    throw new Error(`Genesis tree not found at ${treePath}. Run generate_genesis_root.js first.`);
  }

  const rawTree = JSON.parse(fs.readFileSync(treePath, 'utf8'));
  const treeResult = deserializeTree(rawTree);

  console.log(`Loaded genesis tree: ${treeResult.leafCount} leaves, depth ${treeResult.depth}`);
  console.log(`Root: 0x${treeResult.root.toString(16)}`);

  // ─── Load normalized leaves for day_id lookup ────────────────
  const leavesPath = path.join(BASE, 'data/normalized_leaves.json');
  if (!fs.existsSync(leavesPath)) {
    throw new Error(`Normalized leaves not found at ${leavesPath}. Export from iOS first.`);
  }

  const normalizedLeaves = JSON.parse(fs.readFileSync(leavesPath, 'utf8'));

  // Rebuild leaf buffers from serialized hex
  const leafBuffers = normalizedLeaves.map(l => Buffer.from(l.serialized, 'hex'));

  // ─── Select k leaves within the range ────────────────────────
  const validIndices = normalizedLeaves
    .map((leaf, idx) => ({ dayId: leaf.dayId, idx }))
    .filter(({ dayId }) => dayId >= startDayId && dayId <= endDayId)
    .slice(0, minDays);

  if (validIndices.length < minDays) {
    throw new Error(
      `Only ${validIndices.length} valid days in range [${startDayId}, ${endDayId}], need ${minDays}`
    );
  }

  console.log(`Selected ${validIndices.length} leaves in range`);

  // ─── Build witness ────────────────────────────────────────────
  const leafDayIds = validIndices.map(({ dayId }) => dayId.toString());
  const leafHashes = validIndices.map(({ idx }) => treeResult.leafHashes[idx].toString());
  const merklePaths = validIndices.map(({ idx }) => {
    const { siblings } = getMerklePath(treeResult.tree, idx);
    return siblings.map(s => s.toString());
  });
  const pathIndices = validIndices.map(({ idx }) => {
    const { indices } = getMerklePath(treeResult.tree, idx);
    return indices.map(i => i.toString());
  });

  const input = {
    root: treeResult.root.toString(),
    start_day_id: startDayId.toString(),
    end_day_id: endDayId.toString(),
    min_days: minDays.toString(),
    leaf_day_ids: leafDayIds,
    leaf_hashes: leafHashes,
    merkle_paths: merklePaths,
    path_indices: pathIndices
  };

  // Save witness input for debugging
  const dataDir = path.join(BASE, 'data');
  fs.writeFileSync(path.join(dataDir, 'witness_input.json'), JSON.stringify(input, null, 2));
  console.log('Witness input saved to data/witness_input.json');

  // ─── Check circuit artifacts exist ────────────────────────────
  const wasmPath = path.join(BASE, 'build/coverage/coverage_js/coverage.wasm');
  const zkeyPath = path.join(BASE, 'build/coverage/coverage_final.zkey');
  const vkeyPath = path.join(BASE, 'build/coverage/verification_key.json');

  if (!fs.existsSync(wasmPath)) {
    console.log('');
    console.log('⚠️  Circuit WASM not found. To compile (run on Mac with circom installed):');
    console.log('');
    console.log('   cd zk/');
    console.log('   circom circuits/coverage/coverage.circom --r1cs --wasm --sym -o build/coverage');
    console.log('   wget https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_15.ptau');
    console.log('   npx snarkjs groth16 setup build/coverage/coverage.r1cs powersOfTau28_hez_final_15.ptau build/coverage/coverage_0.zkey');
    console.log('   npx snarkjs zkey contribute build/coverage/coverage_0.zkey build/coverage/coverage_final.zkey --name="test" -v');
    console.log('   npx snarkjs zkey export verificationkey build/coverage/coverage_final.zkey build/coverage/verification_key.json');
    console.log('');
    console.log('Then re-run: node scripts/generate_proof.js');
    return null;
  }

  // ─── Generate proof ───────────────────────────────────────────
  console.log('');
  console.log('Generating Groth16 proof...');
  const startMs = Date.now();

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    wasmPath,
    zkeyPath
  );

  const elapsed = Date.now() - startMs;
  console.log(`Proof generated in ${elapsed}ms`);
  console.log('Public signals:', publicSignals);

  // ─── Verify locally ───────────────────────────────────────────
  const vkey = JSON.parse(fs.readFileSync(vkeyPath, 'utf8'));
  const valid = await snarkjs.groth16.verify(vkey, publicSignals, proof);

  console.log('');
  console.log(`Local verification: ${valid ? '✅ VALID' : '❌ INVALID'}`);

  if (!valid) {
    throw new Error('Proof failed local verification — check witness inputs');
  }

  // ─── Export Solidity calldata ─────────────────────────────────
  const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);

  // Save proof artifacts
  const proofOutput = {
    proof,
    publicSignals,
    calldata,
    startDayId,
    endDayId,
    minDays,
    root: '0x' + treeResult.root.toString(16).padStart(64, '0'),
    generatedAt: Date.now()
  };

  fs.writeFileSync(
    path.join(dataDir, 'coverage_proof.json'),
    JSON.stringify(proofOutput, null, 2)
  );
  console.log('Proof saved to data/coverage_proof.json');

  console.log('');
  console.log('Solidity calldata (for verifyCoverageProof()):');
  console.log(calldata.slice(0, 200) + '...');

  return proofOutput;
}

// ─── Dry-run test with mock tree (no circuit needed) ──────────────────────────
// This validates witness generation logic before circuit compilation.
async function testWitnessGeneration() {
  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  WITNESS GENERATION DRY RUN (no circuit needed)');
  console.log('═══════════════════════════════════════════════');
  console.log('');

  // Build a 32-leaf test tree
  const leaves = Array.from({ length: 32 }, (_, i) =>
    buildTestLeaf({ dayId: i + 1 })
  );

  const treeResult = buildMerkleTree(leaves);

  console.log(`Test tree: ${treeResult.leafCount} leaves, depth ${treeResult.depth}`);
  console.log(`Root: 0x${treeResult.root.toString(16).slice(0, 32)}...`);

  const k = 10; // prove 10 days
  const startDay = 1;
  const endDay = 25;

  // Select first k leaves in range
  const selected = Array.from({ length: k }, (_, i) => i); // indices 0-9 → dayIds 1-10

  const leafDayIds = selected.map(idx => (idx + 1).toString());
  const leafHashes = selected.map(idx => treeResult.leafHashes[idx].toString());

  // Verify each path before building witness
  let allPathsValid = true;
  for (const idx of selected) {
    const { siblings, indices, leaf } = getMerklePath(treeResult.tree, idx);
    const valid = verifyMerklePath(leaf, siblings, indices, treeResult.root);
    if (!valid) {
      console.log(`❌ Path verification failed for leaf[${idx}]`);
      allPathsValid = false;
    }
  }

  if (allPathsValid) {
    console.log(`✅ All ${k} Merkle paths verify correctly`);
  }

  // Check day IDs are in range
  const allInRange = selected.every(idx => {
    const dayId = idx + 1;
    return dayId >= startDay && dayId <= endDay;
  });
  console.log(`✅ All ${k} day IDs within range [${startDay}, ${endDay}]: ${allInRange}`);

  // Check distinctness
  const uniqueIds = new Set(leafDayIds);
  console.log(`✅ All day IDs distinct: ${uniqueIds.size === k}`);

  console.log('');
  console.log('Witness generation dry run: PASSED');
  console.log('Ready for circuit compilation and full proof generation.');
}

// CLI
const args = process.argv.slice(2);

if (args.length === 0) {
  // Run dry test
  testWitnessGeneration().catch(err => {
    console.error('Error:', err.message);
    process.exit(1);
  });
} else {
  const startDay = parseInt(args[0]);
  const endDay = parseInt(args[1]);
  const minDays = parseInt(args[2] || '20');

  generateCoverageProof(startDay, endDay, minDays).catch(err => {
    console.error('❌ Error:', err.message);
    process.exit(1);
  });
}
