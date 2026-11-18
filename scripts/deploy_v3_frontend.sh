#!/usr/bin/env bash
# Build and publish the v3 SPA after infrastructure has been applied.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TF="$ROOT/terraform-v3"

for tool in aws terraform npm; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing required tool: %s\n' "$tool" >&2
    exit 1
  }
done

REGION="$(terraform -chdir="$TF" output -raw region)"
ACCOUNT="$(terraform -chdir="$TF" output -raw aws_account_id)"
BUCKET="$(terraform -chdir="$TF" output -raw web_bucket)"
DIST_ID="$(terraform -chdir="$TF" output -raw cloudfront_distribution_id)"
URL="$(terraform -chdir="$TF" output -raw web_url)"
COGNITO_DOMAIN="$(terraform -chdir="$TF" output -raw cognito_domain)"
COGNITO_CLIENT_ID="$(terraform -chdir="$TF" output -raw cognito_client_id)"
CALLER_ACCOUNT="$(aws sts get-caller-identity --region "$REGION" --query Account --output text)"

if [ "$CALLER_ACCOUNT" != "$ACCOUNT" ]; then
  printf 'AWS account mismatch: Terraform targets %s, but current credentials use %s.\n' \
    "$ACCOUNT" "$CALLER_ACCOUNT" >&2
  exit 1
fi

printf 'Frontend deployment target:\n  Account: %s\n  Region:  %s\n  Bucket:  s3://%s\n  URL:     %s\n' \
  "$ACCOUNT" "$REGION" "$BUCKET" "$URL"
read -r -p "Build and publish the frontend to this target? [y/N]: " CONFIRM
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *)
    printf 'Deployment cancelled.\n'
    exit 1
    ;;
esac

cd "$ROOT/frontend"
npm ci
VITE_COGNITO_DOMAIN="$COGNITO_DOMAIN" \
VITE_COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
  npm run build

# The high-level `aws s3 sync` command has no expected-owner option. The
# account equality check above and Terraform-owned bucket output pin the target.
aws s3 sync dist "s3://$BUCKET" \
  --region "$REGION" \
  --sse AES256 \
  --only-show-errors

aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --paths "/*" \
  --query "Invalidation.Id" \
  --output text

printf 'Frontend deployed: %s\n' "$URL"
