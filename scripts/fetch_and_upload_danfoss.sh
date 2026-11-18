#!/usr/bin/env bash
# Download the tested Danfoss manual from its official source and upload it securely.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="https://files.danfoss.com/download/Drives/MG07A102.pdf"
EXPECTED_SHA256="a1432e55f3ff76468a3e85738f543f824059ad13e0d9980d1af65d4a40d3ee77"
PROFILE_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage: ./scripts/fetch_and_upload_danfoss.sh [--profile PROFILE]

Downloads the tested VLT Midi Drive FC 280 manual directly from Danfoss,
verifies its PDF signature and SHA-256 checksum, then uploads it to the
Terraform-managed document bucket as DANFOSS-FC280 revision r1.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || die "--profile requires a profile name"
      PROFILE_OVERRIDE="$2"
      shift 2
      ;;
    --profile=*)
      PROFILE_OVERRIDE="${1#--profile=}"
      [ -n "$PROFILE_OVERRIDE" ] || die "--profile requires a profile name"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[ -x "$HERE/check_prerequisites.sh" ] || die "Missing executable scripts/check_prerequisites.sh"
"$HERE/check_prerequisites.sh" fetch || {
  printf 'Resume after installing the listed prerequisites by rerunning:\n  %s' "$0" >&2
  if [ -n "$PROFILE_OVERRIDE" ]; then
    printf ' --profile %q' "$PROFILE_OVERRIDE" >&2
  fi
  printf '\n' >&2
  exit 1
}
[ -x "$HERE/upload_v3_manual.sh" ] || die "Missing executable scripts/upload_v3_manual.sh"

if [ -n "$PROFILE_OVERRIDE" ]; then
  export AWS_PROFILE="$PROFILE_OVERRIDE"
fi

umask 077
DOWNLOAD="$(mktemp "${TMPDIR:-/tmp}/vectorless-danfoss-fc280.XXXXXX")"
printf 'Downloading the tested Danfoss FC 280 manual from:\n  %s\n' "$URL"
curl \
  --fail \
  --location \
  --proto '=https' \
  --proto-redir '=https' \
  --tlsv1.2 \
  --retry 3 \
  --retry-all-errors \
  --connect-timeout 30 \
  --max-time 300 \
  --output "$DOWNLOAD" \
  "$URL"

ACTUAL_SHA256="$(python3 - "$DOWNLOAD" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("rb") as handle:
    if handle.read(5) != b"%PDF-":
        raise SystemExit("Downloaded file does not have a PDF signature")
    handle.seek(0)
    digest = hashlib.file_digest(handle, "sha256").hexdigest()
print(digest)
PY
)" || die "Downloaded file validation failed"

[ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] || die \
  "Danfoss changed the download. Expected SHA-256 $EXPECTED_SHA256 but received $ACTUAL_SHA256. Review and test the new revision before uploading it."

printf 'Verified Danfoss PDF SHA-256: %s\n' "$ACTUAL_SHA256"
printf 'Temporary download: %s\n' "$DOWNLOAD"
"$HERE/upload_v3_manual.sh" "$DOWNLOAD" manual DANFOSS-FC280 r1
