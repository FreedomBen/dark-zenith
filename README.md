# Dark Zenith

Dark Zenith is an Elixir/Phoenix application that serves fully-functional RPM (dnf)
package repositories. Phoenix renders all web pages (LiveView) and repository metadata
(`repomd.xml`, `primary.xml.gz`, …); RPM files live in Backblaze B2 and are served to
clients via time-limited signed URLs, so the app server never streams RPM bytes.

The product and architecture contract is `DESIGN.md`. Implementation progress is
tracked in `IMPLEMENTATION_PLAN.md`.

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

Then:

```sh
mix setup        # deps, database, migrations, assets
mix phx.server   # http://localhost:4100 (override with PORT)
mix test         # ExUnit suite
mix precommit    # warnings-as-errors compile, unused-deps check, format, test
```

## Full offline stack (podman compose)

`compose.yaml` runs the released app (built from `Containerfile`) together with
PostgreSQL and MinIO, with MinIO standing in for Backblaze B2 — no network or
cloud credentials needed:

```sh
podman compose up -d --build
```

| Service    | Where                                                            |
| ---------- | ---------------------------------------------------------------- |
| App        | http://localhost:4200 (`admin@example.com` / `darkzenith-admin-dev`) |
| MinIO S3   | http://localhost:9000 (`minioadmin` / `minioadmin`; console on 9001) |
| PostgreSQL | 127.0.0.1:55433                                                  |

This stack is independent of the `dark-zenith-pg` container above (its own
database on 55433, its own volumes) so it can run alongside `mix phx.server`.
`podman compose down` stops it; add `-v` to also discard its data.

## License

AGPL-3.0-or-later — see `LICENSE`.
