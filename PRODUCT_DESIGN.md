# Dark Zenith - Product Design

## Overview

Dark Zenith is an Elixir/Phoenix application that serves as a fully-functional RPM package repository. It renders all repository metadata and web pages, while RPM files themselves are stored in Backblaze B2 object storage and served to clients via time-limited signed URLs.

## Major Features

### Web Interface

- **Create new repos**: Authenticated users can create and configure new RPM repositories.
- **Browse existing repos**: Public listing of available repositories.
- **Repo setup instructions**: Per-repo page with copy-paste commands for adding the repo to a user's `dnf` configuration.
- **View available packages**: Browsable, searchable list of packages within a repository.
- **Package install instructions**: Per-package page with `dnf install` commands and details.
- **Upload RPM packages**: Authenticated users can upload new RPM versions to a repository.

### REST API

- Programmatic access to **everything the web interface supports**: creating repos, listing repos, listing packages, uploading RPMs, deleting packages, etc.
- Authenticated via bearer tokens (API keys).

### RPM Repository Serving

- The web app renders all `repodata/` metadata (`repomd.xml`, `primary.xml.gz`, etc.) that `dnf`/`yum` need.
- RPM files are stored in **Backblaze B2** object storage.
- When a client requests an RPM file, Dark Zenith responds with a redirect to a **signed B2 URL with a 30-minute access window**.
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
| API Auth | Bearer token (API keys) |

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
                                          signed URLs (30 min)
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
| `is_public` | boolean | Whether the repo is listed on the public page |
| `inserted_at` | timestamp | Creation time |
| `updated_at` | timestamp | Last modification time |

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
| `key_hash` | string | Hashed API key |
| `key_prefix` | string | First 8 chars for identification |
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

**Note**: Public repositories do not require `repo:read` — they are accessible without authentication. However, authenticated requests to public repos (using a key with any valid scope) benefit from higher rate limits (see Rate Limiting).

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
| `token_hash` | string | Hashed token value |
| `expires_at` | timestamp | Expiration time (24 hours after creation) |
| `inserted_at` | timestamp | Creation time |

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

Metadata is regenerated as a background job (via Oban) whenever packages are added or removed from a repository. The process:

1. Package upload/deletion triggers an Oban job for the affected repository. On deletion, a separate Oban job removes the RPM file from B2.
2. The job queries all packages in the repository from PostgreSQL.
3. XML metadata files are generated in-memory and compressed with gzip.
4. The generated metadata blobs are stored in PostgreSQL keyed by repository.
5. A new `repomd.xml` is generated with checksums pointing to the current metadata files.
6. The repo endpoint serves these directly from cache.

Multiple rapid changes are debounced — if a regeneration job is already queued for a repository, duplicate requests are collapsed.

### RPM File Downloads

When a client (e.g., `dnf`) requests an RPM file at `/repos/:slug/packages/:id/:filename.rpm`:

1. Dark Zenith looks up the package record by `:id` in PostgreSQL to find the B2 storage key. The `:filename` segment is cosmetic (ignored for routing) but provides a human-readable filename for download clients.
2. Generates a **signed Backblaze B2 URL** with a **30-minute expiration**.
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
```

### GPG Signing (Optional)

Each user can upload a GPG key pair (public + private) to their account. The private key is encrypted at rest in the database using `SECRET_KEY_BASE`. When creating or editing a repository, the owner can enable two levels of signing:

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
2. A GPG detached signature is computed over the RPM header + payload using `gpg --detach-sign` (shelling out to `gpg` for the cryptographic operation).
3. The signature is spliced into the RPM's signature header section using the Elixir RPM parser (which handles both reading and writing the signature header structure).
4. The SHA-256 checksum is recomputed on the signed RPM.
5. The signed RPM is uploaded to B2.

RPMs that are already signed are re-signed (the existing signature is replaced). This ensures all packages in the repo are signed with a consistent key.

If `sign_rpms` is enabled but the owner has no GPG key configured, the upload is rejected with an error.

---

## Package Upload & Processing

When an RPM file is uploaded (via web UI or API) by an authenticated user:

1. **Validate**: Confirm the file is a valid RPM by reading the RPM lead and header.
2. **Extract metadata**: Parse the RPM headers to extract name, version, release, epoch, arch, dependencies, file lists, changelogs, summary, description, license, etc. This is done in Elixir by reading the RPM binary format directly (RPM header structure).
3. **Sign** (if `sign_rpms` enabled): Sign the RPM using the owner's GPG key and rewrite the signature header (see GPG Signing section).
4. **Checksum**: Compute SHA-256 of the (possibly signed) RPM file.
5. **Upload to B2**: Store the RPM file in Backblaze B2 at a deterministic key: `repos/:slug/packages/:name-:version-:release.:arch.rpm`.
6. **Record**: Insert the package record into PostgreSQL with the B2 storage key.
7. **Regenerate**: Enqueue an Oban job to regenerate the repository metadata.

### RPM Parsing

Rather than shelling out to `rpm` or `rpm2cpio`, Dark Zenith will include a pure-Elixir RPM header parser. The RPM format is well-documented:

- **Lead** (96 bytes): Magic number, format version. Used for quick validation.
- **Signature header**: Contains size and digest information.
- **Main header**: Contains all package metadata as tagged entries (name, version, dependencies, etc.) using a well-defined set of tag constants.
- **Payload**: The compressed cpio archive (not needed for metadata extraction).

The parser reads the lead, signature, and main header sections — the payload is stored as-is and never decompressed by Dark Zenith. For RPM signing, the parser also supports **writing** the signature header section to splice in GPG signatures produced by the `gpg` CLI.

---

## Web Interface

The web UI is built with Phoenix LiveView. Public pages are accessible to everyone; actions that modify data (creating repos, uploading packages) require authentication.

### Landing Page (`GET /`)

- Brief description of what Dark Zenith provides.
- Links to available repositories.

### Repository List (`GET /repos`)

- Browse all existing repositories with name, description, and package count.
- Authenticated users see a "Create New Repo" action.

### Create Repository (authenticated)

- Form to create a new repository: name, slug, description, public/private, GPG signing settings (enable metadata signing, enable RPM auto-signing).

### Repository Detail (`GET /repos/:slug`)

- Repository description and status.
- **Setup instructions** with copy-paste `dnf` commands for adding the repo to the user's system:
  - `.repo` file contents to place in `/etc/yum.repos.d/`.
  - For public repos: unauthenticated config shown by default, with an authenticated variant (using Basic Auth with the user's API key) recommended for higher rate limits.
  - For private repos: instructions include Basic Auth credentials using the logged-in user's API key. If the user has no API key, prompt them to create one.
  - One-liner `dnf config-manager` command.
  - GPG key import instructions (if applicable).
- **Package list**: Searchable, sortable table of packages in this repo (name, version, arch, summary).
- Authenticated users see an "Upload RPM" action.
- **Owner/admin only**: "Manage Collaborators" section to add/remove users who can access a private repo.

### Package Detail (`GET /repos/:slug/packages/:name`)

- Lists all versions/architectures available for this package name.
- For each version: arch, summary, size, upload date.
- **Install instructions**: `dnf install <package>` command (assumes the repo is already configured).
- Links to individual package version pages.

### Package Version Detail (`GET /repos/:slug/packages/:name/:version-:release.:arch`)

- Full package metadata: name, epoch, version, release, arch, summary, full description.
- Dependency information (requires, provides, conflicts, obsoletes).
- File list and changelog.
- Direct download link (generates a signed B2 URL).

### Upload RPM (authenticated, `GET /repos/:slug/upload`)

- Drag-and-drop or file picker to upload an RPM to the selected repository.
- Shows extracted metadata for confirmation before finalizing.
- **Web only**: The two-step confirmation flow (preview then confirm) is a web UI feature. The REST API processes uploads immediately in a single request — see the API section.

### GPG Key Management (authenticated, account settings)

- Upload a GPG key pair (public + private) to the user's account.
- View the fingerprint and public key of the currently uploaded key.
- Remove the existing GPG key (only allowed if no repositories have signing enabled with this key).

### Authentication Pages

- Login / logout.
- Account registration (when enabled).
- API key management for the authenticated user.

---

## REST API

The REST API provides programmatic access to everything the web interface supports. Authentication is via `Authorization: Bearer <token>` header, where the token is either an API key or a short-lived session token obtained from the login endpoint. API endpoints also accept session cookie authentication (as used by the web UI), which allows the web frontend to call API endpoints directly and enables users to create their first API key without already having one.

Read-only endpoints for public repos are unauthenticated.

### Authentication

```
POST   /api/v1/auth/login               # Login with email + password, returns a short-lived session token
DELETE /api/v1/auth/logout              # Invalidate a session token
```

The login endpoint accepts `{"email": "...", "password": "..."}` and returns a short-lived bearer token (24-hour expiration). This token is distinct from API keys — it cannot be managed via the API keys endpoints, expires automatically, and is intended for interactive/CLI use. API keys remain the preferred mechanism for long-lived programmatic access.

### Repositories

```
GET    /api/v1/repos                    # List all repositories
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

### Response Format

All API responses use JSON. Example package response:

```json
{
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
```

---

## .repo File Endpoint

For convenience, serve a downloadable `.repo` file:

```
GET /repos/:slug/dark-zenith.repo
```

Returns a file like:

```ini
[dark-zenith-:slug]
name=Dark Zenith - :repo_name
baseurl=https://<hostname>/repos/:slug/
enabled=1
gpgcheck=1                                          # 0 if no GPG key configured
gpgkey=https://<hostname>/repos/:slug/RPM-GPG-KEY   # omitted if no GPG key configured
```

---

## Configuration

Dark Zenith is configured via environment variables and/or `config/runtime.exs`:

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | — | PostgreSQL connection string |
| `SECRET_KEY_BASE` | — | Phoenix secret key |
| `PHX_HOST` | `localhost` | Hostname for URL generation |
| `PORT` | `4000` | HTTP listen port |
| `B2_KEY_ID` | — | Backblaze B2 application key ID |
| `B2_APPLICATION_KEY` | — | Backblaze B2 application key |
| `B2_BUCKET` | — | B2 bucket name for RPM storage |
| `B2_ENDPOINT` | — | B2 S3-compatible endpoint URL |
| `B2_SIGNED_URL_TTL` | `1800` | Signed URL expiration in seconds (default 30 min) |
| `REGISTRATION_ENABLED` | `false` | Whether new account registration is open |
| `ADMIN_EMAIL` | — | Email for the initial admin account, created on first boot if no users exist |
| `ADMIN_PASSWORD` | — | Password for the initial admin account |

---

## Deployment

Dark Zenith is designed for straightforward deployment:

- **Mix releases**: Standard Elixir release via `mix release`, producing a self-contained binary.
- **Docker**: Dockerfile provided for containerized deployment.
- **Systemd**: Example systemd unit file provided.
- **Reverse proxy**: Designed to sit behind nginx/caddy for TLS termination.

### Initial Setup

Since `REGISTRATION_ENABLED` defaults to `false`, the first admin account is bootstrapped via environment variables (`ADMIN_EMAIL` and `ADMIN_PASSWORD`). On first boot, if no users exist in the database, a confirmed admin user is created with these credentials. After the initial admin is created, these environment variables are ignored. Additional users can be created by the admin or by enabling public registration.

### Storage

RPM files are stored exclusively in Backblaze B2. The app server handles no RPM file traffic — clients are redirected to signed B2 URLs. This means the app itself is lightweight and can run on modest hardware regardless of repository size or download volume.

---

## Security Considerations

- Mutating actions (create repo, upload RPM, delete) require session auth (web) or bearer token auth (API).
- Mutating actions on a repository are restricted to the repo owner or an admin user. API keys inherit the permissions of their owning user.
- Public read-only endpoints (repo browsing, package listing, repodata, RPM downloads) require no authentication for public repos.
- Private repos require HTTP Basic Auth (using API keys) on all endpoints including repodata and RPM downloads.
- Signed B2 URLs expire after 30 minutes, limiting the window for URL sharing/leakage.
- RPM uploads are validated to prevent arbitrary file storage.
- B2 storage keys use deterministic, sanitized paths to prevent key manipulation.
- GPG private keys are encrypted at rest in the database using `SECRET_KEY_BASE`. They are only decrypted in-memory during signing operations.
- Rate limiting on all endpoints (see Rate Limiting below).
- CSRF protection on all web form submissions (standard Phoenix behavior).

---

## Rate Limiting

All endpoints are rate limited. The rate limiting strategy differs based on authentication status:

- **Authenticated requests** (API key, session token, or session cookie): Rate limited per user. All requests from the same user share a single bucket regardless of which API key or auth method is used.
- **Unauthenticated requests**: Rate limited per IP address. Since multiple users may share an IP (corporate networks, VPNs, NAT), these limits are more restrictive.

When a rate limit is exceeded, the server responds with **HTTP 429 Too Many Requests** and includes `Retry-After` and `X-RateLimit-Reset` headers. For unauthenticated requests, the 429 response body includes a message encouraging the user to create an account and authenticate for higher limits.

### Authenticated access to public repos

Public repositories are accessible without authentication, but authenticated requests receive higher rate limits. The web UI setup instructions for public repos include both an unauthenticated `.repo` configuration and an authenticated variant using the user's API key with HTTP Basic Auth. Users are encouraged to use authenticated access to get per-user rate limiting rather than sharing an IP-based limit with other users.

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
