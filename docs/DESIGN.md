# Dark Zenith - Product Design

## Overview

Dark Zenith is an Elixir/Phoenix application that serves as a fully-functional RPM package repository. It renders all repository metadata and web pages, while RPM files themselves are stored in Backblaze B2 object storage and served to clients via time-limited signed URLs.

## Major Features

### Web Interface

- **Create new repos**: Authenticated users can create and configure new RPM repositories.
- **Browse existing repos**: Public listing of public repositories, with authenticated users also seeing private repositories they can access.
- **Global package search**: Instance-wide search over repositories and packages from a field in the top navigation, scoped to what the requester can already browse (see Web Interface: Search).
- **Repo setup instructions**: Per-repo page with copy-paste commands for adding the repo to a user's `dnf` configuration.
- **View available packages**: Browsable, searchable list of packages within a repository.
- **Package install instructions**: Per-package page with `dnf install` commands and details.
- **Upload RPM packages**: Repository owners and admins can upload new RPM versions (binary or source) to a repository.

### REST API

- Programmatic access to repository operations: creating repos, listing repos, listing packages, uploading RPMs, deleting packages, etc.
- Authenticated via bearer tokens (API keys or short-lived session tokens), with session cookies accepted for web-originated calls.

### RPM Repository Serving

- The web app renders all `repodata/` metadata (`repomd.xml`, `primary.xml.gz`, etc.) required by the supported DNF 4 and DNF 5 clients.
- RPM files are stored in **Backblaze B2** object storage.
- When a client requests an RPM file, Dark Zenith responds with a redirect to a **signed B2 URL with a configurable access window** (default 30 minutes).
- Client-facing RPM payload traffic bypasses the app: uploaders send RPMs directly to a private B2 staging key with a short-lived presigned `PutObject` URL, and downloaders follow a redirect to a short-lived presigned B2 URL. Background workers still stream exact staged object versions from B2 into mode-restricted local working directories for validation and optional signing, then write the accepted final object back to B2.

---

## Architecture

### Technology Stack

| Layer | Technology |
|---|---|
| Language | Elixir |
| Web Framework | Phoenix (with LiveView) |
| Database | PostgreSQL |
| RPM Storage | Backblaze B2 (S3-compatible API) |
| Background Jobs | Oban |
| Authentication | `mix phx.gen.auth` (bcrypt-based session auth) |
| API Auth | Bearer token (API keys or short-lived session tokens) |

### High-Level Components

```
 Upload client ── control requests ──► Dark Zenith ◄── repodata/download request ── RPM client
       │                                  │    │                                      │
       │ presigned PUT                    │    ├── PostgreSQL                         │ 302
       │ (staging object)                 │    │   (state + metadata)                 │
       ▼                                  │    │                                      ▼
 Backblaze B2 ◄── worker GET/PUT/Copy ────┘    └── Oban workers ───────────────► Backblaze B2
 (staged and final RPM versions)              (validate/sign/retry)              (signed GET URL)
```

The presigned upload URL names one server-generated staging key and cannot write elsewhere in the bucket. Browser-to-B2 traffic uses B2 CORS and does not traverse the Phoenix reverse proxy or Cloudflare zone in front of the app. The application key itself is never exposed to the client.

### Background Retry Policy

Unless a section explicitly declares an operation non-retryable, every durable background operation uses the same bounded retry policy. Failed attempt `n` (one-indexed) is retried after `min(3600, 30 * 2^(n - 1))` seconds, without random jitter. When an external HTTP service returns a syntactically valid `Retry-After` delta-seconds value or future HTTP-date, `provider_delay` is the positive integer delta or `ceil(date - now)` respectively, and the delay is `min(86400, max(calculated_delay, provider_delay))`; zero, negative, past, overflowed, or malformed values are ignored. The twentieth failed attempt is terminal and has no next run. Deterministic validation, authorization, quota, and state-conflict errors fail immediately without consuming infrastructure retries.

State machines with a `next_attempt_at` column write that timestamp in the same transaction that relinquishes a claim. Oban-only work schedules the identical delay in the replacement job. Oban uniqueness is an efficiency measure, not correctness state; sweepers reconstruct missing jobs from durable application rows, and exhausted work remains visible for admin intervention. Tests freeze the clock and cover attempts 1, 2, 8, and 20, the one-hour calculated cap, the one-day `Retry-After` cap, malformed provider values, and crash-safe rescheduling.

---

## Data Model

### Repositories

A Dark Zenith instance can host multiple named repositories. Each repository is an independent RPM repo with its own metadata and package set.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `user_id` | UUID | FK to users — the owner of this repository |
| `slug` | string | Normalized lowercase URL-safe identifier (e.g., `stable`, `nightly`); must match `^[a-z0-9][a-z0-9_-]{0,63}$`; the value `new` is reserved for the repository-creation route and rejected; slugs of deleted repositories are retired and unavailable to other users (see Slug Reservations) |
| `name` | string | Display name (max 100 characters after trimming) |
| `description` | text | Optional description (max 4 096 characters after trimming) |
| `gpg_key_fingerprint` | string | Optional 40-character uppercase hex OpenPGP V4 fingerprint of the GPG key used to sign metadata for this repo. Must match `gpg_key_fingerprint` on the owner's user record at the time the field is set. |
| `sign_rpms` | boolean | Whether uploaded RPMs are automatically signed with the repo owner's GPG key (default `false`; requires `gpg_key_fingerprint` to be set) |
| `rpm_signing_state` | string | Server-managed RPM signing readiness state: `disabled`, `signing`, or `enabled` (default `disabled`) |
| `signing_transition_id` | UUID | FK to Signing Transitions; active repository RPM-signing transition while `rpm_signing_state = "signing"`, cleared when the transition completes or `sign_rpms` is disabled (default `null`) |
| `is_public` | boolean | Whether unauthenticated users can list, browse, and download from the repo (default `false`) |
| `metadata_revision` | bigint | Monotonic revision incremented whenever package membership, package metadata used in repodata, or metadata signing settings change (default `0`) |
| `package_count` | bigint | Transactionally maintained package count used to enforce `MAX_REPOSITORY_PACKAGES` (default `0`) |
| `primary_open_bytes` | bigint | Exact projected uncompressed byte size of the current `primary.xml`, maintained with package mutations (default is the empty-document size) |
| `filelists_open_bytes` | bigint | Exact projected uncompressed byte size of the current `filelists.xml`, maintained with package mutations (default is the empty-document size) |
| `other_open_bytes` | bigint | Exact projected uncompressed byte size of the current `other.xml`, maintained with package mutations (default is the empty-document size) |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

**Unique constraint**: `(slug)`

Repository creation is bounded by `MAX_USER_REPOSITORIES` (default 100; `0` disables the limit). The creation transaction locks the owning user row before claiming the slug reservation, counts the live repositories that user already owns, and rejects the request with `409 conflict_repository_quota_exceeded` when the new row would cross the limit. Admins are not exempt, matching how `MAX_USER_STORAGE_BYTES` applies to every owner. Only live repositories count, so deleting a repository frees a slot immediately even though its slug stays retired; the limit therefore bounds how many repositories and live slug reservations one account holds at once, while the 30/hour repository-creation rate limit remains the bound on create/delete churn.

### Slug Reservations

One table is the global authority for both live and retired repository slugs. This avoids the race that would exist if live repositories and retired slugs relied on independent unique constraints. When a repository is deleted, its reservation becomes retired rather than being released, so another user cannot recreate the URL and serve packages to clients whose `.repo` files still point at it.

| Field | Type | Description |
|---|---|---|
| `slug` | string | Primary key; normalized repository slug |
| `repository_id` | UUID | Deferrable FK to repositories, unique and nullable; set for a live reservation and null for a retired reservation |
| `user_id` | UUID | FK to users with `ON DELETE SET NULL`, nullable — current owner for a live reservation or deleting owner for a retired reservation; set to null if that former owner is deleted |
| `repository_name` | string | Repository display name, written at creation and refreshed to the final display name when the reservation is retired; retained for admin context on retired reservations (a live reservation's current name lives on the repository row) |
| `retired_at` | timestamp | Null for a live reservation; deletion time for a retired reservation |
| `inserted_at` | timestamp | Reservation creation time |
| `updated_at` | timestamp | Last state change |

**Unique constraint**: `(repository_id)` when non-null

A check constraint requires exactly one of the two states: a live row has both `repository_id` and `user_id` set with `retired_at = null`; a retired row has `repository_id = null` and `retired_at` set, while `user_id` may be null after account deletion. The `repository_id` FK is `DEFERRABLE INITIALLY DEFERRED`, allowing the reservation to be claimed before its repository row is inserted without exposing an invalid committed state.

Repository creation allocates the repository UUID, locks the owning user row for the repository-quota check described above, and then conditionally upserts the slug reservation: it inserts a new live row, or on primary-key conflict revives the row only when it is retired and its retained `user_id` matches the creator. The statement returns the claimed row; no returned row means the slug is live, belongs to another former owner, or has lost its former-owner identity, so the transaction returns `422 validation_failed` with `details.slug`. Only after a successful claim does the transaction insert the repository and its initial metadata cache. Repository deletion locks the live reservation, changes it to retired — refreshing `repository_name` to the repository's final display name — and then deletes the repository in one transaction. Admins can delete an individual retired reservation to release its slug for general reuse; live reservations cannot be released. Releases are recorded in the audit log.

### Packages

Each package record represents a single RPM file within a repository.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories |
| `rpm_format` | smallint | RPM package format version; exactly `4` or `6` |
| `name` | string | Package name (e.g., `nginx`); max 256 characters |
| `epoch` | bigint | RPM epoch in the unsigned 32-bit range (`0 ≤ epoch ≤ 4 294 967 295`); default `0` when the RPM has no epoch. A PostgreSQL `bigint` is required because `integer` cannot represent the upper half of this range. |
| `version` | string | Package version (e.g., `1.24.0`); max 256 characters |
| `release` | string | Package release (e.g., `2.fc39`); max 256 characters |
| `arch` | string | Architecture (`x86_64`, `noarch`, `aarch64`, etc.), or the literal `src` for source RPMs; max 256 characters |
| `summary` | string | Required one-line description (max 256 characters after trimming; no ASCII control characters) |
| `description` | text | Required full description (max 65 536 characters after trimming) |
| `url` | string | Optional upstream project URL (max 256 characters after trimming; must be an absolute `http` or `https` URL) |
| `license` | string | Required license identifier (max 256 characters after trimming) |
| `size_installed` | bigint | Installed size in bytes; `0 ≤ size_installed ≤ 9 223 372 036 854 775 807` |
| `size_package` | bigint | RPM file size in bytes; positive and no greater than `MAX_RPM_UPLOAD_BYTES` |
| `size_archive` | bigint | Uncompressed payload/archive size: optional v4 signature-header `LONGARCHIVESIZE`/`PAYLOADSIZE`, or required v6 main-header `PAYLOADSIZEALT`; null only for a v4 package that omits both applicable tags, otherwise `0 ≤ size_archive ≤ 9 223 372 036 854 775 807` |
| `sha256` | string | Lowercase hex-encoded SHA-256 checksum of the RPM file |
| `build_time` | timestamp | Optional RPM build time from the `BUILDTIME` header tag; null when the tag is absent |
| `rpm_sourcerpm` | string | Optional source RPM filename used in repodata; read from v4 `SOURCERPM` or derived from v6 `SOURCENEVR` (max 800 characters after trimming) |
| `rpm_sourcenevr` | string | Optional exact v6 source NEVR from `SOURCENEVR`; null for v4 and source packages (max 800 characters after trimming) |
| `rpm_group` | string | Optional RPM group (max 256 characters after trimming) |
| `rpm_vendor` | string | Optional RPM vendor from the `VENDOR` header tag (max 256 characters after trimming) |
| `rpm_buildhost` | string | Optional build host from the `BUILDHOST` header tag (max 256 characters after trimming) |
| `header_start` | bigint | Byte offset of the first byte of the main header within the RPM file; non-negative and less than `header_end` |
| `header_end` | bigint | Byte offset one past the last byte of the main header within the RPM file; no greater than `size_package` |
| `storage_path` | text | B2 object key where the RPM file is stored (maximum 1 024 UTF-8 bytes) |
| `storage_version_id` | text | Exact B2 object version ID returned by the successful upload (maximum 1 024 UTF-8 bytes, matching the completion endpoint's `version_id` cap); signed downloads and permanent deletion address this version explicitly |
| `requires` | jsonb | List of dependency requirements (default `[]`) |
| `provides` | jsonb | List of capabilities provided (default `[]`) |
| `conflicts` | jsonb | List of conflicts (default `[]`) |
| `obsoletes` | jsonb | List of obsoletes (default `[]`) |
| `recommends` | jsonb | List of weak recommends dependencies (default `[]`) |
| `suggests` | jsonb | List of weak suggests dependencies (default `[]`) |
| `supplements` | jsonb | List of reverse-weak supplements dependencies (default `[]`) |
| `enhances` | jsonb | List of reverse-weak enhances dependencies (default `[]`) |
| `files` | jsonb | List of files contained in the RPM (default `[]`) |
| `changelogs` | jsonb | Changelog entries (default `[]`) |
| `inserted_at` | timestamp | Upload time |
| `updated_at` | timestamp | Last modification time |

**Unique constraint**: `(repository_id, name, epoch, version, release, arch)`

Persisted packages require `rpm_format`, `name`, `epoch`, `version`, `release`, `arch`, `summary`, `description`, `license`, `size_installed`, `size_package`, `sha256`, `header_start`, `header_end`, `storage_path`, and `storage_version_id`; v6 rows additionally require non-null `size_archive`. Database check constraints enforce the static numeric ranges, v6 archive-size presence, and header-offset ordering stated above; application validation enforces the deployment-specific `MAX_RPM_UPLOAD_BYTES` ceiling. The `url`, `rpm_sourcerpm`, `rpm_sourcenevr`, `rpm_group`, `rpm_vendor`, and `rpm_buildhost` fields are nullable when absent or empty after trimming, `build_time` is nullable when the RPM omits the `BUILDTIME` tag, and `size_archive` is nullable only for v4 when both applicable signature tags are absent. `header_start` and `header_end` are always known because the parser has to locate the main header to read any metadata at all. Dependency, file, and changelog fields are stored as empty arrays when the RPM has no entries for that category.

### Storage Reservations

Short-lived reservations serialize hard per-owner storage-quota accounting across uploads and background re-signing without holding a database lock during object-storage I/O.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key and unguessable reservation identifier |
| `user_id` | UUID | FK to users whose quota is reserved |
| `repository_id` | UUID | FK to the target repository |
| `package_id` | UUID | Preallocated new package UUID for an upload, or existing package UUID for re-signing |
| `kind` | string | `upload` or `resign` |
| `reserved_bytes` | bigint | Positive bytes reserved: the upload's declared size until processing knows and reserves the exact final size, or the positive size delta for re-signing |
| `expires_at` | timestamp | Lease expiration; initially two hours and renewable while processing continues |
| `inserted_at` | timestamp | Reservation creation time |
| `updated_at` | timestamp | Last lease renewal |

**Unique constraint**: `(id)`

Reservation creation locks the owning user row, reclaims that user's expired reservations, and checks `users.storage_bytes + active reserved_bytes + requested_bytes` against `MAX_USER_STORAGE_BYTES`. When `MAX_USER_STORAGE_BYTES` is `0` the quota is disabled: reservations are still created, adjusted, and consumed so accounting and the admin reserved-bytes view stay accurate, but the ceiling check is skipped and never fails. Direct-upload intent creation reserves the one source version Dark Zenith is willing to accept before issuing a B2 URL; the quota governs accepted and permanent package storage, while replayed presigned writes are separately bounded by staging cleanup and the accepted risk described under Security Considerations. Once optional signing has produced the final size, the worker locks the user and atomically increases or decreases that same reservation to the exact final size; an increase is permitted only if quota remains. A successful package transaction consumes the reservation atomically; failure releases it.

A re-sign item owns at most one reservation through its unique `reservation_id`. After calculating the signed result, the worker locks the owner, repository, current package, transition/item, and linked reservation in the global order: a positive size delta creates and links a reservation if none exists, or adjusts and renews the existing linked row to the exact delta; a non-positive delta releases any linked row. A retry reuses that identity rather than stacking another quota claim. Pending and executing items renew linked reservations two hours ahead. A successful compare-and-swap consumes the reservation; any deterministic failure, exhausted retry, cancellation, or stale-source terminal outcome releases it. The hourly reservation cleanup removes an expired row only after confirming that no active upload intent or nonterminal signing item links it. Before consuming an expired reservation, a worker must reacquire the user lock and renew it subject to the quota; if capacity was used meanwhile, it removes any newly written final B2 version and records `conflict_storage_quota_exceeded`. Concurrency and fault-injection tests assert one active reservation per item and no leaked reservation on every terminal path.

Final mutation transactions use one lock order: owning user, repository, existing package, signing transition, transition item and repository-snapshot row, upload intent, storage reservation, then live slug reservation; absent row classes are skipped, and bulk operations lock rows within each class by UUID ascending. A transition or upload worker's short initial claim transaction may lock only its own durable item/snapshot row because it releases that lock before external I/O, but its final compare-and-swap transaction follows the global order. This order also applies to deletion and key-transition phase commits, preventing the quota, deletion, upload, re-sign, and slug-retirement paths from deadlocking one another.

### Signing Transitions

Signing-transition progress is application data and never inferred from the continued presence of Oban job rows.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key; the transition ID stored on the repository or user |
| `kind` | string | `enable_rpm_signing`, `replace_gpg_key`, `clear_metadata_signing`, or `delete_signed_packages` |
| `user_id` | UUID | FK to users with `ON DELETE SET NULL`, nullable — the repository owner or key owner; cleared if that account is later deleted so transition rows can be retained for audit |
| `repository_id` | UUID | Repository UUID snapshot (no FK constraint) for `enable_rpm_signing`, deliberately retained if the repository is later deleted; null for user-wide transitions |
| `target_fingerprint` | string | Exact signing-key fingerprint every re-sign item must use; required for enabling/replacement and null for both removal kinds |
| `prepared_gpg_key_private` | binary | Nullable encrypted candidate private key held before a replacement's key-swap commit |
| `prepared_gpg_key_public` | text | Nullable candidate public key held before a replacement's key-swap commit |
| `prepared_primary_fingerprint` | string | Nullable candidate V4 primary fingerprint held before a replacement's key-swap commit |
| `prepared_signing_fingerprint` | string | Nullable exact candidate signing fingerprint held before a replacement's key-swap commit |
| `prepared_expires_at` | timestamp | Nullable effective candidate expiry held before a replacement's key-swap commit |
| `repositories_prepared_through` | UUID | Nullable UUID cursor for durable repository-snapshot preparation |
| `packages_prepared_through` | UUID | Nullable UUID cursor for durable package-item preparation |
| `repositories_preparation_complete` | boolean | Durable end-of-scan marker for repository preparation (default `false`; left `false` and unused by repository-local `enable_rpm_signing` transitions) |
| `packages_preparation_complete` | boolean | Durable end-of-scan marker for package preparation (default `false`; left `false` and unused by repository-local `enable_rpm_signing` transitions) |
| `phase_attempts` | integer | Consecutive transient failures for the current preparation/activation/finalization batch since the last completed batch or admin reset (default `0`) |
| `phase_next_attempt_at` | timestamp | Earliest time the next phase batch may run; null while active item work, failed, or terminal |
| `last_error_code` | string | Nullable sanitized phase/item summary error for admin diagnosis |
| `status` | string | `preparing`, `activating`, `active`, `finalizing`, `failed`, `completed`, or `canceled` |
| `resume_status` | string | Nullable phase (`preparing`, `activating`, `active`, or `finalizing`) to restore when an exhausted/failed transition is administratively reset; required only while `status = "failed"` |
| `inserted_at` | timestamp | Transition creation time |
| `updated_at` | timestamp | Last state change |
| `completed_at` | timestamp | Completion/cancellation time; null in every nonterminal phase and while failed |

An all-or-none check requires the prepared private key, public key, primary fingerprint, and signing fingerprint before a replacement's key-swap commit (`preparing`, or `failed` with `resume_status = "preparing"`) and requires them all null in every other phase/kind; `prepared_expires_at` may also be null for a non-expiring candidate but must be null outside those pre-swap states. They are cleared atomically at the key-swap commit or on cancellation. Preparation cursors remain through preparing and are cleared once both complete flags prove the snapshot finished; the flags distinguish an empty completed scan from a scan that has not started. A user-wide transition is attached through `users.gpg_key_transition_id`; at most one unresolved preparing, activating, active, finalizing, or failed user-wide transition exists for a user. Large user-wide transitions are never constructed or applied in one transaction: phase workers process UUID-ordered batches of `SIGNING_PREPARATION_BATCH_SIZE`, use unique upserts, and advance cursors/apply rows while resetting `phase_attempts` in the same transaction. A scan sets its complete flag in the transaction that observes no row after its cursor. A transient batch failure increments `phase_attempts` and writes `phase_next_attempt_at` under Background Retry Policy; the twentieth changes the transition to `failed` with `resume_status` recording that phase. An admin reset restores it with a fresh attempt budget. Explicit cancellation atomically nulls any encrypted candidate fields.

Database checks require `phase_next_attempt_at` for scheduled `preparing`, `activating`, and `finalizing` phases and null it during active item work, failure, and terminal states; `failed` requires both `resume_status` and `last_error_code`; terminal states require `completed_at` and clear resume/scheduling state. Repository-local enable transitions begin directly in `active` and never use preparation fields or repository snapshots.

A partial unique index on `user_id` for user-wide kinds in every unresolved status enforces the one-transition rule; application locking is not the only defense against concurrent replacement/removal requests.

### Signing Transition Repositories

This durable snapshot includes metadata-only and empty repositories, which cannot be inferred from package items.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `transition_id` | UUID | FK to Signing Transitions |
| `repository_id` | UUID | Immutable repository UUID snapshot with no FK; retained after repository deletion |
| `application_status` | string | Durable per-repository phase result: `pending` (default), `applied`, or `satisfied_deleted` |
| `applied_at` | timestamp | Time the transition's repository-setting change committed, or deletion was recorded as satisfying it; null while pending |
| `inserted_at` | timestamp | Snapshot time |

**Unique constraint**: `(transition_id, repository_id)`

A check constraint requires null `applied_at` only for `pending` and a non-null value for both completed outcomes.

For key replacement, preparation snapshots every owned repository whose metadata is signed and creates items for every current package in an RPM-signed owned repository. Metadata-only removal snapshots every repository using the key; signed-package deletion does the same and creates an item for every current package in each RPM-signed repository. Repository-application workers claim pending snapshot rows in UUID-ordered batches, lock each live repository through the global order, commit its fingerprint/settings/revision change and row outcome together, and treat an already-deleted repository as `satisfied_deleted`. Thus activation and removal finalization are bounded and resumable as well as preparation.

During `preparing` and replacement `activating` (or a failed phase that resumes either), repository creation/deletion, package creation/deletion, and signing-setting changes for that owner return `409 conflict_gpg_key_transition_in_progress`; reads and downloads remain available. Both removal kinds continue blocking new repository/package creation and signing-setting changes through finalization and any failed removal phase, but after preparation they allow explicit package/repository deletion, which satisfies/cancels the corresponding durable rows and can only reduce the affected state. Replacement active allows ordinary mutations because new packages use the new key. Reaching the end of both preparation scans under the initial bounded write pause proves the snapshot complete without a monolithic transaction.

The owner-level transition is also a commit fence for work that was already in flight. New upload-intent creation is rejected during a blocking phase; completion, refresh, cancellation, and web-preview confirmation for an existing intent remain available, but its package worker is left queued until the phase admits package creation. A claim that observes the block does no external work and moves `next_attempt_at` one minute ahead; a worker that raced and reaches its final transaction deletes any candidate, relinquishes its lease, returns to queued on that same schedule, and restores its pre-claim attempt value so the pause consumes none of the 20-failure budget. The phase-change transaction also schedules deferred uploads immediately, avoiding a full-minute tail. Repository-local re-sign workers make the same final check. Replacement cannot start while such an enable transition exists; a removal transition fences it immediately, and each repository finalization batch cancels its parent transition before disabling signing, so unfinished child jobs no-op without requiring an unbounded child-row update. Sweepers reconstruct missing deferred jobs and clean up those child states in bounded batches.

### Signing Transition Items

One row represents the durable outcome required for one package in a signing transition.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key; Oban jobs carry this ID |
| `transition_id` | UUID | FK to Signing Transitions |
| `repository_id` | UUID | Repository UUID snapshot (no FK constraint) of the repository containing the package when the item was created; deliberately retained if the repository is later deleted |
| `package_id` | UUID | Immutable package-ID snapshot; deliberately retained if the package is later deleted |
| `expected_storage_path` | text | Package storage path the item is allowed to replace or delete |
| `expected_storage_version_id` | text | Exact immutable B2 source version the item must download for re-signing or enqueue for deletion |
| `reservation_id` | UUID | Nullable unique FK to the item's active Storage Reservation; retained across retries and cleared on every terminal outcome |
| `status` | string | `pending`, `executing`, `succeeded`, `failed`, or `canceled` |
| `attempts` | integer | Persistent attempt count, incremented when a worker claims the item |
| `next_attempt_at` | timestamp | Earliest time a pending item may be claimed; null while executing or terminal |
| `lease_token` | UUID | Random fencing token for the current claim; null outside `executing` |
| `lease_expires_at` | timestamp | Renewable execution lease; null outside `executing` |
| `last_error_code` | string | Latest sanitized attempt error, retained while pending for diagnosis and cleared on success/admin reset |
| `inserted_at` | timestamp | Item creation time |
| `updated_at` | timestamp | Last state change |
| `completed_at` | timestamp | Success/failure/cancellation time; null while pending or executing |

**Unique constraints**: `(transition_id, package_id)`, `(reservation_id)` when non-null

Database checks make claim state unambiguous: `pending` requires non-null `next_attempt_at` and null lease/completion fields; `executing` requires both lease fields and null `next_attempt_at`/`completed_at`; every terminal state requires `completed_at`, a null reservation, and null scheduling/lease fields; and `failed` additionally requires `last_error_code`. Initial items are `pending` with `attempts = 0` and `next_attempt_at = inserted_at`.

A worker transaction locks and claims a pending item whose `next_attempt_at` is due and whose parent transition is `active` or is `failed` with `resume_status = "active"`, increments `attempts`, clears `next_attempt_at`, assigns a fresh `lease_token`, and sets a 15-minute lease before doing external I/O; it renews that lease every five minutes with `WHERE lease_token = <claim token>`. An active-phase `failed` transition means at least one sibling needs intervention, not that otherwise-pending work is frozen. Duplicate jobs no-op when the item is already succeeded or canceled, not yet due, or the parent is in another phase or terminal. A 60-second sweep clears the token on an expired `executing` lease, returns the item to `pending`, calculates its retry time, and ensures a scheduled job exists. Every state-changing query and the final package compare-and-swap include the claim's `lease_token`, so a paused worker cannot commit after a replacement worker has claimed the item.

For `enable_rpm_signing` and `replace_gpg_key`, each claim is a clean native-tool attempt: it creates a new mode-`0700` working directory named from the item ID and lease token, downloads `expected_storage_path` at `expected_storage_version_id`, revalidates the immutable source, and never resumes or trusts a partial local file from an earlier claim. It signs only a local working copy and writes any candidate result to a fresh final object key. Normal exits remove the attempt directory in an `after`/cleanup path. An hourly janitor removes app-owned attempt directories older than one hour only when their encoded token is not a current unexpired lease; it never follows symlinks or removes paths outside `RPM_UPLOAD_TMPDIR`. A process exit, node restart, lost lease, partial `rpmsign` output, or transient tool, database, or B2 error therefore leaves the source unchanged; after lease expiry, a new claim starts from the exact source version. A candidate B2 version uploaded before a crash or lost final compare-and-swap is unreferenced and is removed by immediate best-effort cleanup or the orphan reconciler. A successful database commit enqueues deletion of the old exact version in the same transaction, so a crash after commit can delay cleanup but cannot cause the signing work to be repeated or rolled back.

A `delete_signed_packages` item performs no download, temporary-space lease, or RPM/GPG operation. Its fenced transaction locks the owner, live repository/package, transition/item, and any reservation in the global order; requires the package still to match the snapshotted path/version; applies the standard package/storage/metadata-counter deletion; marks the item succeeded; and enqueues exact-version object cleanup plus metadata regeneration atomically. A missing package or repository marks the item canceled; repository deletion separately marks its snapshot row satisfied. Database unavailability is retryable, and a crash after commit can delay cleanup but cannot restore or delete the package twice.

Every `rpmkeys`, `rpmsign`, and `gpg` child runs in its own process group with a hard `RPM_TOOL_TIMEOUT_SECONDS` deadline (default 1 800 seconds). The worker continues renewing its lease while awaiting the child. If renewal updates zero rows because the token was canceled or superseded, or when the deadline arrives, it sends `TERM` to the group, waits 10 seconds, sends `KILL` if needed, and discards the attempt directory. A timeout records a transient tool-unavailable error so the normal durable retry schedule applies; a lost lease records nothing because its replacement state is already authoritative. A hung or superseded native tool therefore cannot keep an item executing forever.

Deterministic contract failures—invalid package integrity, expired key, metadata limit, or storage quota—make the item and transition `failed` immediately with their stable error code and `resume_status = "active"`. Transient tool, database, interruption, or B2 failures return the item to `pending` under Background Retry Policy until the twentieth failed claim makes it terminally `failed` and records the same transition resume phase. `next_attempt_at` is written in the same transaction that relinquishes or reclaims the lease, and the sweep repairs a missing Oban row. Oban job uniqueness is only an efficiency measure, and duplicate delivery remains safe because durable item state and lease fencing are authoritative. Admin replay explicitly resets selected failed items to `pending`, `attempts = 0`, and `next_attempt_at = now()` with a fresh attempt budget; the audit event retains the prior attempt count. Normal package deletion marks every item for that package that is not already `succeeded` or `canceled` — pending, executing, or failed — `canceled` in the deletion transaction, and repository deletion likewise cancels the repository's active or failed transitions and its items under the same rule in its own deletion transaction (see Package Upload & Processing); a worker that races with an already-committed deletion also locks the item and marks it canceled as a no-op. Every success, deterministic failure, exhaustion, cancellation, package deletion, repository deletion, and transition cancellation releases any linked reservation and clears `reservation_id` in the same transaction. Transition rows and items are retained for audit and troubleshooting even if Oban prunes its own terminal rows.

Fault-injection tests terminate a re-sign worker after source download, during `rpmsign`, after candidate upload but before the database transaction, after lease expiry while a replacement worker runs, and after database commit but before cleanup. They assert that the next claim starts from `expected_storage_version_id`, only one fenced compare-and-swap can succeed, the committed package verifies with the target key, `attempts`/`next_attempt_at` follow the formula, old and candidate orphan versions are eventually deleted, and an already-successful item is never signed again. Delete-item tests crash before and after its database commit and prove exactly one counter mutation with eventual exact-version cleanup.

### Upload Intents

Upload intents are the durable authority for browser and API uploads. The client-facing transfer goes directly to a private B2 staging object; the app stores only control state, and workers can always reconstruct an interrupted attempt by downloading the recorded exact staging version again.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key and unguessable client-visible upload identifier |
| `repository_id` | UUID | FK to the target repository |
| `user_id` | UUID | FK to the owner/admin who initiated the upload |
| `package_id` | UUID | Preallocated UUID used for the eventual package row and final storage-key namespace |
| `reservation_id` | UUID | Nullable FK to the upload's active Storage Reservation; unique while non-null and cleared when the reservation is consumed or released |
| `mode` | string | `api` for automatically queued final processing after transfer, or `web_preview` for preview-and-confirm |
| `status` | string | `awaiting_upload`, `queued`, `processing`, `preview_ready`, `succeeded`, `failed`, `expired`, or `canceled` |
| `original_filename` | string | Client-supplied filename for display, reduced to its final path component; valid UTF-8 with no control characters, non-empty after trimming, and at most 255 characters |
| `declared_size` | bigint | Client-declared source bytes; positive and no greater than `MAX_RPM_UPLOAD_BYTES` |
| `upload_generation` | integer | Starts at `1` and increments whenever an expired direct-transfer URL is refreshed |
| `staging_path` | text | Current server-generated B2 key under `staging/uploads/`; never derived from the filename and unique among current intent rows |
| `upload_url_expires_at` | timestamp | Expiration of the current presigned `PutObject` URL; null after leaving `awaiting_upload` |
| `staging_version_id` | text | Exact B2 version accepted by completion (maximum 1 024 UTF-8 bytes, matching the completion endpoint's `version_id` cap); null until the transfer is completed |
| `preview_metadata` | jsonb | Extracted `rpm_format`, NEVRA, summary/description/URL/license, source/group/vendor/buildhost fields, installed/archive/build values, and full dependency/file/changelog entry arrays using the documented nested-entry shapes; null until `preview_ready` and always null for `api` mode |
| `attempts` | integer | Persistent processing-attempt count, incremented on each worker claim |
| `next_attempt_at` | timestamp | Earliest time a queued intent may be claimed; null while processing, waiting for upload/confirmation, or terminal |
| `lease_token` | UUID | Random fencing token for the current processing claim; null outside `processing` |
| `lease_expires_at` | timestamp | Renewable 15-minute processing lease; null outside `processing` |
| `last_error_code` | string | Latest sanitized processing error, retained while queued for diagnosis and cleared on success/new web-confirm phase |
| `expires_at` | timestamp | Expiration used only in `awaiting_upload` and `preview_ready`; initially two hours, reset to 15 minutes when a web preview becomes ready, and null in all other states |
| `completed_at` | timestamp | Terminal completion time; null while active |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last state change |

**Unique constraints**: `(reservation_id)` when non-null, `(staging_path)`, `(package_id)`

Database checks enforce the state machine. `awaiting_upload` requires the reservation, both waiting expirations, and a null staging version/lease/schedule; `queued` requires the reservation, accepted version, and `next_attempt_at`, with null lease/completion fields; `processing` requires the reservation, accepted version, and both lease fields, with null `next_attempt_at`/`completed_at`; `preview_ready` requires the reservation, accepted version, `mode = "web_preview"`, `preview_metadata`, its confirmation expiry, and null scheduling/lease fields; `succeeded` requires a null reservation, `completed_at`, and no scheduling/lease fields; and `failed`, `expired`, or `canceled` require the same, with `failed` also requiring `last_error_code`. API-mode rows may never enter `preview_ready`. All other field/state combinations are rejected.

Creating an intent authenticates and authorizes the uploader, validates the filename and declared size, preallocates `package_id`, and creates a reservation for `declared_size` while holding the repository owner's quota lock. It generates a random staging key containing at least 128 bits of server entropy and returns the current generation plus a presigned B2 `PutObject` URL, valid for at most one hour and never past the intent's two-hour `expires_at`, bound to that exact key, the `PUT` method, `Content-Type: application/x-rpm`, and `Content-Length: <declared_size>` through SigV4 signed headers. A browser sends a `File`/`Blob` body of that known size and lets the user agent set the forbidden `Content-Length` header; non-browser clients set it explicitly. A missing or different signed header makes B2 reject the request, limiting each replay to the reserved size. The application key and arbitrary bucket operations are never delegated. A URL may be refreshed only while the intent is `awaiting_upload`, its current `upload_url_expires_at` has passed, and at least 60 seconds remain before the intent expires; before URL expiry, an interrupted transfer restarts from byte zero with the existing URL. Refresh atomically increments `upload_generation`, replaces the staging key with a fresh random key, caps the new URL at the unchanged intent expiry, and schedules every version at the abandoned key for cleanup. Completion supplies both that generation and the B2 response's `x-amz-version-id`.

Dark Zenith performs `HeadObject` against the generation's exact key and version and independently requires its byte length to equal `declared_size` and its content type to be exactly `application/x-rpm`. It also requires empty/absent `Content-Encoding`, `Content-Disposition`, `Content-Language`, `Cache-Control`, `Expires`, and website-redirect location, plus a user-metadata map with zero keys (even an empty-valued `x-amz-meta-*` key is rejected). A mismatch returns `422 validation_failed`, permanently deletes that exact version, and leaves the intent awaiting a clean upload. On success it atomically stores the version, clears `upload_url_expires_at` and the waiting `expires_at`, sets `status = "queued"` and `next_attempt_at = now()`, and enqueues processing. It never trusts an ETag as an integrity digest.

Completion is idempotent for the already accepted generation and version while the intent remains `queued`, `processing`, `preview_ready`, `succeeded`, or `failed`; a canceled or expired intent returns `409 conflict_upload_state` even for that version. A new completion requires an unexpired `awaiting_upload` intent; an overdue row is atomically expired and cleaned instead. A different version, a stale upload generation, or completion after refresh returns `409 conflict_upload_state`; a nonexistent version or any length/content-type/metadata-contract mismatch returns `422 validation_failed`, permanently deletes that exact version when it exists, and leaves the intent awaiting another `PUT` on the current URL or a refresh after that URL expires. Reusing a presigned URL can create extra B2 versions, but only the version accepted by the compare-and-swap can be processed; the staging orphan reconciler removes every other version.

Processing uses the same 15-minute lease, five-minute renewal, random fencing token, clean-attempt workspace, Background Retry Policy, and 20-attempt transient budget as Signing Transition Items. The worker streams the exact staging version to a new local file, validates the measured byte count against `declared_size` and computes the SHA-256 while downloading, and no-ops unless its token still owns the lease. An expired `processing` lease is requeued by the 60-second sweep. The sweep and active worker also renew the associated storage reservation two hours ahead while an intent is queued or processing, preserving its quota claim during infrastructure downtime. Deterministic validation and conflict outcomes fail immediately; infrastructure errors and process interruption requeue durably. For web mode, the first successful processing pass stores `preview_metadata`, changes the status to `preview_ready`, sets both the intent and reservation to expire in 15 minutes, and retains the immutable staging object. Confirmation reauthorizes the same user, changes `preview_ready` back to `queued`, sets `attempts = 0` and `next_attempt_at = now()`, clears `last_error_code` for a fresh final-processing retry budget, renews the reservation two hours ahead, and runs a new processing attempt from B2; no node-local preview file is durable state. API mode proceeds directly to final storage.

On success, the package transaction marks the intent `succeeded` and enqueues staging cleanup atomically. A crash after that commit can delay deletion but cannot repeat the package insert. Cleanup permanently deletes the accepted exact version and lists/deletes every sibling version at that exact random staging key; for an `awaiting_upload` intent with no accepted version, it lists and deletes every version at the key. It never issues an unversioned delete. Terminal failure, cancellation, or expiration releases the reservation and enqueues the same key-scoped version-aware cleanup; terminal intent rows remain for 24 hours so clients can read the outcome, then an hourly cleanup job deletes them. Waiting-state cleanup runs every 15 minutes and expires only overdue `awaiting_upload` or `preview_ready` rows; accepted `queued`/`processing` work remains governed by its durable retry budget rather than a wall-clock upload deadline. Repository or initiating-user deletion first records the same staging keys and known versions, then deletes the intent rows in the same transaction — fencing any active worker through the removed durable state — and enqueues cleanup after that transaction commits.

Upload integration and fault-injection tests cover current supported browsers performing a CORS `PUT` with signed content length, rejection of a different length/content type and each forbidden metadata/header class, URL refresh/completion races, a reused presigned URL that creates multiple same-sized versions, a client disconnect after completion, web confirmation after an app restart, and the same worker interruption points as signing transitions. They assert exact-version selection, reservation retention across transient attempts, deterministic terminal cleanup, metadata equality on confirmation, one package insert, sanitized final-object metadata, and eventual deletion of every unreferenced staging/final version.

### API Keys

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `user_id` | UUID | FK to users — the owner of this key |
| `name` | string | Human-readable label (required, max 100 characters after trimming) |
| `key_hash` | string | HMAC-SHA-256 hash of the full API key string, including the `dzak_` prefix |
| `key_prefix` | string | First 12 characters of the full API key (e.g., `dzak_abcdefg`) for identification |
| `scopes` | jsonb | Allowed operations (see Scopes below) |
| `expires_at` | timestamp | Optional expiration |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

**Unique constraint**: `(key_hash)`

**API Key Scopes**: Scopes control which operations an API key can perform. Mutating scopes operate on repositories owned by the key's user. The `repo:read` scope grants read access based on the user's identity (owner, collaborator, or admin). Valid scopes:

| Scope | Permits |
|---|---|
| `repo:read` | Read access to private repositories the user can access (as owner, collaborator, or admin), including listing collaborators and pending invitations for a repository the user owns or administers |
| `repo:create` | Create new repositories |
| `repo:update` | Update repository settings, and add or remove collaborators and pending invitations on the user's own repositories (or any repository, for admins) |
| `repo:delete` | Delete repositories |
| `package:upload` | Upload RPM packages |
| `package:delete` | Delete packages from repositories |

Users can create multiple API keys with different scopes and names (e.g., a `repo:read`-only key for CI pulls, a scoped key for uploads). API key creation requires at least one valid scope. Scope input must be an array of strings; unknown or empty values are rejected, duplicates are collapsed, and the result is stored and returned in lexicographic order. This canonical array is used for equality and audit comparisons. Validation tests cover non-string members, unknown/empty input, duplicate collapse, every input permutation, and stable response order. Admin users' API keys operate on all repos, not just their own (e.g., an admin key with `package:upload` can upload to any repo).

**Note**: Public repositories do not require `repo:read` — they are accessible without authentication. However, authenticated requests to public repos (using any non-expired API key with at least one valid scope) benefit from higher rate limits (see Rate Limiting).

**API Key Format and lifecycle**: API keys are generated from 32 bytes of cryptographically secure random data, encoded as unpadded base64url, and returned to the caller as `dzak_<secret>`. The plaintext key is shown only once at creation. The database stores `key_prefix` for display and `key_hash`, computed as `HMAC-SHA-256(SECRET_KEY_BASE, full_key_string)` and encoded as lowercase hex, where `full_key_string` is the complete returned value including the `dzak_` prefix. Expired keys remain listed with `is_expired = true` but are rejected as invalid credentials with `401 unauthenticated` before any scope-based authorization check (surfaced as `404 not_found` on requests where the private-repository masking rule in API Contract Details applies). They are not automatically deleted: users explicitly delete them, and the password-reset page's "active" list means unexpired keys only.

API key creation is bounded by `MAX_USER_API_KEYS` (default 100). Every stored key row counts, including expired rows, until it is deleted. Creation and deletion lock the same user row; creation then counts the user's keys and returns `409 conflict_api_key_quota_exceeded` if the new row would exceed the limit, so concurrent creates/deletes serialize. Admins are not exempt. Lowering the configured limit below an existing count does not refuse boot or prevent listing/deletion, but blocks further creation until enough rows are removed. Creation also consumes the specialized 30-per-hour per-user rate-limit bucket in addition to the general bucket.

Quota tests race simultaneous creates at the last slot, count expired rows, cover admin accounts and a lowered limit, and prove that deletion immediately restores capacity. Rate-limit tests cover REST and LiveView entry points and verify that rejected validation/quota attempts still consume specialized slots.

### Repository Collaborators

Repo owners and admins can grant other users read access to private repositories. When the invited email address, after normalization, matches an already registered user, a collaborator record is created immediately. When the normalized email does not match a registered user, a pending invitation is created instead and converts to a collaborator record when a matching user account is created. The invited user receives an email notification: registered users get a direct link to the repository, and unregistered invitees get a registration link that converts the pending invitation on signup. New deliverable invitations start with `notification_status = "queued"`; successful provider delivery changes it to `sent`, while an exhausted delivery changes it to `failed`. When `REGISTRATION_ENABLED = false`, pending invitations to unregistered addresses are still created so they convert automatically once an admin provisions the account, but no email is queued and `notification_status` is `suppressed`. The inviting user is shown a UI notice indicating that an admin must create the account before the invitation can be accepted, and API clients read the same fact from `notification_status`.

An idempotent add request does not duplicate an already queued or sent notification. It queues a new delivery generation when the existing unexpired invitation is `failed`, or when it is `suppressed` and registration has since been enabled; it remains suppressed while the address is unregistered and registration is disabled. Refreshing an expired-but-uncleaned invitation always increments its delivery generation and either queues or suppresses the replacement notification under the same rule.

Combined membership per repository is bounded by `MAX_REPOSITORY_COLLABORATORS` (default 1 000; `0` disables the limit). An add request that would create a new collaborator or invitation row locks the repository row, counts the repository's stored collaborator rows plus pending invitations — expired-but-uncleaned invitations included, since they occupy their slot until conversion or cleanup deletes them — and is rejected with `409 conflict_collaborator_quota_exceeded` when the new row would cross the limit, so concurrent adds serialize. Idempotent returns of existing rows, expiry refreshes, removals, and cancellations are never quota-checked, and invitation conversion is exempt because it deletes the invitation row it replaces. Admins are not exempt. Lowering the configured limit below an existing count blocks further additions without preventing listing, removal, cancellation, or conversion. Quota tests race simultaneous adds at the last slot, count expired-but-uncleaned invitations, prove refresh and conversion remain available at the limit, and cover admin actors and a lowered limit.

Collaborator and invitation rows are retained when a repository is made public: they have no effect while `is_public = true` and become effective again if the repository returns to private. Owners and admins can remove collaborators and cancel invitations regardless of repository visibility; only adding is restricted to private repositories.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories |
| `user_id` | UUID | FK to users — the collaborator being granted access |
| `notification_status` | string | Direct repository-link delivery state: `queued`, `sent`, or `failed` |
| `notification_generation` | bigint | Monotonic delivery generation included in the unique mail-job args (starts at `1`) |
| `notification_sent_at` | timestamp | Provider-success time for the current generation; null unless `notification_status = "sent"` |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last notification state change |

**Unique constraint**: `(repository_id, user_id)`

Database checks require a positive generation; `sent` requires `notification_sent_at`, while `queued` and `failed` require it to be null. Collaborators are registered users, so this table has no `suppressed` state.

### Collaborator Invitations

Pending invitations for email addresses that do not yet belong to a user account.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories |
| `email` | string | Normalized lowercase email address of the invited user (max 160 characters after trimming) |
| `invited_by_id` | UUID | FK to users — the user who sent the invitation |
| `expires_at` | timestamp | Expiration time (`INVITATION_EXPIRY_DAYS` after creation or the most recent expiry refresh; null when expiry is disabled) |
| `notification_status` | string | `suppressed`, `queued`, `sent`, or `failed` |
| `notification_generation` | bigint | Monotonic delivery generation included in the unique mail-job args (default `0`) |
| `notification_sent_at` | timestamp | Provider-success time for the current generation; null unless `notification_status = "sent"` |
| `inserted_at` | timestamp | Invitation time |
| `updated_at` | timestamp | Last state change (expiry refresh, notification generation, or delivery outcome) |

**Unique constraint**: `(repository_id, email)`

When a user account is created with a normalized email that has pending invitations, whether by public registration or admin provisioning, those invitations are automatically converted to collaborator records and the invitation rows are deleted. The same conversion runs when an existing user confirms an account email change to a normalized email that has pending invitations (see User Lifecycle). Conversion guards the two collisions only the email-change path can create: an invitation on a repository where the user already holds a collaborator row is deleted without modifying the existing row or queuing any notification, and an invitation on a repository the user owns is deleted without creating a collaborator record, mirroring the rule that rejects inviting the owner's email. If an invitation's current notification was already `sent`, conversion carries its status, generation, and sent time to the collaborator and queues no duplicate direct-link message. A `queued`, `failed`, or `suppressed` invitation becomes a queued collaborator notification with generation `invitation.notification_generation + 1` and a null sent time; deleting the invitation fences its stale mail job. Conversion and the new collaborator mail job insert are atomic. Invitations expire `INVITATION_EXPIRY_DAYS` days after creation or their most recent explicit expiry refresh (default 30; `0` disables expiry and stores `expires_at` as null), bounding how long a stale invitation to an unregistered address remains a standing access grant. Expired invitations are never converted: conversion skips and deletes them, and a periodic cleanup job that runs hourly deletes expired invitation rows. User and collaborator-invitation email addresses use the same validation rules as `phx.gen.auth`: values are trimmed, lowercased, capped at 160 characters after trimming, and rejected with `422 validation_failed` when they fail the email format rules.

Queuing a delivery always increments `notification_generation`, so a deliverable invitation's first queued delivery is generation `1`; a suppressed invitation remains at the default `0` until its first delivery generation is queued or an expiry refresh increments the generation while leaving the replacement notification suppressed. Invitation mail jobs are unique on `(invitation_id, notification_generation)` and use Background Retry Policy. Before sending, a worker reloads the row and no-ops unless both the generation and `queued` status still match. Provider success atomically changes the row to `sent` and records `notification_sent_at`; a retryable failure leaves it queued, and the twentieth failure changes it to `failed` before the Oban job is discarded. A later explicit re-attempt increments `notification_generation`, clears `notification_sent_at`, and queues a new unique job, so a delayed worker from an older generation can never overwrite newer state. Delivery is necessarily at-least-once across the external provider and PostgreSQL: a process crash after provider acceptance but before the `sent` update may deliver the same generation twice. The message and audit metadata carry the stable invitation ID and generation for diagnosis, but the design never claims exactly-once email.

Direct collaborator mail uses the same state machine and Background Retry Policy, with jobs unique on `(collaborator_id, notification_generation)`. A direct add starts queued at generation `1`, and its collaborator row plus mail job are inserted in the same transaction. Idempotently re-adding a collaborator with a queued or sent notification queues nothing; re-adding one whose delivery is failed increments the generation, clears the sent time, and queues a fresh job. Workers reload and fence on both generation and queued status before delivery. Conversion, direct-add, provider-success, and exhausted-delivery tests cover every state and delayed stale jobs.

### Session Tokens

Short-lived bearer tokens issued by the login endpoint for interactive/CLI use.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `user_id` | UUID | FK to users |
| `token_hash` | string | HMAC-SHA-256 hash of the full token value |
| `expires_at` | timestamp | Expiration time (24 hours after creation) |
| `inserted_at` | timestamp | Creation time |

**Unique constraint**: `(token_hash)`

Session tokens are generated from 32 bytes of cryptographically secure random data, encoded as unpadded base64url, and returned as `dzst_<secret>`. The database stores only `HMAC-SHA-256(SECRET_KEY_BASE, full_token_string)` encoded as lowercase hex, where `full_token_string` is the complete returned value including the `dzst_` prefix. Session tokens do not have scopes; they authorize API requests as the logged-in user and still require the same owner/admin checks as web sessions.

When a user's password is changed or reset, all of that user's session tokens are deleted in the same operation (matching `phx.gen.auth`, which likewise invalidates the user's web sessions). API keys are unaffected by password changes. Because API keys deliberately survive password changes, the password reset completion page lists the account's active API keys with a one-click option to revoke them all, and every password change or reset triggers a security-notification email (see Email Delivery), so keys created during an account compromise are visible during recovery.

Expired tokens are cleaned up by a background job that runs hourly.

### Repository Metadata Cache

Stores the pre-generated repodata XML blobs so they can be served without regeneration on every request.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories (unique — one cache entry per repo) |
| `primary_xml_gz` | binary | Compressed `primary.xml.gz` blob |
| `filelists_xml_gz` | binary | Compressed `filelists.xml.gz` blob |
| `other_xml_gz` | binary | Compressed `other.xml.gz` blob |
| `repomd_xml` | text | Generated `repomd.xml` content |
| `repomd_xml_asc` | text | GPG signature of `repomd.xml` (null if unsigned) |
| `source_revision` | bigint | Repository metadata revision used to generate this cache entry |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last regeneration time |

**Unique constraint**: `(repository_id)`

### Users

Built on `phx.gen.auth` (bcrypt-based session authentication). Passwords follow the `phx.gen.auth` defaults: minimum 12 characters and maximum 72 bytes, enforced on registration, admin-created accounts, password change, and password reset.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `email` | string | Unique normalized lowercase email address (max 160 characters after trimming) |
| `hashed_password` | string | Bcrypt password hash |
| `is_admin` | boolean | Admin flag — admins can manage all repos and users (default `false`) |
| `storage_bytes` | bigint | Transactionally maintained sum of `size_package` for packages in repositories this user owns (default `0`) |
| `gpg_key_private` | binary | Optional GPG private key, encrypted at rest using the versioned GPG private key encryption envelope |
| `gpg_key_public` | text | Optional ASCII-armored GPG public key (served at `/repos/:slug/RPM-GPG-KEY`); null when the user has no GPG key |
| `gpg_key_fingerprint` | string | Optional 40-character uppercase hex OpenPGP V4 primary-key fingerprint of the stored GPG key (for display/identification); null when the user has no GPG key. The encrypted/private key, public key, primary fingerprint, exact signing fingerprint, expiry, and reminder state are always written or cleared together. |
| `gpg_signing_fingerprint` | string | Optional 40-character uppercase fingerprint of the exact V4 signing key or subkey forced for signatures; null when no key is configured |
| `gpg_key_expires_at` | timestamp | Effective signing expiry — the earlier expiration of the primary key and selected signing key/subkey (see GPG Signing); null when neither expires |
| `gpg_key_expiry_notified_days` | jsonb | Set of reminder thresholds already delivered for the current key (`30`, `7`, `1`), reset on upload/replacement (default `[]`) |
| `previous_gpg_key_public` | text | Optional ASCII-armored previous public GPG key, retained while a GPG key replacement is mid-transition so clients can still verify signatures made with the previous key; cleared after affected metadata caches have reached the current revision and every per-package re-sign job for the user's repositories has completed successfully (or been canceled by package or repository deletion), or immediately when the user's GPG key is removed |
| `gpg_key_transition_id` | UUID | FK to Signing Transitions; unresolved preparing, activating, active, finalizing, or failed user-wide key replacement/removal transition, including replacement preparation before `previous_gpg_key_public` is set; cleared only by the transition's terminal transaction (default `null`) |
| `confirmed_at` | timestamp | Email confirmation time |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

**Unique constraint**: `(email)`

### Audit Events

An append-only log of security-relevant actions. Rows are written in the same database transaction as the action they record when one exists; authentication events are recorded immediately after the authentication decision. Application code never updates or deletes audit rows, and the initial version does not prune them. The one mutation an audit row can undergo is the clearing of `actor_id` when the actor's account is deleted, and that happens in the database through an `ON DELETE SET NULL` foreign key rather than through an application update.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `actor_id` | UUID | FK to users, nullable — the acting user; null for unauthenticated and system events, and set to null when the actor's account is deleted |
| `actor_email` | string | Snapshot of the actor's email at event time (null for unauthenticated and system events), so attribution survives account deletion |
| `action` | string | Dotted event name (e.g., `auth.login`, `auth.login_failed`, `package.upload_intent_create`, `package.upload`, `gpg_key.replace`, `admin.user_delete`, `admin.slug_release`) |
| `target_type` | string | Affected resource type (`repository`, `package`, `upload_intent`, `user`, `api_key`, `gpg_key`, `collaborator`, `invitation`, `signing_transition`, `signing_transition_item`, `slug`); null when not applicable |
| `target_id` | UUID | Affected resource id; null when not applicable, and always null for `slug` targets, whose reservation is string-keyed and identified by the slug recorded in `metadata` |
| `ip` | string | Client IP as resolved by the client IP detection rules; null for system events |
| `metadata` | jsonb | Event-specific details (e.g., package NEVRA, invited email, changed setting names), default `{}`; never contains secrets, token values, or key material |
| `inserted_at` | timestamp | Event time |

Audited actions: successful and failed logins (web and API), password changes and resets, account email changes, account registration and admin account creation, API key creation and revocation, GPG key upload, generation, replacement, removal, and revocation strategies, repository creation, settings changes, and deletion, upload-intent creation/refresh/cancellation and terminal package-upload outcomes, package deletions, collaborator additions and removals, invitation creation, cancellation, conversion, and expiry refresh, signing-transition item and phase resets and transition cancellation, admin-flag changes, recovery promotion, user deletion, and slug-reservation releases. Audit metadata records intent IDs, generation numbers, sizes, and stable result codes but never presigned URLs, B2 version IDs, or GPG key material. Failed-login volume is bounded by the authentication-attempt rate limits. Admins browse the audit log in the admin UI.

### Authorization

- **Owner**: A user owns the repositories they create. Only the owner and admins can modify (update, delete, upload to) their repositories. Owners can add collaborators to their private repos.
- **Collaborator**: A user granted read access to a private repository by its owner or an admin. Collaborators can browse, view packages, and download RPMs from that repo. They cannot modify the repo or upload packages.
- **Admin**: Users with `is_admin = true` can perform any action on any repository, manage users, and access admin-only features.
- **Public**: Unauthenticated users can browse public repos, view packages, and download RPMs. No authentication is required for read-only access to public repositories.
- **Private repos**: When `is_public = false`, all access (including repodata and RPM downloads) requires authentication. Only the owner, collaborators, and admins can access private repos.

### User Lifecycle

- User accounts are created via web registration (when `REGISTRATION_ENABLED = true`) or by an admin in the admin web UI. There is no REST API for user creation or deletion; admin user management is web-only. Web-registered users must complete the `phx.gen.auth` email-confirmation flow before they can log in. Both the web login path (customized on top of `phx.gen.auth`) and the API login endpoint (`POST /api/v1/auth/login`) reject any user whose `confirmed_at` is null with the standard invalid-credentials response. Admin-created users are auto-confirmed: `confirmed_at` is set at creation time so the new account can log in immediately, and no confirmation email is sent (mirroring the bootstrap admin behavior). While `REGISTRATION_ENABLED = false`, the registration routes return the standard HTML 404 response and the web UI renders no registration links.
- Users can change their account email through the standard `phx.gen.auth` settings flow: the change takes effect only when the user confirms it from a link emailed to the proposed new address, which must pass the same normalization, validation, and uniqueness rules as registration. On confirmation, pending collaborator invitations addressed to the new normalized email are converted to collaborator records exactly as at account creation, a security-notification email is sent to the previous address, and the change is recorded in the audit log.
- The `is_admin` flag is managed only in the admin web UI: an admin can grant or revoke it on any user other than themselves. Bootstrap, recovery promotion, every web admin-flag mutation, and every admin user deletion acquire one shared instance-wide transaction-scoped PostgreSQL advisory lock. While holding it, the transaction reloads the acting user and target, requires the actor still to be a confirmed admin, rejects a self-target, and proves that at least one confirmed admin will remain after the mutation. There is no REST API for admin-flag management. Serializing deletion with role changes closes the race in which two admins could otherwise demote or delete each other concurrently and leave the instance without an administrator.
- An admin can delete a user account from the admin UI, but the deletion is rejected with `409 conflict_user_owns_repositories` if that user still owns any repositories. The admin must first delete those repositories. The deletion transaction uses the shared admin-invariant lock and rechecks described above rather than relying on authorization performed before the transaction.
- Users cannot delete their own accounts; account deletion is admin-only. The shared invariant makes the last-admin guarantee hold across concurrent demotion, deletion, bootstrap, and recovery-promotion attempts, not only the single-request self-demotion case. Barrier-started transaction tests cover two admins attempting to demote or delete each other, and an actor being demoted or deleted while its request waits for the lock; every committed outcome retains at least one confirmed admin and no stale actor can commit an admin mutation.
- When a user is deleted, the database cascades remove their API keys, session tokens, GPG key, upload intents they initiated, and pending collaborator invitations they sent, removes any collaborator membership rows where they are the collaborator, and deletes any pending collaborator invitations addressed to the deleted user's normalized email so a later re-registration with the same email does not silently re-attach to old invites. Before deleting upload intents, the transaction records their accepted exact staging versions and current uncompleted staging keys so version-aware cleanup and orphan reconciliation can reclaim every direct-upload object, and releases any storage reservations attached to those intents (the reservation's quota user is the repository owner, who may differ from the deleted initiator); workers are fenced by the deleted durable state. Repositories owned by other users on which the deleted user was a collaborator are otherwise unaffected. Retired slug-reservation rows from repositories the user previously deleted are retained with `user_id` cleared, so those slugs stay reserved until an admin releases them, and audit events keep their `actor_email` snapshot while `actor_id` is cleared. Signing transitions the user owned, their repository snapshots, and their items are likewise retained for audit: any transition still `preparing`, `activating`, `active`, `finalizing`, or `failed` is marked `canceled`, encrypted candidate fields are nulled, and linked reservations are released in the deletion transaction (its package items were already canceled when the user's repositories were deleted, so no worker can still act on it); the transition's `user_id` is cleared through `ON DELETE SET NULL`.

Every transaction that can create a user at an email, confirm an email change, or create/refresh/convert a collaborator invitation first acquires the same transaction-scoped PostgreSQL advisory lock derived from the normalized email, then repeats its user and invitation lookups while holding that lock. Hash collisions merely serialize unrelated addresses. This lock makes the user-versus-invitation decision atomic across registration, admin provisioning, email confirmation, and collaborator addition; database uniqueness constraints remain the final defense.

---

## RPM Repository Endpoint

### URL Structure

Each repository is served at a path like:

```
GET /repos/:slug/
```

The critical sub-paths that RPM clients expect:

```
GET /repos/:slug/repodata/repomd.xml
GET /repos/:slug/repodata/repomd.xml.asc        (when metadata signing is enabled)
GET /repos/:slug/repodata/primary.xml.gz
GET /repos/:slug/repodata/filelists.xml.gz
GET /repos/:slug/repodata/other.xml.gz
GET /repos/:slug/packages/:id/:filename.rpm   → 302 redirect to signed B2 URL
```

### Metadata Format

Dark Zenith generates standard `repodata/` metadata as defined by the RPM repository specification:

- **`repomd.xml`**: Root metadata index. Lists the location, checksum, size, and timestamp of each metadata file (`primary`, `filelists`, `other`). This is the entry point that DNF fetches first.

- **`primary.xml.gz`**: Contains package names, versions, architectures, summaries, sizes, checksums, and dependency information (requires, provides, conflicts, obsoletes, and the weak-dependency sets). This is the main metadata file used for dependency resolution. Each `<package>` element carries `type="rpm"`, matching `createrepo_c`. Each package entry also includes the standard "primary files" subset of that package's file list — paths under `/etc/`, paths containing `bin/`, and `/usr/lib/sendmail` — matching `createrepo_c` behavior so file-path dependencies on common paths (e.g., `/bin/sh`) resolve without downloading filelists. Those `<file>` entries are emitted inside the package's `<format>` block, after the dependency elements, as `createrepo_c` does. Each package's `<location>` element uses the relative path `packages/:id/:name-:version-:release.:arch.rpm` (the standard RPM filename, with no epoch component), so RPM clients resolve downloads against the repository base URL. The route is keyed by package UUID, so the filename segment is cosmetic and does not need to match the B2 storage key, which includes the epoch. Each package's `<time>` element sets `file` to the package row's `inserted_at` and `build` to `build_time`, falling back to `inserted_at` when `build_time` is null, both as Unix epoch timestamps in seconds. Each package's `<size>` element sets `package` to the package row's `size_package`, `installed` to `size_installed`, and `archive` to `size_archive`, omitting the `archive` attribute when `size_archive` is null (dnf/libsolv reads each size attribute independently); the `<packager>` element is not emitted, since the RPM `PACKAGER` tag is not stored, and dnf likewise tolerates its absence. The `<url>` element carries the package row's `url` and is omitted when that column is null. Each package's `<format>` block emits `rpm:license`, `rpm:vendor`, `rpm:group`, `rpm:buildhost`, `rpm:sourcerpm`, and `rpm:header-range` (`start` = `header_start`, `end` = `header_end`) alongside the dependency elements, matching `createrepo_c`; the optional string elements are omitted when their column is null. Dependency entries render as `<rpm:entry>` children of the hard-dependency elements, emitted in `createrepo_c`'s element order — `rpm:provides`, `rpm:requires`, `rpm:conflicts`, then `rpm:obsoletes` — and of the weak-dependency elements emitted after those four, likewise in `createrepo_c`'s order — `rpm:suggests`, `rpm:enhances`, `rpm:recommends`, then `rpm:supplements`. A dependency element whose list is empty is omitted entirely rather than emitted empty, hard and weak alike, matching `createrepo_c`. The `flags` attribute uses RPM's XML operator names — `EQ`, `LT`, `LE`, `GT`, `GE` — rather than the JSON `op` symbols. An unversioned entry carries only `name`; a versioned entry adds `epoch`, `ver`, and, when the RPM constrains one, `rel`; and a pre-transaction requirement adds `pre="1"`, which is omitted rather than set to `0` otherwise. Because dependency lists are normalized at extraction (see Package Upload & Processing), `rpm:requires` never contains `rpmlib(...)` entries or exact duplicates, and a rich (boolean) dependency renders as a name-only `<rpm:entry>` whose name is the full parenthesized expression, matching `createrepo_c`.

- **`filelists.xml.gz`**: Lists all files contained in each package. Used when a user runs commands like `dnf provides /usr/bin/something`. File entries are emitted with `type="dir"` for directories and `type="ghost"` for non-directory entries carrying the `ghost` flag; directory mode takes precedence, so a `%ghost %dir` entry is emitted as `type="dir"`, matching `createrepo_c`. Symlinks and regular files are emitted as plain `<file>` entries. The same mapping applies to the primary files subset embedded in `primary.xml.gz`.

- **`other.xml.gz`**: Contains changelog entries for each package. Only the first 10 changelog entries in RPM header order are emitted per package — `rpmbuild` writes the header newest-first, so these are the 10 most recent — matching the `createrepo_c` default limit, to keep the file small for clients; the full changelog remains on the package row and is served by the web UI and API. The selected entries are written oldest-first (the reverse of their header order), and when an entry's date in that sequence is not strictly greater than the previously emitted date, it is emitted as that previous date plus one second, reproducing `createrepo_c`'s strictly increasing output dates for equal-timestamp runs. The generated bytes are therefore deterministic and byte-match `createrepo_c` for the same package (verified against `createrepo_c` 1.2.1). This presentation rule applies only to the generated XML: the stored package row keeps the raw header entries with their original timestamps, and the API's changelog subresource keeps its own timestamp-descending order.

Generated XML is UTF-8 and is built with an XML encoder: every text and attribute value is escaped according to XML rules rather than interpolated as raw markup. `primary.xml` uses the `http://linux.duke.edu/metadata/common` default namespace and the `http://linux.duke.edu/metadata/rpm` `rpm` namespace. `filelists.xml` uses the `http://linux.duke.edu/metadata/filelists` namespace. `other.xml` uses the `http://linux.duke.edu/metadata/other` namespace. `repomd.xml` uses the `http://linux.duke.edu/metadata/repo` namespace. Each of `primary.xml`, `filelists.xml`, and `other.xml` carries that generation's package count as the `packages` attribute on its root element (`<metadata>`, `<filelists>`, and `<otherdata>` respectively). Package entries in `primary.xml` carry `<checksum type="sha256" pkgid="YES">` holding the package row's `sha256`; entries in `filelists.xml` and `other.xml` are keyed by that same `pkgid` value and repeat the package `name`, `arch`, and `<version epoch= ver= rel=>` element, matching `createrepo_c`.

`repomd.xml` includes a `<revision>` element set to the `metadata_revision` value the generation ran against (the same value stored as the cache row's `source_revision`). This is a deliberate deviation from `createrepo_c`, which writes a Unix timestamp there: `dnf`/`librepo` treat `<revision>` as an opaque string, and a monotonic revision makes cache staleness directly checkable against `source_revision`. Mirroring tools that interpret `<revision>` as a timestamp will therefore read a small integer, and should compare the `<data>` `timestamp` values instead. `repomd.xml` contains one `<data>` entry each for `primary`, `filelists`, and `other`. Each entry uses a fixed `location href` of `repodata/primary.xml.gz`, `repodata/filelists.xml.gz`, or `repodata/other.xml.gz`; `checksum` and `open-checksum` both carry `type="sha256"` and hold lowercase hex SHA-256 digests of the compressed and uncompressed metadata bytes respectively; `size` and `open-size` are byte counts; and `timestamp` is a Unix epoch timestamp in seconds. Metadata generation captures one UTC generation timestamp at the start of each generation run — in the regeneration job, or in the synchronous run at repository creation — truncated to whole seconds, and uses that value for all three `repomd.xml` data entries. Gzip output is deterministic for identical XML input: compression level is `6`, `mtime` is `0`, and no original filename is stored in the gzip header.

### Metadata Generation & Storage

All repodata XML is generated by the app and served directly from the app (not from B2). The metadata is stored in PostgreSQL as cached blobs so it can be served without regeneration on every request. The initial release supports at most `MAX_REPOSITORY_PACKAGES` packages per repository (default 10 000), and each of the three uncompressed XML artifacts is capped at `MAX_REPODATA_OPEN_BYTES` (default 268 435 456 bytes, 256 MiB).

Package creation, deletion, and re-signing lock the repository row and update `package_count`, `primary_open_bytes`, `filelists_open_bytes`, and `other_open_bytes` in the same transaction as the package mutation. The deterministic XML encoder can render an individual package's entries to a counting sink, so a mutation computes its exact byte delta without materializing a whole repository document; the calculation also accounts for the root element and any change in the decimal `packages` attribute. An upload that would exceed the package-count limit or any projected uncompressed-artifact limit is rejected with `409 conflict_repository_metadata_limit_exceeded` during upload processing — before the storage reservation is adjusted to the final size and before any final B2 write — with the authoritative recheck in the final package transaction. A re-sign item that would cross a metadata limit fails with that same persistent error code and requires package deletion, a higher configured limit, or an admin retry after remediation. A release whose XML serialization changes must include a migration that recalculates all four counters before the new encoder runs.

Lowering a configured limit below an existing repository's maintained count does not refuse application startup, invalidate an already-current cache, or prevent a reducing mutation. Uploads and re-signs are rejected while their projected state exceeds any configured limit, but package deletion and metadata regeneration remain available. During regeneration, each defensive artifact ceiling is `max(MAX_REPODATA_OPEN_BYTES, captured_maintained_counter_for_that_artifact)`, so an over-limit grandfathered repository can reproduce its current or smaller valid state while the exact counter-equality check still detects encoder drift. Once every count is at or below configuration, the ordinary configured ceilings apply again. The repository settings and admin views display the exceeded dimensions and current/configured values. Tests lower each limit below live state, verify current metadata remains served, exercise regeneration and deletion, and prove that additions stay blocked until the repository returns below the limit.

Metadata is regenerated as a background job (via Oban) when packages are added to or removed from a repository, or when repository settings that affect generated metadata change. Repository creation is the exception: initial empty metadata is generated synchronously during creation so a new empty repo has a current cache before it is exposed. The regeneration process:

1. Package upload/deletion increments the repository's `metadata_revision` inside the same database transaction that changes package membership.
2. The transaction enqueues a unique Oban regeneration job for the affected repository. On deletion, a separate idempotent Oban job permanently removes the exact RPM object version after the package row is removed. Version-aware B2 cleanup jobs treat an already-absent version as success and retry only other object-storage errors.
3. The regeneration job reads the current repository `metadata_revision` and its maintained size counters, then queries all packages in the repository in deterministic order by `name`, `epoch`, `version`, `release`, `arch`, and `id`, all within one database transaction using a single consistent snapshot so the captured revision, the counters, and the package set cannot skew against one another.
4. Each XML artifact is encoded incrementally to a mode-`0600` temporary file under `RPM_UPLOAD_TMPDIR` while its SHA-256 and byte count are calculated. The encoder never constructs a complete XML document in BEAM memory and aborts defensively if an actual byte count exceeds that artifact's captured effective ceiling (`max(MAX_REPODATA_OPEN_BYTES, maintained_counter)`) or differs from the maintained counter. Each completed XML file is then streamed through gzip level 6 to a second mode-`0600` temporary file, with gzip `mtime = 0` and no original filename; compressed checksums and sizes are calculated during that pass.
5. A new `repomd.xml` is generated with checksums pointing to the current metadata files.
6. The generated metadata blobs, `repomd.xml`, optional `repomd.xml.asc` signature, and `source_revision` are stored in PostgreSQL keyed by repository. The update applies only when the generated `source_revision` is strictly greater than the stored value (or inserts when the cache is missing), so a slower job can never move the cache backward and two jobs for the same revision cannot replace one another with different generation timestamps or signature creation times. A job that finds the cache already at or beyond its captured revision skips generation. Temporary files are removed after the database write, lost compare-and-swap, or any failure.
7. Before completing, the job reloads the repository. If `metadata_revision` is greater than the cached `source_revision`, the job enqueues another unique regeneration job so the final cache reflects the latest package set.
8. The repo endpoint serves metadata directly from the cache once the cache `source_revision` matches the repository's current `metadata_revision`.

Repository creation claims its slug reservation, writes the repository row, generates empty `primary.xml.gz`, `filelists.xml.gz`, `other.xml.gz`, `repomd.xml`, and optional `repomd.xml.asc`, and writes the metadata-cache row with `source_revision = 0` in the same database transaction. A creation that reuses the creator's own retired slug changes that reservation back to live through the conditional claim described under Slug Reservations. Newly created empty repos therefore immediately serve valid metadata from the cache. If a repository is created with `gpg_key_fingerprint` set and synchronous `repomd.xml` signing fails for an infrastructure reason, the transaction is rolled back and the caller receives `503 signing_unavailable`; validation failures still return `422 validation_failed`. Repository setting changes that affect generated metadata, such as enabling/disabling metadata signing or changing `gpg_key_fingerprint`, use the same `metadata_revision` increment and regeneration enqueue path.

Metadata endpoints return `503 Service Unavailable` with plain text body `metadata_not_ready` and `Retry-After: 5` when the cache row is missing or its `source_revision` is older than the repository's current `metadata_revision`. The endpoint does not generate metadata inline and does not serve stale metadata for an out-of-date revision.

Multiple rapid changes are debounced with an Oban unique job keyed by `repository_id` while the job is available or scheduled. Running jobs are allowed to be followed by a newly queued job, and the `metadata_revision`/`source_revision` check guarantees another job runs until the cache reaches the latest revision. If `repomd.xml` signing fails for an infrastructure reason during a regeneration job, the job fails without writing the cache row, so the previous cache is left intact and metadata endpoints keep returning `503 metadata_not_ready` for the newer revision until a retry succeeds. Metadata regeneration and B2 cleanup jobs use Background Retry Policy; exhausted jobs remain visible in Oban for admin intervention.

Because metadata files are served at fixed `repodata/` paths from a single cache row, a client that fetches `repomd.xml` and the referenced blobs across a regeneration boundary can observe checksum mismatches for that fetch cycle. This transient race is accepted for the initial version: the affected metadata fetch fails, and a retry refetches `repomd.xml` and succeeds against the new consistent generation. Serving checksum-named metadata files with retained previous generations would eliminate the race and is listed under Future Considerations.

### RPM File Downloads

When a client (e.g., `dnf`) requests an RPM file at `/repos/:slug/packages/:id/:filename.rpm`:

1. Dark Zenith validates access to the repository identified by `:slug`, then validates that the final path segment — the `:filename` capture together with its `.rpm` extension — matches `^[A-Za-z0-9._+~-]+\.rpm$`; non-matching requests are rejected with `400 invalid_request`. It then looks up the package record by `:id` scoped to that repository in PostgreSQL to find the B2 storage key and exact `storage_version_id`. The `:filename` segment is otherwise cosmetic (ignored for routing) but provides a human-readable filename for download clients.
2. Generates a **signed Backblaze B2 URL** for that exact object version using `B2_SIGNED_URL_TTL` (default **30-minute expiration**). If B2 signed URL generation fails for an infrastructure reason, the endpoint returns `503 storage_unavailable`.
3. Responds with **HTTP 302 redirect** to the signed URL.
4. The client downloads the RPM directly from B2.

This keeps RPM file bandwidth off the app server entirely.

Repository-serving endpoints intended for RPM clients (`/repos/:slug/repodata/...`, `/repos/:slug/packages/:id/:filename.rpm`, `/repos/:slug/RPM-GPG-KEY`, and `/repos/:slug/dark-zenith.repo`) use plain-text error responses. On these endpoints, 4xx and 5xx errors such as `400 invalid_request`, `401 unauthenticated`, `404 not_found`, `429 rate_limited`, `503 storage_unavailable`, and `503 metadata_not_ready` return a `text/plain; charset=utf-8` body whose contents are the error code string and nothing else. `403 forbidden` is not among them: every insufficient-credential outcome on these endpoints resolves to the anonymous `401` challenge or to the `404 not_found` masking rule, including a valid API key that lacks `repo:read`. Web UI routes under `/repos/:slug` keep their normal HTML responses, and `/api/v1/...` endpoints use the JSON `{"error": {...}}` envelope. Successful responses on these repository-serving endpoints use the following `Content-Type` values: `repomd.xml` is served as `application/xml`; `primary.xml.gz`, `filelists.xml.gz`, and `other.xml.gz` as `application/gzip`; and `repomd.xml.asc`, `RPM-GPG-KEY`, and `dark-zenith.repo` as `text/plain; charset=utf-8`. `dark-zenith.repo` additionally sends `Content-Disposition: attachment; filename="dark-zenith-<slug>.repo"` so a browser saves the file instead of rendering it inline; `dnf config-manager` ignores the header and reads the body either way.

Repository-serving endpoints ignore query strings: a request carrying one is processed exactly as if the query were absent. Supported DNF clients never append query parameters to these paths, but proxies and mirror tooling sometimes add cache-busting values, and rejecting them would add client-visible failure modes without protecting a read-only surface whose responses revalidate by `ETag`. The strict query-parameter rules in API Contract Details do not apply to these endpoints.

Every repository-serving `GET` route also accepts `HEAD`. A `HEAD` request performs the same authentication, authorization, rate-limit, and conditional-request work as `GET`, and returns the same status and representation headers but never a response body. Package downloads still return `302 Location`, but the location is a method-specific presigned B2 `HeadObject` URL; Dark Zenith never reuses a presigned `GetObject` URL for `HEAD`, because the HTTP method is part of the SigV4 signature.

### Caching headers

Dark Zenith is expected to run behind a shared cache (Cloudflare in production), so every repository-serving response states its cacheability explicitly rather than relying on a proxy's defaults:

- **Package download redirects** (`/repos/:slug/packages/:id/:filename.rpm`, public or private): `Cache-Control: private, no-store`. The 302 carries a signed B2 URL that is valid for `B2_SIGNED_URL_TTL` seconds; a shared cache that stored it would hand one client's time-limited URL to every other client, and would keep serving it after the underlying object was re-signed or deleted.
- **Any response for a private repository**, on any repository-serving endpoint: `Cache-Control: private, no-store`, so repodata, `RPM-GPG-KEY`, and `dark-zenith.repo` for a private repo are never held in a shared cache. Those three response families still carry the same strong `ETag` and honor `If-None-Match` with `304 Not Modified` as the public bullet below describes: `no-store` keeps the bytes out of intermediary caches, but it must not force a private `dnf` client to re-transfer unchanged metadata on every `metadata_expire` cycle. Package-download redirects are the exception on both counts — public or private, they never carry an `ETag` and ignore `If-None-Match`, because every response mints a fresh signed URL that a `304` could not deliver.
- **Public repodata, `RPM-GPG-KEY`, and `dark-zenith.repo`**: `Cache-Control: public, max-age=0, must-revalidate`, plus one strong `ETag` containing the served bytes' lowercase hex SHA-256 in quotes. A request carrying a matching `If-None-Match` gets `304 Not Modified` with an empty body. These endpoints, public and private alike, do not emit `Last-Modified` and ignore `If-Modified-Since`, because second-resolution HTTP dates cannot safely represent multiple content changes within one second. Revalidation on every fetch keeps a shared cache from widening the checksum-mismatch race described under Metadata Generation & Storage, while still letting `dnf` and the cache skip the transfer when nothing changed.
- **All 4xx and 5xx responses** on these endpoints: `Cache-Control: no-store`, so a transient `503 metadata_not_ready` or a `401` challenge is never cached on behalf of later clients.
- Every repository-serving response also sends `Vary: Authorization, Cookie`, because the same path is reachable anonymously, with Basic Auth credentials, or with a browser session cookie, and those authentication modes use different authorization and rate-limit buckets.

Web UI and `/api/v1/...` responses send `Cache-Control: no-store`.

### Private Repository Authentication

Private repositories (`is_public = false`) require authentication on all endpoints, including repodata and RPM downloads. The initial compatibility contract covers current DNF 4 and DNF 5 clients; legacy Yum behavior is best-effort and is not a release gate. Supported DNF clients authenticate via **HTTP Basic Auth**:

- **Username**: `token` by convention — the server ignores the username, so any value works; the password alone is the credential
- **Password**: a valid API key with the `repo:read` scope

Dark Zenith checks the API key, verifies it has the `repo:read` scope, resolves the owning user, and verifies they have access to the repository (as owner, collaborator, or admin) before serving metadata or issuing a signed B2 URL.

Browser requests to these repository-serving endpoints — for example, the direct download link on the package version detail page — may instead authenticate with the standard web session cookie; the same repository access checks apply.

These endpoints also accept `Authorization: Bearer <token>`, so a script that already holds a bearer token does not need a second credential shape to fetch `RPM-GPG-KEY` or `dark-zenith.repo`. A bearer API key is validated and scope-checked exactly like the Basic password above, requiring `repo:read`; a bearer session token carries no scopes and authorizes as its logged-in user, like a web session. Either way the same repository access check decides the outcome. `Basic` and `Bearer` are the only recognized schemes on these endpoints, and any other scheme is an unsupported credential.

An `Authorization` header is authoritative whenever one is present: it takes precedence over the session cookie, and an invalid or unsupported authorization scheme never falls back to cookie or anonymous access. With no `Authorization` header, a stale or invalid session cookie is ignored for a public repository read and the request proceeds anonymously. On a private or nonexistent target, such a cookie follows the invalid-credential masking rule and receives `404 not_found`; a request with no cookie or authorization credential at all remains anonymous and receives the Basic challenge described below.

Anonymous requests (no credentials at all) to these repository-serving endpoints respond `401 unauthenticated` with a `WWW-Authenticate: Basic realm="Dark Zenith"` header whenever the target slug is private or does not exist. Unknown and private slugs are treated identically so the challenge does not leak repository existence, and RPM client HTTP stacks that wait for a challenge before sending Basic credentials (librepo/libcurl configured via `username=`/`password=` repo directives) still work. Requests that do present credentials follow the private-repository masking rule in API Contract Details: invalid or expired credentials, and valid principals without access, receive `404 not_found`.

Public repositories may also receive the same Basic or Bearer credentials as optional authentication for higher rate limits. For public repository reads, an API key only needs to be valid, non-expired, and have at least one valid scope, and a session token only needs to be unexpired; `repo:read` and repository access checks are not required. If optional credentials are present but invalid, expired, or revoked, the response is `401 unauthenticated` with the same `WWW-Authenticate: Basic realm="Dark Zenith"` challenge rather than silently falling back to anonymous access.

Private configuration uses repository credential directives; Dark Zenith never generates URLs containing userinfo credentials:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://<hostname>/repos/:slug/
username=token
password=<api-key>
enabled=1
metadata_expire=6h
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://<hostname>/repos/:slug/RPM-GPG-KEY
```

For repositories without metadata signing, `repo_gpgcheck` is `0`. For repositories whose `rpm_signing_state` is not `enabled`, including repositories still in the `signing` transition, `gpgcheck` is `0`. The `gpgkey` line is included whenever `gpg_key_fingerprint` is configured and is omitted only when no repository key is configured. Release integration tests install from public and private repositories with both DNF 4 and DNF 5, exercising repodata verification, key retrieval, package redirects, and package-signature verification. The redirect tests capture the B2-side request and prove that the client does not forward the Dark Zenith `Authorization` header or session cookie to the cross-origin object-storage target. If a supported client release does not propagate `username` and `password` to `gpgkey`, its generated setup instructions perform a separate interactive `curl --fail --user token .../RPM-GPG-KEY | sudo rpmkeys --import -` step that prompts for the API key; credentials are never placed in a URL, command argument, or generated file by that fallback.

### GPG Signing (Optional)

Each user can upload an OpenPGP V4 key pair (public + private) to their account, or have Dark Zenith generate one server-side (see Server-side key generation below). OpenPGP V5/V6 keys are outside the initial compatibility contract and are rejected with `422 validation_failed`. Each armored pair must contain exactly one matching V4 primary-key identity. The private key is encrypted at rest in the database using the GPG private key encryption envelope described below. Private keys must be dedicated repository-signing keys that can sign non-interactively. Upload validation chooses a usable signing-capable primary key when one exists; otherwise it requires exactly one usable signing-capable subkey and rejects an ambiguous set of multiple usable signing subkeys. It records the chosen key's exact fingerprint in `gpg_signing_fingerprint` and forces every test and production signature to that fingerprint with GPG's exact-key selector rather than allowing GPG to choose a different subkey later.

Signing usability is verified at upload inside an ephemeral `GNUPGHOME`. Passphrase-protected, revoked, or otherwise unusable private keys are rejected with `422 validation_failed`. The selected key's algorithm and parameters, read from GPG's machine-readable status output, must be exactly RSA-3072, RSA-4096, ECDSA over NIST P-256, ECDSA over NIST P-384, or Ed25519. Other RSA sizes, curves, EdDSA variants, original DSA, and unknown algorithms are rejected. After the generic exact-key GPG test signature, Dark Zenith signs bundled, strongly digested RPM v4 and RPM v6 fixtures with the candidate key; the v6 command also requests `--rpmv4`. It then imports the public key into an isolated RPM database and requires RPM 6 `rpmkeys` to report the expected key's v4-compatible signatures and every digest `OK` on both outputs. A key upload therefore returns `503 signing_unavailable` when `rpmsign` is unavailable and `503 rpm_verification_unavailable` when the verifier is unavailable, even if the user currently plans metadata-only signing. This per-key runtime test, plus release integration fixtures exercised through supported DNF 4 and DNF 5 clients, is the compatibility floor rather than an assumption based only on algorithm names. FIPS-mode tests verify the same fail-closed behavior: an otherwise allowlisted algorithm disabled by the deployment's crypto policy is rejected as unusable with `422 validation_failed`; Dark Zenith never weakens that policy. The effective signing expiry is the earlier expiration of the primary key and the selected signing key or subkey, ignoring a missing expiration on either; it is null only when neither expires. An effective expiry less than 30 full days away is rejected, and the accepted value is stored in `gpg_key_expires_at`. A daily scan queues reminder emails when an expiring key first crosses 30, 7, and 1 full day remaining. Successful delivery records that threshold in `gpg_key_expiry_notified_days`, and replacement resets the set. The jobs are unique by `(user_id, fingerprint, threshold)` and re-check the current fingerprint and expiry before sending.

If a configured key nevertheless expires before replacement, all new metadata-signing, package-signing, re-signing, and attempts to enable signing fail closed with `409 conflict_gpg_key_expired`; existing signed bytes remain stored and served, but clients may reject their signatures. The account and repository settings pages display an expired-key error until the owner replaces or removes the key. Metadata regeneration that requires the expired key records a non-retryable `conflict_gpg_key_expired` failure rather than consuming 20 infrastructure retries.

#### Server-side key generation

As an alternative to uploading key material, a user can ask Dark Zenith to generate their key pair server-side. Generation runs inside the same kind of ephemeral mode-`0700` `GNUPGHOME` under `RPM_UPLOAD_TMPDIR` used for validation and signing, invokes `gpg` batch quick-key generation with an argument vector (never a shell), and removes the home after the attempt. The generated key is a sign-capable V4 primary key with no subkeys, no passphrase, and no expiration; its user ID is `Dark Zenith repository signing <account email>`, snapshotting the account's email at generation time (a later email change does not rewrite the UID — it is informational only). The caller selects the algorithm with an optional `algorithm` parameter drawn from exactly the signing allowlist above: `ed25519` (the default), `rsa3072`, `rsa4096`, `nistp256`, or `nistp384`. Unknown values are rejected with `422 validation_failed`.

Generation is a source of key material, not a validation bypass: the generated armored pair then passes through the identical pipeline as an uploaded pair — the same selection rule, algorithm checks, exact-key test signature, bundled RPM v4/v6 fixture signing with RPM 6 verification, and the same encryption envelope at rest — with the same outcomes. A deployment crypto policy that refuses the chosen algorithm fails with `422 validation_failed`, an unavailable `gpg`/`rpmsign` is `503 signing_unavailable`, an unavailable verifier is `503 rpm_verification_unavailable`, and a pair that fails any check stores nothing. First-key and replacement semantics are also identical to upload: generating with no stored key is a synchronous write, while generating over an existing key starts the same durable `replace_gpg_key` transition under the same `409 conflict_gpg_key_transition_in_progress` guard, holding the candidate in the same encrypted prepared fields.

Successful generation responses reveal the generated ASCII-armored private key exactly once, so the user can keep an offline backup. It is never retrievable again: the server persists only the encryption envelope (or the encrypted prepared candidate mid-replacement), and no GPG key resource, transition resource, audit event, email, or log line ever carries private key material. The reveal exists for backup and portability — Dark Zenith performs every signing operation itself, so no client-side signing step needs the key. Losing the revealed copy costs nothing operationally; conversely it is the user's only hedge if an operator ever rotates `SECRET_KEY_BASE` outside the dual-base procedure below, which would strand the server-held copy. Generation is audited without key material: a first key records `gpg_key.generate` with the chosen algorithm and resulting fingerprint, and a generated replacement's `gpg_key.replace_start` event records the algorithm and that its candidate was server-generated.

#### GPG private key encryption

The `gpg_key_private` field stores a versioned binary encryption envelope rather than raw key material. Two envelope versions are defined:

- **`v1`**: AES-256-GCM with a 32-byte key derived from `SECRET_KEY_BASE` by HKDF-SHA-256 using a fresh cryptographically random 16-byte salt and the context string `dark_zenith:gpg_private_key:v1`. Every encryption also generates a fresh cryptographically random 12-byte nonce; an `(derived key, nonce)` pair is never reused. Binary format: 1-byte version (`0x01`), 16-byte salt, 12-byte nonce, 16-byte authentication tag, and ciphertext bytes for the ASCII-armored private key. AEAD additional authenticated data is `dark_zenith:gpg_private_key:v1:<user_id>`, binding the encrypted value to the owning user.
- **`v2`** (current): identical binary layout and AEAD construction to `v1`, with version byte `0x02`, HKDF context string `dark_zenith:gpg_private_key:v2`, and AAD `dark_zenith:gpg_private_key:v2:<user_id>`. New writes always use `v2`; the dedicated version byte and distinct HKDF/AAD contexts give a clean boundary for future format changes without colliding with `v1` rows.

Reads dispatch by the stored version so older rows continue to decrypt while the background re-encryption job migrates them. Rows whose envelope version is unsupported by the running release fail closed and require admin intervention (typically uploading a fresh GPG key pair to overwrite the unreadable row).

All envelope inputs have exact byte encodings. `SECRET_KEY_BASE` is the raw UTF-8 byte sequence supplied by configuration; it is not trimmed, Unicode-normalized, or base64-decoded. Production boot requires it to contain at least 64 bytes and operators must generate it with a cryptographically secure generator such as `mix phx.gen.secret`; HKDF salt cannot compensate for a low-entropy input key. `PREVIOUS_SECRET_KEY_BASE`, when configured, has the same minimum and must differ from the current value. The deliberately short fixed-vector IKM below is test data only and is exempt from production configuration validation. HKDF emits exactly 32 bytes. Context strings, AAD, and armor are their exact UTF-8 bytes, and `<user_id>` is the canonical lowercase, hyphenated ASCII UUID. Encryption preserves the accepted ASCII-armored private-key bytes exactly, including line endings and final newline. The binary field order is version, salt, nonce, tag, ciphertext; it is not the ciphertext/tag order returned by some AEAD APIs.

Implementations must reproduce these fixed vectors (hex is lowercase only for presentation):

| Input | Value |
|---|---|
| IKM | UTF-8 `test-secret-key-base` |
| User UUID | `00000000-0000-4000-8000-000000000001` |
| Salt | `000102030405060708090a0b0c0d0e0f` |
| Nonce | `101112131415161718191a1b` |
| Plaintext | UTF-8 `-----BEGIN PGP PRIVATE KEY BLOCK-----\nTEST\n-----END PGP PRIVATE KEY BLOCK-----\n` |

In that table each `\n` denotes one LF byte (`0x0a`), not the two characters backslash and `n`; there are no CR bytes.

- `v1` derived key: `4ffe0b263e053b2e989b429a47caac0d4cc8fb4bb67f13d0854a59788c76cc33`
- `v1` envelope: `01000102030405060708090a0b0c0d0e0f101112131415161718191a1bdbf2d8de9d3a7bd94a6e856bcca54c2d395463ec41331ffe72bf035be495fa9449584fdb7fd6ccd274d4ae29bf7c2eddaaf87a9b37c19f5b6099fa67f1a19ca42ade38a077d421ed4969a972eb8f872faab3dcfb65034e04938f6b3410e568`
- `v2` derived key: `54520f77e307c3e71067ef43e4840bc2dc6e358a4e5ac57552ee08200401c86d`
- `v2` envelope: `02000102030405060708090a0b0c0d0e0f101112131415161718191a1b63a7042abadead2e525c11c203fe7263393cabfcb91bce6ddb7abefa28b5e84c9fc05037821acae68113fe28e9431ff4ed3019774ed51df8299f22dc098dcff2fa92726f00c0ce808272c23084384d05ef4bd71d1d1b90328ad5463b1bcbad`

Vector tests also decrypt both envelopes, reject a changed UUID/AAD, and prove that changing one IKM byte, salt byte, nonce byte, tag byte, or ciphertext byte fails or changes the result as appropriate.

**`SECRET_KEY_BASE` rotation procedure.** Because both `v1` and `v2` derive their AEAD key from `SECRET_KEY_BASE`, rotating that value would otherwise strand every current or prepared private key. To rotate safely, the operator sets the new value on `SECRET_KEY_BASE` and provides the prior value on `PREVIOUS_SECRET_KEY_BASE`. Both are read at boot with the exact byte rules above. Encryption always derives its key from `SECRET_KEY_BASE`. Decryption first attempts the current envelope using `SECRET_KEY_BASE`; on AEAD authentication failure it retries with `PREVIOUS_SECRET_KEY_BASE` if configured. When `PREVIOUS_SECRET_KEY_BASE` is set at boot, the application enqueues a unique Oban scan job (`DarkZenith.Jobs.GpgKeyReencryption`) that paginates both user `gpg_key_private` values and transition `prepared_gpg_key_private` values, enqueuing one job per ciphertext. Prepared candidates use their transition owner's user UUID as AAD, exactly like the eventual user row.

Each job snapshots its ciphertext and first classifies it: a `v2` envelope that decrypts with the current base is already migrated and is a successful no-op; a supported envelope that is still `v1` or decrypts only with the previous base is rewritten as `v2` under the current base. A user rewrite compares `(user_id, gpg_key_private)`; a prepared rewrite compares `(transition_id, user_id, prepared_gpg_key_private)`. A zero-row compare-and-swap means the key/candidate moved, was replaced, or was removed concurrently and is a successful no-op, preventing stale re-encryption from restoring old material. Per-row jobs use Background Retry Policy; exhausted jobs remain visible for admin intervention. The scan runs on each boot while the prior base is set; when no current or prepared value decrypts only with it, the operator can remove `PREVIOUS_SECRET_KEY_BASE`. Rotating without the prior base immediately strands old envelopes and they fail closed.

When creating or editing a repository, the owner can enable two levels of signing:

#### Repository metadata signing (`gpg_key_fingerprint` set)

- `repomd.xml` is signed during metadata regeneration using the owner's GPG key. Signing produces a detached ASCII-armored signature (`gpg --local-user <gpg_signing_fingerprint>! --detach-sign --armor`) over the exact `repomd.xml` bytes stored in the cache row, using the owner's decrypted private key imported into an ephemeral `GNUPGHOME` created under `RPM_UPLOAD_TMPDIR` with `0700` permissions and removed after the attempt, exactly as for RPM signing. `gpg` is invoked with an argument vector, never through a shell.
- `repomd.xml.asc` is served alongside `repomd.xml`.
- The owner's public key is served at the repo level.

```
GET /repos/:slug/repodata/repomd.xml.asc
GET /repos/:slug/RPM-GPG-KEY
```

Both endpoints return `404 not_found` when the repository has no `gpg_key_fingerprint` configured. While the repository owner is mid-transition through a GPG key replacement (their `previous_gpg_key_public` is set), `/repos/:slug/RPM-GPG-KEY` returns the previous and current public keys concatenated into a single response body containing both ASCII-armored public key blocks so clients can verify both old- and new-key signatures during the transition (see "Key replacement and revocation" below).

#### RPM signing (`sign_rpms = true`, requires `gpg_key_fingerprint`)

When enabled, Dark Zenith automatically signs uploaded RPMs during the upload processing pipeline:

1. After RPM validation and metadata extraction, the private key is decrypted from the database.
2. The private key is imported into an ephemeral `GNUPGHOME`, created under `RPM_UPLOAD_TMPDIR` with `0700` permissions, and removed after the signing attempt completes.
3. The uploaded RPM is copied to a temporary working path and signed with the system `rpmsign` tool, using an rpm macro configuration that points at the ephemeral GPG home and `--key-id <gpg_signing_fingerprint>` to force the exact signing key. RPM v4 inputs use the default v4 package-signature behavior and do not request `--rpmv6`. RPM v6 inputs use their native v6 signature plus `--rpmv4`, which requests the additional v4 compatibility signature needed by supported RPM 4/DNF 4 clients. Signing never changes the package's v4/v6 file format.
4. Unsigned RPMs are signed with `rpmsign --addsign`; RPMs that already contain an OpenPGP package signature are signed with `rpmsign --resign` so the existing package signature is replaced.
5. The owner's public key is imported into an isolated temporary RPM database/keyring under the upload working directory, and the signed RPM is verified with `rpmkeys --dbpath <temporary-rpmdb> --checksig --verbose` under `LC_ALL=C`. Every reported digest must be `OK`, and at least one OpenPGP signature must be `OK` for `gpg_signing_fingerprint`; `NOTFOUND`, a different signer, or any `BAD` result rejects the upload with `422 validation_failed` and no package row is created. Failure to create the temporary keyring or import the already-validated public key is `503 signing_unavailable`; failure to invoke the required RPM 6 verifier is `503 rpm_verification_unavailable`. The temporary RPM database is removed with the rest of the working directory.
6. The SHA-256 checksum is recomputed on the signed RPM.
7. The signed RPM is uploaded to a fresh write-once final B2 key. The package row is not changed until that exact returned version has passed the fenced final transaction.

RPMs that are already signed — whether with the owner's configured key or a third-party key — are re-signed (the existing signature is replaced). This ensures all packages in the repo are signed with a consistent key; integrity of a third-party-signed upload is still guaranteed by its header and payload digests, which must verify `OK` before signing. Source RPMs are signed and verified through the same flow as binary RPMs. External tools (`rpmkeys`, `rpmsign`, `gpg`) are always invoked directly with argument vectors, never through a shell, so no metadata value is ever interpreted as shell syntax. Upload-intent and signing-transition workers never sign a B2 source object in place: each retry downloads the immutable source again, creates a fresh working copy, and relies on its durable lease token to fence the final commit.

If `sign_rpms` is enabled but the owner has no GPG key configured, the upload is rejected with `422 validation_failed`.

`sign_rpms` is the desired behavior for future uploads. `rpm_signing_state` controls whether generated setup snippets and `.repo` files enable RPM signature verification:

- `disabled`: `sign_rpms = false`; generated `.repo` files use `gpgcheck=0`.
- `signing`: `sign_rpms = true`, but one or more existing packages still need a successful re-sign job before every package can be verified with a key served by `/repos/:slug/RPM-GPG-KEY`; generated `.repo` files use `gpgcheck=0`.
- `enabled`: `sign_rpms = true` and every current package is signed by a key served by `/repos/:slug/RPM-GPG-KEY`; generated `.repo` files use `gpgcheck=1`.

When `sign_rpms` is enabled on an empty repository, `rpm_signing_state` becomes `enabled` immediately. When it is enabled on a non-empty repository, the owner must explicitly choose `existing_package_strategy = "resign"`. In one transaction Dark Zenith creates an `enable_rpm_signing` Signing Transition plus one pending item per current package, sets `sign_rpms = true` and `rpm_signing_state = "signing"`, stores the transition ID, and enqueues one Oban job per item ID. That one transaction writes at most `MAX_REPOSITORY_PACKAGES` items and jobs — the reason that variable carries a hard upper bound — so repository-local enablement stays a single atomic commit instead of needing the batched preparation user-wide transitions use. Each item snapshots both the package's current storage path and exact version ID. New uploads are signed before insertion while the transition runs and need no transition item.

The 60-second transition sweep uses only Signing Transition Item state, never Oban row retention. It requeues expired execution leases and sets `rpm_signing_state = "enabled"`, marks the transition completed, and clears `signing_transition_id` only when every item is `succeeded` or was `canceled` by package deletion and the metadata cache has reached the current revision. Any failed item makes the transition `failed`; the twentieth failed metadata-regeneration attempt required for completion likewise records a sanitized error and fails the transition with `resume_status = "active"`. The repository remains `signing` with `gpgcheck=0` until an admin fixes the cause and resets the failed item or regeneration, or deletes the failed package, which cancels the item. Signing only future uploads is unsupported. Disabling `sign_rpms` marks the transition and all unfinished items `canceled`, sets the repository to `disabled`, clears its transition ID, and does not strip signatures already written. In the same transaction it also cancels every pending, executing, or failed item for that repository in a user-wide `replace_gpg_key` transition and releases those items' reservations, matching how package and repository deletion cancel user-wide items; the parent replacement is unaffected and still completes on its remaining items and repository snapshots. A worker re-checks all current transition fields and target fingerprints immediately before its package update, so a canceled or superseded item cannot commit.

#### Key replacement and revocation

Uploading or generating the first GPG key remains a synchronous write because it has no affected repositories. Replacing an existing key — whether the candidate is uploaded or server-generated — is a durable user-wide operation and is rejected while another user-wide GPG transition is unresolved in any phase, or while an owned repository has `rpm_signing_state = "signing"`. The accepted replacement request returns `202 Accepted` with its transition resource and proceeds as follows:

1. After all candidate-key validation and runtime RPM compatibility tests succeed, one short transaction creates a `replace_gpg_key` transition in `preparing`, stores the candidate only in its encrypted prepared fields, points `users.gpg_key_transition_id` at it, and enqueues the first preparation job. The user's current key and all repository fingerprints remain unchanged; `previous_gpg_key_public` is still null, and `/RPM-GPG-KEY` serves only the current key.
2. Preparation workers snapshot every metadata-signed repository in Signing Transition Repositories and every current package in every RPM-signed repository as a Signing Transition Item, in durable UUID-ordered batches. Each batch commits its rows and cursor together; an exhausted scan sets its explicit complete flag. A 60-second sweeper schedules missing preparation work. Because affected writes are blocked while preparing (and after pre-activation exhaustion), both complete flags prove the snapshot finished even when either set is empty. Transient preparation failures use Background Retry Policy; the twentieth changes the transition to failed with its encrypted candidate/cursors retained for admin reset, while explicit cancellation nulls them. A deterministic precondition loss cancels the transition and nulls its candidate fields.
3. A small key-swap transaction locks only the owner and transition, requires both preparation-complete flags and that the candidate still has at least 30 full days before effective expiry, copies the old public key to `previous_gpg_key_public`, moves the prepared private/public key, primary fingerprint, exact signing fingerprint, expiry, and an empty reminder-threshold set onto the user, changes the transition to `activating`, clears its candidate/cursors, and enqueues the first repository-application batch. A candidate that no longer meets the expiry floor cancels safely while the current key remains untouched. From a successful commit both keys are served, but owner mutations remain blocked until activation finishes.
4. Activation workers process pending Signing Transition Repository rows in bounded batches. For each surviving repository, the transaction changes its fingerprint to the new primary fingerprint, increments `metadata_revision`, marks the snapshot row applied, and enqueues regeneration; deleted repositories are marked satisfied. When no pending rows remain, a small transaction changes the transition to `active` and enqueues only the first bounded item-job batch. A sweeper schedules subsequent items in bounded batches. New uploads are admitted only after this point and use the new key.
5. A replacement that fails during preparation has not swapped keys and continues serving only the current key. Once the key-swap commit has occurred, while replacement is activating, active, or failed with either of those resume phases, every `/RPM-GPG-KEY` request for an owned repository with a configured fingerprint returns the previous and current public keys as two concatenated ASCII-armored blocks. Temporary repository/user fingerprint mismatch during activating is an explicit internal state covered by both-key serving and blocked mutations. An `enabled` repository remains enabled because every old or new package signature is covered by one of those blocks. Repositories created after activation use only the current key and do not delay this transition.
6. A transition-item worker claims its durable lease and fencing token, downloads the exact snapshotted source into a fresh attempt directory, preserves RPM v4/v6 format while re-signing with the target fingerprint, verifies all digests and the expected signature, and computes the new checksum, final size, header range, and metadata-size deltas. It creates or reuses its linked quota reservation for any positive byte delta, uploads to a fresh final key, and retains the returned version ID. Its fenced commit follows the global lock order, rechecks the transition/fingerprint, lease, source identity, metadata limits, and quota, then updates the package by compare-and-swap; adjusts counters and `users.storage_bytes`; consumes and clears the reservation; increments `metadata_revision`; marks the item succeeded; and enqueues metadata generation plus deletion of the previous exact version. A losing or stale worker deletes its candidate and cannot overwrite newer state.
7. Completion is evaluated solely from durable snapshots: every item must be succeeded or canceled because its package/repository was deleted, every repository snapshot must be applied or satisfied by deletion, and every surviving snapshot repository must have a metadata cache whose `source_revision` equals its current `metadata_revision`. The twentieth failed metadata-regeneration attempt for an affected repository also marks the transition failed with a sanitized `last_error_code` and `resume_status` equal to its current `activating` or `active` phase, so a permanently stale cache is visible outside Oban retention. Admin reset gives that regeneration a fresh budget and, for an activating failure, also resumes any pending repository-application batches. The completion transaction marks the transition completed and clears `previous_gpg_key_public` plus `gpg_key_transition_id`. A pre-swap failure retains the current key plus the encrypted candidate; a post-swap failure retains both public keys until an admin restores the recorded `resume_status` or the user chooses a removal escape hatch. Snapshot rows and items remain for audit.

Users can also explicitly revoke (remove) their GPG key without simultaneously replacing it. If the user has no repositories with `gpg_key_fingerprint` set or `sign_rpms = true`, `DELETE /api/v1/gpg_key` and the equivalent web UI action remove the key immediately.

When the user owns any affected repositories, `DELETE /api/v1/gpg_key` returns `409 conflict_gpg_key_in_use` with counts of metadata-signed and RPM-signed repositories. The web UI prompts the user to choose one of the same explicit strategies exposed by `POST /api/v1/gpg_key/revocation`:

- **Clear metadata signing** (`strategy: "clear_metadata_signing"`): Allowed only when none of the user's repositories have `sign_rpms = true`. It creates a durable `clear_metadata_signing` transition and returns `202 Accepted`. Preparation snapshots every affected repository in bounded batches; after both scans have explicit complete flags (the package scan is empty by definition), it changes the transition to `finalizing`. Finalization workers clear `gpg_key_fingerprint`, increment `metadata_revision`, mark each repository-snapshot row applied, and enqueue regeneration in bounded transactions; package rows and B2 objects remain intact. When no pending repository row remains, one small transaction removes the user's current/previous key material, fingerprints, expiry, and reminder state; clears `gpg_key_transition_id`; and completes the transition.
- **Delete signed packages** (`strategy: "delete_signed_packages"`): This creates a durable transition and returns `202 Accepted`; it never attempts an unbounded account-wide delete in the request transaction. Preparation snapshots all affected repositories and every current package in RPM-signed repositories in the same durable batches described above; only after both scans are explicitly complete does it change the transition to active. Each item performs the normal atomic package deletion, counter updates, metadata-revision bump, and exact-version cleanup enqueue. Explicit package/repository deletion remains allowed during this active phase and cancels/satisfies corresponding rows. When every item succeeded or was canceled by such deletion, the transition changes to `finalizing`; repository-application workers then clear fingerprints, disable RPM signing, bump metadata revisions, mark rows applied, and enqueue regeneration in bounded batches. Once no pending repository row remains, the same small user transaction used above removes key material and completes the transition. The current key (and, if escaping an active replacement, its previous key) remains served until that final commit, so repositories stay internally valid throughout removal. Empty and metadata-only repositories are covered by the snapshot.
- **Re-sign with a new key** (`strategy: "replace_key"`): The user uploads a new GPG key pair as part of the same multipart request, and the operation is processed as a replacement (see above) instead of a revocation.
- **Re-sign with a generated key** (`strategy: "replace_with_generated_key"`): Dark Zenith generates a new key pair server-side (see Server-side key generation), honoring the same optional `algorithm` selection and one-time private key reveal, and the operation is processed as a replacement (see above) instead of a revocation.

Standalone cancellation of a `replace_gpg_key` transition — the admin transition view's cancel action, which ends the transition while leaving key material in place — is allowed only before the key-swap commit, while `preparing` or `failed` with `resume_status = "preparing"`. There it nulls the encrypted candidate and leaves the current key, every repository fingerprint, and every package signature untouched. It is refused once the swap has committed (`activating`, `active`, or `failed` resuming either), because the user then already holds the new key while some repositories or packages may still carry the old one: ending the transition without finishing it would strand `previous_gpg_key_public`, which only a terminal completion or key removal clears, stop `/RPM-GPG-KEY` from serving both armored blocks, and leave old-key packages unverifiable in repositories whose generated `.repo` files set `gpgcheck=1`. After the swap the transition ends only by admin reset to its recorded `resume_status` and eventual completion, through a key-removal flow, or with the deletion of the owning account, which the repository-ownership precondition already means holds no repository using the key. Removal-driven cancellation stays available in every phase precisely because it does not leave a partial state behind: immediate deletion of a key no repository uses removes all current and previous key material, and either durable removal strategy drives repository settings and key material to a consistent end before releasing them.

Key removal remains an escape hatch from a stuck replacement. Immediate deletion when no repository uses the key cancels any unresolved replacement, nulls its prepared candidate, and cancels/releases unfinished items/reservations before removing key material. Either durable removal strategy first cancels an old replacement, then creates its own preparation transition against the still-current repository/package state; current key material is retained until the new transition's final commit. Leased workers observe canceled durable state and no-op. Preparation, activation, active work, and finalization crash tests cover every batch boundary, empty repositories, metadata-only repositories, write blocking, idempotent upserts, candidate cleanup, and resumption after node restart.

---

## Package Upload & Processing

An upload by a repository owner or admin has a control plane and a payload plane. The client first creates an Upload Intent with a display filename and exact byte length. Dark Zenith validates and reserves that declared size, then returns a short-lived presigned URL for one random private B2 staging key. The client sends one `PUT` with `Content-Type: application/x-rpm` directly to B2—without the Dark Zenith bearer token, cookies, or any B2 application credential—and reads `x-amz-version-id` from the response. It then completes the intent with that version ID. The app verifies the exact object version with `HeadObject`, and a durable Oban worker downloads and processes it. API intents queue final processing automatically after completion; web intents stop at a parsed preview until the user confirms. No RPM request body traverses Phoenix, its reverse proxy, or a Cloudflare zone in front of the app.

Uploads are limited to `MAX_RPM_UPLOAD_BYTES` bytes (default 512 MiB). Because the direct-transfer design uses one B2 S3-compatible `PutObject` request rather than multipart upload, the configured limit may not exceed B2's 5 GiB single-object-upload ceiling (5 368 709 120 bytes). Intent creation rejects a non-positive declared size with `422 validation_failed` and an oversized declaration with `413 payload_too_large`, before issuing a URL or creating a staging object. Completion requires the exact B2 object length to equal the declaration, so understating the size cannot evade either limit or quota. The client-supplied filename is reduced to its final path component, treating both `/` and `\` as separators; a filename that is empty after trimming, invalid UTF-8, contains control characters, or exceeds 255 characters is rejected with `422 validation_failed`. It is display-only and is never used as a filesystem path or storage key. A staged object that is not a valid RPM remains private and unreachable through any repository route, then is permanently deleted when processing rejects it.

Per-user storage is bounded by `MAX_USER_STORAGE_BYTES` (default 50 GiB; `0` disables the quota). `users.storage_bytes` is the transactionally maintained sum of final stored `size_package` values across repositories the user owns; uploads by an admin to another user's repository count against the owner. Intent creation authoritatively reserves the declared source size. After optional signing, the worker adjusts that reservation to the exact final `size_package` before writing the final object; an increase fails if concurrent use consumed the remaining quota. Package insertion consumes the reservation atomically, so concurrent intents cannot commit a permanent overshoot. A re-sign job reserves only a positive `(new_size - old_size)` delta before uploading and adjusts `storage_bytes` by the signed delta during its compare-and-swap package update; insufficient capacity leaves its durable transition item failed with `conflict_storage_quota_exceeded`. Deletions and size reductions always proceed and decrement `storage_bytes`. Admins can view stored and actively reserved bytes separately.

Upload processing and re-sign work that invokes RPM tools share one `rpm_processing` Oban queue on each node, with concurrency `RPM_PROCESSING_CONCURRENCY`. Immediately after its durable database claim and before downloading, every such worker atomically acquires a node-local temporary-space lease from a supervised ETS owner. The reservation is `3 * source_size + 67108864` bytes — `declared_size` for an upload and the current package `size_package` for a re-sign — and succeeds only when the filesystem's sampled available bytes minus all active leases can cover it. Claims that cannot reserve space return through Background Retry Policy as `upload_temp_space_unavailable`; they do not ask the client to upload again.

The lease is keyed by the durable claim's lease token, monitors the worker process, and is released on `DOWN` as well as in the worker's normal `after` path. A periodic reconciler removes leases whose process/claim no longer exists and compares the ledger with the node's app-owned attempt directories; node restart starts with an empty ETS table and the existing symlink-safe directory janitor removes leftovers before they can be mistaken for reservations. Each claim uses a new mode-`0700` directory under the node-local `RPM_UPLOAD_TMPDIR`; source and derived files use mode `0600`. The worker streams only the recorded exact B2 version, stops if measured bytes differ from its expected source size, and removes the directory after success, failure, interruption recovery, or lease loss. `ENOSPC` remains retryable even after reservation because other processes can consume the filesystem. Concurrency tests barrier-start more workers than capacity permits and prove that the atomic ledger never overcommits, reclaims crashed leases, and lets a later claim proceed.

The HTTP status/code pairs named in the processing steps define the public error classification, not the already-returned completion response. Synchronous intent creation/completion validation uses those HTTP statuses directly. Once processing has been accepted with `202`, a deterministic or exhausted failure sets `status = "failed"` and places the same code in the upload-intent resource while status polling itself remains `200`, as defined in the API contract.

1. **Validate structure and format**: Confirm the lead magic and parse the signature and main headers. Dark Zenith accepts RPM format v4 and v6 and rejects v3 or unknown formats with `422 validation_failed`. A v6 package must carry main-header `RPMFORMAT = 6`, `ENCODING = "utf-8"`, and every signature/header tag that the supported RPM 6 format marks mandatory. In particular, its signature has the immutable region, SHA-256, SHA3-256, and final zero-filled `RESERVED` entries but no size/payload or tag-above-999 entries; its main header uses the v6 long file/installed sizes, a file-digest algorithm of at least SHA-256, and the required compressed/uncompressed payload digest and size pairs. Both headers have strictly increasing unique tag numbers, correct physical types/counts, in-bounds aligned data references, and zero-filled padding. A v4 package has the v4 immutable header structures and either no physical `RPMFORMAT` tag or `RPMFORMAT = 4`; it must carry a valid SHA-256 header digest and a SHA-256 compressed-payload digest in the RPM 4.14+ form. A weak-only v4 package whose integrity depends on MD5 or SHA-1 is rejected with `422 validation_failed`, even if a locally configured RPM would accept it. A v3 header+payload package is never inferred as v4. For parser differential safety, v4 headers with duplicate physical tag numbers or overlapping/out-of-bounds data references are rejected even if a legacy RPM reader would tolerate them. Both binary and source RPMs are accepted. The lead's non-magic fields are historical and are not used to classify it; a nonzero main-header `SOURCEPACKAGE` tag identifies a source package, and an absent or zero value identifies a binary package. While reading, the parser enforces structural bounds: the combined signature and main header regions must not exceed 64 MiB (67 108 864 bytes) and each header must not exceed 65 535 index entries; files exceeding either bound are rejected before further parsing.
2. **Verify integrity**: Invoke RPM 6's `rpmkeys --dbpath <temporary-rpmdb> --checksig --verbose` directly with `LC_ALL=C` against the unchanged uploaded file. Dark Zenith does not weaken the host's verification level or flags to admit legacy digests. The temporary RPM database is empty when `sign_rpms = false`; every available header and payload digest must report `OK`, an absent signature or `NOTFOUND` signer is permitted, and any `BAD` digest or signature is rejected with `422 validation_failed`. When `sign_rpms = true`, the owner's public key is imported first so signatures already made with the configured key are genuinely verified rather than reported `NOTFOUND`; the acceptance rule is otherwise identical — unsigned input and `NOTFOUND` (third-party) signers are permitted, because every existing package signature is replaced during re-signing and the post-signing verification under GPG Signing enforces the configured key on the final bytes — and any `BAD` digest or signature is still rejected with `422 validation_failed`. A completed verifier result that violates these rules is a validation error. Inability to create the isolated RPM database or execute a boot-validated RPM 6 verifier returns `503 rpm_verification_unavailable`. The verifier database is removed after the attempt.
3. **Extract metadata**: Parse the RPM headers directly in Elixir. Required metadata is `name`, `version`, `release`, `arch`, `summary`, `description`, `license`, and `size_installed`; `epoch` defaults to `0` when absent. `summary`, `description`, and `rpm_group` are RPM internationalized strings: Dark Zenith matches the literal `C` entry in `HEADERI18NTABLE`, falling back to its first entry exactly as RPM does when no requested locale matches, and rejects inconsistent locale/value counts. A `HEADERI18NTABLE` physically stored as a single `STRING` instead of a `STRING_ARRAY` — as builders outside rpm itself emit, notably `rpm-rs`/`cargo-generate-rpm` — is read as the one-locale table it is, which is also what rpm resolves it to; any other physical type rejects the package. For v4, `size_installed` uses physical main-header `LONGSIZE` then `SIZE`, while `size_archive` uses signature-header `LONGARCHIVESIZE` then `PAYLOADSIZE` and is `NULL` if both are absent. For v6, `LONGSIZE` is required for installed size, required uncompressed `PAYLOADSIZEALT` supplies `size_archive`, and size/payload tags in the signature header are illegal. Optional `url`, `rpm_group`, `rpm_vendor` (`VENDOR`), and `rpm_buildhost` (`BUILDHOST`) values are `NULL` when absent or empty after trimming; `build_time` uses the unsigned 32-bit `BUILDTIME` timestamp or is `NULL` when absent. Dependency, file, and changelog collections default to empty arrays. Dependency lists are normalized to `createrepo_c`'s output rules at extraction, so the stored collections, API subresources, and generated metadata always agree: `requires` entries carrying the `RPMSENSE_RPMLIB` flag or a name beginning with `rpmlib(` are excluded, since no package provides RPM's internal capabilities and emitting them would make every package unresolvable, and exact duplicate `requires` entries — same name, operator, epoch/version/release, and `pre` value — are collapsed to their first occurrence, preserving the order of the survivors; the other seven lists are stored as the header provides them. Weak dependencies are first-class: `recommends`, `suggests`, `supplements`, and `enhances` are read from the `RECOMMENDNAME`/`RECOMMENDVERSION`/`RECOMMENDFLAGS`, `SUGGESTNAME`, `SUPPLEMENTNAME`, and `ENHANCENAME` tag triplets with the same entry shape and parallel-array validation as the hard lists; they carry no `pre` value, and the legacy `OLD*` weak-dependency tags are not read. A `requires` entry's `pre` is true when its flags carry any of `RPMSENSE_PREREQ`, `RPMSENSE_SCRIPT_PRE`, `RPMSENSE_SCRIPT_POST`, `RPMSENSE_PRETRANS`, or `RPMSENSE_POSTTRANS`, the same set `createrepo_c` treats as pre-transaction. An entry in any dependency list whose name begins with `(` is a rich (boolean) dependency: the header supplies it without version-comparison flags or a version, and it is stored as an unversioned entry whose `name` is the complete parenthesized expression, left for supported clients to parse; a rich entry that does carry version-comparison flags or a version is malformed and rejects the package. Fixture packages with rpmlib requirements, duplicate requires, rich dependencies, and entries in every weak-dependency list assert that the stored collections and generated `primary.xml` match `createrepo_c` output for the same package. Every parallel RPM mapping used to construct those collections must have matching cardinality and every dictionary index must be in range; malformed dependency flags/versions, file triplets, MIME/flag arrays, or changelog arrays reject the package rather than being truncated or padded.

   For a v4 binary package, `rpm_sourcerpm` uses `SOURCERPM` and `rpm_sourcenevr` is null. A v6 binary package requires `SOURCENEVR`; Dark Zenith stores it exactly in `rpm_sourcenevr` and derives `rpm_sourcerpm` for standard repodata by parsing its name-[epoch:]version-release, removing the epoch component, and appending `.src.rpm`. A malformed or non-round-trippable `SOURCENEVR` is rejected. For source packages, `arch` is stored as literal `src`, the physical `ARCH` tag is ignored and not required, the file list contains bare source/spec names, and both source-reference fields are null. Binary packages whose physical `ARCH` is `src` are rejected.

   Validate `epoch` in `0..4 294 967 295`; validate installed/archive sizes against the Packages signed-bigint ranges; require `name`, `version`, `release`, and `arch` to match `^[A-Za-z0-9._+~-]+$` and be at most 256 characters. That character set deliberately excludes `^`, which RPM 4.14+ permits in version/release for snapshot ordering: a package carrying a caret in any NEVRA field is rejected with `422 validation_failed`, keeping storage keys, download paths, and generated filenames free of URI-unsafe characters, while the PostgreSQL EVR comparator still implements full caret semantics for conformance with the upstream algorithm. Apply all other Packages-table limits (`summary` 256, `description` 65 536, `url` 256, `license` 256, both source-reference fields 800, and group/vendor/buildhost 256, after trimming). A non-empty `url` must be absolute HTTP or HTTPS. Every extracted string, including collection members, must be valid UTF-8 and contain only XML 1.0-representable characters. The single-line fields — `summary`, `license`, `url`, `rpm_group`, `rpm_vendor`, `rpm_buildhost`, `rpm_sourcerpm`, and `rpm_sourcenevr` — are additionally rejected when they contain any ASCII control character, mirroring the single-line rule for user-provided API strings; `description` and changelog text may contain newlines and tabs but no other control characters. Reject more than 262 144 files, 4 096 changelogs, or 65 536 entries in any one dependency list. Finally, reject a composed final B2 key over 1 024 UTF-8 bytes, using the full package UUID, fresh write UUID, and sanitized filename template; initial writes and re-sign attempts use the same worst-case template.
4. **Sign** (if `sign_rpms` is enabled): Before choosing the signed or unsigned path, snapshot the repository's current `sign_rpms` value. When it is enabled, also snapshot the repository's primary fingerprint and the owner's exact signing fingerprint, public key, and effective expiry; sign with that exact key and `rpmsign`, then run the required expected-key verification described under GPG Signing. The final transaction fences this snapshot so an upload that raced with signing enablement, disablement, key replacement, or key removal cannot commit bytes produced under superseded settings.
5. **Calculate final values**: Compute SHA-256, `size_package`, `header_start`, and exclusive `header_end` from the final bytes after signing. Signing rewrites the signature header and moves the main header, so pre-signing offsets are never persisted. For the same reason a v4 package's `size_archive` is re-read from the final signature header's `LONGARCHIVESIZE`/`PAYLOADSIZE`, and stays `NULL` when the final header carries neither: the stored row must describe the stored bytes rather than the staged source, whether or not `rpmsign` happens to preserve those tags. A v6 package's `size_archive` comes from main-header `PAYLOADSIZEALT`, which signing does not rewrite, so its extracted value is reused unchanged. Signing never alters the uncompressed payload, so any re-read value is expected to equal the pre-signing one; a v4 package that gains or loses the tag across signing is recorded as the final bytes describe it. If signing makes the final file exceed `MAX_RPM_UPLOAD_BYTES`, fail the intent deterministically with `payload_too_large`; persisted package size always obeys the same ceiling as the staged source.
6. **Enforce repository metadata limits**: Encode the candidate package's deterministic metadata fragments to a counting sink and perform an advisory check against the repository counters. The final transaction repeats the check while holding the repository lock and fails the intent with `conflict_repository_metadata_limit_exceeded` if the projected package count or any uncompressed metadata artifact crosses its configured limit.
7. **Duplicate check**: Perform an advisory lookup for `(repository_id, name, epoch, version, release, arch)`. The final locked check and database unique constraint are authoritative; a conflict fails the intent with `conflict_duplicate_package`.
8. **Adjust quota reservation**: Lock the owning user and reservation, renew the reservation, and change `reserved_bytes` from the declared source size to the exact final `size_package`. A required increase that no longer fits fails with `conflict_storage_quota_exceeded`; a decrease releases capacity immediately.
9. **Write and verify a fresh final version**: Compose a key `repos/:slug/packages/:package_id/:write_id/:name-:epoch-:version-:release.:arch.rpm`, where `package_id` came from the intent and `write_id` is a fresh UUID for this attempt. For an unsigned package, issue server-side `CopyObject` from the exact staging version with `MetadataDirective=REPLACE`; for a signed package, `PutObject` the verified local output. Either path sets only `Content-Type: application/x-rpm` and no user metadata or other content headers. If the B2 S3 integration cannot prove that a version-aware copy both selects the exact source and replaces metadata, the unsigned path falls back to `PutObject` of the already validated local bytes. Retain the returned final version ID, then perform an exact-version `HeadObject` and require the calculated final length, the exact content type, and the same empty forbidden-metadata set used at upload completion. A mismatch permanently deletes the candidate and follows the retryable `storage_unavailable` path; no database row may reference an unverified candidate. SDK automatic retries are disabled for these non-idempotent writes: an ambiguous attempt is abandoned to the reconciler, and a retry always chooses a new `write_id` rather than writing another version at an uncertain key.
10. **Fenced record and consume**: In one transaction, lock the owner, repository, upload intent, and reservation in the global order; require `status = "processing"` and the claim's current `lease_token`; recheck that the initiating user is still the repository owner or an admin plus every duplicate, metadata, transition, and quota invariant; and require `sign_rpms` plus, when signing is enabled, the repository primary fingerprint and owner signing fingerprint/public key to match the attempt's snapshot. The transaction also rechecks that a snapshotted signing key has not expired while the attempt was running. It then inserts the package with its key and version ID; updates repository metadata counters and `metadata_revision`; increments `users.storage_bytes`; consumes and clears the reservation; marks the intent `succeeded`; and enqueues metadata regeneration plus deletion of the exact staging version. A signing-setting or fingerprint mismatch deletes any candidate final version, atomically restores the intent's pre-claim attempt count, returns it to `queued` with `next_attempt_at = now()`, and schedules a unique job so a fresh non-failure attempt uses current settings; a key that has crossed its expiry fails with `conflict_gpg_key_expired`. If authorization, the token, or any other compare-and-swap predicate has been lost, this attempt cannot commit.

Deterministic validation, final-size, authorization (recorded as `forbidden`), duplicate, metadata, expired-key, and quota errors make the intent terminally `failed`, release its reservation, and enqueue staging cleanup. Unavailable `rpmkeys`, `rpmsign`, `gpg`, temporary space, database, or B2 operations are retryable under the Upload Intents lease policy; the immutable staging source and reservation remain available between attempts. After 20 failed claims the intent becomes terminally failed with the applicable sanitized code (`rpm_verification_unavailable`, `signing_unavailable`, `upload_temp_space_unavailable`, `storage_unavailable`, or `internal_error`). If final B2 writing succeeds but the fenced database transaction loses a race, Dark Zenith permanently deletes that exact candidate `(key, version_id)` and follows the relevant retry or terminal path; failed immediate deletion is handled by an idempotent version-aware cleanup job. If package insertion succeeds but metadata regeneration fails, the upload remains successful and regeneration retries until the cache reaches the latest revision.

Package deletion first enforces the user-wide phase blocking rules above. When allowed, it locks the owner, repository, package, affected signing transitions, unfinished transition items, and linked reservations in the global order; marks those items canceled and releases their reservations; removes the package row; decrements metadata counters and `users.storage_bytes`; increments `metadata_revision`; and enqueues metadata regeneration plus version-aware B2 deletion in one database transaction. If B2 deletion fails, the package no longer appears in metadata or API responses, and package-ID download URLs no longer resolve, but cleanup retries. Previously issued signed B2 URLs may remain usable until they expire or until that exact object version is deleted, whichever happens first.

Repository deletion is a hard delete and is blocked during the user-wide phases identified under Signing Transition Repositories. Once allowed, an authorized owner or admin reads every package `(storage_path, storage_version_id)` and every upload intent's `(staging_path, staging_version_id)` when present; locks the owner, repository, package rows, transition/items/snapshot rows, upload intents, reservations, and live slug reservation in that order, with each bulk class ordered by UUID; then deletes the repository row and dependent packages, collaborators, invitations, metadata cache, upload intents, and active storage reservations, decrements the owner's `storage_bytes`, marks repository-local active or failed signing transitions and every pending, executing, or failed item for that repository canceled (including items in user-wide replacement or signed-package-deletion transitions), marks matching pending repository snapshots `satisfied_deleted`, releases linked reservations, cancels workers through durable state, and retires the slug reservation in one database transaction. Signing-transition, repository-snapshot, and item rows are retained for audit: their repository references are UUID snapshots rather than foreign keys, so the hard delete does not remove them. It returns `204 No Content` after commit. Exact final and staging B2 versions are deleted after commit through idempotent cleanup jobs. Failed cleanup leaves the repository inaccessible while retries continue. Previously issued signed URLs may work until expiry or permanent version deletion. Pending jobs that find the repository gone complete as no-ops.

Backblaze B2 buckets retain object versions, so every successful PUT or copy's returned version ID is part of the object's storage identity. Final RPM keys are write-once: Dark Zenith never intentionally writes a second version at the same key, including after an ambiguous result. Cleanup calls S3 `DeleteObject` with a version ID; deleting by key alone is forbidden because it would create a delete marker without reclaiming older storage. A daily final-object reconciler paginates `ListObjectVersions` under `repos/`, compares `(key, version_id)` pairs with package rows, and permanently deletes unreferenced versions and delete markers older than 24 hours. An hourly staging reconciler scans `staging/uploads/`: it preserves every version at the current key of an unexpired `awaiting_upload` intent, the accepted exact version of an active `queued`, `processing`, or `preview_ready` intent, and versions younger than two hours that may belong to an in-flight transfer; it deletes everything else. These grace periods protect writes that completed immediately before a process crash or database commit while still bounding replayed presigned URLs. The B2 application key must permit listing versions and deleting specific versions in addition to normal read/write/copy access. Operators may keep only the latest version at write-once final keys as lifecycle defense in depth, but must not apply an age-based lifecycle deletion to `staging/uploads/`: the database and exact-version reconciler are authoritative, and a blanket rule could delete the durable source of a legitimately delayed retry.

### RPM Parsing

For metadata extraction, rather than querying metadata through `rpm` or `rpm2cpio`, Dark Zenith includes a pure-Elixir parser for RPM format v4 and v6. Format v3 and unknown future formats are rejected. Both accepted formats share four logical sections:

- **Lead** (96 bytes): Magic number plus historical fields. The magic is used for quick validation; source-package detection uses the main header's `SOURCEPACKAGE` tag rather than the historical lead type.
- **Signature header**: Contains signatures and header digests; v4 also carries legacy size and header+payload digest fields, while v6 forbids size/payload fields here.
- **Main header**: Contains all package metadata as tagged entries (name, version, dependencies, etc.) using a well-defined set of tag constants.
- **Payload**: The compressed cpio archive (not needed for metadata extraction).

The parser reads the lead, signature, and main header sections and does not decompress the payload for metadata extraction. It enforces the structural and format-specific invariants defined in the upload pipeline, including v6 sorted/unique tags and zero padding. Integrity verification is deliberately delegated to boot-validated RPM 6 `rpmkeys`, which streams the complete package and verifies the header and payload digests that apply to its format. Signing uses RPM 6 `rpmsign`; Dark Zenith never mutates RPM signatures itself.

Parser/verifier fixtures include strongly digested accepted v4/v6 packages and v4 variants that omit SHA-256 header or payload coverage, declare MD5/SHA-1-only coverage, carry a mismatched strong digest, or would pass only after weakening RPM verification flags. The weak variants are rejected in normal and FIPS-mode test profiles.

---

## Web Interface

The web UI is built with Phoenix LiveView. Public pages are accessible to everyone; actions that modify data (creating repos, uploading packages) require authentication and the matching authorization checks. All user- and RPM-derived strings are rendered as plain text with standard HTML escaping — never as raw HTML — and the package `url` is the only RPM-derived value rendered as a hyperlink (restricted to `http`/`https` at upload validation).

Every web page renders a footer showing the application name and version plus a `Source` link and the license identifier `AGPL-3.0-or-later`. The link target comes from the `SOURCE_URL` configuration entry and is how a deployment offers Corresponding Source to network users under AGPL §13: the default points at the upstream project repository, and operators running a modified version must set `SOURCE_URL` to the source of the code they actually run.

### Landing Page (`GET /`)

- Brief description of what Dark Zenith provides.
- Links to available repositories.

### Repository List (`GET /repos`)

- Browse public repositories with name, description, and package count; authenticated users also see private repositories they can access.
- Authenticated users see a "Create New Repo" action.

### Search (`GET /search`)

Instance-wide search over repositories and packages. Every web page's top navigation renders a package search field that submits to this page, and the page repeats the field for refining the query. The page is public; anonymous requesters see only public data per the visibility rule below.

- **Query execution is submit-driven.** The query lives in the URL as `?q=...` (plus `?page=...` for package-result pages), so results are addressable, reloadable, and shareable; queries are never executed per keystroke. Each executed query — the initial HTTP request or a subsequent query-submit LiveView event — consumes the search rate-limit bucket described under Rate Limiting.
- **Query semantics**: `q` is trimmed and capped at 256 characters and uses the same case-insensitive literal-substring `ILIKE` matching — with `%`, `_`, and the escape character escaped — as the package-list filters under API Contract Details. A blank or absent `q` renders the page with no results and a prompt rather than an error; the page never enumerates the instance without a query. An over-long `q` renders the standard validation error.
- **Visibility is identical to repository browsing**: anonymous requesters search public repositories only; authenticated users additionally search private repositories they own or collaborate on; admins search all repositories. Results are filtered, never masked: a repository the requester cannot access contributes nothing to any result group or count, so search never reveals the existence, slug, name, or package contents of an inaccessible private repository. Authorization tests must cover this boundary for anonymous, unrelated-user, collaborator, owner, and admin requesters.
- **Result groups**, rendered repositories first:
  - **Repositories** whose slug, name, or description matches `q`: slug, name, description, and visibility per row, linking to the repository detail page. The group shows the first 20 rows in the repository default ordering (slug ascending, then id ascending) plus the total match count when more matched; it does not paginate — users refine the query instead.
  - **Packages** whose name or summary matches `q` (the same fields the per-repository package filter matches): name, EVR, arch, repository slug, and summary per row. Rows are package builds linking to their package version detail page, with the repository slug linking to the repository. Ordering is `name` ascending, `arch` ascending, RPM EVR descending, repository slug ascending, then `id` ascending, paginated 50 per page with the page in the URL.
- When both groups are empty, the page renders the standard empty state.

### Create Repository (authenticated, `GET /repos/new`)

- Form to create a new repository: name, slug, description, public/private, GPG signing settings (enable metadata signing, enable RPM auto-signing).

### Repository Detail (`GET /repos/:slug`)

- Repository description and status.
- **Setup instructions** with copy-paste `dnf` commands for adding the repo to the user's system:
  - `.repo` file contents to place in `/etc/yum.repos.d/`.
  - For public repos: unauthenticated config shown by default, with an authenticated variant (Basic Auth with a `password=<api-key>` placeholder; any of the user's active API keys with at least one valid scope works) recommended for higher rate limits.
  - For private repos: instructions show the Basic Auth configuration with a `password=<api-key>` placeholder to be filled with one of the user's API keys carrying `repo:read`, plus a `chmod 600` step for the resulting file, since it will embed the key and `/etc/yum.repos.d/` files are world-readable by default. Because the server stores only key hashes, it can never render an existing key's plaintext; the one exception is key creation — when the user creates an API key from this flow, the creation response may render the snippet with the just-created plaintext key filled in, exactly once. If the user has no suitable API key, prompt them to create one.
  - One-liner `config-manager` command, shown only for public repositories, in both supported client syntaxes, since DNF 5 replaced the DNF 4 flag with an `addrepo` subcommand: DNF 4 uses `dnf config-manager --add-repo https://<hostname>/repos/:slug/dark-zenith.repo` and DNF 5 uses `dnf5 config-manager addrepo --from-repofile=https://<hostname>/repos/:slug/dark-zenith.repo`. `config-manager` fetches the `.repo` file without credentials and cannot supply Basic Auth, and for a private repository the downloaded file would hold only credential placeholders. Private-repo instructions rely on the copy-paste `.repo` block and `chmod 600` step above.
  - GPG key import instructions (if applicable).
- **Package list**: Searchable, sortable table of packages in this repo (name, EVR, arch, summary). EVR displays as `epoch:version-release` when `epoch` is nonzero and as `version-release` otherwise.
- Repository owners and admins see an "Upload RPM" action.
- **Owner/admin only**: "Manage Collaborators" section to add/remove users who can access a private repo.
  - For public repositories, existing collaborators and pending invitations are still listed and removable (they are dormant while the repository is public), but adding new ones is disabled.
  - Removing a collaborator stops new private-repository reads immediately. The confirmation warns that any B2 download URL already issued to that user remains usable only for its existing signed lifetime, as described under Security Considerations.
  - Adding a collaborator by the repository owner's email is rejected with `422 validation_failed`.
  - Additions that would create a new collaborator or invitation row past `MAX_REPOSITORY_COLLABORATORS` are rejected with the quota error described under Repository Collaborators.
  - Adding a collaborator whose normalized email already has a collaborator row or pending invitation is idempotent; the UI shows the existing row instead of creating a duplicate. A failed registered-collaborator notification queues a new direct-link generation; queued and sent notifications are not duplicated. An unexpired invitation queues a new delivery generation only when its notification is `failed`, or when it is `suppressed` and registration has since been enabled. Expired-but-uncleaned invitations are refreshed with a new expiration and a new notification generation, either queued or suppressed under the registration-disabled rule in Repository Collaborators. Collaborators and pending invitations display their notification status; invitations also display expiration.

### Repository Settings (owner/admin, `GET /repos/:slug/settings`)

- Edit repository settings: display name, description, public/private visibility, metadata signing, and RPM auto-signing. The slug is immutable after creation. Enabling RPM auto-signing on a repository that already has packages prompts for the same explicit re-sign confirmation as the API's `existing_package_strategy = "resign"` (see GPG Signing).
- While `rpm_signing_state = "signing"`, the page shows the enable transition's progress as pending, succeeded, and failed re-sign item counts. When the transition is `failed`, the page shows its sanitized `last_error_code` and the packages whose items failed, and explains the remediation paths — an admin resets the failed items or the exhausted metadata regeneration, or the owner deletes the affected packages, which cancels their items (see GPG Signing) — so a stuck transition is distinguishable from a slow one. The API surface is unchanged: the repository resource exposes only `rpm_signing_state`.
- Changing a public repository to private stops new anonymous reads immediately; its confirmation explains that previously issued signed B2 download URLs remain valid until their existing expiration.
- Delete the repository after an explicit confirmation, following the hard-delete flow described under Package Upload & Processing.

### Package Detail (`GET /repos/:slug/packages/:name`)

- Lists all versions/architectures available for this package name.
- For each package build: EVR, arch, summary, size, upload date. EVR uses the same `epoch:version-release` display rule as repository package lists.
- **Install instructions**: `dnf install <package>` command (assumes the repo is already configured). Names whose builds include source packages (arch `src`) also show a `dnf download --source <package>` command; when only source builds exist, the install command is omitted, since source packages cannot be installed directly.
- Links to individual package version pages, keyed by package UUID.

### Package Version Detail (`GET /repos/:slug/package-versions/:id`)

- Full package metadata: name, epoch, version, release, arch, summary, full description.
- Counts for requirements, provided capabilities, conflicts, obsoletes, the four weak-dependency lists (recommends, suggests, supplements, enhances), files, and changelogs. Each collection is a lazy-loaded, paginated tab backed by the corresponding REST subresource; the initial LiveView state never contains all entries.
- Direct download link to the app's package download endpoint, which redirects to a signed B2 URL.

### Upload RPM (owner/admin, `GET /repos/:slug/upload`)

- Drag-and-drop or file picker to upload an RPM to the selected repository.
- **Direct transfer**: Selecting a file creates a `web_preview` Upload Intent using the browser-reported name and exact `File.size`. The browser then sends that `File` directly to the returned B2 URL with `Content-Type: application/x-rpm`, allowing the user agent to supply the signed `Content-Length`; it never posts RPM bytes to Phoenix or through Cloudflare. On B2 success it reads the CORS-exposed `x-amz-version-id` response header and completes the intent. An interrupted transfer restarts from byte zero on the same still-valid URL; after that URL expires, refresh supplies a new random staging key and URL.
- **Preview**: Completion verifies the exact staged version and queues durable preview processing. The LiveView shows `queued`/`processing` progress and receives or polls the intent status; a disconnect does not cancel the job. The worker size-checks, validates, and parses the RPM using the normal pipeline, performs advisory duplicate and repository-metadata-limit checks, stores the extracted metadata on the intent, and changes it to `preview_ready` for 15 minutes. No package row or repository-referenced final B2 object exists yet; the private exact staging version is the durable source.
- **Confirm**: Confirmation identifies an unexpired `preview_ready` intent, which is always scoped to the same repository and initiating user, then reauthorizes that user as the repository's current owner or an admin. It changes `preview_ready` to `queued` and enqueues final processing in one transaction. A fresh attempt downloads and revalidates the same exact staging version, requires its extracted metadata to equal `preview_metadata` (a mismatch — possible only if extraction behavior changed between releases — fails the intent deterministically with `validation_failed`), optionally signs it, and performs the final duplicate, metadata, quota, B2, and package transaction. A browser disconnect, app restart, or interrupted signing attempt is recovered by the lease sweep without asking the user to upload again. A user who no longer has upload permission receives the normal repository-scoped authorization or masking response and cannot confirm the intent.
- **Expiration and cancellation**: An expired, canceled, failed, or already consumed preview cannot be confirmed. Waiting-state cleanup releases its reservation and deletes the exact staging version; the UI shows a terminal error and asks the user to start a new upload. A missing node-local working file is never terminal because a retry reconstructs it from B2.
- **Web only**: Preview-and-confirm is a web presentation choice. The REST package-upload endpoint fixes intents to `api` mode, which proceeds from completion to final processing without a confirmation pause.

### GPG Key Management (authenticated, account settings)

- Upload a GPG key pair (public + private) to the user's account. Uploading a new pair when one already exists creates the durable preparing replacement described under GPG Signing. The page immediately shows preparation/re-sign progress from its transition resource and continues to show the current key until activation.
- Generate a key pair server-side instead of uploading one: an algorithm selector (Ed25519 default plus the other allowlisted algorithms) with the same first-key/replacement semantics as upload. The page shows the generated ASCII-armored private key exactly once, with a download link and a warning that it can never be shown again; leaving or reloading the page discards it.
- View the primary fingerprint, exact signing fingerprint, signing-key expiration, and public key of the currently uploaded key. The page warns at the same 30-, 7-, and 1-day thresholds used for reminder mail and displays a blocking error after expiration.
- Remove the existing GPG key. If any owned repositories have `gpg_key_fingerprint` set or `sign_rpms = true`, the UI prompts the user to clear metadata signing, delete RPM-signed packages, or upload a replacement key as part of the same flow.
- Passphrase-protected private keys are rejected; users should upload a dedicated repository-signing key or have Dark Zenith generate one.

### Authentication Pages

- Login / logout.
- Account registration (when enabled).
- Password reset and email confirmation (including resending the confirmation email), via the standard `phx.gen.auth` flows. The password reset completion page additionally lists the account's active API keys with a one-click option to revoke them all (see Session Tokens).
- Account email change, via the standard `phx.gen.auth` settings flow (see User Lifecycle).
- API key management for the authenticated user. Revocation confirmation explains that it prevents new authorization immediately but cannot revoke a signed B2 download URL that was already issued.

### Admin (admin-only)

- **User management**: List users; create users (created accounts are auto-confirmed and no confirmation email is sent, mirroring the bootstrap admin); grant or revoke `is_admin` on other users (never their own — see User Lifecycle); delete users, which is rejected while the target user still owns repositories (the web equivalent of the `409 conflict_user_owns_repositories` rule). The user list shows each user's storage usage against `MAX_USER_STORAGE_BYTES`, repository count against `MAX_USER_REPOSITORIES`, and stored API-key count against `MAX_USER_API_KEYS`, highlighting grandfathered over-limit values without disabling deletion/remediation.
- **Background jobs**: An admin-only view of Oban jobs (for example, a mounted Oban dashboard) for inspecting, retrying, or discarding the failed and exhausted jobs that the admin-intervention flows in this document rely on.
- **Signing transitions**: A durable transition/repository/item view independent of Oban retention, showing phase cursors/attempts/next run, target repository/user, status/resume phase, item attempts, leases, sanitized last errors, and affected packages. After fixing a phase or metadata-regeneration failure, an admin can restore its recorded `resume_status` with a fresh 20-attempt budget and schedule the next phase batch and/or affected regeneration job. After fixing an item failure, an admin can reset selected failed items to `pending`; the transaction records their prior attempt counts in the audit event, sets `attempts = 0` and `next_attempt_at = now()`, clears lease/terminal error/completion fields, returns a failed active transition to `active` only when no failed items remain, and enqueues unique item jobs for the reset rows. Admins can also cancel a preparing, activating, active, finalizing, or failed transition when the corresponding repository setting or key-removal flow permits it; cancellation clears prepared candidates and linked reservations. A `replace_gpg_key` transition is the exception: once its key-swap commit has occurred the cancel action is unavailable and the view offers only reset/resume, because ending a post-swap replacement without finishing it leaves repositories and packages split across two keys (see Key replacement and revocation). Resets and cancellations require explicit confirmation and are audited; retrying an Oban row alone never changes durable application state.
- **Audit log**: Read-only, filterable view of audit events (actor, action, target, time).
- **Slug reservations**: List retired slug reservations created by repository deletion and release individual retired slugs for general reuse; releases are audited. Live reservations are visible for diagnosis but cannot be released.

---

## REST API

The REST API provides programmatic access to repository operations. Authentication is via `Authorization: Bearer <token>` header, where the token is either an API key or a short-lived session token obtained from the login endpoint. API endpoints also accept session cookie authentication (as used by the web UI), which allows the web frontend to call API endpoints directly and enables users to create their first API key without already having one. When both an `Authorization: Bearer` header and a session cookie are present on the same request, the `Authorization` header takes precedence; the session cookie is ignored for that request.

Read-only endpoints for public repos are unauthenticated.

Repository-scoped mutating API endpoints require either session token/cookie authentication or an API key with the matching scope. Repository-scoped mutations also require the authenticated user to be the repository owner or an admin.

Every package-upload intent endpoint, including status reads, additionally requires the same authenticated user who created the intent; API-key requests require `package:upload`. A second admin cannot take over another user's staged capability: an intent whose initiating `user_id` is not the authenticated user is treated as nonexistent and answered with `404 not_found`, exactly like an id scoped to a different repository. Repository deletion remains able to cancel all intents as a system-side consequence of deleting their target.

Account-management API endpoints for API keys, GPG keys, and GPG transitions require session token or session cookie authentication. API key credentials are not accepted for `/api/v1/api_keys` or any `/api/v1/gpg_key...` route; requests authenticated only by API key return `403 forbidden`.

### Authentication

```
POST   /api/v1/auth/login               # Login with email + password, returns a short-lived session token
DELETE /api/v1/auth/logout              # Invalidate a session token
```

The login endpoint accepts `{"email": "...", "password": "..."}` and returns a short-lived bearer token (24-hour expiration). This token is distinct from API keys — it cannot be managed via the API keys endpoints, expires automatically, and is intended for interactive/CLI use. API keys remain the preferred mechanism for long-lived programmatic access.

Account registration, email confirmation, password reset, and account email change are web-only flows generated by `phx.gen.auth`; they have no REST API equivalents. Rate limits on those flows apply to the corresponding web routes.

A successful login responds with `200 OK` and the body:

```json
{
  "data": {
    "token": "dzst_<secret>",
    "expires_at": "2025-01-16T10:30:00Z"
  }
}
```

Failed logins return `401 unauthenticated` with no further detail (to avoid distinguishing unknown email from wrong password).

`DELETE /api/v1/auth/logout` invalidates the session token presented in the `Authorization` header and responds `204 No Content`. If the request is authenticated by an API key (or by a session cookie) rather than a session token, the server responds `403 forbidden` — only session tokens can be invalidated through this endpoint. API keys are revoked via `DELETE /api/v1/api_keys/:id`.

### Repositories

```
GET    /api/v1/repos                    # List public repositories and private repositories visible to the requester (admins see all repositories)
POST   /api/v1/repos                    # Create a repository (auth required)
GET    /api/v1/repos/:slug              # Get repository details
PATCH  /api/v1/repos/:slug              # Update a repository (auth required)
DELETE /api/v1/repos/:slug              # Delete a repository (auth required)
```

### Packages

```
GET    /api/v1/repos/:slug/packages                         # List packages (paginated, filterable)
GET    /api/v1/repos/:slug/packages/:id                     # Get package details
GET    /api/v1/repos/:slug/packages/:id/requires            # List requirements (paginated)
GET    /api/v1/repos/:slug/packages/:id/provides            # List provided capabilities (paginated)
GET    /api/v1/repos/:slug/packages/:id/conflicts           # List conflicts (paginated)
GET    /api/v1/repos/:slug/packages/:id/obsoletes           # List obsoletes (paginated)
GET    /api/v1/repos/:slug/packages/:id/recommends          # List weak recommends (paginated)
GET    /api/v1/repos/:slug/packages/:id/suggests            # List weak suggests (paginated)
GET    /api/v1/repos/:slug/packages/:id/supplements         # List reverse-weak supplements (paginated)
GET    /api/v1/repos/:slug/packages/:id/enhances            # List reverse-weak enhances (paginated)
GET    /api/v1/repos/:slug/packages/:id/files               # List files (paginated)
GET    /api/v1/repos/:slug/packages/:id/changelogs          # List changelogs (paginated)
DELETE /api/v1/repos/:slug/packages/:id                     # Delete a package (auth required)
POST   /api/v1/repos/:slug/package-uploads                  # Create a direct-to-B2 upload intent (auth required)
GET    /api/v1/repos/:slug/package-uploads/:id              # Read upload processing state/result (auth required)
POST   /api/v1/repos/:slug/package-uploads/:id/refresh      # Replace an expired upload URL and staging key (auth required)
POST   /api/v1/repos/:slug/package-uploads/:id/complete     # Accept an exact B2 version and queue processing (auth required)
DELETE /api/v1/repos/:slug/package-uploads/:id              # Cancel an unfinished upload and clean up staging data (auth required)
```

### Search

```
GET    /api/v1/search/packages          # Instance-wide package search across repositories visible to the requester (paginated; non-blank `q` required)
```

### Collaborators

```
GET    /api/v1/repos/:slug/collaborators              # List collaborators and pending invitations (owner/admin only; API keys need `repo:read`)
POST   /api/v1/repos/:slug/collaborators              # Add a collaborator by email (owner/admin only; API keys need `repo:update`; idempotent for existing collaborators/invitations; creates pending invitation if user not registered)
DELETE /api/v1/repos/:slug/collaborators/:id           # Remove a collaborator by collaborator row id (owner/admin only; API keys need `repo:update`)
DELETE /api/v1/repos/:slug/collaborators/invitations/:id  # Cancel a pending invitation (owner/admin only; API keys need `repo:update`)
```

### API Keys

```
GET    /api/v1/api_keys                 # List your API keys (session token/cookie auth required)
POST   /api/v1/api_keys                 # Create an API key (session token/cookie auth required)
DELETE /api/v1/api_keys/:id             # Revoke an API key (session token/cookie auth required)
```

### GPG Keys

```
GET    /api/v1/gpg_key                  # Get your GPG key info (session token/cookie auth required)
PUT    /api/v1/gpg_key                  # Upload/replace your GPG key pair (session token/cookie auth required)
POST   /api/v1/gpg_key/generation       # Generate a new GPG key pair server-side (session token/cookie auth required)
DELETE /api/v1/gpg_key                  # Remove your GPG key when it is not used by any repository (session token/cookie auth required)
POST   /api/v1/gpg_key/revocation       # Remove or replace an in-use GPG key with an explicit strategy (session token/cookie auth required)
GET    /api/v1/gpg_key/transitions/:id  # Read one of your retained key-transition resources (session token/cookie auth required)
```

### API Contract Details

JSON endpoints with request bodies require `Content-Type: application/json` and accept at most 1 048 576 body bytes; the request reader enforces the cap incrementally and returns `413 payload_too_large` before decoding an oversized body. GPG key upload requests use `multipart/form-data` with a 2 162 688-byte total cap in addition to the per-key-field limits below. RPM payloads are never multipart API bodies: after small JSON control requests, clients `PUT` them directly to a presigned B2 URL. All timestamps are ISO-8601 UTC strings and all IDs are UUID strings. Every PostgreSQL `bigint` value in a JSON response is a canonical base-10 string; request fields that map to `bigint` likewise require strings. A non-negative value is exactly `"0"` or matches `[1-9][0-9]*`; signs, decimals, exponent notation, whitespace, leading zeros, and JSON numeric values are rejected with `422 validation_failed`. This rule prevents precision loss in JavaScript and applies to counts and pagination totals as well as byte sizes and revisions. Contract tests round-trip `0`, `2^53 - 1`, `2^53`, and the relevant database/configuration maxima through JSON without numeric coercion.

User-provided metadata strings are trimmed before validation, but secrets and key material (passwords, bearer/API token values, and GPG armored key fields) are not modified except by their documented parsers. For optional string fields, a value that is empty after trimming is coerced to `NULL` at storage time and surfaced as `null` in responses; an explicit `null` in the request body is treated the same way. Required string fields with an empty-after-trim value are rejected with `422 validation_failed`. Email addresses are trimmed, normalized to lowercase, capped at 160 characters after trimming, and validated with the same email rules used by `phx.gen.auth`. Repository slugs are normalized to lowercase and must match `^[a-z0-9][a-z0-9_-]{0,63}$`; the slug `new` is reserved for the web UI's repository-creation route and rejected with `422 validation_failed`. Unknown JSON fields are rejected with `422 validation_failed`; multipart requests that include any field name the target endpoint does not define are likewise rejected with `422 validation_failed`. String fields whose trimmed length exceeds the maximum specified in the data-model tables are rejected with `422 validation_failed`. Single-line user-provided string fields — repository `name` and API key `name` — are rejected with `422 validation_failed` when they contain ASCII control characters (the repository `name` is interpolated into generated `.repo` files, where a line break would inject arbitrary directives); repository `description` may contain newlines and tabs but no other control characters. Every resource addressed beneath `/repos/:slug/...` — packages, package versions, package uploads, package downloads, collaborators, and invitations, on the API, web, and repository-serving surfaces alike — is looked up scoped to the repository resolved from `:slug`; an id that exists under a different repository is treated as nonexistent and handled by the `404 not_found` masking rule below. An update endpoint rejects an empty JSON object, or a body containing no effective mutable field after validation, with `422 validation_failed` rather than reporting a successful no-op.

Query parsing is strict. A route rejects every query parameter name it does not document with `422 validation_failed`; a route with no documented query parameters rejects any query string. Repeating a key is rejected with `422 validation_failed` even when the values are identical, rather than choosing first/last semantics. Malformed percent encoding or query bytes that cannot be decoded as UTF-8 are syntactically invalid and return `400 invalid_request`. Tests apply these rules to every route family, including pagination, filters, presigned-control endpoints, and account endpoints. Repository-serving endpoints are the exception: they ignore query strings entirely (see RPM Repository Endpoint).

Request bodies and endpoint-specific behavior:

- `POST /api/v1/auth/login`: JSON body `{"email": "...", "password": "..."}`.
- `GET /api/v1/repos`: includes private repositories only when the credential grants private read access — session token or session cookie requests list every private repository the user can access (admins see all repositories), while API-key requests additionally require the `repo:read` scope; a valid API key without `repo:read` receives only public repositories. The optional `q` parameter filters the list to repositories whose `slug`, `name`, or `description` matches the query under the shared filter-string rules below.
- `GET /api/v1/search/packages`: the REST equivalent of the web search page's package group. `q` is required and must be non-blank after trimming — a missing or blank `q` is rejected with `422 validation_failed`, so the endpoint is a search, not an instance-wide package enumeration; the optional `arch` parameter is an exact-match filter. Visibility follows `GET /api/v1/repos` exactly: anonymous requests and API-key requests without `repo:read` search public repositories only; session token or session cookie requests search every repository the user can access; admins search all repositories. Results are filtered, never `404`-masked, and must never include rows from repositories the presented credential cannot read.
- `POST /api/v1/repos`: JSON body with required `name` and `slug`, and optional `description`, `is_public`, `gpg_key_fingerprint`, and `sign_rpms`. Requests with a `slug` whose normalized form is already in use by another repository, or retired by a deleted repository the requester did not own (see Slug Reservations), are rejected with `422 validation_failed` and `details.slug` indicating the conflict, so slug collisions surface the same way as format violations. Requests with `gpg_key_fingerprint` set to anything other than the owner's current GPG key fingerprint are rejected with `422 validation_failed`. Requests with `sign_rpms = true` must also set `gpg_key_fingerprint` to the owner's current GPG key fingerprint or they are rejected with `422 validation_failed`. `rpm_signing_state` is server-managed; requests that include it are rejected with `422 validation_failed`. A new empty repository created with `sign_rpms = true` starts with `rpm_signing_state = "enabled"`. A request that would leave the creator owning more than `MAX_USER_REPOSITORIES` repositories is rejected with `409 conflict_repository_quota_exceeded`.
- `PATCH /api/v1/repos/:slug`: JSON body with any subset of repository fields accepted by create, except `slug`, which is immutable. PATCH requests that include `slug` are rejected with `422 validation_failed` so existing client `.repo` files continue to resolve. `rpm_signing_state` is server-managed; PATCH requests that include it are rejected with `422 validation_failed`. PATCH requests with `gpg_key_fingerprint` set to a non-null value other than the owner's current GPG key fingerprint are rejected with `422 validation_failed`; an explicit `null` is always permitted and clears metadata signing for the repository. PATCH operations that would leave `sign_rpms = true` with `gpg_key_fingerprint` unset are rejected with `422 validation_failed` (mirroring the create-time constraint). Enabling `sign_rpms` on a repository that already has packages requires an explicit `existing_package_strategy` field with value `"resign"` to confirm per-package re-sign jobs identical to the key replacement flow; the server sets `rpm_signing_state = "signing"` until those jobs complete. Transitioning `sign_rpms` to `true` on a non-empty repository without this field is rejected with `422 validation_failed`. Unknown `existing_package_strategy` values are rejected with `422 validation_failed`. When `sign_rpms` is unchanged, when it is transitioning from `true` to `false`, or when it is being enabled on an empty repository, requests that include `existing_package_strategy` are rejected with `422 validation_failed`. Enabling `sign_rpms` on an empty repository sets `rpm_signing_state = "enabled"`; disabling `sign_rpms` sets `rpm_signing_state = "disabled"`.
- `POST /api/v1/repos/:slug/package-uploads`: JSON body `{"filename": "nginx.rpm", "size": "623104"}`. `filename` and the decimal-string `size` use the Upload Intents validation rules; the endpoint fixes `mode` to `api` and rejects a client-supplied `mode`. It atomically creates the declared-size reservation and intent, then returns `201 Created` with the upload-intent resource plus an `upload` object: `{"generation": 1, "method": "PUT", "url": "<presigned-b2-url>", "headers": {"Content-Type": "application/x-rpm"}, "content_length": "623104", "expires_at": "..."}`. `url` is a bearer capability shown only in a create or refresh response and is never returned by the status endpoint. A non-browser client sets both the listed content type and `Content-Length: 623104`; browser code sets `Content-Type` and supplies the selected `File` as the body but does not attempt to set forbidden `Content-Length`, which the user agent derives from that file. The direct B2 request carries no Dark Zenith `Authorization` header. The client must retain the generation and response's `x-amz-version-id`; the B2 response itself is outside Dark Zenith's JSON-envelope contract.
- `POST /api/v1/repos/:slug/package-uploads/:id/refresh`: no request body. It is allowed only for the initiating user while the intent is `awaiting_upload`, its current upload URL has expired, and at least 60 seconds remain on the intent; it abandons the prior key and returns `200 OK` with the resource plus a new `upload` object capped at the unchanged intent expiry. A still-valid URL, insufficient remaining time, or any other state returns `409 conflict_upload_state`; the client retries an interrupted transfer against the current URL or creates a new intent instead of minting overlapping capabilities.
- `POST /api/v1/repos/:slug/package-uploads/:id/complete`: JSON body `{"generation": 1, "version_id": "<x-amz-version-id>"}`. `generation` must be a positive integer, and `version_id` is treated as an opaque non-empty string of at most 1 024 bytes with no control characters. The endpoint first checks durable state: the already accepted same generation/version returns idempotently without contacting B2 (`202` while queued/processing and `200` once `preview_ready`, `succeeded`, or `failed`). For an unexpired `awaiting_upload` intent, Dark Zenith requires the supplied generation to be current, snapshots its key, performs exact-version `HeadObject`, verifies size, content type, and the complete forbidden-metadata set, then uses a compare-and-swap on generation/key/state/expiry to store that version and enqueue processing. The first success returns `202 Accepted` with the upload-intent resource and `Retry-After: 2`. An overdue intent is atomically expired; a stale generation, different version, canceled/expired intent, or other changed state returns `409 conflict_upload_state`. A missing version or mismatched object returns `422 validation_failed` with `details.version_id`. Temporary B2 failure returns `503 storage_unavailable` without changing the intent, so completion is safe to retry.
- `GET /api/v1/repos/:slug/package-uploads/:id`: returns `200 OK` with the current intent resource. Clients poll while status is `queued` or `processing`, honoring the `Retry-After: 2` response header. `succeeded` includes the package detail resource. `failed` includes the stable sanitized error code described under Upload Intents; asynchronous failures do not change this status endpoint's HTTP status from `200`.
- `DELETE /api/v1/repos/:slug/package-uploads/:id`: cancels an `awaiting_upload`, `queued`, `processing`, or `preview_ready` intent, fences any worker, releases the reservation, enqueues version-aware cleanup, and returns `204 No Content`. Repeating cancellation or deleting an already failed/expired intent is an idempotent `204`; a succeeded intent returns `409 conflict_upload_state` and its package must be deleted through the package endpoint.
- `POST /api/v1/repos/:slug/collaborators`: JSON body `{"email": "user@example.com"}`. Adding collaborators or invitations is valid only for private repositories; add requests on a public repository are rejected with `422 validation_failed`. Removal, cancellation, and listing remain available regardless of repository visibility, so rows retained across a private-to-public flip can still be managed. The email is normalized to lowercase before lookup. If the email belongs to the repository owner, the request is rejected with `422 validation_failed`. If a collaborator or pending invitation already exists for the normalized email, the request succeeds idempotently with `200 OK` and returns the existing row instead of creating a duplicate. A failed collaborator notification increments its generation and queues a new direct-link delivery; queued and sent collaborator deliveries are not duplicated. An unexpired invitation queues a new delivery generation only when `notification_status = "failed"`, or when it is `suppressed` and registration has since been enabled; queued and sent invitation deliveries are not duplicated. If the existing invitation has expired but has not yet been cleaned up, the add request resets `expires_at`, increments `notification_generation`, clears `notification_sent_at`, and either queues or suppresses the replacement notification under the registration-disabled rule; it returns `200 OK` with the refreshed invitation. Newly created collaborators or invitations return `201 Created`. A request that must create a new row past `MAX_REPOSITORY_COLLABORATORS` is rejected with `409 conflict_collaborator_quota_exceeded`; idempotent responses and expiry refreshes are not quota-checked (see Repository Collaborators).
- `POST /api/v1/api_keys`: JSON body with `name`, `scopes`, and optional `expires_at`. `name` is trimmed, must be non-blank, and must be at most 100 characters after trimming. `scopes` must be a non-empty array of valid scope strings and is deduplicated/sorted into the canonical representation described under API Keys. When `expires_at` is provided it must be a future ISO-8601 UTC timestamp; values at or before the current server time are rejected with `422 validation_failed`. A request over `MAX_USER_API_KEYS` returns `409 conflict_api_key_quota_exceeded`. The plaintext API key is returned only in this response.
- `GET /api/v1/gpg_key`: no request body. Returns the current GPG key resource, or `404 not_found` if the authenticated user has no GPG key.
- `PUT /api/v1/gpg_key`: multipart body with `public_key` and `private_key` fields containing ASCII-armored OpenPGP V4 keys. Each key field is capped at 1 048 576 bytes; larger key uploads are rejected with `413 payload_too_large`. The public and private material must identify exactly one matching V4 primary key. Validation applies the primary-first, otherwise-single-signing-subkey selection rule in GPG Signing, records the selected exact fingerprint, validates its exact algorithm/parameters, and completes both the exact-key GPG test and bundled v4/v6 RPM signing tests. Unparsable, V5/V6, mismatched, passphrase-protected, revoked, ambiguous, RPM-v4-incompatible, or otherwise unusable material is rejected with `422 validation_failed`, as is a key whose effective primary/selected-key expiry is less than 30 full days away. Uploading the first key returns `200 OK` with the GPG key resource. Replacing an existing key creates a preparing transition and returns `202 Accepted` with that transition resource and `Retry-After: 2`. A replacement is rejected with `409 conflict_gpg_key_transition_in_progress` while another user-wide transition is unresolved in any phase or any owned repository has `rpm_signing_state = "signing"`.
- `POST /api/v1/gpg_key/generation`: optional JSON body whose only accepted field is `algorithm`: one of `"ed25519"` (the default), `"rsa3072"`, `"rsa4096"`, `"nistp256"`, or `"nistp384"`; an absent body or an explicit `null` selects the default, and unknown fields or algorithm values are rejected with `422 validation_failed`. The pair is generated server-side (see Server-side key generation) and then follows `PUT /api/v1/gpg_key` semantics exactly: a first key is written synchronously and returns `200 OK`; an existing key starts a preparing replacement transition and returns `202 Accepted` with `Retry-After: 2`; the same `409 conflict_gpg_key_transition_in_progress`, `503 signing_unavailable`, and `503 rpm_verification_unavailable` rules apply, and a generated pair rejected by validation (including a crypto policy that refuses the chosen algorithm) is `422 validation_failed`. Generation responses are the only responses that carry private key material: the `200` data object is `{"gpg_key": <GPG key resource>, "private_key": "<ASCII-armored private key>"}` and the `202` data object is `{"transition": <transition resource>, "private_key": "..."}`; the value is returned exactly once and can never be fetched again.
- `DELETE /api/v1/gpg_key`: no request body. Returns `404 not_found` when the authenticated user has no GPG key. An unresolved removal transition returns `409 conflict_gpg_key_transition_in_progress` because its durable finalizer owns key deletion. Otherwise, a key not used by any repository is removed with `204 No Content`, atomically canceling an unresolved replacement if necessary; an in-use key returns `409 conflict_gpg_key_in_use` with decimal-string `details.metadata_signed_repositories` and `details.rpm_signed_repositories` counts (see Key replacement and revocation).
- `POST /api/v1/gpg_key/revocation`: JSON body `{"strategy": "clear_metadata_signing"}`, `{"strategy": "delete_signed_packages"}`, or `{"strategy": "replace_with_generated_key"}` (the last also accepting the optional `algorithm` field with generation's values and default; `algorithm` alongside any other strategy is rejected with `422 validation_failed`); or multipart body with `strategy=replace_key`, `public_key`, and `private_key` fields. Each key field in a `replace_key` request is capped at 1 048 576 bytes; larger key uploads are rejected with `413 payload_too_large`. Returns `404 not_found` when the authenticated user has no GPG key. Unknown strategies are rejected with `422 validation_failed`. Multipart revocation bodies are accepted only with `strategy=replace_key`; multipart requests carrying any other strategy value are rejected with `422 validation_failed`, so key material can never accompany a non-replacement strategy. `clear_metadata_signing` is rejected with `409 conflict_gpg_key_in_use` if any owned repository has `sign_rpms = true`. `replace_key` and `replace_with_generated_key` are rejected with `409 conflict_gpg_key_transition_in_progress` under the same conditions as PUT; `replace_with_generated_key` additionally follows the generation, validation, and one-time private-key-reveal rules of `POST /api/v1/gpg_key/generation`, so its `202` data object is `{"transition": <transition resource>, "private_key": "..."}`. A non-replacement strategy may atomically cancel an unresolved replacement as described under Key replacement and revocation, but an existing unresolved removal transition returns `409 conflict_gpg_key_transition_in_progress` rather than being superseded. Every successful strategy returns `202 Accepted` with the new durable transition resource and `Retry-After: 2` (wrapped alongside the one-time `private_key` for `replace_with_generated_key`, as above).
- `GET /api/v1/gpg_key/transitions/:id`: returns a retained user-wide transition owned by the authenticated user, including after their key has been removed. An ID owned by another user is masked as `404 not_found`, as is the ID of a repository-local `enable_rpm_signing` transition, whose progress is exposed only through the owning repository's `rpm_signing_state`. Clients poll a `preparing`, `activating`, `active`, or `finalizing` transition using `Retry-After: 2`; `failed` requires intervention and carries no automatic-poll hint.

Resource response shapes:

- Repository resources have shape `{"id": "<uuid>", "owner_id": "<uuid>", "slug": "stable", "name": "Stable", "description": null, "is_public": true, "gpg_key_fingerprint": null, "sign_rpms": false, "rpm_signing_state": "disabled", "metadata_revision": "0", "package_count": "0", "inserted_at": "...", "updated_at": "..."}`. The API's semantic `owner_id` field maps to the repository table's `user_id` foreign key; `user_id` is not also emitted.
- Package list resources have shape `{"id": "<uuid>", "repository_id": "<uuid>", "rpm_format": 6, "name": "nginx", "epoch": "0", "version": "1.24.0", "release": "2.fc39", "arch": "x86_64", "summary": "A high performance web server and reverse proxy server", "size_package": "623104", "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "download_path": "/repos/stable/packages/<uuid>/nginx-1.24.0-2.fc39.x86_64.rpm", "inserted_at": "...", "updated_at": "..."}`.
- Package detail resources include every package list field plus `description`, `url`, `license`, decimal-string `size_installed`, nullable decimal-string `size_archive`, `build_time`, `rpm_sourcerpm`, `rpm_sourcenevr`, `rpm_group`, `rpm_vendor`, `rpm_buildhost`, and decimal-string `requires_count`, `provides_count`, `conflicts_count`, `obsoletes_count`, `recommends_count`, `suggests_count`, `supplements_count`, `enhances_count`, `files_count`, and `changelogs_count`. They deliberately omit the ten potentially large arrays. `build_time` is an ISO-8601 UTC timestamp or `null`. Package resources never expose the internal `storage_path`, `storage_version_id`, `header_start`, or `header_end`.
- Search result rows from `GET /api/v1/search/packages` have the package list shape plus `repository_slug`, so clients can build browse and download URLs without a second lookup.
- Upload-intent resources have shape `{"id": "<uuid>", "repository_id": "<uuid>", "package_id": "<uuid>", "mode": "api", "status": "processing", "original_filename": "nginx.rpm", "declared_size": "623104", "attempts": 1, "expires_at": null, "error": null, "package": null, "completed_at": null, "inserted_at": "...", "updated_at": "..."}`. `status` is one of the Upload Intents states, although API-mode resources never enter `preview_ready`. `expires_at` is non-null only while awaiting a direct transfer or web confirmation. `error` is null except on `failed`, where it has `{"code": "signing_unavailable", "message": "RPM signing is temporarily unavailable"}` with no tool output or storage detail. `package` is the package detail resource on `succeeded`; it becomes null if that package is later deleted, while the immutable `package_id` remains available for correlation. The internal reservation, staging key/version, and lease token are never exposed; the status resource also omits the upload generation, while create and refresh responses include the current generation only inside the ephemeral `upload` capability object.
- Optional string fields use `null` when absent.
- Dependency entries in `requires`, `provides`, `conflicts`, `obsoletes`, `recommends`, `suggests`, `supplements`, and `enhances` have shape `{"name": "libc.so.6()(64bit)", "op": ">=", "epoch": 0, "version": "2.34", "release": null}`. `op` is one of `<`, `<=`, `=`, `>=`, `>`, or `null`. When `op` is `null`, `epoch`, `version`, and `release` are also `null`. When `op` is set, `version` is required, `epoch` is `0` if the RPM omits an epoch, and `release` is `null` only when the RPM omits a release constraint. These nested epochs are bounded unsigned RPM-header values stored inside JSONB rather than package-table `bigint` columns, so they remain JSON numbers. `requires` entries additionally include `pre`, a boolean indicating a pre-transaction dependency. A rich (boolean) dependency appears as an unversioned entry whose `name` is the full parenthesized expression, and `requires` never includes the `rpmlib(...)` entries or exact duplicates excluded at extraction (see Package Upload & Processing).
- File entries have shape `{"path": "/usr/bin/nginx", "type": "file", "flags": []}`. `type` is `file`, `directory`, or `symlink`. `flags` is an array containing zero or more of `config`, `doc`, `ghost`, `license`, and `readme`.
- Changelog entries have shape `{"timestamp": "2025-01-15T10:30:00Z", "author": "Packager <packager@example.com>", "text": "Updated to 1.24.0"}`.
- API key resources have shape `{"id": "<uuid>", "name": "CI read-only", "key_prefix": "dzak_abcdefg", "scopes": ["repo:read"], "expires_at": null, "is_expired": false, "inserted_at": "...", "updated_at": "..."}`. Scope order is canonical and expired rows remain in this list. `POST /api/v1/api_keys` returns the same resource plus `key`, the full plaintext API key; no other response includes `key` or `key_hash`.
- GPG key resources have shape `{"fingerprint": "0123456789ABCDEF0123456789ABCDEF01234567", "signing_fingerprint": "89ABCDEF0123456789ABCDEF0123456789ABCDEF", "expires_at": "...", "public_key": "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----", "replacement_in_progress": false, "previous_public_key": null, "transition": null, "updated_at": "..."}`. `signing_fingerprint` identifies the exact signing-capable primary key or subkey forced for signatures; `expires_at` is an ISO-8601 UTC timestamp or `null` for a non-expiring signing key. `replacement_in_progress` is true for a preparing, activating, or active `replace_gpg_key` transition (and the corresponding failed phase), including preparation when `previous_public_key` remains null; after the key-swap commit, `previous_public_key` carries the outgoing ASCII-armored key. `transition` is the current transition resource while any user-wide transition is unresolved. GPG key resources never expose private key material or prepared candidate fields; the one-time `private_key` value in generation responses is a sibling of these resources, never a member, and no `GET` endpoint returns private key material. `updated_at` is the owning user record's `updated_at`.
- User-wide GPG transition resources have shape `{"id": "<uuid>", "kind": "replace_gpg_key", "status": "preparing", "resume_status": null, "target_fingerprint": "<fingerprint>", "phase_attempts": 0, "phase_next_attempt_at": "...", "repositories_preparation_complete": false, "packages_preparation_complete": false, "repository_count": "12", "repository_applied_count": "0", "repository_satisfied_deleted_count": "0", "item_count": "1840", "pending_count": "1840", "executing_count": "0", "succeeded_count": "0", "failed_count": "0", "canceled_count": "0", "error": null, "inserted_at": "...", "updated_at": "...", "completed_at": null}`. Counts reflect durable snapshot/item rows available so far during preparation; `target_fingerprint` is null for either removal kind. `error` is null unless failed, when it contains only the stable sanitized code/message. Candidate key material and preparation cursors are never exposed.

`GET /api/v1/repos/:slug/collaborators` returns collaborators and pending invitations as typed rows in the standard paginated list envelope. Rows are sorted by normalized email ascending, then by `type` (`collaborator` before `invitation`), then by `id` ascending. Collaborator rows have shape `{"type": "collaborator", "id": "<collaborator_id>", "user_id": "<user_id>", "email": "user@example.com", "notification_status": "queued", "notification_generation": "1", "notification_sent_at": null, "inserted_at": "...", "updated_at": "..."}`; `id` is the value `DELETE /api/v1/repos/:slug/collaborators/:id` takes, matching how invitations are addressed, and `user_id` is included for clients that need to correlate the row with a user. Invitation rows have shape `{"type": "invitation", "id": "<invitation_id>", "email": "pending@example.com", "invited_by_id": "<user_id>", "expires_at": "...", "notification_status": "queued", "notification_generation": "1", "notification_sent_at": null, "inserted_at": "...", "updated_at": "..."}`. `expires_at` is null when invitation expiry is disabled; `notification_sent_at` is non-null only when the current generation was delivered successfully.

The ten package-detail subresources return their corresponding entry shapes in the standard paginated envelope. Dependency arrays retain original RPM header order, represented by their stored array ordinal. Files sort by path ascending using UTF-8 byte order and then original ordinal. Changelogs sort by timestamp descending and retain original RPM header order for equal timestamps. The API does not accept filters or custom sorting on these routes. The web package-version page initially renders scalar metadata and counts, then lazy-loads each tab/page through these bounded endpoints; it never embeds an unbounded collection in the initial HTML or LiveView state. Upload preview remains an authenticated internal view and may show the fully parsed collections subject to the parser's existing hard caps.

All list endpoints — including `/api/v1/repos`, `/api/v1/repos/:slug/packages`, `/api/v1/search/packages`, the ten package-detail subresources, `/api/v1/repos/:slug/collaborators`, and `/api/v1/api_keys` — support `page` and `per_page` query parameters and return the same paginated envelope. `page` defaults to `1` and must be an integer from `1` through `10 000`; larger, non-integer, or non-positive values are rejected with `422 validation_failed`. `per_page` defaults to `50` and is capped at `100` (larger positive integers are clamped to `100`); non-integer or non-positive values are rejected. `total_pages` is computed as `ceil(total / per_page)`, so it is the decimal string `"0"` when `total` is `"0"`; both `total` and `total_pages` are decimal strings, while the bounded query/response fields `page` and `per_page` remain JSON numbers. A valid `page` greater than `total_pages` succeeds with `200 OK`, returns an empty `data` array, and echoes the requested page in the pagination envelope. Default ordering is deterministic: repositories by `slug` ascending then `id` ascending; packages by `name` ascending, `arch` ascending, RPM EVR descending, then `id` ascending; search results by `name` ascending, `arch` ascending, RPM EVR descending, repository `slug` ascending, then `id` ascending; package-detail collections as described above; collaborators as described above; and API keys by `inserted_at` descending then `id` ascending.

Package list endpoints additionally support `q`, `name`, `arch`, and `sort`. The three filter strings are trimmed and capped at 256 characters; longer values are rejected with `422 validation_failed`. A blank `q` is treated as absent, while blank `name` or `arch` exact-match filters are rejected. The `q` parameter performs a case-insensitive literal substring match against package `name` and `summary` — a package matches when either contains the substring; `%`, `_`, and the chosen SQL escape character in user input are escaped before the parameterized `ILIKE` expression, so they are never interpreted as pattern syntax. `name` and `arch` are parameterized exact-match filters. Valid package sort values are `name`, `version`, `arch`, and `inserted_at`; prefix with `-` for descending order. The `version` sort orders packages by RPM EVR using `(epoch, version, release)` and RPM's native comparison semantics, with `name`, `arch`, and `id` as deterministic ascending tie-breakers. `-version` reverses only EVR ordering. For every other descending sort, only the named sort column is reversed; tie-breakers remain ascending. Non-version package sorts use `id` ascending as their only tie-breaker. Unknown sort values are rejected with `422 validation_failed`.

The same filter-string rules — trimming, the 256-character cap, and `ILIKE` escaping — govern the two search surfaces. `GET /api/v1/repos` accepts an optional `q` matched case-insensitively against repository `slug`, `name`, and `description`, with a blank value treated as absent like the package-list `q`. `GET /api/v1/search/packages` accepts `q` (required non-blank, per its contract bullet above) matched against the same package `name` and `summary` fields as the package-list `q`, and an optional exact-match `arch`; it accepts no `name` or `sort` parameter, and the web search page applies these same match semantics to both of its result groups.

RPM EVR ordering is implemented in PostgreSQL, not approximated with lexical SQL ordering or host-language package versions. A schema migration owns `dark_zenith_rpmvercmp(text, text)` and `dark_zenith_evr_cmp(bigint, text, text, bigint, text, text)`, both declared `IMMUTABLE`, `STRICT`, and `PARALLEL SAFE`. The first implements the RPM 6 segment algorithm exactly, including tilde, caret, numeric-versus-alpha segments, separators, and leading-zero behavior; the second compares numeric epochs first, then version and release with `dark_zenith_rpmvercmp`. The migration also defines a named `dark_zenith_rpm_evr` composite type, comparison operators, and a default btree operator class whose support function delegates to the six-argument comparator. Version queries order by `ROW(epoch, version, release)::dark_zenith_rpm_evr`, so filtering, ordering, and pagination remain one database query. ExUnit conformance fixtures cover every upstream librpm comparison case used by the supported RPM 6 release, and a release test differentially compares the PostgreSQL comparator with the boot-required RPM 6 tooling before deployment. Comparator or operator-class changes require a migration and those conformance tests.

Successful JSON responses use a `data` envelope:

- Single-resource responses: `{"data": {...}}`
- List responses: `{"data": [...], "pagination": {"page": 1, "per_page": 50, "total": "123", "total_pages": "3"}}`
- Create responses: HTTP 201 with the created resource in `data`
- Accepted asynchronous upload completion: HTTP 202 with the current upload-intent resource in `data` and `Retry-After: 2`
- Upload-intent status polling: HTTP 200 with the current upload-intent resource in `data`, plus `Retry-After: 2` while the status is `queued` or `processing`
- Accepted GPG replacement/removal transition: HTTP 202 with the transition resource in `data` and `Retry-After: 2`
- GPG-transition polling: HTTP 200 with the transition resource in `data`, plus `Retry-After: 2` while its status is `preparing`, `activating`, `active`, or `finalizing`
- Delete and logout responses: HTTP 204 with an empty body

Error responses use this shape:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "Validation failed",
    "details": {
      "slug": ["has invalid format"]
    }
  }
}
```

`details` is optional: it is included when field-level or structured information is available (for example, validation errors and the conflict shape below) and omitted otherwise.

`conflict_gpg_key_in_use` responses use this `details` shape:

```json
{
  "error": {
    "code": "conflict_gpg_key_in_use",
    "message": "GPG key is still used by repositories",
    "details": {
      "metadata_signed_repositories": "2",
      "rpm_signed_repositories": "1"
    }
  }
}
```

`metadata_signed_repositories` counts every repository owned by the user with `gpg_key_fingerprint` set, including those that also have `sign_rpms = true`; `rpm_signed_repositories` counts the subset with `sign_rpms = true`.

Standard API error codes:

| HTTP | Code                                          | Meaning                                                                                                               |
| ---: | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
|  400 | `invalid_request`                             | Malformed JSON, query encoding, GPG-key multipart body, or unsupported content type                                   |
|  401 | `unauthenticated`                             | Missing, expired, or invalid credentials                                                                              |
|  403 | `forbidden`                                   | Authenticated user lacks the required scope, repository permission, or allowed authentication method                  |
|  404 | `not_found`                                   | Requested repository, package, upload intent, collaborator, invitation, API key, GPG key, or transition was not found |
|  409 | `conflict_api_key_quota_exceeded`             | API key creation would exceed the user's `MAX_USER_API_KEYS` limit                                                    |
|  409 | `conflict_collaborator_quota_exceeded`        | Collaborator or invitation addition would exceed the repository's `MAX_REPOSITORY_COLLABORATORS` limit                |
|  409 | `conflict_duplicate_package`                  | Package with the same repository/name/epoch/version/release/arch already exists                                       |
|  409 | `conflict_gpg_key_expired`                    | A configured signing key has expired and must be replaced or removed                                                  |
|  409 | `conflict_gpg_key_in_use`                     | GPG key removal requires an explicit revocation strategy because one or more repositories still use it                |
|  409 | `conflict_gpg_key_transition_in_progress`     | A conflicting repository/package/GPG mutation was requested while a signing/key transition blocked it                 |
|  409 | `conflict_repository_metadata_limit_exceeded` | Package mutation would exceed a repository package-count or uncompressed-repodata-size limit                          |
|  409 | `conflict_repository_quota_exceeded`          | Repository creation would exceed the owner's `MAX_USER_REPOSITORIES` limit                                            |
|  409 | `conflict_storage_quota_exceeded`             | Upload or re-sign would exceed the repository owner's `MAX_USER_STORAGE_BYTES` storage quota                          |
|  409 | `conflict_upload_state`                       | Upload completion, refresh, cancellation, or version does not match the intent's current state                        |
|  409 | `conflict_user_owns_repositories`             | Admin attempted to delete a user that still owns repositories                                                         |
|  413 | `payload_too_large`                           | Declared RPM size or a request body exceeds the applicable configured or documented limit                             |
|  422 | `validation_failed`                           | Request shape is valid but field values failed validation                                                             |
|  429 | `rate_limited`                                | Request exceeded the applicable rate limit                                                                            |
|  500 | `internal_error`                              | Unexpected server error                                                                                               |
|  503 | `rpm_verification_unavailable`                | Required RPM 6 verification tooling or its isolated temporary keyring is unavailable                                  |
|  503 | `signing_unavailable`                         | Required RPM/GPG signing tooling or signing infrastructure is temporarily unavailable                                 |
|  503 | `storage_unavailable`                         | Backblaze B2 or object-storage operation is temporarily unavailable                                                   |
|  503 | `upload_temp_space_unavailable`               | Temporary RPM-processing workspace lacks the required reserved free space                                             |

That table enumerates the `/api/v1/...` codes. Repository-serving endpoints reuse the same codes as bare plain-text bodies and add one code of their own: `503 metadata_not_ready`, returned when a repository's metadata cache is missing or behind its current `metadata_revision` (see Metadata Generation & Storage). `metadata_not_ready` never appears in the JSON error envelope. Every `503` returned as a response status carries a `Retry-After` hint, on the JSON and repository-serving surfaces alike, chosen for how quickly that particular dependency realistically recovers rather than a single value for all of them:

| Code                           | `Retry-After` | Returned synchronously by                                             | Rationale                                                                                               |
| ------------------------------ | ------------: | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `metadata_not_ready`           |           `5` | Repository-serving metadata endpoints                                 | A regeneration job is already enqueued and normally commits within seconds.                             |
| `storage_unavailable`          |          `10` | Package-download redirects and upload completion                      | B2 blips and throttling usually clear fast; a longer wait would stall a `dnf` transaction.              |
| `signing_unavailable`          |          `30` | Repository creation with metadata signing; GPG key upload/generation/replacement | A `gpg`/`rpmsign` host fault rarely clears in seconds, and each retry re-runs CPU-heavy key validation. |
| `rpm_verification_unavailable` |          `30` | GPG key upload/replacement                                            | Same host-level fault class; the per-key RPM fixture tests are equally expensive to repeat.             |

`upload_temp_space_unavailable` never appears as a response status. Temporary-space exhaustion is detected only after a worker has claimed durable work, so it is recorded on the upload intent or transition item and retried under Background Retry Policy. More generally, a `503` code stored on a terminally failed intent is a result rather than a status: the polling endpoint keeps returning `200` as defined above and sends no `Retry-After`. These hints are lower bounds on dependency recovery, not permission to exceed a specialized rate-limit bucket — a client retrying GPG key upload every 30 seconds still exhausts the 10-per-hour GPG mutation limit and must then honor the `429` response's own `Retry-After`.

To avoid leaking the existence of private resources, repository-scoped requests that target a private repository (or any resource scoped under one) return `404 not_found` when the requester is anonymous, presents invalid/expired/revoked credentials, or is authenticated as a valid principal that lacks access to that repository. Requests to a slug that does not exist also return `404 not_found`, so clients cannot distinguish "this slug is private" from "this slug does not exist." Anonymous requests refine this rule on two surfaces while preserving that indistinguishability: the repository-serving endpoints intended for RPM clients return `401 unauthenticated` with a `WWW-Authenticate: Basic` challenge for private and nonexistent slugs alike (see Private Repository Authentication), and web UI routes under `/repos/:slug` redirect anonymous requests for private and nonexistent slugs to the login page, rendering the standard HTML 404 page after login only when the authenticated user still lacks access or the slug does not exist. For `/api/v1/...` requests the base `404 not_found` masking applies unchanged. For public repository reads, an explicitly presented `Authorization` credential that fails validation returns `401 unauthenticated` instead of falling back to anonymous access, so bad client configuration is visible; a stale or invalid session cookie with no `Authorization` header is ignored on that public read as defined under Private Repository Authentication. Other endpoints and actions that require authentication return `401 unauthenticated` for missing credentials and also return `401 unauthenticated` for credentials that fail validation — invalid signature, expired, or revoked. `403 forbidden` is returned only when the authenticated principal is known to exist and is permitted to see the resource but lacks the specific scope, mutation permission, or allowed authentication method required for the requested operation (e.g., a valid API key without `package:upload` attempting an upload to a public repo, a valid API key with `repo:read` but without `repo:update` attempting to add a collaborator on a private repo it can read, or any API key attempting to manage API keys or GPG keys).

### Response Format

Example package list response:

```json
{
  "data": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "repository_id": "76c4474c-4b87-4ee8-8eb5-b2f7f4673e31",
      "rpm_format": 6,
      "name": "nginx",
      "epoch": "0",
      "version": "1.24.0",
      "release": "2.fc39",
      "arch": "x86_64",
      "summary": "A high performance web server and reverse proxy server",
      "size_package": "623104",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "download_path": "/repos/stable/packages/550e8400-e29b-41d4-a716-446655440000/nginx-1.24.0-2.fc39.x86_64.rpm",
      "inserted_at": "2025-01-15T10:30:00Z",
      "updated_at": "2025-01-15T10:30:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 50,
    "total": "1",
    "total_pages": "1"
  }
}
```

---

## .repo File Endpoint

For convenience, serve a downloadable `.repo` file:

```
GET /repos/:slug/dark-zenith.repo
```

For private repositories, the request must be authenticated with read access to the repository. The downloaded file never embeds API keys, session tokens, or passwords. Private repo files use placeholders (`password=<api-key>`) so the response is safe to inspect and share, though the endpoint still sends `Cache-Control: private, no-store` under the repository-serving caching rules. A setup snippet containing a user's actual API key can be rendered only in the response that creates that key — the server stores only key hashes and cannot reconstruct plaintext afterward (see Repository Detail) — and is never returned by this endpoint.

For a repository with metadata signing and `rpm_signing_state = "enabled"`, returns a file like:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://<hostname>/repos/:slug/
enabled=1
metadata_expire=6h
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://<hostname>/repos/:slug/RPM-GPG-KEY
```

For repositories without metadata signing, `repo_gpgcheck` is `0`. For repositories whose `rpm_signing_state` is not `enabled`, including repositories still in the `signing` transition, `gpgcheck` is `0`. The `gpgkey` line is included whenever `gpg_key_fingerprint` is configured and is omitted only when no repository key is configured. Generated `baseurl` and `gpgkey` URLs are built from the Phoenix endpoint's configured URL scheme, `PHX_HOST`, and port, so non-default deployments render correct URLs. Every generated file sets `metadata_expire=6h` so configured clients pick up repository changes within hours rather than dnf's 48-hour default. For private repositories, the file includes credential placeholders:

```ini
username=token
password=<api-key>
```

Generated private configuration is tested end-to-end with supported DNF 4 and DNF 5 clients. When a supported release does not propagate the credential directives to `gpgkey`, the repository detail page adds the interactive authenticated key-import step defined under Private Repository Authentication before instructing DNF to refresh metadata. Dark Zenith never falls back to embedding an API key placeholder in the `gpgkey` URL.

---

## Configuration

Dark Zenith is configured via environment variables and/or `config/runtime.exs`:

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | — | PostgreSQL connection string |
| `SECRET_KEY_BASE` | — | Phoenix secret key and root key material for token hashing and GPG-key envelope derivation. Production requires at least 64 raw UTF-8 bytes generated with a cryptographically secure generator such as `mix phx.gen.secret`. |
| `PREVIOUS_SECRET_KEY_BASE` | — | Optional. Prior value of `SECRET_KEY_BASE` during a rotation window so current and prepared encrypted GPG private keys can be decrypted while background jobs migrate them. It must meet the same 64-byte minimum, differ from the current value, and be removed once every ciphertext has been migrated. |
| `TRUSTED_PROXIES` | empty | Comma-separated list of reverse-proxy IPv4/IPv6 addresses or CIDR blocks whose forwarded client headers the application trusts: `CF-Connecting-IP` and `X-Forwarded-For` for client-IP detection, and `X-Forwarded-Proto` for production HTTPS rewriting. Empty means no proxy is trusted; forwarded headers are ignored, the TCP peer address is used, and Phoenix relies on the connection's own scheme. |
| `PHX_HOST` | `localhost` | Public hostname for URL generation |
| `PHX_SCHEME` | `https` | Public URL scheme; `http` is allowed for local development and additionally disables the endpoint's TLS redirect and the `Secure` session-cookie attribute (see Security Considerations) |
| `PHX_URL_PORT` | `443` | Public URL port used in generated links and the exact browser-upload CORS origin |
| `PORT` | `4000` | HTTP listen port |
| `B2_KEY_ID` | — | Backblaze B2 application key ID |
| `B2_APPLICATION_KEY` | — | Backblaze B2 application key |
| `B2_BUCKET` | — | Private B2 bucket name for RPM storage; anonymous bucket access must be disabled |
| `B2_ENDPOINT` | — | B2 S3-compatible endpoint URL |
| `B2_REGION` | — | B2 S3 region used for SigV4 signing |
| `B2_SIGNED_URL_TTL` | `1800` | Signed URL expiration in seconds (default 30 min); must be an integer from `1` through `604800`, the SigV4 maximum |
| `B2_UPLOAD_URL_TTL` | `3600` | Presigned direct-upload URL expiration in seconds (default and maximum 1 hour); must be an integer from `60` through `3600` and is additionally capped at the intent expiry |
| `RPMKEYS_PATH` | `rpmkeys` | Path to the RPM 6-or-newer `rpmkeys` executable required to verify every upload |
| `RPMSIGN_PATH` | `rpmsign` | Path to the RPM 6-or-newer `rpmsign` executable used by key compatibility validation and RPM signing |
| `GPG_PATH` | `gpg` | Path to the `gpg` executable used by metadata signing and `rpmsign` |
| `RPM_TOOL_TIMEOUT_SECONDS` | `1800` | Hard timeout for each `rpmkeys`, `rpmsign`, or `gpg` child; must be an integer from `60` through `7200` |
| `RPM_PROCESSING_CONCURRENCY` | `2` | Per-node concurrency for the shared upload/re-sign RPM-processing queue; must be an integer from `1` through `64` |
| `SIGNING_PREPARATION_BATCH_SIZE` | `1000` | Maximum repositories/packages prepared, repository settings applied, or item jobs enqueued in one key-transition transaction; must be an integer from `1` through `10000` |
| `MAX_RPM_UPLOAD_BYTES` | `536870912` | Maximum accepted RPM upload size in bytes (default 512 MiB); must be an integer from `1` through `5368709120`, B2's 5 GiB ceiling for the single-`PutObject` upload flow |
| `MAX_USER_STORAGE_BYTES` | `53687091200` | Maximum total stored RPM bytes per user across owned repositories (default 50 GiB); must be a non-negative integer, and `0` disables the quota |
| `MAX_USER_REPOSITORIES` | `100` | Maximum repositories one user may own at once; must be a non-negative integer, and `0` disables the limit |
| `MAX_USER_API_KEYS` | `100` | Maximum stored API-key rows per user, including expired rows; must be a positive integer |
| `MAX_REPOSITORY_COLLABORATORS` | `1000` | Maximum stored collaborator rows plus pending invitations in one repository, including expired-but-uncleaned invitations; must be a non-negative integer, and `0` disables the limit |
| `MAX_REPOSITORY_PACKAGES` | `10000` | Maximum package records in one repository; must be an integer from `1` through `1000000`, an upper bound that also caps the single-transaction work of repository-local signing enablement (see GPG Signing) |
| `MAX_REPODATA_OPEN_BYTES` | `268435456` | Maximum uncompressed bytes in each generated primary, filelists, or other XML artifact (default 256 MiB); must be a positive integer |
| `RPM_UPLOAD_TMPDIR` | system temp | Node-local directory used for upload/re-sign temporary files and atomic free-space accounting |
| `MAIL_ADAPTER` | `zepto` | Outbound email adapter (Swoosh module). Default uses Zepto Mail. See Email Delivery below. |
| `ZEPTO_API_KEY` | — | Zepto Mail API key (required when `MAIL_ADAPTER=zepto`) |
| `MAIL_FROM_ADDRESS` | — | Sender address for outbound notifications (required for every mail adapter; development may use a non-routable local address with the `local` adapter) |
| `MAIL_FROM_NAME` | `Dark Zenith` | Display name shown for the sender |
| `INVITATION_EXPIRY_DAYS` | `30` | Days before a pending collaborator invitation expires; must be a non-negative integer, and `0` disables expiry |
| `REGISTRATION_ENABLED` | `false` | Whether new account registration is open |
| `ADMIN_EMAIL` | — | Email for the initial admin account, created on first boot if no users exist |
| `ADMIN_PASSWORD` | — | Password for the initial admin account |
| `SOURCE_URL` | `https://github.com/FreedomBen/dark-zenith` | URL of the corresponding source for the running code, rendered as the web UI footer's `Source` link (see Web Interface). Operators deploying a modified version must point this at their modified source to satisfy AGPL §13. |

---

## Email Delivery

Dark Zenith sends transactional emails for:

- Account email confirmation and password reset (via `phx.gen.auth`).
- Collaborator invitations to registered and unregistered users (subject to the registration-disabled exception described under Repository Collaborators).
- GPG signing-key expiry reminders at the 30-, 7-, and 1-day thresholds described under GPG Signing.
- Security notifications to the affected account: password changed or reset, account email changed (sent to the previous address), GPG key uploaded or generated, replaced, or removed, and new API key created.

Email delivery is built on Swoosh with a pluggable adapter selected by `MAIL_ADAPTER`. The application code uses a single `DarkZenith.Mailer` module and a thin notifier layer, so swapping providers is a configuration change rather than a code change. `MAIL_ADAPTER` accepts the following short aliases:

| Alias | Backing adapter | Notes |
|---|---|---|
| `zepto` | Zepto Mail HTTPS API | Default. Requires `ZEPTO_API_KEY` and `MAIL_FROM_ADDRESS`. |
| `smtp` | `Swoosh.Adapters.SMTP` | Configure host, port, username, password, and TLS settings in `config/runtime.exs`. |
| `local` | `Swoosh.Adapters.Local` | In-memory mailbox for development; messages can be viewed at `/dev/mailbox`. The `/dev/mailbox` route is mounted only in the dev Mix environment. |

Unknown aliases cause the application to refuse to boot. `MAIL_FROM_ADDRESS` is required for every adapter because every message needs a sender; with the default `MAIL_ADAPTER=zepto`, `ZEPTO_API_KEY` is additionally required, and with `MAIL_ADAPTER=smtp`, the SMTP connection settings are additionally required. Development and test deployments may set `MAIL_ADAPTER=local` with a non-routable development sender to avoid external mail credentials. Additional Swoosh adapters can be wired in by adding a new alias to this mapping in a future release.

Outbound mail uses `MAIL_FROM_ADDRESS` as the sender and `MAIL_FROM_NAME` (default `Dark Zenith`) as the display name. Every email is dispatched through an Oban worker so a transient provider outage does not fail the originating request. The Oban job is inserted in the same database transaction as the state change that triggers the message, so a successful password/key/account/invitation action cannot commit without also durably recording its notification work. Delivery is at-least-once: a worker crash after provider acceptance but before its success transaction may send the same message again. Delivery jobs use Background Retry Policy, including a valid provider `Retry-After`; exhausted jobs remain visible in Oban for admin intervention.

---

## Deployment

Dark Zenith is designed for straightforward deployment:

- **Mix releases**: Standard Elixir release via `mix release`, producing a self-contained binary.
- **Containers**: Containerfile provided for containerized deployment. `compose.yaml` runs the app with PostgreSQL and MinIO (standing in for B2) under `podman compose` for offline local development. By default every published port binds to `127.0.0.1`; setting `PHX_HOST` to the host machine's LAN IP address for `podman compose up` instead binds the app and MinIO S3 ports to that address and derives generated URLs, presigned MinIO URLs, and the browser-upload origin from it, so the stack (including `dnf` installs) works from other machines on that network. The stack's fixed development credentials are then reachable by anyone on the network, which is why `127.0.0.1` is the default.
- **Systemd**: Example systemd unit file provided.
- **Reverse proxy**: Designed to sit behind nginx/caddy and optionally Cloudflare for TLS termination. Every terminating proxy address or network must be listed in `TRUSTED_PROXIES`; the application discards forwarded client-IP and scheme headers from any other peer before client-IP resolution and `force_ssl` processing. The trusted edge proxy strips client-supplied `CF-Connecting-IP`, `X-Forwarded-For`, and `X-Forwarded-Proto` values and writes its own authoritative values, and the application listen port is not exposed around that edge in production. Only bounded JSON control requests and GPG-key multipart requests traverse that path; RPM `PUT` requests use presigned `B2_ENDPOINT` URLs and bypass the app's proxy and Cloudflare zone. The proxy therefore needs the documented 1 048 576-byte JSON limit and 2 162 688-byte GPG multipart limit, not `MAX_RPM_UPLOAD_BYTES`. Cloudflare's proxied request-body cap does not constrain RPM size in this architecture.
- **B2 browser CORS**: The private bucket has a narrowly scoped CORS rule whose allowed origin is exactly the canonical public Phoenix origin derived from `PHX_SCHEME`, `PHX_HOST`, and `PHX_URL_PORT` (default ports are omitted, as browsers do when serializing `Origin`); allowed method is `PUT`; allowed request header is `Content-Type`; and exposed response header is `x-amz-version-id`. Development origins are added explicitly rather than using `*`. CORS grants browser response access only—it does not make the bucket public—and every upload still requires a valid presigned URL for one exact staging key. Presigned URLs are generated with path-style addressing (`<B2_ENDPOINT>/<bucket>/<key>`) so the browser's `PUT` targets exactly the `B2_ENDPOINT` origin allowed by the `Content-Security-Policy` `connect-src` list; virtual-hosted-style addressing would place the request on a different origin and be blocked.
- **RPM verification and signing tools**: `RPMKEYS_PATH` is required in every deployment because every upload is verified. At boot Dark Zenith resolves the executable, runs its version probe under `LC_ALL=C`, refuses to start unless it is RPM 6.0 or newer, and verifies pristine bundled strong-digest v4/v6 fixtures to detect unusable policy/tool combinations. `gpg` and RPM 6 `rpmsign` are required for GPG-key upload/replacement because every candidate runs the runtime compatibility test, even for metadata-only use; missing tools make that operation return `503 signing_unavailable`. Boot additionally probes configured signing executables when present, while the per-key fixture test remains authoritative for an uploaded key. These native tools process attacker-supplied material, so the example systemd unit confines the application: a dedicated unprivileged user, `NoNewPrivileges=true`, `PrivateTmp=true`, and `ProtectSystem=strict` with write access limited to `RPM_UPLOAD_TMPDIR`; operators not using systemd should apply equivalent confinement. Mounting the node-local `RPM_UPLOAD_TMPDIR` on tmpfs keeps uploaded files, signing working copies, temporary RPM keyrings, and decrypted key material off persistent storage.
- **Health check**: `GET /health` and `HEAD /health` are unauthenticated liveness probes that return `200 OK` with a `text/plain; charset=utf-8` body of `ok` whenever the application is up and serving requests. They perform no database or B2 calls, so they signal process liveness rather than dependency readiness, and they are excluded from rate limiting (see Rate Limiting).
- **Single application node**: The initial version assumes one app node because rate-limit buckets live in node-local memory (ETS). Upload and signing jobs do not require session affinity or a shared temporary filesystem: their durable source is an exact private B2 version, and any node can reconstruct a clean local attempt under its own `RPM_UPLOAD_TMPDIR`. Running multiple nodes still requires a shared rate-limit store and coordinated deployment testing, and is out of scope for the initial version.

### Initial Setup

Since `REGISTRATION_ENABLED` defaults to `false`, the first admin account is bootstrapped via environment variables (`ADMIN_EMAIL` and `ADMIN_PASSWORD`). On first boot, if no users exist in the database, a confirmed admin user is created with these credentials. If no users exist but `ADMIN_EMAIL` or `ADMIN_PASSWORD` is unset, Dark Zenith logs a warning and starts without creating an admin; the operator must restart with both variables set to bootstrap an admin. `ADMIN_EMAIL` and `ADMIN_PASSWORD` must satisfy the same email and password validation rules as regular accounts; if either fails validation, Dark Zenith logs a warning and starts without creating an admin, the same as when the variables are unset. After the initial admin is created, these environment variables are ignored; operators should remove them from the environment after the first successful boot and rotate the bootstrap password from the web UI, since process environments are visible to host tooling. Additional users can be created by the admin or by enabling public registration.

If an existing installation has users but no administrator, an operator can promote one already-confirmed account with `bin/dark_zenith eval 'DarkZenith.Release.promote_admin("user@example.com")'`. The release function normalizes and validates the email, opens a transaction, acquires the same instance-wide transaction-scoped PostgreSQL advisory lock used by bootstrap, every admin-flag mutation, and every admin user deletion, and rechecks that the database has zero admins. It then requires one existing confirmed user at that email, changes only that user's `is_admin` flag, and writes a system-authored `admin.recovery_promote` audit event in the same transaction. It refuses to act if an admin already exists, the user is missing, or the user is unconfirmed; it never creates an account or accepts a password. This makes the recovery command safe to retry and prevents two concurrent operators or a racing bootstrap from promoting multiple recovery admins.

### Storage

RPM files are stored exclusively in a private Backblaze B2 bucket whose anonymous access is disabled. Client uploads go directly to presigned staging keys and download clients are redirected to signed final versions, so neither client-facing payload path consumes app-server or Cloudflare bandwidth. Background workers do read staged bytes into local temporary storage and write or copy accepted final bytes, so worker network, disk, and native-tool capacity must be sized for concurrent processing. The bucket-scoped B2 application key needs only listing, reading, writing/copying, and deleting file versions (`listFiles`, `readFiles`, `writeFiles`, and `deleteFiles`); it must not be account-wide or exposed to clients. A lifecycle rule may retain only the latest version at write-once final keys as defense in depth, but `staging/uploads/` must remain under database-aware exact-version cleanup so delayed retries keep their source. Dark Zenith stores each accepted version ID, signs downloads for that exact version, and permanently deletes versions explicitly. The reconcilers therefore also require permission to list object versions and delete identified versions and delete markers.

---

## Security Considerations

- Mutating actions (create repo, upload RPM, delete) require session auth (web) or bearer token auth (API).
- Mutating actions on a repository are restricted to the repo owner or an admin user. API keys inherit the permissions of their owning user.
- API key and GPG key management endpoints require session token or session cookie authentication; API keys cannot manage API keys or GPG keys.
- Public read-only endpoints (repo browsing, package listing, global search, repodata, RPM downloads) require no authentication for public repos. Search results are visibility-filtered with the same rules as browsing and never reveal data from inaccessible private repositories.
- Private repo read endpoints require authentication. Browser requests may use the user's session; RPM clients use HTTP Basic Auth with API keys for repodata and RPM downloads.
- Signed B2 URLs expire after `B2_SIGNED_URL_TTL` seconds (default 30 minutes), limiting the window for URL sharing/leakage. The 302 responses that carry them, and every response for a private repository, are marked `Cache-Control: private, no-store` so an intermediary cache cannot redistribute them (see Caching headers).
- A signed B2 download URL is an independent bearer capability once issued. Revoking an API key or session, removing a collaborator, making a repository private, or deleting an account prevents issuance of new URLs but cannot revoke an existing URL; it remains usable until its signature expires or that exact object version is permanently deleted. Operators choose `B2_SIGNED_URL_TTL` to match their private-access revocation objective, the UI warns about this bounded delay when private access is revoked, and authorization tests prove both that issuance stops immediately and that the previously issued capability has only its documented residual lifetime.
- Presigned B2 upload URLs expire after `B2_UPLOAD_URL_TTL` seconds (default one hour), authorize only `PutObject` to one random staging key with the signed content type and declared content length, and are returned only over authenticated `Cache-Control: no-store` control responses. They do not reveal the bucket application key. The bucket CORS rule names exact trusted web origins and exposes only the version header needed for completion.
- Unvalidated direct uploads are quarantined under the private `staging/uploads/` prefix and are never reachable through a repository route. Declared-size enforcement, quota reservation, waiting-state expiration, exact-version cleanup, and reconciliation bound normal retention; only a fully validated and optionally signed version can be referenced by a package row.
- Accepted risk: B2's documented S3 `PutObject` surface creates a new version when the same key is written again and does not document a conditional create-only header. A presigned `PUT` is therefore replayable until its signed expiry, so a malicious authorized uploader or leaked URL can temporarily create multiple same-sized staging versions outside `MAX_USER_STORAGE_BYTES`. The one-hour URL, 60-intent/hour issuance limit, no-overlap refresh rule, hourly orphan deletion, bucket billing alerts/budgets, and private non-serving prefix limit exposure and duration, but do not provide a hard instantaneous staging-byte quota; an application outage also delays reconciliation. Operators that require such a hard quota must place uploads behind a metered upload service instead of enabling direct-to-B2 transfer.
- B2 storage keys use server-generated UUIDs and random values rather than client filenames, preventing key manipulation. Completion accepts only the current intent key and an exact B2 version whose length, content type, and absence of attacker-controlled content headers/user metadata match the staging contract. Final copy/write operations replace metadata and are exact-version `HeadObject`-verified before database commit, so a download cannot inherit staging `Content-Disposition`, encoding, cache, redirect, or user metadata.
- GPG private keys are encrypted at rest in the database with the versioned AES-256-GCM envelope described in GPG Signing. They are decrypted only during signing operations and written, when required by `gpg` or `rpmsign`, only inside the mode-restricted ephemeral `GNUPGHOME`; deployments should place `RPM_UPLOAD_TMPDIR` on tmpfs as described above.
- Server-side generated GPG keys use a one-time reveal: the armored private key appears only in the immediate generation response — over the same authenticated TLS channel that delivers freshly created API keys — so the owner can keep an offline backup, and there is no export endpoint. Afterward it exists only as the standard encryption envelope and is excluded from logs, audit metadata, email, and every resource. Because the server is otherwise the key's only holder, that backup is the user's hedge against a `SECRET_KEY_BASE` rotation performed outside the dual-base procedure.
- Rotating `SECRET_KEY_BASE` invalidates Phoenix cookie sessions and all stored HMAC token hashes that use it (API keys and session tokens). Operators must communicate the rotation in advance; users must sign in again and re-create API keys afterward. Upload intents are scoped database resources rather than HMAC bearer tokens, so rotation does not invalidate already staged objects; their normal authenticated ownership and expiry checks still apply. Current and prepared GPG private keys survive `SECRET_KEY_BASE` rotation only when operators follow the dual-base rotation procedure — set `PREVIOUS_SECRET_KEY_BASE` to the prior value while the background re-encryption jobs run and remove it once every ciphertext has been migrated. See the GPG private key encryption envelope section for the full procedure. Per-token envelope versioning for HMAC token hashes is reserved for a future release.
- Downloadable `.repo` files never include API keys, session tokens, or passwords.
- Rate limiting on all dynamic application requests and LiveView application events, with the explicit health/static/transport exclusions in Rate Limiting below.
- CSRF protection on all web form submissions and cookie-authenticated mutating API requests (standard Phoenix behavior).
- Dark Zenith emits no CORS permission headers on its own web, API, or repository-serving endpoints; browser access to those surfaces is same-origin only. The narrowly scoped B2 upload rule is the sole initial cross-origin exception. Any future cross-origin API must name exact trusted origins and may not combine credentialed requests with a wildcard origin.
- Deployments with `PHX_SCHEME=https` (the default) enforce TLS (TLS redirect plus `Strict-Transport-Security` on HTTPS responses) at the Phoenix endpoint even behind the reverse proxy; requests whose host is `localhost` or `127.0.0.1` are exempt from the redirect for host-local checks. Trusted-proxy normalization removes `X-Forwarded-Proto` unless the immediate TCP peer is in `TRUSTED_PROXIES`, and it runs before the TLS redirect; only then does `rewrite_on: [:x_forwarded_proto]` honor the terminating proxy's value so proxied HTTPS requests are not redirect-looped. This prevents a direct HTTP client from spoofing `X-Forwarded-Proto: https` to bypass the redirect. Setting `PHX_SCHEME=http` (local development only) disables the TLS redirect entirely. Session cookies are `http_only` and `SameSite=Lax`, and carry the `Secure` attribute exactly when the request's effective scheme after trusted-proxy normalization is HTTPS — always for a `PHX_SCHEME=https` deployment's authenticated flows, and never under `PHX_SCHEME=http`, where browsers would reject a `Secure` cookie set over plain HTTP from any non-localhost origin. Responses set `X-Content-Type-Options: nosniff`; and web UI responses carry a restrictive, LiveView-compatible `Content-Security-Policy`. Its `connect-src` permits only the app's own HTTP/WebSocket origins plus the exact origin of `B2_ENDPOINT` (HTTPS in production; the offline compose stack's MinIO stand-in uses HTTP), which is required for browser `PUT` requests; it does not wildcard object-storage domains.
- Post-login redirect targets are stored server-side and must be local paths; client-supplied absolute URLs are never used as redirect destinations.
- Request logging never records `Authorization` headers, Basic Auth passwords, token or API key values, GPG key material, or passwords; Phoenix `filter_parameters` covers the password, token, key, and GPG key fields, and URLs are logged without userinfo.
- Security-relevant actions are recorded in an append-only audit log (see Audit Events), and users receive email notifications for password changes and resets, account email changes, GPG key upload or generation, replacement, or removal, and API key creation.
- Deleted repository slugs are retired, not freed: only the deleting owner can reuse one, and only an admin can release it, so a deleted repository's URL cannot be taken over to serve packages to clients that still hold its `.repo` file. Retired reservations accumulate with each deletion; `MAX_USER_REPOSITORIES` caps how many repositories one account holds at once, the 30/hour repository-creation limit bounds how quickly a single user can retire slugs, and admins can release individual retired reservations.
- Authentication is password-only in the initial version; TOTP MFA is a prioritized future consideration (see Future Considerations), a limitation operators should weigh before opening registration or granting `is_admin` on instances exposed to untrusted networks.
- Accepted risk: collaborator-add responses distinguish registered users (`collaborator`) from unregistered addresses (`invitation`), so a repository owner can learn whether an email has an account. This is inherent to the feature and bounded by the 60/hour collaborator-addition limit. Each request is audited and normally queues an email to the target; unregistered targets are not emailed while registration is disabled, and provider failure can also prevent delivery.

---

## Rate Limiting

Every dynamic HTTP request is rate limited except `GET /health`, `HEAD /health`, compiled static assets under `/assets/`, `/favicon.ico`, and `/robots.txt`. Phoenix/LiveView transport setup after the initial HTTP handshake, heartbeat frames, and other protocol bookkeeping are also excluded; user-initiated LiveView application events are not. Limits use UTC-aligned fixed windows keyed by `floor(unix_seconds / window_seconds)`, so every one-minute bucket resets at a wall-clock minute and every one-hour bucket at a wall-clock hour. All applicable counters are consumed once when the request reaches the limiting plug—after the minimum credential or login-email parse needed to choose an identity, but before controller work and before a multipart body is read. Rejected requests consume their attempted slots. The strategy differs by request class and authentication status:

- **Authenticated general requests** (API key, session token, or session cookie): 600 requests per minute per user. All requests from the same user share a single bucket regardless of which API key or auth method is used.
- **Unauthenticated general requests**: 120 requests per minute per IP address. Since multiple users may share an IP (corporate networks, VPNs, NAT), these limits are more restrictive.
- **Authentication attempts** (`/api/v1/auth/login`, the web login route, registration, password reset, and the email-confirmation resend route): 10 requests per minute per IP address and 10 requests per minute per normalized (trimmed, lowercased) syntactically valid email address, whether or not that address has an account. A missing or syntactically invalid email consumes only the IP bucket, so arbitrary invalid values cannot mint email buckets. These buckets apply *in lieu of* the 120/min unauthenticated general bucket — requests to these routes do not also count against the general bucket.
- **Unauthenticated package downloads** (`GET` or `HEAD /repos/:slug/packages/:id/:filename.rpm`): 600 requests per minute per IP address. This bucket applies *in lieu of* the 120/min unauthenticated general bucket for these requests, so large `dnf` transactions against public repositories do not stall mid-install; the endpoint only performs a database lookup and signed-URL generation, so the higher ceiling is cheap for the app server.
- **Authenticated package downloads** (`GET` or `HEAD` on the same route): 1 200 requests per minute per user. This bucket applies *in lieu of* the 600/min authenticated general bucket for these requests. Private repositories can only be fetched with credentials, so without a dedicated bucket an authenticated `dnf` transaction would share a lower effective ceiling with every other API and web request the user makes — inverting the incentive to authenticate described under Authenticated access to public repos.
- **Search queries** (`GET /api/v1/search/packages`, and each executed web search — the `GET /search` request or a subsequent query-submit LiveView event): 30 requests per minute per IP address for unauthenticated requesters and 120 requests per minute per user for authenticated ones, in addition to the applicable general bucket. A search substring-scans every package row visible to the requester, and the initial implementation may serve those scans without dedicated indexes (a trigram index is a future optimization), so the ceiling is deliberately below the general limits. One web search execution consumes one slot even though it also produces the repository result group; `GET /api/v1/repos` with `q` consumes only the general bucket, since the repository table is comparatively small.
- **Package uploads**: 60 new upload intents per hour per user, in addition to the authenticated general request limit. Intent creation is the operation that reserves quota and mints a B2 capability, so it consumes the specialized bucket for both REST and web flows. Refresh, completion, status polling, confirmation, and cancellation consume only the authenticated general bucket; a direct client-to-B2 `PUT` does not reach the application limiter. Refresh is unavailable until the prior URL expires, so it does not intentionally create overlapping live capabilities; an old presigned URL cannot be cryptographically revoked and remains subject to the replay risk described under Security Considerations until its signed expiry.
- **Repository creations** (`POST /api/v1/repos` and the equivalent web action): 30 requests per hour per user, in addition to the authenticated general request limit. Deleting a repository permanently retires its slug until an admin releases it, so bounding creation volume also bounds how quickly one user can accumulate retired slug reservations through create/delete churn. `MAX_USER_REPOSITORIES` separately caps how many repositories one user holds at once.
- **API key creations** (`POST /api/v1/api_keys` and the equivalent web action): 30 requests per hour per user, in addition to the authenticated general request limit. Failed validation and quota conflicts consume slots, and `MAX_USER_API_KEYS` separately bounds retained rows.
- **GPG key mutations** (`PUT` or `DELETE /api/v1/gpg_key`, `POST /api/v1/gpg_key/generation`, `POST /api/v1/gpg_key/revocation`, and equivalent web actions): 10 requests per hour per user, in addition to the authenticated general request limit. Every attempted upload, generation, replacement, removal, or revocation strategy consumes a slot before native-tool work, limiting CPU-heavy key generation and validation and security-notification volume.
- **Collaborator additions** (`POST /api/v1/repos/:slug/collaborators` and the equivalent web action): 60 requests per hour per user, in addition to the authenticated general request limit, bounding the volume of invitation email a single user can trigger. Failed validation and quota conflicts consume slots, and `MAX_REPOSITORY_COLLABORATORS` separately bounds retained rows per repository.
- **Account email change requests** (the web settings action that emails a confirmation link to the proposed new address): 10 requests per hour per user, in addition to the authenticated general request limit, bounding the volume of confirmation email a single user can direct at arbitrary addresses.

A credential selects a per-user bucket only after successful authentication. Missing, malformed, expired, or revoked credentials use the applicable unauthenticated per-IP bucket even when the endpoint subsequently returns an authentication error or masks a private repository as not found. Authentication-attempt routes consume and check the IP bucket before parsing their bounded body; only a syntactically valid email then consumes the second email bucket.

Every rate-limited HTTP response includes `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and `X-RateLimit-Reset`. The remaining value is measured after consuming the current request and is clamped at zero; reset is the governing window's exclusive end as a Unix epoch timestamp in seconds. A request whose atomic post-increment count is less than or equal to the limit is admitted, so the request that consumes the last available slot succeeds with `X-RateLimit-Remaining: 0`; only a count greater than the limit is rejected. When more than one bucket applies, the headers describe the bucket with the smallest remaining allowance; ties choose the earliest reset, then the lower limit. If any applicable bucket is over its limit, endpoint work does not run and the server responds **429 Too Many Requests**, additionally setting `Retry-After` to the positive number of whole seconds until that governing reset. For unauthenticated API and web requests, the JSON/HTML 429 message encourages account creation and authentication for higher limits. Repository-serving endpoints keep the plain-text `rate_limited` body described in the RPM Repository Endpoint section.

The initial LiveView HTTP handshake consumes the applicable general bucket and receives normal HTTP rate-limit headers. Each subsequent user-initiated LiveView event consumes the applicable general bucket — per-user when the socket is authenticated, per-IP otherwise; upload-intent creation, repository creation, API-key creation, GPG-key mutation, collaborator addition, account-email-change, and search-execution events also consume their corresponding specialized bucket under the same rules as HTTP endpoints. When a socket event is rejected, its handler does not run and the server replies with a `rate_limited` payload containing `limit`, `remaining`, `reset`, and `retry_after`; the LiveView displays the error without disconnecting. Heartbeats, reconnect bookkeeping after a successfully limited handshake, server pushes, and internal component messages consume no bucket.

Rate-limit tests exercise each specialized bucket through both HTTP and LiveView, including invalid and conflict responses, the exact last admitted slot, the first rejected slot, and simultaneous atomic increments. API-key and GPG-key buckets are verified to compose with rather than replace the authenticated general bucket.

### Client IP detection

Per-IP rate-limit buckets and the authentication-attempt buckets identify the client using the following resolution order, controlled by the `TRUSTED_PROXIES` configuration:

1. If the connecting TCP peer address is in `TRUSTED_PROXIES` and the request includes a `CF-Connecting-IP` header whose value parses as a valid IP address, use that value. Dark Zenith is expected to sit behind Cloudflare in production, so this hop is checked first and authoritatively overrides any forwarded chain when it is present from a trusted proxy.
2. Else, if the connecting TCP peer is in `TRUSTED_PROXIES` and the request includes `X-Forwarded-For`, walk the comma-separated chain from right to left, skip every address that is itself in `TRUSTED_PROXIES`, and use the first remaining address as the client IP. If that address does not parse as a valid IP address, or every address in the chain is in `TRUSTED_PROXIES`, fall back to the TCP peer address.
3. Otherwise, use the TCP peer address.

When `TRUSTED_PROXIES` is empty, `CF-Connecting-IP`, `X-Forwarded-For`, and `X-Forwarded-Proto` are ignored entirely; the TCP peer address and the connection's own scheme are always used. Operators MUST configure `TRUSTED_PROXIES` to include Cloudflare's published IP ranges (and any additional in-cluster reverse proxies) when running behind Cloudflare; failing to do so causes every request to be bucketed as a single source IP and prevents the trusted-scheme rewrite needed behind TLS termination. Because step 1 accepts `CF-Connecting-IP` from any trusted peer, operators who place additional non-Cloudflare reverse proxies in `TRUSTED_PROXIES` must ensure those proxies are reachable only through Cloudflare or strip client-supplied `CF-Connecting-IP` headers; otherwise a client that can reach such a proxy directly could spoof its rate-limit identity.

For per-IP buckets, IPv6 clients are bucketed by their /64 prefix rather than the full address, since a typical IPv6 allocation makes individual addresses free to mint. Rate-limit state lives in ETS under `{bucket_kind, identity, window_number}` keys with atomic counter updates. A periodic sweep every 60 seconds removes every entry whose fixed-window reset is at or before the sweep time; it never uses attacker-controlled timestamps. This bounds key retention to the active minute/hour windows while allowing arbitrary old windows to be discarded after a process pause.

### Authenticated access to public repos

Public repositories are accessible without authentication, but authenticated requests receive higher rate limits. The web UI setup instructions for public repos include both an unauthenticated `.repo` configuration and an authenticated variant with a placeholder for any active API key with at least one valid scope via HTTP Basic Auth. Users are encouraged to use authenticated access to get per-user rate limiting rather than sharing an IP-based limit with other users.

---

## Future Considerations

These features are out of scope for the initial version but may be added later:

- **TOTP multi-factor authentication**: Prioritized ahead of the rest of this list. Authentication is password-only in the initial version; TOTP (e.g., `nimble_totp`) with recovery codes should be added and become enforceable for `is_admin` accounts.
- **Dedicated GPG key-encryption key**: A `v3` envelope deriving its AEAD key from a dedicated environment variable or KMS instead of `SECRET_KEY_BASE`, so GPG key encryption rotates independently of Phoenix secrets.
- **Isolated signing worker**: Run `rpmsign`/`gpg` under a separate OS user/process boundary so a parsing exploit in the C signing toolchain cannot read application secrets or the database.
- **Delta RPMs (drpm)**: Generate and serve delta RPMs to reduce download sizes for updates.
- **Repository snapshots/versioning**: Point-in-time snapshots of repository state.
- **Checksum-named repodata files**: Serve metadata blobs under checksum-unique `repodata/` paths and briefly retain the previous generation, eliminating the transient checksum-mismatch race during metadata updates.
- **Webhook notifications**: Notify external systems when packages are added/updated.
- **Multi-arch mirroring**: Proxy/cache packages from upstream repositories.
- **Metrics/analytics**: Download counts, popular packages, bandwidth usage dashboards.
- **RPM groups/comps.xml**: Support for package groups and environment definitions.
- **Module metadata (modules.yaml)**: Support for DNF modularity streams.
