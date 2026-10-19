# Project state: local-first

Decisions and status across the local-first phases. Branch naming: `local-first/phase-N-*`, in both AmachHealth-iOS and Amach-Website.

## Phase 2: local vault (`local-first/phase-2-vault`)

- **Vault:** plain GRDB, one database per wallet, `FileProtectionType.complete`, excluded from iCloud backup (SCHEMA.md).
- **No SQLCipher:** GRDB supports SQLCipher through SPM only by forking GRDB. The HKDF vault key names the file and is checked on open, ready to become the SQLCipher passphrase. Because the database file isn't encrypted, it stays out of iCloud backup, and Phase 3's settings copy does not say iCloud backup works.
- **Storj import:** history is imported on device through keyless `storage/list-raw` and `storage/download-raw`.

## Phase 3: phone-side encryption and opt-in Storj backup (`local-first/phase-3-backup`)

### Credential mode: presigned URLs (not restricted access grants)

The brief preferred deriving a child access grant per user (prefix-restricted, short expiry) and registering it for S3 credentials, with presigned URLs as the fallback. **We use presigned URLs.**

Why grant restriction was awkward here:

- **No library on the server runtime.** Restricting a grant needs Storj's uplink library. The website runs on Vercel's Node runtime, and there is no maintained pure-JS uplink (`uplink-nodejs` is a native binding).
- **Hand-rolling it is risky.** We would have to reimplement macaroon caveats, plus Storj path-encryption key derivation for the prefix, because grants created in the console encrypt object keys. A mistake there produces credentials that look valid but don't work, or that work too broadly.
- **It can't be tested from here.** That code can only be tested against the real parent grant.

What presigning gives instead:

- The server holds S3 credentials for the backup project (registered from its access grant). After a wallet signature it issues a 2-hour session token bound to the user's prefix.
- With that token it signs 15-minute URLs only for `<prefix><32-hex id>` (PUT, GET, DELETE) and for LIST on the prefix.
- The phone uploads and downloads directly to `gateway.storjshare.io`.

What this costs:

- **The server signs each batch of URLs.** It sees opaque ids, counts and timing, as it would with grants, but per request rather than once per session.
- **No size cap.** Presigned PUTs (signed headers: `host`) can't cap object size, so a user could store large objects in their own folder. A POST-policy upload would allow a `content-length-range`; that's a follow-up if abuse appears.
- **Challenges can be replayed for 5 minutes.** They are sealed with HMAC and expire after 5 minutes, but no nonce store is kept, so the same signed challenge works again inside that window. That's acceptable because the signature only travels over TLS. A KV-backed nonce set would close it.

If uplink becomes usable server-side (a WASM build, or a small Go function), swap the "presign" action for a "grant" action. The phone's transport is one class (`PresignedStorjTransport`).

### Website configuration needed (Vercel, not yet set)

| Variable | Value |
|---|---|
| `STORJ_BACKUP_ACCESS_KEY` / `STORJ_BACKUP_SECRET_KEY` | S3 credentials for Dave's Storj backup project. Generate them from an access grant that can read, write, list and delete in the backup bucket. |
| `STORJ_BACKUP_BUCKET` | Bucket name in that project (default `amach-backup`; create it once) |
| `STORJ_BACKUP_ENDPOINT` | Default `https://gateway.storjshare.io` |
| `STORJ_BACKUP_REGION` | Default `us-east-1` |
| `BACKUP_PREFIX_SALT` | Random 32+ bytes. **Never rotate it:** it decides every user's folder. |
| `BACKUP_TOKEN_SECRET` | Random 32+ bytes. Rotating it only logs sessions out. |

Without these, `/api/backup/credentials` returns 503 and the app shows backup as unavailable.

### What shipped

- **Format v1:** BACKUP-FORMAT.md (keys, object layout, chunks, index, access, test vectors).
- **Schema v2:** `lab_pdfs` and `backup_objects`, plus backup triggers on `lab_pdfs` and `storj_imports` (SCHEMA.md).
- **iOS (`Sources/Vault/Backup/`):** crypto, format, engine (backup, restore, verify, garbage collection), presigned transport, and `BackupService`, which debounces backups by 120 s, runs a `BGProcessingTask` (`com.amach.health.backup`), restores on a new phone, and handles legacy cleanup. Settings → Encrypted backup holds the toggle, the explanation, "last backed up", "Back up now", "Restore from backup" and "Remove old copies from Storj".
- **Legacy cleanup:** offered after a backup, once the Storj import has completed.
  - First it verifies the whole backup: every object is downloaded, decrypted and hash-checked.
  - It then lists the old shared bucket and deletes only objects whose `storj_imports` row is `imported`, `duplicate` or `archived` and is itself backed up.
  - Deletion goes through the new `storage/delete-raw`. That route needs a backup session token, and the server checks each object's `userAddress` metadata against the signed-in wallet.
- **Removed:**
  - `VaultFlags.legacyStorjWrites`.
  - Every API call that sent `encryptionKey`: `storage/*` store, list, retrieve and delete; `report/*`; health summary; chat session and conversation memory sync; `createAttestation` and `profile/read`, which also sent the key; the Merkle genesis, v2 leaf upload and coverage generation calls.
  - `StorjTimelineService`, `StorageDetailView` and the Storj lab list.
- **Turned off:** `FeatureFlags.zkServerFlowsDisabled = true` disables `/api/merkle/genesis` and `/api/proofs/*` and hides their UI (genesis/coverage card, Shareable Proofs link).
- **Guard:** `OutboundSecretGuard` refuses any API request body that contains the wallet key or derivation signature.

### Tests (2026-10-17)

- **iOS:** 449 run. 446 pass, 1 skipped (live Storj import, opt-in), 3 fail.
  - The 3 failures are in `PDFReportParser`. They fail the same way on `local-first/phase-2-vault`, so they predate this work.
  - `SeedHealthKitTests` hangs on the HealthKit permission sheet and was skipped.
  - New suites, all passing:
    - `BackupCryptoTests`: the Node-computed vectors.
    - `BackupEngineTests`: round trip on a wiped vault, opacity, incremental, deletions, interrupted runs, 4 MB splitting, merge, verify.
    - `BackupServiceTests`: toggle, new-phone restore.
- **Website:** 310 Jest tests pass, including `src/encryptedBackup` (AWS's published SigV4 signature, challenge and session, presign scoping) and `storage/delete-raw`. Type-check, ESLint and Prettier are clean.

### Open items

1. **Plaintext health data still leaves the phone through AI features.**
   - Chat (`/api/ai/chat`) sends health context and messages.
   - PDF parsing (`/api/health/parse-report`) sends the extracted text.
   - Both go to Amach's server over TLS and on to private (enclave) models. They contain no key or signature, but a TLS-intercepting capture of a chat session will show plaintext health data. Meeting the brief's "no plaintext health data" criterion for chat needs end-to-end encryption to the enclave, or on-device inference. That's a product decision, outside Phase 3.
2. **Profile Basics hidden.** The server-decrypted profile read (`/api/profile/read`) was removed, so that section is gone until the profile is decrypted on device.
3. **Live end-to-end test not run yet.** It needs the env vars above on a preview deployment, and an interactive Privy login for the test wallet on a wiped simulator. Steps are in "Restore test" below.
4. **Network capture not run yet.** It needs the same setup.

### Restore test (to run once the backup env vars are set)

1. Point the app at the preview by setting the `AMACH_API_URL` scheme env var (plus `AMACH_VERCEL_BYPASS` if the preview is protected).
2. Sign in with the test wallet, turn on Settings → Encrypted backup, and wait for "Last backed up just now".
3. Erase the simulator: `xcrun simctl erase <udid>`.
4. Install, sign in with the same wallet (one Privy login), and watch Settings → Encrypted backup show "Restoring n of m…".
5. Check dashboard days, labs, timeline, chat history and memory against step 2.
6. Capture traffic (Proxyman or Charles with the simulator proxy) across sync, chat, backup and restore. Search the capture for the wallet key, the derivation signature, and known plaintext values. Expect hits only in the AI calls named in open item 1.
