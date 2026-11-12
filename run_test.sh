#!/bin/sh
# Runs a test binary in the given directory. `cabal test` runs a test-suite
# in its package's directory, and some tests rely on that.
#
# Invoked as: run_test.sh <cwd> <binary> [args...]
set -eu

# The binary's path is relative to the directory that this script starts
# in, not to $cwd, so the script makes it absolute before it changes
# directory.
absolute() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$PWD/$1" ;;
  esac
}

cwd=$1
bin=$(absolute "$2")
shift 2

cd "$cwd"
exec "$bin" "$@"
