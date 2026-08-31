# Design Variations

Deviations found by reviewing the codebase against `DESIGN.md`. Each entry names the
spec rule, what the code actually does, and why it matters. Work through them with the
checklist at the end.

**Status: all items resolved** (2026-08-31). Every checklist entry below is fixed in
code with test coverage; `mix test` reports 882 tests, 0 failures (3 excluded: the
`:rpmsign`-tagged test, which self-enables when `rpmsign` is installed, and the new
two-test `:fips` profile, which self-enables on a FIPS-mode host). Resolution notes
for judgment calls are inline in the checklist. One additional deviation (K1) was
found and fixed while resolving the original list.

**Review scope**: all of `DESIGN.md` (1 399 lines) against `lib/`, `config/`,
`priv/repo/migrations/`, `assets/`, and `test/`.

**Baseline**: `mix test` — 819 tests, 0 failures (1 excluded: the `:rpmsign`-tagged test,
which self-enables when `rpmsign` is installed).

**Overall**: the implementation tracks the spec closely. Nothing found contradicts the
core architecture — direct-to-B2 uploads, exact-version addressing, durable lease-fenced
workers, the metadata revision/cache contract, the slug-reservation authority, the
signing-transition state machines, and the repodata encoders all match. The variations
below are gaps at the edges: unwired configuration, a few missing response headers,
some HTTP contract details, two database invariants the spec asks for explicitly, and
one storage-quota accounting hole.

## Summary

| ID  | Area                | Variation                                                              | Severity |
| --- | ------------------- | ---------------------------------------------------------------------- | -------- |
| A1  | Configuration       | `MAX_USER_REPOSITORIES` env var never read                              | Medium   |
| A2  | Configuration       | `RPM_PROCESSING_CONCURRENCY` env var never read                         | Medium   |
| A3  | Configuration       | `RPMKEYS_PATH` / `RPMSIGN_PATH` / `GPG_PATH` env vars never read        | Medium   |
| A4  | Configuration       | `PHX_HOST` defaults to `example.com`, not `localhost`                   | Low      |
| A5  | Configuration       | `RPM_TOOL_TIMEOUT_SECONDS` range not enforced                           | Low      |
| A6  | Configuration       | `MAX_REPOSITORY_PACKAGES` upper bound not enforced                      | Low      |
| B1  | Response headers    | Web UI and `/api/v1` responses do not send `Cache-Control: no-store`    | Medium   |
| B2  | Response headers    | `X-Content-Type-Options: nosniff` only on the browser pipeline          | Medium   |
| B3  | Response headers    | `Vary` missing on repository-serving `429` responses                    | Low      |
| C1  | Upload intent API   | Cancelling an already terminal intent returns `409`, not `204`          | Medium   |
| C2  | Upload intent API   | Idempotent completion always returns `202`, never `200`                 | Low      |
| C3  | Upload intent API   | `version_id` control characters not rejected                            | Low      |
| C4  | Upload intent API   | Decimal-string `size` accepts leading zeros                             | Low      |
| D1  | GPG key API         | Per-key-field 1 MiB cap not enforced (`413` unreachable)                | Low      |
| E1  | Database invariants | No `phase_next_attempt_at` check constraint on signing transitions      | Medium   |
| E2  | Database invariants | No all-or-none check on prepared candidate key fields                   | Medium   |
| F1  | Background work     | Expired-reservation cleanup ignores nonterminal signing items           | **High** |
| F2  | Background work     | Pending signing items never renew their linked reservation              | **High** |
| F3  | Background work     | Sweep does not rebuild lost item jobs for enable transitions            | Medium   |
| F4  | Background work     | Provider `Retry-After` HTTP-date form ignored; email-only               | Low      |
| G1  | Audit               | `ip` populated on only 4 of 42 audit call sites                         | Medium   |
| G2  | Audit               | API-key audit rows written outside the action's transaction             | Low      |
| H1  | RPM signing         | `rpmsign --resign` always used; `--addsign` path absent                 | Low      |
| H2  | Upload processing   | Web preview skips advisory checks and signs prematurely                 | Medium   |
| I1  | Web UI              | Private-repo GPG key import instructions cannot work                    | Medium   |
| I2  | Web UI              | No API-key creation prompt / one-time snippet on repository detail      | Low      |
| J1  | Tests               | No FIPS-mode test profile                                               | Medium   |
| K1  | User lifecycle      | User deletion left unresolved signing transitions uncanceled            | Medium   |

---

## A. Configuration

### A1 — `MAX_USER_REPOSITORIES` is never read from the environment

*Spec*: Configuration table — `MAX_USER_REPOSITORIES`, default `100`, "must be a
non-negative integer, and `0` disables the limit".

`config/runtime.exs` reads every other documented limit but not this one.
`lib/dark_zenith/repositories.ex:518` reads the `:max_user_repositories` application key,
which nothing ever sets, so the compiled-in `100` is the only value a production
deployment can have. The `0`-disables-the-limit path is unreachable.

### A2 — `RPM_PROCESSING_CONCURRENCY` is never read from the environment

*Spec*: Configuration table — default `2`, "must be an integer from `1` through `64`".

`config/config.exs:37` hardcodes `rpm_processing: 2` and its comment claims the value is
"overridden at runtime by `RPM_PROCESSING_CONCURRENCY`". `config/runtime.exs` contains no
such override. Operators cannot tune RPM processing throughput.

### A3 — `RPMKEYS_PATH`, `RPMSIGN_PATH`, and `GPG_PATH` are never read from the environment

*Spec*: Configuration table — defaults `rpmkeys`, `rpmsign`, `gpg`; "`RPMKEYS_PATH` is
required in every deployment because every upload is verified".

The code consistently reads `:rpmkeys_path` / `:rpmsign_path` / `:gpg_path` from the
application environment (`boot_check.ex:65`, `gpg.ex:158`, `signing/gpg.ex:75-76`,
`gpg/rpm_compat.ex:12-13`, `workers/upload_processing.ex:231`,
`workers/signing_item.ex:134`) with bare-name defaults, but nothing in `config/` sets
those keys from the environment. A deployment whose tools live outside `PATH`, or that
needs to pin a specific RPM 6 build, has no supported way to say so.

### A4 — `PHX_HOST` default differs

*Spec*: default `localhost`. `config/runtime.exs:265` uses `"example.com"`. This is the
generated Phoenix default that was never reconciled with the spec; it affects generated
`baseurl`/`gpgkey` values and the B2 CORS origin when `PHX_HOST` is unset.

### A5 — `RPM_TOOL_TIMEOUT_SECONDS` range not enforced

*Spec*: "must be an integer from `60` through `7200`". `config/runtime.exs:152` accepts
any integer `>= 1`, so a 1-second tool deadline boots cleanly and fails every signing
and verification operation.

### A6 — `MAX_REPOSITORY_PACKAGES` upper bound not enforced

*Spec*: "must be an integer from `1` through `1000000`, an upper bound that also caps the
single-transaction work of repository-local signing enablement". `config/runtime.exs:128`
accepts any integer `>= 1`. The bound exists to keep `enable_rpm_signing` a single atomic
commit; without it an operator can configure a value that makes that transaction
unbounded.

## B. Response headers

### B1 — Web UI and `/api/v1` responses do not send `Cache-Control: no-store`

*Spec*: Caching headers — "Web UI and `/api/v1/...` responses send `Cache-Control:
no-store`."

Only `repo_serving_controller.ex` and the rate limiter's `429` path set `cache-control`
anywhere in `lib/`. The `:browser` and `:api` router pipelines set none, so authenticated
HTML pages and JSON API responses are left to intermediary defaults.

### B2 — `X-Content-Type-Options: nosniff` only on the browser pipeline

*Spec*: Security Considerations — "Responses set `X-Content-Type-Options: nosniff`".

`put_secure_browser_headers` (which supplies the header) is plugged only in the
`:browser` pipeline (`router.ex:12`). `/api/v1` and repository-serving responses carry no
`nosniff`.

### B3 — `Vary` missing on repository-serving `429` responses

*Spec*: Caching headers — "Every repository-serving response also sends `Vary:
Authorization, Cookie`."

`put_vary_header` is a controller plug in `repo_serving_controller.ex`, but the
`RateLimiter` pipeline plug halts before the controller runs, so a rate-limited
repository-serving response omits `Vary`.

## C. Upload intent API contract

### C1 — Cancelling an already terminal intent returns `409` instead of `204`

*Spec*: `DELETE /api/v1/repos/:slug/package-uploads/:id` — "Repeating cancellation or
deleting an already failed/expired intent is an idempotent `204`; a succeeded intent
returns `409 conflict_upload_state`."

`Uploads.cancel_intent/2` returns `{:error, :upload_state}` for every status outside
`awaiting_upload`/`queued`/`processing`/`preview_ready`, and
`package_upload_controller.ex:118` maps that to `409`. A client retrying a cancellation,
or cancelling an intent that has since failed or expired, gets a conflict rather than the
documented idempotent success.

### C2 — Idempotent completion always returns `202`

*Spec*: `POST .../complete` — "the already accepted same generation/version returns
idempotently without contacting B2 (`202` while queued/processing and `200` once
`preview_ready`, `succeeded`, or `failed`)".

`package_upload_controller.ex:94` unconditionally sets `202` and `Retry-After: 2` for
every success, including the replay of an intent that has already reached
`preview_ready`, `succeeded`, or `failed`. The durable-state classification is correct
(`Uploads.classify_completion/3`); only the status mapping is.

### C3 — `version_id` control characters not rejected

*Spec*: "`version_id` is treated as an opaque non-empty string of at most 1 024 bytes with
no control characters."

`Uploads.validate_version_id/1` (`uploads.ex:592`) checks only `is_binary/1` and the
1…1024 byte length.

### C4 — Decimal-string `size` accepts leading zeros

*Spec*: API Contract Details — "A non-negative value is exactly `"0"` or matches
`[1-9][0-9]*`; signs, decimals, exponent notation, whitespace, leading zeros, and JSON
numeric values are rejected."

`package_upload_controller.ex:136` uses `Integer.parse/1`, so `"007"` parses as `7` and is
accepted. Signs, decimals, whitespace, and JSON numbers are correctly rejected — only the
leading-zero rule is missing.

## D. GPG key API

### D1 — Per-key-field 1 MiB cap not enforced

*Spec*: `PUT /api/v1/gpg_key` and `POST /api/v1/gpg_key/revocation` — "Each key field is
capped at 1 048 576 bytes; larger key uploads are rejected with `413 payload_too_large`."

`gpg_key_controller.ex:349` (`field_value/2`) reads the field with no size check. Only the
endpoint-wide 2 162 688-byte multipart cap applies, so a 1.5 MiB `public_key` inside a
2 MiB body reaches key validation instead of being rejected with `413`.

## E. Database invariants

The spec names these explicitly as *database checks*; the code enforces the equivalent
rules only through its own write paths. Nothing writes an invalid row today, but the
stated last line of defense is absent.

### E1 — No `phase_next_attempt_at` check constraint

*Spec*: Signing Transitions — "Database checks require `phase_next_attempt_at` for
scheduled `preparing`, `activating`, and `finalizing` phases and null it during active
item work, failure, and terminal states."

`priv/repo/migrations/20260831025528_create_signing_transitions.exs` implements the
`failed` (resume + error) and terminal (`completed_at`, cleared resume/scheduling) checks,
but nothing about `phase_next_attempt_at` outside the terminal case. There is also no
Ecto changeset for `SigningTransitions.Transition` (`signing_transitions/schemas.ex`
defines the schema only), so no application-layer validation covers it either.

### E2 — No all-or-none check on prepared candidate key fields

*Spec*: Signing Transitions — "An all-or-none check requires the prepared private key,
public key, primary fingerprint, and signing fingerprint before a replacement's key-swap
commit … and requires them all null in every other phase/kind; `prepared_expires_at` …
must be null outside those pre-swap states."

No such constraint exists in the migration. Compare `users_gpg_key_fields_together` in
`20260830213937_extend_users_with_admin_storage_gpg.exs`, which does implement the
equivalent rule for the user row — the transition row's version was not written.

## F. Background work

### F1 — Expired-reservation cleanup ignores nonterminal signing items

*Spec*: Storage Reservations — "The hourly reservation cleanup removes an expired row only
after confirming that no active upload intent **or nonterminal signing item** links it."

`Storage.cleanup_expired/0` (`storage.ex:113`) and `reclaim_expired_unlinked/1`
(`storage.ex:127`) exclude only rows referenced by an `Intent`. They do not consult
`signing_transition_items`. Because that table's `reservation_id` FK is
`on_delete: :nilify_all`, deleting the reservation silently clears the item's link, and
the item's `pending` check constraint does not require a reservation — so the loss is
invisible. The re-sign byte delta then leaves the owner's quota accounting.

The docstring on `cleanup_expired/0` asserts the guard exists ("nonterminal signing items
join the guard with the signing phase"), so this reads as an intended-but-unwritten join
rather than a deliberate simplification.

### F2 — Pending signing items never renew their linked reservation

*Spec*: Storage Reservations — "Pending and executing items renew linked reservations two
hours ahead."

`Storage.renew_reservation/1` is called from exactly five places
(`uploads.ex:326`, `uploads.ex:456`, `signing_transitions.ex:333`,
`upload_processing.ex:117`), and the signing-side call is inside `claim_item/1` — an
*executing* transition. Nothing renews a `pending` item's reservation. An item that stays
pending (parent transition in another phase, a lost Oban job per F3, or an admin-paused
`failed` transition being reset) crosses its two-hour lease and, together with F1, has its
reservation deleted.

F1 and F2 compound: F2 lets the reservation expire, F1 then deletes it.

### F3 — Sweep does not rebuild lost item jobs for repository-local enable transitions

*Spec*: Signing Transition Items — "the sweep repairs a missing Oban row"; Signing
Transition Repositories — "Sweepers reconstruct missing deferred jobs".

`SigningTransitions.sweep/0` (`signing_transitions.ex:611`) requeues expired *executing*
leases and evaluates completion, then delegates to `UserWide.sweep/0`, which calls
`enqueue_item_jobs/1` for due pending items — but only for transitions where
`kind != "enable_rpm_signing"`. A repository-local enable transition whose item job row is
lost (Oban pruning, a discarded row, a failed insert) has no path back: the item stays
`pending` and due forever, and `rpm_signing_state` stays `signing` with `gpgcheck=0`.

### F4 — Provider `Retry-After` handling is delta-seconds only, and email only

*Spec*: Background Retry Policy — "a syntactically valid `Retry-After` delta-seconds value
**or future HTTP-date** … `provider_delay` is the positive integer delta or
`ceil(date - now)` respectively".

`workers/email_delivery.ex:57` (`parse_delay/1`) parses only integers; an HTTP-date value
is discarded. The policy is also implemented only for mail delivery — B2 and other
external HTTP errors never consult a returned `Retry-After`.

## G. Audit

### G1 — `ip` is populated on 4 of 42 audit call sites

*Spec*: Audit Events — "`ip` | Client IP as resolved by the client IP detection rules;
null for system events."

Only `api/v1/auth_controller.ex:27,40` and `api/v1/api_key_controller.ex:43,69` pass
`ip:`. Every other audited action — web login, registration, password change/reset, email
change, repository create/update/delete, package upload and delete, upload-intent
lifecycle, collaborator and invitation events, all GPG key operations, admin-flag changes,
user deletion, slug releases — records `null`. `DarkZenith.ClientIp.resolve/1` exists and
works; it is simply not threaded through the context functions that write the events.

### G2 — API-key audit rows are written outside the action's transaction

*Spec*: Audit Events — "Rows are written in the same database transaction as the action
they record when one exists."

`api_key_controller.ex:40` and `:66` call `Audit.record!/2` after `Accounts.create_api_key/2`
and `Accounts.delete_api_key/2` have already committed. A crash between the two leaves the
key created or revoked with no audit row. Every other context writes its audit row inside
the transaction.

## H. RPM signing and upload processing

### H1 — `rpmsign --resign` is always used

*Spec*: RPM signing step 4 — "Unsigned RPMs are signed with `rpmsign --addsign`; RPMs that
already contain an OpenPGP package signature are signed with `rpmsign --resign` so the
existing package signature is replaced."

`signing/gpg.ex:99-111` always passes `--resign`, with the comment "`--resign` handles both
on RPM 6." That is very likely true for the supported toolchain, so the behavioural risk is
small — but it is a deliberate divergence from the written contract, and either the code or
the spec should say so. `gpg/rpm_compat.ex:45` (the per-key compatibility test) does use
`--addsign`, so the two paths disagree with each other as well.

### H2 — Web preview skips advisory checks and signs prematurely

*Spec*: Upload RPM — "The worker size-checks, validates, and parses the RPM using the normal
pipeline, **performs advisory duplicate and repository-metadata-limit checks**, stores the
extracted metadata on the intent, and changes it to `preview_ready`."

`workers/upload_processing.ex:158` (`continue/6`) routes a first web-preview pass straight
to `preview_transition/3`. The advisory duplicate and metadata-limit checks live in
`finalize/6`, which the preview pass never reaches — so a duplicate NEVRA or an
over-limit repository is not surfaced until *after* the user confirms.

Separately, `run/3` calls `signing_step/7` before `continue/6`, so a preview of an upload
to an RPM-signed repository runs a full `rpmsign` + `rpmkeys` verification cycle whose
output is then discarded and repeated after confirmation. The spec places signing in the
confirmed final pass. No correctness impact; it doubles the native-tool cost of every web
upload to a signed repository.

## I. Web interface

### I1 — Private-repository GPG key import instructions cannot work

*Spec*: Private Repository Authentication — "If a supported client release does not
propagate `username` and `password` to `gpgkey`, its generated setup instructions perform a
separate interactive `curl --fail --user token .../RPM-GPG-KEY | sudo rpmkeys --import -`
step that prompts for the API key."

`live/repository_live/show.ex:61` renders `sudo rpmkeys --import <url>` unconditionally
whenever `gpg_key_fingerprint` is set. For a private repository that URL requires
credentials, so the documented command returns `401` and the user has no working
instruction to import the key.

### I2 — No API-key creation prompt or one-time snippet on repository detail

*Spec*: Repository Detail — "Because the server stores only key hashes, it can never render
an existing key's plaintext; the one exception is key creation — when the user creates an
API key from this flow, the creation response may render the snippet with the just-created
plaintext key filled in, exactly once. If the user has no suitable API key, prompt them to
create one."

The private-repository block in `show.ex:38-44` renders the placeholder and the `chmod 600`
step but neither checks whether the user holds a suitable key nor links to key creation.
The one-time filled-in snippet is not implemented. (The "may render" half is optional; the
"prompt them to create one" half is not.)

## J. Tests

### J1 — No FIPS-mode test profile

*Spec*: GPG Signing — "FIPS-mode tests verify the same fail-closed behavior: an otherwise
allowlisted algorithm disabled by the deployment's crypto policy is rejected as unusable
with `422 validation_failed`". RPM Parsing — "The weak variants are rejected in normal and
FIPS-mode test profiles."

No `fips` tag, profile, or test exists anywhere in `test/`. The weak-digest variants are
covered (`test/dark_zenith/rpm/parser_test.exs:131-156`, synthesized by mutating the
bundled fixtures) but only in the normal profile.

## K. Found while resolving this list

### K1 — User deletion left unresolved signing transitions uncanceled

*Spec*: User Lifecycle — "Signing transitions the user owned, their repository
snapshots, and their items are likewise retained for audit: any transition still
`preparing`, `activating`, `active`, `finalizing`, or `failed` is marked `canceled`,
encrypted candidate fields are nulled, and linked reservations are released in the
deletion transaction … the transition's `user_id` is cleared through
`ON DELETE SET NULL`."

`Accounts.delete_user_checked/2` cleaned up upload intents and invitations but never
touched signing transitions: a nonterminal user-wide transition (reachable with zero
owned repositories — e.g. an `active`/`finalizing` removal, or a `failed` pre-swap
replacement) survived deletion nonterminal, keeping its encrypted candidate key
material, and any leftover item-linked reservation was reclaimed only by the FK
cascade rather than released in-transaction. Fixed:
`SigningTransitions.cancel_transitions_for_deleted_user!/1` runs in the deletion
transaction after the target user-row lock (global lock order; phase workers lock
user → transition the same way), cancelling each unresolved transition via
`cancel_transition!/1`, which nulls the candidate fields, cancels unfinished items,
and releases their reservations. Terminal transitions are retained untouched.

---

## Checklist

### Configuration
- [x] **A1** Wire `MAX_USER_REPOSITORIES` in `config/runtime.exs` (non-negative, `0` disables)
- [x] **A2** Wire `RPM_PROCESSING_CONCURRENCY` (1–64) into the Oban `rpm_processing` queue
- [x] **A3** Wire `RPMKEYS_PATH`, `RPMSIGN_PATH`, `GPG_PATH`
- [x] **A4** Change the `PHX_HOST` fallback to `localhost` (the spec kept its default)
- [x] **A5** Enforce `RPM_TOOL_TIMEOUT_SECONDS` ∈ 60…7200
- [x] **A6** Enforce `MAX_REPOSITORY_PACKAGES` ≤ 1 000 000

### Response headers
- [x] **B1** Send `Cache-Control: no-store` from the `:browser` and `:api` pipelines
- [x] **B2** Send `X-Content-Type-Options: nosniff` on `/api/v1` and repository-serving responses
- [x] **B3** Set `Vary: Authorization, Cookie` on repository-serving `429` responses (the
      header moved into the `:repo_serving` pipeline so halted responses carry it)

### Upload intent API contract
- [x] **C1** Return `204` when cancelling an already `canceled`/`failed`/`expired` intent; `409` only for `succeeded`
- [x] **C2** Return `200` (no `Retry-After`) for idempotent completion of `preview_ready`/`succeeded`/`failed`
- [x] **C3** Reject control characters in `version_id`
- [x] **C4** Enforce the canonical `"0"` / `[1-9][0-9]*` decimal-string form for `size`

### GPG key API
- [x] **D1** Enforce the per-field 1 048 576-byte cap on `public_key` / `private_key` with `413 payload_too_large`

### Database invariants
- [x] **E1** Add the `phase_next_attempt_at` check constraint to `signing_transitions`
- [x] **E2** Add the all-or-none prepared-candidate check constraint to `signing_transitions`

### Background work
- [x] **F1** Exclude reservations linked by nonterminal signing-transition items from expired-reservation cleanup (both `cleanup_expired/0` and `reclaim_expired_unlinked/1`)
- [x] **F2** Renew linked reservations for `pending` signing items, not only on claim (the
      60-second sweep renews every reservation linked by a pending or executing item)
- [x] **F3** Rebuild missing item jobs for repository-local `enable_rpm_signing` transitions in the 60-second sweep
- [x] **F4** Parse the HTTP-date form of provider `Retry-After`; consider applying the policy beyond mail delivery.
      *Resolution*: parsing (delta-seconds plus all three HTTP-date forms via
      `:httpd_util`) moved into `RetryPolicy.provider_delay/2` and is wired into email
      delivery. B2 deliberately keeps flattening every infrastructure failure to
      `:storage_unavailable` (its module contract); honoring a B2 `Retry-After` would
      mean threading header data through every storage error path for a header B2
      rarely sends, so that half stays as-is. Any future consumer can call the shared
      parser.

### Audit
- [x] **G1** Thread the resolved client IP through every user-initiated audited action.
      *Resolution*: a process-scoped audit context (`DarkZenithWeb.AuditContext` plug +
      `on_mount` hook, `ClientIp.resolve_peer/2` for sockets) supplies the default
      `ip` for `Audit.record!/2`, covering every context-function call site at once;
      workers never set it so system events stay null. The review's premise that web
      login "records null" understated the gap — web login wrote no audit event at
      all — so `auth.login`/`auth.login_failed` with `surface: "web"` were added.
- [x] **G2** Move the API-key create/revoke audit writes inside their transactions
      (deduplicating the parallel LiveView writes)

### RPM signing and upload processing
- [x] **H1** Use `--addsign` for unsigned input and `--resign` for already-signed input.
      The parser now records signature-header OpenPGP entries
      (`Metadata.openpgp_signed?`) and `sign_rpm/4` takes the parsed metadata;
      `rpm_compat.ex`'s `--addsign` on unsigned fixtures is now consistent.
- [x] **H2** Run the advisory duplicate and metadata-limit checks in the web-preview pass; skip signing until the confirmed final pass

### Web interface
- [x] **I1** Render the authenticated `curl --user token … | sudo rpmkeys --import -` variant for private repositories
- [x] **I2** Prompt for API-key creation on the repository detail page when the user has no suitable key
      (`Accounts.has_usable_api_key?/2`). The spec's optional one-time filled-in
      snippet ("may render") remains unimplemented.

### Tests
- [x] **J1** Add a FIPS-mode test profile covering weak-digest rejection and crypto-policy-disabled signing algorithms
      (`:fips` tag, self-enabled when `/proc/sys/crypto/fips_enabled` reads `1`)

### Found while resolving this list
- [x] **K1** Cancel the deleted user's unresolved signing transitions, null their
      candidate fields, and release linked reservations in the deletion transaction
