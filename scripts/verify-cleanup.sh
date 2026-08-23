#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cp scripts/verify-cleanup.swift "$OUT/main.swift"
swiftc Sources/Huh/Services/TextCleanup.swift "$OUT/main.swift" -o "$OUT/verify"
"$OUT/verify"
