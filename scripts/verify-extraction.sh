#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cp scripts/verify-extraction.swift "$OUT/main.swift"
swiftc \
    Sources/Huh/Services/EditDistance.swift \
    Sources/Huh/Services/ModelReply.swift \
    Sources/Huh/Core/TokenBudget.swift \
    scripts/support/StringTrimmed.swift \
    "$OUT/main.swift" -o "$OUT/verify"
"$OUT/verify"
