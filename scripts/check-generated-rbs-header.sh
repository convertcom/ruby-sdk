#!/usr/bin/env bash
# check-generated-rbs-header.sh — PR-blocking guard (qs-03 / B5).
#
# Mirrors the android-sdk "Enforce generated-file header (OpenAPI types)" guard
# (android-sdk/.github/workflows/ci.yml:51). Every .rbs file under
# sig/convert_sdk/config/generated/ MUST start with the generated-marker
# comment. Files that lack the header are either hand-edited or mistakenly
# added to the directory — both are PR blockers. Regenerate via the backend
# serving workflow and re-sync; never edit generated files in place.
#
# Usage: ./scripts/check-generated-rbs-header.sh
#   Run from the ruby-sdk repo root. Exits 0 when all files carry the marker;
#   exits 1 listing every offending file.

set -euo pipefail

GEN_DIR="sig/convert_sdk/config/generated"
MARKER="AUTO-GENERATED FROM backend apiDoc/serving"

if [ ! -d "$GEN_DIR" ]; then
  echo "ERROR: generated directory not found: $GEN_DIR"
  echo "       Expected the directory to exist after Task B1 (qs-03)."
  exit 1
fi

missing=0
while IFS= read -r -d '' file; do
  if ! head -1 "$file" | grep -q "$MARKER"; then
    echo "ERROR: $file is missing the auto-generated header."
    echo "       Expected line 1 to contain: $MARKER"
    echo "       Regenerate via 'yarn generateRubyRbs' in backend/apiDoc/serving"
    echo "       and re-sync per sig/convert_sdk/config/generated/. Do not hand-edit."
    missing=1
  fi
done < <(find "$GEN_DIR" -name '*.rbs' -print0)

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: every .rbs file under $GEN_DIR carries the auto-generated header."
