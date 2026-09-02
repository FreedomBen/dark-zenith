# Dark Zenith

Dark Zenith is an Elixir/Phoenix application that serves fully-functional RPM (dnf)
package repositories. Phoenix renders all web pages (LiveView) and repository metadata
(`repomd.xml`, `primary.xml.gz`, …); RPM files live in Backblaze B2 and are served to
clients via time-limited signed URLs, so the app server never streams RPM bytes.

The product and architecture contract is `docs/DESIGN.md`. Implementation progress is
tracked in `docs/IMPLEMENTATION_PLAN.md`. The web UI's visual design (identity, theming,
layout, components) is specified in `docs/DESIGN_UI.md`.

## Development setup

Requirements: Elixir 1.19 / Erlang 28 (see `.tool-versions`) and podman (or any
PostgreSQL 18 reachable at `127.0.0.1:55432`).

Create the dev/test database container once:

```sh
podman run -d --name dark-zenith-pg \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_USER=postgres \
  -v dark-zenith-pgdata:/var/lib/postgresql \
  -p 127.0.0.1:55432:5432 docker.io/library/postgres:18
```

On later boots just `podman start dark-zenith-pg`.

The test configuration connects to that container by default; `PGHOST`,
`PGPORT`, `PGUSER`, and `PGPASSWORD` point it elsewhere (CI does this).

Then:

```sh
mix setup        # deps, database, migrations, assets
mix phx.server   # http://localhost:4100 (override with PORT)
mix test         # ExUnit suite
mix precommit    # warnings-as-errors compile, unused-deps check, format, test
```

### Optional test tags

Some tests self-enable by host capability and are otherwise excluded (the
"Excluding tags" line at the start of a run says which):

- `:rpmsign` — real RPM signing; needs the `rpm-sign` package.
- `:fips` — the FIPS-mode profile; runs only when the kernel reports FIPS mode.
- `:container` — the end-to-end tests that serve the app and the in-memory
  bucket over real HTTP and run a real dnf5 in a fresh Fedora 44 container:
  `test/end_to_end/container_install_test.exs` (dnf5 adds the repository from
  its `dark-zenith.repo` link, installs the uploaded package with every other
  repository disabled, and runs it — public, private, and signed flows; the
  signed one needs `:rpmsign` too) and `test/end_to_end/live_install_check_test.exs`
  (runs `deploy/live_install_check.sh`, below, against the same listeners).
  Needs podman, jq, and the pulled image:

  ```sh
  podman pull registry.fedoraproject.org/fedora:44
  mix test --only container
  ```

## Full offline stack (podman compose)

`compose.yaml` runs the released app (built from `Containerfile`) together with
PostgreSQL and MinIO, with MinIO standing in for Backblaze B2 — no network or
cloud credentials needed:

```sh
podman compose up -d --build
```

| Service    | Where                                                                |
| ---------- | -------------------------------------------------------------------- |
| App        | http://localhost:4200 (`admin@example.com` / `darkzenith-admin-dev`)     |
| MinIO S3   | http://localhost:9000 (`minioadmin` / `minioadmin`; console on 9001)     |
| PostgreSQL | 127.0.0.1:55433                                                      |

By default everything binds to `127.0.0.1`. To use the stack from other
machines (browser, API, and `dnf` installs), set `PHX_HOST` to this machine's
LAN IP address when starting it:

```sh
PHX_HOST=192.168.1.5 podman compose up -d --build
```

The app and MinIO S3 ports then bind to that address instead of localhost
(browse via the LAN IP from this machine too), and generated URLs, presigned
MinIO URLs, and the websocket origin all use it. Anyone on the network can
reach the stack's fixed development credentials in this mode, so keep the
default on untrusted networks.

This stack is independent of the `dark-zenith-pg` container above (its own
database on 55433, its own volumes) so it can run alongside `mix phx.server`.
`podman compose down` stops it; add `-v` to also discard its data.

With the stack up, prove it serves installable repositories to a real dnf5:

```sh
deploy/live_install_check.sh http://localhost:4200   # or http://<PHX_HOST>:4200
```

It logs in as the bootstrap admin, creates a repository per flow (public,
private, signed), uploads the fixture package through the real presigned MinIO
PUT, waits for processing and metadata, runs `deploy/dnf_client_check.sh` in a
fresh Fedora 44 container against each, and deletes what it created. The same
command works against a staging URL with `DZ_CHECK_EMAIL`/`DZ_CHECK_PASSWORD`
or `DZ_CHECK_TOKEN`; its header lists the options. Needs curl, jq, and podman.

`podman compose` delegates to whichever compose provider is installed. With
Docker Compose as the provider, `up --build` recreates the app container
whenever its image changed. The Python `podman-compose` only restarts the
existing container, so add `--force-recreate` after a rebuild or the stack
keeps running the old image (and never applies its new migrations). The tmpfs
at `/tmp/dark-zenith` needs the explicit `mode=1777` set in `compose.yaml`:
without it a restarted container remounts the directory root-owned, the boot
checks fail, and every upload would stall in `processing`.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests:

- **test** — the steps of `mix precommit` (with `deps.unlock --check-unused` and
  `format --check-formatted`, which never rewrite files) against a PostgreSQL 18
  service. It runs inside a Fedora 44 container with the packages the release
  image installs, because the suite verifies uploads with `rpmkeys` from RPM 6,
  signs with `rpmsign`, and drives `gpg`, none of which Ubuntu runners provide.
  That is Fedora's Elixir 1.19.5 on Erlang/OTP 26 — the release toolchain —
  rather than the OTP 28 in `.tool-versions`. The `:container` tests need
  podman and are excluded there, as on any host without it.
- **shellcheck** — `deploy/*.sh`.
- **image** — builds the `Containerfile`.

## License

AGPL-3.0-or-later — see `LICENSE`.
