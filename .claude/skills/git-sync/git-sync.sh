#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$WORKSPACE_DIR/.workspace/skills/git-sync/git-sync.sh" "$@"
