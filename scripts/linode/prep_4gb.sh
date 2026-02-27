#!/usr/bin/env bash
set -euo pipefail

export OPENCLAW_PROFILE="4gb"
exec bash "$(dirname "$0")/prep_common.sh"
