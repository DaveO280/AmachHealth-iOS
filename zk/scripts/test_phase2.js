/**
 * test_phase2.js
 * Phase 2 gate tests — Poseidon Hashing
 *
 * All 4 gate tests must pass before advancing to Phase 3.
 * Run: node scripts/test_phase2.js
 */

'use strict';

const { hashLeaf, leafToChunks, buildTestLeaf, BN128_FIELD_SIZE } = require('./hash_leaf');

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
console.log('  PHASE 2 GATE TESTS — Poseidon Hashing');
console.log('════════════════════════════════════════════════');
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 1: Hash consistency
// Hash the same leaf twice — must produce identical output
// ─────────────────────────────────────────────────
console.log('Gate Test 1 — Hash consistency:');
{
  const leaf = buildTestLeaf({ dayId: 42 });
  const hash1 = hashLeaf(leaf);
  const hash2 = hashLeaf(leaf);
  assertEqual(hash1, hash2, 'Same leaf → same hash (run 1 vs run 2)');
  assertEqual(typeof hash1, 'bigint', 'Hash is a BigInt');
  console.log(`  hash: ${hash1.toString(16).slice(0, 32)}...`);
}
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 2: Hash sensitivity (avalanche effect)
// Flip one bit in the leaf — hash must change completely
// ─────────────────────────────────────────────────
console.log('Gate Test 2 — Hash sensitivity (avalanche effect):');
{
  const leaf1 = buildTestLeaf({ dayId: 42 });
  const leaf2 = Buffer.from(leaf1); // copy
  leaf2[0] ^= 0x01; // flip lowest bit of day_id

  const hash1 = hashLeaf(leaf1);
  const hash2 = hashLeaf(leaf2);

  assertNotEqual(hash1, hash2, 'Flipping bit 0 of day_id changes the hash');

  // Verify the hashes are substantially different (different in most bits)
  const h1hex = hash1.toString(16).padStart(64, '0');
  const h2hex = hash2.toString(16).padStart(64, '0');
  let differentBits = 0;
  for (let i = 0; i < 64; i++) {
    if (h1hex[i] !== h2hex[i]) differentBits++;
  }
  assert(differentBits > 10, 'Avalanche: >10 hex digits differ after 1-bit flip', `${differentBits} digits differ`);
}
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 3: Field element bounds
// All three chunks must be < BN128 field size
// ─────────────────────────────────────────────────
console.log('Gate Test 3 — Field element bounds:');
{
  // Test with extreme values (max uint32, 0xFF bytes)
  const extremeLeaf = buildTestLeaf({
    dayId: 0xFFFFFFFF,
    wallet: Buffer.alloc(32, 0xFF),
    timezoneOffset: 0x7FFF,  // max int16
    steps: 0xFFFFFFFF,
    activeEnergy: 0xFFFFFFFF,
    exerciseMins: 0xFFFF,
    hrv: 0xFFFF,
    restingHR: 0xFFFF,
    sleepMins: 0xFFFF,
    workoutCount: 0xFF,
    sourceCount: 0xFF,
    dataFlags: 0xFFFF,
    sourceHash: Buffer.alloc(32, 0xFF)
  });

  const { chunk1, chunk2, chunk3 } = leafToChunks(extremeLeaf);

  assert(chunk1 < BN128_FIELD_SIZE, 'chunk1 within BN128 field (max values)', `chunk1 = 0x${chunk1.toString(16).slice(0, 16)}...`);
  assert(chunk2 < BN128_FIELD_SIZE, 'chunk2 within BN128 field (max values)', `chunk2 = 0x${chunk2.toString(16).slice(0, 16)}...`);
  assert(chunk3 < BN128_FIELD_SIZE, 'chunk3 within BN128 field (max values)', `chunk3 = 0x${chunk3.toString(16).slice(0, 16)}...`);

  // Note: 31 bytes = 248 bits, which is < 254 bits (BN128 field). Chunks cannot overflow.
  console.log('  Note: 31-byte chunks are 248 bits < 254-bit field size — overflow impossible by construction.');

  // Confirm hash can be computed without throwing
  try {
    hashLeaf(extremeLeaf);
    assert(true, 'hashLeaf completes without field overflow error');
  } catch (e) {
    assert(false, 'hashLeaf should not throw for extreme values', e.message);
  }
}
console.log('');

// ─────────────────────────────────────────────────
// Gate Test 4: Cross-implementation check (JS side)
// Compute known hash values and log them for Circom verification.
// The Circom circuit test verifies the SAME inputs produce the SAME output.
// ─────────────────────────────────────────────────
console.log('Gate Test 4 — Cross-implementation reference values:');
{
  const testCases = [
    buildTestLeaf({ dayId: 0 }),    // epoch leaf
    buildTestLeaf({ dayId: 1 }),    // day 1
    buildTestLeaf({ dayId: 100 }),  // typical day
    buildTestLeaf({ steps: 0, activeEnergy: 0, exerciseMins: 0, hrv: 0, restingHR: 0, sleepMins: 0,
                    workoutCount: 0, sourceCount: 1, dataFlags: 0 }), // minimal leaf
  ];

  console.log('  Reference hashes for Circom verification:');
  console.log('  (These values must match your Circom circuit output for the same inputs)');
  console.log('');

  const referenceValues = testCases.map((leaf, i) => {
    const hash = hashLeaf(leaf);
    const { chunk1, chunk2, chunk3 } = leafToChunks(leaf);
    console.log(`  Case ${i}: dayId=${leaf.readUInt32BE(0)}`);
    console.log(`    chunk1: ${chunk1.toString(10)}`);
    console.log(`    chunk2: ${chunk2.toString(10)}`);
    console.log(`    chunk3: ${chunk3.toString(10)}`);
    console.log(`    hash:   ${hash.toString(10)}`);
    console.log(`    hash:   0x${hash.toString(16)}`);
    console.log('');
    return { leafHex: leaf.toString('hex'), chunk1: chunk1.toString(10), chunk2: chunk2.toString(10), chunk3: chunk3.toString(10), hash: hash.toString(10) };
  });

  // Save reference values for circuit testing
  const fs = require('fs');
  const path = require('path');
  const dataDir = path.join(__dirname, '../data');
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(
    path.join(dataDir, 'phase2_reference_hashes.json'),
    JSON.stringify(referenceValues, null, 2)
  );

  assert(referenceValues.length === 4, 'Generated 4 reference hash cases');
  console.log('  Reference values saved to: data/phase2_reference_hashes.json');
  console.log('  Use these with the LeafHashTest.circom circuit to confirm cross-implementation match.');
}
console.log('');

// ─────────────────────────────────────────────────
// Summary
// ─────────────────────────────────────────────────
console.log('════════════════════════════════════════════════');
console.log(`  PHASE 2 RESULTS: ${passed} passed, ${failed} failed`);
if (failed === 0) {
  console.log('  ✅ All Phase 2 gate tests PASSED');
  console.log('  Note: Gate Test 4 cross-circuit check must also pass after');
  console.log('  compiling and running circuits/LeafHashTest.circom with snarkJS.');
} else {
  console.log('  ❌ Some tests FAILED — fix before advancing to Phase 3');
}
console.log('════════════════════════════════════════════════');
console.log('');

process.exit(failed > 0 ? 1 : 0);
