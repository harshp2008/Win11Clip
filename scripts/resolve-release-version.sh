#!/usr/bin/env bash
# Print the release version for release.yml.
# Usage: scripts/resolve-release-version.sh <event name> <git ref> [version input]
# push:              the tag name without refs/tags/v, as the workflow always did.
# workflow_dispatch: the version input, else the version in package.json.
set -euo pipefail

event="${1:-}"
ref="${2:-}"
input="${3:-}"

if [ "$event" = "push" ]; then
  echo "${ref#refs/tags/v}"
  exit 0
fi

version="${input#v}"
if [ -z "$version" ]; then
  version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -1)"
fi
# The version is later used in shell commands and sed, so accept only a plain one.
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$'; then
  echo "::error::Not a usable version: '$version'" >&2
  exit 1
fi
echo "$version"
