# Dark Zenith production image (DESIGN.md: Deployment).
#
# Fedora is the base because upload verification requires RPM 6.0+
# (rpmkeys), and GPG key upload additionally uses rpmsign and gpg.
FROM fedora:43 AS build

RUN dnf install -y elixir erlang git rpm-sign gnupg2 && dnf clean all

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib
RUN mix assets.deploy && mix compile && mix release

FROM fedora:43 AS app

# rpm/rpmkeys verify every upload; rpm-sign and gnupg2 back GPG key
# validation and signing. These tools process attacker-supplied material:
# run the container unprivileged with a tmpfs RPM_UPLOAD_TMPDIR.
RUN dnf install -y rpm rpm-sign gnupg2 ncurses-libs openssl-libs libstdc++ && dnf clean all

RUN useradd --system --home /app --shell /sbin/nologin darkzenith
WORKDIR /app
USER darkzenith

COPY --from=build --chown=darkzenith:darkzenith /app/_build/prod/rel/dark_zenith ./

ENV HOME=/app \
    RPM_UPLOAD_TMPDIR=/tmp/dark-zenith

EXPOSE 4000
CMD ["bin/dark_zenith", "start"]
