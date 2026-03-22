#!/usr/bin/env bash
set -e

# Build gh-task for the current platform
# Used by: gh extension install HikaruEgashira/gh-task

zig build -Doptimize=ReleaseSafe
cp zig-out/bin/gh-task .
echo "Built gh-task successfully"
