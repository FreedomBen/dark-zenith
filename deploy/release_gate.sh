#!/usr/bin/env bash
# Release-gate check (DESIGN.md: Deployment; Phase 16): runs the in-app
# boot checks and exercises a live instance with real dnf clients.
#
# Usage: deploy/release_gate.sh <base-url> [public-repo-slug]
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

check_client() {
  local client="$1"
  if ! command -v "${client}" >/dev/null; then
    echo "    ${client} not installed; skipping"
    return 0
  fi

  local cache
  cache="$(mktemp -d)"
  echo "==> ${client} makecache against ${BASE_URL}/repos/${SLUG}/"
  "${client}" --setopt=cachedir="${cache}" \
    --repofrompath="dz-gate,${BASE_URL}/repos/${SLUG}/" \
    --repo=dz-gate --setopt=dz-gate.gpgcheck=0 makecache
  rm -rf "${cache}"
}

check_client dnf5
check_client dnf

echo "release gate passed"
