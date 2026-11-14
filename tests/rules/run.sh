#!/usr/bin/env bash
# Runs the tests of the rules (see README.md).
#
# usage: tests/rules/run.sh GHC_BIN_DIR [WORK_DIR] [-- CHECK_ARGS...]
#
# GHC_BIN_DIR has ghc and ghc-pkg. The project is copied to WORK_DIR (default:
# a new temporary directory) and built there with the buck2 on PATH; the checks
# edit its sources. With BAZEL_REMOTE set to a bazel-remote binary, check_cache
# builds with it as a remote cache. With BUCK2_GHC_WORKER set to a
# buck2-ghc-worker that was built with the same GHC, the modules are compiled
# in that worker. The buck2 daemon is killed at the end.
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
if [ -n "${BUCK2_GHC_WORKER:-}" ]; then
  worker=$(cd "$(dirname "$BUCK2_GHC_WORKER")" && pwd)/$(basename "$BUCK2_GHC_WORKER")
  printf '\n[haskell]\n  per_module_worker = %s\n' "$worker" >> "$project/.buckconfig"
fi

python3 "$here/gen_prebuilt.py" "$ghc_bin/ghc" "$project/third-party/haskell"

cd "$project"
status=0
python3 "$here/check.py" ${BAZEL_REMOTE:+--bazel-remote "$BAZEL_REMOTE"} ${BUCK2_GHC_WORKER:+--worker} "$@" || status=$?
buck2 kill > /dev/null 2>&1 || true
exit $status
