#!/usr/bin/env bash
# Runs the tests of the per-module rules (see README.md).
#
# usage: tests/rules/run.sh GHC_BIN_DIR [WORK_DIR] [-- CHECK_ARGS...]
#
# GHC_BIN_DIR has ghc and ghc-pkg. The project is copied to WORK_DIR
# (default: a new temporary directory) and built there with the buck2 on
# PATH; the checks edit its sources. The buck2 daemon is killed at the end.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
ghc_bin=$(cd "$1" && pwd)
shift
if [ $# -gt 0 ] && [ "$1" != "--" ]; then work=$1; shift; else work=$(mktemp -d); fi
if [ $# -gt 0 ] && [ "$1" = "--" ]; then shift; fi

project=$work/project
if [ -d "$project" ]; then (cd "$project" && buck2 kill > /dev/null 2>&1 || true); fi
rm -rf "$project"
mkdir -p "$work"
echo "project: $project"
cp -r "$here/project" "$project"
# An absolute path: buck2 doesn't accept a symlink with ".." in it.
ln -s "$repo" "$project/buck2"

python3 "$here/gen_prebuilt.py" "$ghc_bin/ghc" "$project/third-party/haskell"

cd "$project"
status=0
python3 "$here/check.py" "$@" || status=$?
buck2 kill > /dev/null 2>&1 || true
exit $status
