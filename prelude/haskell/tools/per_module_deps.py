#!/usr/bin/env python3
# The module graph of a target compiled per-module (see compile_per_module
# in prelude/haskell/compile_per_module.bzl): runs `ghc -M`, then writes the
# path of each source that runs Template Haskell, one per line.
#
# usage: per_module_deps.py OUT SRCS... -- GHC_M_COMMAND...
#
# A source runs Template Haskell if its own pragmas enable TemplateHaskell
# or QuasiQuotes (the target's flags may enable them for every source,
# which compile_per_module.bzl takes into account), or if it has an ANN pragma,
# which GHC also evaluates with its interpreter.

import re
import subprocess
import sys

# A source that may run Template Haskell. Not TemplateHaskellQuotes alone,
# whose quotes run nothing at compile time (a splice in a quote is only
# code the quote builds).
MAY_RUN_TH = re.compile(r"TemplateHaskell(?!Quotes)|QuasiQuotes|\{-# *ANN ")


def may_run_th(text):
    return MAY_RUN_TH.search(text) is not None


def main():
    out = sys.argv[1]
    args = sys.argv[2:]
    sep = args.index("--")
    srcs, command = args[:sep], args[sep + 1:]
    code = subprocess.call(command)
    if code != 0:
        sys.exit(code if code > 0 else 128 - code)

    lines = []
    for src in srcs:
        with open(src, encoding="utf-8", errors="replace") as f:
            if may_run_th(f.read()):
                lines.append(src + "\n")
    with open(out, "w") as f:
        f.writelines(lines)


if __name__ == "__main__":
    main()
