#!/bin/sh
# Runs a test binary as `cabal test` runs a test-suite: in a given directory
# (the package's), with the executables of its build-tool-depends on PATH.
#
# Invoked as: run_test.sh <cwd> [<tool>...] -- <binary> [args...]
set -eu

# The paths (`$(location ...)` and `$(exe_target ...)` expansions) are relative
# to the directory this script starts in, not $cwd.
absolute() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$PWD/$1" ;;
  esac
}

cwd=$1
shift

# The tools come first, so that the test runs the ones it was built with
# rather than any others of the same name.
tools=
while [ "$1" != -- ]; do
  tools="$tools$(dirname "$(absolute "$1")"):"
  shift
done
shift

bin=$(absolute "$1")
shift

PATH="$tools${PATH-}"
export PATH
cd "$cwd"
exec "$bin" "$@"
