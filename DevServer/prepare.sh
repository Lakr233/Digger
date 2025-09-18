#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p public
# 10 MB file for range/resume tests
python3 - <<'PY'
import os
size = 10 * 1024 * 1024
with open('public/bigfile.bin', 'wb') as f:
    f.truncate(size)
PY

echo "hello from nginx" > public/hello.txt

echo "Prepared public assets:"
ls -l public
