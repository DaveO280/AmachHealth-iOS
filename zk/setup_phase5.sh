#!/usr/bin/env zsh
# setup_phase5.sh
# Amach Health ZK — Phase 5: Contract Deployment
#
# Installs hardhat + zkSync dependencies, compiles both contracts,
# and deploys them to zkSync Era Sepolia (if PRIVATE_KEY is set).
#
# Run from the zk/ directory:
#   cd AmachHealth-iOS/zk
#
# Compile only (no wallet needed):
#   ./setup_phase5.sh
#
# Compile + deploy contracts (deployer wallet):
#   DEPLOYER_KEY=<deployer-hex-key> ./setup_phase5.sh
#
# After deployment, submit the genesis root (user wallet):
#   PRIVATE_KEY=<user-hex-key> node deploy/scripts/submit_genesis_root.js

set -e

echo ""
echo "════════════════════════════════════════════════"
echo "  AMACH HEALTH — Phase 5 Contract Deployment"
echo "════════════════════════════════════════════════"
echo ""

# ─── Ensure we're in the zk/ directory ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
echo "Working directory: $SCRIPT_DIR"
echo ""

# ─── Step 1: Install deployment dependencies ─────────────────────
echo "Step 1/4: Installing Hardhat + zkSync dependencies..."
echo "  (installing in deploy/ to keep isolated from snarkJS deps)"
echo ""

cd deploy
npm install
cd ..

echo ""
echo "✅  Dependencies installed"
echo ""

# ─── Step 2: Compile contracts ────────────────────────────────────
echo "Step 2/4: Compiling contracts with zksolc..."
echo "  Contracts:"
echo "    circuits/coverage/CoverageVerifier.sol  (Groth16Verifier, snarkJS-generated)"
echo "    circuits/coverage/MerkleCommitment.sol  (root commitment + proof verification)"
echo ""

# Copy contracts into deploy/contracts/ (Hardhat can't reference files outside its project root)
# This is done fresh each run so CoverageVerifier.sol stays in sync with the trusted setup.
mkdir -p deploy/contracts
cp circuits/coverage/CoverageVerifier.sol deploy/contracts/
cp circuits/coverage/MerkleCommitment.sol deploy/contracts/
echo "  Copied contracts to deploy/contracts/"
echo ""

cd deploy
npx hardhat compile
cd ..

echo ""
echo "✅  Contracts compiled (artifacts in deploy/artifacts/)"
echo ""

# ─── Step 3: Gate check — artifacts exist ────────────────────────
echo "Step 3/4: Checking compiled artifacts..."

VERIFIER_ARTIFACT="deploy/artifacts-zk/contracts/CoverageVerifier.sol/Groth16Verifier.json"
COMMITMENT_ARTIFACT="deploy/artifacts-zk/contracts/MerkleCommitment.sol/MerkleCommitment.json"

if [[ -f "$VERIFIER_ARTIFACT" ]]; then
    echo "  ✅ Groth16Verifier artifact ready"
else
    echo "  ❌ Groth16Verifier artifact not found at $VERIFIER_ARTIFACT"
    echo "     Check that hardhat.config.js paths.sources points to circuits/coverage/"
    exit 1
fi

if [[ -f "$COMMITMENT_ARTIFACT" ]]; then
    echo "  ✅ MerkleCommitment artifact ready"
else
    echo "  ❌ MerkleCommitment artifact not found at $COMMITMENT_ARTIFACT"
    exit 1
fi

echo ""

# ─── Step 4: Deploy (if PRIVATE_KEY is set) ───────────────────────
echo "Step 4/4: Contract deployment..."
echo ""

if [[ -z "${DEPLOYER_KEY}" ]]; then
    echo "  ⚠️  DEPLOYER_KEY not set — skipping deployment."
    echo ""
    echo "  Two wallets are used in Phase 5:"
    echo "    DEPLOYER_KEY  — the wallet that pays gas to deploy the contracts"
    echo "    PRIVATE_KEY   — the user wallet that owns/commits the genesis root"
    echo ""
    echo "  To deploy contracts, run:"
    echo "    DEPLOYER_KEY=<deployer-hex-key> ./setup_phase5.sh"
    echo ""
    echo "  Or deploy manually:"
    echo "    DEPLOYER_KEY=<key> node deploy/scripts/deploy_all.js"
    echo ""
else
    echo "  DEPLOYER_KEY detected — deploying to zkSync Era Sepolia..."
    echo ""

    DEPLOYER_KEY="$DEPLOYER_KEY" node deploy/scripts/deploy_all.js

    echo ""
    echo "✅  Both contracts deployed"
    echo ""

    # Show deployed addresses
    if [[ -f "data/deployed_contracts.json" ]]; then
        echo "  Deployed addresses (data/deployed_contracts.json):"
        node -e "
const c = require('./data/deployed_contracts.json');
console.log('    CoverageVerifier:  ' + c.coverageVerifier);
console.log('    MerkleCommitment:  ' + c.merkleCommitment);
console.log('');
console.log('    Explorer:');
console.log('      https://explorer.sepolia.era.zksync.dev/address/' + c.coverageVerifier);
console.log('      https://explorer.sepolia.era.zksync.dev/address/' + c.merkleCommitment);
"
    fi
fi

echo ""
echo "════════════════════════════════════════════════"
echo "  PHASE 5 SETUP COMPLETE"
echo "════════════════════════════════════════════════"
echo ""
echo "Files ready:"
echo "  deploy/artifacts/  — compiled contract artifacts"

if [[ -f "data/deployed_contracts.json" ]]; then
    echo "  data/deployed_contracts.json  — on-chain addresses"
fi

echo ""
echo "Next steps:"
if [[ -z "${DEPLOYER_KEY}" ]]; then
    echo "  1. Run: DEPLOYER_KEY=<deployer-key> ./setup_phase5.sh"
    echo "  2. Build genesis tree from your HealthKit export:"
    echo "     node scripts/generate_genesis_root.js data/normalized_leaves.json"
    echo "  3. Submit genesis root with your USER wallet:"
    echo "     PRIVATE_KEY=<user-key> node deploy/scripts/submit_genesis_root.js"
else
    echo "  1. Build genesis tree from your HealthKit export:"
    echo "     node scripts/generate_genesis_root.js data/normalized_leaves.json"
    echo ""
    echo "  2. Submit the genesis root on-chain (use your USER wallet, not deployer):"
    echo "     PRIVATE_KEY=<user-key> node deploy/scripts/submit_genesis_root.js"
    echo ""
    echo "  3. Generate a coverage proof and verify on-chain:"
    echo "     node scripts/generate_proof.js 0 89 20"
fi
echo ""
