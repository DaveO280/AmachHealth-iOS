/**
 * hash_leaf.test.js
 *
 * Jest coverage for the v1/v2 dispatch in zk/scripts/hash_leaf.js.
 *
 * Layer 0 acceptance criteria covered here:
 *   - v1 leaves still produce the same Poseidon3 hashes as before the v2
 *     refactor (no regression on existing on-chain commitments).
 *   - v2 leaves produce stable Poseidon4 hashes against the fixed cross-
 *     platform vectors that AmachLeafV2Tests.swift also asserts against.
 *   - The dispatch function picks the right variant from input length and
 *     rejects malformed lengths or wrong version bytes.
 */

'use strict';

const {
  hashLeaf,
  hashLeafV1,
  hashLeafV2,
  leafToChunks,
  chunksV1,
  chunksV2,
  buildTestLeafV1,
  buildTestLeafV2,
  V1_LEAF_BYTES,
  V2_LEAF_BYTES,
  V2_VERSION_BYTE
} = require('../hash_leaf');

const { VECTORS } = require('./v2_test_vectors');

// ─────────────────────────────────────────────────────────────────────────────
// Backward-compatibility: v1 hashing path must be byte-identical to the
// pre-refactor implementation. Captured against the original `buildTestLeaf()`
// default leaf at the moment of refactor.
// ─────────────────────────────────────────────────────────────────────────────

const V1_DEFAULT_HASH_DEC =
  '17179885469404872142164092827986967472057426223041017331885626938256671872211';

describe('hash_leaf — v1 backward compatibility', () => {
  test('default v1 leaf hashes to the pinned pre-refactor value', () => {
    const buf = buildTestLeafV1();
    expect(buf.length).toBe(V1_LEAF_BYTES);
    const hash = hashLeafV1(buf);
    expect(hash.toString(10)).toBe(V1_DEFAULT_HASH_DEC);
  });

  test('hashLeaf dispatches v1 by length', () => {
    const buf = buildTestLeafV1();
    expect(hashLeaf(buf).toString(10)).toBe(V1_DEFAULT_HASH_DEC);
  });

  test('chunksV1 last chunk is right-padded (28 bytes copied to 31-byte buffer)', () => {
    // Build a v1 leaf where bytes 62-89 are all 0xFF and confirm the chunk's
    // last 3 bytes are zero (the padding).
    const buf = buildTestLeafV1({ sourceHash: Buffer.alloc(32, 0xFF) });
    const [, , c3] = chunksV1(buf);
    // c3 as 31-byte big-endian: 28 bytes of FF then 3 bytes of 00
    const c3Hex = c3.toString(16).padStart(62, '0');
    expect(c3Hex.endsWith('000000')).toBe(true);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// v2 cross-platform hash vectors. Same fixtures, same expected hashes, as the
// Swift XCTest mirror. Any drift here is a cross-platform consistency break.
// ─────────────────────────────────────────────────────────────────────────────

describe('hash_leaf — v2 cross-platform vectors', () => {
  test.each(VECTORS.map((v) => [v.name, v]))(
    'fixture "%s" hashes to its pinned vector',
    (name, { serializedHex, expectedHashDec }) => {
      const buf = Buffer.from(serializedHex, 'hex');
      expect(buf.length).toBe(V2_LEAF_BYTES);

      const direct = hashLeafV2(buf);
      const dispatched = hashLeaf(buf);
      expect(direct.toString(10)).toBe(expectedHashDec);
      expect(dispatched.toString(10)).toBe(expectedHashDec);
      expect(typeof name).toBe('string');
    }
  );

  test('default v2 builder produces the default-mid-range vector', () => {
    const buf = buildTestLeafV2();
    expect(buf.length).toBe(V2_LEAF_BYTES);
    const v = VECTORS.find((x) => x.name === 'default_mid_range');
    expect(buf.toString('hex')).toBe(v.serializedHex);
    expect(hashLeafV2(buf).toString(10)).toBe(v.expectedHashDec);
  });

  test('hash differs for two v2 leaves that differ in only one byte', () => {
    const a = buildTestLeafV2();
    const b = buildTestLeafV2({ vo2max: 426 }); // default is 425
    expect(hashLeafV2(a)).not.toEqual(hashLeafV2(b));
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Dispatch and validation
// ─────────────────────────────────────────────────────────────────────────────

describe('hash_leaf — dispatch and validation', () => {
  test('hashLeaf rejects unsupported lengths', () => {
    expect(() => hashLeaf(Buffer.alloc(89, 0))).toThrow(/unsupported leaf length/);
    expect(() => hashLeaf(Buffer.alloc(91, 0))).toThrow(/unsupported leaf length/);
    expect(() => hashLeaf(Buffer.alloc(123, 0))).toThrow(/unsupported leaf length/);
    expect(() => hashLeaf(Buffer.alloc(125, 0))).toThrow(/unsupported leaf length/);
    expect(() => hashLeaf(Buffer.alloc(0, 0))).toThrow(/unsupported leaf length/);
  });

  test('hashLeaf rejects non-Buffer input', () => {
    expect(() => hashLeaf('not a buffer')).toThrow(/Buffer/);
    expect(() => hashLeaf(null)).toThrow(/Buffer/);
    expect(() => hashLeaf(undefined)).toThrow(/Buffer/);
  });

  test('hashLeafV2 rejects v1-length input', () => {
    expect(() => hashLeafV2(buildTestLeafV1())).toThrow(/expects a 124-byte/);
  });

  test('hashLeafV1 rejects v2-length input', () => {
    expect(() => hashLeafV1(buildTestLeafV2())).toThrow(/expects a 90-byte/);
  });

  test('chunksV2 rejects buffer with wrong version byte', () => {
    const buf = buildTestLeafV2();
    buf[0] = 0x01; // wrong version
    expect(() => chunksV2(buf)).toThrow(/version byte/);
  });

  test('leafToChunks reports correct version and chunk count', () => {
    const v1 = leafToChunks(buildTestLeafV1());
    expect(v1.version).toBe(1);
    expect(v1.chunks).toHaveLength(3);

    const v2 = leafToChunks(buildTestLeafV2());
    expect(v2.version).toBe(2);
    expect(v2.chunks).toHaveLength(4);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Round-trip and edge cases
// ─────────────────────────────────────────────────────────────────────────────

describe('hash_leaf — v2 edge cases', () => {
  test('all-zero metric payload (envelope only) hashes deterministically', () => {
    const v = VECTORS.find((x) => x.name === 'zeros_envelope_only');
    const buf = Buffer.from(v.serializedHex, 'hex');
    expect(hashLeafV2(buf).toString(10)).toBe(v.expectedHashDec);
  });

  test('all-max u16/u32 fields hash deterministically', () => {
    const v = VECTORS.find((x) => x.name === 'all_max');
    const buf = Buffer.from(v.serializedHex, 'hex');
    // Confirm we are actually exercising the upper-bit space.
    expect(buf.readUInt32BE(42)).toBe(0xFFFFFFFF); // steps
    expect(buf.readUInt16BE(64)).toBe(0xFFFF);      // vo2max
    expect(hashLeafV2(buf).toString(10)).toBe(v.expectedHashDec);
  });

  test('chunks v2 are each strictly less than BN128 field size', () => {
    const buf = buildTestLeafV2({
      // even at all-max, 31 bytes are < 2^248 < BN128 modulus
      wallet: Buffer.alloc(32, 0xFF),
      sourceHash: Buffer.alloc(32, 0xFF),
      reservedPayload: Buffer.alloc(12, 0)
    });
    const cs = chunksV2(buf);
    const FIELD = BigInt(
      '21888242871839275222246405745257275088548364400416034343698204186575808495617'
    );
    for (const c of cs) {
      expect(c < FIELD).toBe(true);
    }
  });
});
