# Amach Health iOS — Roadmap

Deferred items from the Luma memory architecture + Privy integration planning sessions.
These are tracked here so they don't get lost as we proceed with other work.

---

## ✅ Completed

### P1 — Session Fact Extraction (Conversation Memory)
- `ConversationMemoryStore` with `CriticalFact[]` and `SessionSummary[]`
- `AIChatMemoryCapsule` injected into every chat request (goals, concerns, medications, conditions, session notes)
- Commit: `03b7b14`

### P3 — 30-Day Health Context Window
- `HealthContextBuilder` expanded from 7-day to 30-day window
- Added `recoveryScore`, `sleepDeepHours`, `sleepRemHours` to `AIChatMetrics`
- Commit: `03b7b14`

### Recovery Score
- `RecoveryScoreBreakdown` computed property on `DashboardTodayData`
- `RecoveryScoreCard` + `RecoveryScorePopover` (tap ⓘ for breakdown)
- Weighted: HRV 40%, RHR 25%, Sleep Duration 20%, Efficiency 15%
- Commits: `7123da5`, `55e1d87`

### Charts → Trends Tab
- All 9 metrics in TrendsView with period selector (7D/30D/90D)
- Sleep stages chart below sleep, HR zones below exercise
- Dashboard cards display-only (no tap navigation)
- Z1 removed from HR zones donut
- Commit: `5953f2e`

---

## 🔨 In Progress

### Privy SDK Integration (Phase 1)
- Install Privy iOS SDK via SPM (`privy-io/privy-ios` v2.9+)
- Rewrite `WalletService.swift` with real SDK calls
- CryptoKit PBKDF2 key derivation matching web exactly
- Add wallet connect to Sync tab (deferred auth — Option C)
- Existing web users: Privy recovers wallet → same address → same encryption key

---

## 📋 Deferred — Priority 2: Unified Storj Memory Schema

**Depends on:** Privy integration (needs wallet for encryption)

### What
Define a shared `amach-memory` Storj object type that both web and iOS read/write.

### Current Problem
- Web writes `ConversationMemory` to Storj as `dataType: "conversation-memory"`
- iOS writes raw `ChatSession` to Storj as `dataType: "chat-session"`
- Neither platform reads the other's data

### Implementation
1. iOS: `ConversationMemoryStore.syncToStorj()` — POST `/api/storj` with `action: "conversation/sync"` (backend already supports this action)
2. iOS: `ConversationMemoryStore.pullFromStorj()` — POST `/api/storj` with `action: "storage/retrieve"`, query by `dataType: "conversation-memory"`
3. Merge strategy: last-write-wins per fact ID, union for collections, dedup by `CriticalFact.value`
4. Wire into auth flow: after Privy login → pull memory from Storj → merge with local
5. Wire into ChatService: after session archive + fact extraction → sync to Storj

### Web-Side Changes
- Update `ConversationMemoryService.ts` to include `platform: "web"` metadata
- Ensure `conversation/sync` action in Storj route handles merge from both platforms
- Add `lastSyncedFrom` field to detect which platform wrote last

---

## 📋 Deferred — Priority 4: Session Summarization via LLM

**Depends on:** P2 (summaries are part of cross-platform memory)

### What
When a chat session is archived, POST the conversation to the backend to generate a 2–3 sentence summary via Venice. Store in `ChatSession.healthSummary` (field already exists but is never populated).

### Implementation
1. Add `/api/ai/summarize-session` endpoint (or reuse `/api/ai/chat` with `mode: "summarize"`)
2. In `ChatService.startNewSession()`: if `currentSession.messages.count >= 4`, fire summary request
3. Store result in `archived.healthSummary`
4. Include summaries in `ConversationMemoryStore.buildMemoryCapsule()` for richer context
5. Sync summaries to Storj as part of P2 memory sync

### Backend Endpoint Design
```json
POST /api/ai/summarize-session
{
  "messages": [...],
  "walletAddress": "0x...",
  "options": { "maxLength": 200 }
}
→ { "summary": "User discussed their declining HRV trend and asked about Zone 2 training..." }
```

---

## 📋 Deferred — Priority 5: True SSE Streaming

**Independent of other priorities**

### What
Replace the iOS client-side streaming simulation (word-by-word, 15ms delay) with real server-sent events from the backend.

### Current State
- Backend returns complete response in one HTTP response
- iOS `AmachAPIClient.streamLumaChat()` splits by spaces and yields word-by-word with `Task.sleep(15ms)`
- Feels acceptable but adds latency (full response must complete before first word appears)

### Implementation
1. Backend: Update `/api/ai/chat` to support `Accept: text/event-stream` header
2. Backend: Stream Venice AI tokens as SSE chunks: `data: {"token": "word"}\n\n`
3. iOS: Use `URLSession.bytes(for:)` to consume SSE stream
4. iOS: Parse `data:` lines and yield tokens to the `AsyncThrowingStream`
5. Fallback: Keep current simulation for non-streaming responses

### Benefits
- First token appears in <1s instead of 5–20s (depends on response length)
- More responsive feel, especially for long analytical responses
- Enables "stop generating" button (cancel the stream)

---

## 📋 Deferred — Web Onboarding Steps for iOS

These web `WalletSetupWizard` steps are NOT needed for iOS MVP but should be added post-launch:

| Web Step | iOS Plan | Priority |
|---|---|---|
| Health Profile (DOB, sex, height, weight) → encrypt → ZKsync | Add as "Complete Your Profile" card in Sync tab | Medium |
| Email Verification → on-chain proof | Add after profile completion | Low |
| Token Claim (beta AHP tokens) | Add as reward after first sync | Low |
| Wallet Funding (test ETH) | Backend handles automatically on wallet creation | Auto |

---

## 📋 Deferred — Luma Memory Improvements (from cross-platform analysis)

| Improvement | Priority | Notes |
|---|---|---|
| Daily Log Service (auto-generated health summaries) | Medium | Web has `DailyLogService.ts` with completeness scoring; iOS could generate on sync |
| Health Profile Store (pattern detection, persona) | Low | Social jetlag, sleep-mood correlation; useful for Luma personality |
| Hybrid Search Index (BM25 over chat history) | Low | Web has `HybridSearchIndex.ts`; iOS would need CoreData or SQLite |
| Tiered storage (hot/warm/cold) | Low | Web uses localStorage → IndexedDB → Storj; iOS could use Documents → CoreData → Storj |
| Memory encryption at rest | Medium | Web encrypts memory with wallet key; iOS should do the same once Privy is wired |
