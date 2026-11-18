#!/usr/bin/env bash
# Safely upload one explicitly identified PDF to the v3 document bucket.
set -euo pipefail

usage() {
  printf 'Usage: %s <pdf-path> <manual|unit> <identifier> <revision>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 4 ] || usage
PDF="$1"
KIND="$2"
IDENTIFIER="$3"
REVISION="$4"

[ -f "$PDF" ] || {
  printf 'PDF does not exist: %s\n' "$PDF" >&2
  exit 1
}
case "$KIND" in
  manual) PREFIX="manuals" ;;
  unit) PREFIX="units" ;;
  *) usage ;;
esac
case "$IDENTIFIER" in
  ""|*[!A-Za-z0-9._-]*)
    printf 'Identifier may contain only letters, numbers, period, underscore, and hyphen.\n' >&2
    exit 1
    ;;
esac
case "$IDENTIFIER" in
  [A-Za-z0-9]*) ;;
  *)
    printf 'Identifier must start with a letter or number.\n' >&2
    exit 1
    ;;
esac
if [ "${#IDENTIFIER}" -gt 64 ]; then
  printf 'Identifier must not exceed 64 characters.\n' >&2
  exit 1
fi
case "$REVISION" in
  ""|*[!A-Za-z0-9._-]*)
    printf 'Revision may contain only letters, numbers, period, underscore, and hyphen.\n' >&2
    exit 1
    ;;
esac
if [ "${#REVISION}" -gt 32 ]; then
  printf 'Revision must not exceed 32 characters.\n' >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TF="$ROOT/terraform-v3"
[ -x "$HERE/check_prerequisites.sh" ] || {
  printf 'Missing executable scripts/check_prerequisites.sh\n' >&2
  exit 1
}
"$HERE/check_prerequisites.sh" upload || {
  printf 'Resume after installing the listed prerequisites by rerunning the same upload command.\n' >&2
  exit 1
}
REGION="$(terraform -chdir="$TF" output -raw region)"
ACCOUNT="$(terraform -chdir="$TF" output -raw aws_account_id)"
BUCKET="$(terraform -chdir="$TF" output -raw document_bucket)"
KMS_KEY="$(terraform -chdir="$TF" output -raw kms_key_arn)"
CALLER_ACCOUNT="$(aws sts get-caller-identity --region "$REGION" --query Account --output text)"

if [ "$CALLER_ACCOUNT" != "$ACCOUNT" ]; then
  printf 'AWS account mismatch: Terraform targets %s, but current credentials use %s.\n' \
    "$ACCOUNT" "$CALLER_ACCOUNT" >&2
  exit 1
fi

KEY="$PREFIX/$IDENTIFIER/$REVISION.pdf"
printf 'Upload target:\n  Source:  %s\n  Account: %s\n  Region:  %s\n  Object:  s3://%s/%s\n' \
  "$PDF" "$ACCOUNT" "$REGION" "$BUCKET" "$KEY"

HEAD_ERROR=""
if HEAD_ERROR="$(aws s3api head-object \
  --bucket "$BUCKET" \
  --key "$KEY" \
  --region "$REGION" \
  --expected-bucket-owner "$ACCOUNT" 2>&1)"; then
  printf 'Revision already exists at s3://%s/%s. Choose a new revision; this script will not overwrite it.\n' \
    "$BUCKET" "$KEY" >&2
  exit 1
else
  case "$HEAD_ERROR" in
    *"(404)"*|*Not\ Found*|*NoSuchKey*) ;;
    *)
      printf 'Could not safely confirm that the revision is new: %s\n' "$HEAD_ERROR" >&2
      exit 1
      ;;
  esac
fi

read -r -p "Encrypt, upload, and trigger ingestion? [y/N]: " CONFIRM
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *)
    printf 'Upload cancelled.\n'
    exit 1
    ;;
esac

aws s3api put-object \
  --bucket "$BUCKET" \
  --key "$KEY" \
  --body "$PDF" \
  --content-type application/pdf \
  --region "$REGION" \
  --server-side-encryption aws:kms \
  --ssekms-key-id "$KMS_KEY" \
  --expected-bucket-owner "$ACCOUNT" \
  --query ETag \
  --output text >/dev/null

printf 'Uploaded s3://%s/%s. The S3 event started ingestion.\n' "$BUCKET" "$KEY"
