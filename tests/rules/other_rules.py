"""The checks of the rest of the rules: haskell_test, linking, and the
toolchains."""

import os
import re
import stat
import tempfile

from harness import COMPILES, buck2, configured, expect, expect_output, tail, write


def check_test_build_tools(st):
    """A test runs with its build_tool_depends on PATH, as `cabal test` runs
    a test-suite: uses-tool runs //test-suite:tool by name."""
    buck2("test", "//test-suite:uses-tool")


def check_data_files(st):
    """A binary with data_dirs finds its data files through the variables
    they set, both with `buck2 run` and as a test."""
    expect_output("//test-suite:reads-data-bin", "with buck2 run", "hello")
    buck2("test", "//test-suite:reads-data")


def check_test_labels(st):
    """A test's labels are the test's, so `buck2 test --exclude manual`
    leaves out //test-suite:manual, which fails."""
    p = buck2("test", "//test-suite:manual", ok=False)
    expect("//test-suite:manual fails when it is asked for", p.returncode != 0)
    p = buck2("test", "//test-suite:", "--exclude", "manual", ok=False)
    expect("`buck2 test //test-suite: --exclude manual` passes (got:\n{})".format(tail(p.stderr, 15)), p.returncode == 0)


def check_profiled_shared_only(st):
    """A profiled binary, linked static or static_pic, links the profiled
    archive of a library that is otherwise only shared."""
    for c in COMPILES:
        for binary in ["static", "static-pic"]:
            expect_output(configured("//prof-shared:" + binary, c), "compiled {}".format(c), "7")


# The names of the tools that the toolchains once ran from the daemon's PATH.
_TOOLS = ["ghc", "ghc-pkg", "haddock", "hsc2hs"]
_C_TOOLS = ["clang", "clang++", "c++", "g++"]


def check_toolchain_paths(st):
    """The toolchains run the tools that the project names (in tools.bzl,
    which `cabal buck2` writes), not those on the PATH of the buck2 daemon:
    with tools of the same names that fail ahead of the real ones on the
    daemon's PATH, a clean build of lib-user (GHC and ghc-pkg), ffi-import
    (the C toolchain, for c-lib) and main (a link) succeeds. (Last: it
    restarts the daemon and cleans.)"""
    with open("third-party/haskell/tools.bzl") as f:
        version = re.search(r"^GHC_VERSION = '([^']+)'$", f.read(), re.M).group(1)
    with tempfile.TemporaryDirectory(prefix="fake-tools-") as fake:
        for name in _TOOLS + [t + "-" + version for t in _TOOLS] + _C_TOOLS:
            path = os.path.join(fake, name)
            write(path, '#!/bin/sh\necho "$0 ran: it is on the daemon\'s PATH" >&2\nexit 1\n')
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        env = dict(os.environ, PATH=fake + ":" + os.environ["PATH"])
        buck2("kill")
        try:
            buck2("clean", env=env)
            buck2("build", "//lib-user:lib-user", "//ffi-import:ffi-import", "//main:main", env=env)
        finally:
            buck2("kill", ok=False)
