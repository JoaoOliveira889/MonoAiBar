#!/usr/bin/env bash
set -euo pipefail

./scripts/build.sh

echo "==> Starting MonoAiBar in menu bar..."
exec .build/release/MonoAiBar
