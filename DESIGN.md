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
                        │           Dark Zenith            │
                        │          (Phoenix App)           │
                        ├──────────┬───────────┬───────────┤
                        │   Web    │  REST API │   Repo    │
                        │   UI     │ (JSON)    │  Endpoint │
                        │(LiveView)│           │ (repodata)│
                        ├──────────┴───────────┴───────────┤
                        │           Core Domain            │
                        │   (Packages, Repos, Metadata)    │
                        ├─────────────────┬────────────────┤
                        │   PostgreSQL    │  Backblaze B2  │
                        │   (metadata)    │  (RPM files)   │
                        └─────────────────┴────────────────┘
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
| `slug` | string | Normalized lowercase URL-safe identifier (e.g., `stable`, `nightly`); must match `^[a-z0-9][a-z0-9_-]{0,63}$` |
| `name` | string | Display name (max 100 characters after trimming) |
| `description` | text | Optional description (max 4 096 characters after trimming) |
| `gpg_key_fingerprint` | string | Optional 40-character uppercase hex OpenPGP V4 fingerprint of the GPG key used to sign metadata for this repo. Must match `gpg_key_fingerprint` on the owner's user record at the time the field is set. |
| `sign_rpms` | boolean | Whether uploaded RPMs are automatically signed with the repo owner's GPG key (default `false`; requires `gpg_key_fingerprint` to be set) |
| `rpm_signing_state` | string | Server-managed RPM signing readiness state: `disabled`, `signing`, or `enabled` (default `disabled`) |
| `signing_transition_id` | UUID | Active RPM signing transition id while `rpm_signing_state = "signing"`; cleared when the transition completes or `sign_rpms` is disabled (default `null`) |
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
| `name` | string | Package name (e.g., `nginx`); max 256 characters |
| `epoch` | integer | RPM epoch in the unsigned 32-bit range (`0 ≤ epoch ≤ 4 294 967 295`); default `0` when the RPM has no epoch |
| `version` | string | Package version (e.g., `1.24.0`); max 256 characters |
| `release` | string | Package release (e.g., `2.fc39`); max 256 characters |
| `arch` | string | Architecture (`x86_64`, `noarch`, `aarch64`, etc.); max 256 characters |
| `summary` | string | Required one-line description (max 256 characters after trimming) |
| `description` | text | Required full description (max 65 536 characters after trimming) |
| `url` | string | Optional upstream project URL (max 256 characters after trimming) |
| `license` | string | Required license identifier (max 256 characters after trimming) |
| `size_installed` | bigint | Installed size in bytes |
| `size_package` | bigint | RPM file size in bytes |
| `sha256` | string | Lowercase hex-encoded SHA-256 checksum of the RPM file |
| `build_time` | timestamp | Optional RPM build time from the `BUILDTIME` header tag; null when the tag is absent |
| `rpm_sourcerpm` | string | Optional source RPM name (max 256 characters after trimming) |
| `rpm_group` | string | Optional RPM group (max 256 characters after trimming) |
| `storage_path` | string | Path/key where the RPM file is stored |
| `requires` | jsonb | List of dependency requirements (default `[]`) |
| `provides` | jsonb | List of capabilities provided (default `[]`) |
| `conflicts` | jsonb | List of conflicts (default `[]`) |
| `obsoletes` | jsonb | List of obsoletes (default `[]`) |
| `files` | jsonb | List of files contained in the RPM (default `[]`) |
| `changelogs` | jsonb | Changelog entries (default `[]`) |
| `inserted_at` | timestamp | Upload time |
| `updated_at` | timestamp | Last modification time |

**Unique constraint**: `(repository_id, name, epoch, version, release, arch)`

Persisted packages require `name`, `epoch`, `version`, `release`, `arch`, `summary`, `description`, `license`, `size_installed`, `size_package`, and `sha256`. The `url`, `rpm_sourcerpm`, and `rpm_group` fields are nullable when absent or empty after trimming, and `build_time` is nullable when the RPM omits the `BUILDTIME` tag. Dependency, file, and changelog fields are stored as empty arrays when the RPM has no entries for that category.

### Web Upload Previews

Temporary records used only by the web UI's preview-and-confirm RPM upload flow.

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Primary key |
| `repository_id` | UUID | FK to repositories |
| `user_id` | UUID | FK to users — the owner/admin who initiated the preview |
| `token_hash` | string | HMAC-SHA-256 hash of the full preview token string, including the `dzup_` prefix |
| `original_filename` | string | Original uploaded filename for display |
| `tmp_path` | string | Server-local temporary path under `RPM_UPLOAD_TMPDIR` containing the uploaded RPM until confirmation or expiration |
| `size_uploaded` | bigint | Uploaded file size in bytes |
| `metadata` | jsonb | Extracted preview metadata (`name`, `epoch`, `version`, `release`, `arch`, `summary`, `description`, `url`, `license`, `rpm_sourcerpm`, `rpm_group`, `size_installed`, `build_time`, dependencies, files, and changelogs) using the same dependency, file, and changelog shapes as package detail responses |
| `expires_at` | timestamp | Expiration time (15 minutes after creation) |
| `inserted_at` | timestamp | Creation time |

**Unique constraint**: `(token_hash)`

Preview tokens are generated from 32 bytes of cryptographically secure random data, encoded as unpadded base64url, and returned to the web UI as `dzup_<secret>`. The database stores only `HMAC-SHA-256(SECRET_KEY_BASE, full_token_string)` encoded as lowercase hex. Expired preview rows and their temporary files are deleted by a periodic Oban cleanup job that runs every 15 minutes. Repository deletion removes pending preview rows for that repository and enqueues cleanup for their temporary files.

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

Repo owners and admins can grant other users read access to private repositories. When the invited email address, after normalization, matches an already registered user, a collaborator record is created immediately. When the normalized email does not match a registered user, a pending invitation is created instead and converts to a collaborator record when a matching user account is created. The invited user receives an email notification: registered users get a direct link to the repository, and unregistered invitees get a registration link that converts the pending invitation on signup. When `REGISTRATION_ENABLED = false`, pending invitations to unregistered addresses are still created so they convert automatically once an admin provisions the account, but no email is sent to the unregistered invitee. The inviting user is shown a UI notice indicating that an admin must create the account before the invitation can be accepted.

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
| `inserted_at` | timestamp | Invitation time |

**Unique constraint**: `(repository_id, email)`

When a user account is created with a normalized email that has pending invitations, whether by public registration or admin provisioning, those invitations are automatically converted to collaborator records and the invitation rows are deleted. User and collaborator-invitation email addresses use the same validation rules as `phx.gen.auth`: values are trimmed, lowercased, capped at 160 characters after trimming, and rejected with `422 validation_failed` when they fail the email format rules.

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

When a user's password is changed or reset, all of that user's session tokens are deleted in the same operation (matching `phx.gen.auth`, which likewise invalidates the user's web sessions). API keys are unaffected by password changes.

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
| `source_revision` | integer | Repository metadata revision used to generate this cache entry |
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
| `gpg_key_private` | binary | Optional GPG private key, encrypted at rest using the versioned GPG private key encryption envelope |
| `gpg_key_public` | text | ASCII-armored GPG public key (served at `/repos/:slug/RPM-GPG-KEY`) |
| `gpg_key_fingerprint` | string | 40-character uppercase hex OpenPGP V4 fingerprint of the stored GPG key (for display/identification) |
| `previous_gpg_key_public` | text | Optional ASCII-armored previous public GPG key, retained while a GPG key replacement is mid-transition so clients can still verify signatures made with the previous key; cleared after affected metadata caches have reached the current revision and every per-package re-sign job for the user's repositories has completed successfully |
| `gpg_key_transition_id` | UUID | Active GPG key replacement transition id while `previous_gpg_key_public` is set; cleared in the same transaction that clears `previous_gpg_key_public` (default `null`) |
| `confirmed_at` | timestamp | Email confirmation time |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

**Unique constraint**: `(email)`

### Authorization

- **Owner**: A user owns the repositories they create. Only the owner can modify (update, delete, upload to) their repositories. Owners can add collaborators to their private repos.
- **Collaborator**: A user granted read access to a private repository by its owner or an admin. Collaborators can browse, view packages, and download RPMs from that repo. They cannot modify the repo or upload packages.
- **Admin**: Users with `is_admin = true` can perform any action on any repository, manage users, and access admin-only features.
- **Public**: Unauthenticated users can browse public repos, view packages, and download RPMs. No authentication is required for read-only access to public repositories.
- **Private repos**: When `is_public = false`, all access (including repodata and RPM downloads) requires authentication. Only the owner, collaborators, and admins can access private repos.

### User Lifecycle

- User accounts are created via web registration (when `REGISTRATION_ENABLED = true`) or by an admin in the admin web UI. There is no REST API for user creation or deletion; admin user management is web-only. Web-registered users must complete the `phx.gen.auth` email-confirmation flow before they can log in. Both the web login path (customized on top of `phx.gen.auth`) and the API login endpoint (`POST /api/v1/auth/login`) reject any user whose `confirmed_at` is null with the standard invalid-credentials response. Admin-created users are auto-confirmed: `confirmed_at` is set at creation time so the new account can log in immediately, and no confirmation email is sent (mirroring the bootstrap admin behavior).
- The `is_admin` flag is managed only in the admin web UI: an admin can grant or revoke it on any user other than themselves. Because admins can never change their own flag, the last remaining admin cannot demote itself. There is no REST API for admin-flag management.
- An admin can delete a user account from the admin UI, but the deletion is rejected with `409 conflict_user_owns_repositories` if that user still owns any repositories. The admin must first delete those repositories.
- Users cannot delete their own accounts; account deletion is admin-only.
- When a user is deleted, the database cascades remove their API keys, session tokens, GPG key, web upload preview rows they initiated, and pending collaborator invitations they sent, removes any collaborator membership rows where they are the collaborator, and deletes any pending collaborator invitations addressed to the deleted user's normalized email so a later re-registration with the same email does not silently re-attach to old invites. Temporary files for deleted web upload previews are cleaned up by the preview cleanup job. Repositories owned by other users on which the deleted user was a collaborator are otherwise unaffected.

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

- **`repomd.xml`**: Root metadata index. Lists the location, checksum, size, and timestamp of each metadata file (`primary`, `filelists`, `other`). This is the entry point that `dnf`/`yum` fetches first.

- **`primary.xml.gz`**: Contains package names, versions, architectures, summaries, sizes, checksums, and dependency information (requires, provides, conflicts, obsoletes). This is the main metadata file used for dependency resolution. Each package entry also includes the standard "primary files" subset of that package's file list — paths under `/etc/`, paths containing `bin/`, and `/usr/lib/sendmail` — matching `createrepo_c` behavior so file-path dependencies on common paths (e.g., `/bin/sh`) resolve without downloading filelists. Each package's `<location>` element uses the relative path `packages/:id/:name-:version-:release.:arch.rpm` (the standard RPM filename, with no epoch component), so RPM clients resolve downloads against the repository base URL. The route is keyed by package UUID, so the filename segment is cosmetic and does not need to match the B2 storage key, which includes the epoch. Each package's `<time>` element sets `file` to the package row's `inserted_at` and `build` to `build_time`, falling back to `inserted_at` when `build_time` is null, both as Unix epoch timestamps in seconds.

- **`filelists.xml.gz`**: Lists all files contained in each package. Used when a user runs commands like `dnf provides /usr/bin/something`.

- **`other.xml.gz`**: Contains changelog entries for each package. Only the 10 most recent changelog entries per package (by changelog timestamp) are emitted, matching the `createrepo_c` default, to keep the file small for clients; the full changelog remains on the package row and is served by the web UI and API.

Generated XML is UTF-8. `primary.xml` uses the `http://linux.duke.edu/metadata/common` default namespace and the `http://linux.duke.edu/metadata/rpm` `rpm` namespace. `filelists.xml` uses the `http://linux.duke.edu/metadata/filelists` namespace. `other.xml` uses the `http://linux.duke.edu/metadata/other` namespace. `repomd.xml` uses the `http://linux.duke.edu/metadata/repo` namespace.

`repomd.xml` includes a `<revision>` element set to the `metadata_revision` value the generation ran against (the same value stored as the cache row's `source_revision`) and contains one `<data>` entry each for `primary`, `filelists`, and `other`. Each entry uses a fixed `location href` of `repodata/primary.xml.gz`, `repodata/filelists.xml.gz`, or `repodata/other.xml.gz`; `checksum` and `open-checksum` values are lowercase hex SHA-256 digests of the compressed and uncompressed metadata bytes respectively; `size` and `open-size` are byte counts; and `timestamp` is a Unix epoch timestamp in seconds. Metadata generation captures one UTC generation timestamp at job start, truncated to whole seconds, and uses that value for all three `repomd.xml` data entries. Gzip output is deterministic for identical XML input: `mtime` is `0`, no original filename is stored in the gzip header, and the same compression level is used for every generation.

### Metadata Generation & Storage

All repodata XML is generated by the app and served directly from the app (not from B2). The metadata is stored in PostgreSQL as cached blobs so it can be served without regeneration on every request.

Metadata is regenerated as a background job (via Oban) when packages are added to or removed from a repository, or when repository settings that affect generated metadata change. Repository creation is the exception: initial empty metadata is generated synchronously during creation so a new empty repo has a current cache before it is exposed. The regeneration process:

1. Package upload/deletion increments the repository's `metadata_revision` inside the same database transaction that changes package membership.
2. The transaction enqueues a unique Oban regeneration job for the affected repository. On deletion, a separate idempotent Oban job removes the RPM file from B2 after the package row is removed. B2 cleanup jobs throughout this document are idempotent in the same sense: they treat B2 `404 not_found` responses as success and only retry on other object-storage errors, so a re-run after a previously successful deletion is a no-op.
3. The regeneration job reads the current repository `metadata_revision`, then queries all packages in the repository from PostgreSQL in deterministic order by `name`, `epoch`, `version`, `release`, `arch`, and `id`.
4. XML metadata files are generated in-memory and compressed with gzip.
5. A new `repomd.xml` is generated with checksums pointing to the current metadata files.
6. The generated metadata blobs, `repomd.xml`, optional `repomd.xml.asc` signature, and `source_revision` are stored in PostgreSQL keyed by repository.
7. Before completing, the job reloads the repository. If `metadata_revision` is greater than the cached `source_revision`, the job enqueues another unique regeneration job so the final cache reflects the latest package set.
8. The repo endpoint serves metadata directly from the cache once the cache `source_revision` matches the repository's current `metadata_revision`.

Repository creation writes the repository row, generates empty `primary.xml.gz`, `filelists.xml.gz`, `other.xml.gz`, `repomd.xml`, and optional `repomd.xml.asc`, and writes the metadata-cache row with `source_revision = 0` in the same database transaction. Newly created empty repos therefore immediately serve valid metadata from the cache. If a repository is created with `gpg_key_fingerprint` set and synchronous `repomd.xml` signing fails for an infrastructure reason, the transaction is rolled back and the caller receives `503 signing_unavailable`; validation failures still return `422 validation_failed`. Repository setting changes that affect generated metadata, such as enabling/disabling metadata signing or changing `gpg_key_fingerprint`, use the same `metadata_revision` increment and regeneration enqueue path.

Metadata endpoints return `503 Service Unavailable` with plain text body `metadata_not_ready` and `Retry-After: 5` when the cache row is missing or its `source_revision` is older than the repository's current `metadata_revision`. The endpoint does not generate metadata inline and does not serve stale metadata for an out-of-date revision.

Multiple rapid changes are debounced with an Oban unique job keyed by `repository_id` while the job is available or scheduled. Running jobs are allowed to be followed by a newly queued job, and the `metadata_revision`/`source_revision` check guarantees another job runs until the cache reaches the latest revision. Metadata regeneration and B2 cleanup jobs retry up to 20 attempts with exponential backoff; exhausted jobs remain visible in Oban for admin intervention.

Because metadata files are served at fixed `repodata/` paths from a single cache row, a client that fetches `repomd.xml` and the referenced blobs across a regeneration boundary can observe checksum mismatches for that fetch cycle. This transient race is accepted for the initial version: the affected metadata fetch fails, and a retry refetches `repomd.xml` and succeeds against the new consistent generation. Serving checksum-named metadata files with retained previous generations would eliminate the race and is listed under Future Considerations.

### RPM File Downloads

When a client (e.g., `dnf`) requests an RPM file at `/repos/:slug/packages/:id/:filename.rpm`:

1. Dark Zenith validates access to the repository identified by `:slug`, then validates that `:filename` matches `^[A-Za-z0-9._+~-]+\.rpm$`; non-matching requests are rejected with `400 invalid_request`. It then looks up the package record by `:id` scoped to that repository in PostgreSQL to find the B2 storage key. The `:filename` segment is otherwise cosmetic (ignored for routing) but provides a human-readable filename for download clients.
2. Generates a **signed Backblaze B2 URL** using `B2_SIGNED_URL_TTL` (default **30-minute expiration**). If B2 signed URL generation fails for an infrastructure reason, the endpoint returns `503 storage_unavailable`.
3. Responds with **HTTP 302 redirect** to the signed URL.
4. The client downloads the RPM directly from B2.

This keeps RPM file bandwidth off the app server entirely.

Repository-serving endpoints intended for RPM clients (`/repos/:slug/repodata/...`, `/repos/:slug/packages/:id/:filename.rpm`, `/repos/:slug/RPM-GPG-KEY`, and `/repos/:slug/dark-zenith.repo`) use plain-text error responses. On these endpoints, 4xx and 5xx errors such as `400 invalid_request`, `401 unauthenticated`, `403 forbidden`, `404 not_found`, `429 rate_limited`, `503 storage_unavailable`, `503 signing_unavailable`, and `503 metadata_not_ready` return a `text/plain; charset=utf-8` body whose contents are the error code string and nothing else. Web UI routes under `/repos/:slug` keep their normal HTML responses, and `/api/v1/...` endpoints use the JSON `{"error": {...}}` envelope. Successful responses on these repository-serving endpoints use the following `Content-Type` values: `repomd.xml` is served as `application/xml`; `primary.xml.gz`, `filelists.xml.gz`, and `other.xml.gz` as `application/gzip`; and `repomd.xml.asc`, `RPM-GPG-KEY`, and `dark-zenith.repo` as `text/plain; charset=utf-8`.

### Private Repository Authentication

Private repositories (`is_public = false`) require authentication on all endpoints, including repodata and RPM downloads. RPM clients (`dnf`/`yum`) authenticate via **HTTP Basic Auth**:

- **Username**: `token` (literal string)
- **Password**: a valid API key with the `repo:read` scope

Dark Zenith checks the API key, verifies it has the `repo:read` scope, resolves the owning user, and verifies they have access to the repository (as owner, collaborator, or admin) before serving metadata or issuing a signed B2 URL.

Browser requests to these repository-serving endpoints — for example, the direct download link on the package version detail page — may instead authenticate with the standard web session cookie; the same repository access checks apply.

Anonymous requests (no credentials at all) to these repository-serving endpoints respond `401 unauthenticated` with a `WWW-Authenticate: Basic realm="Dark Zenith"` header whenever the target slug is private or does not exist. Unknown and private slugs are treated identically so the challenge does not leak repository existence, and RPM client HTTP stacks that wait for a challenge before sending Basic credentials (librepo/libcurl configured via `username=`/`password=` repo directives) still work. Requests that do present credentials follow the private-repository masking rule in API Contract Details: invalid or expired credentials, and valid principals without access, receive `404 not_found`.

Public repositories may also receive the same Basic Auth credentials as optional authentication for higher rate limits. For public repository reads, the API key only needs to be valid, non-expired, and have at least one valid scope; `repo:read` and repository access checks are not required.

Example `.repo` configuration for a private repo with metadata signing and `rpm_signing_state = "enabled"`:

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

For repositories without metadata signing, `repo_gpgcheck` is `0`. For repositories whose `rpm_signing_state` is not `enabled`, including repositories still in the `signing` transition, `gpgcheck` is `0`. The `gpgkey` line is included whenever `gpg_key_fingerprint` is configured and is omitted only when no repository key is configured.

### GPG Signing (Optional)

Each user can upload a GPG key pair (public + private) to their account. The private key is encrypted at rest in the database using the GPG private key encryption envelope described below. Private keys must be dedicated repository-signing keys that can sign non-interactively; passphrase-protected private keys are rejected at upload with `422 validation_failed`.

#### GPG private key encryption

The `gpg_key_private` field stores a versioned binary encryption envelope rather than raw key material. Two envelope versions are defined:

- **`v1`**: AES-256-GCM with a 32-byte key derived from `SECRET_KEY_BASE` by HKDF-SHA-256 using a random 16-byte salt and the context string `dark_zenith:gpg_private_key:v1`. Binary format: 1-byte version (`0x01`), 16-byte salt, 12-byte nonce, 16-byte authentication tag, and ciphertext bytes for the ASCII-armored private key. AEAD additional authenticated data is `dark_zenith:gpg_private_key:v1:<user_id>`, binding the encrypted value to the owning user.
- **`v2`** (current): identical binary layout and AEAD construction to `v1`, with version byte `0x02`, HKDF context string `dark_zenith:gpg_private_key:v2`, and AAD `dark_zenith:gpg_private_key:v2:<user_id>`. New writes always use `v2`; the dedicated version byte and distinct HKDF/AAD contexts give a clean boundary for future format changes without colliding with `v1` rows.

Reads dispatch by the stored version so older rows continue to decrypt while the background re-encryption job migrates them. Rows whose envelope version is unsupported by the running release fail closed and require admin intervention (typically uploading a fresh GPG key pair to overwrite the unreadable row).

**`SECRET_KEY_BASE` rotation procedure.** Because both `v1` and `v2` derive their AEAD key from `SECRET_KEY_BASE`, rotating that value would otherwise strand every existing `gpg_key_private` row. To rotate safely, the operator sets the new value on `SECRET_KEY_BASE` and provides the prior value on `PREVIOUS_SECRET_KEY_BASE`. Both are read at boot. Encryption always derives its key from `SECRET_KEY_BASE`. Decryption first attempts the current envelope using `SECRET_KEY_BASE`; on AEAD authentication failure it retries with `PREVIOUS_SECRET_KEY_BASE` if configured. When `PREVIOUS_SECRET_KEY_BASE` is set at boot, the application enqueues a unique Oban job (`DarkZenith.Jobs.GpgKeyReencryption`) that scans every user row with `gpg_key_private` set, decrypts the row using whichever base succeeds, re-encrypts it under `SECRET_KEY_BASE` as a `v2` envelope, and writes the new ciphertext in a single transaction. The job retries up to 20 attempts per row with exponential backoff; exhausted rows remain visible in Oban for admin intervention. When no rows remain that decrypt only with the previous base, the job logs completion and the operator can remove `PREVIOUS_SECRET_KEY_BASE` from the deployment. Rotating `SECRET_KEY_BASE` without configuring `PREVIOUS_SECRET_KEY_BASE` immediately strands all existing `gpg_key_private` rows and they fail closed.

When creating or editing a repository, the owner can enable two levels of signing:

#### Repository metadata signing (`gpg_key_fingerprint` set)

- `repomd.xml` is signed during metadata regeneration using the owner's GPG key.
- `repomd.xml.asc` is served alongside `repomd.xml`.
- The owner's public key is served at the repo level.

```
GET /repos/:slug/repodata/repomd.xml.asc
GET /repos/:slug/RPM-GPG-KEY
```

Both endpoints return `404 not_found` when the repository has no `gpg_key_fingerprint` configured. While the repository owner is mid-transition through a GPG key replacement (their `previous_gpg_key_public` is set), `/repos/:slug/RPM-GPG-KEY` returns the previous and current public keys concatenated as a single ASCII-armored keyring so clients can verify both old- and new-key signatures during the transition (see "Key replacement and revocation" below).

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

`sign_rpms` is the desired behavior for future uploads. `rpm_signing_state` controls whether generated setup snippets and `.repo` files enable RPM signature verification:

- `disabled`: `sign_rpms = false`; generated `.repo` files use `gpgcheck=0`.
- `signing`: `sign_rpms = true`, but one or more existing packages still need a successful re-sign job before every package can be verified with a key served by `/repos/:slug/RPM-GPG-KEY`; generated `.repo` files use `gpgcheck=0`.
- `enabled`: `sign_rpms = true` and every current package is signed by a key served by `/repos/:slug/RPM-GPG-KEY`; generated `.repo` files use `gpgcheck=1`.

When `sign_rpms` is enabled on an empty repository, `rpm_signing_state` becomes `enabled` immediately. When `sign_rpms` is enabled on a repository that already has packages, the owner must explicitly confirm re-signing existing packages retroactively using the same per-package job flow described under "Key replacement and revocation". The REST API exposes this confirmation via the `existing_package_strategy` field on `PATCH /api/v1/repos/:slug` with value `"resign"`, and the web UI prompts the owner to confirm. The transaction generates a fresh `transition_id` UUID, sets `sign_rpms = true`, sets `rpm_signing_state = "signing"`, writes the new `transition_id` to the repository's `signing_transition_id` column, and enqueues one re-sign job per existing package with that `transition_id` in the job's Oban args. New uploads are signed before insertion while the repository is in `signing`.

A periodic sweep, running every 60 seconds, sets `rpm_signing_state = "enabled"` and clears `signing_transition_id` only after every re-sign job tagged with the repository's current `signing_transition_id` has completed successfully, no such job remains in a non-terminal Oban state (available, scheduled, executing, or retryable), and the metadata cache has reached the repository's current `metadata_revision`. Re-sign jobs whose `transition_id` argument no longer matches the repository's `signing_transition_id` are ignored by the sweep — that is how exhausted jobs from a prior, since-superseded transition stop blocking later transitions. If any job tagged with the current `signing_transition_id` exhausts its retry budget, `rpm_signing_state` remains `signing` and generated client configuration keeps `gpgcheck=0` until an admin resolves and replays the failed jobs or deletes the affected packages. Signing only future uploads while leaving existing packages unsigned is not supported. Disabling `sign_rpms` sets `rpm_signing_state = "disabled"`, clears `signing_transition_id`, and does not strip signatures from already-signed packages. Pending transition re-sign jobs are canceled when possible; running jobs must re-check `sign_rpms`, `rpm_signing_state`, the repository's current `signing_transition_id`, and the target fingerprint before updating a package row, and must no-op if the job's `transition_id` argument no longer matches the repository's `signing_transition_id`.

#### Key replacement and revocation

Users can replace their GPG key by uploading a new pair (public + private). Replacement is allowed even when repositories have signing enabled, but a replacement is rejected while `previous_gpg_key_public` is already set or while any repository owned by the user has `rpm_signing_state = "signing"`. In that case, `PUT /api/v1/gpg_key` and `POST /api/v1/gpg_key/revocation` with `strategy=replace_key` return `409 conflict_gpg_key_transition_in_progress`; the current transition must complete, or an admin must resolve it, before a replacement can start. Because the cached metadata signature and existing per-package signatures may still chain to the previous key while re-sign jobs run, the previous public key is retained during the transition so clients keep verifying successfully. When replacement happens:

1. In a single transaction, the user's existing `gpg_key_public` is copied to `previous_gpg_key_public`, a fresh `transition_id` UUID is generated and written to the user's `gpg_key_transition_id`, the user's `gpg_key_private`, `gpg_key_public`, and `gpg_key_fingerprint` are updated to the new pair, every repository owned by the user that has `gpg_key_fingerprint` set has its `gpg_key_fingerprint` updated to the new fingerprint and its `metadata_revision` incremented, and a metadata regeneration job is enqueued for each so `repomd.xml.asc` is re-signed with the new key.
2. While `previous_gpg_key_public` is set, every `GET /repos/:slug/RPM-GPG-KEY` request for a repository owned by that user with `gpg_key_fingerprint` configured returns the previous and current public keys concatenated as a single ASCII-armored keyring, so clients can verify signatures made with either key during the transition. Repositories without `gpg_key_fingerprint` configured continue to return `404 not_found`.
3. For each affected repository where `sign_rpms = true`, a re-sign job is enqueued per existing package and tagged with the user's `gpg_key_transition_id` in its Oban args. Each re-sign job decrypts the new private key, downloads the existing RPM from B2, signs unsigned RPMs with `rpmsign --addsign`, re-signs already signed RPMs with `rpmsign --resign`, verifies the result with `rpm --checksig`, recomputes the SHA-256 and final RPM file size, and uploads the re-signed RPM to `repos/:slug/packages/:resign_id/:name-:epoch-:version-:release.:arch.rpm`, where `:resign_id` is a newly generated UUID for that re-sign attempt. The job then updates the package row's `sha256`, `size_package`, and `storage_path` in a single transaction. The same transaction increments the repository's `metadata_revision` and enqueues metadata regeneration so repodata reflects the new package checksum and size. The previous B2 object is deleted asynchronously by an idempotent cleanup job. If the upload succeeds but the package-row update fails, Dark Zenith immediately attempts to delete the newly uploaded object; if that cleanup fails, it enqueues an idempotent B2 cleanup job and returns the original database error to Oban for retry. Re-sign jobs retry up to 20 attempts with exponential backoff; exhausted jobs remain visible in Oban for admin intervention. Running re-sign jobs must re-check the user's current `gpg_key_transition_id` before updating a package row and must no-op if the job's `transition_id` argument no longer matches. Key replacement does not move an `enabled` repository back to `signing`, because `/repos/:slug/RPM-GPG-KEY` serves both old and new keys during the transition.
4. A periodic background sweep, running every 60 seconds, checks whether affected repository metadata caches have reached the current `metadata_revision` and whether every re-sign job tagged with the user's current `gpg_key_transition_id` has reached a terminal state. When every affected metadata cache is current, every such re-sign job has completed successfully, and none remain in a non-terminal Oban state (available, scheduled, executing, or retryable), the sweep clears `previous_gpg_key_public` and `gpg_key_transition_id` on the user in a single transaction. Re-sign jobs tagged with a different `transition_id` (for example, jobs from a prior transition that has since been resolved) are ignored by the sweep. If any re-sign job tagged with the current `gpg_key_transition_id` has exhausted its retry budget, `previous_gpg_key_public` is left in place so old-key signatures remain verifiable, and the admin must resolve and replay the failed jobs (or delete the affected packages) before the previous key is cleared.

Users can also explicitly revoke (remove) their GPG key without simultaneously replacing it. If the user has no repositories with `gpg_key_fingerprint` set or `sign_rpms = true`, `DELETE /api/v1/gpg_key` and the equivalent web UI action remove the key immediately.

When the user owns any affected repositories, `DELETE /api/v1/gpg_key` returns `409 conflict_gpg_key_in_use` with counts of metadata-signed and RPM-signed repositories. The web UI prompts the user to choose one of the same explicit strategies exposed by `POST /api/v1/gpg_key/revocation`:

- **Clear metadata signing** (`strategy: "clear_metadata_signing"`): Allowed only when none of the user's repositories have `sign_rpms = true`. For every affected repository, `gpg_key_fingerprint` is cleared and metadata regeneration is enqueued. Package rows and B2 objects are left intact. The user's GPG key is then removed.
- **Delete signed packages** (`strategy: "delete_signed_packages"`): For every affected repository where `sign_rpms = true`, all package rows are deleted (which enqueues the standard B2 cleanup jobs), pending re-sign jobs are canceled when possible, `gpg_key_fingerprint` is cleared, `sign_rpms` is set to `false`, `rpm_signing_state` is set to `disabled`, and metadata regeneration is enqueued. Running re-sign jobs no-op when they observe that the package row is gone or the signing transition is no longer current. For repositories that only have metadata signing enabled, `gpg_key_fingerprint` is cleared and metadata regeneration is enqueued without deleting packages. The user's GPG key is then removed.
- **Re-sign with a new key** (`strategy: "replace_key"`): The user uploads a new GPG key pair as part of the same multipart request, and the operation is processed as a replacement (see above) instead of a revocation.

---

## Package Upload & Processing

When an RPM file is uploaded (via web UI or API) by a repository owner or admin:

Uploads are limited to `MAX_RPM_UPLOAD_BYTES` bytes (default 512 MiB). Requests that exceed the limit are rejected with `413 payload_too_large` before RPM parsing or B2 upload. Malformed multipart bodies, missing `rpm` file fields, and requests with more than one `rpm` file field are rejected with `400 invalid_request`. Files that are within the size limit but are not valid RPMs, have unreadable RPM headers, are missing required metadata, or contain metadata values that fail validation are rejected with `422 validation_failed`.

Upload processing uses a per-upload temporary working directory under `RPM_UPLOAD_TMPDIR`. Before processing begins, Dark Zenith verifies that the temporary filesystem has at least `3 * uploaded_file_size + 67108864` free bytes, allowing room for the original upload, a working copy, a signed output file, and parser/signing overhead. If the check fails, the request is rejected with `503 upload_temp_space_unavailable` and no B2 or database changes are made. The web upload preview request runs the same free-space check before parsing, and the confirmation step re-runs it before signing begins, because free space may have changed during the preview window; either failure is rejected with `503 upload_temp_space_unavailable`. Temporary files are removed after success or failure.

1. **Validate**: Confirm the file is a valid RPM by reading the RPM lead and header.
2. **Extract metadata**: Parse the RPM headers to extract name, version, release, epoch, arch, dependencies, file lists, changelogs, summary, description, license, etc. This is done in Elixir by reading the RPM binary format directly (RPM header structure). Required RPM header metadata is `name`, `version`, `release`, `arch`, `summary`, `description`, `license`, and `size_installed`; `epoch` defaults to `0` when absent. Optional `url`, `rpm_sourcerpm`, and `rpm_group` values are stored as `NULL` when absent or empty after trimming; `build_time` is read from the `BUILDTIME` header tag (an unsigned 32-bit Unix timestamp) and stored as `NULL` when absent; and dependency, file, and changelog collections default to empty arrays. Verify that `epoch` is an integer in the unsigned 32-bit range (`0 ≤ epoch ≤ 4 294 967 295`), that `name`, `version`, `release`, and `arch` each match `^[A-Za-z0-9._+~-]+$` and are at most 256 characters long, and that other extracted strings respect the maximum lengths defined in the Packages data-model table (`summary` ≤ 256, `description` ≤ 65 536, `url` ≤ 256, `license` ≤ 256, `rpm_sourcerpm` ≤ 256, `rpm_group` ≤ 256, all measured after trimming). Any value that fails these checks is rejected with `422 validation_failed`. This keeps B2 storage keys constrained to a safe, predictable character set and prevents oversized fields from ballooning generated repodata.
3. **Sign** (if `sign_rpms` enabled): Sign the RPM using the owner's GPG key and `rpmsign` (see GPG Signing section).
4. **Checksum and final size**: Compute SHA-256 and `size_package` from the final RPM file after any signing step has completed.
5. **Duplicate check**: If a package with the same `(repository_id, name, epoch, version, release, arch)` already exists, reject the upload with `409 conflict_duplicate_package`. The database unique constraint is still the source of truth for concurrent uploads.
6. **Generate package UUID**: Allocate the package row's UUID in application code so it can be used in the B2 storage key before the row is inserted.
7. **Upload to B2**: Store the RPM file in Backblaze B2 at the per-upload key `repos/:slug/packages/:id/:name-:epoch-:version-:release.:arch.rpm`, where `:id` is the UUID generated in step 6. Including the per-upload UUID guarantees that two concurrent uploads of the same NEVRA never share a B2 path, so a failed-insert cleanup cannot delete an object referenced by another package row.
8. **Record**: Insert the package record into PostgreSQL using the UUID from step 6 and the B2 storage key from step 7, increment `metadata_revision`, and enqueue the repository metadata regeneration job in the same transaction.

If signing is required but `rpm`, `rpmsign`, or `gpg` is unavailable or fails for an infrastructure reason, no package row is inserted and the caller receives `503 signing_unavailable`. If B2 upload fails, no package row is inserted and the caller receives `503 storage_unavailable`. If the B2 upload succeeds but the database insert fails, Dark Zenith immediately attempts to delete the just-uploaded object — safe because the object's key includes the unreferenced UUID. If that cleanup fails, it enqueues an idempotent B2 cleanup job and returns the original database error mapped to its standard API error response (for example, a concurrent unique-constraint failure returns `409 conflict_duplicate_package`). If the package insert succeeds but metadata regeneration fails, the upload remains successful; the regeneration job retries until the cache reaches the repository's latest `metadata_revision`.

Package deletion removes the package row, increments `metadata_revision`, and enqueues metadata regeneration in one database transaction. B2 object deletion happens in a separate idempotent Oban job with retries. If B2 deletion fails, the package no longer appears in metadata or API responses, and package-id download URLs no longer resolve, but the orphaned object is retried for cleanup. Previously issued signed B2 URLs may remain usable until they expire or until the B2 object is deleted, whichever happens first.

Repository deletion is a hard delete. When an authorized owner or admin deletes a repository, Dark Zenith reads the current package `storage_path` values and pending web upload preview `tmp_path` values, deletes the repository row and dependent packages, collaborators, invitations, the metadata-cache row, and web upload preview rows in one database transaction, and returns `204 No Content` after that transaction commits. B2 object deletion happens after commit through idempotent cleanup jobs for the collected storage paths; temporary preview-file deletion happens through the preview cleanup job. If one or more B2 cleanup jobs fail, the repository remains deleted from PostgreSQL and inaccessible through the web, API, metadata, and package download endpoints while cleanup continues through Oban retries. Previously issued signed B2 URLs for the repository's RPM objects may remain usable until they expire or until the B2 objects are deleted, whichever happens first.

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
- **Package list**: Searchable, sortable table of packages in this repo (name, EVR, arch, summary). EVR displays as `epoch:version-release` when `epoch` is nonzero and as `version-release` otherwise.
- Repository owners and admins see an "Upload RPM" action.
- **Owner/admin only**: "Manage Collaborators" section to add/remove users who can access a private repo.
  - For public repositories, existing collaborators and pending invitations are still listed and removable (they are dormant while the repository is public), but adding new ones is disabled.
  - Adding a collaborator by the repository owner's email is rejected with `422 validation_failed`.
  - Adding a collaborator whose normalized email already has a collaborator row or pending invitation is idempotent; the UI shows the existing collaborator or invitation instead of creating a duplicate.

### Package Detail (`GET /repos/:slug/packages/:name`)

- Lists all versions/architectures available for this package name.
- For each package build: EVR, arch, summary, size, upload date. EVR uses the same `epoch:version-release` display rule as repository package lists.
- **Install instructions**: `dnf install <package>` command (assumes the repo is already configured).
- Links to individual package version pages, keyed by package UUID.

### Package Version Detail (`GET /repos/:slug/package-versions/:id`)

- Full package metadata: name, epoch, version, release, arch, summary, full description.
- Dependency information (requires, provides, conflicts, obsoletes).
- File list and changelog.
- Direct download link to the app's package download endpoint, which redirects to a signed B2 URL.

### Upload RPM (owner/admin, `GET /repos/:slug/upload`)

- Drag-and-drop or file picker to upload an RPM to the selected repository.
- **Preview**: The uploaded RPM is size-checked, validated, and parsed using the same validation and metadata extraction rules as the final upload pipeline. No package row is created and no B2 object is written during preview. On success, Dark Zenith stores the uploaded file in a temporary path under `RPM_UPLOAD_TMPDIR`, creates a Web Upload Preview record with a 15-minute expiration, and shows the extracted metadata for confirmation.
- **Confirm**: The confirmation request sends the preview token back to the server. Dark Zenith reloads the preview row, verifies that it belongs to the same repository and authenticated user, verifies that it has not expired, re-runs RPM validation and metadata extraction from the temporary file, and rejects the confirmation with `422 validation_failed` if the NEVRA or extracted metadata no longer matches the stored preview. The confirmation then runs the normal upload pipeline starting with signing, checksum/final-size calculation, duplicate check, B2 upload, and package insertion. Confirmation consumes the preview token; the preview row and temporary file are deleted after success or failure.
- **Expiration**: Expired previews cannot be confirmed. A preview token that is unknown or already consumed is treated the same as an expired one. In every such case the UI asks the user to upload the RPM again.
- **Web only**: The two-step confirmation flow (preview then confirm) is a web UI feature. The REST API processes uploads immediately in a single request — see the API section.

### GPG Key Management (authenticated, account settings)

- Upload a GPG key pair (public + private) to the user's account. Uploading a new pair when one already exists is treated as a replacement and triggers automatic re-signing of metadata and (if `sign_rpms` is enabled) existing packages — see "Key replacement and revocation" under GPG Signing.
- View the fingerprint and public key of the currently uploaded key.
- Remove the existing GPG key. If any owned repositories have `gpg_key_fingerprint` set or `sign_rpms = true`, the UI prompts the user to clear metadata signing, delete RPM-signed packages, or upload a replacement key as part of the same flow.
- Passphrase-protected private keys are rejected; users should upload a dedicated repository-signing key.

### Authentication Pages

- Login / logout.
- Account registration (when enabled).
- Password reset and email confirmation (including resending the confirmation email), via the standard `phx.gen.auth` flows.
- API key management for the authenticated user.

### Admin (admin-only)

- **User management**: List users; create users (created accounts are auto-confirmed and no confirmation email is sent, mirroring the bootstrap admin); grant or revoke `is_admin` on other users (never their own — see User Lifecycle); delete users, which is rejected while the target user still owns repositories (the web equivalent of the `409 conflict_user_owns_repositories` rule).
- **Background jobs**: An admin-only view of Oban jobs (for example, a mounted Oban dashboard) for inspecting, retrying, or discarding the failed and exhausted jobs that the admin-intervention flows in this document rely on.

---

## REST API

The REST API provides programmatic access to repository operations. Authentication is via `Authorization: Bearer <token>` header, where the token is either an API key or a short-lived session token obtained from the login endpoint. API endpoints also accept session cookie authentication (as used by the web UI), which allows the web frontend to call API endpoints directly and enables users to create their first API key without already having one. When both an `Authorization: Bearer` header and a session cookie are present on the same request, the `Authorization` header takes precedence; the session cookie is ignored for that request.

Read-only endpoints for public repos are unauthenticated.

Repository-scoped mutating API endpoints require either session token/cookie authentication or an API key with the matching scope. Repository-scoped mutations also require the authenticated user to be the repository owner or an admin.

Account-management API endpoints for API keys and GPG keys require session token or session cookie authentication. API key credentials are not accepted for `/api/v1/api_keys`, `/api/v1/gpg_key`, or `/api/v1/gpg_key/revocation`; requests authenticated only by API key return `403 forbidden`.

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
GET    /api/v1/repos/:slug/collaborators              # List collaborators and pending invitations (owner/admin only; API keys need `repo:read`)
POST   /api/v1/repos/:slug/collaborators              # Add a collaborator by email (owner/admin only; API keys need `repo:update`; idempotent for existing collaborators/invitations; creates pending invitation if user not registered)
DELETE /api/v1/repos/:slug/collaborators/:user_id      # Remove a collaborator (owner/admin only; API keys need `repo:update`)
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

JSON endpoints with request bodies require `Content-Type: application/json`. File and key upload requests use `multipart/form-data`. All timestamps are ISO-8601 UTC strings and all IDs are UUID strings. User-provided metadata strings are trimmed before validation, but secrets and key material (passwords, bearer/API token values, and GPG armored key fields) are not modified except by their documented parsers. For optional string fields, a value that is empty after trimming is coerced to `NULL` at storage time and surfaced as `null` in responses; an explicit `null` in the request body is treated the same way. Required string fields with an empty-after-trim value are rejected with `422 validation_failed`. Email addresses are trimmed, normalized to lowercase, capped at 160 characters after trimming, and validated with the same email rules used by `phx.gen.auth`. Repository slugs are normalized to lowercase and must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Unknown JSON fields are rejected with `422 validation_failed`; multipart requests that include any field name the target endpoint does not define are likewise rejected with `422 validation_failed`. String fields whose trimmed length exceeds the maximum specified in the data-model tables are rejected with `422 validation_failed`.

Request bodies and endpoint-specific behavior:

- `POST /api/v1/auth/login`: JSON body `{"email": "...", "password": "..."}`.
- `POST /api/v1/repos`: JSON body with required `name` and `slug`, and optional `description`, `is_public`, `gpg_key_fingerprint`, and `sign_rpms`. Requests with a `slug` whose normalized form is already in use by another repository are rejected with `422 validation_failed` and `details.slug` indicating the conflict, so slug uniqueness collisions surface the same way as format violations. Requests with `gpg_key_fingerprint` set to anything other than the owner's current GPG key fingerprint are rejected with `422 validation_failed`. Requests with `sign_rpms = true` must also set `gpg_key_fingerprint` to the owner's current GPG key fingerprint or they are rejected with `422 validation_failed`. `rpm_signing_state` is server-managed; requests that include it are rejected with `422 validation_failed`. A new empty repository created with `sign_rpms = true` starts with `rpm_signing_state = "enabled"`.
- `PATCH /api/v1/repos/:slug`: JSON body with any subset of repository fields accepted by create, except `slug`, which is immutable. PATCH requests that include `slug` are rejected with `422 validation_failed` so existing client `.repo` files continue to resolve. `rpm_signing_state` is server-managed; PATCH requests that include it are rejected with `422 validation_failed`. PATCH requests with `gpg_key_fingerprint` set to anything other than the owner's current GPG key fingerprint are rejected with `422 validation_failed`. PATCH operations that would leave `sign_rpms = true` with `gpg_key_fingerprint` unset are rejected with `422 validation_failed` (mirroring the create-time constraint). Enabling `sign_rpms` on a repository that already has packages requires an explicit `existing_package_strategy` field with value `"resign"` to confirm per-package re-sign jobs identical to the key replacement flow; the server sets `rpm_signing_state = "signing"` until those jobs complete. Transitioning `sign_rpms` to `true` on a non-empty repository without this field is rejected with `422 validation_failed`. Unknown `existing_package_strategy` values are rejected with `422 validation_failed`. When `sign_rpms` is unchanged, when it is transitioning from `true` to `false`, or when it is being enabled on an empty repository, requests that include `existing_package_strategy` are rejected with `422 validation_failed`. Enabling `sign_rpms` on an empty repository sets `rpm_signing_state = "enabled"`; disabling `sign_rpms` sets `rpm_signing_state = "disabled"`.
- `POST /api/v1/repos/:slug/packages`: multipart body with exactly one `rpm` file field. A duplicate NEVRA in the repository returns `409 conflict_duplicate_package`. Oversized uploads return `413 payload_too_large`; valid-size files that are not valid RPMs return `422 validation_failed`; insufficient temporary upload workspace returns `503 upload_temp_space_unavailable`; signing infrastructure failures return `503 signing_unavailable`; object-storage failures return `503 storage_unavailable`.
- `POST /api/v1/repos/:slug/collaborators`: JSON body `{"email": "user@example.com"}`. Adding collaborators or invitations is valid only for private repositories; add requests on a public repository are rejected with `422 validation_failed`. Removal, cancellation, and listing remain available regardless of repository visibility, so rows retained across a private-to-public flip can still be managed. The email is normalized to lowercase before lookup. If the email belongs to the repository owner, the request is rejected with `422 validation_failed`. If a collaborator or pending invitation already exists for the normalized email, the request succeeds idempotently with `200 OK` and returns the existing collaborator or invitation instead of creating a duplicate. Newly created collaborators or invitations return `201 Created`.
- `POST /api/v1/api_keys`: JSON body with `name`, `scopes`, and optional `expires_at`. `name` is trimmed, must be non-blank, and must be at most 100 characters after trimming. `scopes` must be a non-empty array of valid scope strings. When `expires_at` is provided it must be a future ISO-8601 UTC timestamp; values at or before the current server time are rejected with `422 validation_failed`. The plaintext API key is returned only in this response.
- `GET /api/v1/gpg_key`: no request body. Returns the current GPG key resource, or `404 not_found` if the authenticated user has no GPG key.
- `PUT /api/v1/gpg_key`: multipart body with `public_key` and `private_key` fields containing ASCII-armored GPG keys. Each key field is capped at 1 048 576 bytes; larger key uploads are rejected with `413 payload_too_large`. The public and private keys must share the same fingerprint, and the private key must be usable for non-interactive signing. The response is `200 OK` with the GPG key resource. If `previous_gpg_key_public` is already set for the user, or if any repository owned by the user has `rpm_signing_state = "signing"`, the request is rejected with `409 conflict_gpg_key_transition_in_progress`.
- `DELETE /api/v1/gpg_key`: no request body. Returns `404 not_found` when the authenticated user has no GPG key. Returns `204 No Content` when the key exists and is not used by any repository. Returns `409 conflict_gpg_key_in_use` with `details.metadata_signed_repositories` and `details.rpm_signed_repositories` counts when an explicit revocation strategy is required.
- `POST /api/v1/gpg_key/revocation`: JSON body `{"strategy": "clear_metadata_signing"}` or `{"strategy": "delete_signed_packages"}`; or multipart body with `strategy=replace_key`, `public_key`, and `private_key` fields. Each key field in a `replace_key` request is capped at 1 048 576 bytes; larger key uploads are rejected with `413 payload_too_large`. Returns `404 not_found` when the authenticated user has no GPG key. Unknown strategies are rejected with `422 validation_failed`. `clear_metadata_signing` is rejected with `409 conflict_gpg_key_in_use` if any owned repository has `sign_rpms = true`. `strategy=replace_key` is rejected with `409 conflict_gpg_key_transition_in_progress` if `previous_gpg_key_public` is already set for the user, or if any repository owned by the user has `rpm_signing_state = "signing"`. Successful `clear_metadata_signing` and `delete_signed_packages` requests return `204 No Content`; successful `replace_key` requests return `200 OK` with the new GPG key resource.

Resource response shapes:

- Repository resources have shape `{"id": "<uuid>", "owner_id": "<uuid>", "slug": "stable", "name": "Stable", "description": null, "is_public": true, "gpg_key_fingerprint": null, "sign_rpms": false, "rpm_signing_state": "disabled", "metadata_revision": 0, "package_count": 0, "inserted_at": "...", "updated_at": "..."}`.
- Package list resources have shape `{"id": "<uuid>", "repository_id": "<uuid>", "name": "nginx", "epoch": 0, "version": "1.24.0", "release": "2.fc39", "arch": "x86_64", "summary": "A high performance web server and reverse proxy server", "size_package": 623104, "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "download_path": "/repos/stable/packages/<uuid>/nginx-1.24.0-2.fc39.x86_64.rpm", "inserted_at": "...", "updated_at": "..."}`.
- Package detail resources include every package list field plus `description`, `url`, `license`, `size_installed`, `build_time`, `rpm_sourcerpm`, `rpm_group`, `requires`, `provides`, `conflicts`, `obsoletes`, `files`, and `changelogs`. `build_time` is an ISO-8601 UTC timestamp or `null`. Package resources never expose the internal `storage_path`.
- Optional string fields use `null` when absent.
- Dependency entries in `requires`, `provides`, `conflicts`, and `obsoletes` have shape `{"name": "libc.so.6()(64bit)", "op": ">=", "epoch": 0, "version": "2.34", "release": null}`. `op` is one of `<`, `<=`, `=`, `>=`, `>`, or `null`. When `op` is `null`, `epoch`, `version`, and `release` are also `null`. When `op` is set, `version` is required, `epoch` is `0` if the RPM omits an epoch, and `release` is `null` only when the RPM omits a release constraint. `requires` entries additionally include `pre`, a boolean indicating a pre-transaction dependency.
- File entries have shape `{"path": "/usr/bin/nginx", "type": "file", "flags": []}`. `type` is `file`, `directory`, or `symlink`. `flags` is an array containing zero or more of `config`, `doc`, `ghost`, `license`, and `readme`.
- Changelog entries have shape `{"timestamp": "2025-01-15T10:30:00Z", "author": "Packager <packager@example.com>", "text": "Updated to 1.24.0"}`.
- API key resources have shape `{"id": "<uuid>", "name": "CI read-only", "key_prefix": "dzak_abcdefg", "scopes": ["repo:read"], "expires_at": null, "inserted_at": "...", "updated_at": "..."}`. `POST /api/v1/api_keys` returns the same resource plus `key`, the full plaintext API key; no other response includes `key` or `key_hash`.
- GPG key resources have shape `{"fingerprint": "0123456789ABCDEF0123456789ABCDEF01234567", "public_key": "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----", "replacement_in_progress": false, "previous_public_key": null, "updated_at": "..."}`. GPG key resources never expose private key material.

`GET /api/v1/repos/:slug/collaborators` returns collaborators and pending invitations as typed rows in the standard paginated list envelope. Rows are sorted by normalized email ascending, then by `type` (`collaborator` before `invitation`), then by `id` ascending. Collaborator rows have shape `{"type": "collaborator", "id": "<collaborator_id>", "user_id": "<user_id>", "email": "user@example.com", "inserted_at": "..."}`. Invitation rows have shape `{"type": "invitation", "id": "<invitation_id>", "email": "pending@example.com", "invited_by_id": "<user_id>", "inserted_at": "..."}`.

All list endpoints — including `/api/v1/repos`, `/api/v1/repos/:slug/packages`, `/api/v1/repos/:slug/collaborators`, and `/api/v1/api_keys` — support `page` and `per_page` query parameters and return the same paginated envelope. `page` defaults to `1`; `per_page` defaults to `50` and is capped at `100`. Non-integer or non-positive pagination values are rejected with `422 validation_failed`. `total_pages` is computed as `ceil(total / per_page)`, so it is `0` when `total` is `0`. Requests for a `page` value greater than `total_pages` succeed with `200 OK`, return an empty `data` array, and echo the requested `page` value in the pagination envelope. Default ordering is deterministic: repositories by `slug` ascending then `id` ascending; packages by `name` ascending, `arch` ascending, RPM EVR descending, then `id` ascending; collaborators as described above; and API keys by `inserted_at` descending then `id` ascending. Package list endpoints additionally support `q`, `name`, `arch`, and `sort`. The `q` parameter performs a case-insensitive substring match against the package `name` and `summary` fields combined; `name` is an exact-match filter. Valid package sort values are `name`, `version`, `arch`, and `inserted_at`; prefix with `-` for descending order. The `version` sort orders packages by RPM EVR using `(epoch, version, release)` and RPM's native comparison semantics (`rpmvercmp` behavior), with `name`, `arch`, and `id` as deterministic tie-breakers. `-version` reverses the EVR ordering. For every descending sort, only the named sort column is reversed; tie-breaker columns keep their ascending order. Non-version package sorts use `id` ascending as the final tie-breaker. Unknown sort values are rejected with `422 validation_failed`.

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

Standard API error codes:

| HTTP | Code                                       | Meaning                                                                                                |
| ---: | ------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
|  400 | `invalid_request`                          | Malformed JSON, malformed multipart upload, or unsupported content type                                |
|  401 | `unauthenticated`                          | Missing, expired, or invalid credentials                                                               |
|  403 | `forbidden`                                | Authenticated user lacks the required scope, repository permission, or allowed authentication method    |
|  404 | `not_found`                                | Requested repository, package, collaborator, invitation, API key, or GPG key was not found             |
|  409 | `conflict_duplicate_package`               | Package with the same repository/name/epoch/version/release/arch already exists                        |
|  409 | `conflict_gpg_key_in_use`                  | GPG key removal requires an explicit revocation strategy because one or more repositories still use it |
|  409 | `conflict_gpg_key_transition_in_progress`  | GPG key replacement was requested while a key or RPM signing transition is still active                |
|  409 | `conflict_user_owns_repositories`          | Admin attempted to delete a user that still owns repositories                                          |
|  413 | `payload_too_large`                        | File upload exceeds the endpoint's configured or documented size limit                                 |
|  422 | `validation_failed`                        | Request shape is valid but field values failed validation                                              |
|  429 | `rate_limited`                             | Request exceeded the applicable rate limit                                                             |
|  500 | `internal_error`                           | Unexpected server error                                                                                |
|  503 | `signing_unavailable`                      | Required RPM/GPG signing tooling or signing infrastructure is temporarily unavailable                   |
|  503 | `storage_unavailable`                      | Backblaze B2 or object-storage operation is temporarily unavailable                                    |
|  503 | `upload_temp_space_unavailable`            | Temporary upload workspace lacks the required free space                                               |

To avoid leaking the existence of private resources, repository-scoped requests that target a private repository (or any resource scoped under one) return `404 not_found` when the requester is anonymous, presents invalid/expired/revoked credentials, or is authenticated as a valid principal that lacks access to that repository. Requests to a slug that does not exist also return `404 not_found`, so clients cannot distinguish "this slug is private" from "this slug does not exist." Anonymous requests refine this rule on two surfaces while preserving that indistinguishability: the repository-serving endpoints intended for RPM clients return `401 unauthenticated` with a `WWW-Authenticate: Basic` challenge for private and nonexistent slugs alike (see Private Repository Authentication), and web UI routes under `/repos/:slug` redirect anonymous requests for private and nonexistent slugs to the login page, rendering the standard HTML 404 page after login only when the authenticated user still lacks access or the slug does not exist. For `/api/v1/...` requests the base `404 not_found` masking applies unchanged. For public repository reads, optional credentials that fail validation return `401 unauthenticated` instead of falling back to anonymous access, so bad client configuration is visible. Other endpoints and actions that require authentication return `401 unauthenticated` for missing credentials and also return `401 unauthenticated` for credentials that fail validation — invalid signature, expired, or revoked. `403 forbidden` is returned only when the authenticated principal is known to exist and is permitted to see the resource but lacks the specific scope, mutation permission, or allowed authentication method required for the requested operation (e.g., a valid API key without `package:upload` attempting an upload to a public repo, a valid API key with `repo:read` but without `repo:update` attempting to add a collaborator on a private repo it can read, or any API key attempting to manage API keys or GPG keys).

### Response Format

Example package list response:

```json
{
  "data": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "repository_id": "76c4474c-4b87-4ee8-8eb5-b2f7f4673e31",
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

For private repositories, the request must be authenticated with read access to the repository. The downloaded file never embeds API keys, session tokens, or passwords. Private repo files use placeholders (`password=<api-key>`) so the same endpoint is safe to cache, inspect, and share. Personalized setup snippets that include a user's actual API key may be rendered in the authenticated web UI, but they are not returned by this endpoint.

For a repository with metadata signing and `rpm_signing_state = "enabled"`, returns a file like:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://<hostname>/repos/:slug/
enabled=1
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://<hostname>/repos/:slug/RPM-GPG-KEY
```

For repositories without metadata signing, `repo_gpgcheck` is `0`. For repositories whose `rpm_signing_state` is not `enabled`, including repositories still in the `signing` transition, `gpgcheck` is `0`. The `gpgkey` line is included whenever `gpg_key_fingerprint` is configured and is omitted only when no repository key is configured. For private repositories, the file includes credential placeholders:

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
| `PREVIOUS_SECRET_KEY_BASE` | —       | Optional. Prior value of `SECRET_KEY_BASE` during a rotation window so encrypted GPG private keys can be decrypted while the background re-encryption job migrates them. Remove once the job has migrated every row. |
| `TRUSTED_PROXIES`      | empty       | Comma-separated list of reverse-proxy IPv4/IPv6 addresses or CIDR blocks whose forwarded-IP headers (`CF-Connecting-IP`, `X-Forwarded-For`) the application trusts when determining the client IP for rate limiting. Empty means no proxy is trusted and the TCP peer address is always used. |
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
| `MAX_RPM_UPLOAD_BYTES` | `536870912` | Maximum accepted RPM upload size in bytes (default 512 MiB)                    |
| `RPM_UPLOAD_TMPDIR`    | system temp | Directory used for per-upload temporary working files                          |
| `MAIL_ADAPTER`         | `zepto`     | Outbound email adapter (Swoosh module). Default uses Zepto Mail. See Email Delivery below. |
| `ZEPTO_API_KEY`        | —           | Zepto Mail API key (required when `MAIL_ADAPTER=zepto`)                        |
| `MAIL_FROM_ADDRESS`    | —           | Sender address for outbound notifications (required when email is enabled)     |
| `MAIL_FROM_NAME`       | `Dark Zenith` | Display name shown for the sender                                            |
| `REGISTRATION_ENABLED` | `false`     | Whether new account registration is open                                       |
| `ADMIN_EMAIL`          | —           | Email for the initial admin account, created on first boot if no users exist   |
| `ADMIN_PASSWORD`       | —           | Password for the initial admin account                                         |

---

## Email Delivery

Dark Zenith sends transactional emails for:

- Account email confirmation and password reset (via `phx.gen.auth`).
- Collaborator invitations to registered and unregistered users (subject to the registration-disabled exception described under Repository Collaborators).

Email delivery is built on Swoosh with a pluggable adapter selected by `MAIL_ADAPTER`. The application code uses a single `DarkZenith.Mailer` module and a thin notifier layer, so swapping providers is a configuration change rather than a code change. `MAIL_ADAPTER` accepts the following short aliases:

| Alias | Backing adapter | Notes |
|---|---|---|
| `zepto` | Zepto Mail HTTPS API | Default. Requires `ZEPTO_API_KEY` and `MAIL_FROM_ADDRESS`. |
| `smtp` | `Swoosh.Adapters.SMTP` | Configure host, port, username, password, and TLS settings in `config/runtime.exs`. |
| `local` | `Swoosh.Adapters.Local` | In-memory mailbox for development; messages can be viewed at `/dev/mailbox`. The `/dev/mailbox` route is mounted only in the dev Mix environment. |

Unknown aliases cause the application to refuse to boot. When the selected adapter requires credentials or sender configuration, the application also refuses to boot if the required values are missing; with the default `MAIL_ADAPTER=zepto`, both `ZEPTO_API_KEY` and `MAIL_FROM_ADDRESS` are required. Development and test deployments may set `MAIL_ADAPTER=local` to avoid external mail credentials. Additional Swoosh adapters can be wired in by adding a new alias to this mapping in a future release.

Outbound mail uses `MAIL_FROM_ADDRESS` as the sender and `MAIL_FROM_NAME` (default `Dark Zenith`) as the display name. Every email is dispatched through an Oban worker so a transient provider outage does not fail the originating request; delivery jobs retry up to 20 attempts with exponential backoff and exhausted jobs remain visible in Oban for admin intervention.

---

## Deployment

Dark Zenith is designed for straightforward deployment:

- **Mix releases**: Standard Elixir release via `mix release`, producing a self-contained binary.
- **Docker**: Dockerfile provided for containerized deployment.
- **Systemd**: Example systemd unit file provided.
- **Reverse proxy**: Designed to sit behind nginx/caddy for TLS termination.
- **RPM signing tools**: Deployments that enable RPM signing must have `rpm`, `rpmsign`, and `gpg` available in the runtime environment.
- **Single application node**: The initial version assumes one app node. Web upload previews keep their temporary files on node-local `RPM_UPLOAD_TMPDIR`, and rate-limit buckets live in node-local memory (ETS). Running multiple nodes would require a shared upload workspace (or session affinity) and a shared rate-limit store, and is out of scope for the initial version.

### Initial Setup

Since `REGISTRATION_ENABLED` defaults to `false`, the first admin account is bootstrapped via environment variables (`ADMIN_EMAIL` and `ADMIN_PASSWORD`). On first boot, if no users exist in the database, a confirmed admin user is created with these credentials. If no users exist but `ADMIN_EMAIL` or `ADMIN_PASSWORD` is unset, Dark Zenith logs a warning and starts without creating an admin; the operator must restart with both variables set to bootstrap an admin. `ADMIN_EMAIL` and `ADMIN_PASSWORD` must satisfy the same email and password validation rules as regular accounts; if either fails validation, Dark Zenith logs a warning and starts without creating an admin, the same as when the variables are unset. After the initial admin is created, these environment variables are ignored. Additional users can be created by the admin or by enabling public registration.

### Storage

RPM files are stored exclusively in Backblaze B2. The app server handles no RPM file traffic — clients are redirected to signed B2 URLs. This means the app itself is lightweight and can run on modest hardware regardless of repository size or download volume.

---

## Security Considerations

- Mutating actions (create repo, upload RPM, delete) require session auth (web) or bearer token auth (API).
- Mutating actions on a repository are restricted to the repo owner or an admin user. API keys inherit the permissions of their owning user.
- API key and GPG key management endpoints require session token or session cookie authentication; API keys cannot manage API keys or GPG keys.
- Public read-only endpoints (repo browsing, package listing, repodata, RPM downloads) require no authentication for public repos.
- Private repo read endpoints require authentication. Browser requests may use the user's session; RPM clients use HTTP Basic Auth with API keys for repodata and RPM downloads.
- Signed B2 URLs expire after `B2_SIGNED_URL_TTL` seconds (default 30 minutes), limiting the window for URL sharing/leakage.
- RPM uploads are validated to prevent arbitrary file storage.
- B2 storage keys use deterministic, sanitized paths to prevent key manipulation.
- GPG private keys are encrypted at rest in the database with the versioned AES-256-GCM envelope described in GPG Signing. They are only decrypted in-memory during signing operations.
- Rotating `SECRET_KEY_BASE` invalidates Phoenix cookie sessions and all stored HMAC token hashes that use it (API keys, session tokens, and web upload preview tokens). Operators must communicate the rotation in advance; users must sign in again and re-create API keys afterward. GPG private keys survive `SECRET_KEY_BASE` rotation only when operators follow the dual-base rotation procedure — set `PREVIOUS_SECRET_KEY_BASE` to the prior value while the background re-encryption job runs and remove it once the job has migrated every row. See the GPG private key encryption envelope section for the full procedure. Per-token envelope versioning for HMAC token hashes is reserved for a future release.
- Downloadable `.repo` files never include API keys, session tokens, or passwords.
- Rate limiting on all endpoints (see Rate Limiting below).
- CSRF protection on all web form submissions and cookie-authenticated mutating API requests (standard Phoenix behavior).

---

## Rate Limiting

All endpoints are rate limited. The rate limiting strategy differs based on authentication status:

- **Authenticated general requests** (API key, session token, or session cookie): 600 requests per minute per user. All requests from the same user share a single bucket regardless of which API key or auth method is used.
- **Unauthenticated general requests**: 120 requests per minute per IP address. Since multiple users may share an IP (corporate networks, VPNs, NAT), these limits are more restrictive.
- **Authentication attempts** (`/api/v1/auth/login`, the web login route, registration, and password reset): 10 requests per minute per IP address and 10 requests per minute per normalized (trimmed, lowercased) email address. These buckets apply *in lieu of* the 120/min unauthenticated general bucket — requests to these routes do not also count against the general bucket.
- **Unauthenticated package downloads** (`GET /repos/:slug/packages/:id/:filename.rpm`): 600 requests per minute per IP address. This bucket applies *in lieu of* the 120/min unauthenticated general bucket for these requests, so large `dnf` transactions against public repositories do not stall mid-install; the endpoint only performs a database lookup and signed-URL generation, so the higher ceiling is cheap for the app server. Authenticated package downloads count against the authenticated general bucket as usual.
- **Package uploads**: 60 uploads per hour per user, in addition to the authenticated general request limit. In the web preview-and-confirm flow, the preview request (which carries the file transfer) counts against this bucket; the confirmation request does not, though it still counts against the authenticated general bucket.
- **Collaborator additions** (`POST /api/v1/repos/:slug/collaborators` and the equivalent web action): 60 requests per hour per user, in addition to the authenticated general request limit, bounding the volume of invitation email a single user can trigger.

Every response to a rate-limited endpoint includes `X-RateLimit-Limit` (the ceiling for the bucket that governed the request, in requests per window) and `X-RateLimit-Remaining` (the number of requests still allowed in the current window) so clients can self-throttle without waiting for a rejection. When a rate limit is exceeded, the server additionally responds with **HTTP 429 Too Many Requests** and includes `Retry-After` (a duration in seconds, per RFC 9110) and `X-RateLimit-Reset` (a Unix epoch timestamp in seconds indicating when the limit resets) headers. When more than one bucket applies to a request (for example, package upload endpoints that count against both the per-user general bucket and the per-user upload bucket), the headers reflect the bucket with the smallest remaining allowance. For unauthenticated API and web requests, the 429 response body includes a message encouraging the user to create an account and authenticate for higher limits. Repository-serving endpoints keep the plain-text `rate_limited` body described in the RPM Repository Endpoint section.

### Client IP detection

Per-IP rate-limit buckets and the authentication-attempt buckets identify the client using the following resolution order, controlled by the `TRUSTED_PROXIES` configuration:

1. If the connecting TCP peer address is in `TRUSTED_PROXIES` and the request includes a `CF-Connecting-IP` header, use that header's value. Dark Zenith is expected to sit behind Cloudflare in production, so this hop is checked first and authoritatively overrides any forwarded chain when it is present from a trusted proxy.
2. Else, if the connecting TCP peer is in `TRUSTED_PROXIES` and the request includes `X-Forwarded-For`, walk the comma-separated chain from right to left, skip every address that is itself in `TRUSTED_PROXIES`, and use the first remaining address as the client IP.
3. Otherwise, use the TCP peer address.

When `TRUSTED_PROXIES` is empty, forwarded-IP headers are ignored entirely and the TCP peer address is always used. Operators MUST configure `TRUSTED_PROXIES` to include Cloudflare's published IP ranges (and any additional in-cluster reverse proxies) when running behind Cloudflare; failing to do so causes every request to be bucketed as a single source IP. Because step 1 accepts `CF-Connecting-IP` from any trusted peer, operators who place additional non-Cloudflare reverse proxies in `TRUSTED_PROXIES` must ensure those proxies are reachable only through Cloudflare or strip client-supplied `CF-Connecting-IP` headers; otherwise a client that can reach such a proxy directly could spoof its rate-limit identity.

### Authenticated access to public repos

Public repositories are accessible without authentication, but authenticated requests receive higher rate limits. The web UI setup instructions for public repos include both an unauthenticated `.repo` configuration and an authenticated variant using any active API key with at least one valid scope via HTTP Basic Auth. Users are encouraged to use authenticated access to get per-user rate limiting rather than sharing an IP-based limit with other users.

---

## Future Considerations

These features are out of scope for the initial version but may be added later:

- **Delta RPMs (drpm)**: Generate and serve delta RPMs to reduce download sizes for updates.
- **Repository snapshots/versioning**: Point-in-time snapshots of repository state.
- **Checksum-named repodata files**: Serve metadata blobs under checksum-unique `repodata/` paths and briefly retain the previous generation, eliminating the transient checksum-mismatch race during metadata updates.
- **Webhook notifications**: Notify external systems when packages are added/updated.
- **Multi-arch mirroring**: Proxy/cache packages from upstream repositories.
- **Metrics/analytics**: Download counts, popular packages, bandwidth usage dashboards.
- **RPM groups/comps.xml**: Support for package groups and environment definitions.
- **Module metadata (modules.yaml)**: Support for DNF modularity streams.
