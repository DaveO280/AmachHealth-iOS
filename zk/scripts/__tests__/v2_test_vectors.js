/**
 * v2_test_vectors.js
 *
 * Cross-platform hash vectors for AmachLeafV2. Five fixed leaves with their
 * expected Poseidon4 hashes (decimal). Both the Jest tests in this directory
 * and the Swift XCTest in AmachHealth/Tests/AmachLeafV2Tests.swift assert
 * against this same set, which is how Layer 0's cross-platform consistency
 * acceptance criterion is anchored.
 *
 * To extend: add a new entry to FIXTURES, run `node scripts/__tests__/v2_test_vectors.js`
 * and copy the printed `expectedHashDec` value into the entry. The Swift side
 * picks up the entry from its own mirror in AmachLeafV2Tests.swift (kept in
 * sync by hand — only five vectors today, scales to 100 in the next session
 * via a generator).
 */

'use strict';

const { hashLeafV2, buildTestLeafV2, V2_LEAF_BYTES } = require('../hash_leaf');

// ─────────────────────────────────────────────────────────────────────────────
// Fixture inputs. Designed to exercise:
//   - all-zeros payload (envelope only)
//   - the default mid-range case
//   - all-max u16/u32 fields
//   - elite athlete (high vo2max, low rhr, deep sleep dominant)
//   - sedentary day (mostly zero metrics, valid envelope)
// ─────────────────────────────────────────────────────────────────────────────

const FIXTURES = [
  {
    name: 'zeros_envelope_only',
    input: {
      wallet: Buffer.alloc(32, 0x00),
      dayId: 0,
      timezoneOffset: 0,
      steps: 0,
      activeEnergy: 0,
      exerciseMins: 0,
      hrv: 0,
      restingHR: 0,
      sleepMins: 0,
      workoutCount: 0,
      sourceCount: 0,
      dataFlags: 0,
      vo2max: 0,
      weight: 0,
      bodyFatPct: 0,
      leanMass: 0,
      deepSleepMins: 0,
      remSleepMins: 0,
      lightSleepMins: 0,
      awakeMins: 0,
      sourceHash: Buffer.alloc(32, 0x00)
    }
  },
  {
    name: 'default_mid_range',
    input: {} // uses buildTestLeafV2 defaults
  },
  {
    name: 'all_max',
    input: {
      wallet: Buffer.alloc(32, 0xFF),
      dayId: 0xFFFF_FFFF,
      timezoneOffset: 32767,
      steps: 0xFFFF_FFFF,
      activeEnergy: 0xFFFF_FFFF,
      exerciseMins: 0xFFFF,
      hrv: 0xFFFF,
      restingHR: 0xFFFF,
      sleepMins: 0xFFFF,
      workoutCount: 0xFF,
      sourceCount: 0xFF,
      dataFlags: 0xFFFF_FFFF,
      vo2max: 0xFFFF,
      weight: 0xFFFF,
      bodyFatPct: 0xFFFF,
      leanMass: 0xFFFF,
      deepSleepMins: 0xFFFF,
      remSleepMins: 0xFFFF,
      lightSleepMins: 0xFFFF,
      awakeMins: 0xFFFF,
      sourceHash: Buffer.alloc(32, 0xFF)
    }
  },
  {
    name: 'elite_athlete',
    input: {
      wallet: Buffer.from('1111111111111111111111111111111111111111111111111111111111111111', 'hex'),
      dayId: 365 + 90, // ~year and a quarter past epoch
      timezoneOffset: -480, // PST
      steps: 14237,
      activeEnergy: 92500, // 925 kcal
      exerciseMins: 95,
      hrv: 854,    // 85.4 ms
      restingHR: 420, // 42.0 bpm
      sleepMins: 480,
      workoutCount: 2,
      sourceCount: 2,
      dataFlags: 0x000F_03FF,
      vo2max: 612,    // 61.2
      weight: 7350,   // 73.5 kg
      bodyFatPct: 1180, // 11.80%
      leanMass: 6480, // 64.8 kg
      deepSleepMins: 110,
      remSleepMins: 105,
      lightSleepMins: 245,
      awakeMins: 20,
      sourceHash: Buffer.from('aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899', 'hex')
    }
  },
  {
    name: 'sedentary_minimal',
    input: {
      wallet: Buffer.from('00000000000000000000000000000000000000000000000000000000000000ab', 'hex'),
      dayId: 100,
      timezoneOffset: 0, // UTC
      steps: 1200,
      activeEnergy: 4500, // 45 kcal
      exerciseMins: 0,
      hrv: 0,
      restingHR: 720, // 72.0 bpm
      sleepMins: 360,
      workoutCount: 0,
      sourceCount: 1,
      dataFlags: 0x0000_0021, // steps + sleep only
      vo2max: 0,
      weight: 8200, // 82.0 kg
      bodyFatPct: 0,
      leanMass: 0,
      deepSleepMins: 30,
      remSleepMins: 50,
      lightSleepMins: 260,
      awakeMins: 20,
      sourceHash: Buffer.alloc(32, 0x11)
    }
  }
];

function vector(fixture) {
  const buf = buildTestLeafV2(fixture.input);
  if (buf.length !== V2_LEAF_BYTES) {
    throw new Error(`fixture ${fixture.name}: serialized length ${buf.length}, expected ${V2_LEAF_BYTES}`);
  }
  const hash = hashLeafV2(buf);
  return {
    name: fixture.name,
    serializedHex: buf.toString('hex'),
    expectedHashDec: hash.toString(10),
    expectedHashHex: hash.toString(16)
  };
}

const VECTORS = FIXTURES.map(vector);

module.exports = { FIXTURES, VECTORS, vector };

if (require.main === module) {
  console.log(JSON.stringify(VECTORS, null, 2));
}
