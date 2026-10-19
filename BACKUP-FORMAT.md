# Amach backup format (v1)

The encrypted backup is part of the Amach protocol, not just an iOS feature. Any client that holds the wallet encryption key can read and write it. Nobody else can: not Storj, not Amach's servers, not someone who copies the bucket.

- **Code:** `AmachHealth/Sources/Vault/Backup/` (`BackupCrypto.swift`, `BackupFormat.swift`, `BackupEngine.swift`)
- **Server side:** `Amach-Website/src/encryptedBackup/`, behind `POST /api/backup/credentials`
- **Rows:** use the vault schema in [SCHEMA.md](SCHEMA.md)

## 1. Keys

| Name | Derivation |
|---|---|
| Wallet key | The 32-byte PBKDF2 output from the wallet signature (64 hex characters). It never leaves the device. |
| **Backup key** | `HKDF-SHA256(ikm = wallet key bytes, salt = empty, info = "amach-backup-v1", L = 32)` |
| Vault key (for comparison) | Same HKDF, `info = "amach-local-db-v1"`. The two keys are independent. |
| **Index id** | `hex(HMAC-SHA256(backup key, "amach-backup-index-v1")[0..<16])` |

The backup key is derived on the device each time it is needed. It is never stored and never sent.

## 2. Objects

Every object, including the index, has the same layout:

```
byte 0        version = 0x01
bytes 1–12    nonce (random, 12 bytes)
bytes 13–n-16 AES-256-GCM ciphertext
last 16 bytes GCM tag
```

- **AAD:** `"amach-backup-v1/" + object id` (UTF-8). This binds each object to its name, so objects can't be swapped or replayed under another id.
- **Object ids:** 16 random bytes as 32 lowercase hex characters. The index id looks exactly the same.
- **Storage key:** `<user prefix><object id>` in the backup bucket (see §6).
- **No metadata:** content type is `application/octet-stream` and there are no `x-amz-meta-*` headers.
- **What an observer learns:** nothing in a name, a header or a listing reveals the data type, date, count or category. Storage and the website see sizes and timing only.
- **Immutable:** objects are never rewritten in place. Changed content gets a new id. The one exception is the index, which is replaced at its fixed id.

## 3. Chunks

Vault data is grouped into chunks. Each chunk is one plaintext, split into parts of at most 3 MiB, so every object stays well under 4 MB. Each part is its own object.

| Chunk key | Contents | `recordIds` |
|---|---|---|
| `daily_metrics/YYYY-MM` | All `daily_metrics` rows for that local month | omitted (the record id names the month) |
| `lab_report/<id>` | One `lab_reports` row and its `lab_markers` | listed |
| `timeline/YYYY-MM` | `timeline_events` whose `occurred_at` falls in that **UTC** month | listed |
| `journal/YYYY-MM` | `journal_entries` for that month | listed |
| `chat_session/<id>` | One `chat_sessions` row and its `chat_messages` | listed |
| `memory` | All `memory_facts` and `memory_summaries` (the memory snapshot) | listed |
| `merkle_leaves/YYYY` | `merkle_leaves` whose `day_id` falls in that UTC year | omitted |
| `merkle_roots` | All `merkle_roots` | listed |
| `lab_pdfs` | All `lab_pdfs` rows | listed |
| `pdf/<sha256>` | The original PDF bytes (a **blob** chunk) | `["lab_pdfs|<sha256>"]` |
| `storj_imports` | The legacy import ledger, including archived payloads | listed |

Chunk keys appear only inside the encrypted index.

### Rows chunk plaintext

UTF-8 JSON with sorted keys:

```json
{
  "format": "amach-backup-chunk",
  "version": 1,
  "schemaVersion": 2,
  "chunk": "daily_metrics/2026-09",
  "tables": {
    "daily_metrics": {
      "columns": ["day", "metric", "total", "avg", "..."],
      "rows": [["2026-09-01", "steps", 8000, null, "..."]]
    }
  }
}
```

- **Values:** JSON null, number, string, or `{"b64": "..."}` for a blob. Integers and reals are both JSON numbers; SQLite column affinity restores the type.
- **Order:** rows are sorted by primary key, so unchanged data produces identical bytes and isn't re-uploaded.
- **Record ids** are the `backup_state.record_id` format: `day|metric` for daily_metrics, `day_id|leaf_version` for merkle_leaves, `object_key` for storj_imports, `sha256` for lab_pdfs, and `id` for everything else. In `recordIds` they are prefixed with the table: `"chat_messages|<id>"`.

### Blob chunk plaintext

Blob chunks hold the raw bytes. A reader must check `sha256` against the chunk key.

## 4. Index

**Root object.** It is stored at the index id and kept small:

```json
{
  "format": "amach-backup-index",
  "version": 1,
  "schemaVersion": 2,
  "generation": 7,
  "updatedAt": 1792233600000,
  "body": [{ "id": "<32 hex>", "sha256": "<hex of part plaintext>", "size": 1234 }],
  "bodySha256": "<hex of the whole body plaintext>"
}
```

**Body.** Its parts are joined in order and must hash to `bodySha256`:

```json
{
  "chunks": [{
    "key": "lab_report/bloodwork-2026-07-14-x1",
    "kind": "rows",
    "tables": ["lab_reports", "lab_markers"],
    "month": null,
    "recordIds": ["lab_reports|bloodwork-2026-07-14-x1", "lab_markers|12"],
    "version": 3,
    "sha256": "<hex of the whole chunk plaintext>",
    "size": 5120,
    "parts": [{ "id": "<32 hex>", "sha256": "<hex>", "size": 5149 }]
  }]
}
```

- **`version`** counts re-uploads of that chunk.
- **`generation`** counts index commits.
- **`size`** in a part is the stored (encrypted) size. `size` on a chunk is the plaintext size.
- **Readers must verify** every part's `sha256`, the joined chunk's `sha256`, and the GCM tag.

## 5. Writing and reading

**Backup**, run after changes (debounced to about two minutes) and as a background catch-up:

1. Read pending records from `backup_state`. A record is pending when `local_version > backed_up_version`. Map each record to its chunks, both where it lives now and where the index last put it. That second lookup catches deletions and moves.
2. For each affected chunk, read its rows in one transaction, along with the `local_version` of its pending records.
3. If the plaintext's sha256 equals the index entry's, skip the upload. Otherwise seal new parts under new ids and upload them. A chunk with no rows left is removed.
4. Upload a new body (new ids), then the root, at the index id. The commit point is the root write. Before it, the old index is untouched and still names only objects that exist.
5. Locally, record the new entries and set `backed_up_version` to the versions read in step 2.
6. Delete superseded objects. Then list the prefix and delete anything the index doesn't name (garbage collection).

Long first backups commit every 40 changed chunks or 24 MB, so an interruption keeps the progress made so far.

**Restore** (new device):

1. Fetch the root at the index id. A missing root means there is no backup.
2. Fetch and verify the body.
3. Download chunks in batches and verify them. Insert rows with `INSERT OR IGNORE`, parent tables first.
4. Rows already on the device win. A chunk where any row was kept local stays pending, so the next backup uploads the merged result. Fully applied chunks are marked backed up.
5. Write blob chunks to the vault's file directory after checking their hash.

A device whose vault has never committed a backup refuses to back up over an existing index (`needsRestore`). It must restore first.

**Concurrency:** one writer per wallet is assumed. Two devices backing up the same wallet at once can overwrite each other's index. The losing device's next run re-uploads its changes, and garbage collection can delete objects the other device just wrote. Multi-device sync needs a later format version.

## 6. Access

There is one bucket in the Amach Storj backup project. Each user gets a folder:

```
prefix = "u/" + hex(HMAC-SHA256(BACKUP_PREFIX_SALT, lower(wallet address)))[0..<32] + "/"
```

1. The device asks for a challenge: `POST /api/backup/credentials {action: "challenge", address}`.
2. The server returns a message and a sealed challenge token:

   ```
   Amach backup access
   Address: 0x…
   Nonce: <32 hex>
   Expires: <ISO 8601, 5 minutes>
   ```

   This is not the key derivation message. The device refuses to sign anything that doesn't start with `Amach backup access\n`, and the server rebuilds the message from its own sealed token. A signature over any other message, including the derivation message, can't be used.
3. The device signs the message with `personal_sign` and sends `{action: "session", address, challenge, signature}`. The server verifies the signature and returns a session token: HMAC-sealed, bound to the prefix, valid for 2 hours.
4. With `{action: "presign", token, ops}` the device gets 15-minute presigned URLs: PUT, GET or DELETE for `<prefix><id>`, and LIST scoped to `prefix`. It then talks to the Storj S3 gateway directly.

The server never sees object contents, the wallet key, or the derivation signature. Requests that include an encryption key are refused. On the device, `OutboundSecretGuard` blocks any API request whose body contains the key or the derivation signature.

## 7. Test vectors

All values are hex. They were computed with Node's `crypto` (`hkdfSync`, `aes-256-gcm`), independently of CryptoKit, and are checked in `BackupCryptoTests`.

**Inputs**

| Input | Value |
|---|---|
| wallet key | `3f1c9a0b7d2e4f6a8b0c1d2e3f405162738495a6b7c8d9e0f1a2b3c4d5e6f708` |
| object id | `00112233445566778899aabbccddeeff` |
| nonce | `000102030405060708090a0b` |
| plaintext | `{"hello":"amach"}` |

**Outputs**

| Output | Value |
|---|---|
| backup key | `27397bb0c08c69f280a606cdaf3e16381d31b5a96c2d6465c235574287de9efd` |
| index id | `421dc8852aa7c1bfb2c9be43666c5467` |
| object | `01000102030405060708090a0b520dcba58edeb0098e7a76c21a12dc48a1e2e4fb62b2fd1f99874b4f5a63582f8a` |

## 8. Versioning

- **Byte 0** of an object changes only if the encryption layout changes.
- **`format` and `version`** in the root and chunks change if their JSON shape changes.
- **`schemaVersion`** is the vault schema the rows follow. A reader refuses a backup whose `schemaVersion` is newer than it knows ("update the app"). Rows from an older schema go into the current tables, and columns they don't carry take the column default. A future migration that changes meaning, not just adds columns, must say how older backups map.
