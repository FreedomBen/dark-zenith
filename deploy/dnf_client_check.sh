#!/usr/bin/env bash
# Exercises a Dark Zenith repository the way a freshly installed dnf5 machine
# would (DESIGN.md: .repo File Endpoint; Private Repository Authentication):
# adds the repository from its dark-zenith.repo link with the command the
# repository page shows, installs a package from it with every other
# repository disabled, confirms dnf took the package from that repository,
# and runs a verification command against what was installed.
#
# It is meant to run as root inside a throwaway Fedora container and needs no
# network beyond the Dark Zenith instance (and its object storage) itself.
# test/end_to_end/container_install_test.exs feeds it to `podman run`; a
# release-gate run can do the same against a staging deployment:
#
#   podman run --rm --network=host registry.fedoraproject.org/fedora:44 \
#     bash -c "$(cat deploy/dnf_client_check.sh)" -- \
#     https://staging.example.com/repos/paladin/dark-zenith.repo paladin
#
# Usage:
#   dnf_client_check.sh <repo-file-url> <package> [verify-command]
#
# The verification command runs through `bash -c` after the install and
# defaults to `<package> --version`.
#
# Environment:
#   DZ_CLIENT_PASSWORD   Private repository: the API key (or session token).
#                        `config-manager` cannot send credentials, so the
#                        .repo file is fetched with them, its placeholders are
#                        filled in, and it is saved with mode 600 by hand,
#                        exactly as the private-repository instructions say.
#   DZ_CLIENT_USERNAME   Basic username for the private flow (default: token,
#                        the username API keys use).
#
# Every step prints the command it runs. The final line `dnf_client_check: ok`
# marks success; any failure stops the script with a non-zero status.
set -euo pipefail

usage="usage: dnf_client_check.sh <repo-file-url> <package> [verify-command]"
REPO_FILE_URL="${1:?${usage}}"
PACKAGE="${2:?${usage}}"
VERIFY="${3:-${PACKAGE} --version}"

# .../repos/<slug>/dark-zenith.repo declares the repository id dark-zenith-<slug>.
SLUG="$(basename "$(dirname "${REPO_FILE_URL}")")"
REPO_ID="dark-zenith-${SLUG}"

run() {
  echo "+ $*"
  "$@"
}

if [ -n "${DZ_CLIENT_PASSWORD:-}" ]; then
  username="${DZ_CLIENT_USERNAME:-token}"
  repo_file="/etc/yum.repos.d/${REPO_ID}.repo"

  echo "+ curl --fail --user ${username}:<redacted> ${REPO_FILE_URL} > ${repo_file}"
  while IFS= read -r line; do
    case "${line}" in
      "username=token") printf 'username=%s\n' "${username}" ;;
      "password=<api-key>") printf 'password=%s\n' "${DZ_CLIENT_PASSWORD}" ;;
      *) printf '%s\n' "${line}" ;;
    esac
  done < <(curl --fail --silent --show-error --user "${username}:${DZ_CLIENT_PASSWORD}" "${REPO_FILE_URL}") \
    > "${repo_file}"

  run chmod 600 "${repo_file}"
else
  run dnf5 config-manager addrepo --from-repofile="${REPO_FILE_URL}"
fi

# --repo leaves only this repository enabled: the base image's Fedora
# repositories are never contacted, so the check works offline and proves
# the package resolves from Dark Zenith alone.
run dnf5 --assumeyes --repo "${REPO_ID}" makecache
run dnf5 --assumeyes --repo "${REPO_ID}" install "${PACKAGE}"
run rpm -q "${PACKAGE}"

from_repo="$(dnf5 --repo "${REPO_ID}" repoquery --installed --queryformat '%{from_repo}\n' "${PACKAGE}")"
echo "installed from: ${from_repo}"
[ "${from_repo}" = "${REPO_ID}" ]

echo "+ ${VERIFY}"
bash -c "${VERIFY}"

echo "dnf_client_check: ok"
