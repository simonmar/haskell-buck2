#!/bin/sh
# Runs a binary with its cwd set to a given directory - used by
# haskell_test()'s own `cwd` attribute (see haskell.bzl) to match real
# `cabal test`'s own invariant (it always runs a test-suite with its cwd
# set to the package's own directory), which buck2's sh_test() has no
# built-in concept of.
#
# Invoked as: run_in_cwd.sh <cwd> <binary> [args...]
set -eu

cwd=$1
bin=$2
shift 2

# $bin (typically a `$(exe ...)` macro expansion) is only guaranteed
# valid from the cwd this script itself started in - not from `$cwd`,
# about to be cd'd into - so it's resolved to an absolute path first.
case "$bin" in
  /*) ;;
  *) bin="$PWD/$bin" ;;
esac

cd "$cwd"
exec "$bin" "$@"
