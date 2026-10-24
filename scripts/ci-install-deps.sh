#!/usr/bin/env bash
# Install the system packages the Tauri build needs. A slow Ubuntu mirror has
# stalled this step for 10-18 minutes in CI, so apt gets its own retries and
# timeouts, and each attempt is capped and retried.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt_opts=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
packages=(
  libwebkit2gtk-4.1-dev build-essential curl wget file
  libssl-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev
  libgtk-3-dev libglib2.0-dev
)

retry() {
  local n
  for n in 1 2 3; do
    if timeout 180 "$@"; then
      return 0
    fi
    echo "attempt $n failed: $*" >&2
    sudo dpkg --configure -a || true
    sleep 5
  done
  return 1
}

retry sudo apt-get "${apt_opts[@]}" update
retry sudo apt-get "${apt_opts[@]}" install -y "${packages[@]}"
