#!/usr/bin/env bash
set -euo pipefail

# rebuild_circuit.sh
# Recompile the coverage circuit and regenerate trusted setup artifacts.
#
# Run this after any change to coverage.circom (e.g. new k, depth, or signals).
# Current target: CoverageProof(k=60, depth=10), 5 public signals.
#
# Prerequisites:
#   - circom >= 2.1.0: https://docs.circom.io/getting-started/installation/
#   - snarkjs installed globally: npm install -g snarkjs
#   - Powers of Tau file for BN128 (2^20 sufficient for this circuit):
#       https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_20.ptau
#
# Usage:
#   PTAU_FILE=/path/to/powersOfTau28_hez_final_20.ptau bash zk/scripts/rebuild_circuit.sh
#
# After completion:
#   1. Copy the emitted CoverageVerifier.sol to contracts/ in the web app repo.
#   2. Deploy the new verifier: npx hardhat run scripts/deploy-coverage-verifier.js
#   3. Update coverageVerifierAddress in ZKSyncAttestationService.swift.
#   4. Update CONTRACT_ADDRESSES in src/lib/contractConfig.ts.

CIRCUIT_DIR="$(cd "$(dirname "$0")/../circuits/coverage" && pwd)"
BUILD_DIR="$(cd "$(dirname "$0")/../build/coverage" && pwd)"

PTAU_FILE="${PTAU_FILE:-/path/to/powersOfTau28_hez_final_20.ptau}"

if [ ! -f "$PTAU_FILE" ]; then
  echo "ERROR: Powers of Tau file not found: $PTAU_FILE"
  echo "Download it:"
  echo "  wget https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_20.ptau"
  echo "Then re-run with: PTAU_FILE=/path/to/file.ptau bash $0"
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "=== Step 1: Compile circuit ==="
circom "$CIRCUIT_DIR/coverage.circom" \
  --r1cs --wasm --sym \
  -l "$CIRCUIT_DIR/../../node_modules" \
  -o "$BUILD_DIR"

echo ""
echo "=== Step 2: Constraint count ==="
snarkjs r1cs info "$BUILD_DIR/coverage.r1cs"

echo ""
echo "=== Step 3: Groth16 Phase 2 setup ==="
snarkjs groth16 setup \
  "$BUILD_DIR/coverage.r1cs" \
  "$PTAU_FILE" \
  "$BUILD_DIR/coverage_0000.zkey"

echo ""
echo "=== Step 4: Phase 2 beacon contribution ==="
# Using a deterministic beacon for dev. For production, run a multi-party ceremony.
snarkjs zkey beacon \
  "$BUILD_DIR/coverage_0000.zkey" \
  "$BUILD_DIR/coverage_final.zkey" \
  0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f \
  10 -n="Amach Coverage v2 Final Beacon"

echo ""
echo "=== Step 5: Verify final zkey ==="
snarkjs zkey verify \
  "$BUILD_DIR/coverage.r1cs" \
  "$PTAU_FILE" \
  "$BUILD_DIR/coverage_final.zkey"

echo ""
echo "=== Step 6: Export verification key ==="
snarkjs zkey export verificationkey \
  "$BUILD_DIR/coverage_final.zkey" \
  "$BUILD_DIR/verification_key.json"

echo ""
echo "=== Step 7: Export Solidity verifier ==="
snarkjs zkey export solidityverifier \
  "$BUILD_DIR/coverage_final.zkey" \
  "$CIRCUIT_DIR/CoverageVerifier.sol"

echo ""
echo "=== Done ==="
echo ""
echo "Artifacts written to: $BUILD_DIR"
echo "New verifier written to: $CIRCUIT_DIR/CoverageVerifier.sol"
echo ""
echo "Next steps:"
echo "  1. cp $CIRCUIT_DIR/CoverageVerifier.sol <web-app>/contracts/CoverageVerifier.sol"
echo "  2. npx hardhat compile  (in web-app repo)"
echo "  3. Deploy new verifier and update CONTRACT_ADDRESSES"
