#!/usr/bin/env bash
# 10-apt-base.sh — base packages every dome machine gets.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_root

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: apt-get update"
else
  apt-get update
fi

ensure_pkg \
  build-essential \
  ca-certificates \
  curl \
  git \
  make \
  unzip \
  timeshift
