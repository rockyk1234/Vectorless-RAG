#!/usr/bin/env bash
# Interactive, fail-closed deployment for a fresh Vectorless Document Tree v3 stack.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TF="$ROOT/terraform-v3"
ROUTER_MODEL_ID="global.anthropic.claude-haiku-4-5-20251001-v1:0"
ANSWER_MODEL_ID="global.anthropic.claude-sonnet-4-6"
MODE="deploy"
PROFILE_OVERRIDE=""
AUTH_GATE_MAX_ATTEMPTS=40
MANUAL_INGEST_MAX_ATTEMPTS=60
POLL_INTERVAL_SECONDS=15
HTTP_REQUEST_TIMEOUT_SECONDS=30
SECONDS_PER_MINUTE=60
MANUAL_INGEST_TIMEOUT_MINUTES=$(((MANUAL_INGEST_MAX_ATTEMPTS * POLL_INTERVAL_SECONDS + SECONDS_PER_MINUTE - 1) / SECONDS_PER_MINUTE))

# These Regions have the required AWS services. The selected account and models
# must still pass the live preflight before Terraform can run.
SUPPORTED_REGIONS=(
  us-east-1
  us-east-2
  us-west-2
  eu-west-1
  eu-west-2
  eu-central-1
  ap-southeast-1
  ap-southeast-2
)

usage() {
  cat <<'USAGE'
Usage: ./scripts/setup_and_deploy_v3.sh [--plan-only] [--profile PROFILE]

Interactively configures, validates, plans, and deploys a fresh v3 stack.
Use --plan-only to stop after creating and validating the Terraform plan.
Use --profile to select a named AWS CLI profile. Without it, the script uses
the active AWS credential chain and stops with guidance if no identity exists.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

print_resume_help() {
  printf '\nThis stack already has Terraform state. Do not rerun infrastructure creation.\n' >&2
  printf 'Resume only the unfinished step:\n' >&2
  if [ -n "$PROFILE_OVERRIDE" ]; then
    printf '  Frontend: AWS_PROFILE=%q ./scripts/deploy_v3_frontend.sh\n' "$PROFILE_OVERRIDE" >&2
    printf '  Manual:   ./scripts/fetch_and_upload_danfoss.sh --profile %q\n' "$PROFILE_OVERRIDE" >&2
    printf '  Teardown: ./scripts/teardown_v3.sh --profile %q\n' "$PROFILE_OVERRIDE" >&2
  else
    printf '  Frontend: ./scripts/deploy_v3_frontend.sh\n' >&2
    printf '  Manual:   ./scripts/fetch_and_upload_danfoss.sh\n' >&2
    printf '  Teardown: ./scripts/teardown_v3.sh\n' >&2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan-only)
      MODE="plan-only"
      shift
      ;;
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
"$HERE/check_prerequisites.sh" full || {
  printf 'Resume after installing the listed prerequisites by rerunning:\n  %s' "$0" >&2
  if [ "$MODE" = "plan-only" ]; then
    printf ' --plan-only' >&2
  fi
  if [ -n "$PROFILE_OVERRIDE" ]; then
    printf ' --profile %q' "$PROFILE_OVERRIDE" >&2
  fi
  printf '\n' >&2
  exit 1
}
[ -f "$TF/terraform.tfvars.example" ] || die "Missing terraform-v3/terraform.tfvars.example"

if [ -s "$TF/terraform.tfstate" ]; then
  STATE_RESOURCES="$(python3 - "$TF/terraform.tfstate" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
print(sum(1 for resource in state.get("resources", []) if resource.get("mode") == "managed"))
PY
)"
  if [ "$STATE_RESOURCES" -gt 0 ]; then
    print_resume_help
    die "Existing Terraform state manages $STATE_RESOURCES resources"
  fi
fi

printf '\nSelect the regional location for data, compute, Cognito, Textract, and Bedrock calls.\n'
for index in "${!SUPPORTED_REGIONS[@]}"; do
  printf '  %d) %s\n' "$((index + 1))" "${SUPPORTED_REGIONS[$index]}"
done
while true; do
  read -r -p "Region number: " REGION_NUMBER
  if [[ "$REGION_NUMBER" =~ ^[0-9]+$ ]] \
      && [ "$REGION_NUMBER" -ge 1 ] \
      && [ "$REGION_NUMBER" -le "${#SUPPORTED_REGIONS[@]}" ]; then
    REGION="${SUPPORTED_REGIONS[$((REGION_NUMBER - 1))]}"
    break
  fi
  printf 'Choose a number from 1 to %d.\n' "${#SUPPORTED_REGIONS[@]}" >&2
done

if [ -n "$PROFILE_OVERRIDE" ]; then
  export AWS_PROFILE="$PROFILE_OVERRIDE"
  printf '\nChecking AWS credentials with profile %s...\n' "$PROFILE_OVERRIDE"
else
  printf '\nChecking active AWS credentials...\n'
fi

if ! CALLER_JSON="$(aws sts get-caller-identity --region "$REGION" --output json 2>/dev/null)"; then
  if [ -n "$PROFILE_OVERRIDE" ]; then
    aws sts get-caller-identity --region "$REGION" --output json >&2 || true
    die "AWS profile $PROFILE_OVERRIDE did not provide valid credentials"
  fi
  printf '\nNo active AWS credentials were found.\n' >&2
  printf 'Authenticate with the AWS CLI, or rerun with a named profile:\n' >&2
  printf '  %s --profile PROFILE\n' "$0" >&2
  printf 'Alternatively, run this deployment from AWS CloudShell, which uses your active console credentials.\n' >&2
  die "AWS authentication is required"
fi

if [ -n "${AWS_PROFILE:-}" ]; then
  printf 'Authenticated with AWS profile %s.\n' "$AWS_PROFILE"
else
  printf 'Authenticated with the active AWS credential chain.\n'
fi

ACCOUNT="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<< "$CALLER_JSON")"
CALLER_ARN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])' <<< "$CALLER_JSON")"
printf '\nDeployment identity:\n  Account: %s\n  Caller:  %s\n  Region:  %s\n' \
  "$ACCOUNT" "$CALLER_ARN" "$REGION"

while true; do
  read -r -p "Initial Cognito administrator email (receives the temporary password for first sign-in): " ADMIN_EMAIL
  if [[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    break
  fi
  printf 'Enter a valid email address.\n' >&2
done

case "$REGION" in
  us-east-1) REGION_LABEL="use1" ;;
  us-east-2) REGION_LABEL="use2" ;;
  us-west-2) REGION_LABEL="usw2" ;;
  eu-west-1) REGION_LABEL="euw1" ;;
  eu-west-2) REGION_LABEL="euw2" ;;
  eu-central-1) REGION_LABEL="euc1" ;;
  ap-southeast-1) REGION_LABEL="apse1" ;;
  ap-southeast-2) REGION_LABEL="apse2" ;;
  *) die "Unsupported Region: $REGION" ;;
esac
DEFAULT_PROJECT="vectorless-v3-$REGION_LABEL"
while true; do
  read -r -p "Project name [$DEFAULT_PROJECT]: " PROJECT_NAME
  PROJECT_NAME="${PROJECT_NAME:-$DEFAULT_PROJECT}"
  if [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]{2,24}$ ]]; then
    break
  fi
  printf 'Use 3 to 25 lowercase letters, numbers, or hyphens, starting with a letter or number.\n' >&2
done

printf '\nDefault Bedrock inference profiles:\n  Router: %s\n  Answer: %s\n' \
  "$ROUTER_MODEL_ID" "$ANSWER_MODEL_ID"
printf 'Global inference profiles may route requests across AWS Regions. Cancel if that conflicts with residency requirements.\n'

TFVARS="$TF/terraform.tfvars"
if [ -e "$TFVARS" ]; then
  BACKUP_TFVARS="$TF/backup-$(date -u +%Y%m%dT%H%M%SZ).tfvars"
  cp "$TFVARS" "$BACKUP_TFVARS"
  printf 'Preserved existing configuration at %s\n' "$BACKUP_TFVARS"
fi
umask 077
cat > "$TFVARS" <<EOF
region           = "$REGION"
project_name     = "$PROJECT_NAME"
admin_user_email = "$ADMIN_EMAIL"

router_model_id = "$ROUTER_MODEL_ID"
answer_model_id = "$ANSWER_MODEL_ID"
EOF

export EXPECTED_AWS_ACCOUNT_ID="$ACCOUNT"
export ROUTER_MODEL_ID
export ANSWER_MODEL_ID

printf '\nRunning local validation...\n'
cd "$ROOT"
python3 -m unittest discover -s lambdas/tests -v
(
  cd frontend
  npm ci
  npm run build
  npm audit --omit=dev
)
bash -n scripts/check_prerequisites.sh
bash -n scripts/preflight_v3.sh
bash -n scripts/fetch_and_upload_danfoss.sh
bash -n scripts/upload_v3_manual.sh
bash -n scripts/deploy_v3_frontend.sh
bash -n scripts/teardown_v3.sh
./scripts/build_v3_lambdas.sh

printf '\nRunning live regional and Bedrock model preflight...\n'
./scripts/preflight_v3.sh "$REGION"

printf '\nCreating the Terraform plan...\n'
terraform -chdir="$TF" init -input=false
terraform -chdir="$TF" fmt -check
terraform -chdir="$TF" validate
PLAN="$TF/v3-$(date -u +%Y%m%dT%H%M%SZ).plan"
terraform -chdir="$TF" plan -input=false -out="$PLAN"

PLAN_SUMMARY="$(terraform -chdir="$TF" show -json "$PLAN" | python3 -c '
import collections
import json
import sys
plan = json.load(sys.stdin)
changes = plan.get("resource_changes", [])
counts = collections.Counter(tuple(item["change"]["actions"]) for item in changes)
creates = counts.get(("create",), 0)
updates = counts.get(("update",), 0)
deletes = sum(count for actions, count in counts.items() if "delete" in actions)
print(f"creates={creates} updates={updates} deletes={deletes}")
if updates or deletes or creates == 0:
    raise SystemExit(2)
')" || die "Plan must contain one or more creates and no updates or deletions"
printf 'Validated plan: %s\nSaved plan: %s\n' "$PLAN_SUMMARY" "$PLAN"

if [ "$MODE" = "plan-only" ]; then
  printf 'Plan-only run complete. No AWS resources were created.\n'
  exit 0
fi

printf '\nDeployment summary\n\n'
printf '  Account:       %s\n' "$ACCOUNT"
printf '  Region:        %s\n' "$REGION"
printf '  Project:       %s\n' "$PROJECT_NAME"
printf '  Administrator: %s\n' "$ADMIN_EMAIL"
printf '  Models:        Claude Haiku 4.5 and Claude Sonnet 4.6\n\n'
read -r -p "Deploy? [y/N]: " APPLY_CONFIRMATION
case "$APPLY_CONFIRMATION" in
  y|Y|yes|YES) ;;
  *) die "Deployment was not confirmed" ;;
esac
terraform -chdir="$TF" apply -input=false "$PLAN"

WEB_URL="$(terraform -chdir="$TF" output -raw web_url)"
printf '\nWaiting for the anonymous authentication gate at %s...\n' "$WEB_URL"
AUTH_VERIFIED="false"
for ((attempt = 1; attempt <= AUTH_GATE_MAX_ATTEMPTS; attempt++)); do
  RESPONSE="$(curl --silent --show-error --max-time "$HTTP_REQUEST_TIMEOUT_SECONDS" --write-out $'\n%{http_code}' \
    "$WEB_URL/api/ask/orders" || true)"
  HTTP_STATUS="${RESPONSE##*$'\n'}"
  RESPONSE_BODY="${RESPONSE%$'\n'*}"
  if [ "$HTTP_STATUS" = "401" ] && [[ "$RESPONSE_BODY" == *"Sign in required"* ]]; then
    AUTH_VERIFIED="true"
    break
  fi
  printf '  Attempt %d: HTTP %s\n' "$attempt" "${HTTP_STATUS:-unavailable}"
  sleep "$POLL_INTERVAL_SECONDS"
done
if [ "$AUTH_VERIFIED" != "true" ]; then
  printf 'Terraform state was preserved at %s/terraform.tfstate.\n' "$TF" >&2
  printf 'Correct the authentication gate, verify HTTP 401 manually, then resume with scripts/deploy_v3_frontend.sh.\n' >&2
  die "Anonymous access was not denied with the expected 401 response. Frontend publication is blocked."
fi
printf 'Anonymous authentication gate verified: HTTP 401.\n'

printf '\nPublishing the frontend after the verified authentication gate...\n'
if ! ./scripts/deploy_v3_frontend.sh <<< "y"; then
  print_resume_help
  die "Frontend deployment did not complete; infrastructure state was preserved"
fi

printf '\nFetching, verifying, and uploading the tested Danfoss manual...\n'
if ! ./scripts/fetch_and_upload_danfoss.sh <<< "y"; then
  print_resume_help
  die "Manual download or upload did not complete; infrastructure and frontend remain deployed"
fi

TABLE="$(terraform -chdir="$TF" output -raw metadata_table)"
printf 'Waiting for the manual CURRENT pointer...\n'
for ((attempt = 1; attempt <= MANUAL_INGEST_MAX_ATTEMPTS; attempt++)); do
  DANFOSS_REVISION="$(aws dynamodb get-item \
    --region "$REGION" \
    --table-name "$TABLE" \
    --key '{"pk":{"S":"MANUAL#PART#DANFOSS-FC280"},"sk":{"S":"CURRENT"}}' \
    --consistent-read \
    --query 'Item.revision.S' \
    --output text 2>/dev/null || true)"
  if [ "$DANFOSS_REVISION" = "r1" ]; then
    printf 'The sample manual is ready.\n'
    break
  fi
  if [ "$attempt" -eq "$MANUAL_INGEST_MAX_ATTEMPTS" ]; then
    print_resume_help
    die "Manual ingestion did not finish within $MANUAL_INGEST_TIMEOUT_MINUTES minutes. Inspect the ingest logs and DLQ, then rerun only the manual command if needed."
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

printf '\nDeployment complete.\n  Account: %s\n  Region:  %s\n  Project: %s\n  URL:     %s\n' \
  "$ACCOUNT" "$REGION" "$PROJECT_NAME" "$WEB_URL"
printf 'Use the Cognito invitation sent to %s, then run the known-answer and absent-answer checks in the README.\n' \
  "$ADMIN_EMAIL"
