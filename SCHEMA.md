# Amach vault schema (v2)

The on-device vault is the start of the protocol's data format. Names are Amach's, not HealthKit's. HealthKit is one source among several.

- **Engine:** SQLite through GRDB 7, one database per wallet: `Application Support/Vault/vault-<id>.sqlite`.
- **Protection:** the vault directory and the database, `-wal` and `-shm` files use `FileProtectionType.complete` and are excluded from backup.
- **Key:** `HKDF-SHA256(ikm = wallet encryption key bytes, salt = empty, info = "amach-local-db-v1", 32 bytes)`.
  - It is derived on the phone each time, never stored, and never sent anywhere.
  - Today it names the file (`<id>` = first 8 bytes of `HMAC(key, "vault-file-id")`) and is checked on open through `vault_meta.key_check`.
  - It is ready to become the SQLCipher passphrase. SQLCipher isn't used yet, because GRDB only supports it through SPM by forking GRDB.
- **Code:** `AmachHealth/Sources/Vault/VaultDatabase.swift` (migrations), `VaultRecords.swift` (row types), `AmachMetric.swift` (metric vocabulary).

## Conventions

| Thing | Format |
|---|---|
| `day` | Local calendar date, `YYYY-MM-DD`, in the phone's time zone when the row was written |
| Timestamps (`*_at`) | Unix milliseconds, UTC |
| `*_json` | UTF-8 JSON with sorted keys |
| `origin` / `source` | Where a row came from (see each table) |

## Migrations

- **`schema_version (version, applied_at)`:** one row per applied migration.
- GRDB's `grdb_migrations` table tracks migration identifiers ("v1", ...).
- Every change is a new migration. An existing one is never edited.
- **Current version:** 2.
  - **v1:** Phase 2, the base schema.
  - **v2:** Phase 3. Adds `lab_pdfs` and `backup_objects`, and backup triggers on `lab_pdfs` and `storj_imports` (existing `storj_imports` rows are queued once).

## vault_meta

| Column | Meaning |
|---|---|
| key, value | Key/value text. Keys in use:<br>• `key_check`, `wallet_address`<br>• `hk_backfill_from` (oldest day backfilled from HealthKit)<br>• `hk_backfill_complete`<br>• `storj_import_completed` (ISO time)<br>• `storj_import_report` (JSON)<br>• `backup_enabled` ("1" when encrypted backup is on)<br>• `backup_generation`, `backup_last_success` (ms), `backup_index_body` (JSON part list)<br>• `backup_restore_checked` (ms; the new-phone restore check ran)<br>• `legacy_storj_cleanup` (JSON summary once old Storj objects were deleted)<br>• `memory_extracted` (JSON `[{session, messages}]`: how many messages of each recent chat session have been read for memory; last 60 sessions) |

## daily_metrics

One row per day and metric. Primary key: `(day, metric)`.

| Column | Meaning |
|---|---|
| day | Local date. Samples count on the day they start; sleep counts on the day it ends. |
| metric | Amach metric id (table below) |
| total | Daily sum, for `sum` metrics. For `sleep`: minutes asleep (core + deep + REM). |
| avg, min, max | Daily mean, minimum and maximum, for `range` and `average` metrics |
| count | Number of source samples that day (0 when an import didn't record it) |
| source | `healthkit`, `import:ios` (old iOS Storj payload) or `import:web` (website XML import) |
| sleep_in_bed_min, sleep_awake_min, sleep_core_min, sleep_deep_min, sleep_rem_min | Sleep stages in minutes. Unspecified "asleep" counts as core. Only on `metric = 'sleep'`. |
| sleep_efficiency | asleep ÷ in bed (0–1), or null when no in-bed time was recorded |
| updated_at | Last write |

**Write rule:** HealthKit rows overwrite. Imports only fill days that have no HealthKit row; a later import replaces an earlier import's row.

**HealthKit aggregation:**
- Daily totals for sum metrics come from `HKStatisticsCollectionQuery`, which removes Watch/iPhone overlap.
- avg, min, max and count come from the raw samples.

### Metrics

| id | unit | aggregation |
|---|---|---|
| steps | count | sum |
| active_energy | kcal | sum |
| basal_energy | kcal | sum |
| exercise_minutes | min | sum |
| stand_minutes | min | sum |
| move_minutes | min | sum |
| flights_climbed | count | sum |
| distance_walking_running | m | sum |
| distance_cycling | m | sum |
| distance_swimming | m | sum |
| time_in_daylight | min | sum |
| heart_rate | bpm | range |
| hrv_sdnn | ms | range |
| respiratory_rate | breaths/min | range |
| blood_oxygen | % (0–100) | range |
| body_temperature | °C | range |
| blood_glucose | mg/dL | range |
| blood_pressure_systolic | mmHg | range |
| blood_pressure_diastolic | mmHg | range |
| resting_heart_rate | bpm | average |
| walking_heart_rate | bpm | average |
| vo2_max | mL/kg/min | average |
| body_mass | kg | average |
| lean_body_mass | kg | average |
| body_fat | % (0–100) | average |
| bmi | kg/m² | average |
| height | m | average |
| waist_circumference | cm | average |
| dietary_energy | kcal | sum |
| dietary_protein | g | sum |
| dietary_carbohydrates | g | sum |
| dietary_fat | g | sum |
| dietary_fiber | g | sum |
| dietary_sugar | g | sum |
| dietary_water | mL | sum |
| dietary_caffeine | mg | sum |
| sleep | min asleep, plus stage columns | special |
| workout_minutes | min (count = workouts) | sum |
| mindful_minutes | min (count = sessions) | sum |

**HealthKit ingestion** covers the metrics the app already asks permission for, plus `sleep`, `workout_minutes` and `mindful_minutes`. The other metric ids are filled by imports only, so the permission prompt is unchanged.

**Imports** convert older payloads to these units:
- iOS stored percentages as 0–1 and water in litres; both are converted.
- The website's XML import kept the export's units. Distance is treated as km when a payload's median daily distance is under 300.
- Keys with no metric id are kept: the import keeps the payload in `storj_imports.payload_json`.

## lab_reports

| Column | Meaning |
|---|---|
| id | Report id. Device uploads use the upload's report id; imports use `storj-<hash of object key>`; manual entries use the record id. |
| kind | `bloodwork`, `dexa` or `medical` |
| report_date | Collection or scan date, `YYYY-MM-DD` when known |
| laboratory | Lab or provider name |
| source_pdf_sha256 | SHA-256 of the uploaded PDF (device uploads) |
| created_at | When it was stored (for imports, the Storj upload time) |
| subtype | For example `manual-entry`, `gut-health`, or a medical document type (`imaging`, ...) |
| title, source, notes | As parsed |
| narrative | Clinical narrative text, when one was generated |
| fingerprint | Content fingerprint (FhirConverter fingerprints). Unique per kind, so duplicates are refused. |
| origin | `device`, `import` or `legacy-file` |
| storj_key | Source object key (imports) |
| attestation_tx_hash | On-chain attestation, when known |

## lab_markers

One row per value. Nothing in a report is dropped.

| Column | Meaning |
|---|---|
| report_id | → lab_reports.id (cascade delete) |
| position | Order within the report |
| name | Name as printed |
| canonical_name | Lowercase snake_case of the name. For DEXA it is a fixed vocabulary: `body_fat_percent`, `lean_mass_kg`, `fat_mass_kg`, `bone_density_g_cm2`, `bone_t_score`, `bone_z_score`, `visceral_fat_rating`, `visceral_fat_area_cm2`, `visceral_fat_volume_cm3`, `android_gynoid_ratio`. |
| value | Numeric value |
| value_text | Non-numeric result (for example "Non-reactive"), or the text of a medical finding |
| unit, reference_range | As reported |
| flag | `low`, `high`, `critical-low`, `critical-high`, `normal` (bloodwork); provider status (gut health) |
| panel | What the value belongs to, which depends on the report kind:<br>• Bloodwork: the lab panel, when known.<br>• DEXA: the body region (`total` for whole-body values; regions such as `left_arm` and `trunk` are kept).<br>• Medical records: `summary`, `finding`, `diagnosis` or `medication`.<br>• Gut health: the report section. |

## timeline_events

| Column | Meaning |
|---|---|
| id | Event id (iOS UUID or website id) |
| event_type | For example `MEDICATION_STARTED`. Types this app doesn't know are kept as written and shown as Custom. |
| occurred_at | When it happened |
| data_json | Event fields as strings |
| metadata_json | `{platform, version, source}` |
| anomaly_type, metric, direction, deviation_pct, resolved_at | Anomaly events |
| attestation_tx_hash | On-chain record, when known |
| origin | `device`, `import` or `legacy-cache` |
| updated_at | Last write |

## journal_entries

Created for the journal feature; nothing writes to it yet.

| Column | Meaning |
|---|---|
| id | Entry id |
| day | Local date the entry is for |
| body | Entry text |
| tags_json | Tags |
| created_at, updated_at | Timestamps |

## chat_sessions / chat_messages

| Table | Columns |
|---|---|
| chat_sessions | id (UUID), created_at, updated_at, is_current (the open session), health_summary, rolling_summary, storj_uri (legacy upload), origin |
| chat_messages | id (UUID), session_id → chat_sessions (cascade), position, role (`user`, `assistant`, `system`), content, created_at, metadata_json (proactive-insight link), feedback (`helpful`, `unhelpful`) |

The vault keeps every session; the chat list shows the 30 most recent. Website sessions with non-UUID ids get a stable UUID derived from SHA-256 of the id.

## memory_facts / memory_summaries

| Table | Columns |
|---|---|
| memory_facts | id, category (`medication`, `condition`, `goal`, `concern`, `preference`), value, context, identified_at, last_confirmed_at, is_active |
| memory_summaries | id, date, summary, topics_json, importance (`critical`, `high`, `medium`, `low`), message_count |

Retention is the same as before: 200 facts and 40 summaries.

- A fact the user says no longer holds (stopped a medication, goal reached, concern resolved) is retired: `is_active` = 0 and `last_confirmed_at` = when it was retired. Retired facts are not sent to Luma.
- A summary written since memory is read mid-session has the chat session's id and is rewritten as the session grows; older summaries have their own ids.

## merkle_leaves / merkle_roots

| Table | Column | Meaning |
|---|---|---|
| merkle_leaves | day_id | Days since the Unix epoch |
| | leaf_version | Serialization version (1 = genesis) |
| | fields | The leaf's inputs as JSON |
| | hash | Leaf hash as 0x-hex |
| merkle_roots | root | 0x-padded root |
| | start_day, end_day | Day ids covered |
| | tx_hash | On-chain commit, when known |
| | leaf_count, tree_depth | Tree shape |
| | created_at | When stored |

## lab_pdfs (v2)

Original PDFs the user uploaded, kept so encrypted backup can carry them. The bytes are a file at `Vault/files-<id>/pdfs/<sha256>.pdf`, with complete protection and excluded from iCloud backup.

| Column | Meaning |
|---|---|
| sha256 | SHA-256 of the PDF bytes (primary key and file name) |
| report_id | → lab_reports.id it was parsed into (not a foreign key; the PDF outlives a deleted report until the user removes it) |
| filename | Original file name |
| byte_count | Size |
| created_at | When it was saved |

## backup_objects (v2)

The phone's copy of the encrypted backup index, one row per chunk ([BACKUP-FORMAT.md](BACKUP-FORMAT.md)). Not itself backed up.

| Column | Meaning |
|---|---|
| chunk_key | For example `daily_metrics/2026-09` or `lab_report/<id>` |
| entry_json | The chunk's index entry: parts, hashes, version, record ids |
| updated_at | Last write |

## backup_state

| Column | Meaning |
|---|---|
| record_type | Table name |
| record_id | Primary key as text. For `daily_metrics` it is `day|metric`; for `merkle_leaves` it is `day_id|leaf_version`. |
| local_version | Incremented by triggers on every insert, update and delete of a backed-up table |
| backed_up_version | Version last backed up (0 = never) |

A row needs backing up when `local_version > backed_up_version`. A record missing from its table is a deletion. Tables with triggers: every table above from daily_metrics to merkle_roots, plus (v2) `lab_pdfs` (id = sha256) and `storj_imports` (id = object_key).

## healthkit_sync

| Column | Meaning |
|---|---|
| stream | Metric id of the HealthKit stream |
| anchor | Archived `HKQueryAnchor` for the anchored query (which watches the last 30 days) |
| backfilled_from, earliest_day | Reserved; overall backfill progress is in `vault_meta` |
| updated_at | Last write |

## storj_imports

One row per Storj object seen by the one-time import, so nothing is skipped silently.

| Column | Meaning |
|---|---|
| object_key | Key in the wallet's bucket |
| data_type | Prefix of the key (the dataType it was uploaded with) |
| uploaded_at | From the key |
| size | Bytes |
| status | One of:<br>• `imported`<br>• `duplicate` (already in the vault)<br>• `archived` (no table yet; decrypted JSON kept)<br>• `failed` (reason in `detail`; retried on the next run) |
| record_type, record_id | Where it went |
| detail | Counts, notes or the failure reason |
| payload_json | Decrypted JSON when it is archived, or when part of it had no table to go to |
| imported_at | When it was processed |
