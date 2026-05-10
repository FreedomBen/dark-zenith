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
| `gpg_key_id` | string | Optional GPG key ID for signing (must match the fingerprint of the owner's uploaded GPG key) |
| `sign_rpms` | boolean | Whether uploaded RPMs are automatically signed with the repo owner's GPG key (default `false`; requires the owner to have uploaded a GPG key pair) |
| `is_public` | boolean | Whether unauthenticated users can list, browse, and download from the repo |
| `metadata_revision` | integer | Monotonic revision incremented whenever package membership or metadata signing settings change (default `0`) |
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
| `epoch` | integer | RPM epoch (default `0`) |
| `version` | string | Package version (e.g., `1.24.0`) |
| `release` | string | Package release (e.g., `2.fc39`) |
| `arch` | string | Architecture (`x86_64`, `noarch`, `aarch64`, etc.) |
| `summary` | string | One-line description |
| `description` | text | Full description |
| `url` | string | Upstream project URL |
| `license` | string | License identifier |
| `size_installed` | bigint | Installed size in bytes |
| `size_package` | bigint | RPM file size in bytes |
| `sha256` | string | SHA-256 checksum of the RPM file |
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
| `key_hash` | string | HMAC-SHA-256 hash of the full API key |
| `key_prefix` | string | First 12 chars of the API key for identification |
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

Users can create multiple API keys with different scopes and names (e.g., a `repo:read`-only key for CI pulls, a scoped key for uploads). A key with an empty scopes list has no access — at least one scope is required. Admin users' API keys operate on all repos, not just their own (e.g., an admin key with `package:upload` can upload to any repo).

**Note**: Public repositories do not require `repo:read` — they are accessible without authentication. However, authenticated requests to public repos (using any non-expired API key with at least one valid scope) benefit from higher rate limits (see Rate Limiting).

**API Key Format**: API keys are generated from 32 bytes of cryptographically secure random data, encoded as unpadded base64url, and returned to the caller as `dzak_<secret>`. The plaintext key is shown only once at creation. The database stores `key_prefix` for display and `key_hash`, computed as `HMAC-SHA-256(SECRET_KEY_BASE, plaintext_key)` and encoded as lowercase hex. Expired keys and keys with no scopes are rejected before scope checks.

### Repository Collaborators

Repo owners can grant other users read access to their private repositories. When the invited user is already registered, a collaborator record is created immediately. When the email does not match a registered user, a pending invitation is created instead and converts to a collaborator record when the user registers.

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

Session tokens are generated from 32 bytes of cryptographically secure random data, encoded as unpadded base64url, and returned as `dzst_<secret>`. The database stores only `HMAC-SHA-256(SECRET_KEY_BASE, plaintext_token)` encoded as lowercase hex. Session tokens do not have scopes; they authorize API requests as the logged-in user and still require the same owner/admin checks as web sessions.

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
| `gpg_key_private` | binary | Optional GPG private key, encrypted at rest using `SECRET_KEY_BASE` |
| `gpg_key_public` | text | ASCII-armored GPG public key (served at `/repos/:slug/RPM-GPG-KEY`) |
| `gpg_key_fingerprint` | string | Fingerprint of the stored GPG key (for display/identification) |
| `confirmed_at` | timestamp | Email confirmation time |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

### Authorization

- **Owner**: A user owns the repositories they create. Only the owner can modify (update, delete, upload to) their repositories. Owners can add collaborators to their private repos.
- **Collaborator**: A user granted read access to a private repository by its owner. Collaborators can browse, view packages, and download RPMs from that repo. They cannot modify the repo or upload packages.
- **Admin**: Users with `is_admin = true` can perform any action on any repository, manage users, and access admin-only features.
- **Public**: Unauthenticated users can browse public repos, view packages, and download RPMs. No authentication is required for read-only access to public repositories.
- **Private repos**: When `is_public = false`, all access (including repodata and RPM downloads) requires authentication. Only the owner, collaborators, and admins can access private repos.

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

- **`primary.xml.gz`**: Contains package names, versions, architectures, summaries, sizes, checksums, and dependency information (requires, provides, conflicts, obsoletes). This is the main metadata file used for dependency resolution.

- **`filelists.xml.gz`**: Lists all files contained in each package. Used when a user runs commands like `dnf provides /usr/bin/something`.

- **`other.xml.gz`**: Contains changelog entries for each package.

### Metadata Generation & Storage

All repodata XML is generated by the app and served directly from the app (not from B2). The metadata is stored in PostgreSQL as cached blobs so it can be served without regeneration on every request.

Metadata is regenerated as a background job (via Oban) whenever packages are added or removed from a repository, or whenever repository settings that affect generated metadata change. The process:

1. Package upload/deletion increments the repository's `metadata_revision` inside the same database transaction that changes package membership.
2. The transaction enqueues a unique Oban regeneration job for the affected repository. On deletion, a separate idempotent Oban job removes the RPM file from B2 after the package row is removed.
3. The regeneration job reads the current repository `metadata_revision`, then queries all packages in the repository from PostgreSQL.
4. XML metadata files are generated in-memory and compressed with gzip.
5. A new `repomd.xml` is generated with checksums pointing to the current metadata files.
6. The generated metadata blobs, `repomd.xml`, optional `repomd.xml.asc` signature, and `source_revision` are stored in PostgreSQL keyed by repository.
7. Before completing, the job reloads the repository. If `metadata_revision` is greater than the cached `source_revision`, the job enqueues another unique regeneration job so the final cache reflects the latest package set.
8. The repo endpoint serves metadata directly from the cache.

Repository setting changes that affect generated metadata, such as enabling/disabling metadata signing or changing `gpg_key_id`, use the same `metadata_revision` increment and regeneration enqueue path.

Multiple rapid changes are debounced with an Oban unique job keyed by `repository_id` while the job is available or scheduled. Running jobs are allowed to be followed by a newly queued job, and the `metadata_revision`/`source_revision` check guarantees another job runs until the cache reaches the latest revision. Metadata regeneration and B2 cleanup jobs retry up to 20 attempts with exponential backoff; exhausted jobs remain visible in Oban for admin intervention.

### RPM File Downloads

When a client (e.g., `dnf`) requests an RPM file at `/repos/:slug/packages/:id/:filename.rpm`:

1. Dark Zenith looks up the package record by `:id` in PostgreSQL to find the B2 storage key. The `:filename` segment is cosmetic (ignored for routing) but provides a human-readable filename for download clients.
2. Generates a **signed Backblaze B2 URL** using `B2_SIGNED_URL_TTL` (default **30-minute expiration**).
3. Responds with **HTTP 302 redirect** to the signed URL.
4. The client downloads the RPM directly from B2.

This keeps RPM file bandwidth off the app server entirely.

### Private Repository Authentication

Private repositories (`is_public = false`) require authentication on all endpoints, including repodata and RPM downloads. RPM clients (`dnf`/`yum`) authenticate via **HTTP Basic Auth**:

- **Username**: `token` (literal string)
- **Password**: a valid API key with the `repo:read` scope

Dark Zenith checks the API key, verifies it has the `repo:read` scope, resolves the owning user, and verifies they have access to the repository (as owner, collaborator, or admin) before serving metadata or issuing a signed B2 URL.

Example `.repo` configuration for a private repo:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://token:<api-key>@<hostname>/repos/:slug/
enabled=1
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
gpgcheck=1
gpgkey=https://<hostname>/repos/:slug/RPM-GPG-KEY
```

For private repositories without a configured GPG key, `gpgcheck` is `0` and the `gpgkey` line is omitted.

### GPG Signing (Optional)

Each user can upload a GPG key pair (public + private) to their account. The private key is encrypted at rest in the database using `SECRET_KEY_BASE`. Private keys must be dedicated repository-signing keys that can sign non-interactively; passphrase-protected private keys are rejected at upload with `422 validation_failed`. When creating or editing a repository, the owner can enable two levels of signing:

#### Repository metadata signing (`gpg_key_id` set)

- `repomd.xml` is signed during metadata regeneration using the owner's GPG key.
- `repomd.xml.asc` is served alongside `repomd.xml`.
- The owner's public key is served at the repo level.

```
GET /repos/:slug/repodata/repomd.xml.asc
GET /repos/:slug/RPM-GPG-KEY
```

#### RPM signing (`sign_rpms = true`, requires `gpg_key_id`)

When enabled, Dark Zenith automatically signs uploaded RPMs during the upload processing pipeline:

1. After RPM validation and metadata extraction, the private key is decrypted from the database.
2. The private key is imported into an ephemeral `GNUPGHOME` with `0700` permissions and removed after the signing attempt completes.
3. The uploaded RPM is copied to a temporary working path and signed with the system `rpmsign` tool, using an rpm macro configuration that points at the ephemeral GPG home and the configured key fingerprint.
4. Unsigned RPMs are signed with `rpmsign --addsign`; RPMs that already contain an OpenPGP package signature are signed with `rpmsign --resign` so the existing package signature is replaced.
5. The signed RPM is verified with `rpm --checksig` before it is accepted.
6. The SHA-256 checksum is recomputed on the signed RPM.
7. The signed RPM is uploaded to B2.

RPMs that are already signed are re-signed (the existing signature is replaced). This ensures all packages in the repo are signed with a consistent key.

If `sign_rpms` is enabled but the owner has no GPG key configured, the upload is rejected with an error.

---

## Package Upload & Processing

When an RPM file is uploaded (via web UI or API) by a repository owner or admin:

1. **Validate**: Confirm the file is a valid RPM by reading the RPM lead and header.
2. **Extract metadata**: Parse the RPM headers to extract name, version, release, epoch, arch, dependencies, file lists, changelogs, summary, description, license, etc. This is done in Elixir by reading the RPM binary format directly (RPM header structure).
3. **Sign** (if `sign_rpms` enabled): Sign the RPM using the owner's GPG key and `rpmsign` (see GPG Signing section).
4. **Checksum**: Compute SHA-256 of the (possibly signed) RPM file.
5. **Duplicate check**: If a package with the same `(repository_id, name, epoch, version, release, arch)` already exists, reject the upload with **HTTP 409 Conflict**. The database unique constraint is still the source of truth for concurrent uploads.
6. **Upload to B2**: Store the RPM file in Backblaze B2 at a deterministic key that includes the full NEVRA tuple: `repos/:slug/packages/:name-:epoch-:version-:release.:arch.rpm`.
7. **Record**: Insert the package record into PostgreSQL with the B2 storage key, increment `metadata_revision`, and enqueue the repository metadata regeneration job in the same transaction.

If B2 upload fails, no package row is inserted and the caller receives an upload error. If the B2 upload succeeds but the database insert fails, Dark Zenith immediately attempts to delete the just-uploaded object. If that cleanup fails, it enqueues an idempotent B2 cleanup job and returns the original database error to the caller. If the package insert succeeds but metadata regeneration fails, the upload remains successful; the regeneration job retries until the cache reaches the repository's latest `metadata_revision`.

Package deletion removes the package row, increments `metadata_revision`, and enqueues metadata regeneration in one database transaction. B2 object deletion happens in a separate idempotent Oban job with retries. If B2 deletion fails, the package no longer appears in metadata or API responses, and package-id download URLs no longer resolve, but the orphaned object is retried for cleanup.

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

### Package Detail (`GET /repos/:slug/packages/:name`)

- Lists all versions/architectures available for this package name.
- For each version: arch, summary, size, upload date.
- **Install instructions**: `dnf install <package>` command (assumes the repo is already configured).
- Links to individual package version pages.

### Package Version Detail (`GET /repos/:slug/packages/:name/:epoch/:version-:release.:arch`)

- Full package metadata: name, epoch, version, release, arch, summary, full description.
- Dependency information (requires, provides, conflicts, obsoletes).
- File list and changelog.
- Direct download link (generates a signed B2 URL).

### Upload RPM (owner/admin, `GET /repos/:slug/upload`)

- Drag-and-drop or file picker to upload an RPM to the selected repository.
- Shows extracted metadata for confirmation before finalizing.
- **Web only**: The two-step confirmation flow (preview then confirm) is a web UI feature. The REST API processes uploads immediately in a single request — see the API section.

### GPG Key Management (authenticated, account settings)

- Upload a GPG key pair (public + private) to the user's account.
- View the fingerprint and public key of the currently uploaded key.
- Remove the existing GPG key (only allowed if no repositories have signing enabled with this key).
- Passphrase-protected private keys are rejected; users should upload a dedicated repository-signing key.

### Authentication Pages

- Login / logout.
- Account registration (when enabled).
- API key management for the authenticated user.

---

## REST API

The REST API provides programmatic access to repository operations. Authentication is via `Authorization: Bearer <token>` header, where the token is either an API key or a short-lived session token obtained from the login endpoint. API endpoints also accept session cookie authentication (as used by the web UI), which allows the web frontend to call API endpoints directly and enables users to create their first API key without already having one.

Read-only endpoints for public repos are unauthenticated.

Mutating API endpoints require either session/cookie authentication or an API key with the matching scope. Repository-scoped mutations also require the authenticated user to be the repository owner or an admin.

### Authentication

```
POST   /api/v1/auth/login               # Login with email + password, returns a short-lived session token
DELETE /api/v1/auth/logout              # Invalidate a session token
```

The login endpoint accepts `{"email": "...", "password": "..."}` and returns a short-lived bearer token (24-hour expiration). This token is distinct from API keys — it cannot be managed via the API keys endpoints, expires automatically, and is intended for interactive/CLI use. API keys remain the preferred mechanism for long-lived programmatic access.

### Repositories

```
GET    /api/v1/repos                    # List public repositories and private repositories visible to the requester
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
POST   /api/v1/repos/:slug/collaborators              # Add a collaborator by email (owner/admin only; creates pending invitation if user not registered)
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
DELETE /api/v1/gpg_key                  # Remove your GPG key (auth required)
```

### API Contract Details

JSON endpoints require `Content-Type: application/json`. Upload endpoints use `multipart/form-data`. All timestamps are ISO-8601 UTC strings, all IDs are UUID strings, and all request strings are trimmed before validation. Email addresses are normalized to lowercase. Repository slugs are normalized to lowercase and must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Unknown JSON fields are rejected with `422 validation_failed`.

Request bodies:

- `POST /api/v1/auth/login`: JSON body `{"email": "...", "password": "..."}`.
- `POST /api/v1/repos`: JSON body with `name`, `slug`, optional `description`, `is_public`, optional `gpg_key_id`, and `sign_rpms`.
- `PATCH /api/v1/repos/:slug`: JSON body with any subset of repository fields accepted by create.
- `POST /api/v1/repos/:slug/packages`: multipart body with a single `rpm` file field. A duplicate NEVRA in the repository returns `409 conflict_duplicate_package`.
- `POST /api/v1/repos/:slug/collaborators`: JSON body `{"email": "user@example.com"}`.
- `POST /api/v1/api_keys`: JSON body with `name`, `scopes`, and optional `expires_at`. The plaintext API key is returned only in this response.
- `PUT /api/v1/gpg_key`: multipart body with `public_key` and `private_key` fields containing ASCII-armored GPG keys. The public/private keys must match, and the private key must be usable for non-interactive signing.

List endpoints support `page` and `per_page` query parameters. `page` defaults to `1`; `per_page` defaults to `50` and is capped at `100`. Package list endpoints additionally support `q`, `name`, `arch`, and `sort`. Valid package sort values are `name`, `version`, `arch`, and `inserted_at`; prefix with `-` for descending order.

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

| HTTP | Code                         | Meaning                                                                                    |
| ---: | ---------------------------- | ------------------------------------------------------------------------------------------ |
|  400 | `invalid_request`            | Malformed JSON, malformed multipart upload, or unsupported content type                    |
|  401 | `unauthenticated`            | Missing, expired, or invalid credentials                                                   |
|  403 | `forbidden`                  | Authenticated user lacks the required scope or repository permission                       |
|  404 | `not_found`                  | Requested repository, package, collaborator, invitation, API key, or GPG key was not found |
|  409 | `conflict_duplicate_package` | Package with the same repository/name/epoch/version/release/arch already exists            |
|  422 | `validation_failed`          | Request shape is valid but field values failed validation                                  |
|  429 | `rate_limited`               | Request exceeded the applicable rate limit                                                 |
|  500 | `internal_error`             | Unexpected server error                                                                    |

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

Returns a file like:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://<hostname>/repos/:slug/
enabled=1
gpgcheck=1
gpgkey=https://<hostname>/repos/:slug/RPM-GPG-KEY
```

For unsigned repositories, `gpgcheck` is `0` and the `gpgkey` line is omitted. For private repositories, the file includes credential placeholders:

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

Since `REGISTRATION_ENABLED` defaults to `false`, the first admin account is bootstrapped via environment variables (`ADMIN_EMAIL` and `ADMIN_PASSWORD`). On first boot, if no users exist in the database, a confirmed admin user is created with these credentials. After the initial admin is created, these environment variables are ignored. Additional users can be created by the admin or by enabling public registration.

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
- GPG private keys are encrypted at rest in the database using `SECRET_KEY_BASE`. They are only decrypted in-memory during signing operations.
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

When a rate limit is exceeded, the server responds with **HTTP 429 Too Many Requests** and includes `Retry-After` and `X-RateLimit-Reset` headers. For unauthenticated requests, the 429 response body includes a message encouraging the user to create an account and authenticate for higher limits.

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
