#!/bin/bash
# swift test は Command Line Tools だけでは動かないため、純粋ロジックだけを swiftc で単体ビルドして検査する。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -parse-as-library -o "$OUT/check" \
    "$ROOT/Sources/Koe/Services/TriggerStateMachine.swift" \
    "$ROOT/Sources/Koe/Services/LiveTextReconciler.swift" \
    "$ROOT/Sources/Koe/Services/UserDictionary.swift" \
    "$ROOT/scripts/LiveTextReconcilerCheck.swift" \
    "$ROOT/scripts/UserDictionaryCheck.swift" \
    "$ROOT/scripts/TriggerStateMachineCheck.swift"
"$OUT/check"
