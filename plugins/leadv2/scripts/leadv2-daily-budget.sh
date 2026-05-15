#!/usr/bin/env bash
# DEPRECATED: leadv2-daily-budget.sh → superseded by leadv2-quota-status.sh (R7)
#
# Subscription plan makes $-budget meaningless; the real limit is the 5h/weekly
# token quota. This stub forwards all args to leadv2-quota-status.sh for back-compat.
set -euo pipefail
echo "DEPRECATED: use leadv2-quota-status.sh (subscription tokens, not \$)" >&2
exec "$(dirname "$0")/leadv2-quota-status.sh" "$@"
