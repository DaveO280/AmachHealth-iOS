/**
 * Generates AmachHealth/Tests/Fixtures/WalletDecryptorFixtures.swift from the
 * website's own encryption code, so the iOS decryptor is tested against
 * real CryptoJS output rather than a re-implementation.
 *
 * Run from the website checkout (it has crypto-js and tsx installed):
 *
 *   cd ../Amach-Website
 *   npx tsx ../AmachHealth-iOS/scripts/generate-decryptor-fixtures.ts
 *
 * Uses a throwaway key and address; no real wallet material.
 */

import { writeFileSync } from "fs";
import { resolve } from "path";
// Paths are relative to this script, so the website must sit beside the iOS repo.
import { encryptWithWalletKey } from "../../Amach-Website/src/utils/walletEncryption";
import { generateBucketName } from "../../Amach-Website/src/utils/storjAccessControl";
import { convertBloodworkToFhir } from "../../Amach-Website/src/utils/fhir/bloodworkToFhir";
import { convertDexaToFhir } from "../../Amach-Website/src/utils/fhir/dexaToFhir";

const address = "0x5C52974c3217fE4B62D5035E336089DEE1718fd6".toLowerCase();
// 64 hex chars, same shape as the PBKDF2 output the apps use.
const key = "3f1c9a0b7d2e4f6a8b0c1d2e3f405162738495a6b7c8d9e0f1a2b3c4d5e6f708";
const walletKey = { key, derivedAt: 0, walletAddress: address };

// Each plaintext is what StorageService.storeHealthData encrypts:
// JSON.stringify(data). The object bytes on Storj are the UTF-8 of
// encryptWithWalletKey(...) ("0x" + base64 OpenSSL "Salted__" blob).
const cases: Array<{ name: string; data: unknown }> = [
  { name: "string", data: "hello" },
  { name: "emptyObject", data: {} },
  {
    name: "unicode",
    data: { note: "Café — 睡眠 💤", value: 42.5, list: [1, 2, 3] },
  },
  {
    // JSON.stringify gives exactly 16 bytes, so PKCS#7 adds a whole block.
    name: "exactBlock",
    data: "0123456789abcd",
  },
  {
    name: "timelineEvent",
    data: {
      id: "evt-1",
      eventType: "MEDICATION_STARTED",
      timestamp: 1712345678901,
      data: { name: "Vitamin D", dose: "2000 IU" },
      metadata: { source: "user-entered", platform: "web", version: "1" },
    },
  },
  {
    name: "appleHealthIOS",
    data: {
      manifest: {
        version: 1,
        exportDate: "2026-04-01T00:00:00Z",
        uploadDate: "2026-04-01T00:00:00Z",
        dateRange: { start: "2026-03-01", end: "2026-03-02" },
        metricsPresent: ["HKQuantityTypeIdentifierStepCount"],
        completeness: { score: 50, tier: "BRONZE", coreComplete: false, daysCovered: 2, recordCount: 10 },
        sources: { watch: 1, phone: 1, other: 0 },
      },
      dailySummaries: {
        "2026-03-01": {
          metrics: { StepCount: { total: 8123, count: 40 } },
          sleep: { total: 420, inBed: 460, awake: 20, core: 250, deep: 80, rem: 90, efficiency: 0.91 },
        },
      },
    },
  },
  {
    name: "large",
    data: { rows: Array.from({ length: 400 }, (_, i) => ({ i, v: i * 1.5 })) },
  },
];

function swiftString(s: string): string {
  // Raw string literal with enough #'s to be safe.
  return `#"${s.replace(/"#/g, '"\\#')}"#`;
}

// Storj objects as the website and older iOS builds wrote them, for the
// import tests. Each is stored exactly as StorageService would.
const T0 = 1760000000000; // 2025-10-09T08:53:20Z
const importCases: Array<{ name: string; key: string; dataType: string; data: unknown }> = [
  {
    name: "appleHealthIOS",
    dataType: "apple-health-full-export",
    key: `apple-health-full-export/${T0}-aaaa0001.enc`,
    data: {
      manifest: { version: 1 },
      dailySummaries: {
        "2025-10-01": {
          metrics: {
            StepCount: { total: 9000, count: 50 },
            HeartRate: { avg: 62.5, min: 48, max: 140, count: 300 },
            OxygenSaturation: { avg: 0.97, count: 10 },
            DietaryWater: { total: 2.5, count: 4 },
            MadeUpMetric: { avg: 1, count: 1 },
          },
          sleep: { total: 420, inBed: 470, awake: 25, core: 250, deep: 80, rem: 90, efficiency: 0.89 },
        },
      },
    },
  },
  {
    name: "appleHealthWeb",
    dataType: "apple-health-full-export",
    key: `apple-health-full-export/${T0 + 1000}-aaaa0002.enc`,
    data: {
      manifest: { version: 1 },
      dailySummaries: {
        "2025-09-30": {
          stepCount: { total: 7000, count: 20 },
          distanceWalkingRunning: { total: 5.2, count: 20 },
          restingHeartRate: { avg: 55 },
          sleep: { total: 400, inBed: 430, awake: 10, core: 230, deep: 70, rem: 100 },
        },
        "2025-10-01": { stepCount: { total: 1, count: 1 }, distanceWalkingRunning: { total: 4.8 } },
      },
    },
  },
  {
    name: "bloodworkFhir",
    dataType: "bloodwork-report-fhir",
    key: `bloodwork-report-fhir/${T0 + 2000}-aaaa0003.enc`,
    data: convertBloodworkToFhir({
      type: "bloodwork",
      reportDate: "2025-09-15",
      laboratory: "Quest Diagnostics",
      panels: {},
      metrics: [
        { name: "LDL Cholesterol", value: 128, unit: "mg/dL", referenceRange: "<100", flag: "high", panel: "lipids" },
        { name: "HbA1c", value: 5.4, unit: "%", referenceRange: "4.0-5.6", flag: "normal" },
        { name: "Hepatitis B Surface Ag", valueText: "Non-reactive" },
      ],
      rawText: "",
      confidence: 0.9,
    }),
  },
  {
    name: "bloodworkNarrative",
    dataType: "bloodwork-narrative",
    key: `bloodwork-narrative/${T0 + 5000}-aaaa0004.enc`,
    data: "LDL is above range; HbA1c is normal.",
  },
  {
    name: "dexaFhir",
    dataType: "dexa-report-fhir",
    key: `dexa-report-fhir/${T0 + 6000}-aaaa0005.enc`,
    data: convertDexaToFhir({
      type: "dexa",
      scanDate: "2025-08-20",
      totalBodyFatPercent: 18.4,
      totalLeanMassKg: 61.2,
      visceralFatAreaCm2: 70.1,
      boneDensityTotal: { bmd: 1.21, tScore: 0.8, zScore: 0.6 },
      androidGynoidRatio: 0.92,
      regions: [
        { region: "Left Arm", bodyFatPercent: 14.2, leanMassKg: 3.4, fatMassKg: 0.6 },
        { region: "Trunk", bodyFatPercent: 20.5, leanMassKg: 29.8, fatMassKg: 7.7, boneDensityGPerCm2: 0.98, tScore: 0.2 },
      ],
      rawText: "",
      confidence: 0.8,
    }),
  },
  {
    name: "timelineWeb",
    dataType: "timeline-event",
    key: `timeline-event/${T0 + 7000}-aaaa0006.enc`,
    data: {
      id: "evt-web-1",
      eventType: "MEDICATION_STARTED",
      timestamp: T0 - 86400000,
      data: { name: "Vitamin D", dose: 2000 },
      metadata: { source: "user-input", confidence: 1 },
    },
  },
  {
    name: "timelineUnknownType",
    dataType: "timeline-event",
    key: `timeline-event/${T0 + 7500}-aaaa0007.enc`,
    data: { id: "evt-web-2", eventType: "SOMETHING_NEW", timestamp: T0, data: { note: "x" } },
  },
  {
    name: "chatSessionIOS",
    dataType: "chat-session",
    key: `chat-session/${T0 + 8000}-aaaa0008.enc`,
    data: {
      id: "6F1A2B3C-0000-4000-8000-000000000001",
      createdAt: "2025-10-08T10:00:00Z",
      updatedAt: "2025-10-08T10:05:00Z",
      messages: [
        { id: "6F1A2B3C-0000-4000-8000-0000000000A1", role: "user", content: "How did I sleep?", timestamp: "2025-10-08T10:00:00Z" },
        { id: "6F1A2B3C-0000-4000-8000-0000000000A2", role: "assistant", content: "About 7 hours.", timestamp: "2025-10-08T10:00:05Z" },
      ],
    },
  },
  {
    name: "conversationSessionWeb",
    dataType: "conversation-session",
    key: `conversation-session/${T0 + 9000}-aaaa0009.enc`,
    data: {
      session: { id: "web-session-1", userId: "0x", startedAt: T0 - 3600000, messageCount: 2, importance: "medium", topics: [] },
      messages: [
        { id: "web-msg-1", role: "user", content: "Hi", timestamp: T0 - 3600000 },
        { id: "web-msg-2", role: "assistant", content: "Hello", timestamp: T0 - 3590000 },
      ],
    },
  },
  {
    name: "conversationMemoryIOS",
    dataType: "conversation-memory",
    key: `conversation-memory/${T0 + 10000}-aaaa0010.enc`,
    data: {
      facts: [
        {
          id: "6F1A2B3C-0000-4000-8000-0000000000F1",
          category: "goal",
          value: "Run a half marathon",
          dateIdentified: "2025-10-01T00:00:00Z",
          isActive: true,
        },
      ],
      summaries: [
        {
          id: "6F1A2B3C-0000-4000-8000-0000000000B1",
          date: "2025-10-01T00:00:00Z",
          summary: "Talked about training.",
          topics: ["running"],
          importance: "medium",
          messageCount: 6,
        },
      ],
    },
  },
  {
    name: "merkleLeaves",
    dataType: "merkle-genesis-leaves",
    key: `merkle-genesis-leaves/${T0 + 11000}-aaaa0011.enc`,
    data: { leaves: [{ dayId: 20000, steps: 9000, serializedHex: "00ff", hashDec: "255" }] },
  },
  {
    name: "healthScores",
    dataType: "health-scores",
    key: `health-scores/${T0 + 12000}-aaaa0012.enc`,
    data: { overall: 72 },
  },
];

const lines: string[] = [];
lines.push("// GENERATED by scripts/generate-decryptor-fixtures.ts — do not edit.");
lines.push("// Ciphertexts come from the website's encryptWithWalletKey (CryptoJS 4).");
lines.push("");
lines.push("import Foundation");
lines.push("");
lines.push("enum WalletDecryptorFixtures {");
lines.push(`    static let walletAddress = ${swiftString(address)}`);
lines.push(`    static let encryptionKey = ${swiftString(key)}`);
lines.push(`    static let expectedBucket = ${swiftString(generateBucketName(address, walletKey))}`);
lines.push(
  `    static let expectedBucketCustomPrefix = ${swiftString(generateBucketName(address, walletKey, "amach-test"))}`,
);
lines.push("");
lines.push("    struct Case {");
lines.push("        let name: String");
lines.push("        let plaintext: String");
lines.push("        let objectText: String");
lines.push("    }");
lines.push("");
lines.push("    static let cases: [Case] = [");
for (const c of cases) {
  const plaintext = JSON.stringify(c.data);
  const objectText = encryptWithWalletKey(plaintext, walletKey);
  lines.push("        Case(");
  lines.push(`            name: ${swiftString(c.name)},`);
  lines.push(`            plaintext: ${swiftString(plaintext)},`);
  lines.push(`            objectText: ${swiftString(objectText)}`);
  lines.push("        ),");
}
lines.push("    ]");
lines.push("");
lines.push("    struct ImportCase {");
lines.push("        let name: String");
lines.push("        let key: String");
lines.push("        let dataType: String");
lines.push("        let uploadedAt: Int64");
lines.push("        let objectText: String");
lines.push("    }");
lines.push("");
lines.push("    static let importCases: [ImportCase] = [");
for (const c of importCases) {
  const uploadedAt = Number(c.key.split("/")[1].split("-")[0]);
  lines.push("        ImportCase(");
  lines.push(`            name: ${swiftString(c.name)},`);
  lines.push(`            key: ${swiftString(c.key)},`);
  lines.push(`            dataType: ${swiftString(c.dataType)},`);
  lines.push(`            uploadedAt: ${uploadedAt},`);
  lines.push(`            objectText: ${swiftString(encryptWithWalletKey(JSON.stringify(c.data), walletKey))}`);
  lines.push("        ),");
}
lines.push("    ]");
lines.push("}");
lines.push("");

const out = resolve(__dirname, "../AmachHealth/Tests/Fixtures/WalletDecryptorFixtures.swift");
writeFileSync(out, lines.join("\n"));
console.log(`wrote ${cases.length} decrypt cases and ${importCases.length} import cases to ${out}`);
