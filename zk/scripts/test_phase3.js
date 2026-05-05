/**
 * test_phase3.js
 * Phase 3 gate tests — Merkle Tree Construction
 *
 * All 5 gate tests must pass before advancing to Phase 4.
 * Run: node scripts/test_phase3.js
 */

'use strict';

const { buildMerkleTree, getMerklePath, verifyMerklePath, nextPowerOf2 } = require('./build_tree');
const { buildTestLeaf, hashLeaf } = require('./hash_leaf');
const { poseidon2 } = require('poseidon-lite');

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

function assertNotEqual(a, b, testName) {
  if (a !== b) {
    console.log(`  ✅ PASS: ${testName}`);
    passed++;
  } else {
    console.log(`  ❌ FAIL: ${testName} — values are identical when they should differ`);
    failed++;
  }
}

console.log('');
console.log('════════════════════════════════════════════════');
console.log('  PHASE 3 GATE TESTS — Merkle Tree Construction');
console.log('════════════════════════════════════════════════');
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 1: Small tree by hand (4 leaves)
// Build a tree with 4 known leaves and verify root manually
// ─────────────────────────────────────────────────
console.log('Gate Test 1 — Small tree manual verification:');
{
  const leaves = [
    buildTestLeaf({ dayId: 0 }),
    buildTestLeaf({ dayId: 1 }),
    buildTestLeaf({ dayId: 2 }),
    buildTestLeaf({ dayId: 3 })
  ];

  const result = buildMerkleTree(leaves);

  // Manually compute what the root should be
  const h0 = hashLeaf(leaves[0]);
  const h1 = hashLeaf(leaves[1]);
  const h2 = hashLeaf(leaves[2]);
  const h3 = hashLeaf(leaves[3]);

  // Level 1 (internal nodes)
  const n01 = poseidon2([h0, h1]);
  const n23 = poseidon2([h2, h3]);

  // Root
  const expectedRoot = poseidon2([n01, n23]);

  assertEqual(result.root, expectedRoot, '4-leaf tree root matches manual computation');
  assertEqual(result.depth, 2, 'Tree depth = 2 for 4 leaves');
  assertEqual(result.leafCount, 4, 'Leaf count = 4');
  assertEqual(result.treeSize, 4, 'Tree size = 4 (no padding needed)');
  console.log(`  Root: 0x${result.root.toString(16).slice(0, 32)}...`);
}
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 2: Root stability
// Same leaves → same root across multiple runs
// ─────────────────────────────────────────────────
console.log('Gate Test 2 — Root stability:');
{
  const leaves = Array.from({ length: 7 }, (_, i) => buildTestLeaf({ dayId: i * 10 }));

  const r1 = buildMerkleTree([...leaves]);
  const r2 = buildMerkleTree([...leaves]);

  assertEqual(r1.root, r2.root, 'Same leaves → identical root across runs');
  assertEqual(r1.depth, r2.depth, 'Depth is stable across runs');
}
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 3: Leaf order sensitivity
// Swapping two leaves must change the root
// (confirms sorting matters for commitments)
// ─────────────────────────────────────────────────
console.log('Gate Test 3 — Leaf order sensitivity:');
{
  const leaf0 = buildTestLeaf({ dayId: 0 });
  const leaf1 = buildTestLeaf({ dayId: 1 });
  const leaf2 = buildTestLeaf({ dayId: 2 });
  const leaf3 = buildTestLeaf({ dayId: 3 });

  const original = buildMerkleTree([leaf0, leaf1, leaf2, leaf3]);

  // Swap leaf0 and leaf1
  const swapped = buildMerkleTree([leaf1, leaf0, leaf2, leaf3]);

  assertNotEqual(original.root, swapped.root, 'Swapping leaves[0] and leaves[1] changes root');
  console.log('  Original root: 0x' + original.root.toString(16).slice(0, 16) + '...');
  console.log('  Swapped root:  0x' + swapped.root.toString(16).slice(0, 16) + '...');
}
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 4: Merkle path verification
// For each leaf in a 4-leaf tree, generate and verify the path
// ─────────────────────────────────────────────────
console.log('Gate Test 4 — Merkle path verification:');
{
  const leaves = [
    buildTestLeaf({ dayId: 10 }),
    buildTestLeaf({ dayId: 20 }),
    buildTestLeaf({ dayId: 30 }),
    buildTestLeaf({ dayId: 40 })
  ];

  const { root, tree } = buildMerkleTree(leaves);

  for (let i = 0; i < leaves.length; i++) {
    const { siblings, indices, leaf } = getMerklePath(tree, i);
    const valid = verifyMerklePath(leaf, siblings, indices, root);
    assert(valid, `Merkle path for leaf[${i}] (dayId=${10 * (i+1)}) verifies correctly`);
  }

  // Test with a larger tree (8 leaves — depth 3)
  const bigLeaves = Array.from({ length: 8 }, (_, i) => buildTestLeaf({ dayId: i * 5 }));
  const bigResult = buildMerkleTree(bigLeaves);

  for (let i = 0; i < 8; i++) {
    const { siblings, indices, leaf } = getMerklePath(bigResult.tree, i);
    const valid = verifyMerklePath(leaf, siblings, indices, bigResult.root);
    assert(valid, `8-leaf tree: path for leaf[${i}] verifies`);
  }
}
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 5: Tree padding behavior
// Trees with non-power-of-2 leaf counts must pad correctly
// ─────────────────────────────────────────────────
console.log('Gate Test 5 — Tree padding behavior:');
{
  // 3 leaves → padded to 4
  const threeLeaves = [
    buildTestLeaf({ dayId: 0 }),
    buildTestLeaf({ dayId: 1 }),
    buildTestLeaf({ dayId: 2 })
  ];

  const r3 = buildMerkleTree(threeLeaves);
  assertEqual(r3.leafCount, 3, '3 real leaves');
  assertEqual(r3.treeSize, 4, 'Padded to 4 (next power of 2)');

  // Padding doesn't change the real leaf hashes
  assertEqual(r3.leafHashes[0], hashLeaf(threeLeaves[0]), 'Real leaf[0] hash preserved after padding');
  assertEqual(r3.leafHashes[1], hashLeaf(threeLeaves[1]), 'Real leaf[1] hash preserved after padding');
  assertEqual(r3.leafHashes[2], hashLeaf(threeLeaves[2]), 'Real leaf[2] hash preserved after padding');

  // 5 leaves → padded to 8
  const fiveLeaves = Array.from({ length: 5 }, (_, i) => buildTestLeaf({ dayId: i }));
  const r5 = buildMerkleTree(fiveLeaves);
  assertEqual(r5.leafCount, 5, '5 real leaves');
  assertEqual(r5.treeSize, 8, 'Padded to 8 (next power of 2)');
  assertEqual(r5.depth, 3, 'Depth = 3 for 8-node padded tree');

  // nextPowerOf2 helper
  assertEqual(nextPowerOf2(1), 1, 'nextPowerOf2(1) = 1');
  assertEqual(nextPowerOf2(2), 2, 'nextPowerOf2(2) = 2');
  assertEqual(nextPowerOf2(3), 4, 'nextPowerOf2(3) = 4');
  assertEqual(nextPowerOf2(5), 8, 'nextPowerOf2(5) = 8');
  assertEqual(nextPowerOf2(65), 128, 'nextPowerOf2(65) = 128');
}
console.log('');

// ─────────────────────────────────────────────────
// Bonus: Simulate genesis root from 90-day window
// Build a realistic 80-leaf tree (simulating a real user window)
// ─────────────────────────────────────────────────
console.log('Bonus — Simulated 80-day genesis root:');
{
  // 80 days (simulating ~90 days with gaps)
  const realisticLeaves = Array.from({ length: 80 }, (_, i) => {
    return buildTestLeaf({
      dayId: i + 1,  // day 1 through 80
      steps: 5000 + (i * 137 % 5000),
      activeEnergy: 20000 + (i * 97 % 20000),
      sleepMins: 360 + (i * 13 % 120),
      dataFlags: 0b0000_0000_0010_0001  // steps + sleep present
    });
  });

  const genesisResult = buildMerkleTree(realisticLeaves);

  console.log(`  Leaves: ${genesisResult.leafCount}`);
  console.log(`  Tree depth: ${genesisResult.depth}`);
  console.log(`  Genesis root: 0x${genesisResult.root.toString(16)}`);

  assert(genesisResult.depth <= 8, `Tree depth (${genesisResult.depth}) ≤ 8 (circuit parameter)`);
  assert(genesisResult.leafCount === 80, 'All 80 leaves committed');

  // Verify a random path
  const { siblings, indices, leaf } = getMerklePath(genesisResult.tree, 40);
  const valid = verifyMerklePath(leaf, siblings, indices, genesisResult.root);
  assert(valid, 'Merkle path for leaf[40] in 80-leaf genesis tree verifies');
}
console.log('');

// ─────────────────────────────────────────────────
// Summary
// ─────────────────────────────────────────────────
console.log('════════════════════════════════════════════════');
console.log(`  PHASE 3 RESULTS: ${passed} passed, ${failed} failed`);
if (failed === 0) {
  console.log('  ✅ All Phase 3 gate tests PASSED');
  console.log('  Ready to advance to Phase 4 (Circom circuit).');
} else {
  console.log('  ❌ Some tests FAILED — fix before advancing to Phase 4');
}
console.log('════════════════════════════════════════════════');
console.log('');

process.exit(failed > 0 ? 1 : 0);
