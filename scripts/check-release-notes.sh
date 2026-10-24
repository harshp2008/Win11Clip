#!/usr/bin/env bash
# Fail unless docs/release-notes/<version>.md exists, is not empty, and is
# linked from docs/release-notes/index.md.
# Usage: scripts/check-release-notes.sh <version or tag, e.g. 0.7.6 or v0.7.6>
set -euo pipefail

version="${1:-}"
version="${version#v}"
if [ -z "$version" ]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/docs/release-notes"
file="$dir/$version.md"

if [ ! -f "$file" ]; then
  echo "::error::Missing release notes: docs/release-notes/$version.md. Write it and link it from docs/release-notes/index.md." >&2
  exit 1
fi
if ! grep -q '[^[:space:]]' "$file"; then
  echo "::error::Release notes are empty: docs/release-notes/$version.md" >&2
  exit 1
fi
if ! grep -qF "]($version.md)" "$dir/index.md"; then
  echo "::error::docs/release-notes/index.md does not link to $version.md" >&2
  exit 1
fi
echo "Release notes OK: docs/release-notes/$version.md"
