# Amach Health — Test Infrastructure

## Pre-Session Continuity Check

Run this at the start of every coding session:

```bash
cd ~/AmachHealth-iOS
./amach-test-runner.sh --quick      # ~60 seconds, Layers 1 + 3
./amach-test-runner.sh              # Full run including simulator (~10 min)
```

**Minimum threshold before writing code:** Layers 1 and 3 must both pass.

---

## Architecture: Four Test Layers

### Layer 1 — API Smoke Tests (no auth, ~30s)
**Script:** `Tests/Scripts/layer1-smoke-tests.sh`

Tests `/api/ai/chat` directly. No credentials needed. Confirms the backend is alive and Luma responds.

Success thresholds:
- HTTP 200 from `/api/ai/chat`
- Valid JSON in response
- Response content ≥ 50 characters
- Response time < 30s
- No `error` field

### Layer 2 — XCTest Unit + Integration (in Xcode)
**Files:** `AmachHealth/Tests/ChatServiceTests.swift` and `ChatServiceIntegrationTests.swift`

Pure Swift tests — run via `Cmd+U` in Xcode or via Layer 4. Cover:
- `ChatMessage`, `ChatSession`, `AIChatHistoryMessage` models
- History truncation logic (18-message window)
- Session cap logic (30 sessions max)
- Storj sync trigger counts
- **Integration:** `ChatService.send()` appends messages, `startStreaming()` fills placeholder, cancellation cleanup, disk persistence round-trip, Storj sync skipped when wallet disconnected

### Layer 3 — Authenticated API Tests (~30-60s)
**Script:** `Tests/Scripts/layer3-auth-tests.sh`

Tests all authenticated endpoints using the test account's `WalletEncryptionKey`. Requires `Tests/TestCredentials.json`.

Tests: `/api/profile/read`, `/api/storj` (list), `/api/health/summary`, `/api/ai/chat` with wallet context.

### Layer 4 — Simulator Build + XCTest + Screenshots (~5-10 min)
**Script:** `Tests/Scripts/layer4-simulator-tests.sh`

Runs `xcodebuild`, executes the full XCTest suite on a simulator, boots the simulator, installs + launches the app, captures screenshots. Confirms zero build errors and zero test failures.

---

## Test Account

| Field | Value |
|---|---|
| Email | amachhealthtest+1@gmail.com |
| Wallet | `0x5C52974c3217fE4B62D5035E336089DEE1718fd6` |
| Credentials file | `Tests/TestCredentials.json` (gitignored) |

**The `WalletEncryptionKey` never expires.** It's derived deterministically from the wallet's Ethereum signature — no TTL. You only need to re-derive if:
- The Privy wallet is rotated/recreated
- The `TestCredentials.json` file is accidentally deleted

---

## Re-Deriving Credentials

If you ever need to refresh `TestCredentials.json`:

1. Log into `https://www.amachhealth.com` with `amachhealthtest+1@gmail.com` in Chrome
2. Open Chrome DevTools Console (`Cmd+Option+J`)
3. Paste and run:

```javascript
// Step 1: Get the signature
var walletAddress = window.__privyProvider.address;
var msg = "Amach Health - Derive Encryption Key\n\nThis signature is used to encrypt your health data.\n\nNonce: " + walletAddress.toLowerCase();
window.__privyProvider.signMessage(msg).then(s => window.__sig = s);
// Click "Sign and continue" in the Privy modal that appears
```

4. After approving the modal:

```javascript
// Step 2: Derive the PBKDF2 key
var sigHex = window.__sig.slice(2);
var addrHex = walletAddress.toLowerCase().replace('0x','').slice(0,40);
function hexToBytes(h){var b=new Uint8Array(h.length/2);for(var i=0;i<h.length;i+=2)b[i/2]=parseInt(h.slice(i,i+2),16);return b;}
crypto.subtle.importKey("raw",hexToBytes(sigHex),"PBKDF2",false,["deriveBits"])
  .then(k=>crypto.subtle.deriveBits({name:"PBKDF2",salt:hexToBytes(addrHex),iterations:100000,hash:"SHA-256"},k,256))
  .then(d=>console.log("ENCRYPTION KEY:",Array.from(new Uint8Array(d)).map(b=>b.toString(16).padStart(2,'0')).join('')));
// Also: console.log("SIGNATURE:", window.__sig);
```

5. Update `Tests/TestCredentials.json` with the new values.

---

## Key Derivation Spec (PBKDF2)

Must match `WalletService.swift` exactly to work cross-platform:

| Parameter | Value |
|---|---|
| Algorithm | PBKDF2 |
| Hash | SHA-256 |
| Iterations | 100,000 |
| Output | 32 bytes → 64-char hex |
| Password | Signature hex bytes (strip `0x`) |
| Salt | Wallet address hex bytes (strip `0x`, first 20 bytes) |

---

## Running a Single Layer

```bash
# Just smoke tests (fastest, no credentials)
./amach-test-runner.sh --layer 1

# Just authenticated tests
./amach-test-runner.sh --layer 3

# Just simulator (skip screenshots to speed up)
./amach-test-runner.sh --layer 4 --skip-screenshots
```

---

## Mock Infrastructure (Layer 2)

New source files added for testability:

| File | Purpose |
|---|---|
| `Sources/API/AmachAPIClientProtocol.swift` | Protocol over `AmachAPIClient` |
| `Sources/Services/WalletServiceProtocol.swift` | Protocol over `WalletService` |
| `Sources/Services/ChatService+Testing.swift` | `#if DEBUG` test init factory |
| `Tests/Helpers/MockAmachAPIClient.swift` | Configurable mock; tracks call counts |
| `Tests/Helpers/MockWalletService.swift` | Stub wallet; controllable `isConnected` |
| `Tests/ChatServiceIntegrationTests.swift` | Integration tests using mocks |

---

## Xcode Test Plan

Open `AmachHealth.xcodeproj` → Product → Test → all test targets run automatically.
Or from terminal:

```bash
xcodebuild test \
  -project AmachHealth.xcodeproj \
  -scheme AmachHealth \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```
