#!/usr/bin/env bash
# Validate tools, credentials, regional service access, and Bedrock tool use.
set -euo pipefail

REGION="${1:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
ROUTER_MODEL_ID="${ROUTER_MODEL_ID:-}"
ANSWER_MODEL_ID="${ANSWER_MODEL_ID:-}"

[ -n "$REGION" ] || {
  printf 'Pass the Terraform region as argument 1 or set AWS_REGION/AWS_DEFAULT_REGION.\n' >&2
  exit 1
}
[ -n "$ROUTER_MODEL_ID" ] || {
  printf 'Set ROUTER_MODEL_ID to the same value used by Terraform.\n' >&2
  exit 1
}
[ -n "$ANSWER_MODEL_ID" ] || {
  printf 'Set ANSWER_MODEL_ID to the same value used by Terraform.\n' >&2
  exit 1
}

for tool in aws terraform python3 node npm; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing required tool: %s\n' "$tool" >&2
    exit 1
  }
done

if ! command -v uv >/dev/null 2>&1; then
  python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' || {
    printf 'Python 3.11+ or uv is required to package the Python 3.12 Lambda layer.\n' >&2
    exit 1
  }
fi

ACCOUNT="$(aws sts get-caller-identity --region "$REGION" --query Account --output text)"
ARN="$(aws sts get-caller-identity --region "$REGION" --query Arn --output text)"
if [ -n "${EXPECTED_AWS_ACCOUNT_ID:-}" ] && [ "$ACCOUNT" != "$EXPECTED_AWS_ACCOUNT_ID" ]; then
  printf 'AWS account mismatch: expected %s, got %s\n' "$EXPECTED_AWS_ACCOUNT_ID" "$ACCOUNT" >&2
  exit 1
fi
printf 'AWS caller: %s\nAWS account: %s\nTarget Region: %s\n' "$ARN" "$ACCOUNT" "$REGION"

TEXTRACT_ERROR=""
if ! TEXTRACT_ERROR="$(aws textract list-adapters --region "$REGION" --max-results 1 2>&1)"; then
  case "$TEXTRACT_ERROR" in
    *AccessDenied*|*UnauthorizedOperation*)
      printf 'Warning: Textract exists in %s, but this caller cannot run ListAdapters.\n' "$REGION" >&2
      ;;
    *)
      printf 'Textract preflight failed in %s: %s\n' "$REGION" "$TEXTRACT_ERROR" >&2
      exit 1
      ;;
  esac
fi

MESSAGES='[{"role":"user","content":[{"text":"Call the preflight tool with ok=true."}]}]'
TOOL_CONFIG='{"tools":[{"toolSpec":{"name":"preflight","description":"Confirm tool use support.","inputSchema":{"json":{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}}}}],"toolChoice":{"tool":{"name":"preflight"}}}'
INFERENCE_CONFIG='{"maxTokens":128,"temperature":0}'

check_model() {
  local purpose="$1"
  local model_id="$2"
  local result
  printf 'Checking %s model: %s\n' "$purpose" "$model_id"
  result="$(aws bedrock-runtime converse \
    --region "$REGION" \
    --model-id "$model_id" \
    --messages "$MESSAGES" \
    --tool-config "$TOOL_CONFIG" \
    --inference-config "$INFERENCE_CONFIG" \
    --query 'output.message.content[0].toolUse.input.ok' \
    --output text)"
  if [ "$result" != "True" ] && [ "$result" != "true" ]; then
    printf '%s model did not return the required tool result. Got: %s\n' "$purpose" "$result" >&2
    exit 1
  fi
}

check_model "router" "$ROUTER_MODEL_ID"
if [ "$ANSWER_MODEL_ID" != "$ROUTER_MODEL_ID" ]; then
  check_model "answer" "$ANSWER_MODEL_ID"
fi

printf 'Preflight passed for account %s in %s.\n' "$ACCOUNT" "$REGION"
printf 'The two model checks are bounded, billable Bedrock requests with no customer data.\n'
