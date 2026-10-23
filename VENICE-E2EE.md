# Venice E2EE: phone-to-enclave encryption for Luma and report parsing

Status: spike merged; Phase 4a (Luma chat over E2EE, behind the off-by-default
`LumaE2EEChat` flag) on `luma/e2ee-chat` (iOS) and `luma/e2ee-relay-auth`
(website), 2026-10-23. The relay stays off in production
(`AMACH_E2EE_RELAY_ENABLED`). See "Phase 4a" below.

## TL;DR / recommendation

**Do it, in this shape:**

1. **The phone fetches attestation from Venice itself, and verifies it on the
   device.** `GET /api/v1/tee/attestation` needs no API key, so Amach is never
   in a position to give the phone a substitute model key. The phone checks
   the full TDX quote chain to Intel's root, not only Venice's
   `verified: true` (`Packages/VeniceE2EE`, done in the spike).
2. **The phone builds and encrypts every message.** That covers system
   prompts, context blocks, history and the user turn, for every role,
   *assistant included* (Venice rejects plaintext history with E2EE headers).
3. **Amach's server becomes a dumb ciphertext relay** (`POST /api/ai/e2ee`).
   It adds the API key, enforces the enclave-only model chain, refuses
   anything that isn't ciphertext, and streams Venice's encrypted SSE back
   without reading it. Fallback still happens on the server. The phone sends
   one encrypted copy per enclave key, and models on the same gateway share a
   key, so that's two copies today.
4. **Chat:** port the small server-side prompt assembly to Swift. The phone
   already sends pre-formatted `contextBlocks`. Serve the prompt text from
   the server as non-sensitive, versioned config.
5. **PDF parsing:** run the website's existing TypeScript parse pipeline *on
   the phone* in JavaScriptCore, with the model call bridged to the native
   E2EE client. Don't port about 3.5K lines of prompts and cleanup to Swift.
   The bundle is 145 KB and ran unmodified in `jsc`. Each section's model call
   becomes its own short relay request, which removes the 300 s Vercel
   ceiling as a concern.
6. **Chat fallback changes:** `e2ee-kimi-k2-6` can't take phone-encrypted
   requests today. E2EE chat is **GLM 5.3 (phala) → Qwen 3.8 27B (near-ai)
   → GLM 5.3 Flash (near-ai)** (decided 2026-10-23). Different enclave
   providers, so the failure domains stay independent; Qwen and Flash share
   the near-ai key, so the phone still encrypts two copies.

**What this buys:** neither Vercel nor Venice's API layer can read prompts,
health context or replies, as long as both behave honestly. Logs,
subpoenas, a leaked Vercel log drain, or a curious operator see only
ciphertext plus metadata: model, sizes, timing and IP.

**What it doesn't buy (be honest in product copy):** Venice's protocol
doesn't authenticate the `X-Venice-TEE-Client-Pub-Key` header. An *actively
malicious* relay, meaning a compromised Vercel deployment running modified
code (or Venice's API layer), can't read prompts. It *can* swap that header
for its own key, read the reply, and re-encrypt it to the phone without
being detected. Venice's response signatures don't close this gap (see
§Q2). Options are listed under "Residual risk".

## What was verified live (2026-10-23)

| Fact | Evidence |
|---|---|
| Header names: `X-Venice-TEE-Client-Pub-Key`, `X-Venice-TEE-Model-Pub-Key`, `X-Venice-TEE-Signing-Algo: ecdsa` | docs + live 200s |
| Format: `hex(eph65 ‖ nonce12 ‖ AES-256-GCM ct‖tag)`, key = HKDF-SHA256(ECDH x-coord, no salt, info `ecdsa_encryption`) on secp256k1 | Node and Swift both interoperate with Venice; Swift decrypts the @noble reference vector |
| **Assistant history must be encrypted too** | plaintext assistant turn → `400 E2EE decryption failed`; encrypted → 200 with correct recall |
| **Non-streaming works**: `message.content` is one encrypted blob | live, GLM 5.3 |
| Streaming: every `delta.content` *and* `delta.reasoning_content` chunk is encrypted, with no plaintext chunks | 283/283, 85/85 |
| Attestation needs **no API key** | `GET /tee/attestation` → 200 without `Authorization` |
| REPORTDATA = `signing_address(20) ‖ 0×12 ‖ nonce(32)`, address = keccak256(pubkey)[12:] | phala (`aci/1`) and near-ai formats both |
| Enclave keys are per gateway, not per model: phala `04943c…` serves glm-5-3-p, glm-5-2-p, gpt-oss-120b-p; near-ai `0442d4…` serves deepseek-v4-flash, glm-5-3-flash | attestation survey |
| TD attributes debug bit is 0 on every attested model | quote parse |
| **At most one system message.** Venice merges system messages before the enclave, which corrupts ciphertext: two encrypted system messages (adjacent or not) → `400 E2EE decryption failed` (phala) / `Encrypted field is not valid hex` (near-ai). One → 200. Field size isn't the limit (4 KB plaintext → 200). The phone merges its system parts into one before encrypting | live probe + simulator run, Phase 4a |
| Qwen 3.8 27B (`e2ee-qwen3-8-27b`, near-ai): E2EE chat, encrypted history recall and `strip_thinking_response` work; replies open with a stray `"\n\n"` (trimmed on the phone) | live |
| Kimi K2.6 / K3: `verified: false`, attested by chutes/near-ai with an `e2e_pubkey` (1580 b64 chars, probably ML-KEM-768), no `signing_key`; K2.6 attestation sometimes 502 | survey |

### Q5: which models report `supportsE2EE` today

`/api/v1/models` returns `supportsE2EE: true` for 12 models:

| Model | Amach tier today | Documented ECDSA E2EE works? | Provider |
|---|---|---|---|
| e2ee-glm-5-3-p | chat primary, parseLong primary | ✅ | phala (→ Privatemode upstream) |
| e2ee-kimi-k2-6 | chat backup | ❌ attestation `verified:false`, no ECDSA key | chutes / near-ai |
| e2ee-gpt-oss-120b-p | parseText primary, parseLong backup | ✅ | phala |
| e2ee-deepseek-v4-flash | parseText / memory | ✅ | near-ai |
| e2ee-glm-5-3-flash | parseText / memory backup | ✅ | near-ai |
| e2ee-glm-5-2-p | — | ✅ | phala |
| e2ee-kimi-k3-p | — | ❌ (same as K2.6) | phala, `e2e_pubkey` only |
| e2ee-qwen3-8-27b, e2ee-qwen3-6-35b-a3b | — | ✅ (attested) | near-ai |
| e2ee-qwen3-vl-30b-a3b-p, e2ee-qwen-2-5-7b-p, e2ee-gemma-4-26b-a4b-uncensored-p | — | not tested | — |

So `supportsE2EE: true` isn't enough on its own; the attestation has to
carry a `signing_public_key`. The relay encodes the verified set as
`E2EE_ECDSA_MODELS` / `getE2EEModelChain()` (website `src/config/aiModels.ts`).
The phone also skips any model whose attestation fails, so a model that
regresses is never sent data.

## Trust model: who sees what

| Party | Today (`/api/ai/chat`, `/api/health/parse-report`) | With this design |
|---|---|---|
| Vercel / Amach server | **Plaintext**: full prompt, health context, reply | Ciphertext, model, sizes, timing, client IP |
| Venice API layer | **Plaintext** | Ciphertext + metadata (rewrites the JSON envelope only) |
| Enclave gateway (phala / near-ai, TDX) | Plaintext (inside TEE) | Plaintext (inside TEE): the attested party |
| GPU host | Excluded (TEE) | Excluded (TEE) |

On the phala gateway, the receipt shows `route.selected privatemode:z-ai/glm-5.3`
plus `upstream.verified`. The attested gateway enclave decrypts and
re-forwards to Privatemode's GPU TEE, which the gateway itself verifies. The
phone verifies the gateway, and the gateway verifies the upstream.

## Q1: where prompts get assembled

**Chat.** Today `/api/ai/chat` adds `SYSTEM_PROMPT`, then either the phone's
`contextBlocks` verbatim (the iOS path) or legacy `buildContextMessage`, the
`labData` wrapper, the last 20 history messages, and a "[Conversation
context]" summary of prior assistant turns. Then it adds the user message.
That's about 80 lines of logic, and the phone already owns the hard part
(context blocks). Plan:

- Port the assembly to Swift (`LumaPromptAssembler`) and give it a snapshot
  test against the TS output for the same inputs.
- Serve prompt text from `GET /api/ai/prompts?v=` (non-sensitive config).
  Bundle a fallback copy in the app. Prompt edits stay a server deploy, not
  an app release.
- Prompt injection from the server is low-risk. A malicious prompt can only
  change what the model says *back to the phone*, because the reply is
  encrypted to the phone. Still, pin prompts by hash in release builds.
- Tools: none are used by Luma chat today. With E2EE, tool *definitions*
  aren't encrypted, so keep sensitive data out of them if tools arrive.
- Other server-side Venice callers also see health data and need the same
  treatment or retirement. These include agent fan-out (`agent` tier),
  conversation memory extraction (`memory` tier, already E2EE-capable
  models), `ClinicalNarrativeService`, and `/api/venice`. That inventory is
  Phase 4c.

**Report parsing.** The pipeline (`src/utils/reportParsers/`: registry,
sections, bloodwork/DEXA/gut definitions, gut cleanup, hallucination guard,
validators) is pure TypeScript. Its only I/O is `veniceClient.callVenice`.
Spike result: esbuild bundles `parseHealthReport` into a **145 KB IIFE**,
with `veniceClient` swapped for a bridge to a native `__amachCallModel(tier,
body)` and `AsyncLocalStorage` stubbed. It ran unmodified in macOS
JavaScriptCore and routed its model call through the bridge with tier
`parseText`. Plan:

- Website CI builds `amach-parsers.js` from the same source the server uses.
- The app bundles that file, and may later fetch signed updates.
- `ReportParseEngine` (Swift) hosts a `JSContext` and implements
  `__amachCallModel` with `VeniceE2EEClient`. The tier comes from the
  registry pass (`ParserPass.tier`), so parseLong is preserved.
- One source of truth for prompts, cleanup and validation on web and phone.
  No 3.5K-line port.
- The server parse route stays for the web app until the web client gets
  its own E2EE path (browser WebCrypto has no secp256k1 either; @noble
  works there).

## Q2: attestation on iOS

Implemented in `Packages/VeniceE2EE` (CryptoKit + Security + swift-secp256k1),
about 1 s per attestation over the network:

| Check | On device? |
|---|---|
| Fresh 32-byte nonce echoed, and inside REPORTDATA | ✅ |
| `signing_address == keccak256(signing_public_key)[12:]`, and that address inside REPORTDATA | ✅ (this is what stops key substitution) |
| TD not in debug mode (TDATTRIBUTES bit 0) | ✅ |
| Quote ECDSA-P256 signature by the attestation key | ✅ |
| QE report binds the attestation key (SHA-256(attKey ‖ authData)) | ✅ |
| QE report signed by the PCK leaf | ✅ |
| PCK chain → **pinned Intel SGX Root CA** (sha256 `44a0196b…74d3`) via SecTrust, anchors-only, no network | ✅ |
| Venice `verified: true` | ✅ (required, not trusted alone) |
| PCK CRL / TCB status / QE identity (Intel PCS collateral) | ❌. Can be fetched by the phone directly from Intel PCS (public). Phase 4b |
| Workload measurements (MRTD/RTMRs/compose hash) against an allowlist | ❌. Exposed in `AttestedModelKey`. Measurements change on every gateway upgrade, so start with log + alert on change, then pin to the dstack/phala published compose hashes |
| NVIDIA GPU evidence | ❌. Phala omits it (`gpu_evidence_omitted`); near-ai includes `nvidia_payload`, but verifying it needs NVIDIA NRAS (online). Trust the gateway's upstream check |

Tests (`swift test` in `Packages/VeniceE2EE`, 13 passing) replay the live
phala and near-ai attestations. They show that a substituted key, a stale
nonce, a flipped quote byte, and `verified:false` are each rejected.

**Response signatures don't authenticate the client key.**
`GET /tee/signature` (also no key) returns a signed receipt. Its
`request.received` hash doesn't match SHA-256 of the body we sent, because
Venice rewrites the body, and Venice's own text says to "treat request/response hashes as
provider-reported values". So a phone can't use signatures to detect a
swapped `X-Venice-TEE-Client-Pub-Key`.

### The unauthenticated client key, in detail

Request fields are bound: each carries its own ephemeral key, sealed to the
attested enclave key. Replies are encrypted to whatever key arrives in
`X-Venice-TEE-Client-Pub-Key`, and nothing ties that header to the phone.
Any party that can rewrite requests between the phone and the enclave can
do the following. That means a compromised or modified relay deployment, or
Venice's API layer; passive log readers can't.

1. Swap the header for a key of its own.
2. Decrypt every reply chunk.
3. Re-encrypt each chunk to the phone's real key, which it has from the
   request.

The phone sees valid AES-GCM chunks and can't tell, because GCM proves only
the symmetric key, not who sealed it. The same weakness lets such a party
forge whole replies (integrity). Reasoning chunks go to the same key and
restate the prompt at length, so in practice they leak much of the prompt as
well. The relay now strips reasoning (`strip_thinking_response`, verified
under E2EE), so only the answer itself is exposed.

### What the gateway's "E2EE v2" does (checked 2026-10-23)

Both phala attestations advertise `supported_e2ee_versions: ["2"]`. The
gateway's spec (`Dstack-TEE/private-ai-gateway` at the attested commit
`22d08e2`, `spec/e2ee-v2.md` + `spec/aci.md`) defines:

- headers `X-E2EE-Version: 2`, `X-Client-Pub-Key`, `X-Model-Pub-Key`,
  `X-E2EE-Nonce`, `X-E2EE-Timestamp`;
- HKDF info `aci.e2ee.v2.secp256k1` / `aci.e2ee.v2.x25519`;
- AES-GCM AAD = JCS `{purpose, algo, model, field, nonce, ts}` (plus the
  response `id`), which binds each ciphertext to its field and request, and
  replay protection;
- a signed ACI receipt whose `response.returned` hashes **the exact bytes
  the gateway emitted**, and whose `request.received` hashes the restored
  request.

v2 does **not** put the client key in the AAD, so the header swap above still
works against v2 itself. Its defence is detection after the fact. The client
compares SHA-256 of the bytes it received with the receipt's signed
`response.returned`, and a re-encrypted reply doesn't match. That still
doesn't stop the attacker from reading the reply first. Holding the reply
until the receipt verifies would also give integrity: forged replies would
be rejected before display.

**It doesn't work through Venice today.** A live v2 request through
`api.venice.ai` returned 200 with a **plaintext** reply. The gateway got the
ciphertext as ordinary text (the model's reasoning began "Just a hash —"),
so Venice doesn't forward the v2 headers. Nothing leaked, because only
ciphertext was sent. Venice also rewrites response chunks (`id: req_…`,
`model: e2ee-glm-5-3-p`). So the bytes the phone receives never hash to the
gateway's `response.returned`, in either the documented ECDSA flow or v2.
Receipt-based detection is impossible through Venice as it stands.

Hardening taken from this: `VeniceE2EEClient` now **fails closed on any
plaintext reply chunk** (`VeniceE2EEError.plaintextReply`). The relay
controls `venice_parameters`, including Venice's documented `enable_e2ee`
switch, and a dropped header or a disabled E2EE mode both show up as
plaintext replies.

### Residual risk and options (choose before GA)

1. **Accept it for v1**, and say "Amach's servers relay only encrypted data"
   rather than "Amach can never read replies". The relay is about 200 lines
   and doesn't log headers or bodies.
2. **Ask Venice for two things**:
   - Pass E2EE v2 headers through, and pass the gateway's response bytes
     through unmodified (or return them alongside the rewritten ones), so
     clients can verify receipts. That gives detection and integrity using
     a spec that already exists.
   - Ask Venice and dstack to bind the client key in E2EE v3. Putting
     `client_pub_key` in the request AAD makes a swapped header fail
     decryption inside the TEE, which is actual prevention. v2 is frozen
     and v3 is "to be specified", so this is the right time to ask.
3. **Direct-to-Venice with server-minted scoped keys.** The server mints
   short-lived, credit-capped Venice inference keys per device. The phone
   calls Venice directly, so Amach leaves the data path entirely. The costs:
   Venice sees user IPs, key-abuse controls are needed, and Venice's
   key-management API limits need checking. Venice's API layer could still
   swap the header, so this narrows trust to Venice; it doesn't remove it.
4. **Go to the gateway operator directly.** The attested keyset pins TLS
   for `api.redpill.ai`, `inference.phala.com` and `tee.redpill.ai`. A
   client talking to that gateway directly gets v2 plus verifiable
   receipts. That's a provider change outside Venice (new account, pricing,
   model list), so it's for consideration only.

## Q3: fallback across the model chain

- `GET /api/ai/e2ee?tier=chat` → `{models:[…]}` (relay's `getE2EEModelChain`).
- The phone attests each model and caches the result for 10 minutes. Keys are
  KMS-derived and stable per gateway; the cache is keyed by model.
- The phone encrypts the conversation **once per distinct enclave key**,
  not per model. chat = phala + near-ai = 2 encryptions. parseText
  (gpt-oss, deepseek, glm-flash) = also 2.
- One POST carries `attempts:[{model, modelPubKey, messages}]` in chain order.
  The relay tries them in order on 400/404/429/5xx/network error. It stops on
  402 (`ai_credit_exhausted`), and returns `enclave_busy` (503) when all
  fail, the same contract as `callVeniceWithFallback`.
- A fresh client key per request means a failed attempt doesn't leak
  anything to the next one.
- Request size grows by about 2× (hex doubles bytes, and there are 2
  copies), so roughly 4× today's plaintext. A 6 KB context becomes about
  25 KB. Fine for chat. For gut parsing (6 KB sections) still small.
- On `400 E2EE decryption failed` (gateway key rotated), invalidate that
  model's cached key and retry once. Not implemented in the spike.

## Q4: streaming and Vercel's 300 s limit

- The relay streams Venice's SSE straight through (`new Response(upstream.body)`).
  Vercel's limit is total function time (300 s here), not idle time.
- Chat: about 20 s in the spike (GLM 5.3, 758 completion tokens including
  reasoning). No issue.
- Parsing: the phone-side pipeline makes **one relay request per section
  pass**, so no single request carries a whole report. Today's longest
  single sections are well under the limit. Whole gut runs took 97–206 s
  end to end across all sections. Parallelism moves to the phone (keep the
  server's concurrency of about 2–3, since enclaves 429 easily).
- Streaming also keeps bytes flowing for the phone's `URLSession` idle
  timer, which today needs a special 330 s `parseSession`.
- Reasoning: without stripping it's streamed (encrypted) too, which was
  650 of 736 chunks in the first spike run. `strip_thinking_response: true`
  **works under E2EE**: GLM 5.3 went from 131 to 8 chunks and GLM 5.3 Flash
  from 15 to 3, with replies intact. It must be applied inside the enclave
  gateway, since Venice only sees ciphertext. It removes reasoning from the
  reply only; the model still reasons, so quality and token cost are
  unchanged. The relay now always sends it.

## Relay API (website `src/app/api/ai/e2ee/route.ts`)

```
GET  /api/ai/e2ee?tier=chat|parseText|parseLong|memory|agent
  → 200 {"tier":"chat","models":["e2ee-glm-5-3-p","e2ee-qwen3-8-27b","e2ee-glm-5-3-flash"]}

POST /api/ai/e2ee?tier=chat        Authorization: Bearer <backup session token>
  {"clientPubKey":"04…(130 hex)","stream":true,"maxTokens":600,"temperature":0.7,
   "attempts":[{"model":"e2ee-glm-5-3-p","modelPubKey":"04…","messages":[{"role":"system","content":"<hex>"},…]}, …]}
  → 200 text/event-stream (Venice's encrypted SSE, unread), x-amach-model, x-amach-tee(-provider)
  → 400 {code: plaintext_refused | model_not_allowed | bad_client_key | bad_model_key | bad_role | bad_attempts | multiple_system_messages}
  → 401 auth_required | session_expired     (phone signs a new challenge, retries once)
  → 429 rate_limited                         (per wallet)
  → 503 enclave_busy (+ staleKeyModels when an enclave couldn't decrypt) | ai_credit_exhausted | relay_not_configured
  a success served after a stale-key failure carries x-amach-e2ee-stale-key

GET /api/ai/prompts → {sha256, config}       (Luma's prompt text; public, no health data)
```

It refuses any message that isn't ≥186 hex chars, for every role. A client
bug therefore fails closed instead of leaking plaintext to the server.
The route is **off (404) unless `AMACH_E2EE_RELAY_ENABLED=true`**. Because
the relay can't see content, an open one would let anyone run arbitrary
prompts on Amach's Venice key without a trace. POST needs the wallet's
encrypted-backup session token (signed "Amach backup access" challenge from
`/api/backup/credentials`, 2 h) and is limited per wallet: 20 per minute and
500 per day. The limits live in memory, so they're per Vercel instance: a
brake on one wallet, not a global quota. Bodies are capped at 2 MB (413).
`/api/ai/chat` has no auth today.

## The spike

iOS (`Packages/VeniceE2EE`, linked into the app as a local package):

- `VeniceE2EECrypto.swift`: secp256k1 ECDH (swift-secp256k1 `P256K`, pinned
  0.24.0), HKDF + AES-GCM from CryptoKit
- `Keccak256.swift`, `TDXQuote.swift`, `VeniceAttestation.swift`:
  on-device verification
- `VeniceE2EEClient.swift`: chain → attest → encrypt per key → relay → decrypt stream
- `venice-e2ee-spike` CLI, and the DEBUG-only app hook
  `AmachHealth/Sources/API/VeniceE2EESpike.swift` (launch argument
  `-VeniceE2EESpike`)

Website: `src/lib/venice/e2eeRelay.ts`, `src/app/api/ai/e2ee/route.ts`,
`getE2EEModelChain` in `src/config/aiModels.ts`. There are 7 new Jest
tests; the `src/lib/venice` suite passes 26/26.

Run it:

```bash
# website worktree, with VENICE_API_KEY in the environment
AMACH_E2EE_RELAY_ENABLED=true npx next dev -p 3123
# iOS worktree
cd Packages/VeniceE2EE && swift test && swift run venice-e2ee-spike http://127.0.0.1:3123/api/ai/e2ee
```

### Capture results

mitmproxy captured both hops: phone → relay (reverse proxy) and
relay → Venice (`NODE_USE_ENV_PROXY` + mitm CA). The search covered every
request and response body and header for the question text, the system
prompt, and words from the decrypted reply ("ferritin", "hemoglobin",
"18 ng", "11.9", "Luma", "anemia", "clinician", "iron", …):

```
GET  /api/ai/e2ee?tier=chat                 -> 200  plaintext_hits=NONE
POST /api/ai/e2ee?tier=chat (phone->relay)  -> 200  req=2062B res=308583B  plaintext_hits=NONE  api_key_visible=False
POST api.venice.ai/chat/completions (relay->Venice) -> 200  req=893B  plaintext_hits=NONE
  messages: system/user = 342-344 hex chars each, all-hex; 736 SSE chunks, all encrypted
client: served by e2ee-glm-5-3-p (phala), 85/85 content chunks decrypted, reply correct
server log: "[venice-e2ee:e2ee-chat] served by e2ee-glm-5-3-p tee=true/phala attempt=1/2 msgs=2"
```

**Simulator run** (iPhone 17 Pro, iOS 26.2, Debug build, `-VeniceE2EESpike`,
app → mitm reverse proxy → relay → mitm → Venice):

```
[E2EE spike] served by e2ee-glm-5-3-p (phala)
[E2EE spike] attempts=["e2ee-glm-5-3-p", "e2ee-glm-5-3-flash"] skipped=[] encryptedChunks=20 plaintextChunks=0 seconds=26.1
[E2EE spike] reply: No need to panic — your vitamin D is mildly insufficient … talk with your doctor …
capture (needles: vitamin D, 21 ng, TSH, 4.8, mIU, Luma, insufficient, thyroid, doctor, …):
GET  /api/ai/e2ee?tier=chat                          -> 200  plaintext_hits=NONE
POST api.venice.ai/chat/completions (relay->Venice)  -> 200  req=877B  res=62758B  plaintext_hits=NONE
POST /api/ai/e2ee?tier=chat (app->relay)             -> 200  req=2030B res=62758B  plaintext_hits=NONE  api_key_visible=False
```

Attestation went from the app straight to `api.venice.ai` over TLS (not
through Amach). Captures and scan scripts are in the session notes folder.

## Migration plan

| Phase | Work | Size |
|---|---|---|
| 4a | Relay hardened (auth, rate limit, size caps, metrics). `LumaPromptAssembler` + prompt config endpoint. `ChatService` on `VeniceE2EEClient` behind a flag. Key-rotation retry. Stream rendering in the chat UI | ~1 wk |
| 4b | Intel PCS collateral (CRL/TCB) on device. Measurement change alerting. Settings "Private AI: verified enclave" detail view | 3–4 d |
| 4c | Parse pipeline in JavaScriptCore (`amach-parsers.js` built in website CI, `ReportParseEngine`). Then retire `/api/health/parse-report` for the app. Memory/agent tiers through the relay. Inventory of the remaining server Venice callers | ~1–1.5 wk |
| 4d | Remove the plaintext routes for the app (server refuses plaintext AI). mitmproxy regression capture in CI-style script (as for Phase 3) | 2 d |

Decided 2026-10-23: residual-risk option 1 for v1 (product copy: "Amach's
servers only relay encrypted data"; reasoning stripped), and Qwen 3.8 27B
replaces Kimi as the E2EE chat fallback.

### Phase 4a (2026-10-23)

Done, behind `LumaE2EEChat` (off by default; `-LumaE2EEChat YES` in Debug):

- Website: relay auth = backup session token + per-wallet limits
  (`src/lib/venice/e2eeAuth.ts`); `AMACH_E2EE_RELAY_ENABLED` stays the master
  switch. Prompt assembly moved to `src/lib/luma/chatPrompt.ts` (shared by
  `/api/ai/chat`, `GET /api/ai/prompts` and the fixture). Stale-key
  reporting. Refuses >1 system message.
- iOS: `LumaPromptAssembler` reproduces `/api/ai/chat` exactly
  (`LumaPromptAssemblerTests` replays the website's fixture; copy it with
  `scripts/sync-luma-prompts.py`). Bundled prompt config; served configs must
  hash-match, and release builds accept only hashes they ship with.
  `LumaPrivateChat` sends every ChatService call (chat, proactive insight,
  rolling summary, health summary, memory extraction) through
  `VeniceE2EEClient`, streaming. Failures map to Luma's "enclave busy" /
  "out of credit" notes (all attestations failing included); no plaintext
  fallback while the flag is on. `VeniceE2EEClient` adds the bearer token
  (one refresh on 401) and re-attests + retries once on stale enclave keys.
- Simulator capture of both hops: no plaintext (report in the session notes).

Not done / next: Privy-signed relay auth wasn't exercised on the simulator
(no wallet session there; a DEBUG `AMACH_E2EE_RELAY_TOKEN` override was
used); rate limits are per instance; memory extraction still uses the chat
tier (as `/api/ai/chat` does today).

## Side findings

- `Amach-Website/.env.local`'s `VENICE_API_KEY` line holds the key pasted
  about 6 times plus shell-prompt text, so local runs get 401. The spike
  extracted one copy in memory and didn't edit the file.
- The Venice account shows a negative USD balance (DIEM credit about 3.4),
  so the 402 path is close.
- `next dev` prints a Next.js security-advisory nudge on startup.
