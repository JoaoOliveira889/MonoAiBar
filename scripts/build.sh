#!/usr/bin/env bash
set -euo pipefail

if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "==> Building MonoAiBar in Release mode for Apple Silicon (ARM64)..."
swift build -c release --arch arm64

echo "==> Binary successfully generated at: .build/release/MonoAiBar"
