# Dark Zenith production image (DESIGN.md: Deployment).
#
# Fedora is the base because upload verification requires RPM 6.0+
# (rpmkeys), and GPG key upload additionally uses rpmsign and gpg.
FROM fedora:44 AS build

# elixir (not the erlang metapackage, whose hard deps include the wx/GTK
# desktop stack) pulls exactly the erlang subpackages the build needs;
# gcc/make compile NIF dependencies (bcrypt_elixir). Weak deps stay off.
RUN dnf install -y --setopt=install_weak_deps=False elixir erlang-xmerl git gcc make && dnf clean all

ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib
# Compile before bundling: the compiler extracts colocated hooks/CSS into
# _build, which assets.deploy resolves via the phoenix-colocated import.
RUN mix compile && mix assets.deploy && mix release

FROM fedora:44 AS app

# rpm/rpmkeys verify every upload; rpm-sign and gnupg2 back GPG key
# validation and signing. These tools process attacker-supplied material:
# run the container unprivileged with a tmpfs RPM_UPLOAD_TMPDIR.
RUN dnf install -y --setopt=install_weak_deps=False rpm rpm-sign gnupg2 ncurses-libs openssl-libs libstdc++ util-linux procps-ng && dnf clean all

RUN useradd --system --home /app --shell /sbin/nologin darkzenith
WORKDIR /app
USER darkzenith

COPY --from=build --chown=darkzenith:darkzenith /app/_build/prod/rel/dark_zenith ./

ENV HOME=/app \
    LANG=C.UTF-8 \
    RPM_UPLOAD_TMPDIR=/tmp/dark-zenith

EXPOSE 4000
CMD ["bin/dark_zenith", "start"]
