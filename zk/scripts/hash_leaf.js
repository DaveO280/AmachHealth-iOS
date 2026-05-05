/**
 * hash_leaf.js
 * Amach Health ZK
 *
 * Poseidon hashing for Amach Merkle leaves. Dispatches on leaf version:
 *
 *   v1 (90 bytes, legacy):
 *     - Three 31-byte chunks (last is 28 bytes right-padded with zeros to 31)
 *     - Hash: Poseidon3([chunk1, chunk2, chunk3])
 *     - No version byte; selected when input length is 90 bytes
 *
 *   v2 (124 bytes, AmachLeafV2 / Spring Push Season One and beyond):
 *     - Four 31-byte chunks (124 = 4 * 31, no padding)
 *     - Hash: Poseidon4([chunk1, chunk2, chunk3, chunk4])
 *     - First byte is the version field; must equal 0x02
 *
 * The dispatch function is `hashLeaf(buf)` which picks the right hash by
 * inspecting the input. v1 callers using the legacy 90-byte path are
 * unchanged. v2 callers pass a 124-byte buffer whose first byte is 0x02.
 *
 * CRITICAL: Circuits and the Swift implementation (AmachLeafV2.swift,
 * LeafHashingService.swift) must use IDENTICAL chunking. Any deviation breaks
 * proofs and breaks Merkle reconstruction in the legitimacy script.
 */

'use strict';

const { poseidon3 } = require('poseidon-lite/poseidon3');
const { poseidon4 } = require('poseidon-lite/poseidon4');

// BN128 field size (scalar field of BN128 curve used by Groth16/circomlib)
const BN128_FIELD_SIZE = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');

const V1_LEAF_BYTES = 90;
const V2_LEAF_BYTES = 124;
const V2_VERSION_BYTE = 0x02;
const V2_LEAF_TYPE_DAILY_SUMMARY = 0x00;
const V2_SCHEMA_VERSION_DAILY_SUMMARY = 0x01;

// ─────────────────────────────────────────────────────────────────────────────
// Public API: dispatch on length / version byte
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Hash a serialized leaf. Auto-selects v1 (Poseidon3) or v2 (Poseidon4) based
 * on the buffer's length and (for v2) its version byte.
 * @param {Buffer} leafBytes
 * @returns {BigInt} Poseidon hash as a BN128 field element
 */
function hashLeaf(leafBytes) {
  if (!Buffer.isBuffer(leafBytes)) {
    throw new Error(`hashLeaf expects a Buffer, got ${typeof leafBytes}`);
  }
  if (leafBytes.length === V1_LEAF_BYTES) {
    return hashLeafV1(leafBytes);
  }
  if (leafBytes.length === V2_LEAF_BYTES) {
    return hashLeafV2(leafBytes);
  }
  throw new Error(
    `hashLeaf: unsupported leaf length ${leafBytes.length}. ` +
    `Expected ${V1_LEAF_BYTES} (v1) or ${V2_LEAF_BYTES} (v2).`
  );
}

/**
 * Decompose a leaf into the field-element chunks consumed by its Poseidon
 * variant. v1 returns 3 chunks; v2 returns 4. Useful for circuit witness
 * generation.
 * @param {Buffer} leafBytes
 * @returns {{ version: 1|2, chunks: BigInt[] }}
 */
function leafToChunks(leafBytes) {
  if (!Buffer.isBuffer(leafBytes)) {
    throw new Error('leafToChunks expects a Buffer');
  }
  if (leafBytes.length === V1_LEAF_BYTES) {
    return { version: 1, chunks: chunksV1(leafBytes) };
  }
  if (leafBytes.length === V2_LEAF_BYTES) {
    return { version: 2, chunks: chunksV2(leafBytes) };
  }
  throw new Error(
    `leafToChunks: unsupported leaf length ${leafBytes.length}. ` +
    `Expected ${V1_LEAF_BYTES} (v1) or ${V2_LEAF_BYTES} (v2).`
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// v1: Poseidon3 over three 31-byte chunks
// ─────────────────────────────────────────────────────────────────────────────
//
// Chunking layout (preserved verbatim from the original v1 implementation —
// existing on-chain commitments depend on it):
//   Chunk 1: bytes  0-30  (31 bytes)
//   Chunk 2: bytes 31-61  (31 bytes)
//   Chunk 3: bytes 62-89  (28 bytes), zero-padded to 31 on the RIGHT
//
function chunksV1(leafBytes) {
  const chunk1 = BigInt('0x' + leafBytes.slice(0, 31).toString('hex'));
  const chunk2 = BigInt('0x' + leafBytes.slice(31, 62).toString('hex'));
  const chunk3Buf = Buffer.alloc(31, 0);
  leafBytes.slice(62, 90).copy(chunk3Buf, 0); // 28 bytes copied to start of 31-byte buffer
  const chunk3 = BigInt('0x' + chunk3Buf.toString('hex'));

  validateFieldElement(chunk1, 'v1.chunk1');
  validateFieldElement(chunk2, 'v1.chunk2');
  validateFieldElement(chunk3, 'v1.chunk3');

  return [chunk1, chunk2, chunk3];
}

function hashLeafV1(leafBytes) {
  if (leafBytes.length !== V1_LEAF_BYTES) {
    throw new Error(`hashLeafV1 expects a ${V1_LEAF_BYTES}-byte Buffer, got ${leafBytes.length}`);
  }
  const [c1, c2, c3] = chunksV1(leafBytes);
  return poseidon3([c1, c2, c3]);
}

// ─────────────────────────────────────────────────────────────────────────────
// v2: Poseidon4 over four 31-byte chunks
// ─────────────────────────────────────────────────────────────────────────────
//
// 124 = 4 * 31 exactly, so no padding is required. The schema in
// VERIFICATION_FACTORY.md was sized for this property.
//
//   Chunk 1: bytes   0-30  (31 bytes) — envelope (4) + wallet[0..27]
//   Chunk 2: bytes  31-61  (31 bytes) — wallet[27..32] + dayId + tz + steps + ...
//   Chunk 3: bytes  62-92  (31 bytes) — vo2max + body comp + sleep stages + reserved[0..1]
//   Chunk 4: bytes  93-123 (31 bytes) — reserved[1..12] + sourceHash[0..19]
//
// (Per-byte field-position details live in AmachLeafV2.swift / VERIFICATION_FACTORY.md.)
//
function chunksV2(leafBytes) {
  // Envelope sanity. We don't enforce leafType / schemaVersion here because
  // the hash function is content-agnostic — that's the validator's job — but
  // the version byte is a low-cost check that catches v1-buffer-handed-to-v2
  // mistakes immediately.
  if (leafBytes[0] !== V2_VERSION_BYTE) {
    throw new Error(
      `chunksV2: expected version byte 0x${V2_VERSION_BYTE.toString(16)}, ` +
      `got 0x${leafBytes[0].toString(16)}`
    );
  }
  const chunk1 = BigInt('0x' + leafBytes.slice(0, 31).toString('hex'));
  const chunk2 = BigInt('0x' + leafBytes.slice(31, 62).toString('hex'));
  const chunk3 = BigInt('0x' + leafBytes.slice(62, 93).toString('hex'));
  const chunk4 = BigInt('0x' + leafBytes.slice(93, 124).toString('hex'));

  validateFieldElement(chunk1, 'v2.chunk1');
  validateFieldElement(chunk2, 'v2.chunk2');
  validateFieldElement(chunk3, 'v2.chunk3');
  validateFieldElement(chunk4, 'v2.chunk4');

  return [chunk1, chunk2, chunk3, chunk4];
}

function hashLeafV2(leafBytes) {
  if (leafBytes.length !== V2_LEAF_BYTES) {
    throw new Error(`hashLeafV2 expects a ${V2_LEAF_BYTES}-byte Buffer, got ${leafBytes.length}`);
  }
  const [c1, c2, c3, c4] = chunksV2(leafBytes);
  return poseidon4([c1, c2, c3, c4]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Validation
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Validate that a value is a valid BN128 field element (< field size).
 * @param {BigInt} value
 * @param {string} name - Label for error messages
 */
function validateFieldElement(value, name = 'value') {
  if (value >= BN128_FIELD_SIZE) {
    throw new Error(
      `Field element overflow: ${name} (${value.toString(16)}) >= BN128 field size.\n` +
      `This means chunk data exceeds 253 bits. Check leaf serialization.`
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test-leaf builders
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Build a 90-byte v1 leaf with known values. Layout matches the legacy v1
 * spec in MerkleLeaf.swift.
 * @param {object} overrides
 * @returns {Buffer} 90-byte buffer
 */
function buildTestLeafV1(overrides = {}) {
  const defaults = {
    dayId: 42,
    wallet: Buffer.alloc(32, 0xAB),
    timezoneOffset: -300,
    steps: 8500,
    activeEnergy: 35000,
    exerciseMins: 60,
    hrv: 412,
    restingHR: 560,
    sleepMins: 450,
    workoutCount: 2,
    sourceCount: 3,
    dataFlags: 0b0000_0001_0111_1111,
    sourceHash: Buffer.alloc(32, 0xCC)
  };
  const f = { ...defaults, ...overrides };
  const buf = Buffer.alloc(V1_LEAF_BYTES, 0);
  let offset = 0;
  buf.writeUInt32BE(f.dayId, offset); offset += 4;
  toBuf32(f.wallet).copy(buf, offset, 0, 32); offset += 32;
  buf.writeInt16BE(f.timezoneOffset, offset); offset += 2;
  buf.writeUInt32BE(f.steps, offset); offset += 4;
  buf.writeUInt32BE(f.activeEnergy, offset); offset += 4;
  buf.writeUInt16BE(f.exerciseMins, offset); offset += 2;
  buf.writeUInt16BE(f.hrv, offset); offset += 2;
  buf.writeUInt16BE(f.restingHR, offset); offset += 2;
  buf.writeUInt16BE(f.sleepMins, offset); offset += 2;
  buf.writeUInt8(f.workoutCount, offset); offset += 1;
  buf.writeUInt8(f.sourceCount, offset); offset += 1;
  buf.writeUInt16BE(f.dataFlags, offset); offset += 2;
  toBuf32(f.sourceHash).copy(buf, offset, 0, 32); offset += 32;
  if (offset !== V1_LEAF_BYTES) {
    throw new Error(`buildTestLeafV1 internal: wrote ${offset} bytes, expected ${V1_LEAF_BYTES}`);
  }
  return buf;
}

/**
 * Build a 124-byte v2 leaf with known values. Layout matches AmachLeafV2.
 * Envelope defaults to the v2.0 daily_summary contract; pass overrides to
 * deliberately produce malformed leaves for validator tests.
 * @param {object} overrides
 * @returns {Buffer} 124-byte buffer
 */
function buildTestLeafV2(overrides = {}) {
  const defaults = {
    version: V2_VERSION_BYTE,
    leafType: V2_LEAF_TYPE_DAILY_SUMMARY,
    schemaVersion: V2_SCHEMA_VERSION_DAILY_SUMMARY,
    reservedEnvelope: 0,
    wallet: Buffer.alloc(32, 0xAB),
    dayId: 42,
    timezoneOffset: -300,
    steps: 8500,
    activeEnergy: 35000,
    exerciseMins: 60,
    hrv: 412,
    restingHR: 560,
    sleepMins: 450,
    workoutCount: 2,
    sourceCount: 3,
    dataFlags: 0x000F_03FF, // wide pattern across both u16 halves
    vo2max: 425,
    weight: 7800,           // 78.00 kg in grams/10
    bodyFatPct: 1850,       // 18.50%
    leanMass: 6300,         // 63.00 kg lean
    deepSleepMins: 75,
    remSleepMins: 95,
    lightSleepMins: 240,
    awakeMins: 20,
    reservedPayload: Buffer.alloc(12, 0),
    sourceHash: Buffer.alloc(32, 0xCC)
  };
  const f = { ...defaults, ...overrides };
  const buf = Buffer.alloc(V2_LEAF_BYTES, 0);
  let o = 0;
  buf.writeUInt8(f.version, o); o += 1;
  buf.writeUInt8(f.leafType, o); o += 1;
  buf.writeUInt8(f.schemaVersion, o); o += 1;
  buf.writeUInt8(f.reservedEnvelope, o); o += 1;
  toBuf32(f.wallet).copy(buf, o, 0, 32); o += 32;
  buf.writeUInt32BE(f.dayId, o); o += 4;
  buf.writeInt16BE(f.timezoneOffset, o); o += 2;
  buf.writeUInt32BE(f.steps, o); o += 4;
  buf.writeUInt32BE(f.activeEnergy, o); o += 4;
  buf.writeUInt16BE(f.exerciseMins, o); o += 2;
  buf.writeUInt16BE(f.hrv, o); o += 2;
  buf.writeUInt16BE(f.restingHR, o); o += 2;
  buf.writeUInt16BE(f.sleepMins, o); o += 2;
  buf.writeUInt8(f.workoutCount, o); o += 1;
  buf.writeUInt8(f.sourceCount, o); o += 1;
  buf.writeUInt32BE(f.dataFlags, o); o += 4;
  buf.writeUInt16BE(f.vo2max, o); o += 2;
  buf.writeUInt16BE(f.weight, o); o += 2;
  buf.writeUInt16BE(f.bodyFatPct, o); o += 2;
  buf.writeUInt16BE(f.leanMass, o); o += 2;
  buf.writeUInt16BE(f.deepSleepMins, o); o += 2;
  buf.writeUInt16BE(f.remSleepMins, o); o += 2;
  buf.writeUInt16BE(f.lightSleepMins, o); o += 2;
  buf.writeUInt16BE(f.awakeMins, o); o += 2;
  toBufN(f.reservedPayload, 12).copy(buf, o, 0, 12); o += 12;
  toBuf32(f.sourceHash).copy(buf, o, 0, 32); o += 32;
  if (o !== V2_LEAF_BYTES) {
    throw new Error(`buildTestLeafV2 internal: wrote ${o} bytes, expected ${V2_LEAF_BYTES}`);
  }
  return buf;
}

// Back-compat alias: legacy callers used buildTestLeaf for the v1 path.
const buildTestLeaf = buildTestLeafV1;

function toBuf32(input) {
  if (Buffer.isBuffer(input)) {
    if (input.length === 32) return input;
    const out = Buffer.alloc(32, 0);
    if (input.length > 32) {
      input.slice(0, 32).copy(out, 0);
    } else {
      input.copy(out, 32 - input.length);
    }
    return out;
  }
  return toBuf32(Buffer.from(input));
}

function toBufN(input, n) {
  if (Buffer.isBuffer(input)) {
    if (input.length === n) return input;
    const out = Buffer.alloc(n, 0);
    input.copy(out, 0, 0, Math.min(n, input.length));
    return out;
  }
  return toBufN(Buffer.from(input), n);
}

module.exports = {
  // dispatch
  hashLeaf,
  leafToChunks,
  // version-pinned variants
  hashLeafV1,
  hashLeafV2,
  chunksV1,
  chunksV2,
  // builders
  buildTestLeaf,    // alias for v1 (back-compat)
  buildTestLeafV1,
  buildTestLeafV2,
  // helpers
  validateFieldElement,
  // constants
  BN128_FIELD_SIZE,
  V1_LEAF_BYTES,
  V2_LEAF_BYTES,
  V2_VERSION_BYTE,
  V2_LEAF_TYPE_DAILY_SUMMARY,
  V2_SCHEMA_VERSION_DAILY_SUMMARY
};

// CLI mode: `node scripts/hash_leaf.js [v1|v2]`. Defaults to v2.
if (require.main === module) {
  const which = (process.argv[2] || 'v2').toLowerCase();
  if (which === 'v1') {
    const buf = buildTestLeafV1();
    const hash = hashLeafV1(buf);
    console.log(`v1 test leaf (${buf.length} bytes):`);
    console.log('  hex:', buf.toString('hex'));
    console.log('  poseidon3 hash (decimal):', hash.toString(10));
    console.log('  poseidon3 hash (hex):    ', hash.toString(16));
    const [c1, c2, c3] = chunksV1(buf);
    console.log('  chunks:', { chunk1: c1.toString(10), chunk2: c2.toString(10), chunk3: c3.toString(10) });
  } else {
    const buf = buildTestLeafV2();
    const hash = hashLeafV2(buf);
    console.log(`v2 test leaf (${buf.length} bytes):`);
    console.log('  hex:', buf.toString('hex'));
    console.log('  poseidon4 hash (decimal):', hash.toString(10));
    console.log('  poseidon4 hash (hex):    ', hash.toString(16));
    const [c1, c2, c3, c4] = chunksV2(buf);
    console.log('  chunks:', {
      chunk1: c1.toString(10),
      chunk2: c2.toString(10),
      chunk3: c3.toString(10),
      chunk4: c4.toString(10)
    });
  }
}
