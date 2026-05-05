#!/usr/bin/env zsh
# setup_improvement.sh
# Amach Health ZK — Spring Push Verification Layer 2
#
# Compile AverageImprovementProof, run a fresh local Phase 2 ceremony reusing
# the existing pot17_final.ptau (Phase 1), and emit the Groth16 verifier
# Solidity contract.
#
# Run from the zk/ directory:
#   cd AmachHealth-iOS/zk && ./setup_improvement.sh
#
# Outputs:
#   build/improvement/improvement.r1cs
#   build/improvement/improvement_js/improvement.wasm
#   build/improvement/improvement_final.zkey
#   build/improvement/verification_key.json
#   circuits/improvement/AverageImprovementProofV1Verifier.sol
#       (also copied to /Amach-Website/contracts/ if that path exists)

set -e

echo ""
echo "════════════════════════════════════════════════"
echo "  AMACH HEALTH — Layer 2 ZK Setup"
echo "  AverageImprovementProof (Spring Push Season One)"
echo "════════════════════════════════════════════════"
echo ""

# ─── Locate circom ────────────────────────────────────────────────
CIRCOM=""
for candidate in \
    "$(command -v circom 2>/dev/null)" \
    "$HOME/.cargo/bin/circom" \
    "/usr/local/bin/circom" \
    "/opt/homebrew/bin/circom"
do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        CIRCOM="$candidate"
        break
    fi
done

if [[ -z "$CIRCOM" ]]; then
    echo "❌  circom not found. See setup_phase4.sh for install instructions."
    exit 1
fi

echo "✅  circom found: $CIRCOM"
$CIRCOM --version
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
echo "Working directory: $SCRIPT_DIR"
echo ""

mkdir -p build/improvement

# ─── npm deps (in case running from a fresh clone) ───────────────
echo "📦 Installing npm dependencies..."
npm install --silent
echo ""

# ─── Step 1: Compile improvement circuit ─────────────────────────
echo "Step 1/6: Compiling AverageImprovementProof..."
$CIRCOM circuits/improvement/improvement.circom \
    --r1cs --wasm --sym \
    -o build/improvement \
    -l node_modules

echo "✅  AverageImprovementProof compiled"
echo ""

echo "Constraint info:"
npx snarkjs r1cs info build/improvement/improvement.r1cs
echo ""

# ─── Step 2: Phase 1 PTAU sanity ─────────────────────────────────
PTAU_FINAL="pot17_final.ptau"

if [[ ! -f "$PTAU_FINAL" ]]; then
    echo "❌  $PTAU_FINAL missing — run setup_phase4.sh first to generate it."
    exit 1
fi

CONSTRAINT_COUNT=$(npx snarkjs r1cs info build/improvement/improvement.r1cs 2>/dev/null | grep -E '# of Constraints' | grep -oE '[0-9]+' | tail -1)
echo "Step 2/6: Phase-1 PTAU capacity check"
echo "  pot17 supports up to 2^17 = 131072 constraints"
echo "  improvement.r1cs reports $CONSTRAINT_COUNT constraints"
if [[ "$CONSTRAINT_COUNT" -gt 131072 ]]; then
    echo "❌  Constraint count exceeds pot17 capacity. Switch to a larger ptau (e.g. powersOfTau28_hez_final_20.ptau)."
    exit 1
fi
echo "✅  pot17_final.ptau has sufficient capacity"
echo ""

# ─── Step 3: Groth16 setup (Phase 2 init) ────────────────────────
echo "Step 3/6: Groth16 Phase 2 setup (~30 s)..."
npx snarkjs groth16 setup \
    build/improvement/improvement.r1cs \
    "$PTAU_FINAL" \
    build/improvement/improvement_0.zkey

echo "✅  Initial zkey generated"
echo ""

# ─── Step 4: Contribute randomness (Phase 2) ─────────────────────
echo "Step 4/6: Contributing randomness to zkey..."
echo "amach-health-zk-improvement-dev-$(date +%s)" | \
    npx snarkjs zkey contribute \
        build/improvement/improvement_0.zkey \
        build/improvement/improvement_final.zkey \
        --name="amach-improvement-v1-dev" \
        -v 2>&1 | grep -E "(contribution|hash|name)" || true

echo "✅  Randomness contributed"
echo ""

# ─── Step 5: Export verification key ─────────────────────────────
echo "Step 5/6: Exporting verification key..."
npx snarkjs zkey export verificationkey \
    build/improvement/improvement_final.zkey \
    build/improvement/verification_key.json

echo "✅  Verification key: build/improvement/verification_key.json"
echo ""

# ─── Step 6: Export Solidity verifier ────────────────────────────
echo "Step 6/6: Exporting Solidity verifier..."
npx snarkjs zkey export solidityverifier \
    build/improvement/improvement_final.zkey \
    circuits/improvement/AverageImprovementProofV1Verifier.sol

echo "✅  Verifier: circuits/improvement/AverageImprovementProofV1Verifier.sol"
echo ""

# ─── Mirror to Amach-Website if it exists ────────────────────────
WEBSITE_CONTRACTS="/Users/dave/Amach-Website/contracts"
if [[ -d "$WEBSITE_CONTRACTS" ]]; then
    cp circuits/improvement/AverageImprovementProofV1Verifier.sol "$WEBSITE_CONTRACTS/"
    echo "📋 Mirrored verifier to $WEBSITE_CONTRACTS/"
else
    echo "ℹ️  $WEBSITE_CONTRACTS not found — copy the verifier manually for the website repo."
fi
echo ""

echo "════════════════════════════════════════════════"
echo "  LAYER 2 SETUP COMPLETE"
echo "════════════════════════════════════════════════"
