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
- **Upload RPM packages**: Repository owners and admins can upload new RPM versions to a repository.

### REST API

- Programmatic access to repository operations: creating repos, listing repos, listing packages, uploading RPMs, deleting packages, etc.
- Authenticated via bearer tokens (API keys or short-lived session tokens), with session cookies accepted for web-originated calls.

### RPM Repository Serving

- The web app renders all `repodata/` metadata (`repomd.xml`, `primary.xml.gz`, etc.) that `dnf`/`yum` need.
- RPM files are stored in **Backblaze B2** object storage.
- When a client requests an RPM file, Dark Zenith responds with a redirect to a **signed B2 URL with a configurable access window** (default 30 minutes).
- The app never proxies RPM file bytes — it only generates and serves metadata, HTML, and signed download URLs.

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
                        ┌──────────────────────────────────┐
                        │          Dark Zenith              │
                        │         (Phoenix App)             │
                        ├──────────┬───────────┬───────────┤
                        │   Web    │  REST API │   Repo    │
                        │   UI     │ (JSON)    │  Endpoint │
                        │(LiveView)│           │ (repodata)│
                        ├──────────┴───────────┴───────────┤
                        │          Core Domain              │
                        │  (Packages, Repos, Metadata)      │
                        ├──────────────────┬───────────────┤
                        │    PostgreSQL    │  Backblaze B2  │
                        │   (metadata)    │  (RPM files)   │
                        └──────────────────┴───────────────┘
                                                  │
                                      signed URLs (default 30 min)
                                                  │
                                                  ▼
                                          RPM client (dnf)
```

---

## Data Model

### Repositories

A Dark Zenith instance can host multiple named repositories. Each repository is an independent RPM repo with its own metadata and package set.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `user_id` | UUID | FK to users — the owner of this repository |
| `slug` | string | URL-safe identifier (e.g., `stable`, `nightly`) |
| `name` | string | Display name |
| `description` | text | Optional description |
| `gpg_key_fingerprint` | string | Optional 40-character uppercase hex OpenPGP V4 fingerprint of the GPG key used to sign metadata for this repo. Must match `gpg_key_fingerprint` on the owner's user record at the time the field is set. |
| `sign_rpms` | boolean | Whether uploaded RPMs are automatically signed with the repo owner's GPG key (default `false`; requires `gpg_key_fingerprint` to be set) |
| `is_public` | boolean | Whether unauthenticated users can list, browse, and download from the repo (default `false`) |
| `metadata_revision` | integer | Monotonic revision incremented whenever package membership, package metadata used in repodata, or metadata signing settings change (default `0`) |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

**Unique constraint**: `(slug)`

### Packages

Each package record represents a single RPM file within a repository.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories |
| `name` | string | Package name (e.g., `nginx`) |
| `epoch` | integer | Non-negative RPM epoch (default `0` when the RPM has no epoch) |
| `version` | string | Package version (e.g., `1.24.0`) |
| `release` | string | Package release (e.g., `2.fc39`) |
| `arch` | string | Architecture (`x86_64`, `noarch`, `aarch64`, etc.) |
| `summary` | string | One-line description |
| `description` | text | Full description |
| `url` | string | Upstream project URL |
| `license` | string | License identifier |
| `size_installed` | bigint | Installed size in bytes |
| `size_package` | bigint | RPM file size in bytes |
| `sha256` | string | Lowercase hex-encoded SHA-256 checksum of the RPM file |
| `rpm_sourcerpm` | string | Source RPM name |
| `rpm_group` | string | RPM group |
| `storage_path` | string | Path/key where the RPM file is stored |
| `requires` | jsonb | List of dependency requirements |
| `provides` | jsonb | List of capabilities provided |
| `conflicts` | jsonb | List of conflicts |
| `obsoletes` | jsonb | List of obsoletes |
| `files` | jsonb | List of files contained in the RPM |
| `changelogs` | jsonb | Changelog entries |
| `inserted_at` | timestamp | Upload time |
| `updated_at` | timestamp | Last modification time |

**Unique constraint**: `(repository_id, name, epoch, version, release, arch)`

### API Keys

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `user_id` | UUID | FK to users — the owner of this key |
| `name` | string | Human-readable label |
| `key_hash` | string | HMAC-SHA-256 hash of the full API key string, including the `dzak_` prefix |
| `key_prefix` | string | First 12 characters of the full API key (e.g., `dzak_abcdefg`) for identification |
| `scopes` | jsonb | Allowed operations (see Scopes below) |
| `expires_at` | timestamp | Optional expiration |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

**API Key Scopes**: Scopes control which operations an API key can perform. Mutating scopes operate on repositories owned by the key's user. The `repo:read` scope grants read access based on the user's identity (owner, collaborator, or admin). Valid scopes:

| Scope | Permits |
|---|---|
| `repo:read` | Read access to private repositories the user can access (as owner, collaborator, or admin) |
| `repo:create` | Create new repositories |
| `repo:update` | Update repository settings |
| `repo:delete` | Delete repositories |
| `package:upload` | Upload RPM packages |
| `package:delete` | Delete packages from repositories |

Users can create multiple API keys with different scopes and names (e.g., a `repo:read`-only key for CI pulls, a scoped key for uploads). API key creation requires at least one valid scope. Admin users' API keys operate on all repos, not just their own (e.g., an admin key with `package:upload` can upload to any repo).

**Note**: Public repositories do not require `repo:read` — they are accessible without authentication. However, authenticated requests to public repos (using any non-expired API key with at least one valid scope) benefit from higher rate limits (see Rate Limiting).

**API Key Format**: API keys are generated from 32 bytes of cryptographically secure random data, encoded as unpadded base64url, and returned to the caller as `dzak_<secret>`. The plaintext key is shown only once at creation. The database stores `key_prefix` for display and `key_hash`, computed as `HMAC-SHA-256(SECRET_KEY_BASE, full_key_string)` and encoded as lowercase hex, where `full_key_string` is the complete returned value including the `dzak_` prefix. API key creation rejects empty scopes and unknown scope values with `422 validation_failed`. Expired keys and any persisted keys with no scopes are rejected as invalid credentials with `401 unauthenticated` before any scope-based authorization check.

### Repository Collaborators

Repo owners can grant other users read access to their private repositories. When the invited user is already registered, a collaborator record is created immediately. When the email does not match a registered user, a pending invitation is created instead and converts to a collaborator record when the user registers. The invited user receives an email notification: registered users get a direct link to the repository, and unregistered invitees get a registration link that converts the pending invitation on signup.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories |
| `user_id` | UUID | FK to users — the collaborator being granted access |
| `inserted_at` | timestamp | Creation time |

**Unique constraint**: `(repository_id, user_id)`

### Collaborator Invitations

Pending invitations for users who have not yet registered.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories |
| `email` | string | Email address of the invited user |
| `invited_by_id` | UUID | FK to users — the owner who sent the invitation |
| `inserted_at` | timestamp | Invitation time |

**Unique constraint**: `(repository_id, email)`

When a user registers with an email that has pending invitations, those invitations are automatically converted to collaborator records and the invitation rows are deleted.

### Session Tokens

Short-lived bearer tokens issued by the login endpoint for interactive/CLI use.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `user_id` | UUID | FK to users |
| `token_hash` | string | HMAC-SHA-256 hash of the full token value |
| `expires_at` | timestamp | Expiration time (24 hours after creation) |
| `inserted_at` | timestamp | Creation time |

Session tokens are generated from 32 bytes of cryptographically secure random data, encoded as unpadded base64url, and returned as `dzst_<secret>`. The database stores only `HMAC-SHA-256(SECRET_KEY_BASE, full_token_string)` encoded as lowercase hex, where `full_token_string` is the complete returned value including the `dzst_` prefix. Session tokens do not have scopes; they authorize API requests as the logged-in user and still require the same owner/admin checks as web sessions.

Expired tokens are periodically cleaned up by a background job.

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
| `source_revision` | integer | Repository metadata revision used to generate this cache entry |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last regeneration time |

**Unique constraint**: `(repository_id)`

### Users

Built on `phx.gen.auth` (bcrypt-based session authentication).

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `email` | string | Unique email address |
| `hashed_password` | string | Bcrypt password hash |
| `is_admin` | boolean | Admin flag — admins can manage all repos and users (default `false`) |
| `gpg_key_private` | binary | Optional GPG private key, encrypted at rest using the versioned GPG private key encryption envelope |
| `gpg_key_public` | text | ASCII-armored GPG public key (served at `/repos/:slug/RPM-GPG-KEY`) |
| `gpg_key_fingerprint` | string | 40-character uppercase hex OpenPGP V4 fingerprint of the stored GPG key (for display/identification) |
| `confirmed_at` | timestamp | Email confirmation time |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

### Authorization

- **Owner**: A user owns the repositories they create. Only the owner can modify (update, delete, upload to) their repositories. Owners can add collaborators to their private repos.
- **Collaborator**: A user granted read access to a private repository by its owner. Collaborators can browse, view packages, and download RPMs from that repo. They cannot modify the repo or upload packages.
- **Admin**: Users with `is_admin = true` can perform any action on any repository, manage users, and access admin-only features.
- **Public**: Unauthenticated users can browse public repos, view packages, and download RPMs. No authentication is required for read-only access to public repositories.
- **Private repos**: When `is_public = false`, all access (including repodata and RPM downloads) requires authentication. Only the owner, collaborators, and admins can access private repos.

### User Lifecycle

- User accounts are created via web registration (when `REGISTRATION_ENABLED = true`) or by an admin in the admin web UI. There is no REST API for user creation or deletion; admin user management is web-only.
- An admin can delete a user account from the admin UI, but the deletion is rejected with `409 conflict_user_owns_repositories` if that user still owns any repositories. The admin must first reassign or delete those repositories.
- Users cannot delete their own accounts; account deletion is admin-only.
- When a user is deleted, the database cascades remove their API keys, session tokens, GPG key, and pending collaborator invitations they sent, removes any collaborator membership rows where they are the collaborator, and deletes any pending collaborator invitations addressed to the deleted user's email so a later re-registration with the same email does not silently re-attach to old invites. Repositories owned by other users on which the deleted user was a collaborator are otherwise unaffected.

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
GET /repos/:slug/repodata/primary.xml.gz
GET /repos/:slug/repodata/filelists.xml.gz
GET /repos/:slug/repodata/other.xml.gz
GET /repos/:slug/packages/:id/:filename.rpm   → 302 redirect to signed B2 URL
```

### Metadata Format

Dark Zenith generates standard `repodata/` metadata as defined by the RPM repository specification:

- **`repomd.xml`**: Root metadata index. Lists the location, checksum, size, and timestamp of each metadata file (`primary`, `filelists`, `other`). This is the entry point that `dnf`/`yum` fetches first.

- **`primary.xml.gz`**: Contains package names, versions, architectures, summaries, sizes, checksums, and dependency information (requires, provides, conflicts, obsoletes). This is the main metadata file used for dependency resolution. Each package's `<location>` element uses the relative path `packages/:id/:name-:version-:release.:arch.rpm` (the standard RPM filename, with no epoch component), so RPM clients resolve downloads against the repository base URL. The route is keyed by package UUID, so the filename segment is cosmetic and does not need to match the B2 storage key, which includes the epoch.

- **`filelists.xml.gz`**: Lists all files contained in each package. Used when a user runs commands like `dnf provides /usr/bin/something`.

- **`other.xml.gz`**: Contains changelog entries for each package.

### Metadata Generation & Storage

All repodata XML is generated by the app and served directly from the app (not from B2). The metadata is stored in PostgreSQL as cached blobs so it can be served without regeneration on every request.

Metadata is regenerated as a background job (via Oban) when packages are added to or removed from a repository, or when repository settings that affect generated metadata change. Repository creation is the exception: initial empty metadata is generated synchronously during creation so a new empty repo has a current cache before it is exposed. The regeneration process:

1. Package upload/deletion increments the repository's `metadata_revision` inside the same database transaction that changes package membership.
2. The transaction enqueues a unique Oban regeneration job for the affected repository. On deletion, a separate idempotent Oban job removes the RPM file from B2 after the package row is removed.
3. The regeneration job reads the current repository `metadata_revision`, then queries all packages in the repository from PostgreSQL.
4. XML metadata files are generated in-memory and compressed with gzip.
5. A new `repomd.xml` is generated with checksums pointing to the current metadata files.
6. The generated metadata blobs, `repomd.xml`, optional `repomd.xml.asc` signature, and `source_revision` are stored in PostgreSQL keyed by repository.
7. Before completing, the job reloads the repository. If `metadata_revision` is greater than the cached `source_revision`, the job enqueues another unique regeneration job so the final cache reflects the latest package set.
8. The repo endpoint serves metadata directly from the cache once the cache `source_revision` matches the repository's current `metadata_revision`.

Repository creation writes the repository row, generates empty `primary.xml.gz`, `filelists.xml.gz`, `other.xml.gz`, `repomd.xml`, and optional `repomd.xml.asc`, and writes the metadata-cache row with `source_revision = 0` in the same database transaction. Newly created empty repos therefore immediately serve valid metadata from the cache. Repository setting changes that affect generated metadata, such as enabling/disabling metadata signing or changing `gpg_key_fingerprint`, use the same `metadata_revision` increment and regeneration enqueue path.

Metadata endpoints return `503 Service Unavailable` with plain text body `metadata_not_ready` and `Retry-After: 5` when the cache row is missing or its `source_revision` is older than the repository's current `metadata_revision`. The endpoint does not generate metadata inline and does not serve stale metadata for an out-of-date revision.

Multiple rapid changes are debounced with an Oban unique job keyed by `repository_id` while the job is available or scheduled. Running jobs are allowed to be followed by a newly queued job, and the `metadata_revision`/`source_revision` check guarantees another job runs until the cache reaches the latest revision. Metadata regeneration and B2 cleanup jobs retry up to 20 attempts with exponential backoff; exhausted jobs remain visible in Oban for admin intervention.

### RPM File Downloads

When a client (e.g., `dnf`) requests an RPM file at `/repos/:slug/packages/:id/:filename.rpm`:

1. Dark Zenith validates access to the repository identified by `:slug`, then validates that `:filename` matches `^[A-Za-z0-9._+~-]+\.rpm$`; non-matching requests are rejected with `400 invalid_request`. It then looks up the package record by `:id` scoped to that repository in PostgreSQL to find the B2 storage key. The `:filename` segment is otherwise cosmetic (ignored for routing) but provides a human-readable filename for download clients.
2. Generates a **signed Backblaze B2 URL** using `B2_SIGNED_URL_TTL` (default **30-minute expiration**).
3. Responds with **HTTP 302 redirect** to the signed URL.
4. The client downloads the RPM directly from B2.

This keeps RPM file bandwidth off the app server entirely.

### Private Repository Authentication

Private repositories (`is_public = false`) require authentication on all endpoints, including repodata and RPM downloads. RPM clients (`dnf`/`yum`) authenticate via **HTTP Basic Auth**:

- **Username**: `token` (literal string)
- **Password**: a valid API key with the `repo:read` scope

Dark Zenith checks the API key, verifies it has the `repo:read` scope, resolves the owning user, and verifies they have access to the repository (as owner, collaborator, or admin) before serving metadata or issuing a signed B2 URL.

Example `.repo` configuration for a private repo with metadata signing and RPM signing enabled:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://token:<api-key>@<hostname>/repos/:slug/
enabled=1
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://token:<api-key>@<hostname>/repos/:slug/RPM-GPG-KEY
```

Alternatively, using repo file directives:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://<hostname>/repos/:slug/
username=token
password=<api-key>
enabled=1
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://<hostname>/repos/:slug/RPM-GPG-KEY
```

For repositories without metadata signing, `repo_gpgcheck` is `0`. For repositories without RPM signing, `gpgcheck` is `0`. The `gpgkey` line is included whenever either metadata signing or RPM signing is enabled and is omitted only when both checks are disabled.

### GPG Signing (Optional)

Each user can upload a GPG key pair (public + private) to their account. The private key is encrypted at rest in the database using the GPG private key encryption envelope described below. Private keys must be dedicated repository-signing keys that can sign non-interactively; passphrase-protected private keys are rejected at upload with `422 validation_failed`.

#### GPG private key encryption

The `gpg_key_private` field stores a versioned encryption envelope rather than raw key material. Version `v1` uses AES-256-GCM with a 32-byte key derived from `SECRET_KEY_BASE` by HKDF-SHA-256 using a random 16-byte salt and the context string `dark_zenith:gpg_private_key:v1`. Each encrypted value stores the envelope version, salt, 12-byte nonce, ciphertext, and 16-byte authentication tag. The AEAD additional authenticated data is `dark_zenith:gpg_private_key:v1:<user_id>`, binding the encrypted value to the owning user.

New writes use the current envelope version. Reads dispatch by the stored version so future releases can add new encryption versions and re-encrypt existing keys in a background rotation job without losing the ability to decrypt older rows. If root secret material changes, the rotation release must keep the previous version's root secret available until all rows for that version have been re-encrypted; rows with unsupported envelope versions fail closed and require admin intervention.

When creating or editing a repository, the owner can enable two levels of signing:

#### Repository metadata signing (`gpg_key_fingerprint` set)

- `repomd.xml` is signed during metadata regeneration using the owner's GPG key.
- `repomd.xml.asc` is served alongside `repomd.xml`.
- The owner's public key is served at the repo level.

```
GET /repos/:slug/repodata/repomd.xml.asc
GET /repos/:slug/RPM-GPG-KEY
```

Both endpoints return `404 not_found` when the repository has no `gpg_key_fingerprint` configured.

#### RPM signing (`sign_rpms = true`, requires `gpg_key_fingerprint`)

When enabled, Dark Zenith automatically signs uploaded RPMs during the upload processing pipeline:

1. After RPM validation and metadata extraction, the private key is decrypted from the database.
2. The private key is imported into an ephemeral `GNUPGHOME` with `0700` permissions and removed after the signing attempt completes.
3. The uploaded RPM is copied to a temporary working path and signed with the system `rpmsign` tool, using an rpm macro configuration that points at the ephemeral GPG home and the configured key fingerprint.
4. Unsigned RPMs are signed with `rpmsign --addsign`; RPMs that already contain an OpenPGP package signature are signed with `rpmsign --resign` so the existing package signature is replaced.
5. The signed RPM is verified with `rpm --checksig`; if verification fails, the upload is rejected with `422 validation_failed` and no package row is created.
6. The SHA-256 checksum is recomputed on the signed RPM.
7. The signed RPM is uploaded to B2.

RPMs that are already signed are re-signed (the existing signature is replaced). This ensures all packages in the repo are signed with a consistent key.

If `sign_rpms` is enabled but the owner has no GPG key configured, the upload is rejected with `422 validation_failed`.

When `sign_rpms` is enabled on a repository that already has packages, the owner must explicitly confirm re-signing existing packages retroactively using the same per-package job flow described under "Key replacement and revocation". The REST API exposes this confirmation via the `existing_package_strategy` field on `PATCH /api/v1/repos/:slug` with value `"resign"`, and the web UI prompts the owner to confirm. Signing only future uploads while leaving existing packages unsigned is not supported, because generated `.repo` files must not enable `gpgcheck=1` unless every package in the repository is signed with the repository key. Disabling `sign_rpms` does not strip signatures from already-signed packages.

#### Key replacement and revocation

Users can replace their GPG key by uploading a new pair (public + private). Replacement is allowed even when repositories have signing enabled. When replacement happens:

1. The user's `gpg_key_private`, `gpg_key_public`, and `gpg_key_fingerprint` are updated to the new pair in a single transaction.
2. Every repository owned by the user that has `gpg_key_fingerprint` set has its `gpg_key_fingerprint` updated to the new fingerprint, its `metadata_revision` incremented, and a metadata regeneration job enqueued so `repomd.xml.asc` is re-signed with the new key.
3. For each affected repository where `sign_rpms = true`, a re-sign job is enqueued per existing package. Each re-sign job decrypts the new private key, downloads the existing RPM from B2, signs unsigned RPMs with `rpmsign --addsign`, re-signs already signed RPMs with `rpmsign --resign`, verifies the result with `rpm --checksig`, recomputes the SHA-256 and final RPM file size, and uploads the re-signed RPM to `repos/:slug/packages/:resign_id/:name-:epoch-:version-:release.:arch.rpm`, where `:resign_id` is a newly generated UUID for that re-sign attempt. The job then updates the package row's `sha256`, `size_package`, and `storage_path` in a single transaction. The same transaction increments the repository's `metadata_revision` and enqueues metadata regeneration so repodata reflects the new package checksum and size. The previous B2 object is deleted asynchronously by an idempotent cleanup job. If the upload succeeds but the package-row update fails, Dark Zenith immediately attempts to delete the newly uploaded object; if that cleanup fails, it enqueues an idempotent B2 cleanup job and returns the original database error to Oban for retry. Re-sign jobs retry up to 20 attempts with exponential backoff; exhausted jobs remain visible in Oban for admin intervention.

Users can also explicitly revoke (remove) their GPG key without simultaneously replacing it. If the user has no repositories with `gpg_key_fingerprint` set or `sign_rpms = true`, `DELETE /api/v1/gpg_key` and the equivalent web UI action remove the key immediately.

When the user owns any affected repositories, `DELETE /api/v1/gpg_key` returns `409 conflict_gpg_key_in_use` with counts of metadata-signed and RPM-signed repositories. The web UI prompts the user to choose one of the same explicit strategies exposed by `POST /api/v1/gpg_key/revocation`:

- **Clear metadata signing** (`strategy: "clear_metadata_signing"`): Allowed only when none of the user's repositories have `sign_rpms = true`. For every affected repository, `gpg_key_fingerprint` is cleared and metadata regeneration is enqueued. Package rows and B2 objects are left intact. The user's GPG key is then removed.
- **Delete signed packages** (`strategy: "delete_signed_packages"`): For every affected repository where `sign_rpms = true`, all package rows are deleted (which enqueues the standard B2 cleanup jobs), `gpg_key_fingerprint` is cleared, `sign_rpms` is set to `false`, and metadata regeneration is enqueued. For repositories that only have metadata signing enabled, `gpg_key_fingerprint` is cleared and metadata regeneration is enqueued without deleting packages. The user's GPG key is then removed.
- **Re-sign with a new key** (`strategy: "replace_key"`): The user uploads a new GPG key pair as part of the same multipart request, and the operation is processed as a replacement (see above) instead of a revocation.

---

## Package Upload & Processing

When an RPM file is uploaded (via web UI or API) by a repository owner or admin:

1. **Validate**: Confirm the file is a valid RPM by reading the RPM lead and header.
2. **Extract metadata**: Parse the RPM headers to extract name, version, release, epoch, arch, dependencies, file lists, changelogs, summary, description, license, etc. This is done in Elixir by reading the RPM binary format directly (RPM header structure). Verify that `epoch` is a non-negative integer and that `name`, `version`, `release`, and `arch` each match `^[A-Za-z0-9._+~-]+$`; any value that does not match is rejected with `422 validation_failed`. This keeps B2 storage keys constrained to a safe, predictable character set.
3. **Sign** (if `sign_rpms` enabled): Sign the RPM using the owner's GPG key and `rpmsign` (see GPG Signing section).
4. **Checksum and final size**: Compute SHA-256 and `size_package` from the final RPM file after any signing step has completed.
5. **Duplicate check**: If a package with the same `(repository_id, name, epoch, version, release, arch)` already exists, reject the upload with **HTTP 409 Conflict**. The database unique constraint is still the source of truth for concurrent uploads.
6. **Generate package UUID**: Allocate the package row's UUID in application code so it can be used in the B2 storage key before the row is inserted.
7. **Upload to B2**: Store the RPM file in Backblaze B2 at the per-upload key `repos/:slug/packages/:id/:name-:epoch-:version-:release.:arch.rpm`, where `:id` is the UUID generated in step 6. Including the per-upload UUID guarantees that two concurrent uploads of the same NEVRA never share a B2 path, so a failed-insert cleanup cannot delete an object referenced by another package row.
8. **Record**: Insert the package record into PostgreSQL using the UUID from step 6 and the B2 storage key from step 7, increment `metadata_revision`, and enqueue the repository metadata regeneration job in the same transaction.

If B2 upload fails, no package row is inserted and the caller receives an upload error. If the B2 upload succeeds but the database insert fails, Dark Zenith immediately attempts to delete the just-uploaded object — safe because the object's key includes the unreferenced UUID. If that cleanup fails, it enqueues an idempotent B2 cleanup job and returns the original database error to the caller. If the package insert succeeds but metadata regeneration fails, the upload remains successful; the regeneration job retries until the cache reaches the repository's latest `metadata_revision`.

Package deletion removes the package row, increments `metadata_revision`, and enqueues metadata regeneration in one database transaction. B2 object deletion happens in a separate idempotent Oban job with retries. If B2 deletion fails, the package no longer appears in metadata or API responses, and package-id download URLs no longer resolve, but the orphaned object is retried for cleanup.

Repository deletion is a hard delete. When an authorized owner or admin deletes a repository, Dark Zenith reads the current package `storage_path` values, deletes the repository row and dependent packages, collaborator, invitation, and metadata-cache rows in one database transaction, and returns `204 No Content` after that transaction commits. B2 object deletion happens after commit through idempotent cleanup jobs for the collected storage paths. If one or more B2 cleanup jobs fail, the repository remains deleted from PostgreSQL and inaccessible through the web, API, metadata, and package download endpoints while cleanup continues through Oban retries.

### RPM Parsing

For metadata extraction, rather than shelling out to `rpm` or `rpm2cpio`, Dark Zenith will include a pure-Elixir RPM header parser. The RPM format is well-documented:

- **Lead** (96 bytes): Magic number, format version. Used for quick validation.
- **Signature header**: Contains size and digest information.
- **Main header**: Contains all package metadata as tagged entries (name, version, dependencies, etc.) using a well-defined set of tag constants.
- **Payload**: The compressed cpio archive (not needed for metadata extraction).

The parser reads the lead, signature, and main header sections — the payload is stored as-is and never decompressed by Dark Zenith. Initial RPM signing relies on the system `rpmsign` and `rpm --checksig` tools instead of custom RPM signature mutation.

---

## Web Interface

The web UI is built with Phoenix LiveView. Public pages are accessible to everyone; actions that modify data (creating repos, uploading packages) require authentication and the matching authorization checks.

### Landing Page (`GET /`)

- Brief description of what Dark Zenith provides.
- Links to available repositories.

### Repository List (`GET /repos`)

- Browse public repositories with name, description, and package count; authenticated users also see private repositories they can access.
- Authenticated users see a "Create New Repo" action.

### Create Repository (authenticated)

- Form to create a new repository: name, slug, description, public/private, GPG signing settings (enable metadata signing, enable RPM auto-signing).

### Repository Detail (`GET /repos/:slug`)

- Repository description and status.
- **Setup instructions** with copy-paste `dnf` commands for adding the repo to the user's system:
  - `.repo` file contents to place in `/etc/yum.repos.d/`.
  - For public repos: unauthenticated config shown by default, with an authenticated variant (using Basic Auth with any of the user's active API keys that has at least one valid scope) recommended for higher rate limits.
  - For private repos: instructions include Basic Auth credentials using one of the logged-in user's API keys with `repo:read`. If the user has no suitable API key, prompt them to create one.
  - One-liner `dnf config-manager` command.
  - GPG key import instructions (if applicable).
- **Package list**: Searchable, sortable table of packages in this repo (name, version, arch, summary).
- Repository owners and admins see an "Upload RPM" action.
- **Owner/admin only**: "Manage Collaborators" section to add/remove users who can access a private repo.
  - Adding a collaborator by the repository owner's email is rejected with `422 validation_failed`.
  - Adding a collaborator whose normalized email already has a collaborator row or pending invitation is idempotent; the UI shows the existing collaborator or invitation instead of creating a duplicate.

### Package Detail (`GET /repos/:slug/packages/:name`)

- Lists all versions/architectures available for this package name.
- For each version: arch, summary, size, upload date.
- **Install instructions**: `dnf install <package>` command (assumes the repo is already configured).
- Links to individual package version pages, keyed by package UUID.

### Package Version Detail (`GET /repos/:slug/package-versions/:id`)

- Full package metadata: name, epoch, version, release, arch, summary, full description.
- Dependency information (requires, provides, conflicts, obsoletes).
- File list and changelog.
- Direct download link (generates a signed B2 URL).

### Upload RPM (owner/admin, `GET /repos/:slug/upload`)

- Drag-and-drop or file picker to upload an RPM to the selected repository.
- Shows extracted metadata for confirmation before finalizing.
- **Web only**: The two-step confirmation flow (preview then confirm) is a web UI feature. The REST API processes uploads immediately in a single request — see the API section.

### GPG Key Management (authenticated, account settings)

- Upload a GPG key pair (public + private) to the user's account. Uploading a new pair when one already exists is treated as a replacement and triggers automatic re-signing of metadata and (if `sign_rpms` is enabled) existing packages — see "Key replacement and revocation" under GPG Signing.
- View the fingerprint and public key of the currently uploaded key.
- Remove the existing GPG key. If any owned repositories have `gpg_key_fingerprint` set or `sign_rpms = true`, the UI prompts the user to clear metadata signing, delete RPM-signed packages, or upload a replacement key as part of the same flow.
- Passphrase-protected private keys are rejected; users should upload a dedicated repository-signing key.

### Authentication Pages

- Login / logout.
- Account registration (when enabled).
- API key management for the authenticated user.

---

## REST API

The REST API provides programmatic access to repository operations. Authentication is via `Authorization: Bearer <token>` header, where the token is either an API key or a short-lived session token obtained from the login endpoint. API endpoints also accept session cookie authentication (as used by the web UI), which allows the web frontend to call API endpoints directly and enables users to create their first API key without already having one.

Read-only endpoints for public repos are unauthenticated.

Mutating API endpoints require either session token/cookie authentication or an API key with the matching scope. Repository-scoped mutations also require the authenticated user to be the repository owner or an admin.

### Authentication

```
POST   /api/v1/auth/login               # Login with email + password, returns a short-lived session token
DELETE /api/v1/auth/logout              # Invalidate a session token
```

The login endpoint accepts `{"email": "...", "password": "..."}` and returns a short-lived bearer token (24-hour expiration). This token is distinct from API keys — it cannot be managed via the API keys endpoints, expires automatically, and is intended for interactive/CLI use. API keys remain the preferred mechanism for long-lived programmatic access.

Account registration, email confirmation, and password reset are web-only flows generated by `phx.gen.auth`; they have no REST API equivalents. Rate limits on those flows apply to the corresponding web routes.

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

`DELETE /api/v1/auth/logout` invalidates the session token presented in the `Authorization` header and responds `204 No Content`. If the request is authenticated by an API key (or by a session cookie) rather than a session token, the server responds `422 validation_failed` — only session tokens can be invalidated through this endpoint. API keys are revoked via `DELETE /api/v1/api_keys/:id`.

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
GET    /api/v1/repos/:slug/packages              # List packages (paginated, filterable)
POST   /api/v1/repos/:slug/packages              # Upload an RPM (multipart, auth required, immediate — no confirmation step)
GET    /api/v1/repos/:slug/packages/:id           # Get package details
DELETE /api/v1/repos/:slug/packages/:id           # Delete a package (auth required)
```

### Collaborators

```
GET    /api/v1/repos/:slug/collaborators              # List collaborators and pending invitations (owner/admin only)
POST   /api/v1/repos/:slug/collaborators              # Add a collaborator by email (owner/admin only; idempotent for existing collaborators/invitations; creates pending invitation if user not registered)
DELETE /api/v1/repos/:slug/collaborators/:user_id      # Remove a collaborator (owner/admin only)
DELETE /api/v1/repos/:slug/collaborators/invitations/:id  # Cancel a pending invitation (owner/admin only)
```

### API Keys

```
GET    /api/v1/api_keys                 # List your API keys (auth required)
POST   /api/v1/api_keys                 # Create an API key (auth required)
DELETE /api/v1/api_keys/:id             # Revoke an API key (auth required)
```

### GPG Keys

```
GET    /api/v1/gpg_key                  # Get your GPG key info (auth required)
PUT    /api/v1/gpg_key                  # Upload/replace your GPG key pair (auth required)
DELETE /api/v1/gpg_key                  # Remove your GPG key when it is not used by any repository (auth required)
POST   /api/v1/gpg_key/revocation       # Remove or replace an in-use GPG key with an explicit strategy (auth required)
```

### API Contract Details

JSON endpoints with request bodies require `Content-Type: application/json`. File and key upload requests use `multipart/form-data`. All timestamps are ISO-8601 UTC strings and all IDs are UUID strings. User-provided metadata strings are trimmed before validation, but secrets and key material (passwords, bearer/API token values, and GPG armored key fields) are not modified except by their documented parsers. Email addresses are normalized to lowercase. Repository slugs are normalized to lowercase and must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Unknown JSON fields are rejected with `422 validation_failed`.

Request bodies:

- `POST /api/v1/auth/login`: JSON body `{"email": "...", "password": "..."}`.
- `POST /api/v1/repos`: JSON body with required `name` and `slug`, and optional `description`, `is_public`, `gpg_key_fingerprint`, and `sign_rpms`. Requests with `sign_rpms = true` must also set `gpg_key_fingerprint` to the owner's current GPG key fingerprint or they are rejected with `422 validation_failed`.
- `PATCH /api/v1/repos/:slug`: JSON body with any subset of repository fields accepted by create. PATCH operations that would leave `sign_rpms = true` with `gpg_key_fingerprint` unset are rejected with `422 validation_failed` (mirroring the create-time constraint). Enabling `sign_rpms` on a repository that already has packages requires an explicit `existing_package_strategy` field with value `"resign"` to confirm per-package re-sign jobs identical to the key replacement flow; transitioning `sign_rpms` to `true` on a non-empty repository without this field is rejected with `422 validation_failed`. Unknown `existing_package_strategy` values are rejected with `422 validation_failed`. When `sign_rpms` is unchanged, when it is transitioning from `true` to `false`, or when it is being enabled on an empty repository, requests that include `existing_package_strategy` are rejected with `422 validation_failed`.
- `POST /api/v1/repos/:slug/packages`: multipart body with a single `rpm` file field. A duplicate NEVRA in the repository returns `409 conflict_duplicate_package`.
- `POST /api/v1/repos/:slug/collaborators`: JSON body `{"email": "user@example.com"}`. The email is normalized to lowercase before lookup. If the email belongs to the repository owner, the request is rejected with `422 validation_failed`. If a collaborator or pending invitation already exists for the normalized email, the request succeeds idempotently with `200 OK` and returns the existing collaborator or invitation instead of creating a duplicate. Newly created collaborators or invitations return `201 Created`.
- `POST /api/v1/api_keys`: JSON body with `name`, `scopes`, and optional `expires_at`. The plaintext API key is returned only in this response.
- `PUT /api/v1/gpg_key`: multipart body with `public_key` and `private_key` fields containing ASCII-armored GPG keys. The public and private keys must share the same fingerprint, and the private key must be usable for non-interactive signing.
- `DELETE /api/v1/gpg_key`: no request body. Returns `204 No Content` when the key is not used by any repository; returns `409 conflict_gpg_key_in_use` with counts of metadata-signed and RPM-signed repositories when an explicit revocation strategy is required.
- `POST /api/v1/gpg_key/revocation`: JSON body `{"strategy": "clear_metadata_signing"}` or `{"strategy": "delete_signed_packages"}`; or multipart body with `strategy=replace_key`, `public_key`, and `private_key` fields. Unknown strategies are rejected with `422 validation_failed`. `clear_metadata_signing` is rejected with `409 conflict_gpg_key_in_use` if any owned repository has `sign_rpms = true`.

All list endpoints — including `/api/v1/repos`, `/api/v1/repos/:slug/packages`, `/api/v1/repos/:slug/collaborators`, and `/api/v1/api_keys` — support `page` and `per_page` query parameters and return the same paginated envelope. `page` defaults to `1`; `per_page` defaults to `50` and is capped at `100`. Non-integer or non-positive pagination values are rejected with `422 validation_failed`. Package list endpoints additionally support `q`, `name`, `arch`, and `sort`. The `q` parameter performs a case-insensitive substring match against the package `name` and `summary` fields combined; `name` is an exact-match filter. Valid package sort values are `name`, `version`, `arch`, and `inserted_at`; prefix with `-` for descending order. The `version` sort orders packages by RPM EVR using `(epoch, version, release)` and RPM's native comparison semantics (`rpmvercmp` behavior), with `name`, `arch`, and `id` as deterministic tie-breakers. `-version` reverses the EVR ordering. Unknown sort values are rejected with `422 validation_failed`.

Successful JSON responses use a `data` envelope:

- Single-resource responses: `{"data": {...}}`
- List responses: `{"data": [...], "pagination": {"page": 1, "per_page": 50, "total": 123, "total_pages": 3}}`
- Create responses: HTTP 201 with the created resource in `data`
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

Standard API error codes:

| HTTP | Code                                | Meaning                                                                                                  |
| ---: | ----------------------------------- | -------------------------------------------------------------------------------------------------------- |
|  400 | `invalid_request`                   | Malformed JSON, malformed multipart upload, or unsupported content type                                  |
|  401 | `unauthenticated`                   | Missing, expired, or invalid credentials                                                                 |
|  403 | `forbidden`                         | Authenticated user lacks the required scope or repository permission                                     |
|  404 | `not_found`                         | Requested repository, package, collaborator, invitation, API key, or GPG key was not found               |
|  409 | `conflict_duplicate_package`        | Package with the same repository/name/epoch/version/release/arch already exists                          |
|  409 | `conflict_gpg_key_in_use`           | GPG key removal requires an explicit revocation strategy because one or more repositories still use it   |
|  409 | `conflict_user_owns_repositories`   | Admin attempted to delete a user that still owns repositories                                            |
|  422 | `validation_failed`                 | Request shape is valid but field values failed validation                                                |
|  429 | `rate_limited`                      | Request exceeded the applicable rate limit                                                               |
|  500 | `internal_error`                    | Unexpected server error                                                                                  |

To avoid leaking the existence of private resources, requests authenticated to a valid principal that target a private repository (or any resource scoped under one) which that principal cannot access return `404 not_found`, not `403 forbidden`. `401 unauthenticated` is reserved for requests that present no credentials at all (or credentials that fail validation — invalid signature, expired, revoked). `403 forbidden` is returned only when the authenticated principal is known to exist and is permitted to see the resource but lacks the specific scope or mutation permission required for the requested operation (e.g., a valid API key without `package:upload` attempting an upload to a public repo).

### Response Format

Example package response:

```json
{
  "data": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "name": "nginx",
    "epoch": 0,
    "version": "1.24.0",
    "release": "2.fc39",
    "arch": "x86_64",
    "summary": "A high performance web server and reverse proxy server",
    "size_package": 623104,
    "sha256": "abc123...",
    "inserted_at": "2025-01-15T10:30:00Z"
  }
}
```

---

## .repo File Endpoint

For convenience, serve a downloadable `.repo` file:

```
GET /repos/:slug/dark-zenith.repo
```

For private repositories, the request must be authenticated with read access to the repository. The downloaded file never embeds API keys, session tokens, or passwords. Private repo files use placeholders (`password=<api-key>`) so the same endpoint is safe to cache, inspect, and share. Personalized setup snippets that include a user's actual API key may be rendered in the authenticated web UI, but they are not returned by this endpoint.

For a repository with metadata signing and RPM signing enabled, returns a file like:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://<hostname>/repos/:slug/
enabled=1
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://<hostname>/repos/:slug/RPM-GPG-KEY
```

For repositories without metadata signing, `repo_gpgcheck` is `0`. For repositories without RPM signing, `gpgcheck` is `0`. The `gpgkey` line is included whenever either metadata signing or RPM signing is enabled and is omitted only when both checks are disabled. For private repositories, the file includes credential placeholders:

```ini
username=token
password=<api-key>
```

---

## Configuration

Dark Zenith is configured via environment variables and/or `config/runtime.exs`:

| Variable               | Default     | Description                                                                    |
| ---------------------- | ----------- | ------------------------------------------------------------------------------ |
| `DATABASE_URL`         | —           | PostgreSQL connection string                                                   |
| `SECRET_KEY_BASE`      | —           | Phoenix secret key                                                             |
| `PHX_HOST`             | `localhost` | Hostname for URL generation                                                    |
| `PORT`                 | `4000`      | HTTP listen port                                                               |
| `B2_KEY_ID`            | —           | Backblaze B2 application key ID                                                |
| `B2_APPLICATION_KEY`   | —           | Backblaze B2 application key                                                   |
| `B2_BUCKET`            | —           | B2 bucket name for RPM storage                                                 |
| `B2_ENDPOINT`          | —           | B2 S3-compatible endpoint URL                                                  |
| `B2_SIGNED_URL_TTL`    | `1800`      | Signed URL expiration in seconds (default 30 min)                              |
| `RPM_PATH`             | `rpm`       | Path to the `rpm` executable used for signature verification                   |
| `RPMSIGN_PATH`         | `rpmsign`   | Path to the `rpmsign` executable used when RPM signing is enabled              |
| `GPG_PATH`             | `gpg`       | Path to the `gpg` executable used by metadata signing and `rpmsign`            |
| `REGISTRATION_ENABLED` | `false`     | Whether new account registration is open                                       |
| `ADMIN_EMAIL`          | —           | Email for the initial admin account, created on first boot if no users exist   |
| `ADMIN_PASSWORD`       | —           | Password for the initial admin account                                         |

---

## Deployment

Dark Zenith is designed for straightforward deployment:

- **Mix releases**: Standard Elixir release via `mix release`, producing a self-contained binary.
- **Docker**: Dockerfile provided for containerized deployment.
- **Systemd**: Example systemd unit file provided.
- **Reverse proxy**: Designed to sit behind nginx/caddy for TLS termination.
- **RPM signing tools**: Deployments that enable RPM signing must have `rpm`, `rpmsign`, and `gpg` available in the runtime environment.

### Initial Setup

Since `REGISTRATION_ENABLED` defaults to `false`, the first admin account is bootstrapped via environment variables (`ADMIN_EMAIL` and `ADMIN_PASSWORD`). On first boot, if no users exist in the database, a confirmed admin user is created with these credentials. If no users exist but `ADMIN_EMAIL` or `ADMIN_PASSWORD` is unset, Dark Zenith logs a warning and starts without creating an admin; the operator must restart with both variables set to bootstrap an admin. After the initial admin is created, these environment variables are ignored. Additional users can be created by the admin or by enabling public registration.

### Storage

RPM files are stored exclusively in Backblaze B2. The app server handles no RPM file traffic — clients are redirected to signed B2 URLs. This means the app itself is lightweight and can run on modest hardware regardless of repository size or download volume.

---

## Security Considerations

- Mutating actions (create repo, upload RPM, delete) require session auth (web) or bearer token auth (API).
- Mutating actions on a repository are restricted to the repo owner or an admin user. API keys inherit the permissions of their owning user.
- Public read-only endpoints (repo browsing, package listing, repodata, RPM downloads) require no authentication for public repos.
- Private repo read endpoints require authentication. Browser requests may use the user's session; RPM clients use HTTP Basic Auth with API keys for repodata and RPM downloads.
- Signed B2 URLs expire after `B2_SIGNED_URL_TTL` seconds (default 30 minutes), limiting the window for URL sharing/leakage.
- RPM uploads are validated to prevent arbitrary file storage.
- B2 storage keys use deterministic, sanitized paths to prevent key manipulation.
- GPG private keys are encrypted at rest in the database with the versioned AES-256-GCM envelope described in GPG Signing. They are only decrypted in-memory during signing operations.
- Downloadable `.repo` files never include API keys, session tokens, or passwords.
- Rate limiting on all endpoints (see Rate Limiting below).
- CSRF protection on all web form submissions and cookie-authenticated mutating API requests (standard Phoenix behavior).

---

## Rate Limiting

All endpoints are rate limited. The rate limiting strategy differs based on authentication status:

- **Authenticated general requests** (API key, session token, or session cookie): 600 requests per minute per user. All requests from the same user share a single bucket regardless of which API key or auth method is used.
- **Unauthenticated general requests**: 120 requests per minute per IP address. Since multiple users may share an IP (corporate networks, VPNs, NAT), these limits are more restrictive.
- **Authentication attempts** (`/api/v1/auth/login`, registration, password reset): 10 requests per minute per IP address and 10 requests per minute per email address.
- **Package uploads**: 60 uploads per hour per user, in addition to the authenticated general request limit.

When a rate limit is exceeded, the server responds with **HTTP 429 Too Many Requests** and includes `Retry-After` (a duration in seconds, per RFC 9110) and `X-RateLimit-Reset` (a Unix epoch timestamp in seconds indicating when the limit resets) headers. For unauthenticated requests, the 429 response body includes a message encouraging the user to create an account and authenticate for higher limits.

### Authenticated access to public repos

Public repositories are accessible without authentication, but authenticated requests receive higher rate limits. The web UI setup instructions for public repos include both an unauthenticated `.repo` configuration and an authenticated variant using any active API key with at least one valid scope via HTTP Basic Auth. Users are encouraged to use authenticated access to get per-user rate limiting rather than sharing an IP-based limit with other users.

---

## Future Considerations

These features are out of scope for the initial version but may be added later:

- **Delta RPMs (drpm)**: Generate and serve delta RPMs to reduce download sizes for updates.
- **Repository snapshots/versioning**: Point-in-time snapshots of repository state.
- **Webhook notifications**: Notify external systems when packages are added/updated.
- **Multi-arch mirroring**: Proxy/cache packages from upstream repositories.
- **Metrics/analytics**: Download counts, popular packages, bandwidth usage dashboards.
- **RPM groups/comps.xml**: Support for package groups and environment definitions.
- **Module metadata (modules.yaml)**: Support for DNF modularity streams.
