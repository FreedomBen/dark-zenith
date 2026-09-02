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
- [x] Normalized-email advisory lock shared by registration/provisioning/email-change/invitations
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
- [x] Collaborators + invitations tables, quota, idempotent add, conversion on
      registration/email-change, expiry cleanup (Repository Collaborators; Collaborator Invitations)
- [x] Authorization module: owner/collaborator/admin/public matrix (Authorization)

## Phase 4 — EVR ordering in PostgreSQL (M1)

- [x] Migration owning `dark_zenith_rpmvercmp`, `dark_zenith_evr_cmp`, composite type +
      operator class (API Contract Details)
- [x] ExUnit conformance fixtures for the upstream librpm comparison corpus
      (corpus + 400 random pairs differentially validated against rpm 6.0.1 on 2026-08-30)
- [x] Release-time differential check against RPM 6 tooling (BootCheck.check_evr_comparator,
      run at prod boot and by deploy/release_gate.sh)

## Phase 5 — RPM parser, pure Elixir (M2)

- [x] Lead/signature/main header structural parsing with bounds (64 MiB headers, 65 535 entries)
      (RPM Parsing; Package Upload & Processing step 1)
- [x] v4 acceptance rules (SHA-256 header + payload digest required; weak-only rejected)
- [x] v6 acceptance rules (RPMFORMAT/ENCODING, mandatory tags, sorted unique tags, zero padding)
- [x] Metadata extraction: NEVRA, i18n strings, sizes, source refs, build_time
      (Package Upload & Processing step 3)
- [x] Dependency extraction incl. weak deps, rpmlib exclusion, duplicate collapse, rich deps,
      `pre` flag set
- [x] File and changelog extraction with caps (262 144 files / 4 096 changelogs / 65 536 deps)
- [x] Validation of extracted values (charsets, control chars, XML 1.0, caret rejection)
- [x] Fixture corpus: accepted v4/v6, weak-digest variants, malformed headers, differential
      parity with `createrepo_c` output (extraction parity done; generated-XML parity joins
      the Phase 6 encoders)

## Phase 6 — Repodata generation (M1 for empty repos, M2 full)

- [x] Deterministic XML encoders for `primary`/`filelists`/`other` (namespaces, element order,
      createrepo_c parity — format/filelists/other blocks byte-match the reference; dnf5
      makecache + repoquery validated against generated metadata) (Metadata Format)
- [x] Deterministic gzip (level 6, mtime 0, no filename)
- [x] `repomd.xml` (+ optional `.asc` hook for Phase 11), revision semantics
- [x] Counting-sink byte accounting for the four repository counters (Metadata Generation & Storage)
- [x] Oban regeneration job: snapshot transaction, tmp-file streaming, revision CAS, re-enqueue,
      debounce (Metadata Generation & Storage)
- [x] `MAX_REPOSITORY_PACKAGES` / `MAX_REPODATA_OPEN_BYTES` enforcement incl. grandfathered
      ceilings (regeneration ceilings + config; upload pipeline advisory + final locked checks)

## Phase 7 — Repo-serving endpoints (M1)

- [x] `/repos/:slug/repodata/*` from cache, `503 metadata_not_ready` + `Retry-After: 5`
- [x] Plain-text error bodies, content types, HEAD support, query-string tolerance
      (RPM File Downloads; RPM Repository Endpoint)
- [x] Caching headers + strong ETag/If-None-Match matrix, `Vary` (Caching headers)
- [x] Basic/Bearer auth, anonymous challenge, masking rules (Private Repository Authentication)
- [x] `dark-zenith.repo` endpoint (+ `RPM-GPG-KEY` completes in Phase 11) (.repo File Endpoint)
- [x] Package download 302 to signed B2 URL for exact version

## Phase 8 — B2 / S3 client (M2)

- [x] SigV4 presigned `PutObject` (signed content type/length) and `GetObject`/`HeadObject`
      URLs, path-style (Upload Intents; Deployment) — signer verified against AWS doc vectors
- [x] Server-side `HeadObject` contract checks (length, content type, forbidden metadata)
- [x] `CopyObject` with `MetadataDirective=REPLACE` + fallback rule (step 9; the PutObject
      fallback path is chosen by the Phase 9 pipeline)
- [x] Version-aware delete, `ListObjectVersions` pagination
- [x] Retry/error mapping to `storage_unavailable`; no SDK auto-retry on non-idempotent writes

## Phase 9 — Upload pipeline (M2)

- [x] Storage reservations table + user-lock quota accounting (Storage Reservations)
- [x] Upload intents table + full state machine checks (Upload Intents)
- [x] Intent create/refresh/complete/cancel endpoints incl. idempotency + CAS rules
- [x] Temp-space ETS ledger, leases, janitor, `upload_temp_space_unavailable` (Package Upload & Processing)
- [x] Processing worker: download, `rpmkeys` verify, parse, validate, limits, duplicate,
      reservation adjust, final write, fenced commit (steps 1–10; RPM signing dispatch joins
      in Phase 11)
- [x] Web preview mode: `preview_ready`, confirmation, metadata-equality recheck
- [x] Package deletion transaction; staging + final reconcilers (cron :30 / 03:00);
      waiting-state cleanup
- [x] Fault-injection test suite for the interruption points named in the spec (lease
      expiry/requeue, settings races, CAS-lost, exhaustion, user-wide phase batch
      boundaries/budgets/idempotent upserts, owner-fence deferral without budget use)

## Phase 10 — REST API surface (M1 partial, M2 complete)

- [x] JSON envelope, error codes table, decimal-string bigint contract (API Contract Details)
- [x] Strict query/body parsing (unknown fields, duplicate keys, malformed encoding)
- [x] Pagination envelope + deterministic orderings; package filters/sorts incl. EVR sort
- [x] Auth plugs: bearer precedence, cookie fallback, scope checks, 404 masking, 401/403 split
- [x] `POST /auth/login`, `DELETE /auth/logout` (session tokens)
- [x] Repos CRUD; api_keys; collaborators; packages list/detail/subresources/delete;
      package-uploads intent endpoints
- [x] Request caps: 1 MiB JSON, GPG multipart caps, `413 payload_too_large`

## Phase 11 — GPG signing (M3)

- [x] Key upload validation: armored V4 pair, single identity, signing-key selection,
      algorithm allowlist, ephemeral GNUPGHOME, rpmsign/rpmkeys fixture tests, expiry floor
      (GPG Signing) — real-gpg tests; the rpmsign fixture check is stubbed where rpm-sign is
      absent and exercised via the tagged :rpmsign integration test
- [x] Metadata signing in regeneration; `RPM-GPG-KEY` and `repomd.xml.asc` endpoints
      (Signing.Gpg default impl; expired keys fail closed with conflict_gpg_key_expired)
- [x] RPM signing in upload pipeline (addsign/resign, --rpmv4 for v6, expected-key verify)
- [x] Signing transitions + items + repository snapshots, end to end for all four kinds:
      repository-local enable plus user-wide replace_gpg_key (preparation cursors, key-swap
      commit with expiry floor, both-keys serving, activation batches), clear_metadata_signing,
      and delete_signed_packages (delete items, finalization, key-material removal); owner
      write fence with worker deferral; PUT 202 replacement, POST /gpg_key/revocation,
      GET /gpg_key/transitions/:id; RPM_TOOL_TIMEOUT_SECONDS process-group deadlines with
      lease-renewal heartbeats; hourly attempt-directory janitor (Signing Transitions)
- [x] Lease/fencing worker runtime shared with uploads; sweeps; admin item reset
- [x] `PREVIOUS_SECRET_KEY_BASE` re-encryption scan/jobs (GPG private key encryption;
      transition prepared-candidate rows join with the transition machinery)
- [x] Expiry reminders (30/7/1 days) + expired-key fail-closed behavior

## Phase 12 — Email delivery (M2)

- [x] Swoosh mailer + `MAIL_ADAPTER` alias mapping, boot validation (Email Delivery)
- [x] Oban-backed delivery with per-notification generation fencing
      (Repository Collaborators; Collaborator Invitations)
- [x] phx.gen.auth mail (confirmation/reset/email change) through the same worker path
- [x] Security notification mails (password/email/API-key; GPG key uploaded, replaced at
      the key swap, and removed)

## Phase 13 — Rate limiting (M4)

- [x] ETS fixed-window counters, UTC-aligned, atomic increments, 60 s sweep (Rate Limiting)
- [x] Bucket classes: general auth/unauth, auth attempts, downloads, specialized per-user hourly
- [x] Client IP resolution with `TRUSTED_PROXIES` / CF-Connecting-IP / XFF walk; IPv6 /64
- [x] Response headers, 429 bodies per surface, LiveView event limiting

## Phase 14 — Web UI (M1 partial, M2/M3 complete)

- [x] Landing, repo list/detail, setup instructions; package list/detail/version pages
      (searchable/sortable table, lazy-loaded collection tabs) (Web Interface)
- [x] Repo create/settings/delete and collaborator management
- [x] Upload flow LiveView (direct-to-B2 via the DirectUpload hook, preview/confirm)
- [x] Account: API keys, GPG key management, auth pages incl. reset-page API-key revocation
- [x] HTML escaping guarantees; `url` as the only RPM-derived hyperlink (regression tests
      render hostile summary/description/license/vendor across all package pages)

## Phase 15 — Admin surface (M4)

- [x] User management (create auto-confirmed, admin flags, delete with ownership guard)
- [x] Signing-transition views with reset/cancel (durable list + item inspection, failed-item
      reset, phase reset restoring resume_status, cancel where the flow permits);
      background-jobs view with retry/cancel
- [x] Audit log browser; slug reservation release

## Phase 16 — Deployment & boot (M4)

- [x] `config/runtime.exs` covering the full Configuration table with validation ranges
      (built up phase by phase; RPM tool paths/timeouts read from app env with defaults)
- [x] Boot probes: rpmkeys/rpmsign/gpg version + fixture verification, mail adapter check
      (Deployment)
- [x] `/health` endpoints; release packaging, Containerfile, systemd unit with confinement
- [x] `compose.yaml` offline local stack (app + PostgreSQL + MinIO under podman compose)
- [x] `force_ssl`/proxy trust, CSP with `connect-src` B2 origin, filter_parameters, secure cookies
- [x] dnf 4/5 end-to-end release-gate tests (public + private, signed + unsigned) —
      deploy/release_gate.sh runs boot checks plus dnf5/dnf makecache/repoquery for the
      public flow and, via DZ_GATE_* env, the repo_gpgcheck-signed and Basic-auth private
      flows; run it against a staging deployment before release
- [x] Container client check — `deploy/dnf_client_check.sh` (dnf5 adds the repository from
      its `dark-zenith.repo` link, installs a package with every other repository disabled,
      confirms it came from Dark Zenith, runs a verification command) run by the
      `:container`-tagged test/end_to_end/container_install_test.exs in a fresh Fedora 44
      container against listeners the test starts; reusable by hand against staging
- [x] Live install check — `deploy/live_install_check.sh <base-url> [public|private|signed ...]`
      logs in (or takes DZ_CHECK_TOKEN), creates a repository per flow, uploads the fixture
      through the real presigned PUT, waits for processing and metadata, runs the container
      client check against each (private via a repo:read API key it creates; signed with the
      account's key, generated only when absent), and deletes what it created; covered by
      test/end_to_end/live_install_check_test.exs against the test listeners with a queue
      drainer, and verified against the compose stack
- [x] GitHub Actions CI (`.github/workflows/ci.yml`): the precommit steps in a Fedora 44
      container with a PostgreSQL 18 service (Fedora's Elixir/OTP and RPM 6 tools, as in the
      Containerfile; `:container` tests excluded there), shellcheck of deploy/*.sh, and a
      Containerfile build, on pushes to main and pull requests; the test database follows
      PGHOST/PGPORT/PGUSER/PGPASSWORD

## Phase 17 — Server-side GPG key generation (post-M4 feature)

Spec: DESIGN.md "Server-side key generation" (GPG Signing), plus the generation additions
under Key replacement and revocation, Web Interface, REST API, Rate Limiting, Audit
Events, Email Delivery, and Security Considerations.

- [x] `DarkZenith.Gpg.generate_key_pair/2`: batch quick-generation in an ephemeral
      `GNUPGHOME` (sign-usage V4 primary, no passphrase, no expiry, snapshot-email UID),
      armored export, allowlisted algorithms with `ed25519` default
- [x] `Accounts.generate_gpg_key/2`: generated pair through the identical
      validation/storage/replacement pipeline as upload; one-time private-key return;
      `gpg_key.generate` audit for a first key, generated-flag metadata on
      `gpg_key.replace_start`; existing upload/replace notification emails
- [x] `POST /api/v1/gpg_key/generation`: optional JSON body (`algorithm` only), 200/202
      wrapped data objects carrying the one-time `private_key`, PUT-equivalent 409/422/503
      semantics
- [x] `POST /api/v1/gpg_key/revocation` strategy `replace_with_generated_key` (JSON-only,
      optional `algorithm`, wrapped 202 body)
- [x] Rate limiting: generation route + LiveView generate event in the `gpg_key_mutation`
      bucket; add the missing web revocation-strategy events to the same bucket
- [x] Settings LiveView: generate form with algorithm select, one-time private-key display
      with download link and never-again warning
- [x] Tests proving the security invariants: private key returned exactly once and only in
      generation responses, envelope-encrypted at rest, absent from resources/audit
      metadata, full validation pipeline applied to generated pairs

## Phase 18 — Durable upload history (post-M4 feature)

Spec: DESIGN.md "Package Upload Records" (Data Model), "Upload History" (Repository
Detail), "Reattaching" (Upload RPM), "Upload records" (Admin), the repository-scoped
listing exception in the REST API preamble, the `GET /api/v1/repos/:slug/package-uploads`
bullet and upload record row shape under API Contract Details, and the Audit Events,
Rate Limiting, repository-deletion, and user-deletion additions.

- [x] `package_upload_records` migration: UUID snapshot `repository_id` (no FK),
      `user_id` nilify-on-delete with `user_email` snapshot, unique `(intent_id)`,
      index on `(repository_id, started_at DESC, id)`, `(user_id)`, `(package_id)`,
      partial index on `(repository_id)` where `outcome = 'in_flight'` for the
      in-flight count, `(started_at DESC, id)`, `(repository_slug, started_at DESC, id)`,
      and `(user_email, started_at DESC, id)` for the admin view, outcome check
      constraint
- [x] Backfill in that migration: one record per existing intent row per the DESIGN.md
      backfill rule (`outcome` from status, `started_at` from `inserted_at`,
      `finished_at` from `completed_at`, error code/detail for `failed`, `nevra` and
      `final_size` from a surviving package row); a zero-row finalization CAS is a no-op
- [x] Record created in the intent-creation transaction as `in_flight`; finalized by a
      compare-and-swap on `outcome = 'in_flight'` inside `Uploads.terminalize!/4` and
      inside the success path's final package transaction (`final_size`, `nevra`)
- [x] Repository deletion and user deletion finalize `in_flight` records as `canceled`
      in their existing transactions and retain the record rows; hourly terminal-intent
      cleanup runs a second anti-join query finalizing any `in_flight` record whose
      intent row is gone, writing the sweep timestamp to `finished_at`, as the safety net
- [x] `Uploads.list_repository_records/2`: repository-scoped, `started_at` descending
      then `id` ascending, optional outcome-subset filter, left join to the live intent
      for `live_status`, initiator email from the record snapshot. `live_status` is
      non-null only for an `in_flight` record with a surviving intent, so a terminal
      record reads `null` even inside its intent's 24-hour retention window
- [x] `GET /api/v1/repos/:slug/package-uploads`: owner/admin repository-scoped read,
      `repo:read` for API keys (the id-addressed endpoints keep `package:upload`),
      standard paginated envelope, `outcome` filter validation, decimal-string
      `declared_size`/`final_size`, `user_email` serialized but never `user_id`,
      `intent_id` always the stored snapshot (never nulled after intent cleanup),
      404 masking on an inaccessible repository
- [x] Repository detail LiveView: Upload History section for managers only, 25 per page
      with the page and the `outcome` filter in the URL, header in-flight count pill
      linking to the `in_flight` filter, status badges, succeeded NEVRA and package
      link, sanitized failure code and reason, initiator-only cancel action, upload-page
      link (`?intent=`) only on the viewer's own in-flight rows, section omitted when
      the repository has no records
- [x] Upload page `?intent=<id>` reattach: patched into the URL on intent creation;
      resumes `queued`/`processing`/`preview_ready` for the initiator, shows
      `awaiting_upload` as an unfinished transfer with cancel only, and renders the
      standard 404 for any other id (other user, other repository, terminal, cleaned
      up, malformed); `intent` is the route's only documented query parameter
- [x] Admin Uploads view (web-only): instance-wide read-only listing with `repository`,
      `initiator`, and `outcome` filters and the page in the URL, 25 per page, live
      status via the same left join, no auto-refresh, Upload History link only on a
      live `repository_id` match, admin-only like the other admin views
- [x] Five-second refresh timer driven by the repository-wide in-flight count, not the
      current page's rows, so a stuck upload past page one keeps refreshing; internal
      message consumes no rate-limit bucket
- [x] Audit: add `repository_id`, `repository_slug`, `intent_id`, `upload_record_id`,
      and `original_filename` to every `package.upload*` event so terminal events are
      self-sufficient; add the currently missing expiry event — `package.upload` with
      `result: "expired"` targeting the intent — from both expiry paths (overdue
      completion, and the 15-minute waiting-state sweep with null actor fields)
- [x] Authorization tests across anonymous, unrelated user, collaborator, non-initiating
      owner, non-initiating admin, and initiating user on all three surfaces, plus the
      scope split: a `repo:read`-only key lists records, a `package:upload`-only key
      does not but still reads its own intent by id; the upload page 404s a
      `?intent=` of another user, another repository, or a terminal intent
- [x] Durability tests: record survives intent cleanup, package deletion, repository
      deletion, and initiator account deletion; never left `in_flight` after its intent
      is gone; exactly one terminal write under a replayed or racing worker; a terminal
      record reports `live_status` null while its intent is still retained; an
      orphaned `in_flight` record renders as `Unknown` with no cancel action and
      reconciles to `canceled` on the next sweep; a record deleted with its repository
      remains listed in the admin view with no repository link; backfilled records
      carry the migration time in `inserted_at` and the intent time in `started_at`
- [x] Tests asserting no `upload`, `staging_path`, `staging_version_id`, `lease_token`,
      or `preview_metadata` field appears in any listing row, and that refresh/complete/
      cancel remain initiator-only 404-masked

## Cross-cutting requirements to keep in every phase

- Background Retry Policy for every durable job (Architecture)
- Global lock order for final mutation transactions (Storage Reservations)
- Audit events written in-transaction with their action (Audit Events)
- 404 masking and 401/403 discipline on every new route (API Contract Details)
- Decimal-string bigints on every new JSON field (API Contract Details)
