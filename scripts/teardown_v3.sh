#!/usr/bin/env bash
# Safely remove one Vectorless Document Tree v3 stack from its Terraform state.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TF="$ROOT/terraform-v3"
PROFILE_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage: ./scripts/teardown_v3.sh [--profile PROFILE]

Inventories, backs up, destroys, and verifies the v3 stack managed by the
local terraform-v3 state. S3 object versions are permanently deleted.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
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

[ -t 0 ] || die "Run this interactive script from a terminal"
[ -x "$HERE/check_prerequisites.sh" ] || die "Missing executable scripts/check_prerequisites.sh"
"$HERE/check_prerequisites.sh" teardown || {
  printf 'Resume after installing the listed prerequisites by rerunning:\n  %s' "$0" >&2
  if [ -n "$PROFILE_OVERRIDE" ]; then
    printf ' --profile %q' "$PROFILE_OVERRIDE" >&2
  fi
  printf '\n' >&2
  exit 1
}

if [ -n "$PROFILE_OVERRIDE" ]; then
  export AWS_PROFILE="$PROFILE_OVERRIDE"
fi

[ -s "$TF/terraform.tfstate" ] || die \
  "No local terraform-v3/terraform.tfstate was found. Run teardown from the directory that deployed the stack."

terraform -chdir="$TF" init -input=false
STATE_JSON="$(terraform -chdir="$TF" show -json)" || die "Unable to read Terraform state"

state_value() {
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
address = sys.argv[1]
attribute = sys.argv[2]
modules = [data.get("values", {}).get("root_module", {})]
while modules:
    module = modules.pop()
    for resource in module.get("resources", []):
        resource_address = resource.get("address", "")
        if resource_address == address or resource_address.startswith(address + "["):
            value = resource.get("values", {}).get(attribute)
            if value is None:
                raise SystemExit(2)
            print(value)
            raise SystemExit(0)
    modules.extend(module.get("child_modules", []))
raise SystemExit(1)
' "$1" "$2" <<< "$STATE_JSON"
}

optional_state_value() {
  state_value "$1" "$2" 2>/dev/null || true
}

MANAGED_RESOURCE_COUNT="$(python3 -c '
import json
import sys

data = json.load(sys.stdin)
modules = [data.get("values", {}).get("root_module", {})]
count = 0
while modules:
    module = modules.pop()
    count += sum(1 for resource in module.get("resources", []) if resource.get("mode") == "managed")
    modules.extend(module.get("child_modules", []))
print(count)
' <<< "$STATE_JSON")"
[ "$MANAGED_RESOURCE_COUNT" -gt 0 ] || die "Terraform state contains no managed resources"

ACCOUNT="$(terraform -chdir="$TF" output -raw aws_account_id)"
REGION="$(terraform -chdir="$TF" output -raw region)"
WEB_URL="$(terraform -chdir="$TF" output -raw web_url)"
DOCUMENT_BUCKET="$(terraform -chdir="$TF" output -raw document_bucket)"
WEB_BUCKET="$(terraform -chdir="$TF" output -raw web_bucket)"
ACCESS_LOG_BUCKET="$(state_value aws_s3_bucket.access_logs bucket)"
METADATA_TABLE="$(terraform -chdir="$TF" output -raw metadata_table)"
QUERY_FUNCTION="$(terraform -chdir="$TF" output -raw query_function_name)"
INGEST_FUNCTION="$(terraform -chdir="$TF" output -raw ingest_function_name)"
PROJECT_NAME="${QUERY_FUNCTION%-query}"
USER_POOL_ID="$(terraform -chdir="$TF" output -raw cognito_user_pool_id)"
DISTRIBUTION_ID="$(terraform -chdir="$TF" output -raw cloudfront_distribution_id)"
DLQ_URL="$(state_value aws_sqs_queue.ingest_dlq id)"
QUERY_ROLE="$(state_value aws_iam_role.query name)"
INGEST_ROLE="$(state_value aws_iam_role.ingest name)"
DATA_KEY_ID="$(state_value aws_kms_key.data key_id)"
WAF_KEY_ID="$(optional_state_value aws_kms_key.waf_logs key_id)"
WAF_ID="$(optional_state_value aws_wafv2_web_acl.web id)"
WAF_NAME="$(optional_state_value aws_wafv2_web_acl.web name)"
WEB_OAC_ID="$(state_value aws_cloudfront_origin_access_control.web id)"
QUERY_OAC_ID="$(state_value aws_cloudfront_origin_access_control.query id)"
CACHE_POLICY_ID="$(state_value aws_cloudfront_cache_policy.api id)"
ORIGIN_POLICY_ID="$(state_value aws_cloudfront_origin_request_policy.api id)"
HEADERS_POLICY_ID="$(state_value aws_cloudfront_response_headers_policy.security id)"
LAYER_NAME="$(state_value aws_lambda_layer_version.imaging layer_name)"
LAYER_VERSION="$(state_value aws_lambda_layer_version.imaging version)"
INGEST_LOG_GROUP="$(state_value aws_cloudwatch_log_group.ingest name)"
QUERY_LOG_GROUP="$(state_value aws_cloudwatch_log_group.query name)"
WAF_LOG_GROUP="$(optional_state_value aws_cloudwatch_log_group.waf name)"
WAF_ENABLED="false"
if [ -n "$WAF_ID" ]; then
  WAF_ENABLED="true"
fi

if ! CALLER_JSON="$(aws sts get-caller-identity --region "$REGION" --output json 2>/dev/null)"; then
  die "AWS authentication failed. Rerun with active credentials or --profile PROFILE."
fi
CALLER_ACCOUNT="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<< "$CALLER_JSON")"
CALLER_ARN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])' <<< "$CALLER_JSON")"
[ "$CALLER_ACCOUNT" = "$ACCOUNT" ] || die \
  "Account mismatch: Terraform state targets $ACCOUNT, but current credentials use $CALLER_ACCOUNT"

bucket_inventory() {
  local bucket="$1"
  local versions_json
  local uploads_json
  versions_json="$(aws s3api list-object-versions \
    --region "$REGION" \
    --bucket "$bucket" \
    --expected-bucket-owner "$ACCOUNT" \
    --output json)"
  uploads_json="$(aws s3api list-multipart-uploads \
    --region "$REGION" \
    --bucket "$bucket" \
    --expected-bucket-owner "$ACCOUNT" \
    --output json)"
  python3 -c '
import json
import sys

versions = json.loads(sys.argv[1] or "{}")
uploads = json.loads(sys.argv[2] or "{}")
print(len(versions.get("Versions", [])), len(versions.get("DeleteMarkers", [])), len(uploads.get("Uploads", [])))
' "$versions_json" "$uploads_json"
}

read -r DOCUMENT_VERSIONS DOCUMENT_MARKERS DOCUMENT_UPLOADS < <(bucket_inventory "$DOCUMENT_BUCKET")
read -r WEB_VERSIONS WEB_MARKERS WEB_UPLOADS < <(bucket_inventory "$WEB_BUCKET")
read -r LOG_VERSIONS LOG_MARKERS LOG_UPLOADS < <(bucket_inventory "$ACCESS_LOG_BUCKET")
TOTAL_VERSIONS=$((DOCUMENT_VERSIONS + DOCUMENT_MARKERS + WEB_VERSIONS + WEB_MARKERS + LOG_VERSIONS + LOG_MARKERS))
TOTAL_UPLOADS=$((DOCUMENT_UPLOADS + WEB_UPLOADS + LOG_UPLOADS))

printf '\nVectorless v3 teardown target:\n'
printf '  Account:             %s\n' "$ACCOUNT"
printf '  Caller:              %s\n' "$CALLER_ARN"
printf '  Region:              %s\n' "$REGION"
printf '  Project:             %s\n' "$PROJECT_NAME"
printf '  Application URL:     %s\n' "$WEB_URL"
printf '  Terraform resources: %s\n' "$MANAGED_RESOURCE_COUNT"
printf '  S3 object versions:  %s\n' "$TOTAL_VERSIONS"
printf '  Multipart uploads:   %s\n' "$TOTAL_UPLOADS"
printf '\nServices scheduled for removal:\n'
printf '  Amazon CloudFront distribution, policies, and origin access controls\n'
if [ "$WAF_ENABLED" = "true" ]; then
  printf '  AWS WAF web ACL, logging configuration, log group, and KMS key\n'
fi
printf '  Amazon Cognito user pool, client, domain, branding, and users\n'
printf '  AWS Lambda query and ingest functions, Function URL, layer, and permissions\n'
printf '  AWS IAM query and ingest roles and inline policies\n'
printf '  Amazon DynamoDB metadata table and records\n'
printf '  Amazon SQS ingest dead-letter queue\n'
printf '  Three Amazon S3 buckets, every object version, and multipart upload\n'
printf '  CloudWatch Lambda log groups\n'
if [ "$WAF_ENABLED" = "true" ]; then
  printf '  Two AWS KMS keys, which enter a 30-day pending-deletion period\n'
else
  printf '  One AWS KMS key, which enters a 30-day pending-deletion period\n'
fi

confirm "Continue with this exact account, Region, and project?" || die "Teardown cancelled"
printf '\nThis permanently deletes every object version in the three listed Terraform-owned buckets.\n'
confirm "Disable Cognito deletion protection and permanently delete $TOTAL_VERSIONS S3 versions?" || \
  die "Teardown cancelled before data deletion"

umask 077
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STATE_BACKUP="$TF/terraform.tfstate.pre-teardown-$TIMESTAMP.bak"
cp "$TF/terraform.tfstate" "$STATE_BACKUP"
printf 'Terraform state backup: %s\n' "$STATE_BACKUP"

DELETION_PROTECTION="$(aws cognito-idp describe-user-pool \
  --region "$REGION" \
  --user-pool-id "$USER_POOL_ID" \
  --query 'UserPool.DeletionProtection' \
  --output text)"
if [ "$DELETION_PROTECTION" = "ACTIVE" ]; then
  PROTECTION_PLAN="$TF/disable-cognito-protection-$TIMESTAMP.plan"
  terraform -chdir="$TF" plan \
    -input=false \
    -var='cognito_deletion_protection=INACTIVE' \
    -out="$PROTECTION_PLAN"
  terraform -chdir="$TF" show -json "$PROTECTION_PLAN" | python3 -c '
import json
import sys

plan = json.load(sys.stdin)
changes = [item for item in plan.get("resource_changes", []) if item.get("change", {}).get("actions") == ["update"]]
creates_or_deletes = [
    item for item in plan.get("resource_changes", [])
    if "create" in item.get("change", {}).get("actions", []) or "delete" in item.get("change", {}).get("actions", [])
]
if len(changes) != 1 or changes[0].get("address") != "aws_cognito_user_pool.main" or creates_or_deletes:
    raise SystemExit("Protection plan contains unexpected changes")
'
  terraform -chdir="$TF" apply -input=false "$PROTECTION_PLAN"
fi

empty_owned_buckets() {
  python3 - "$REGION" "$ACCOUNT" "$DOCUMENT_BUCKET" "$WEB_BUCKET" "$ACCESS_LOG_BUCKET" <<'PY'
import json
import os
import subprocess
import sys

region, owner, *buckets = sys.argv[1:]
profile = os.environ.get("AWS_PROFILE")

def aws(*args):
    command = ["aws", *args, "--region", region]
    if profile:
        command.extend(["--profile", profile])
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)

for bucket in buckets:
    deleted = 0
    bucket_exists = True
    while True:
        try:
            raw = aws(
                "s3api", "list-object-versions",
                "--bucket", bucket,
                "--expected-bucket-owner", owner,
                "--output", "json",
            ).strip()
        except subprocess.CalledProcessError as error:
            if "NoSuchBucket" in error.output or "Not Found" in error.output:
                print(f"Already removed {bucket}")
                bucket_exists = False
                break
            raise
        data = json.loads(raw) if raw else {}
        objects = [
            {"Key": item["Key"], "VersionId": item["VersionId"]}
            for item in data.get("Versions", []) + data.get("DeleteMarkers", [])
        ][:1000]
        if not objects:
            break
        result = json.loads(aws(
            "s3api", "delete-objects",
            "--bucket", bucket,
            "--expected-bucket-owner", owner,
            "--delete", json.dumps({"Objects": objects, "Quiet": True}),
            "--output", "json",
        ) or "{}")
        if result.get("Errors"):
            raise SystemExit(f"Failed to delete one or more versions from {bucket}")
        deleted += len(objects)

    if not bucket_exists:
        continue

    aborted = 0
    while True:
        raw = aws(
            "s3api", "list-multipart-uploads",
            "--bucket", bucket,
            "--expected-bucket-owner", owner,
            "--output", "json",
        ).strip()
        uploads = (json.loads(raw) if raw else {}).get("Uploads", [])
        if not uploads:
            break
        for upload in uploads:
            aws(
                "s3api", "abort-multipart-upload",
                "--bucket", bucket,
                "--expected-bucket-owner", owner,
                "--key", upload["Key"],
                "--upload-id", upload["UploadId"],
            )
            aborted += 1
    print(f"Emptied {bucket}: deleted_versions={deleted}, aborted_uploads={aborted}")
PY
}

empty_owned_buckets

MAX_DESTROY_ATTEMPTS=3
DESTROY_SUCCEEDED="false"
for ((destroy_attempt = 1; destroy_attempt <= MAX_DESTROY_ATTEMPTS; destroy_attempt++)); do
  ATTEMPT_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)-$destroy_attempt"
  DESTROY_PLAN="$TF/destroy-$ATTEMPT_TIMESTAMP.plan"
  terraform -chdir="$TF" plan \
    -destroy \
    -input=false \
    -var='cognito_deletion_protection=INACTIVE' \
    -out="$DESTROY_PLAN"
  DESTROY_COUNT="$(terraform -chdir="$TF" show -json "$DESTROY_PLAN" | python3 -c '
import json
import sys

plan = json.load(sys.stdin)
changes = plan.get("resource_changes", [])
deletes = [item for item in changes if item.get("change", {}).get("actions") == ["delete"]]
unexpected = [
    item for item in changes
    if "create" in item.get("change", {}).get("actions", []) or item.get("change", {}).get("actions") == ["update"]
]
if not deletes or unexpected:
    raise SystemExit("Destroy plan contains unexpected actions")
print(len(deletes))
')"
  printf '\nValidated destroy plan attempt %s: %s resources will be removed, with no creates or updates.\n' \
    "$destroy_attempt" "$DESTROY_COUNT"
  printf 'Saved destroy plan: %s\n' "$DESTROY_PLAN"
  if [ "$destroy_attempt" -eq 1 ]; then
    confirm "Apply this exact destroy plan?" || die "Destroy plan preserved but not applied"
  else
    printf 'Retrying the confirmed teardown with a fresh plan after delayed AWS activity.\n'
  fi

  if terraform -chdir="$TF" apply -input=false "$DESTROY_PLAN"; then
    DESTROY_SUCCEEDED="true"
    break
  fi

  if [ "$destroy_attempt" -lt "$MAX_DESTROY_ATTEMPTS" ]; then
    printf 'Destroy attempt %s was partial. Terraform preserved the remaining state.\n' "$destroy_attempt" >&2
    printf 'Waiting 30 seconds for asynchronous log delivery before cleanup and replanning...\n' >&2
    sleep 30
    empty_owned_buckets
  fi
done

[ "$DESTROY_SUCCEEDED" = "true" ] || die \
  "Teardown remained incomplete after $MAX_DESTROY_ATTEMPTS fresh plans. State backup: $STATE_BACKUP"

VERIFICATION_FAILURES=0
verify_absent() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  PRESENT: %s\n' "$label"
    VERIFICATION_FAILURES=$((VERIFICATION_FAILURES + 1))
  else
    printf '  REMOVED: %s\n' "$label"
  fi
}

verify_log_group_absent() {
  local label="$1"
  local region="$2"
  local name="$3"
  local count
  count="$(aws logs describe-log-groups \
    --region "$region" \
    --log-group-name-prefix "$name" \
    --query "length(logGroups[?logGroupName=='$name'])" \
    --output text)"
  if [ "$count" = "0" ]; then
    printf '  REMOVED: %s\n' "$label"
  else
    printf '  PRESENT: %s\n' "$label"
    VERIFICATION_FAILURES=$((VERIFICATION_FAILURES + 1))
  fi
}

printf '\nPost-teardown verification:\n'
verify_absent "CloudFront distribution" aws cloudfront get-distribution --id "$DISTRIBUTION_ID"
verify_absent "CloudFront web origin access control" aws cloudfront get-origin-access-control --id "$WEB_OAC_ID"
verify_absent "CloudFront query origin access control" aws cloudfront get-origin-access-control --id "$QUERY_OAC_ID"
verify_absent "CloudFront API cache policy" aws cloudfront get-cache-policy --id "$CACHE_POLICY_ID"
verify_absent "CloudFront API origin request policy" aws cloudfront get-origin-request-policy --id "$ORIGIN_POLICY_ID"
verify_absent "CloudFront security headers policy" aws cloudfront get-response-headers-policy --id "$HEADERS_POLICY_ID"
if [ "$WAF_ENABLED" = "true" ]; then
  verify_absent "AWS WAF web ACL" aws wafv2 get-web-acl --region us-east-1 --scope CLOUDFRONT --id "$WAF_ID" --name "$WAF_NAME"
fi
verify_absent "Cognito user pool and users" aws cognito-idp describe-user-pool --region "$REGION" --user-pool-id "$USER_POOL_ID"
verify_absent "Query Lambda and Function URL" aws lambda get-function --region "$REGION" --function-name "$QUERY_FUNCTION"
verify_absent "Ingest Lambda" aws lambda get-function --region "$REGION" --function-name "$INGEST_FUNCTION"
verify_absent "Lambda imaging layer" aws lambda get-layer-version --region "$REGION" --layer-name "$LAYER_NAME" --version-number "$LAYER_VERSION"
verify_absent "DynamoDB metadata table and records" aws dynamodb describe-table --region "$REGION" --table-name "$METADATA_TABLE"
verify_absent "SQS ingest dead-letter queue" aws sqs get-queue-attributes --region "$REGION" --queue-url "$DLQ_URL" --attribute-names QueueArn
verify_absent "Query IAM role and policy" aws iam get-role --role-name "$QUERY_ROLE"
verify_absent "Ingest IAM role and policy" aws iam get-role --role-name "$INGEST_ROLE"
verify_absent "S3 document bucket and all versions" aws s3api head-bucket --region "$REGION" --bucket "$DOCUMENT_BUCKET" --expected-bucket-owner "$ACCOUNT"
verify_absent "S3 web bucket and all versions" aws s3api head-bucket --region "$REGION" --bucket "$WEB_BUCKET" --expected-bucket-owner "$ACCOUNT"
verify_absent "S3 access-log bucket and all versions" aws s3api head-bucket --region "$REGION" --bucket "$ACCESS_LOG_BUCKET" --expected-bucket-owner "$ACCOUNT"
verify_log_group_absent "Ingest CloudWatch log group" "$REGION" "$INGEST_LOG_GROUP"
verify_log_group_absent "Query CloudWatch log group" "$REGION" "$QUERY_LOG_GROUP"
if [ "$WAF_ENABLED" = "true" ]; then
  verify_log_group_absent "AWS WAF CloudWatch log group" "us-east-1" "$WAF_LOG_GROUP"
fi

verify_kms_pending_deletion() {
  local key_region="$1"
  local key_id="$2"
  local key_label="$3"
  local key_state
  key_state="$(aws kms describe-key --region "$key_region" --key-id "$key_id" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || true)"
  if [ "$key_state" = "PendingDeletion" ]; then
    printf '  PENDING DELETION: %s, 30-day AWS waiting period\n' "$key_label"
  else
    printf '  UNEXPECTED STATE: %s, %s\n' "$key_label" "${key_state:-not found}"
    VERIFICATION_FAILURES=$((VERIFICATION_FAILURES + 1))
  fi
}

verify_kms_pending_deletion "$REGION" "$DATA_KEY_ID" "Data KMS key"
if [ "$WAF_ENABLED" = "true" ]; then
  verify_kms_pending_deletion "us-east-1" "$WAF_KEY_ID" "WAF log KMS key"
fi

REMAINING_STATE="$(terraform -chdir="$TF" state list | wc -l | tr -d ' ')"
if [ "$REMAINING_STATE" = "0" ]; then
  printf '  EMPTY: Terraform managed state\n'
else
  printf '  PRESENT: Terraform still tracks %s addresses\n' "$REMAINING_STATE"
  VERIFICATION_FAILURES=$((VERIFICATION_FAILURES + 1))
fi

[ "$VERIFICATION_FAILURES" -eq 0 ] || die \
  "$VERIFICATION_FAILURES post-teardown verification checks failed. Preserve state and investigate."
printf '\nTeardown complete and verified for account %s, Region %s, project %s.\n' \
  "$ACCOUNT" "$REGION" "$PROJECT_NAME"
printf 'State backup retained at %s\n' "$STATE_BACKUP"
