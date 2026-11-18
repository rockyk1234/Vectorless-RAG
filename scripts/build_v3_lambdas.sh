#!/usr/bin/env bash
# Build the regional v3 Lambda packages without DocumentDB or VPC dependencies.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TREE="$ROOT/lambdas/tree"
BUILD="$ROOT/lambdas/build-v3-portable"
IMG="$BUILD/img_layer/python"

mkdir -p "$BUILD/ingest" "$BUILD/query" "$IMG"

if [ ! -d "$IMG/pypdfium2" ] || [ ! -d "$IMG/Pillow-13.0.0.dist-info" ]; then
  if command -v uv >/dev/null 2>&1; then
    uv pip install \
      --python-platform x86_64-manylinux_2_28 \
      --python-version 3.12 \
      --only-binary=:all: \
      --target "$IMG" \
      --requirements "$ROOT/lambdas/requirements-v3.txt" >/dev/null
  else
    python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' || {
      printf 'Python 3.11+ or uv is required to package the Python 3.12 imaging layer.\n' >&2
      exit 1
    }
    python3 -m pip install \
      --platform manylinux_2_28_x86_64 \
      --implementation cp \
      --python-version 3.12 \
      --only-binary=:all: \
      --target "$IMG" \
      --requirements "$ROOT/lambdas/requirements-v3.txt" >/dev/null
  fi
fi

cp "$TREE/tree_builder.py" "$TREE/adapters.py" "$BUILD/ingest/"
cp "$TREE/ingest_handler.py" "$BUILD/ingest/handler.py"

cp "$TREE/runtime.py" "$TREE/adapters.py" "$TREE/auth.py" "$BUILD/query/"
cp "$TREE/query_handler.py" "$BUILD/query/handler.py"
cp "$TREE/orders.json" "$TREE/compatibility.json" "$BUILD/query/"

printf 'v3 ingest package ready: %s\n' "$BUILD/ingest"
printf 'v3 query package ready: %s\n' "$BUILD/query"
