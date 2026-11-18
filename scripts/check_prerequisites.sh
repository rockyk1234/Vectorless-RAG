#!/usr/bin/env bash
# Validate local tools and versions without installing or changing anything.
set -u

MODE="${1:-full}"
case "$MODE" in
  full|frontend|fetch|upload|teardown) ;;
  *)
    printf 'Usage: %s [full|frontend|fetch|upload|teardown]\n' "$0" >&2
    exit 2
    ;;
esac

FAILURES=0
AWS_HELP="false"
TERRAFORM_HELP="false"
PYTHON_HELP="false"
NODE_HELP="false"
CURL_HELP="false"

pass() {
  printf '  PASS  %s\n' "$1"
}

fail() {
  printf '  FAIL  %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

version_at_least() {
  local actual="$1"
  local minimum_major="$2"
  local minimum_minor="$3"
  local major
  local minor
  IFS=. read -r major minor _ <<< "$actual"
  major="${major//[!0-9]/}"
  minor="${minor//[!0-9]/}"
  [ -n "$major" ] && [ -n "$minor" ] \
    && { [ "$major" -gt "$minimum_major" ] \
      || { [ "$major" -eq "$minimum_major" ] && [ "$minor" -ge "$minimum_minor" ]; }; }
}

needs_python="false"
needs_node="false"
needs_curl="false"
case "$MODE" in
  full)
    needs_python="true"
    needs_node="true"
    needs_curl="true"
    ;;
  frontend)
    needs_node="true"
    ;;
  fetch)
    needs_python="true"
    needs_curl="true"
    ;;
  teardown)
    needs_python="true"
    ;;
  upload) ;;
esac

printf 'Checking %s prerequisites...\n' "$MODE"

if [ "${BASH_VERSINFO[0]}" -gt 3 ] \
    || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  pass "Bash ${BASH_VERSION}"
else
  fail "Bash 3.2 or later is required; found ${BASH_VERSION}"
fi

if has_command aws; then
  AWS_VERSION="$(aws --version 2>&1)"
  case "$AWS_VERSION" in
    aws-cli/2.*) pass "$AWS_VERSION" ;;
    *) AWS_HELP="true"; fail "AWS CLI v2 is required; found $AWS_VERSION" ;;
  esac
else
  AWS_HELP="true"
  fail "AWS CLI v2 is not installed"
fi

if has_command terraform; then
  TERRAFORM_OUTPUT="$(terraform version 2>&1)"
  TERRAFORM_LINE="${TERRAFORM_OUTPUT%%$'\n'*}"
  TERRAFORM_VERSION="${TERRAFORM_LINE#Terraform v}"
  TERRAFORM_VERSION="${TERRAFORM_VERSION%% *}"
  if version_at_least "$TERRAFORM_VERSION" 1 5; then
    pass "Terraform $TERRAFORM_VERSION"
  else
    TERRAFORM_HELP="true"
    fail "Terraform 1.5 or later is required; found $TERRAFORM_VERSION"
  fi
else
  TERRAFORM_HELP="true"
  fail "Terraform 1.5 or later is not installed"
fi

if [ "$needs_python" = "true" ]; then
  if has_command python3; then
    PYTHON_VERSION="$(python3 -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"
    if version_at_least "$PYTHON_VERSION" 3 11; then
      pass "Python $PYTHON_VERSION"
    else
      PYTHON_HELP="true"
      fail "Python 3.11 or later is required; found ${PYTHON_VERSION:-unknown}"
    fi
  else
    PYTHON_HELP="true"
    fail "Python 3.11 or later is not installed as python3"
  fi
fi

if [ "$needs_node" = "true" ]; then
  if has_command node; then
    NODE_VERSION="$(node -p 'process.versions.node' 2>/dev/null || true)"
    IFS=. read -r NODE_MAJOR NODE_MINOR _ <<< "$NODE_VERSION"
    if [ -n "$NODE_MAJOR" ] && [ -n "$NODE_MINOR" ] \
        && { { [ "$NODE_MAJOR" -eq 20 ] && [ "$NODE_MINOR" -ge 19 ]; } \
          || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -ge 13 ]; } \
          || [ "$NODE_MAJOR" -gt 22 ]; }; then
      pass "Node.js $NODE_VERSION"
    else
      NODE_HELP="true"
      fail "Node.js 20.19 or later, or 22.13 or later, is required; found ${NODE_VERSION:-unknown}"
    fi
  else
    NODE_HELP="true"
    fail "Node.js 20.19 or later, or 22.13 or later, is not installed"
  fi

  if has_command npm; then
    pass "npm $(npm --version 2>/dev/null || printf 'unknown')"
  else
    NODE_HELP="true"
    fail "npm is not installed"
  fi
fi

if [ "$needs_curl" = "true" ]; then
  if has_command curl; then
    CURL_VERSION="$(curl --version 2>/dev/null)"
    pass "${CURL_VERSION%%$'\n'*}"
  else
    CURL_HELP="true"
    fail "curl is not installed"
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\nInstall or update only the failed prerequisites using your organization-approved method:\n' >&2
  [ "$AWS_HELP" = "true" ] && printf '  AWS CLI:   https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html\n' >&2
  [ "$TERRAFORM_HELP" = "true" ] && printf '  Terraform: https://developer.hashicorp.com/terraform/install\n' >&2
  [ "$PYTHON_HELP" = "true" ] && printf '  Python:    https://www.python.org/downloads/\n' >&2
  [ "$NODE_HELP" = "true" ] && printf '  Node.js:   https://nodejs.org/en/download\n' >&2
  [ "$CURL_HELP" = "true" ] && printf '  curl:      https://curl.se/download.html\n' >&2
  printf '\nNo AWS calls or resource changes were made by this prerequisite check.\n' >&2
  printf 'After correcting the listed tools, rerun the same command.\n' >&2
  exit 1
fi

printf 'All required %s prerequisites are ready.\n' "$MODE"
