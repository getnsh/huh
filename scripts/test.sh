#!/usr/bin/env bash
# Runs every verification suite. Each compiles the shipping sources directly —
# no duplicated logic, no mocks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

status=0
run() {
    echo "── $1 ─────────────────────────────────────────"
    if "$2"; then echo; else status=1; echo; fi
}

run "corrections"   ./scripts/verify-corrections.sh
run "cleanup"       ./scripts/verify-cleanup.sh
run "plausibility"  ./scripts/verify-plausibility.sh
run "extraction"    ./scripts/verify-extraction.sh

if [ "$status" -eq 0 ]; then
    echo "All suites passed."
else
    echo "One or more suites failed." >&2
fi
exit "$status"
