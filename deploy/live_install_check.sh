#!/usr/bin/env bash
# Live install check (DESIGN.md: Deployment; Phase 16): proves a running
# Dark Zenith instance serves an installable repository to a real dnf5. For
# each requested flow it creates a repository through the REST API, uploads a
# package through the real presigned PUT into object storage, waits for
# processing and metadata regeneration, and then runs
# deploy/dnf_client_check.sh in a fresh Fedora container that adds the
# repository from its dark-zenith.repo link, installs the package with every
# other repository disabled, and runs it. The repositories (and the API key
# the private flow needs) are deleted afterwards unless DZ_CHECK_KEEP=1.
#
# The container uses host networking: the served .repo baseurl and the
# presigned download URLs carry the instance's configured host, which
# podman's default network cannot reach when that host is this machine.
#
# Usage:
#   deploy/live_install_check.sh <base-url> [public|private|signed ...]
#
# Flows default to all three:
#   public    anonymous repository; dnf adds it with config-manager
#   private   repository visible only with credentials; the container saves
#             the .repo file with an API key the way the instructions say
#   signed    metadata and package signing with the account's GPG key, which
#             is generated (ed25519) only when the account has none; dnf
#             must import the served key and verify both
#
# Environment:
#   DZ_CHECK_EMAIL / DZ_CHECK_PASSWORD   account to log in as (default: the
#                                        compose stack's bootstrap admin,
#                                        admin@example.com / darkzenith-admin-dev)
#   DZ_CHECK_TOKEN     a session token or API key to use instead of logging
#                      in; an API key needs repo:create, repo:read,
#                      repo:delete, and package:upload, and doubles as the
#                      private flow's client credential
#   DZ_CHECK_RPM       package file to upload (default: the paladin fixture)
#   DZ_CHECK_PACKAGE   its package name (default: read with rpm -qp)
#   DZ_CHECK_VERIFY    command run in the container after the install
#                      (default: an encrypt/decrypt round trip for the fixture,
#                      otherwise the client check's own `<package> --version`)
#   DZ_CHECK_IMAGE     container image (default: registry.fedoraproject.org/fedora:44)
#   DZ_CHECK_KEEP=1    keep the repositories and API key for inspection
#
# Needs curl, jq, podman, and (unless DZ_CHECK_PACKAGE is set) rpm.
set -euo pipefail

usage="usage: live_install_check.sh <base-url> [public|private|signed ...]"
BASE_URL="${1:?${usage}}"
BASE_URL="${BASE_URL%/}"
shift
FLOWS=("$@")
[ "${#FLOWS[@]}" -gt 0 ] || FLOWS=(public private signed)

for flow in "${FLOWS[@]}"; do
  case "${flow}" in
    public | private | signed) ;;
    *) echo "${usage}" >&2; exit 2 ;;
  esac
done

for tool in curl jq podman; do
  command -v "${tool}" >/dev/null || { echo "${tool} is required" >&2; exit 2; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_CHECK="${SCRIPT_DIR}/dnf_client_check.sh"
IMAGE="${DZ_CHECK_IMAGE:-registry.fedoraproject.org/fedora:44}"
RPM="${DZ_CHECK_RPM:-${SCRIPT_DIR}/../test/support/fixtures/rpms/paladin-0.1.0-1.x86_64.rpm}"
FILENAME="$(basename "${RPM}")"
SIZE="$(stat -c %s "${RPM}")"

PACKAGE="${DZ_CHECK_PACKAGE:-}"
if [ -z "${PACKAGE}" ]; then
  command -v rpm >/dev/null || { echo "set DZ_CHECK_PACKAGE, or install rpm to read the name" >&2; exit 2; }
  PACKAGE="$(rpm -qp --queryformat '%{NAME}' "${RPM}")"
fi

# The fixture is exercised for real: the installed program encrypts and
# decrypts a file, then reports its version.
# shellcheck disable=SC2016 # runs in the container, not here
paladin_verify='printf zenith > /tmp/plain &&
PALADIN_PW=hunter2 paladin --encrypt /tmp/plain --output /tmp/plain.pal --password-env PALADIN_PW &&
PALADIN_PW=hunter2 paladin --decrypt /tmp/plain.pal --output /tmp/roundtrip --password-env PALADIN_PW &&
[ "$(cat /tmp/roundtrip)" = zenith ] &&
paladin --version &&
echo roundtrip ok'

VERIFY="${DZ_CHECK_VERIFY-}"
if [ -z "${DZ_CHECK_VERIFY+set}" ] && [ "${PACKAGE}" = paladin ]; then
  VERIFY="${paladin_verify}"
fi

RUN_ID="$(date +%s)"
API_STATUS=""

die() {
  echo "!! $*" >&2
  exit 1
}

# api <expected statuses> <method> <path> [json body]: prints the response
# body, sets API_STATUS, and fails loudly on any other status.
api() {
  local expected="$1" method="$2" path="$3" body="${4:-}"
  local out
  out="$(mktemp)"

  local args=(-sS -o "${out}" -w '%{http_code}' -X "${method}" -H 'content-type: application/json')
  [ -n "${TOKEN:-}" ] && args+=(-H "authorization: Bearer ${TOKEN}")
  [ -n "${body}" ] && args+=(--data "${body}")

  API_STATUS="$(curl "${args[@]}" "${BASE_URL}${path}")"

  case " ${expected} " in
    *" ${API_STATUS} "*)
      cat "${out}"
      rm -f "${out}"
      ;;
    *)
      echo "!! ${method} ${path} returned ${API_STATUS}, expected ${expected}:" >&2
      cat "${out}" >&2
      echo >&2
      rm -f "${out}"
      return 1
      ;;
  esac
}

# Anonymous status of a repository-serving URL.
anonymous_status() {
  curl -sS -o /dev/null -w '%{http_code}' "$1"
}

## Session and account-level setup

TOKEN="${DZ_CHECK_TOKEN:-}"
LOGGED_IN=0
API_KEY_ID=""
CLIENT_KEY=""
CREATED_SLUGS=()

cleanup() {
  local status=$?
  trap - EXIT

  if [ "${DZ_CHECK_KEEP:-0}" = 1 ]; then
    echo "==> keeping repositories: ${CREATED_SLUGS[*]:-none}"
  else
    local slug
    for slug in "${CREATED_SLUGS[@]:-}"; do
      [ -n "${slug}" ] || continue
      echo "==> delete repository ${slug}"
      api 204 DELETE "/api/v1/repos/${slug}" >/dev/null || true
    done

    if [ -n "${API_KEY_ID}" ]; then
      echo "==> delete the client API key"
      api 204 DELETE "/api/v1/api_keys/${API_KEY_ID}" >/dev/null || true
    fi
  fi

  if [ "${LOGGED_IN}" = 1 ]; then
    api 204 DELETE /api/v1/auth/logout >/dev/null || true
  fi

  exit "${status}"
}
trap cleanup EXIT

echo "==> health probe ${BASE_URL}/health"
curl -fsS "${BASE_URL}/health" | grep -qx ok

if [ -z "${TOKEN}" ]; then
  email="${DZ_CHECK_EMAIL:-admin@example.com}"
  password="${DZ_CHECK_PASSWORD:-darkzenith-admin-dev}"
  echo "==> log in as ${email}"

  login="$(api 200 POST /api/v1/auth/login \
    "$(jq -n --arg email "${email}" --arg password "${password}" '{email: $email, password: $password}')")"
  TOKEN="$(jq -r .data.token <<<"${login}")"
  LOGGED_IN=1
else
  echo "==> using DZ_CHECK_TOKEN"
fi

wants() {
  local flow
  for flow in "${FLOWS[@]}"; do
    [ "${flow}" = "$1" ] && return 0
  done
  return 1
}

FINGERPRINT=""
if wants signed; then
  key="$(api "200 404" GET /api/v1/gpg_key)"
  if [ "${API_STATUS}" = 200 ]; then
    FINGERPRINT="$(jq -r .data.fingerprint <<<"${key}")"
    echo "==> signing with the account's GPG key ${FINGERPRINT}"
  else
    echo "==> generating the account's GPG key (ed25519)"
    generated="$(api 200 POST /api/v1/gpg_key/generation '{"algorithm": "ed25519"}')"
    FINGERPRINT="$(jq -r .data.gpg_key.fingerprint <<<"${generated}")"
  fi
fi

if wants private; then
  case "${TOKEN}" in
    dzak_*)
      echo "==> the private flow's client uses DZ_CHECK_TOKEN"
      CLIENT_KEY="${TOKEN}"
      ;;
    *)
      echo "==> create a repo:read API key for the private flow's client"
      created_key="$(api 201 POST /api/v1/api_keys \
        "$(jq -n --arg name "live-install-check-${RUN_ID}" '{name: $name, scopes: ["repo:read"]}')")"
      API_KEY_ID="$(jq -r .data.id <<<"${created_key}")"
      CLIENT_KEY="$(jq -r .data.key <<<"${created_key}")"
      ;;
  esac
fi

## One flow: provision, upload, wait, run the container

# wait_until <label> <seconds> <command...>: retries the command every two
# seconds until it succeeds.
wait_until() {
  local label="$1" seconds="$2"
  shift 2
  local waited=0
  until "$@"; do
    [ "${waited}" -lt "${seconds}" ] || die "timed out after ${seconds}s waiting for ${label}"
    sleep 2
    waited=$((waited + 2))
  done
}

upload_state() {
  jq -r .data.status <<<"$(api 200 GET "/api/v1/repos/$1/package-uploads/$2")"
}

upload_done() {
  local state
  state="$(upload_state "$1" "$2")"
  case "${state}" in
    succeeded) return 0 ;;
    failed | expired | canceled)
      die "upload ${state}: $(jq -c .data.error <<<"$(api 200 GET "/api/v1/repos/$1/package-uploads/$2")")"
      ;;
    *) return 1 ;;
  esac
}

metadata_ready() {
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' -H "authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/repos/$1/repodata/repomd.xml")"
  [ "${status}" = 200 ]
}

check_flow() {
  local flow="$1"
  local slug="install-check-${RUN_ID}-${flow}"
  local repo_file_url="${BASE_URL}/repos/${slug}/dark-zenith.repo"

  echo "==> ${flow}: create repository ${slug}"
  local attrs
  # shellcheck disable=SC2016 # jq expressions
  case "${flow}" in
    public) attrs='{is_public: true}' ;;
    private) attrs='{is_public: false}' ;;
    signed) attrs='{is_public: true, gpg_key_fingerprint: $fingerprint, sign_rpms: true}' ;;
  esac

  api 201 POST /api/v1/repos "$(jq -n --arg slug "${slug}" --arg name "Live install check (${flow})" \
    --arg fingerprint "${FINGERPRINT}" "{slug: \$slug, name: \$name} + ${attrs}")" >/dev/null
  CREATED_SLUGS+=("${slug}")

  echo "==> ${flow}: upload ${FILENAME} (${SIZE} bytes) through the presigned PUT"
  local declared
  declared="$(api 201 POST "/api/v1/repos/${slug}/package-uploads" \
    "$(jq -n --arg filename "${FILENAME}" --arg size "${SIZE}" '{filename: $filename, size: $size}')")"

  local intent_id method url
  intent_id="$(jq -r .data.id <<<"${declared}")"
  method="$(jq -r .upload.method <<<"${declared}")"
  url="$(jq -r .upload.url <<<"${declared}")"

  local -a header_args
  mapfile -t header_args < <(jq -r '.upload.headers | to_entries[] | "-H", "\(.key): \(.value)"' <<<"${declared}")

  local version_id
  version_id="$(curl -sS --fail -X "${method}" "${header_args[@]}" --data-binary "@${RPM}" \
    -D - -o /dev/null "${url}" | tr -d '\r' | awk 'tolower($1) == "x-amz-version-id:" { print $2 }')"
  [ -n "${version_id}" ] || die "object storage returned no x-amz-version-id (bucket versioning must be on)"

  api 202 POST "/api/v1/repos/${slug}/package-uploads/${intent_id}/complete" \
    "$(jq -n --argjson generation "$(jq -c .upload.generation <<<"${declared}")" --arg version_id "${version_id}" \
      '{generation: $generation, version_id: $version_id}')" >/dev/null

  echo "==> ${flow}: wait for processing"
  wait_until "the upload to succeed" 120 upload_done "${slug}" "${intent_id}"

  echo "==> ${flow}: wait for metadata"
  wait_until "repomd.xml" 120 metadata_ready "${slug}"

  local anonymous
  anonymous="$(anonymous_status "${BASE_URL}/repos/${slug}/repodata/repomd.xml")"
  case "${flow}" in
    private)
      echo "==> ${flow}: anonymous repomd.xml is ${anonymous}"
      [ "${anonymous}" = 401 ] || die "a private repository must challenge anonymous clients"
      ;;
    *)
      echo "==> ${flow}: anonymous repomd.xml is ${anonymous}"
      [ "${anonymous}" = 200 ] || die "a public repository must serve anonymous clients"
      ;;
  esac

  if [ "${flow}" = signed ]; then
    echo "==> ${flow}: the served .repo file turns verification on"
    local repo_file
    repo_file="$(curl -fsS "${repo_file_url}")"
    grep -qx 'repo_gpgcheck=1' <<<"${repo_file}" || die "repo_gpgcheck is off in the served .repo file"
    grep -qx 'gpgcheck=1' <<<"${repo_file}" || die "gpgcheck is off in the served .repo file"
  fi

  echo "==> ${flow}: dnf5 in a fresh ${IMAGE} container"
  local -a run=(run --rm --network=host)
  [ "${flow}" = private ] && run+=(--env "DZ_CLIENT_PASSWORD=${CLIENT_KEY}")
  run+=("${IMAGE}" bash -c "$(cat "${CLIENT_CHECK}")" dnf_client_check.sh "${repo_file_url}" "${PACKAGE}")
  [ -n "${VERIFY}" ] && run+=("${VERIFY}")

  local log
  log="$(mktemp)"
  podman "${run[@]}" 2>&1 | tee "${log}"

  if [ "${flow}" = signed ]; then
    grep -q 'The key was successfully imported\.' "${log}" ||
      die "dnf did not import the served key"
    ! grep -q 'skipped OpenPGP checks' "${log}" ||
      die "dnf skipped signature checks on a signed repository"
  else
    grep -q 'skipped OpenPGP checks' "${log}" ||
      die "dnf reported no skipped signature checks on an unsigned repository"
  fi
  rm -f "${log}"
}

for flow in "${FLOWS[@]}"; do
  check_flow "${flow}"
done

echo "live install check passed: ${FLOWS[*]} against ${BASE_URL}"
