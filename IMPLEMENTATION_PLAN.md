# Dark Zenith — Implementation Plan

`DESIGN.md` is the source of truth for every behavior listed here. This document only
sequences the work and tracks progress; when it and `DESIGN.md` disagree, `DESIGN.md`
wins. Checklist items reference spec sections rather than restating their rules.

## Working agreements

- TDD: write the failing test first for every code change (see `CLAUDE.md` / `AGENTS.md`).
- Commit after each coherent change; serialize commits with the `commit.lock` protocol.
- Update `AGENTS.md`, `README.md`, and this checklist as commands and structure appear.
- Spec deviations discovered during implementation are fixed in `DESIGN.md` first (or
  raised with the user), never silently coded around.

## Milestones

| Milestone | Meaning |
|-----------|---------|
| M1 | A repository can be created (web + API) and an empty repo serves valid `repodata/` to `dnf` |
| M2 | End-to-end package flow: direct-to-B2 upload, processing, metadata regen, signed-URL download |
| M3 | GPG signing: metadata signing, RPM auto-signing, key replacement/removal transitions |
| M4 | Production hardening: rate limiting, admin surface, deployment artifacts, dnf release-gate tests |

## Phase 0 — Scaffolding (M1)

- [x] Phoenix app at repo root (`mix phx.new`, LiveView, `--binary-id` for UUID PKs)
- [x] PostgreSQL for dev/test (podman container `dark-zenith-pg`, host port 55432)
- [x] `mix test` green on the pristine scaffold
- [x] Merge `.gitignore`, add `.tool-versions`, update `AGENTS.md`/`CLAUDE.md` repo-status sections
- [x] Add Oban + core dependency baseline and app configuration

## Phase 1 — Crypto and token primitives (M1)

- [x] `SECRET_KEY_BASE` byte rules and validation (Configuration; GPG private key encryption)
- [x] HMAC-SHA-256 token hashing helper for `dzak_`/`dzst_` values (Token storage)
- [x] GPG private-key encryption envelope `v1`/`v2` with the spec's fixed vectors
      (GPG private key encryption) — including AAD/user binding and tamper tests
- [x] Decrypt fallback to `PREVIOUS_SECRET_KEY_BASE` (re-encryption job itself is Phase 11)

## Phase 2 — Accounts foundation (M1)

- [x] `mix phx.gen.auth` (bcrypt) baseline; confirm password rules (min 12 / max 72) (Users)
- [x] Confirmed-only login on web path (User Lifecycle)
- [x] Users table extensions: `is_admin`, `storage_bytes`, GPG columns (nullable, unused until Phase 11)
- [x] Session tokens table + `dzst_` issuance/validation, 24 h expiry, hourly cleanup (Session Tokens)
- [x] API keys table + `dzak_` issuance/validation, scopes canonicalization, `MAX_USER_API_KEYS`
      quota under user-row lock (API Keys)
- [x] Password change/reset deletes session tokens; API keys survive (Session Tokens)
- [x] Bootstrap admin on first boot from `ADMIN_EMAIL`/`ADMIN_PASSWORD` (Initial Setup)
- [x] `DarkZenith.Release.promote_admin/1` with the shared admin advisory lock (Initial Setup)
- [x] Admin-invariant advisory lock: admin-flag mutations, last-admin guarantee (admin
      deletes arrive with user deletion in Phase 3+) (User Lifecycle)
- [ ] Normalized-email advisory lock shared by registration/provisioning/email-change/invitations
      (User Lifecycle)
- [x] Audit events table + append-only recorder (Audit Events)

## Phase 3 — Repositories domain (M1)

- [x] Repositories table with counters and signing fields (Data Model — Repositories)
- [x] Slug reservations: conditional claim/revive, retire on delete, admin release
      (Slug Reservations)
- [x] Repository creation transaction: quota, slug claim, empty metadata cache row
      (`source_revision = 0`) (Metadata Generation & Storage)
- [x] Repository metadata cache table (Repository Metadata Cache)
- [x] Repository update rules (immutable slug, fingerprint/sign_rpms validation matrix;
      enable-on-non-empty needs Phase 11 transitions) (REST API — PATCH)
- [x] Repository deletion transaction (hard delete, retire slug; intent/item cancelation
      joins in Phases 9/11) (Package Upload & Processing)
- [ ] Collaborators + invitations tables, quota, idempotent add, conversion on
      registration/email-change, expiry cleanup (Repository Collaborators; Collaborator Invitations)
- [ ] Authorization module: owner/collaborator/admin/public matrix (Authorization)

## Phase 4 — EVR ordering in PostgreSQL (M1)

- [ ] Migration owning `dark_zenith_rpmvercmp`, `dark_zenith_evr_cmp`, composite type +
      operator class (API Contract Details)
- [ ] ExUnit conformance fixtures for the upstream librpm comparison corpus
- [ ] Release-time differential check against RPM 6 tooling (wire into Phase 16 boot/release tests)

## Phase 5 — RPM parser, pure Elixir (M2)

- [ ] Lead/signature/main header structural parsing with bounds (64 MiB headers, 65 535 entries)
      (RPM Parsing; Package Upload & Processing step 1)
- [ ] v4 acceptance rules (SHA-256 header + payload digest required; weak-only rejected)
- [ ] v6 acceptance rules (RPMFORMAT/ENCODING, mandatory tags, sorted unique tags, zero padding)
- [ ] Metadata extraction: NEVRA, i18n strings, sizes, source refs, build_time
      (Package Upload & Processing step 3)
- [ ] Dependency extraction incl. weak deps, rpmlib exclusion, duplicate collapse, rich deps,
      `pre` flag set
- [ ] File and changelog extraction with caps (262 144 files / 4 096 changelogs / 65 536 deps)
- [ ] Validation of extracted values (charsets, control chars, XML 1.0, caret rejection)
- [ ] Fixture corpus: accepted v4/v6, weak-digest variants, malformed headers, differential
      parity with `createrepo_c` output

## Phase 6 — Repodata generation (M1 for empty repos, M2 full)

- [ ] Deterministic XML encoders for `primary`/`filelists`/`other` (namespaces, element order,
      createrepo_c parity) (Metadata Format)
- [ ] Deterministic gzip (level 6, mtime 0, no filename)
- [ ] `repomd.xml` (+ optional `.asc` hook for Phase 11), revision semantics
- [ ] Counting-sink byte accounting for the four repository counters (Metadata Generation & Storage)
- [ ] Oban regeneration job: snapshot transaction, tmp-file streaming, revision CAS, re-enqueue,
      debounce (Metadata Generation & Storage)
- [ ] `MAX_REPOSITORY_PACKAGES` / `MAX_REPODATA_OPEN_BYTES` enforcement incl. grandfathered
      ceilings

## Phase 7 — Repo-serving endpoints (M1)

- [x] `/repos/:slug/repodata/*` from cache, `503 metadata_not_ready` + `Retry-After: 5`
- [x] Plain-text error bodies, content types, HEAD support, query-string tolerance
      (RPM File Downloads; RPM Repository Endpoint)
- [x] Caching headers + strong ETag/If-None-Match matrix, `Vary` (Caching headers)
- [x] Basic/Bearer auth, anonymous challenge, masking rules (Private Repository Authentication)
- [x] `dark-zenith.repo` endpoint (+ `RPM-GPG-KEY` completes in Phase 11) (.repo File Endpoint)
- [ ] Package download 302 to signed B2 URL for exact version (needs Phase 8)

## Phase 8 — B2 / S3 client (M2)

- [ ] SigV4 presigned `PutObject` (signed content type/length) and `GetObject`/`HeadObject`
      URLs, path-style (Upload Intents; Deployment)
- [ ] Server-side `HeadObject` contract checks (length, content type, forbidden metadata)
- [ ] `CopyObject` with `MetadataDirective=REPLACE` + fallback rule (step 9)
- [ ] Version-aware delete, `ListObjectVersions` pagination
- [ ] Retry/error mapping to `storage_unavailable`; no SDK auto-retry on non-idempotent writes

## Phase 9 — Upload pipeline (M2)

- [ ] Storage reservations table + user-lock quota accounting (Storage Reservations)
- [ ] Upload intents table + full state machine checks (Upload Intents)
- [ ] Intent create/refresh/complete/cancel endpoints incl. idempotency + CAS rules
- [ ] Temp-space ETS ledger, leases, janitor, `upload_temp_space_unavailable` (Package Upload & Processing)
- [ ] Processing worker: download, `rpmkeys` verify, parse, validate, limits, duplicate,
      reservation adjust, final write, fenced commit (steps 1–10)
- [ ] Web preview mode: `preview_ready`, confirmation, metadata-equality recheck
- [ ] Package deletion transaction; staging + final reconcilers; waiting-state cleanup
- [ ] Fault-injection test suite for every interruption point named in the spec

## Phase 10 — REST API surface (M1 partial, M2 complete)

- [x] JSON envelope, error codes table, decimal-string bigint contract (API Contract Details)
- [x] Strict query/body parsing (unknown fields, duplicate keys, malformed encoding)
- [ ] Pagination envelope + deterministic orderings (done); package filters/sorts incl. EVR sort
- [x] Auth plugs: bearer precedence, cookie fallback, scope checks, 404 masking, 401/403 split
- [x] `POST /auth/login`, `DELETE /auth/logout` (session tokens)
- [ ] Repos CRUD (done); api_keys (done); packages list/detail/subresources/delete; collaborators
- [x] Request caps: 1 MiB JSON, GPG multipart caps, `413 payload_too_large`

## Phase 11 — GPG signing (M3)

- [ ] Key upload validation: armored V4 pair, single identity, signing-key selection,
      algorithm allowlist, ephemeral GNUPGHOME, rpmsign/rpmkeys fixture tests, expiry floor
      (GPG Signing)
- [ ] Metadata signing in regeneration; `RPM-GPG-KEY` and `repomd.xml.asc` endpoints
- [ ] RPM signing in upload pipeline (addsign/resign, --rpmv4 for v6, expected-key verify)
- [ ] Signing transitions + items + repository snapshots: enable_rpm_signing,
      replace_gpg_key, clear_metadata_signing, delete_signed_packages (Signing Transitions)
- [ ] Lease/fencing worker runtime shared with uploads; sweeps; admin reset/cancel flows
- [ ] `PREVIOUS_SECRET_KEY_BASE` re-encryption scan/jobs (GPG private key encryption)
- [ ] Expiry reminders (30/7/1 days) + expired-key fail-closed behavior

## Phase 12 — Email delivery (M2)

- [ ] Swoosh mailer + `MAIL_ADAPTER` alias mapping, boot validation (Email Delivery)
- [ ] Oban-backed delivery with per-notification generation fencing
      (Repository Collaborators; Collaborator Invitations)
- [ ] phx.gen.auth mail (confirmation/reset/email change) through the same worker path
- [ ] Security notification mails (password/email/GPG/API-key events)

## Phase 13 — Rate limiting (M4)

- [ ] ETS fixed-window counters, UTC-aligned, atomic increments, 60 s sweep (Rate Limiting)
- [ ] Bucket classes: general auth/unauth, auth attempts, downloads, specialized per-user hourly
- [ ] Client IP resolution with `TRUSTED_PROXIES` / CF-Connecting-IP / XFF walk; IPv6 /64
- [ ] Response headers, 429 bodies per surface, LiveView event limiting

## Phase 14 — Web UI (M1 partial, M2/M3 complete)

- [ ] Landing, repo list/detail, setup instructions, package list/detail/version pages
      (Web Interface)
- [ ] Repo create/settings/delete; collaborator management
- [ ] Upload flow LiveView (direct-to-B2, preview/confirm)
- [ ] Account: API keys, GPG key management, auth pages incl. reset-page API-key revocation
- [ ] HTML escaping guarantees; `url` as the only RPM-derived hyperlink

## Phase 15 — Admin surface (M4)

- [ ] User management (create auto-confirmed, admin flags, delete with ownership guard)
- [ ] Signing-transition views with reset/cancel; Oban dashboard mount
- [ ] Audit log browser; slug reservation release

## Phase 16 — Deployment & boot (M4)

- [ ] `config/runtime.exs` covering the full Configuration table with validation ranges
- [ ] Boot probes: rpmkeys/rpmsign/gpg version + fixture verification, mail adapter check
      (Deployment)
- [ ] `/health` endpoints; release packaging, Dockerfile, systemd unit with confinement
- [ ] `force_ssl`/proxy trust, CSP with `connect-src` B2 origin, filter_parameters, secure cookies
- [ ] dnf 4/5 end-to-end release-gate tests (public + private, signed + unsigned)

## Cross-cutting requirements to keep in every phase

- Background Retry Policy for every durable job (Architecture)
- Global lock order for final mutation transactions (Storage Reservations)
- Audit events written in-transaction with their action (Audit Events)
- 404 masking and 401/403 discipline on every new route (API Contract Details)
- Decimal-string bigints on every new JSON field (API Contract Details)
