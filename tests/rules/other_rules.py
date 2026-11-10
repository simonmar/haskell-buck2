"""The checks of the rest of the rules: haskell_test, linking, the
toolchains, and the use of a remote cache."""

import json
import os
import re
import socket
import stat
import subprocess
import tempfile
import time
import urllib.request

from harness import IDENTITY, LOG_DIR, COMPILES, buck2, build, configured, expect, expect_output, expect_set, tail, what_ran, write


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


# The targets of check_cache: per-module compiles, package dbs and a binary's
# link (main), and a library built with --make (make-lib, below th-make-dep).
CACHE_TARGETS = ["//main:main", "//th-make-dep:th-make-dep"]


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def check_cache(st):
    """With a remote cache (bazel-remote), configured as `cabal buck2
    --cache` configures it, the rules' actions upload their results, and a
    clean build finds them all there. Without `[buck2]
    default_allow_cache_upload`, nothing is uploaded. Cleans the project, so it
    runs last."""
    grpc = "127.0.0.1:{}".format(free_port())
    http = "127.0.0.1:{}".format(free_port())
    cache_dir = tempfile.mkdtemp(prefix="bazel-remote-")
    log = open(os.path.join(LOG_DIR, "bazel-remote.log"), "w")
    server = subprocess.Popen([st.bazel_remote, "--dir", cache_dir, "--max_size", "1",
                               "--grpc_address", grpc, "--http_address", http],
                              stdout=log, stderr=subprocess.STDOUT)

    def stored():
        with urllib.request.urlopen("http://{}/status".format(http)) as r:
            return json.load(r)["NumFiles"]

    def configure(uploads):
        with open(".buckconfig.local", "w") as f:
            f.write("[buck2_re_client]\n")
            for key in ["engine_address", "action_cache_address", "cas_address"]:
                f.write("  {} = grpc://{}\n".format(key, grpc))
            f.write("  tls = false\n\n[cabal_buck2]\n  cache = true\n")
            if uploads:
                f.write("\n[buck2]\n  default_allow_cache_upload = true\n")
        # The daemon reads [buck2_re_client] as it starts.
        buck2("kill")

    try:
        for _ in range(100):
            try:
                stored()
                break
            except OSError:
                expect("bazel-remote is running (see {}/bazel-remote.log)".format(LOG_DIR), server.poll() is None)
                time.sleep(0.1)

        configure(uploads=False)
        buck2("clean")
        build(*CACHE_TARGETS)
        expect("nothing in the cache after a build without default_allow_cache_upload", stored() == 0)

        configure(uploads=True)
        buck2("clean")
        build(*CACHE_TARGETS)
        expect("results in the cache after a build", stored() > 0)

        buck2("clean")
        build(*CACHE_TARGETS)
        expect_set("actions that ran, though the cache has their results",
                   {"{} {} {}".format(t, c, i or "") for t, c, i, _ in what_ran()}, set())
        out = buck2("log", "what-ran", "--format", "json").stdout
        entries = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
        cached = {IDENTITY.match(e["identity"]).group(2) for e in entries
                  if IDENTITY.match(e["identity"]) and e["reproducer"].get("executor", "").endswith("Cache")}
        kinds = {
            "per-module compile": lambda c: c.startswith("haskell_compile_module_"),
            "--make compile": lambda c: c.startswith("haskell_compile_") and not c.startswith("haskell_compile_module_"),
            "module graph": lambda c: c.startswith("haskell_deps_"),
            "GHC API tool": lambda c: c.startswith("haskell_ghc_api_tool"),
            "package db": lambda c: c.startswith("haskell_package_"),
            "link": lambda c: c.startswith("haskell_link"),
        }
        expect_set("kinds of action found in the cache",
                   {k for k, is_kind in kinds.items() if any(is_kind(c) for c in cached)}, set(kinds))
    finally:
        if os.path.exists(".buckconfig.local"):
            os.remove(".buckconfig.local")
        buck2("kill", ok=False)
        server.terminate()
        server.wait()
        log.close()
