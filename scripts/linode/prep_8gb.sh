#!/usr/bin/env bash
set -euo pipefail

export OPENCLAW_PROFILE="8gb"
exec bash "$(dirname "$0")/prep_common.sh"
