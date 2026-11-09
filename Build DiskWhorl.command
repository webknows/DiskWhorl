#!/bin/zsh
# Double-click in Finder to build DiskWhorl and install it to ~/Applications.
# The full compiler output is written to build/build.log.
cd "$(dirname "$0")"
mkdir -p build
LOG="$PWD/build/build.log"
{
  echo "=== Build started $(date) ==="
  zsh Scripts/build-app.sh --install
  echo "EXIT CODE: $?"
  echo "=== Build ended $(date) ==="
} > "$LOG" 2>&1
tail -n 4 "$LOG"
echo
echo "Full log: build/build.log"
