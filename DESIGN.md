# Dark Zenith - Product Design

## Overview

Dark Zenith is an Elixir/Phoenix application that serves as a fully-functional RPM package repository. It renders all repository metadata and web pages, while RPM files themselves are stored in Backblaze B2 object storage and served to clients via time-limited signed URLs.

## Major Features

### Web Interface

- **Create new repos**: Authenticated users can create and configure new RPM repositories.
- **Browse existing repos**: Public listing of public repositories, with authenticated users also seeing private repositories they can access.
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

Reservation creation locks the owning user row, reclaims that user's expired reservations, and checks `users.storage_bytes + active reserved_bytes + requested_bytes` against `MAX_USER_STORAGE_BYTES`. When `MAX_USER_STORAGE_BYTES` is `0` the quota is disabled: reservations are still created, adjusted, and consumed so accounting and the admin reserved-bytes view stay accurate, but the ceiling check is skipped and never fails. Direct-upload intent creation reserves the one source version Dark Zenith is willing to accept before issuing a B2 URL; the quota governs accepted and permanent package storage, while replayed presigned writes are separately bounded by staging cleanup and the accepted risk described under Security Considerations. Once optional signing has produced the final size, the worker locks the user and atomically increases or decreases that same reservation to the exact final size; an increase is permitted only if quota remains. A successful package transaction consumes the reservation atomically; failure releases it. A cleanup job runs hourly, but it removes an expired reservation only after confirming no active upload intent or package transaction still owns it. Before consuming an expired reservation, a worker must reacquire the user lock and renew it subject to the quota; if capacity was used meanwhile, it removes any newly written final B2 version and records `conflict_storage_quota_exceeded`.

Final package-mutation transactions use one lock order: owning user, repository, existing package, signing transition and item, upload intent, storage reservation, then live slug reservation; absent row classes are skipped, and bulk operations lock rows within each class by UUID ascending. A transition or upload worker's short initial claim transaction may lock only its own durable item because it releases that lock before external I/O, but its final compare-and-swap transaction follows the global order. This order also applies to deletion and key-transition commits, preventing the quota, deletion, upload, re-sign, and slug-retirement paths from deadlocking one another.

### Signing Transitions

Signing-transition progress is application data and never inferred from the continued presence of Oban job rows.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key; the transition ID stored on the repository or user |
| `kind` | string | `enable_rpm_signing` or `replace_gpg_key` |
| `user_id` | UUID | FK to users with `ON DELETE SET NULL`, nullable — the repository owner or key owner; cleared if that account is later deleted so transition rows can be retained for audit |
| `repository_id` | UUID | Repository UUID snapshot (no FK constraint) for `enable_rpm_signing`, deliberately retained if the repository is later deleted; null for user-wide `replace_gpg_key` |
| `target_fingerprint` | string | Exact signing-key fingerprint every item must use |
| `status` | string | `active`, `failed`, `completed`, or `canceled` |
| `inserted_at` | timestamp | Transition creation time |
| `updated_at` | timestamp | Last state change |
| `completed_at` | timestamp | Completion/cancellation time; null while active or failed |

### Signing Transition Items

One row represents the durable outcome required for one package in a signing transition.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key; Oban jobs carry this ID |
| `transition_id` | UUID | FK to Signing Transitions |
| `repository_id` | UUID | Repository UUID snapshot (no FK constraint) of the repository containing the package when the item was created; deliberately retained if the repository is later deleted |
| `package_id` | UUID | Immutable package-ID snapshot; deliberately retained if the package is later deleted |
| `expected_storage_path` | text | Package storage path the item is allowed to replace |
| `expected_storage_version_id` | text | Exact immutable B2 source version the item must download and is allowed to replace |
| `status` | string | `pending`, `executing`, `succeeded`, `failed`, or `canceled` |
| `attempts` | integer | Persistent attempt count, incremented when a worker claims the item |
| `next_attempt_at` | timestamp | Earliest time a pending item may be claimed; null while executing or terminal |
| `lease_token` | UUID | Random fencing token for the current claim; null outside `executing` |
| `lease_expires_at` | timestamp | Renewable execution lease; null outside `executing` |
| `last_error_code` | string | Latest sanitized attempt error, retained while pending for diagnosis and cleared on success/admin reset |
| `inserted_at` | timestamp | Item creation time |
| `updated_at` | timestamp | Last state change |
| `completed_at` | timestamp | Success/failure/cancellation time; null while pending or executing |

**Unique constraint**: `(transition_id, package_id)`

Database checks make claim state unambiguous: `pending` requires non-null `next_attempt_at` and null lease/completion fields; `executing` requires both lease fields and null `next_attempt_at`/`completed_at`; every terminal state requires `completed_at` and null scheduling/lease fields; and `failed` additionally requires `last_error_code`. Initial items are `pending` with `attempts = 0` and `next_attempt_at = inserted_at`.

A worker transaction locks and claims a pending item whose `next_attempt_at` is due and whose parent transition is `active` or `failed`, increments `attempts`, clears `next_attempt_at`, assigns a fresh `lease_token`, and sets a 15-minute lease before doing external I/O; it renews that lease every five minutes with `WHERE lease_token = <claim token>`. `failed` means at least one sibling needs intervention, not that otherwise-pending work is frozen. Duplicate jobs no-op when the item is already succeeded or canceled, not yet due, or the parent is completed or canceled. A 60-second sweep clears the token on an expired `executing` lease, returns the item to `pending`, calculates its retry time, and ensures a scheduled job exists. Every state-changing query and the final package compare-and-swap include the claim's `lease_token`, so a paused worker cannot commit after a replacement worker has claimed the item.

Each claim is a clean attempt: it creates a new mode-`0700` working directory named from the item ID and lease token, downloads `expected_storage_path` at `expected_storage_version_id`, revalidates the immutable source, and never resumes or trusts a partial local file from an earlier claim. It signs only a local working copy and writes any candidate result to a fresh final object key. Normal exits remove the attempt directory in an `after`/cleanup path. An hourly janitor removes app-owned attempt directories older than one hour only when their encoded token is not a current unexpired lease; it never follows symlinks or removes paths outside `RPM_UPLOAD_TMPDIR`. A process exit, node restart, lost lease, partial `rpmsign` output, or transient tool, database, or B2 error therefore leaves the source unchanged; after lease expiry, a new claim starts from the exact source version. A candidate B2 version uploaded before a crash or lost final compare-and-swap is unreferenced and is removed by immediate best-effort cleanup or the orphan reconciler. A successful database commit enqueues deletion of the old exact version in the same transaction, so a crash after commit can delay cleanup but cannot cause the signing work to be repeated or rolled back.

Every `rpmkeys`, `rpmsign`, and `gpg` child runs in its own process group with a hard `RPM_TOOL_TIMEOUT_SECONDS` deadline (default 1 800 seconds). The worker continues renewing its lease while awaiting the child. If renewal updates zero rows because the token was canceled or superseded, or when the deadline arrives, it sends `TERM` to the group, waits 10 seconds, sends `KILL` if needed, and discards the attempt directory. A timeout records a transient tool-unavailable error so the normal durable retry schedule applies; a lost lease records nothing because its replacement state is already authoritative. A hung or superseded native tool therefore cannot keep an item executing forever.

Deterministic contract failures—invalid package integrity, expired key, metadata limit, or storage quota—make the item and transition `failed` immediately with their stable error code. Transient tool, database, interruption, or B2 failures return the item to `pending` until the twentieth failed claim, which makes it terminally `failed`. For failed claim number `n`, the durable retry delay is `min(3600, 30 * 2^(n - 1))` seconds; `next_attempt_at` is written in the same transaction that relinquishes or reclaims the lease, and the sweep repairs a missing Oban row. Oban job uniqueness is only an efficiency measure, and duplicate delivery remains safe because durable item state and lease fencing are authoritative. Admin replay explicitly resets selected failed items to `pending`, `attempts = 0`, and `next_attempt_at = now()` with a fresh attempt budget; the audit event retains the prior attempt count. Normal package deletion marks every item for that package that is not already `succeeded` or `canceled` — pending, executing, or failed — `canceled` in the deletion transaction, and repository deletion likewise cancels the repository's active or failed transitions and its items under the same rule in its own deletion transaction (see Package Upload & Processing); a worker that races with an already-committed deletion also locks the item and marks it canceled as a no-op. Transition rows and items are retained for audit and troubleshooting even if Oban prunes its own terminal rows.

Fault-injection tests terminate a worker after source download, during `rpmsign`, after candidate upload but before the database transaction, after lease expiry while a replacement worker runs, and after database commit but before cleanup. They assert that the next claim starts from `expected_storage_version_id`, only one fenced compare-and-swap can succeed, the committed package verifies with the target key, `attempts`/`next_attempt_at` follow the formula, old and candidate orphan versions are eventually deleted, and an already-successful item is never signed again.

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
| `preview_metadata` | jsonb | Extracted `rpm_format`, NEVRA, summary/description/URL/license, source/group/vendor/buildhost fields, installed/archive/build values, dependencies, files, and changelogs using package-detail shapes; null until `preview_ready` and always null for `api` mode |
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

Creating an intent authenticates and authorizes the uploader, validates the filename and declared size, preallocates `package_id`, and creates a reservation for `declared_size` while holding the repository owner's quota lock. It generates a random staging key containing at least 128 bits of server entropy and returns the current generation plus a presigned B2 `PutObject` URL, valid for at most one hour and never past the intent's two-hour `expires_at`, bound to that exact key, the `PUT` method, `Content-Type: application/x-rpm`, and `Content-Length: <declared_size>` through SigV4 signed headers. A browser sends a `File`/`Blob` body of that known size and lets the user agent set the forbidden `Content-Length` header; non-browser clients set it explicitly. A missing or different signed header makes B2 reject the request, limiting each replay to the reserved size. The application key and arbitrary bucket operations are never delegated. A URL may be refreshed only while the intent is `awaiting_upload`, its current `upload_url_expires_at` has passed, and at least 60 seconds remain before the intent expires; before URL expiry, an interrupted transfer restarts from byte zero with the existing URL. Refresh atomically increments `upload_generation`, replaces the staging key with a fresh random key, caps the new URL at the unchanged intent expiry, and schedules every version at the abandoned key for cleanup. Completion supplies both that generation and the B2 response's `x-amz-version-id`. Dark Zenith performs `HeadObject` against the generation's exact key and version, independently requires its byte length to equal `declared_size` and its content type to be `application/x-rpm`, and then atomically stores the version, clears `upload_url_expires_at` and the waiting `expires_at`, sets `status = "queued"` and `next_attempt_at = now()`, and enqueues processing. It never trusts an ETag as an integrity digest.

Completion is idempotent for the already accepted version. A new completion requires an unexpired `awaiting_upload` intent; an overdue row is atomically expired and cleaned instead. A different version, a stale upload generation, or completion after refresh/terminal state returns `409 conflict_upload_state`; a nonexistent version or length/content-type mismatch returns `422 validation_failed`, permanently deletes that exact version when it exists, and leaves the intent awaiting another `PUT` on the current URL or a refresh after that URL expires. Reusing a presigned URL can create extra B2 versions, but only the version accepted by the compare-and-swap can be processed; the staging orphan reconciler removes every other version.

Processing uses the same 15-minute lease, five-minute renewal, random fencing token, clean-attempt workspace, `next_attempt_at` scheduling, exact retry-delay formula, and 20-attempt transient budget as Signing Transition Items. The worker streams the exact staging version to a new local file, validates the measured byte count against `declared_size` and computes the SHA-256 while downloading, and no-ops unless its token still owns the lease. An expired `processing` lease is requeued by the 60-second sweep. The sweep and active worker also renew the associated storage reservation two hours ahead while an intent is queued or processing, preserving its quota claim during infrastructure downtime. Deterministic validation and conflict outcomes fail immediately; infrastructure errors and process interruption requeue durably. For web mode, the first successful processing pass stores `preview_metadata`, changes the status to `preview_ready`, sets both the intent and reservation to expire in 15 minutes, and retains the immutable staging object. Confirmation reauthorizes the same user, changes `preview_ready` back to `queued`, sets `attempts = 0` and `next_attempt_at = now()`, clears `last_error_code` for a fresh final-processing retry budget, renews the reservation two hours ahead, and runs a new processing attempt from B2; no node-local preview file is durable state. API mode proceeds directly to final storage.

On success, the package transaction marks the intent `succeeded` and enqueues staging cleanup atomically. A crash after that commit can delay deletion but cannot repeat the package insert. Cleanup permanently deletes the accepted exact version and lists/deletes every sibling version at that exact random staging key; for an `awaiting_upload` intent with no accepted version, it lists and deletes every version at the key. It never issues an unversioned delete. Terminal failure, cancellation, or expiration releases the reservation and enqueues the same key-scoped version-aware cleanup; terminal intent rows remain for 24 hours so clients can read the outcome, then an hourly cleanup job deletes them. Waiting-state cleanup runs every 15 minutes and expires only overdue `awaiting_upload` or `preview_ready` rows; accepted `queued`/`processing` work remains governed by its durable retry budget rather than a wall-clock upload deadline. Repository or initiating-user deletion first records the same staging keys and known versions, then deletes the intent rows in the same transaction — fencing any active worker through the removed durable state — and enqueues cleanup after that transaction commits.

Upload integration and fault-injection tests cover current supported browsers performing a CORS `PUT` with signed content length, rejection of a different length/content type, URL refresh/completion races, a reused presigned URL that creates multiple same-sized versions, a client disconnect after completion, web confirmation after an app restart, and the same worker interruption points as signing transitions. They assert exact-version selection, reservation retention across transient attempts, deterministic terminal cleanup, metadata equality on confirmation, one package insert, and eventual deletion of every unreferenced staging/final version.

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

Users can create multiple API keys with different scopes and names (e.g., a `repo:read`-only key for CI pulls, a scoped key for uploads). API key creation requires at least one valid scope. Admin users' API keys operate on all repos, not just their own (e.g., an admin key with `package:upload` can upload to any repo).

**Note**: Public repositories do not require `repo:read` — they are accessible without authentication. However, authenticated requests to public repos (using any non-expired API key with at least one valid scope) benefit from higher rate limits (see Rate Limiting).

**API Key Format**: API keys are generated from 32 bytes of cryptographically secure random data, encoded as unpadded base64url, and returned to the caller as `dzak_<secret>`. The plaintext key is shown only once at creation. The database stores `key_prefix` for display and `key_hash`, computed as `HMAC-SHA-256(SECRET_KEY_BASE, full_key_string)` and encoded as lowercase hex, where `full_key_string` is the complete returned value including the `dzak_` prefix. API key creation rejects empty scopes and unknown scope values with `422 validation_failed`. Expired keys and any persisted keys with no scopes are rejected as invalid credentials with `401 unauthenticated` before any scope-based authorization check (surfaced as `404 not_found` on requests where the private-repository masking rule in API Contract Details applies).

### Repository Collaborators

Repo owners and admins can grant other users read access to private repositories. When the invited email address, after normalization, matches an already registered user, a collaborator record is created immediately. When the normalized email does not match a registered user, a pending invitation is created instead and converts to a collaborator record when a matching user account is created. The invited user receives an email notification: registered users get a direct link to the repository, and unregistered invitees get a registration link that converts the pending invitation on signup. New deliverable invitations start with `notification_status = "queued"`; successful provider delivery changes it to `sent`, while an exhausted delivery changes it to `failed`. When `REGISTRATION_ENABLED = false`, pending invitations to unregistered addresses are still created so they convert automatically once an admin provisions the account, but no email is queued and `notification_status` is `suppressed`. The inviting user is shown a UI notice indicating that an admin must create the account before the invitation can be accepted, and API clients read the same fact from `notification_status`.

An idempotent add request does not duplicate an already queued or sent notification. It queues a new delivery generation when the existing unexpired invitation is `failed`, or when it is `suppressed` and registration has since been enabled; it remains suppressed while the address is unregistered and registration is disabled. Refreshing an expired-but-uncleaned invitation always increments its delivery generation and either queues or suppresses the replacement notification under the same rule.

Collaborator and invitation rows are retained when a repository is made public: they have no effect while `is_public = true` and become effective again if the repository returns to private. Owners and admins can remove collaborators and cancel invitations regardless of repository visibility; only adding is restricted to private repositories.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories |
| `user_id` | UUID | FK to users — the collaborator being granted access |
| `inserted_at` | timestamp | Creation time |

**Unique constraint**: `(repository_id, user_id)`

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

When a user account is created with a normalized email that has pending invitations, whether by public registration or admin provisioning, those invitations are automatically converted to collaborator records and the invitation rows are deleted. The same conversion runs when an existing user confirms an account email change to a normalized email that has pending invitations (see User Lifecycle). Invitations expire `INVITATION_EXPIRY_DAYS` days after creation or their most recent explicit expiry refresh (default 30; `0` disables expiry and stores `expires_at` as null), bounding how long a stale invitation to an unregistered address remains a standing access grant. Expired invitations are never converted: conversion skips and deletes them, and a periodic cleanup job that runs hourly deletes expired invitation rows. User and collaborator-invitation email addresses use the same validation rules as `phx.gen.auth`: values are trimmed, lowercased, capped at 160 characters after trimming, and rejected with `422 validation_failed` when they fail the email format rules.

Queuing a delivery always increments `notification_generation`, so a deliverable invitation's first queued delivery is generation `1`, and a suppressed invitation remains at the default `0` until its first delivery generation is queued. Invitation mail jobs are unique on `(invitation_id, notification_generation)`. Before sending, a worker reloads the row and no-ops unless both the generation and `queued` status still match. Provider success atomically changes the row to `sent` and records `notification_sent_at`; a retryable failure leaves it queued, and the twentieth failure changes it to `failed` before the Oban job is discarded. A later explicit re-attempt increments `notification_generation`, clears `notification_sent_at`, and queues a new unique job, so a delayed worker from an older generation can never overwrite newer state. Delivery is necessarily at-least-once across the external provider and PostgreSQL: a process crash after provider acceptance but before the `sent` update may deliver the same generation twice. The message and audit metadata carry the stable invitation ID and generation for diagnosis, but the design never claims exactly-once email.

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
| `gpg_key_expires_at` | timestamp | Expiration of the selected signing key/subkey; null when it does not expire |
| `gpg_key_expiry_notified_days` | jsonb | Set of reminder thresholds already delivered for the current key (`30`, `7`, `1`), reset on upload/replacement (default `[]`) |
| `previous_gpg_key_public` | text | Optional ASCII-armored previous public GPG key, retained while a GPG key replacement is mid-transition so clients can still verify signatures made with the previous key; cleared after affected metadata caches have reached the current revision and every per-package re-sign job for the user's repositories has completed successfully (or been canceled by package or repository deletion), or immediately when the user's GPG key is removed |
| `gpg_key_transition_id` | UUID | FK to Signing Transitions; active GPG key replacement transition while `previous_gpg_key_public` is set, cleared in the same transaction that clears `previous_gpg_key_public` (default `null`) |
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
| `target_id` | UUID | Affected resource id; null when not applicable |
| `ip` | string | Client IP as resolved by the client IP detection rules; null for system events |
| `metadata` | jsonb | Event-specific details (e.g., package NEVRA, invited email, changed setting names), default `{}`; never contains secrets, token values, or key material |
| `inserted_at` | timestamp | Event time |

Audited actions: successful and failed logins (web and API), password changes and resets, account email changes, account registration and admin account creation, API key creation and revocation, GPG key upload, replacement, removal, and revocation strategies, repository creation, settings changes, and deletion, upload-intent creation/refresh/cancellation and terminal package-upload outcomes, package deletions, collaborator additions and removals, invitation creation, cancellation, conversion, and expiry refresh, signing-transition item reset and transition cancellation, admin-flag changes, recovery promotion, user deletion, and slug-reservation releases. Audit metadata records intent IDs, generation numbers, sizes, and stable result codes but never presigned URLs or B2 version IDs. Failed-login volume is bounded by the authentication-attempt rate limits. Admins browse the audit log in the admin UI.

### Authorization

- **Owner**: A user owns the repositories they create. Only the owner and admins can modify (update, delete, upload to) their repositories. Owners can add collaborators to their private repos.
- **Collaborator**: A user granted read access to a private repository by its owner or an admin. Collaborators can browse, view packages, and download RPMs from that repo. They cannot modify the repo or upload packages.
- **Admin**: Users with `is_admin = true` can perform any action on any repository, manage users, and access admin-only features.
- **Public**: Unauthenticated users can browse public repos, view packages, and download RPMs. No authentication is required for read-only access to public repositories.
- **Private repos**: When `is_public = false`, all access (including repodata and RPM downloads) requires authentication. Only the owner, collaborators, and admins can access private repos.

### User Lifecycle

- User accounts are created via web registration (when `REGISTRATION_ENABLED = true`) or by an admin in the admin web UI. There is no REST API for user creation or deletion; admin user management is web-only. Web-registered users must complete the `phx.gen.auth` email-confirmation flow before they can log in. Both the web login path (customized on top of `phx.gen.auth`) and the API login endpoint (`POST /api/v1/auth/login`) reject any user whose `confirmed_at` is null with the standard invalid-credentials response. Admin-created users are auto-confirmed: `confirmed_at` is set at creation time so the new account can log in immediately, and no confirmation email is sent (mirroring the bootstrap admin behavior). While `REGISTRATION_ENABLED = false`, the registration routes return the standard HTML 404 response and the web UI renders no registration links.
- Users can change their account email through the standard `phx.gen.auth` settings flow: the change takes effect only when the user confirms it from a link emailed to the proposed new address, which must pass the same normalization, validation, and uniqueness rules as registration. On confirmation, pending collaborator invitations addressed to the new normalized email are converted to collaborator records exactly as at account creation, a security-notification email is sent to the previous address, and the change is recorded in the audit log.
- The `is_admin` flag is managed only in the admin web UI: an admin can grant or revoke it on any user other than themselves. Because admins can never change their own flag, the last remaining admin cannot demote itself. Bootstrap, recovery promotion, and every web admin-flag mutation acquire one shared instance-wide transaction-scoped PostgreSQL advisory lock and recheck their preconditions under that lock. There is no REST API for admin-flag management.
- An admin can delete a user account from the admin UI, but the deletion is rejected with `409 conflict_user_owns_repositories` if that user still owns any repositories. The admin must first delete those repositories.
- Users cannot delete their own accounts; account deletion is admin-only, and an admin cannot delete their own account, so — together with the self-demotion rule above — the last remaining admin cannot remove itself.
- When a user is deleted, the database cascades remove their API keys, session tokens, GPG key, upload intents they initiated, and pending collaborator invitations they sent, removes any collaborator membership rows where they are the collaborator, and deletes any pending collaborator invitations addressed to the deleted user's normalized email so a later re-registration with the same email does not silently re-attach to old invites. Before deleting upload intents, the transaction records their accepted exact staging versions and current uncompleted staging keys so version-aware cleanup and orphan reconciliation can reclaim every direct-upload object, and releases any storage reservations attached to those intents (the reservation's quota user is the repository owner, who may differ from the deleted initiator); workers are fenced by the deleted durable state. Repositories owned by other users on which the deleted user was a collaborator are otherwise unaffected. Retired slug-reservation rows from repositories the user previously deleted are retained with `user_id` cleared, so those slugs stay reserved until an admin releases them, and audit events keep their `actor_email` snapshot while `actor_id` is cleared. Signing transitions the user owned, and their items, are likewise retained for audit: any transition still `active` or `failed` is marked `canceled` in the deletion transaction (its items were already canceled when the user's repositories were deleted, so no worker can still act on it), and the transition's `user_id` is cleared through `ON DELETE SET NULL`.

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

- **`primary.xml.gz`**: Contains package names, versions, architectures, summaries, sizes, checksums, and dependency information (requires, provides, conflicts, obsoletes). This is the main metadata file used for dependency resolution. Each package entry also includes the standard "primary files" subset of that package's file list — paths under `/etc/`, paths containing `bin/`, and `/usr/lib/sendmail` — matching `createrepo_c` behavior so file-path dependencies on common paths (e.g., `/bin/sh`) resolve without downloading filelists. Each package's `<location>` element uses the relative path `packages/:id/:name-:version-:release.:arch.rpm` (the standard RPM filename, with no epoch component), so RPM clients resolve downloads against the repository base URL. The route is keyed by package UUID, so the filename segment is cosmetic and does not need to match the B2 storage key, which includes the epoch. Each package's `<time>` element sets `file` to the package row's `inserted_at` and `build` to `build_time`, falling back to `inserted_at` when `build_time` is null, both as Unix epoch timestamps in seconds. Each package's `<size>` element sets `package` to the package row's `size_package`, `installed` to `size_installed`, and `archive` to `size_archive`, omitting the `archive` attribute when `size_archive` is null (dnf/libsolv reads each size attribute independently); the `<packager>` element is not emitted, since the RPM `PACKAGER` tag is not stored, and dnf likewise tolerates its absence. Each package's `<format>` block emits `rpm:license`, `rpm:vendor`, `rpm:group`, `rpm:buildhost`, `rpm:sourcerpm`, and `rpm:header-range` (`start` = `header_start`, `end` = `header_end`) alongside the dependency elements, matching `createrepo_c`; the optional string elements are omitted when their column is null.

- **`filelists.xml.gz`**: Lists all files contained in each package. Used when a user runs commands like `dnf provides /usr/bin/something`. File entries are emitted with `type="dir"` for directories and `type="ghost"` for files carrying the `ghost` flag (ghost takes precedence when both apply); symlinks and regular files are emitted as plain `<file>` entries, matching `createrepo_c`. The same mapping applies to the primary files subset embedded in `primary.xml.gz`.

- **`other.xml.gz`**: Contains changelog entries for each package. Only the 10 most recent changelog entries per package (by changelog timestamp, with equal timestamps retaining their original RPM header order) are emitted, matching the `createrepo_c` default, to keep the file small for clients; the full changelog remains on the package row and is served by the web UI and API.

Generated XML is UTF-8 and is built with an XML encoder: every text and attribute value is escaped according to XML rules rather than interpolated as raw markup. `primary.xml` uses the `http://linux.duke.edu/metadata/common` default namespace and the `http://linux.duke.edu/metadata/rpm` `rpm` namespace. `filelists.xml` uses the `http://linux.duke.edu/metadata/filelists` namespace. `other.xml` uses the `http://linux.duke.edu/metadata/other` namespace. `repomd.xml` uses the `http://linux.duke.edu/metadata/repo` namespace. Each of `primary.xml`, `filelists.xml`, and `other.xml` carries that generation's package count as the `packages` attribute on its root element (`<metadata>`, `<filelists>`, and `<otherdata>` respectively). Package entries in `primary.xml` carry `<checksum type="sha256" pkgid="YES">` holding the package row's `sha256`; entries in `filelists.xml` and `other.xml` are keyed by that same `pkgid` value and repeat the package `name`, `arch`, and `<version epoch= ver= rel=>` element, matching `createrepo_c`.

`repomd.xml` includes a `<revision>` element set to the `metadata_revision` value the generation ran against (the same value stored as the cache row's `source_revision`). This is a deliberate deviation from `createrepo_c`, which writes a Unix timestamp there: `dnf`/`librepo` treat `<revision>` as an opaque string, and a monotonic revision makes cache staleness directly checkable against `source_revision`. Mirroring tools that interpret `<revision>` as a timestamp will therefore read a small integer, and should compare the `<data>` `timestamp` values instead. `repomd.xml` contains one `<data>` entry each for `primary`, `filelists`, and `other`. Each entry uses a fixed `location href` of `repodata/primary.xml.gz`, `repodata/filelists.xml.gz`, or `repodata/other.xml.gz`; `checksum` and `open-checksum` both carry `type="sha256"` and hold lowercase hex SHA-256 digests of the compressed and uncompressed metadata bytes respectively; `size` and `open-size` are byte counts; and `timestamp` is a Unix epoch timestamp in seconds. Metadata generation captures one UTC generation timestamp at the start of each generation run — in the regeneration job, or in the synchronous run at repository creation — truncated to whole seconds, and uses that value for all three `repomd.xml` data entries. Gzip output is deterministic for identical XML input: compression level is `6`, `mtime` is `0`, and no original filename is stored in the gzip header.

### Metadata Generation & Storage

All repodata XML is generated by the app and served directly from the app (not from B2). The metadata is stored in PostgreSQL as cached blobs so it can be served without regeneration on every request. The initial release supports at most `MAX_REPOSITORY_PACKAGES` packages per repository (default 10 000), and each of the three uncompressed XML artifacts is capped at `MAX_REPODATA_OPEN_BYTES` (default 268 435 456 bytes, 256 MiB).

Package creation, deletion, and re-signing lock the repository row and update `package_count`, `primary_open_bytes`, `filelists_open_bytes`, and `other_open_bytes` in the same transaction as the package mutation. The deterministic XML encoder can render an individual package's entries to a counting sink, so a mutation computes its exact byte delta without materializing a whole repository document; the calculation also accounts for the root element and any change in the decimal `packages` attribute. An upload that would exceed the package-count limit or any projected uncompressed-artifact limit is rejected with `409 conflict_repository_metadata_limit_exceeded` during upload processing — before the storage reservation is adjusted to the final size and before any final B2 write — with the authoritative recheck in the final package transaction. A re-sign item that would cross a metadata limit fails with that same persistent error code and requires package deletion, a higher configured limit, or an admin retry after remediation. A release whose XML serialization changes must include a migration that recalculates all four counters before the new encoder runs.

Metadata is regenerated as a background job (via Oban) when packages are added to or removed from a repository, or when repository settings that affect generated metadata change. Repository creation is the exception: initial empty metadata is generated synchronously during creation so a new empty repo has a current cache before it is exposed. The regeneration process:

1. Package upload/deletion increments the repository's `metadata_revision` inside the same database transaction that changes package membership.
2. The transaction enqueues a unique Oban regeneration job for the affected repository. On deletion, a separate idempotent Oban job permanently removes the exact RPM object version after the package row is removed. Version-aware B2 cleanup jobs treat an already-absent version as success and retry only other object-storage errors.
3. The regeneration job reads the current repository `metadata_revision` and its maintained size counters, then queries all packages in the repository in deterministic order by `name`, `epoch`, `version`, `release`, `arch`, and `id`, all within one database transaction using a single consistent snapshot so the captured revision, the counters, and the package set cannot skew against one another.
4. Each XML artifact is encoded incrementally to a mode-`0600` temporary file under `RPM_UPLOAD_TMPDIR` while its SHA-256 and byte count are calculated. The encoder never constructs a complete XML document in BEAM memory and aborts defensively if an actual byte count exceeds `MAX_REPODATA_OPEN_BYTES` or differs from the repository's maintained counter. Each completed XML file is then streamed through gzip level 6 to a second mode-`0600` temporary file, with gzip `mtime = 0` and no original filename; compressed checksums and sizes are calculated during that pass.
5. A new `repomd.xml` is generated with checksums pointing to the current metadata files.
6. The generated metadata blobs, `repomd.xml`, optional `repomd.xml.asc` signature, and `source_revision` are stored in PostgreSQL keyed by repository. The update applies only when the generated `source_revision` is strictly greater than the stored value (or inserts when the cache is missing), so a slower job can never move the cache backward and two jobs for the same revision cannot replace one another with different generation timestamps or signature creation times. A job that finds the cache already at or beyond its captured revision skips generation. Temporary files are removed after the database write, lost compare-and-swap, or any failure.
7. Before completing, the job reloads the repository. If `metadata_revision` is greater than the cached `source_revision`, the job enqueues another unique regeneration job so the final cache reflects the latest package set.
8. The repo endpoint serves metadata directly from the cache once the cache `source_revision` matches the repository's current `metadata_revision`.

Repository creation claims its slug reservation, writes the repository row, generates empty `primary.xml.gz`, `filelists.xml.gz`, `other.xml.gz`, `repomd.xml`, and optional `repomd.xml.asc`, and writes the metadata-cache row with `source_revision = 0` in the same database transaction. A creation that reuses the creator's own retired slug changes that reservation back to live through the conditional claim described under Slug Reservations. Newly created empty repos therefore immediately serve valid metadata from the cache. If a repository is created with `gpg_key_fingerprint` set and synchronous `repomd.xml` signing fails for an infrastructure reason, the transaction is rolled back and the caller receives `503 signing_unavailable`; validation failures still return `422 validation_failed`. Repository setting changes that affect generated metadata, such as enabling/disabling metadata signing or changing `gpg_key_fingerprint`, use the same `metadata_revision` increment and regeneration enqueue path.

Metadata endpoints return `503 Service Unavailable` with plain text body `metadata_not_ready` and `Retry-After: 5` when the cache row is missing or its `source_revision` is older than the repository's current `metadata_revision`. The endpoint does not generate metadata inline and does not serve stale metadata for an out-of-date revision.

Multiple rapid changes are debounced with an Oban unique job keyed by `repository_id` while the job is available or scheduled. Running jobs are allowed to be followed by a newly queued job, and the `metadata_revision`/`source_revision` check guarantees another job runs until the cache reaches the latest revision. If `repomd.xml` signing fails for an infrastructure reason during a regeneration job, the job fails without writing the cache row, so the previous cache is left intact and metadata endpoints keep returning `503 metadata_not_ready` for the newer revision until a retry succeeds. Metadata regeneration and B2 cleanup jobs retry up to 20 attempts with exponential backoff; exhausted jobs remain visible in Oban for admin intervention.

Because metadata files are served at fixed `repodata/` paths from a single cache row, a client that fetches `repomd.xml` and the referenced blobs across a regeneration boundary can observe checksum mismatches for that fetch cycle. This transient race is accepted for the initial version: the affected metadata fetch fails, and a retry refetches `repomd.xml` and succeeds against the new consistent generation. Serving checksum-named metadata files with retained previous generations would eliminate the race and is listed under Future Considerations.

### RPM File Downloads

When a client (e.g., `dnf`) requests an RPM file at `/repos/:slug/packages/:id/:filename.rpm`:

1. Dark Zenith validates access to the repository identified by `:slug`, then validates that the final path segment — the `:filename` capture together with its `.rpm` extension — matches `^[A-Za-z0-9._+~-]+\.rpm$`; non-matching requests are rejected with `400 invalid_request`. It then looks up the package record by `:id` scoped to that repository in PostgreSQL to find the B2 storage key and exact `storage_version_id`. The `:filename` segment is otherwise cosmetic (ignored for routing) but provides a human-readable filename for download clients.
2. Generates a **signed Backblaze B2 URL** for that exact object version using `B2_SIGNED_URL_TTL` (default **30-minute expiration**). If B2 signed URL generation fails for an infrastructure reason, the endpoint returns `503 storage_unavailable`.
3. Responds with **HTTP 302 redirect** to the signed URL.
4. The client downloads the RPM directly from B2.

This keeps RPM file bandwidth off the app server entirely.

Repository-serving endpoints intended for RPM clients (`/repos/:slug/repodata/...`, `/repos/:slug/packages/:id/:filename.rpm`, `/repos/:slug/RPM-GPG-KEY`, and `/repos/:slug/dark-zenith.repo`) use plain-text error responses. On these endpoints, 4xx and 5xx errors such as `400 invalid_request`, `401 unauthenticated`, `403 forbidden`, `404 not_found`, `429 rate_limited`, `503 storage_unavailable`, and `503 metadata_not_ready` return a `text/plain; charset=utf-8` body whose contents are the error code string and nothing else. Web UI routes under `/repos/:slug` keep their normal HTML responses, and `/api/v1/...` endpoints use the JSON `{"error": {...}}` envelope. Successful responses on these repository-serving endpoints use the following `Content-Type` values: `repomd.xml` is served as `application/xml`; `primary.xml.gz`, `filelists.xml.gz`, and `other.xml.gz` as `application/gzip`; and `repomd.xml.asc`, `RPM-GPG-KEY`, and `dark-zenith.repo` as `text/plain; charset=utf-8`.

Every repository-serving `GET` route also accepts `HEAD`. A `HEAD` request performs the same authentication, authorization, rate-limit, and conditional-request work as `GET`, and returns the same status and representation headers but never a response body. Package downloads still return `302 Location`, but the location is a method-specific presigned B2 `HeadObject` URL; Dark Zenith never reuses a presigned `GetObject` URL for `HEAD`, because the HTTP method is part of the SigV4 signature.

### Caching headers

Dark Zenith is expected to run behind a shared cache (Cloudflare in production), so every repository-serving response states its cacheability explicitly rather than relying on a proxy's defaults:

- **Package download redirects** (`/repos/:slug/packages/:id/:filename.rpm`, public or private): `Cache-Control: private, no-store`. The 302 carries a signed B2 URL that is valid for `B2_SIGNED_URL_TTL` seconds; a shared cache that stored it would hand one client's time-limited URL to every other client, and would keep serving it after the underlying object was re-signed or deleted.
- **Any response for a private repository**, on any repository-serving endpoint: `Cache-Control: private, no-store`, so repodata, `RPM-GPG-KEY`, and `dark-zenith.repo` for a private repo are never held in a shared cache.
- **Public repodata, `RPM-GPG-KEY`, and `dark-zenith.repo`**: `Cache-Control: public, max-age=0, must-revalidate`, plus one strong `ETag` containing the served bytes' lowercase hex SHA-256 in quotes. A request carrying a matching `If-None-Match` gets `304 Not Modified` with an empty body. These endpoints do not emit `Last-Modified` and ignore `If-Modified-Since`, because second-resolution HTTP dates cannot safely represent multiple content changes within one second. Revalidation on every fetch keeps a shared cache from widening the checksum-mismatch race described under Metadata Generation & Storage, while still letting `dnf` and the cache skip the transfer when nothing changed.
- **All 4xx and 5xx responses** on these endpoints: `Cache-Control: no-store`, so a transient `503 metadata_not_ready` or a `401` challenge is never cached on behalf of later clients.
- Every repository-serving response also sends `Vary: Authorization, Cookie`, because the same path is reachable anonymously, with Basic Auth credentials, or with a browser session cookie, and those authentication modes use different authorization and rate-limit buckets.

Web UI and `/api/v1/...` responses send `Cache-Control: no-store`.

### Private Repository Authentication

Private repositories (`is_public = false`) require authentication on all endpoints, including repodata and RPM downloads. The initial compatibility contract covers current DNF 4 and DNF 5 clients; legacy Yum behavior is best-effort and is not a release gate. Supported DNF clients authenticate via **HTTP Basic Auth**:

- **Username**: `token` by convention — the server ignores the username, so any value works; the password alone is the credential
- **Password**: a valid API key with the `repo:read` scope

Dark Zenith checks the API key, verifies it has the `repo:read` scope, resolves the owning user, and verifies they have access to the repository (as owner, collaborator, or admin) before serving metadata or issuing a signed B2 URL.

Browser requests to these repository-serving endpoints — for example, the direct download link on the package version detail page — may instead authenticate with the standard web session cookie; the same repository access checks apply.

An `Authorization` header is authoritative whenever one is present: it takes precedence over the session cookie, and an invalid or unsupported authorization scheme never falls back to cookie or anonymous access. With no `Authorization` header, a stale or invalid session cookie is ignored for a public repository read and the request proceeds anonymously. On a private or nonexistent target, such a cookie follows the invalid-credential masking rule and receives `404 not_found`; a request with no cookie or authorization credential at all remains anonymous and receives the Basic challenge described below.

Anonymous requests (no credentials at all) to these repository-serving endpoints respond `401 unauthenticated` with a `WWW-Authenticate: Basic realm="Dark Zenith"` header whenever the target slug is private or does not exist. Unknown and private slugs are treated identically so the challenge does not leak repository existence, and RPM client HTTP stacks that wait for a challenge before sending Basic credentials (librepo/libcurl configured via `username=`/`password=` repo directives) still work. Requests that do present credentials follow the private-repository masking rule in API Contract Details: invalid or expired credentials, and valid principals without access, receive `404 not_found`.

Public repositories may also receive the same Basic Auth credentials as optional authentication for higher rate limits. For public repository reads, the API key only needs to be valid, non-expired, and have at least one valid scope; `repo:read` and repository access checks are not required. If optional Basic credentials are present but invalid, expired, or revoked, the response is `401 unauthenticated` with the same `WWW-Authenticate: Basic realm="Dark Zenith"` challenge rather than silently falling back to anonymous access.

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

For repositories without metadata signing, `repo_gpgcheck` is `0`. For repositories whose `rpm_signing_state` is not `enabled`, including repositories still in the `signing` transition, `gpgcheck` is `0`. The `gpgkey` line is included whenever `gpg_key_fingerprint` is configured and is omitted only when no repository key is configured. Release integration tests install from public and private repositories with both DNF 4 and DNF 5, exercising repodata verification, key retrieval, package redirects, and package-signature verification. If a supported client release does not propagate `username` and `password` to `gpgkey`, its generated setup instructions perform a separate interactive `curl --fail --user token .../RPM-GPG-KEY | sudo rpmkeys --import -` step that prompts for the API key; credentials are never placed in a URL, command argument, or generated file by that fallback.

### GPG Signing (Optional)

Each user can upload an OpenPGP V4 key pair (public + private) to their account. OpenPGP V5/V6 keys are outside the initial compatibility contract and are rejected with `422 validation_failed`. Each armored pair must contain exactly one matching V4 primary-key identity. The private key is encrypted at rest in the database using the GPG private key encryption envelope described below. Private keys must be dedicated repository-signing keys that can sign non-interactively. Upload validation chooses a usable signing-capable primary key when one exists; otherwise it requires exactly one usable signing-capable subkey and rejects an ambiguous set of multiple usable signing subkeys. It records the chosen key's exact fingerprint in `gpg_signing_fingerprint` and forces every test and production signature to that fingerprint with GPG's exact-key selector rather than allowing GPG to choose a different subkey later.

Signing usability is verified at upload by performing a test signature inside an ephemeral `GNUPGHOME`. Passphrase-protected, revoked, or otherwise unusable private keys are rejected with `422 validation_failed`. The selected key's algorithm, read from GPG's machine-readable status output, must be RSA, ECDSA, or EdDSA in the initial release; original DSA and unknown algorithms are rejected. This set is accepted by the supported RPM 6 release for v4 compatibility signatures, which Dark Zenith needs for its DNF 4 promise. Release integration fixtures exercise every admitted algorithm through `rpmsign --rpmv4` and both supported DNF generations; a runtime key upload needs only the generic exact-key GPG test. The effective signing expiry is the earlier expiration of the primary key and selected signing subkey, ignoring a missing expiration on either; it is null only when neither expires. An effective expiry less than 30 full days away is rejected, and the accepted value is stored in `gpg_key_expires_at`. A daily scan queues reminder emails when an expiring key first crosses 30, 7, and 1 full day remaining. Successful delivery records that threshold in `gpg_key_expiry_notified_days`, and replacement resets the set. The jobs are unique by `(user_id, fingerprint, threshold)` and re-check the current fingerprint and expiry before sending.

If a configured key nevertheless expires before replacement, all new metadata-signing, package-signing, re-signing, and attempts to enable signing fail closed with `409 conflict_gpg_key_expired`; existing signed bytes remain stored and served, but clients may reject their signatures. The account and repository settings pages display an expired-key error until the owner replaces or removes the key. Metadata regeneration that requires the expired key records a non-retryable `conflict_gpg_key_expired` failure rather than consuming 20 infrastructure retries.

#### GPG private key encryption

The `gpg_key_private` field stores a versioned binary encryption envelope rather than raw key material. Two envelope versions are defined:

- **`v1`**: AES-256-GCM with a 32-byte key derived from `SECRET_KEY_BASE` by HKDF-SHA-256 using a random 16-byte salt and the context string `dark_zenith:gpg_private_key:v1`. Binary format: 1-byte version (`0x01`), 16-byte salt, 12-byte nonce, 16-byte authentication tag, and ciphertext bytes for the ASCII-armored private key. AEAD additional authenticated data is `dark_zenith:gpg_private_key:v1:<user_id>`, binding the encrypted value to the owning user.
- **`v2`** (current): identical binary layout and AEAD construction to `v1`, with version byte `0x02`, HKDF context string `dark_zenith:gpg_private_key:v2`, and AAD `dark_zenith:gpg_private_key:v2:<user_id>`. New writes always use `v2`; the dedicated version byte and distinct HKDF/AAD contexts give a clean boundary for future format changes without colliding with `v1` rows.

Reads dispatch by the stored version so older rows continue to decrypt while the background re-encryption job migrates them. Rows whose envelope version is unsupported by the running release fail closed and require admin intervention (typically uploading a fresh GPG key pair to overwrite the unreadable row).

**`SECRET_KEY_BASE` rotation procedure.** Because both `v1` and `v2` derive their AEAD key from `SECRET_KEY_BASE`, rotating that value would otherwise strand every existing `gpg_key_private` row. To rotate safely, the operator sets the new value on `SECRET_KEY_BASE` and provides the prior value on `PREVIOUS_SECRET_KEY_BASE`. Both are read at boot. Encryption always derives its key from `SECRET_KEY_BASE`. Decryption first attempts the current envelope using `SECRET_KEY_BASE`; on AEAD authentication failure it retries with `PREVIOUS_SECRET_KEY_BASE` if configured. When `PREVIOUS_SECRET_KEY_BASE` is set at boot, the application enqueues a unique Oban scan job (`DarkZenith.Jobs.GpgKeyReencryption`) that enqueues one re-encryption job per user row with `gpg_key_private` set. Each per-row job snapshots the ciphertext and first classifies it: a `v2` envelope that decrypts with the current base is already migrated and is a successful no-op; a supported envelope that is still `v1` or decrypts only with the previous base is rewritten as `v2` under the current base. A rewrite updates with `WHERE id = <user_id> AND gpg_key_private = <snapshotted_ciphertext>`. A zero-row compare-and-swap means the user replaced or removed the key concurrently and is a successful no-op, preventing stale re-encryption from restoring old key material. Per-row jobs retry up to 20 attempts with exponential backoff; exhausted jobs remain visible for admin intervention. The scan runs on each boot while the prior base is set; when no rows decrypt only with it, the operator can remove `PREVIOUS_SECRET_KEY_BASE`. Rotating without the prior base immediately strands old envelopes and they fail closed.

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

When `sign_rpms` is enabled on an empty repository, `rpm_signing_state` becomes `enabled` immediately. When it is enabled on a non-empty repository, the owner must explicitly choose `existing_package_strategy = "resign"`. In one transaction Dark Zenith creates an `enable_rpm_signing` Signing Transition plus one pending item per current package, sets `sign_rpms = true` and `rpm_signing_state = "signing"`, stores the transition ID, and enqueues one Oban job per item ID. Each item snapshots both the package's current storage path and exact version ID. New uploads are signed before insertion while the transition runs and need no transition item.

The 60-second transition sweep uses only Signing Transition Item state, never Oban row retention. It requeues expired execution leases and sets `rpm_signing_state = "enabled"`, marks the transition completed, and clears `signing_transition_id` only when every item is `succeeded` or was `canceled` by package deletion and the metadata cache has reached the current revision. Any failed item makes the transition `failed`; the repository remains `signing` with `gpgcheck=0` until an admin fixes the cause and resets the failed item, or deletes the failed package, which cancels the item. Signing only future uploads is unsupported. Disabling `sign_rpms` marks the transition and all unfinished items `canceled`, sets the repository to `disabled`, clears its transition ID, and does not strip signatures already written. A worker re-checks all current transition fields and target fingerprints immediately before its package update, so a canceled or superseded item cannot commit.

#### Key replacement and revocation

Users can replace their GPG key by uploading a new pair (public + private). Replacement is allowed even when repositories have signing enabled, but a replacement is rejected while `previous_gpg_key_public` is already set or while any repository owned by the user has `rpm_signing_state = "signing"`. In that case, `PUT /api/v1/gpg_key` and `POST /api/v1/gpg_key/revocation` with `strategy=replace_key` return `409 conflict_gpg_key_transition_in_progress`; the current transition must complete, or an admin must resolve it, before a replacement can start. The reverse direction is deliberately not blocked: enabling `sign_rpms` on a non-empty repository while a `replace_gpg_key` transition is still running is allowed, and the two transitions run independently. The new `enable_rpm_signing` items take their `target_fingerprint` from the user's current signing fingerprint, which is already the replacement key, so they never sign to the outgoing key; the replacement transition still clears `previous_gpg_key_public` on its own items alone, and the repository's `signing` state merely defers the user's next key replacement until those items finish. Because the cached metadata signature and existing per-package signatures may still chain to the previous key while re-sign jobs run, the previous public key is retained during the transition so clients keep verifying successfully. When replacement happens:

1. In a single transaction, the existing public key is copied to `previous_gpg_key_public`; a `replace_gpg_key` Signing Transition and one item per current package in every RPM-signed owned repository are created; the user's encrypted key, public key, primary fingerprint, exact signing fingerprint, expiry, and empty reminder-threshold set are written; `gpg_key_transition_id` points to the transition; every metadata-signed owned repository is moved to the new primary fingerprint and has `metadata_revision` incremented; and metadata-regeneration and transition-item jobs are enqueued.
2. While `previous_gpg_key_public` is set, every `GET /repos/:slug/RPM-GPG-KEY` request for a repository owned by that user with `gpg_key_fingerprint` configured returns the previous and current public keys concatenated into a single response body containing both ASCII-armored public key blocks, so clients can verify signatures made with either key during the transition. Repositories without `gpg_key_fingerprint` configured continue to return `404 not_found`.
3. A transition-item worker claims its durable lease and fencing token, downloads `expected_storage_path` at `expected_storage_version_id` into a fresh attempt directory, preserves RPM v4/v6 format while re-signing with the new exact signing fingerprint, verifies all digests and the expected signature with `rpmkeys`, and computes the new checksum, final size, header range, and metadata-size deltas. It acquires a quota reservation for any positive byte delta, uploads to a fresh final key using the same `:write_id` template as initial uploads, and retains the returned version ID. Its commit transaction follows the global order—owner, repository, package, transition/item, reservation—then verifies the current transition/fingerprint, the still-current lease token, and the expected source identity, rechecks metadata limits, and updates the package only with a compare-and-swap on `(id, storage_path, storage_version_id)`. The winning transaction writes checksum, size, offsets, key and version ID, adjusts metadata counters and `users.storage_bytes`, consumes the reservation, increments `metadata_revision`, marks the item succeeded, and enqueues metadata generation plus permanent deletion of the previous exact object version. A duplicate, expired-lease, or stale worker permanently deletes its newly uploaded version and no-ops if the item already succeeded; any other compare-and-swap mismatch returns the still-current item to its defined retry or conflict path. A crash-created version is caught by the orphan reconciler.
4. The 60-second sweep reads durable item states and repository cache revisions. When every item has succeeded or was canceled by package or repository deletion, and every affected repository that still exists has a cache at its current revision (a deleted repository is treated as satisfied), it marks the transition completed and clears `previous_gpg_key_public` plus `gpg_key_transition_id` in one transaction. Failed items leave the transition failed and the previous public key served until an admin remediates and resets them or deletes the affected package. Key replacement does not move an `enabled` repository to `signing`, because both old and new public keys remain available throughout the durable transition.

Users can also explicitly revoke (remove) their GPG key without simultaneously replacing it. If the user has no repositories with `gpg_key_fingerprint` set or `sign_rpms = true`, `DELETE /api/v1/gpg_key` and the equivalent web UI action remove the key immediately.

When the user owns any affected repositories, `DELETE /api/v1/gpg_key` returns `409 conflict_gpg_key_in_use` with counts of metadata-signed and RPM-signed repositories. The web UI prompts the user to choose one of the same explicit strategies exposed by `POST /api/v1/gpg_key/revocation`:

- **Clear metadata signing** (`strategy: "clear_metadata_signing"`): Allowed only when none of the user's repositories have `sign_rpms = true`. For every affected repository, `gpg_key_fingerprint` is cleared and metadata regeneration is enqueued. Package rows and B2 objects are left intact. The user's GPG key is then removed.
- **Delete signed packages** (`strategy: "delete_signed_packages"`): For every affected repository where `sign_rpms = true`, all package rows are deleted with the standard storage-counter, metadata-counter, and exact-version cleanup updates; active signing transitions/items are canceled; `gpg_key_fingerprint` is cleared; `sign_rpms` becomes `false`; `rpm_signing_state` becomes `disabled`; and metadata regeneration is enqueued. Leased workers no-op when they re-check canceled item state or find the package gone. Repositories that only use metadata signing clear their fingerprint and regenerate without deleting packages. The user's key is then removed.
- **Re-sign with a new key** (`strategy: "replace_key"`): The user uploads a new GPG key pair as part of the same multipart request, and the operation is processed as a replacement (see above) instead of a revocation.

Unlike `replace_key`, key removal is not blocked by an active key-replacement transition: `DELETE /api/v1/gpg_key` and the two non-replacement strategies remain escape hatches from a stuck transition. Every successful removal marks any active key transition and unfinished items canceled, then clears the current and previous encrypted/public key material, primary/signing fingerprints, expiry, reminder thresholds, and transition ID in the same transaction. This is safe because immediate deletion applies only when no repository uses the key, while strategy paths clear every repository fingerprint and bump metadata revisions before the key disappears. Leased workers observe canceled durable state and no-op.

---

## Package Upload & Processing

An upload by a repository owner or admin has a control plane and a payload plane. The client first creates an Upload Intent with a display filename and exact byte length. Dark Zenith validates and reserves that declared size, then returns a short-lived presigned URL for one random private B2 staging key. The client sends one `PUT` with `Content-Type: application/x-rpm` directly to B2—without the Dark Zenith bearer token, cookies, or any B2 application credential—and reads `x-amz-version-id` from the response. It then completes the intent with that version ID. The app verifies the exact object version with `HeadObject`, and a durable Oban worker downloads and processes it. API intents queue final processing automatically after completion; web intents stop at a parsed preview until the user confirms. No RPM request body traverses Phoenix, its reverse proxy, or a Cloudflare zone in front of the app.

Uploads are limited to `MAX_RPM_UPLOAD_BYTES` bytes (default 512 MiB). Because the direct-transfer design uses one B2 S3-compatible `PutObject` request rather than multipart upload, the configured limit may not exceed B2's 5 GiB single-object-upload ceiling (5 368 709 120 bytes). Intent creation rejects a non-positive declared size with `422 validation_failed` and an oversized declaration with `413 payload_too_large`, before issuing a URL or creating a staging object. Completion requires the exact B2 object length to equal the declaration, so understating the size cannot evade either limit or quota. The client-supplied filename is reduced to its final path component, treating both `/` and `\` as separators; a filename that is empty after trimming, invalid UTF-8, contains control characters, or exceeds 255 characters is rejected with `422 validation_failed`. It is display-only and is never used as a filesystem path or storage key. A staged object that is not a valid RPM remains private and unreachable through any repository route, then is permanently deleted when processing rejects it.

Per-user storage is bounded by `MAX_USER_STORAGE_BYTES` (default 50 GiB; `0` disables the quota). `users.storage_bytes` is the transactionally maintained sum of final stored `size_package` values across repositories the user owns; uploads by an admin to another user's repository count against the owner. Intent creation authoritatively reserves the declared source size. After optional signing, the worker adjusts that reservation to the exact final `size_package` before writing the final object; an increase fails if concurrent use consumed the remaining quota. Package insertion consumes the reservation atomically, so concurrent intents cannot commit a permanent overshoot. A re-sign job reserves only a positive `(new_size - old_size)` delta before uploading and adjusts `storage_bytes` by the signed delta during its compare-and-swap package update; insufficient capacity leaves its durable transition item failed with `conflict_storage_quota_exceeded`. Deletions and size reductions always proceed and decrement `storage_bytes`. Admins can view stored and actively reserved bytes separately.

Every worker claim uses a new per-attempt directory under `RPM_UPLOAD_TMPDIR`, created with mode `0700`; source and derived files within it use mode `0600`. Before downloading, the worker requires at least `3 * declared_size + 67108864` free bytes, allowing room for the staged source, a working copy, a signed output, and parser/signing overhead. Insufficient space is a retryable `upload_temp_space_unavailable` processing failure, not a reason for the client to upload the staged bytes again. The worker streams only the recorded exact B2 version, stops if the measured bytes differ from `declared_size`, and removes the entire attempt directory after success, failure, interruption recovery, or lease loss. The durable source remains in B2 until the intent succeeds or reaches a terminal state.

The HTTP status/code pairs named in the processing steps define the public error classification, not the already-returned completion response. Synchronous intent creation/completion validation uses those HTTP statuses directly. Once processing has been accepted with `202`, a deterministic or exhausted failure sets `status = "failed"` and places the same code in the upload-intent resource while status polling itself remains `200`, as defined in the API contract.

1. **Validate structure and format**: Confirm the lead magic and parse the signature and main headers. Dark Zenith accepts RPM format v4 and v6 and rejects v3 or unknown formats with `422 validation_failed`. A v6 package must carry main-header `RPMFORMAT = 6`, `ENCODING = "utf-8"`, and every signature/header tag that the supported RPM 6 format marks mandatory. In particular, its signature has the immutable region, SHA-256, SHA3-256, and final zero-filled `RESERVED` entries but no size/payload or tag-above-999 entries; its main header uses the v6 long file/installed sizes, a file-digest algorithm of at least SHA-256, and the required compressed/uncompressed payload digest and size pairs. Both headers have strictly increasing unique tag numbers, correct physical types/counts, in-bounds aligned data references, and zero-filled padding. A v4 package has the v4 immutable header structures and either no physical `RPMFORMAT` tag or `RPMFORMAT = 4`; a v3 header+payload package is never inferred as v4. For parser differential safety, v4 headers with duplicate physical tag numbers or overlapping/out-of-bounds data references are rejected even if a legacy RPM reader would tolerate them. Both binary and source RPMs are accepted. The lead's non-magic fields are historical and are not used to classify it; a nonzero main-header `SOURCEPACKAGE` tag identifies a source package, and an absent or zero value identifies a binary package. While reading, the parser enforces structural bounds: the combined signature and main header regions must not exceed 64 MiB (67 108 864 bytes) and each header must not exceed 65 535 index entries; files exceeding either bound are rejected before further parsing.
2. **Verify integrity**: Invoke RPM 6's `rpmkeys --dbpath <temporary-rpmdb> --checksig --verbose` directly with `LC_ALL=C` against the unchanged uploaded file. The temporary RPM database is empty when `sign_rpms = false`; every available header and payload digest must report `OK`, an absent signature or `NOTFOUND` signer is permitted, and any `BAD` digest or signature is rejected with `422 validation_failed`. When `sign_rpms = true`, the owner's public key is imported first so signatures already made with the configured key are genuinely verified rather than reported `NOTFOUND`; the acceptance rule is otherwise identical — unsigned input and `NOTFOUND` (third-party) signers are permitted, because every existing package signature is replaced during re-signing and the post-signing verification under GPG Signing enforces the configured key on the final bytes — and any `BAD` digest or signature is still rejected with `422 validation_failed`. A completed verifier result that violates these rules is a validation error. Inability to create the isolated RPM database or execute a boot-validated RPM 6 verifier returns `503 rpm_verification_unavailable`. The verifier database is removed after the attempt.
3. **Extract metadata**: Parse the RPM headers directly in Elixir. Required metadata is `name`, `version`, `release`, `arch`, `summary`, `description`, `license`, and `size_installed`; `epoch` defaults to `0` when absent. `summary`, `description`, and `rpm_group` are RPM internationalized strings: Dark Zenith matches the literal `C` entry in `HEADERI18NTABLE`, falling back to its first entry exactly as RPM does when no requested locale matches, and rejects inconsistent locale/value counts. For v4, `size_installed` uses physical main-header `LONGSIZE` then `SIZE`, while `size_archive` uses signature-header `LONGARCHIVESIZE` then `PAYLOADSIZE` and is `NULL` if both are absent. For v6, `LONGSIZE` is required for installed size, required uncompressed `PAYLOADSIZEALT` supplies `size_archive`, and size/payload tags in the signature header are illegal. Optional `url`, `rpm_group`, `rpm_vendor` (`VENDOR`), and `rpm_buildhost` (`BUILDHOST`) values are `NULL` when absent or empty after trimming; `build_time` uses the unsigned 32-bit `BUILDTIME` timestamp or is `NULL` when absent. Dependency, file, and changelog collections default to empty arrays. Every parallel RPM mapping used to construct those collections must have matching cardinality and every dictionary index must be in range; malformed dependency flags/versions, file triplets, MIME/flag arrays, or changelog arrays reject the package rather than being truncated or padded.

   For a v4 binary package, `rpm_sourcerpm` uses `SOURCERPM` and `rpm_sourcenevr` is null. A v6 binary package requires `SOURCENEVR`; Dark Zenith stores it exactly in `rpm_sourcenevr` and derives `rpm_sourcerpm` for standard repodata by parsing its name-[epoch:]-version-release, removing the epoch component, and appending `.src.rpm`. A malformed or non-round-trippable `SOURCENEVR` is rejected. For source packages, `arch` is stored as literal `src`, the physical `ARCH` tag is ignored and not required, the file list contains bare source/spec names, and both source-reference fields are null. Binary packages whose physical `ARCH` is `src` are rejected.

   Validate `epoch` in `0..4 294 967 295`; validate installed/archive sizes against the Packages signed-bigint ranges; require `name`, `version`, `release`, and `arch` to match `^[A-Za-z0-9._+~-]+$` and be at most 256 characters. Apply all other Packages-table limits (`summary` 256, `description` 65 536, `url` 256, `license` 256, both source-reference fields 800, and group/vendor/buildhost 256, after trimming). A non-empty `url` must be absolute HTTP or HTTPS. Every extracted string, including collection members, must be valid UTF-8 and contain only XML 1.0-representable characters. The single-line fields — `summary`, `license`, `url`, `rpm_group`, `rpm_vendor`, `rpm_buildhost`, `rpm_sourcerpm`, and `rpm_sourcenevr` — are additionally rejected when they contain any ASCII control character, mirroring the single-line rule for user-provided API strings; `description` and changelog text may contain newlines and tabs but no other control characters. Reject more than 262 144 files, 4 096 changelogs, or 65 536 entries in any one dependency list. Finally, reject a composed final B2 key over 1 024 UTF-8 bytes, using the full package UUID, fresh write UUID, and sanitized filename template; initial writes and re-sign attempts use the same worst-case template.
4. **Sign** (if `sign_rpms` is enabled): Before choosing the signed or unsigned path, snapshot the repository's current `sign_rpms` value. When it is enabled, also snapshot the repository's primary fingerprint and the owner's exact signing fingerprint, public key, and effective expiry; sign with that exact key and `rpmsign`, then run the required expected-key verification described under GPG Signing. The final transaction fences this snapshot so an upload that raced with signing enablement, disablement, key replacement, or key removal cannot commit bytes produced under superseded settings.
5. **Calculate final values**: Compute SHA-256, `size_package`, `header_start`, and exclusive `header_end` from the final bytes after signing. Signing rewrites the signature header and moves the main header, so pre-signing offsets are never persisted. If signing makes the final file exceed `MAX_RPM_UPLOAD_BYTES`, fail the intent deterministically with `payload_too_large`; persisted package size always obeys the same ceiling as the staged source.
6. **Enforce repository metadata limits**: Encode the candidate package's deterministic metadata fragments to a counting sink and perform an advisory check against the repository counters. The final transaction repeats the check while holding the repository lock and fails the intent with `conflict_repository_metadata_limit_exceeded` if the projected package count or any uncompressed metadata artifact crosses its configured limit.
7. **Duplicate check**: Perform an advisory lookup for `(repository_id, name, epoch, version, release, arch)`. The final locked check and database unique constraint are authoritative; a conflict fails the intent with `conflict_duplicate_package`.
8. **Adjust quota reservation**: Lock the owning user and reservation, renew the reservation, and change `reserved_bytes` from the declared source size to the exact final `size_package`. A required increase that no longer fits fails with `conflict_storage_quota_exceeded`; a decrease releases capacity immediately.
9. **Write a fresh final version**: Compose a key `repos/:slug/packages/:package_id/:write_id/:name-:epoch-:version-:release.:arch.rpm`, where `package_id` came from the intent and `write_id` is a fresh UUID for this attempt. For an unsigned package, issue server-side `CopyObject` from the exact staging version; for a signed package, `PutObject` the verified local output. Retain the returned final version ID. SDK automatic retries are disabled for these non-idempotent writes: an ambiguous attempt is abandoned to the reconciler, and a retry always chooses a new `write_id` rather than writing another version at an uncertain key.
10. **Fenced record and consume**: In one transaction, lock the owner, repository, upload intent, and reservation in the global order; require `status = "processing"` and the claim's current `lease_token`; recheck that the initiating user is still the repository owner or an admin plus every duplicate, metadata, transition, and quota invariant; and require `sign_rpms` plus, when signing is enabled, the repository primary fingerprint and owner signing fingerprint/public key to match the attempt's snapshot. The transaction also rechecks that a snapshotted signing key has not expired while the attempt was running. It then inserts the package with its key and version ID; updates repository metadata counters and `metadata_revision`; increments `users.storage_bytes`; consumes and clears the reservation; marks the intent `succeeded`; and enqueues metadata regeneration plus deletion of the exact staging version. A signing-setting or fingerprint mismatch deletes any candidate final version and returns the intent to its normal retry path so a fresh attempt uses current settings; a key that has crossed its expiry fails with `conflict_gpg_key_expired`. If authorization, the token, or any other compare-and-swap predicate has been lost, this attempt cannot commit.

Deterministic validation, final-size, authorization (recorded as `forbidden`), duplicate, metadata, expired-key, and quota errors make the intent terminally `failed`, release its reservation, and enqueue staging cleanup. Unavailable `rpmkeys`, `rpmsign`, `gpg`, temporary space, database, or B2 operations are retryable under the Upload Intents lease policy; the immutable staging source and reservation remain available between attempts. After 20 failed claims the intent becomes terminally failed with the applicable sanitized code (`rpm_verification_unavailable`, `signing_unavailable`, `upload_temp_space_unavailable`, `storage_unavailable`, or `internal_error`). If final B2 writing succeeds but the fenced database transaction loses a race, Dark Zenith permanently deletes that exact candidate `(key, version_id)` and follows the relevant retry or terminal path; failed immediate deletion is handled by an idempotent version-aware cleanup job. If package insertion succeeds but metadata regeneration fails, the upload remains successful and regeneration retries until the cache reaches the latest revision.

Package deletion locks the owner, repository, package, affected signing transitions, and unfinished transition items in the global order, marks those items canceled, removes the package row, decrements metadata counters and `users.storage_bytes`, increments `metadata_revision`, and enqueues metadata regeneration plus version-aware B2 deletion in one database transaction. If B2 deletion fails, the package no longer appears in metadata or API responses, and package-ID download URLs no longer resolve, but cleanup retries. Previously issued signed B2 URLs may remain usable until they expire or until that exact object version is deleted, whichever happens first.

Repository deletion is a hard delete. When an authorized owner or admin deletes a repository, Dark Zenith reads every package `(storage_path, storage_version_id)` and every upload intent's `(staging_path, staging_version_id)` when present; locks the owner, repository, package rows, transition/items, upload intents, reservations, and live slug reservation in that order, with each bulk class ordered by UUID; then deletes the repository row and dependent packages, collaborators, invitations, metadata cache, upload intents, and active storage reservations, decrements the owner's `storage_bytes`, marks the repository's active or failed signing transitions, and its pending, executing, or failed transition items, `canceled` (for a user-wide `replace_gpg_key` transition, only that repository's items), cancels active workers through their durable state, and retires the slug reservation in one database transaction. Signing-transition and item rows are retained for audit: their repository references are UUID snapshots rather than foreign keys, so the hard delete does not remove them. It returns `204 No Content` after commit. Exact final and staging B2 versions are deleted after commit through idempotent cleanup jobs. Failed cleanup leaves the repository inaccessible while retries continue. Previously issued signed URLs may work until expiry or permanent version deletion. Pending jobs that find the repository gone complete as no-ops.

Backblaze B2 buckets retain object versions, so every successful PUT or copy's returned version ID is part of the object's storage identity. Final RPM keys are write-once: Dark Zenith never intentionally writes a second version at the same key, including after an ambiguous result. Cleanup calls S3 `DeleteObject` with a version ID; deleting by key alone is forbidden because it would create a delete marker without reclaiming older storage. A daily final-object reconciler paginates `ListObjectVersions` under `repos/`, compares `(key, version_id)` pairs with package rows, and permanently deletes unreferenced versions and delete markers older than 24 hours. An hourly staging reconciler scans `staging/uploads/`: it preserves every version at the current key of an unexpired `awaiting_upload` intent, the accepted exact version of an active `queued`, `processing`, or `preview_ready` intent, and versions younger than two hours that may belong to an in-flight transfer; it deletes everything else. These grace periods protect writes that completed immediately before a process crash or database commit while still bounding replayed presigned URLs. The B2 application key must permit listing versions and deleting specific versions in addition to normal read/write/copy access. Operators may keep only the latest version at write-once final keys as lifecycle defense in depth, but must not apply an age-based lifecycle deletion to `staging/uploads/`: the database and exact-version reconciler are authoritative, and a blanket rule could delete the durable source of a legitimately delayed retry.

### RPM Parsing

For metadata extraction, rather than querying metadata through `rpm` or `rpm2cpio`, Dark Zenith includes a pure-Elixir parser for RPM format v4 and v6. Format v3 and unknown future formats are rejected. Both accepted formats share four logical sections:

- **Lead** (96 bytes): Magic number plus historical fields. The magic is used for quick validation; source-package detection uses the main header's `SOURCEPACKAGE` tag rather than the historical lead type.
- **Signature header**: Contains signatures and header digests; v4 also carries legacy size and header+payload digest fields, while v6 forbids size/payload fields here.
- **Main header**: Contains all package metadata as tagged entries (name, version, dependencies, etc.) using a well-defined set of tag constants.
- **Payload**: The compressed cpio archive (not needed for metadata extraction).

The parser reads the lead, signature, and main header sections and does not decompress the payload for metadata extraction. It enforces the structural and format-specific invariants defined in the upload pipeline, including v6 sorted/unique tags and zero padding. Integrity verification is deliberately delegated to boot-validated RPM 6 `rpmkeys`, which streams the complete package and verifies the header and payload digests that apply to its format. Signing uses RPM 6 `rpmsign`; Dark Zenith never mutates RPM signatures itself.

---

## Web Interface

The web UI is built with Phoenix LiveView. Public pages are accessible to everyone; actions that modify data (creating repos, uploading packages) require authentication and the matching authorization checks. All user- and RPM-derived strings are rendered as plain text with standard HTML escaping — never as raw HTML — and the package `url` is the only RPM-derived value rendered as a hyperlink (restricted to `http`/`https` at upload validation).

### Landing Page (`GET /`)

- Brief description of what Dark Zenith provides.
- Links to available repositories.

### Repository List (`GET /repos`)

- Browse public repositories with name, description, and package count; authenticated users also see private repositories they can access.
- Authenticated users see a "Create New Repo" action.

### Create Repository (authenticated, `GET /repos/new`)

- Form to create a new repository: name, slug, description, public/private, GPG signing settings (enable metadata signing, enable RPM auto-signing).

### Repository Detail (`GET /repos/:slug`)

- Repository description and status.
- **Setup instructions** with copy-paste `dnf` commands for adding the repo to the user's system:
  - `.repo` file contents to place in `/etc/yum.repos.d/`.
  - For public repos: unauthenticated config shown by default, with an authenticated variant (Basic Auth with a `password=<api-key>` placeholder; any of the user's active API keys with at least one valid scope works) recommended for higher rate limits.
  - For private repos: instructions show the Basic Auth configuration with a `password=<api-key>` placeholder to be filled with one of the user's API keys carrying `repo:read`, plus a `chmod 600` step for the resulting file, since it will embed the key and `/etc/yum.repos.d/` files are world-readable by default. Because the server stores only key hashes, it can never render an existing key's plaintext; the one exception is key creation — when the user creates an API key from this flow, the creation response may render the snippet with the just-created plaintext key filled in, exactly once. If the user has no suitable API key, prompt them to create one.
  - One-liner `dnf config-manager` command.
  - GPG key import instructions (if applicable).
- **Package list**: Searchable, sortable table of packages in this repo (name, EVR, arch, summary). EVR displays as `epoch:version-release` when `epoch` is nonzero and as `version-release` otherwise.
- Repository owners and admins see an "Upload RPM" action.
- **Owner/admin only**: "Manage Collaborators" section to add/remove users who can access a private repo.
  - For public repositories, existing collaborators and pending invitations are still listed and removable (they are dormant while the repository is public), but adding new ones is disabled.
  - Adding a collaborator by the repository owner's email is rejected with `422 validation_failed`.
  - Adding a collaborator whose normalized email already has a collaborator row or pending invitation is idempotent; the UI shows the existing collaborator or invitation instead of creating a duplicate. An unexpired invitation queues a new delivery generation only when its notification is `failed`, or when it is `suppressed` and registration has since been enabled; `queued` and `sent` notifications are not duplicated. Expired-but-uncleaned invitations are refreshed with a new expiration and a new notification generation, either queued or suppressed under the registration-disabled rule in Repository Collaborators. Pending invitations display their expiration and notification status.

### Repository Settings (owner/admin, `GET /repos/:slug/settings`)

- Edit repository settings: display name, description, public/private visibility, metadata signing, and RPM auto-signing. The slug is immutable after creation. Enabling RPM auto-signing on a repository that already has packages prompts for the same explicit re-sign confirmation as the API's `existing_package_strategy = "resign"` (see GPG Signing).
- Delete the repository after an explicit confirmation, following the hard-delete flow described under Package Upload & Processing.

### Package Detail (`GET /repos/:slug/packages/:name`)

- Lists all versions/architectures available for this package name.
- For each package build: EVR, arch, summary, size, upload date. EVR uses the same `epoch:version-release` display rule as repository package lists.
- **Install instructions**: `dnf install <package>` command (assumes the repo is already configured). Names whose builds include source packages (arch `src`) also show a `dnf download --source <package>` command; when only source builds exist, the install command is omitted, since source packages cannot be installed directly.
- Links to individual package version pages, keyed by package UUID.

### Package Version Detail (`GET /repos/:slug/package-versions/:id`)

- Full package metadata: name, epoch, version, release, arch, summary, full description.
- Dependency information (requires, provides, conflicts, obsoletes).
- File list and changelog.
- Direct download link to the app's package download endpoint, which redirects to a signed B2 URL.

### Upload RPM (owner/admin, `GET /repos/:slug/upload`)

- Drag-and-drop or file picker to upload an RPM to the selected repository.
- **Direct transfer**: Selecting a file creates a `web_preview` Upload Intent using the browser-reported name and exact `File.size`. The browser then sends that `File` directly to the returned B2 URL with `Content-Type: application/x-rpm`, allowing the user agent to supply the signed `Content-Length`; it never posts RPM bytes to Phoenix or through Cloudflare. On B2 success it reads the CORS-exposed `x-amz-version-id` response header and completes the intent. An interrupted transfer restarts from byte zero on the same still-valid URL; after that URL expires, refresh supplies a new random staging key and URL.
- **Preview**: Completion verifies the exact staged version and queues durable preview processing. The LiveView shows `queued`/`processing` progress and receives or polls the intent status; a disconnect does not cancel the job. The worker size-checks, validates, and parses the RPM using the normal pipeline, performs advisory duplicate and repository-metadata-limit checks, stores the extracted metadata on the intent, and changes it to `preview_ready` for 15 minutes. No package row or repository-referenced final B2 object exists yet; the private exact staging version is the durable source.
- **Confirm**: Confirmation identifies an unexpired `preview_ready` intent, which is always scoped to the same repository and initiating user, then reauthorizes that user as the repository's current owner or an admin. It changes `preview_ready` to `queued` and enqueues final processing in one transaction. A fresh attempt downloads and revalidates the same exact staging version, requires its extracted metadata to equal `preview_metadata` (a mismatch — possible only if extraction behavior changed between releases — fails the intent deterministically with `validation_failed`), optionally signs it, and performs the final duplicate, metadata, quota, B2, and package transaction. A browser disconnect, app restart, or interrupted signing attempt is recovered by the lease sweep without asking the user to upload again. A user who no longer has upload permission receives the normal repository-scoped authorization or masking response and cannot confirm the intent.
- **Expiration and cancellation**: An expired, canceled, failed, or already consumed preview cannot be confirmed. Waiting-state cleanup releases its reservation and deletes the exact staging version; the UI shows a terminal error and asks the user to start a new upload. A missing node-local working file is never terminal because a retry reconstructs it from B2.
- **Web only**: Preview-and-confirm is a web presentation choice. The REST package-upload endpoint fixes intents to `api` mode, which proceeds from completion to final processing without a confirmation pause.

### GPG Key Management (authenticated, account settings)

- Upload a GPG key pair (public + private) to the user's account. Uploading a new pair when one already exists is treated as a replacement and triggers automatic re-signing of metadata and (if `sign_rpms` is enabled) existing packages — see "Key replacement and revocation" under GPG Signing.
- View the primary fingerprint, exact signing fingerprint, signing-key expiration, and public key of the currently uploaded key. The page warns at the same 30-, 7-, and 1-day thresholds used for reminder mail and displays a blocking error after expiration.
- Remove the existing GPG key. If any owned repositories have `gpg_key_fingerprint` set or `sign_rpms = true`, the UI prompts the user to clear metadata signing, delete RPM-signed packages, or upload a replacement key as part of the same flow.
- Passphrase-protected private keys are rejected; users should upload a dedicated repository-signing key.

### Authentication Pages

- Login / logout.
- Account registration (when enabled).
- Password reset and email confirmation (including resending the confirmation email), via the standard `phx.gen.auth` flows. The password reset completion page additionally lists the account's active API keys with a one-click option to revoke them all (see Session Tokens).
- Account email change, via the standard `phx.gen.auth` settings flow (see User Lifecycle).
- API key management for the authenticated user.

### Admin (admin-only)

- **User management**: List users; create users (created accounts are auto-confirmed and no confirmation email is sent, mirroring the bootstrap admin); grant or revoke `is_admin` on other users (never their own — see User Lifecycle); delete users, which is rejected while the target user still owns repositories (the web equivalent of the `409 conflict_user_owns_repositories` rule). The user list shows each user's storage usage against `MAX_USER_STORAGE_BYTES` and repository count against `MAX_USER_REPOSITORIES`.
- **Background jobs**: An admin-only view of Oban jobs (for example, a mounted Oban dashboard) for inspecting, retrying, or discarding the failed and exhausted jobs that the admin-intervention flows in this document rely on.
- **Signing transitions**: A durable transition/item view independent of Oban retention, showing target repository/user, status, attempts, next attempt, lease, sanitized last error, and affected package. After fixing the underlying cause, an admin can reset selected failed items to `pending`; the transaction records their prior attempt counts in the audit event, sets `attempts = 0` and `next_attempt_at = now()`, clears lease/terminal error/completion fields, returns a failed transition to `active` only when no failed items remain, and enqueues unique item jobs for the reset rows. Admins can also cancel an active or failed transition when the corresponding repository setting or key-removal flow permits it. Resets and cancellations require explicit confirmation and are audited; retrying an Oban row alone never changes durable item state.
- **Audit log**: Read-only, filterable view of audit events (actor, action, target, time).
- **Slug reservations**: List retired slug reservations created by repository deletion and release individual retired slugs for general reuse; releases are audited. Live reservations are visible for diagnosis but cannot be released.

---

## REST API

The REST API provides programmatic access to repository operations. Authentication is via `Authorization: Bearer <token>` header, where the token is either an API key or a short-lived session token obtained from the login endpoint. API endpoints also accept session cookie authentication (as used by the web UI), which allows the web frontend to call API endpoints directly and enables users to create their first API key without already having one. When both an `Authorization: Bearer` header and a session cookie are present on the same request, the `Authorization` header takes precedence; the session cookie is ignored for that request.

Read-only endpoints for public repos are unauthenticated.

Repository-scoped mutating API endpoints require either session token/cookie authentication or an API key with the matching scope. Repository-scoped mutations also require the authenticated user to be the repository owner or an admin.

Every package-upload intent endpoint, including status reads, additionally requires the same authenticated user who created the intent; API-key requests require `package:upload`. A second admin cannot take over another user's staged capability: an intent whose initiating `user_id` is not the authenticated user is treated as nonexistent and answered with `404 not_found`, exactly like an id scoped to a different repository. Repository deletion remains able to cancel all intents as a system-side consequence of deleting their target.

Account-management API endpoints for API keys and GPG keys require session token or session cookie authentication. API key credentials are not accepted for `/api/v1/api_keys`, `/api/v1/gpg_key`, or `/api/v1/gpg_key/revocation`; requests authenticated only by API key return `403 forbidden`.

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
DELETE /api/v1/repos/:slug/packages/:id                     # Delete a package (auth required)
POST   /api/v1/repos/:slug/package-uploads                  # Create a direct-to-B2 upload intent (auth required)
GET    /api/v1/repos/:slug/package-uploads/:id              # Read upload processing state/result (auth required)
POST   /api/v1/repos/:slug/package-uploads/:id/refresh      # Replace an expired upload URL and staging key (auth required)
POST   /api/v1/repos/:slug/package-uploads/:id/complete     # Accept an exact B2 version and queue processing (auth required)
DELETE /api/v1/repos/:slug/package-uploads/:id              # Cancel an unfinished upload and clean up staging data (auth required)
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
DELETE /api/v1/gpg_key                  # Remove your GPG key when it is not used by any repository (session token/cookie auth required)
POST   /api/v1/gpg_key/revocation       # Remove or replace an in-use GPG key with an explicit strategy (session token/cookie auth required)
```

### API Contract Details

JSON endpoints with request bodies require `Content-Type: application/json` and accept at most 1 048 576 body bytes; the request reader enforces the cap incrementally and returns `413 payload_too_large` before decoding an oversized body. GPG key upload requests use `multipart/form-data` with a 2 162 688-byte total cap in addition to the per-key-field limits below. RPM payloads are never multipart API bodies: after small JSON control requests, clients `PUT` them directly to a presigned B2 URL. All timestamps are ISO-8601 UTC strings and all IDs are UUID strings. User-provided metadata strings are trimmed before validation, but secrets and key material (passwords, bearer/API token values, and GPG armored key fields) are not modified except by their documented parsers. For optional string fields, a value that is empty after trimming is coerced to `NULL` at storage time and surfaced as `null` in responses; an explicit `null` in the request body is treated the same way. Required string fields with an empty-after-trim value are rejected with `422 validation_failed`. Email addresses are trimmed, normalized to lowercase, capped at 160 characters after trimming, and validated with the same email rules used by `phx.gen.auth`. Repository slugs are normalized to lowercase and must match `^[a-z0-9][a-z0-9_-]{0,63}$`; the slug `new` is reserved for the web UI's repository-creation route and rejected with `422 validation_failed`. Unknown JSON fields are rejected with `422 validation_failed`; multipart requests that include any field name the target endpoint does not define are likewise rejected with `422 validation_failed`. String fields whose trimmed length exceeds the maximum specified in the data-model tables are rejected with `422 validation_failed`. Single-line user-provided string fields — repository `name` and API key `name` — are rejected with `422 validation_failed` when they contain ASCII control characters (the repository `name` is interpolated into generated `.repo` files, where a line break would inject arbitrary directives); repository `description` may contain newlines and tabs but no other control characters. Every resource addressed beneath `/repos/:slug/...` — packages, package versions, package uploads, package downloads, collaborators, and invitations, on the API, web, and repository-serving surfaces alike — is looked up scoped to the repository resolved from `:slug`; an id that exists under a different repository is treated as nonexistent and handled by the `404 not_found` masking rule below. An update endpoint rejects an empty JSON object, or a body containing no effective mutable field after validation, with `422 validation_failed` rather than reporting a successful no-op.

Request bodies and endpoint-specific behavior:

- `POST /api/v1/auth/login`: JSON body `{"email": "...", "password": "..."}`.
- `GET /api/v1/repos`: includes private repositories only when the credential grants private read access — session token or session cookie requests list every private repository the user can access (admins see all repositories), while API-key requests additionally require the `repo:read` scope; a valid API key without `repo:read` receives only public repositories.
- `POST /api/v1/repos`: JSON body with required `name` and `slug`, and optional `description`, `is_public`, `gpg_key_fingerprint`, and `sign_rpms`. Requests with a `slug` whose normalized form is already in use by another repository, or retired by a deleted repository the requester did not own (see Slug Reservations), are rejected with `422 validation_failed` and `details.slug` indicating the conflict, so slug collisions surface the same way as format violations. Requests with `gpg_key_fingerprint` set to anything other than the owner's current GPG key fingerprint are rejected with `422 validation_failed`. Requests with `sign_rpms = true` must also set `gpg_key_fingerprint` to the owner's current GPG key fingerprint or they are rejected with `422 validation_failed`. `rpm_signing_state` is server-managed; requests that include it are rejected with `422 validation_failed`. A new empty repository created with `sign_rpms = true` starts with `rpm_signing_state = "enabled"`. A request that would leave the creator owning more than `MAX_USER_REPOSITORIES` repositories is rejected with `409 conflict_repository_quota_exceeded`.
- `PATCH /api/v1/repos/:slug`: JSON body with any subset of repository fields accepted by create, except `slug`, which is immutable. PATCH requests that include `slug` are rejected with `422 validation_failed` so existing client `.repo` files continue to resolve. `rpm_signing_state` is server-managed; PATCH requests that include it are rejected with `422 validation_failed`. PATCH requests with `gpg_key_fingerprint` set to anything other than the owner's current GPG key fingerprint are rejected with `422 validation_failed`. PATCH operations that would leave `sign_rpms = true` with `gpg_key_fingerprint` unset are rejected with `422 validation_failed` (mirroring the create-time constraint). Enabling `sign_rpms` on a repository that already has packages requires an explicit `existing_package_strategy` field with value `"resign"` to confirm per-package re-sign jobs identical to the key replacement flow; the server sets `rpm_signing_state = "signing"` until those jobs complete. Transitioning `sign_rpms` to `true` on a non-empty repository without this field is rejected with `422 validation_failed`. Unknown `existing_package_strategy` values are rejected with `422 validation_failed`. When `sign_rpms` is unchanged, when it is transitioning from `true` to `false`, or when it is being enabled on an empty repository, requests that include `existing_package_strategy` are rejected with `422 validation_failed`. Enabling `sign_rpms` on an empty repository sets `rpm_signing_state = "enabled"`; disabling `sign_rpms` sets `rpm_signing_state = "disabled"`.
- `POST /api/v1/repos/:slug/package-uploads`: JSON body `{"filename": "nginx.rpm", "size": 623104}`. `filename` and `size` use the Upload Intents validation rules; the endpoint fixes `mode` to `api` and rejects a client-supplied `mode`. It atomically creates the declared-size reservation and intent, then returns `201 Created` with the upload-intent resource plus an `upload` object: `{"generation": 1, "method": "PUT", "url": "<presigned-b2-url>", "headers": {"Content-Type": "application/x-rpm"}, "content_length": 623104, "expires_at": "..."}`. `url` is a bearer capability shown only in a create or refresh response and is never returned by the status endpoint. A non-browser client sets both the listed content type and `Content-Length: 623104`; browser code sets `Content-Type` and supplies the selected `File` as the body but does not attempt to set forbidden `Content-Length`, which the user agent derives from that file. The direct B2 request carries no Dark Zenith `Authorization` header. The client must retain the generation and response's `x-amz-version-id`; the B2 response itself is outside Dark Zenith's JSON-envelope contract.
- `POST /api/v1/repos/:slug/package-uploads/:id/refresh`: no request body. It is allowed only for the initiating user while the intent is `awaiting_upload`, its current upload URL has expired, and at least 60 seconds remain on the intent; it abandons the prior key and returns `200 OK` with the resource plus a new `upload` object capped at the unchanged intent expiry. A still-valid URL, insufficient remaining time, or any other state returns `409 conflict_upload_state`; the client retries an interrupted transfer against the current URL or creates a new intent instead of minting overlapping capabilities.
- `POST /api/v1/repos/:slug/package-uploads/:id/complete`: JSON body `{"generation": 1, "version_id": "<x-amz-version-id>"}`. `generation` must be a positive integer, and `version_id` is treated as an opaque non-empty string of at most 1 024 bytes with no control characters. The endpoint first checks durable state: the already accepted same generation/version returns idempotently without contacting B2 (`202` while queued/processing and `200` once `preview_ready`, `succeeded`, or `failed`). For an unexpired `awaiting_upload` intent, Dark Zenith requires the supplied generation to be current, snapshots its key, performs exact-version `HeadObject`, verifies size and content type, then uses a compare-and-swap on generation/key/state/expiry to store that version and enqueue processing. The first success returns `202 Accepted` with the upload-intent resource and `Retry-After: 2`. An overdue intent is atomically expired; a stale generation, different version, canceled/expired intent, or other changed state returns `409 conflict_upload_state`. A missing version or mismatched object returns `422 validation_failed` with `details.version_id`. Temporary B2 failure returns `503 storage_unavailable` without changing the intent, so completion is safe to retry.
- `GET /api/v1/repos/:slug/package-uploads/:id`: returns `200 OK` with the current intent resource. Clients poll while status is `queued` or `processing`, honoring the `Retry-After: 2` response header. `succeeded` includes the package detail resource. `failed` includes the stable sanitized error code described under Upload Intents; asynchronous failures do not change this status endpoint's HTTP status from `200`.
- `DELETE /api/v1/repos/:slug/package-uploads/:id`: cancels an `awaiting_upload`, `queued`, `processing`, or `preview_ready` intent, fences any worker, releases the reservation, enqueues version-aware cleanup, and returns `204 No Content`. Repeating cancellation or deleting an already failed/expired intent is an idempotent `204`; a succeeded intent returns `409 conflict_upload_state` and its package must be deleted through the package endpoint.
- `POST /api/v1/repos/:slug/collaborators`: JSON body `{"email": "user@example.com"}`. Adding collaborators or invitations is valid only for private repositories; add requests on a public repository are rejected with `422 validation_failed`. Removal, cancellation, and listing remain available regardless of repository visibility, so rows retained across a private-to-public flip can still be managed. The email is normalized to lowercase before lookup. If the email belongs to the repository owner, the request is rejected with `422 validation_failed`. If a collaborator or pending invitation already exists for the normalized email, the request succeeds idempotently with `200 OK` and returns the existing collaborator or invitation instead of creating a duplicate. An unexpired invitation queues a new delivery generation only when `notification_status = "failed"`, or when it is `suppressed` and registration has since been enabled; `queued` and `sent` deliveries are not duplicated. If the existing invitation has expired but has not yet been cleaned up, the add request resets `expires_at`, increments `notification_generation`, clears `notification_sent_at`, and either queues or suppresses the replacement notification under the registration-disabled rule; it returns `200 OK` with the refreshed invitation. Newly created collaborators or invitations return `201 Created`.
- `POST /api/v1/api_keys`: JSON body with `name`, `scopes`, and optional `expires_at`. `name` is trimmed, must be non-blank, and must be at most 100 characters after trimming. `scopes` must be a non-empty array of valid scope strings. When `expires_at` is provided it must be a future ISO-8601 UTC timestamp; values at or before the current server time are rejected with `422 validation_failed`. The plaintext API key is returned only in this response.
- `GET /api/v1/gpg_key`: no request body. Returns the current GPG key resource, or `404 not_found` if the authenticated user has no GPG key.
- `PUT /api/v1/gpg_key`: multipart body with `public_key` and `private_key` fields containing ASCII-armored OpenPGP V4 keys. Each key field is capped at 1 048 576 bytes; larger key uploads are rejected with `413 payload_too_large`. The public and private material must identify exactly one matching V4 primary key. Validation applies the primary-first, otherwise-single-signing-subkey selection rule in GPG Signing, records the selected exact fingerprint, validates its algorithm, and completes the exact-key GPG test signature. Unparsable, V5/V6, mismatched, passphrase-protected, revoked, ambiguous, RPM-v4-incompatible, or otherwise unusable material is rejected with `422 validation_failed`, as is a key whose effective primary/selected-key expiry is less than 30 full days away. The response is `200 OK` with the GPG key resource. If `previous_gpg_key_public` is already set for the user, or if any repository owned by the user has `rpm_signing_state = "signing"`, the request is rejected with `409 conflict_gpg_key_transition_in_progress`.
- `DELETE /api/v1/gpg_key`: no request body. Returns `404 not_found` when the authenticated user has no GPG key. Returns `204 No Content` when the key exists and is not used by any repository. Returns `409 conflict_gpg_key_in_use` with `details.metadata_signed_repositories` and `details.rpm_signed_repositories` counts when an explicit revocation strategy is required. Removal is not blocked by an active key-replacement transition; a successful removal also clears `previous_gpg_key_public` and `gpg_key_transition_id` (see Key replacement and revocation).
- `POST /api/v1/gpg_key/revocation`: JSON body `{"strategy": "clear_metadata_signing"}` or `{"strategy": "delete_signed_packages"}`; or multipart body with `strategy=replace_key`, `public_key`, and `private_key` fields. Each key field in a `replace_key` request is capped at 1 048 576 bytes; larger key uploads are rejected with `413 payload_too_large`. Returns `404 not_found` when the authenticated user has no GPG key. Unknown strategies are rejected with `422 validation_failed`. Multipart revocation bodies are accepted only with `strategy=replace_key`; multipart requests carrying any other strategy value are rejected with `422 validation_failed`, so key material can never accompany a non-replacement strategy. `clear_metadata_signing` is rejected with `409 conflict_gpg_key_in_use` if any owned repository has `sign_rpms = true`. `strategy=replace_key` is rejected with `409 conflict_gpg_key_transition_in_progress` if `previous_gpg_key_public` is already set for the user, or if any repository owned by the user has `rpm_signing_state = "signing"`. The `clear_metadata_signing` and `delete_signed_packages` strategies are not blocked by an active transition and, on success, also clear `previous_gpg_key_public` and `gpg_key_transition_id`. Successful `clear_metadata_signing` and `delete_signed_packages` requests return `204 No Content`; successful `replace_key` requests return `200 OK` with the new GPG key resource.

Resource response shapes:

- Repository resources have shape `{"id": "<uuid>", "owner_id": "<uuid>", "slug": "stable", "name": "Stable", "description": null, "is_public": true, "gpg_key_fingerprint": null, "sign_rpms": false, "rpm_signing_state": "disabled", "metadata_revision": 0, "package_count": 0, "inserted_at": "...", "updated_at": "..."}`. The API's semantic `owner_id` field maps to the repository table's `user_id` foreign key; `user_id` is not also emitted.
- Package list resources have shape `{"id": "<uuid>", "repository_id": "<uuid>", "rpm_format": 6, "name": "nginx", "epoch": 0, "version": "1.24.0", "release": "2.fc39", "arch": "x86_64", "summary": "A high performance web server and reverse proxy server", "size_package": 623104, "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "download_path": "/repos/stable/packages/<uuid>/nginx-1.24.0-2.fc39.x86_64.rpm", "inserted_at": "...", "updated_at": "..."}`.
- Package detail resources include every package list field plus `description`, `url`, `license`, `size_installed`, `size_archive`, `build_time`, `rpm_sourcerpm`, `rpm_sourcenevr`, `rpm_group`, `rpm_vendor`, `rpm_buildhost`, `requires`, `provides`, `conflicts`, `obsoletes`, `files`, and `changelogs`. `build_time` is an ISO-8601 UTC timestamp or `null`. Package resources never expose the internal `storage_path`, `storage_version_id`, `header_start`, or `header_end`.
- Upload-intent resources have shape `{"id": "<uuid>", "repository_id": "<uuid>", "package_id": "<uuid>", "mode": "api", "status": "processing", "original_filename": "nginx.rpm", "declared_size": 623104, "attempts": 1, "expires_at": null, "error": null, "package": null, "completed_at": null, "inserted_at": "...", "updated_at": "..."}`. `status` is one of the Upload Intents states, although API-mode resources never enter `preview_ready`. `expires_at` is non-null only while awaiting a direct transfer or web confirmation. `error` is null except on `failed`, where it has `{"code": "signing_unavailable", "message": "RPM signing is temporarily unavailable"}` with no tool output or storage detail. `package` is the package detail resource on `succeeded`; it becomes null if that package is later deleted, while the immutable `package_id` remains available for correlation. The internal reservation, staging key/version, and lease token are never exposed; the status resource also omits the upload generation, while create and refresh responses include the current generation only inside the ephemeral `upload` capability object.
- Optional string fields use `null` when absent.
- Dependency entries in `requires`, `provides`, `conflicts`, and `obsoletes` have shape `{"name": "libc.so.6()(64bit)", "op": ">=", "epoch": 0, "version": "2.34", "release": null}`. `op` is one of `<`, `<=`, `=`, `>=`, `>`, or `null`. When `op` is `null`, `epoch`, `version`, and `release` are also `null`. When `op` is set, `version` is required, `epoch` is `0` if the RPM omits an epoch, and `release` is `null` only when the RPM omits a release constraint. `requires` entries additionally include `pre`, a boolean indicating a pre-transaction dependency.
- File entries have shape `{"path": "/usr/bin/nginx", "type": "file", "flags": []}`. `type` is `file`, `directory`, or `symlink`. `flags` is an array containing zero or more of `config`, `doc`, `ghost`, `license`, and `readme`.
- Changelog entries have shape `{"timestamp": "2025-01-15T10:30:00Z", "author": "Packager <packager@example.com>", "text": "Updated to 1.24.0"}`.
- API key resources have shape `{"id": "<uuid>", "name": "CI read-only", "key_prefix": "dzak_abcdefg", "scopes": ["repo:read"], "expires_at": null, "inserted_at": "...", "updated_at": "..."}`. `POST /api/v1/api_keys` returns the same resource plus `key`, the full plaintext API key; no other response includes `key` or `key_hash`.
- GPG key resources have shape `{"fingerprint": "0123456789ABCDEF0123456789ABCDEF01234567", "signing_fingerprint": "89ABCDEF0123456789ABCDEF0123456789ABCDEF", "expires_at": "...", "public_key": "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----", "replacement_in_progress": false, "previous_public_key": null, "updated_at": "..."}`. `signing_fingerprint` identifies the exact signing-capable primary key or subkey forced for signatures; `expires_at` is an ISO-8601 UTC timestamp or `null` for a non-expiring signing key. `replacement_in_progress` is `true` exactly while the user's `previous_gpg_key_public` is set, and `previous_public_key` carries that ASCII-armored previous key; both are `false` and `null` otherwise. GPG key resources never expose private key material. `updated_at` is the owning user record's `updated_at`.

`GET /api/v1/repos/:slug/collaborators` returns collaborators and pending invitations as typed rows in the standard paginated list envelope. Rows are sorted by normalized email ascending, then by `type` (`collaborator` before `invitation`), then by `id` ascending. Collaborator rows have shape `{"type": "collaborator", "id": "<collaborator_id>", "user_id": "<user_id>", "email": "user@example.com", "inserted_at": "..."}`; `id` is the value `DELETE /api/v1/repos/:slug/collaborators/:id` takes, matching how invitations are addressed, and `user_id` is included for clients that need to correlate the row with a user. Invitation rows have shape `{"type": "invitation", "id": "<invitation_id>", "email": "pending@example.com", "invited_by_id": "<user_id>", "expires_at": "...", "notification_status": "queued", "notification_generation": 1, "notification_sent_at": null, "inserted_at": "..."}`. `expires_at` is null when invitation expiry is disabled; `notification_sent_at` is non-null only when the current generation was delivered successfully.

All list endpoints — including `/api/v1/repos`, `/api/v1/repos/:slug/packages`, `/api/v1/repos/:slug/collaborators`, and `/api/v1/api_keys` — support `page` and `per_page` query parameters and return the same paginated envelope. `page` defaults to `1` and must be an integer from `1` through `10 000`; larger, non-integer, or non-positive values are rejected with `422 validation_failed`. `per_page` defaults to `50` and is capped at `100` (larger positive integers are clamped to `100`); non-integer or non-positive values are rejected. `total_pages` is computed as `ceil(total / per_page)`, so it is `0` when `total` is `0`. A valid `page` greater than `total_pages` succeeds with `200 OK`, returns an empty `data` array, and echoes the requested page in the pagination envelope. Default ordering is deterministic: repositories by `slug` ascending then `id` ascending; packages by `name` ascending, `arch` ascending, RPM EVR descending, then `id` ascending; collaborators as described above; and API keys by `inserted_at` descending then `id` ascending.

Package list endpoints additionally support `q`, `name`, `arch`, and `sort`. The three filter strings are trimmed and capped at 256 characters; longer values are rejected with `422 validation_failed`. A blank `q` is treated as absent, while blank `name` or `arch` exact-match filters are rejected. The `q` parameter performs a case-insensitive literal substring match against package `name` and `summary` — a package matches when either contains the substring; `%`, `_`, and the chosen SQL escape character in user input are escaped before the parameterized `ILIKE` expression, so they are never interpreted as pattern syntax. `name` and `arch` are parameterized exact-match filters. Valid package sort values are `name`, `version`, `arch`, and `inserted_at`; prefix with `-` for descending order. The `version` sort orders packages by RPM EVR using `(epoch, version, release)` and RPM's native comparison semantics, with `name`, `arch`, and `id` as deterministic ascending tie-breakers. `-version` reverses only EVR ordering. For every other descending sort, only the named sort column is reversed; tie-breakers remain ascending. Non-version package sorts use `id` ascending as their only tie-breaker. Unknown sort values are rejected with `422 validation_failed`.

RPM EVR ordering is implemented in PostgreSQL, not approximated with lexical SQL ordering or host-language package versions. A schema migration owns `dark_zenith_rpmvercmp(text, text)` and `dark_zenith_evr_cmp(bigint, text, text, bigint, text, text)`, both declared `IMMUTABLE`, `STRICT`, and `PARALLEL SAFE`. The first implements the RPM 6 segment algorithm exactly, including tilde, caret, numeric-versus-alpha segments, separators, and leading-zero behavior; the second compares numeric epochs first, then version and release with `dark_zenith_rpmvercmp`. The migration also defines a named `dark_zenith_rpm_evr` composite type, comparison operators, and a default btree operator class whose support function delegates to the six-argument comparator. Version queries order by `ROW(epoch, version, release)::dark_zenith_rpm_evr`, so filtering, ordering, and pagination remain one database query. ExUnit conformance fixtures cover every upstream librpm comparison case used by the supported RPM 6 release, and a release test differentially compares the PostgreSQL comparator with the boot-required RPM 6 tooling before deployment. Comparator or operator-class changes require a migration and those conformance tests.

Successful JSON responses use a `data` envelope:

- Single-resource responses: `{"data": {...}}`
- List responses: `{"data": [...], "pagination": {"page": 1, "per_page": 50, "total": 123, "total_pages": 3}}`
- Create responses: HTTP 201 with the created resource in `data`
- Accepted asynchronous upload completion: HTTP 202 with the current upload-intent resource in `data` and `Retry-After: 2`
- Upload-intent status polling: HTTP 200 with the current upload-intent resource in `data`, plus `Retry-After: 2` while the status is `queued` or `processing`
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
      "metadata_signed_repositories": 2,
      "rpm_signed_repositories": 1
    }
  }
}
```

`metadata_signed_repositories` counts every repository owned by the user with `gpg_key_fingerprint` set, including those that also have `sign_rpms = true`; `rpm_signed_repositories` counts the subset with `sign_rpms = true`.

Standard API error codes:

| HTTP | Code                                       | Meaning                                                                                                |
| ---: | ------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
|  400 | `invalid_request`                          | Malformed JSON, malformed GPG-key multipart body, or unsupported content type                           |
|  401 | `unauthenticated`                          | Missing, expired, or invalid credentials                                                               |
|  403 | `forbidden`                                | Authenticated user lacks the required scope, repository permission, or allowed authentication method    |
|  404 | `not_found`                                | Requested repository, package, upload intent, collaborator, invitation, API key, or GPG key was not found |
|  409 | `conflict_duplicate_package`               | Package with the same repository/name/epoch/version/release/arch already exists                        |
|  409 | `conflict_gpg_key_expired`                 | A configured signing key has expired and must be replaced or removed                                   |
|  409 | `conflict_gpg_key_in_use`                  | GPG key removal requires an explicit revocation strategy because one or more repositories still use it |
|  409 | `conflict_gpg_key_transition_in_progress`  | GPG key replacement was requested while a key or RPM signing transition is still active                |
|  409 | `conflict_repository_metadata_limit_exceeded` | Package mutation would exceed a repository package-count or uncompressed-repodata-size limit         |
|  409 | `conflict_repository_quota_exceeded`       | Repository creation would exceed the owner's `MAX_USER_REPOSITORIES` limit                             |
|  409 | `conflict_storage_quota_exceeded`          | Upload would exceed the repository owner's `MAX_USER_STORAGE_BYTES` storage quota                      |
|  409 | `conflict_upload_state`                    | Upload completion, refresh, cancellation, or version does not match the intent's current state          |
|  409 | `conflict_user_owns_repositories`          | Admin attempted to delete a user that still owns repositories                                          |
|  413 | `payload_too_large`                        | Declared RPM size or a request body exceeds the applicable configured or documented limit               |
|  422 | `validation_failed`                        | Request shape is valid but field values failed validation                                              |
|  429 | `rate_limited`                             | Request exceeded the applicable rate limit                                                             |
|  500 | `internal_error`                           | Unexpected server error                                                                                |
|  503 | `rpm_verification_unavailable`             | Required RPM 6 verification tooling or its isolated temporary keyring is unavailable                   |
|  503 | `signing_unavailable`                      | Required RPM/GPG signing tooling or signing infrastructure is temporarily unavailable                   |
|  503 | `storage_unavailable`                      | Backblaze B2 or object-storage operation is temporarily unavailable                                    |
|  503 | `upload_temp_space_unavailable`            | Temporary upload workspace lacks the required free space                                               |

That table enumerates the `/api/v1/...` codes. Repository-serving endpoints reuse the same codes as bare plain-text bodies and add one code of their own: `503 metadata_not_ready`, returned with `Retry-After: 5` when a repository's metadata cache is missing or behind its current `metadata_revision` (see Metadata Generation & Storage). `metadata_not_ready` never appears in the JSON error envelope.

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
      "epoch": 0,
      "version": "1.24.0",
      "release": "2.fc39",
      "arch": "x86_64",
      "summary": "A high performance web server and reverse proxy server",
      "size_package": 623104,
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "download_path": "/repos/stable/packages/550e8400-e29b-41d4-a716-446655440000/nginx-1.24.0-2.fc39.x86_64.rpm",
      "inserted_at": "2025-01-15T10:30:00Z",
      "updated_at": "2025-01-15T10:30:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 50,
    "total": 1,
    "total_pages": 1
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
| `SECRET_KEY_BASE` | — | Phoenix secret key |
| `PREVIOUS_SECRET_KEY_BASE` | — | Optional. Prior value of `SECRET_KEY_BASE` during a rotation window so encrypted GPG private keys can be decrypted while the background re-encryption jobs migrate them. Remove once every row has been migrated. |
| `TRUSTED_PROXIES` | empty | Comma-separated list of reverse-proxy IPv4/IPv6 addresses or CIDR blocks whose forwarded client headers the application trusts: `CF-Connecting-IP` and `X-Forwarded-For` for client-IP detection, and `X-Forwarded-Proto` for production HTTPS rewriting. Empty means no proxy is trusted; forwarded headers are ignored, the TCP peer address is used, and Phoenix relies on the connection's own scheme. |
| `PHX_HOST` | `localhost` | Public hostname for URL generation |
| `PHX_SCHEME` | `https` | Public URL scheme; `http` is allowed for local development |
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
| `RPMSIGN_PATH` | `rpmsign` | Path to the `rpmsign` executable used when RPM signing is enabled |
| `GPG_PATH` | `gpg` | Path to the `gpg` executable used by metadata signing and `rpmsign` |
| `RPM_TOOL_TIMEOUT_SECONDS` | `1800` | Hard timeout for each `rpmkeys`, `rpmsign`, or `gpg` child; must be an integer from `60` through `7200` |
| `MAX_RPM_UPLOAD_BYTES` | `536870912` | Maximum accepted RPM upload size in bytes (default 512 MiB); must be an integer from `1` through `5368709120`, B2's 5 GiB ceiling for the single-`PutObject` upload flow |
| `MAX_USER_STORAGE_BYTES` | `53687091200` | Maximum total stored RPM bytes per user across owned repositories (default 50 GiB); `0` disables the quota |
| `MAX_USER_REPOSITORIES` | `100` | Maximum repositories one user may own at once; must be a non-negative integer, and `0` disables the limit |
| `MAX_REPOSITORY_PACKAGES` | `10000` | Maximum package records in one repository; must be a positive integer |
| `MAX_REPODATA_OPEN_BYTES` | `268435456` | Maximum uncompressed bytes in each generated primary, filelists, or other XML artifact (default 256 MiB); must be a positive integer |
| `RPM_UPLOAD_TMPDIR` | system temp | Directory used for per-upload temporary working files |
| `MAIL_ADAPTER` | `zepto` | Outbound email adapter (Swoosh module). Default uses Zepto Mail. See Email Delivery below. |
| `ZEPTO_API_KEY` | — | Zepto Mail API key (required when `MAIL_ADAPTER=zepto`) |
| `MAIL_FROM_ADDRESS` | — | Sender address for outbound notifications (required for every mail adapter; development may use a non-routable local address with the `local` adapter) |
| `MAIL_FROM_NAME` | `Dark Zenith` | Display name shown for the sender |
| `INVITATION_EXPIRY_DAYS` | `30` | Days before a pending collaborator invitation expires; `0` disables expiry |
| `REGISTRATION_ENABLED` | `false` | Whether new account registration is open |
| `ADMIN_EMAIL` | — | Email for the initial admin account, created on first boot if no users exist |
| `ADMIN_PASSWORD` | — | Password for the initial admin account |

---

## Email Delivery

Dark Zenith sends transactional emails for:

- Account email confirmation and password reset (via `phx.gen.auth`).
- Collaborator invitations to registered and unregistered users (subject to the registration-disabled exception described under Repository Collaborators).
- GPG signing-key expiry reminders at the 30-, 7-, and 1-day thresholds described under GPG Signing.
- Security notifications to the affected account: password changed or reset, account email changed (sent to the previous address), GPG key uploaded, replaced, or removed, and new API key created.

Email delivery is built on Swoosh with a pluggable adapter selected by `MAIL_ADAPTER`. The application code uses a single `DarkZenith.Mailer` module and a thin notifier layer, so swapping providers is a configuration change rather than a code change. `MAIL_ADAPTER` accepts the following short aliases:

| Alias | Backing adapter | Notes |
|---|---|---|
| `zepto` | Zepto Mail HTTPS API | Default. Requires `ZEPTO_API_KEY` and `MAIL_FROM_ADDRESS`. |
| `smtp` | `Swoosh.Adapters.SMTP` | Configure host, port, username, password, and TLS settings in `config/runtime.exs`. |
| `local` | `Swoosh.Adapters.Local` | In-memory mailbox for development; messages can be viewed at `/dev/mailbox`. The `/dev/mailbox` route is mounted only in the dev Mix environment. |

Unknown aliases cause the application to refuse to boot. `MAIL_FROM_ADDRESS` is required for every adapter because every message needs a sender; with the default `MAIL_ADAPTER=zepto`, `ZEPTO_API_KEY` is additionally required, and with `MAIL_ADAPTER=smtp`, the SMTP connection settings are additionally required. Development and test deployments may set `MAIL_ADAPTER=local` with a non-routable development sender to avoid external mail credentials. Additional Swoosh adapters can be wired in by adding a new alias to this mapping in a future release.

Outbound mail uses `MAIL_FROM_ADDRESS` as the sender and `MAIL_FROM_NAME` (default `Dark Zenith`) as the display name. Every email is dispatched through an Oban worker so a transient provider outage does not fail the originating request. The Oban job is inserted in the same database transaction as the state change that triggers the message, so a successful password/key/account/invitation action cannot commit without also durably recording its notification work. Delivery is at-least-once: a worker crash after provider acceptance but before its success transaction may send the same message again. Delivery jobs retry up to 20 attempts with exponential backoff and exhausted jobs remain visible in Oban for admin intervention.

---

## Deployment

Dark Zenith is designed for straightforward deployment:

- **Mix releases**: Standard Elixir release via `mix release`, producing a self-contained binary.
- **Docker**: Dockerfile provided for containerized deployment.
- **Systemd**: Example systemd unit file provided.
- **Reverse proxy**: Designed to sit behind nginx/caddy and optionally Cloudflare for TLS termination. Every terminating proxy address or network must be listed in `TRUSTED_PROXIES`; the application discards forwarded client-IP and scheme headers from any other peer before client-IP resolution and `force_ssl` processing. The trusted edge proxy strips client-supplied `CF-Connecting-IP`, `X-Forwarded-For`, and `X-Forwarded-Proto` values and writes its own authoritative values, and the application listen port is not exposed around that edge in production. Only bounded JSON control requests and GPG-key multipart requests traverse that path; RPM `PUT` requests use presigned `B2_ENDPOINT` URLs and bypass the app's proxy and Cloudflare zone. The proxy therefore needs the documented 1 048 576-byte JSON limit and 2 162 688-byte GPG multipart limit, not `MAX_RPM_UPLOAD_BYTES`. Cloudflare's proxied request-body cap does not constrain RPM size in this architecture.
- **B2 browser CORS**: The private bucket has a narrowly scoped CORS rule whose allowed origin is exactly the canonical public Phoenix origin derived from `PHX_SCHEME`, `PHX_HOST`, and `PHX_URL_PORT` (default ports are omitted, as browsers do when serializing `Origin`); allowed method is `PUT`; allowed request header is `Content-Type`; and exposed response header is `x-amz-version-id`. Development origins are added explicitly rather than using `*`. CORS grants browser response access only—it does not make the bucket public—and every upload still requires a valid presigned URL for one exact staging key. Presigned URLs are generated with path-style addressing (`<B2_ENDPOINT>/<bucket>/<key>`) so the browser's `PUT` targets exactly the `B2_ENDPOINT` origin allowed by the `Content-Security-Policy` `connect-src` list; virtual-hosted-style addressing would place the request on a different origin and be blocked.
- **RPM verification and signing tools**: `RPMKEYS_PATH` is required in every deployment because every upload is verified. At boot Dark Zenith resolves the executable, runs its version probe under `LC_ALL=C`, and refuses to start unless it is RPM 6.0 or newer. Deployments that allow metadata or package signing must additionally provide `gpg`, and those that enable RPM signing must provide `rpmsign`; a missing optional signing executable makes the affected operation fail with `503 signing_unavailable`. These native tools process attacker-supplied material, so the example systemd unit confines the application: a dedicated unprivileged user, `NoNewPrivileges=true`, `PrivateTmp=true`, and `ProtectSystem=strict` with write access limited to `RPM_UPLOAD_TMPDIR`; operators not using systemd should apply equivalent confinement. Mounting `RPM_UPLOAD_TMPDIR` on tmpfs keeps uploaded files, signing working copies, temporary RPM keyrings, and decrypted key material off persistent storage.
- **Health check**: `GET /health` and `HEAD /health` are unauthenticated liveness probes that return `200 OK` with a `text/plain; charset=utf-8` body of `ok` whenever the application is up and serving requests. They perform no database or B2 calls, so they signal process liveness rather than dependency readiness, and they are excluded from rate limiting (see Rate Limiting).
- **Single application node**: The initial version assumes one app node because rate-limit buckets live in node-local memory (ETS). Upload and signing jobs do not require session affinity or a shared temporary filesystem: their durable source is an exact private B2 version, and any node can reconstruct a clean local attempt under its own `RPM_UPLOAD_TMPDIR`. Running multiple nodes still requires a shared rate-limit store and coordinated deployment testing, and is out of scope for the initial version.

### Initial Setup

Since `REGISTRATION_ENABLED` defaults to `false`, the first admin account is bootstrapped via environment variables (`ADMIN_EMAIL` and `ADMIN_PASSWORD`). On first boot, if no users exist in the database, a confirmed admin user is created with these credentials. If no users exist but `ADMIN_EMAIL` or `ADMIN_PASSWORD` is unset, Dark Zenith logs a warning and starts without creating an admin; the operator must restart with both variables set to bootstrap an admin. `ADMIN_EMAIL` and `ADMIN_PASSWORD` must satisfy the same email and password validation rules as regular accounts; if either fails validation, Dark Zenith logs a warning and starts without creating an admin, the same as when the variables are unset. After the initial admin is created, these environment variables are ignored; operators should remove them from the environment after the first successful boot and rotate the bootstrap password from the web UI, since process environments are visible to host tooling. Additional users can be created by the admin or by enabling public registration.

If an existing installation has users but no administrator, an operator can promote one already-confirmed account with `bin/dark_zenith eval 'DarkZenith.Release.promote_admin("user@example.com")'`. The release function normalizes and validates the email, opens a transaction, acquires the same instance-wide transaction-scoped PostgreSQL advisory lock used by bootstrap and every admin-flag mutation, and rechecks that the database has zero admins. It then requires one existing confirmed user at that email, changes only that user's `is_admin` flag, and writes a system-authored `admin.recovery_promote` audit event in the same transaction. It refuses to act if an admin already exists, the user is missing, or the user is unconfirmed; it never creates an account or accepts a password. This makes the recovery command safe to retry and prevents two concurrent operators or a racing bootstrap from promoting multiple recovery admins.

### Storage

RPM files are stored exclusively in a private Backblaze B2 bucket whose anonymous access is disabled. Client uploads go directly to presigned staging keys and download clients are redirected to signed final versions, so neither client-facing payload path consumes app-server or Cloudflare bandwidth. Background workers do read staged bytes into local temporary storage and write or copy accepted final bytes, so worker network, disk, and native-tool capacity must be sized for concurrent processing. The bucket-scoped B2 application key needs only listing, reading, writing/copying, and deleting file versions (`listFiles`, `readFiles`, `writeFiles`, and `deleteFiles`); it must not be account-wide or exposed to clients. A lifecycle rule may retain only the latest version at write-once final keys as defense in depth, but `staging/uploads/` must remain under database-aware exact-version cleanup so delayed retries keep their source. Dark Zenith stores each accepted version ID, signs downloads for that exact version, and permanently deletes versions explicitly. The reconcilers therefore also require permission to list object versions and delete identified versions and delete markers.

---

## Security Considerations

- Mutating actions (create repo, upload RPM, delete) require session auth (web) or bearer token auth (API).
- Mutating actions on a repository are restricted to the repo owner or an admin user. API keys inherit the permissions of their owning user.
- API key and GPG key management endpoints require session token or session cookie authentication; API keys cannot manage API keys or GPG keys.
- Public read-only endpoints (repo browsing, package listing, repodata, RPM downloads) require no authentication for public repos.
- Private repo read endpoints require authentication. Browser requests may use the user's session; RPM clients use HTTP Basic Auth with API keys for repodata and RPM downloads.
- Signed B2 URLs expire after `B2_SIGNED_URL_TTL` seconds (default 30 minutes), limiting the window for URL sharing/leakage. The 302 responses that carry them, and every response for a private repository, are marked `Cache-Control: private, no-store` so an intermediary cache cannot redistribute them (see Caching headers).
- Presigned B2 upload URLs expire after `B2_UPLOAD_URL_TTL` seconds (default one hour), authorize only `PutObject` to one random staging key with the signed content type and declared content length, and are returned only over authenticated `Cache-Control: no-store` control responses. They do not reveal the bucket application key. The bucket CORS rule names exact trusted web origins and exposes only the version header needed for completion.
- Unvalidated direct uploads are quarantined under the private `staging/uploads/` prefix and are never reachable through a repository route. Declared-size enforcement, quota reservation, waiting-state expiration, exact-version cleanup, and reconciliation bound normal retention; only a fully validated and optionally signed version can be referenced by a package row.
- Accepted risk: B2's documented S3 `PutObject` surface creates a new version when the same key is written again and does not document a conditional create-only header. A presigned `PUT` is therefore replayable until its signed expiry, so a malicious authorized uploader or leaked URL can temporarily create multiple same-sized staging versions outside `MAX_USER_STORAGE_BYTES`. The one-hour URL, 60-intent/hour issuance limit, no-overlap refresh rule, hourly orphan deletion, bucket billing alerts/budgets, and private non-serving prefix limit exposure and duration, but do not provide a hard instantaneous staging-byte quota; an application outage also delays reconciliation. Operators that require such a hard quota must place uploads behind a metered upload service instead of enabling direct-to-B2 transfer.
- B2 storage keys use server-generated UUIDs and random values rather than client filenames, preventing key manipulation. Completion accepts only the current intent key and an exact B2 version whose length and content type match the reservation.
- GPG private keys are encrypted at rest in the database with the versioned AES-256-GCM envelope described in GPG Signing. They are decrypted only during signing operations and written, when required by `gpg` or `rpmsign`, only inside the mode-restricted ephemeral `GNUPGHOME`; deployments should place `RPM_UPLOAD_TMPDIR` on tmpfs as described above.
- Rotating `SECRET_KEY_BASE` invalidates Phoenix cookie sessions and all stored HMAC token hashes that use it (API keys and session tokens). Operators must communicate the rotation in advance; users must sign in again and re-create API keys afterward. Upload intents are scoped database resources rather than HMAC bearer tokens, so rotation does not invalidate already staged objects; their normal authenticated ownership and expiry checks still apply. GPG private keys survive `SECRET_KEY_BASE` rotation only when operators follow the dual-base rotation procedure — set `PREVIOUS_SECRET_KEY_BASE` to the prior value while the background re-encryption jobs run and remove it once every row has been migrated. See the GPG private key encryption envelope section for the full procedure. Per-token envelope versioning for HMAC token hashes is reserved for a future release.
- Downloadable `.repo` files never include API keys, session tokens, or passwords.
- Rate limiting on all dynamic application requests and LiveView application events, with the explicit health/static/transport exclusions in Rate Limiting below.
- CSRF protection on all web form submissions and cookie-authenticated mutating API requests (standard Phoenix behavior).
- Production deployments enable `force_ssl` (TLS redirect plus `Strict-Transport-Security`) at the Phoenix endpoint even behind the reverse proxy. Trusted-proxy normalization removes `X-Forwarded-Proto` unless the immediate TCP peer is in `TRUSTED_PROXIES`; only then does `rewrite_on: [:x_forwarded_proto]` honor the terminating proxy's value so proxied HTTPS requests are not redirect-looped. This prevents a direct HTTP client from spoofing `X-Forwarded-Proto: https` to bypass the redirect. Session cookies are `secure`, `http_only`, and `SameSite=Lax`; responses set `X-Content-Type-Options: nosniff`; and web UI responses carry a restrictive, LiveView-compatible `Content-Security-Policy`. Its `connect-src` permits only the app's own HTTP/WebSocket origins plus the exact HTTPS origin of `B2_ENDPOINT`, which is required for browser `PUT` requests; it does not wildcard object-storage domains.
- Post-login redirect targets are stored server-side and must be local paths; client-supplied absolute URLs are never used as redirect destinations.
- Request logging never records `Authorization` headers, Basic Auth passwords, token or API key values, GPG key material, or passwords; Phoenix `filter_parameters` covers the password, token, key, and GPG key fields, and URLs are logged without userinfo.
- Security-relevant actions are recorded in an append-only audit log (see Audit Events), and users receive email notifications for password changes and resets, account email changes, GPG key upload, replacement, or removal, and API key creation.
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
- **Package uploads**: 60 new upload intents per hour per user, in addition to the authenticated general request limit. Intent creation is the operation that reserves quota and mints a B2 capability, so it consumes the specialized bucket for both REST and web flows. Refresh, completion, status polling, confirmation, and cancellation consume only the authenticated general bucket; a direct client-to-B2 `PUT` does not reach the application limiter. Refresh is unavailable until the prior URL expires, so it does not intentionally create overlapping live capabilities; an old presigned URL cannot be cryptographically revoked and remains subject to the replay risk described under Security Considerations until its signed expiry.
- **Repository creations** (`POST /api/v1/repos` and the equivalent web action): 30 requests per hour per user, in addition to the authenticated general request limit. Deleting a repository permanently retires its slug until an admin releases it, so bounding creation volume also bounds how quickly one user can accumulate retired slug reservations through create/delete churn. `MAX_USER_REPOSITORIES` separately caps how many repositories one user holds at once.
- **Collaborator additions** (`POST /api/v1/repos/:slug/collaborators` and the equivalent web action): 60 requests per hour per user, in addition to the authenticated general request limit, bounding the volume of invitation email a single user can trigger.
- **Account email change requests** (the web settings action that emails a confirmation link to the proposed new address): 10 requests per hour per user, in addition to the authenticated general request limit, bounding the volume of confirmation email a single user can direct at arbitrary addresses.

A credential selects a per-user bucket only after successful authentication. Missing, malformed, expired, or revoked credentials use the applicable unauthenticated per-IP bucket even when the endpoint subsequently returns an authentication error or masks a private repository as not found. Authentication-attempt routes consume and check the IP bucket before parsing their bounded body; only a syntactically valid email then consumes the second email bucket.

Every rate-limited HTTP response includes `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and `X-RateLimit-Reset`. The remaining value is measured after consuming the current request and is clamped at zero; reset is the governing window's exclusive end as a Unix epoch timestamp in seconds. A request whose atomic post-increment count is less than or equal to the limit is admitted, so the request that consumes the last available slot succeeds with `X-RateLimit-Remaining: 0`; only a count greater than the limit is rejected. When more than one bucket applies, the headers describe the bucket with the smallest remaining allowance; ties choose the earliest reset, then the lower limit. If any applicable bucket is over its limit, endpoint work does not run and the server responds **429 Too Many Requests**, additionally setting `Retry-After` to the positive number of whole seconds until that governing reset. For unauthenticated API and web requests, the JSON/HTML 429 message encourages account creation and authentication for higher limits. Repository-serving endpoints keep the plain-text `rate_limited` body described in the RPM Repository Endpoint section.

The initial LiveView HTTP handshake consumes the applicable general bucket and receives normal HTTP rate-limit headers. Each subsequent user-initiated LiveView event consumes the applicable general bucket — per-user when the socket is authenticated, per-IP otherwise; upload-intent creation, repository-creation, collaborator-addition, and account-email-change events also consume their corresponding specialized bucket under the same rules as HTTP endpoints. When a socket event is rejected, its handler does not run and the server replies with a `rate_limited` payload containing `limit`, `remaining`, `reset`, and `retry_after`; the LiveView displays the error without disconnecting. Heartbeats, reconnect bookkeeping after a successfully limited handshake, server pushes, and internal component messages consume no bucket.

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
