#!/usr/bin/env bash
# Release-gate check (DESIGN.md: Deployment; Phase 16): runs the in-app
# boot checks and exercises a live instance with real dnf clients across
# the public/private and unsigned/signed flows the spec gates releases on.
#
# Usage:
#   deploy/release_gate.sh <base-url> [public-slug]
#
# Optional environment for the additional flows:
#   DZ_GATE_SIGNED_SLUG    public slug whose metadata is GPG-signed
#                          (repo_gpgcheck=1 verification via RPM-GPG-KEY)
#   DZ_GATE_PRIVATE_SLUG   private slug reachable with credentials
#   DZ_GATE_USERNAME       Basic username for the private flow ("api" for
#                          API keys, or an account email)
#   DZ_GATE_PASSWORD       Basic password (API key / session token)
#   DZ_GATE_INSTALL_PKG    package name to resolve (repoquery) after
#                          makecache in every flow, proving primary.xml
#                          parses end to end
set -euo pipefail

BASE_URL="${1:?usage: release_gate.sh <base-url> [slug]}"
SLUG="${2:-e2e}"

echo "==> in-app boot checks (requires the release binary on this host)"
if [ -x "bin/dark_zenith" ]; then
  bin/dark_zenith eval 'DarkZenith.BootCheck.run!()'
else
  echo "    (skipped: run from the release root to include them)"
fi

echo "==> health probe"
curl -fsS "${BASE_URL}/health" | grep -qx ok

# check_client <client> <slug> <label> [extra repo options...]
check_client() {
  local client="$1" slug="$2" label="$3"
  shift 3

  if ! command -v "${client}" >/dev/null; then
    echo "    ${client} not installed; skipping ${label}"
    return 0
  fi

  local cache
  cache="$(mktemp -d)"
  echo "==> ${client} makecache (${label}) against ${BASE_URL}/repos/${slug}/"

  local args=(
    --setopt=cachedir="${cache}"
    --repofrompath="dz-gate,${BASE_URL}/repos/${slug}/"
    --repo=dz-gate
  )

  local opt
  for opt in "$@"; do
    args+=("--setopt=dz-gate.${opt}")
  done

  "${client}" "${args[@]}" makecache

  if [ -n "${DZ_GATE_INSTALL_PKG:-}" ]; then
    echo "==> ${client} repoquery ${DZ_GATE_INSTALL_PKG} (${label})"
    "${client}" "${args[@]}" repoquery "${DZ_GATE_INSTALL_PKG}" | grep -q .
  fi

  rm -rf "${cache}"
}

for client in dnf5 dnf; do
  # Unsigned public flow.
  check_client "${client}" "${SLUG}" "public unsigned" gpgcheck=0

  # Signed public flow: repo_gpgcheck makes the client fetch RPM-GPG-KEY
  # and verify repomd.xml.asc.
  if [ -n "${DZ_GATE_SIGNED_SLUG:-}" ]; then
    check_client "${client}" "${DZ_GATE_SIGNED_SLUG}" "public signed" \
      gpgcheck=0 repo_gpgcheck=1 \
      gpgkey="${BASE_URL}/repos/${DZ_GATE_SIGNED_SLUG}/RPM-GPG-KEY"
  fi

  # Private flow: Basic credentials via librepo username/password options.
  if [ -n "${DZ_GATE_PRIVATE_SLUG:-}" ]; then
    : "${DZ_GATE_USERNAME:?DZ_GATE_PRIVATE_SLUG requires DZ_GATE_USERNAME}"
    : "${DZ_GATE_PASSWORD:?DZ_GATE_PRIVATE_SLUG requires DZ_GATE_PASSWORD}"
    check_client "${client}" "${DZ_GATE_PRIVATE_SLUG}" "private" \
      gpgcheck=0 \
      username="${DZ_GATE_USERNAME}" password="${DZ_GATE_PASSWORD}"
  fi
done

echo "release gate passed"
