#!/usr/bin/env bash
# Read changed file paths (one per line) on stdin and print `code=true` or
# `code=false`. false only when every path is documentation. Code paths win
# over doc patterns, and an unknown path counts as code, so the build is only
# skipped when that is clearly safe. An empty list counts as code.
# Usage: git diff --name-only --no-renames A B | scripts/ci-classify-changes.sh
set -euo pipefail

is_code() {
  case "$1" in
    .github/workflows/* | src/* | src-tauri/* | scripts/*) return 0 ;;
    package.json | package-lock.json | */package.json | */package-lock.json) return 0 ;;
    *.lock | Cargo.toml | */Cargo.toml) return 0 ;;
  esac
  return 1
}

is_docs() {
  case "$1" in
    docs/* | *.md | LICENSE | LICENSE.* | .github/FUNDING.yml) return 0 ;;
    .github/ISSUE_TEMPLATE/* | .github/PULL_REQUEST_TEMPLATE*) return 0 ;;
  esac
  return 1
}

seen=0
code=false
while IFS= read -r path; do
  [ -n "$path" ] || continue
  seen=1
  if is_code "$path" || ! is_docs "$path"; then
    code=true
  fi
done

[ "$seen" -eq 1 ] || code=true
echo "code=$code"
