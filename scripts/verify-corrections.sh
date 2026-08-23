#!/usr/bin/env bash
# Compiles the real CorrectionEngine + CorrectionSafety against the real models
# and runs the assertions in verify-corrections.swift. No mocks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Top-level code is only allowed in a file called main.swift.
cp scripts/verify-corrections.swift "$OUT/main.swift"
swiftc \
    Sources/Huh/Model/DictionaryEntry.swift \
    Sources/Huh/Model/Transcript.swift \
    Sources/Huh/Services/CorrectionEngine.swift \
    Sources/Huh/Services/CorrectionSafety.swift \
    "$OUT/main.swift" \
    -o "$OUT/verify"
"$OUT/verify"
