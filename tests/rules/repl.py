"""Checks of the GHC sessions of the [repl] sub-targets and
prelude//haskell/repl.bxl make, for GHCi and for HLS (see Note [REPL
units] in haskell.bzl). They run GHCi, which takes the same options as HLS,
since HLS has to be built for the very GHC under test."""

import os
import subprocess
import tempfile

from harness import buck2, expect, expect_set, restoring, tail

GHC = "third-party/haskell/ghc-bin/ghc"


def ghci(args, script):
    """Runs GHCi with `args`, reading `script` as its input."""
    return subprocess.run([GHC, "--interactive", *args], input=script, capture_output=True, text=True)


def session(*files, targets=()):
    """The options of the session that repl.bxl makes for `files` and
    `targets`."""
    out = buck2("bxl", "prelude//haskell/repl.bxl:main", "--", *[a for f in files for a in ["--file", f]], *[a for t in targets for a in ["--target", t]]).stdout
    return out.split()


def unit_ids(args):
    """The unit ids of the home units in a session's options."""
    ids = set()
    for path in [a[1:] for a in args if a.startswith("@")]:
        with open(path) as f:
            words = f.read().split()
        ids.add(words[words.index("-this-unit-id") + 1])
    return ids


def check_repl_unit(st):
    """The output of //lib-user:lib-user[repl] is the options of the target
    as one unit, with its dependencies from their package dbs, which
    building it builds: GHCi loads it and evaluates B.M.m, which uses lib's
    A.Mid."""
    out = buck2("build", "//lib-user:lib-user[repl]", "--show-full-simple-output").stdout.strip().splitlines()[-1]
    p = ghci(["@" + out, "-e", "B.M.m"], "")
    expect("GHCi evaluates B.M.m to 4 (got:\n{})".format(tail(p.stdout + p.stderr, 10)), p.returncode == 0 and p.stdout.strip().endswith("4"))


def check_repl_run(st):
    """`buck2 run //lib-user:lib-user[repl]` starts GHCi on lib-user, from
    the project's root whatever directory it is run from, and passes on
    the arguments after `--`: here, run from lib/, it evaluates B.M.m."""
    p = subprocess.run(["buck2", "run", "//lib-user:lib-user[repl]", "--", "-e", "B.M.m"], cwd="lib", capture_output=True, text=True)
    expect("GHCi evaluates B.M.m to 4 (got:\n{})".format(tail(p.stdout + p.stderr, 10)), p.returncode == 0 and p.stdout.strip().endswith("4"))


def check_repl_environment(st):
    """[repl] gives GHCi what a build gives GHC: //rtsflags:rtsflags's
    compiler_flags have runtime system options, which GHC only takes on its
    command line, and //data-dirs:paths's Paths_dd reads dd_datadir, one of
    its data dirs."""
    code, last, out = repl_eval("//rtsflags:rtsflags", "R.A.a")
    expect("GHCi evaluates R.A.a to 1 (got:\n{})".format(tail(out, 10)), code == 0 and last == "1")
    code, last, out = repl_eval("//data-dirs:paths", 'Paths_dd.getDataFileName "x"')
    expect("GHCi finds Paths_dd's data dir (got:\n{})".format(tail(out, 10)), code == 0 and last.endswith('/x"'))


def repl_eval(target, expr):
    """What `buck2 run TARGET[repl] -- -e EXPR` prints."""
    p = subprocess.run(["buck2", "run", target + "[repl]", "--", "-e", expr], capture_output=True, text=True)
    return p.returncode, (p.stdout.strip().splitlines() or [""])[-1], p.stdout + p.stderr


def check_repl_c(st):
    """GHCi runs code that calls C: //ffi-import:ffi-import's own C
    dependency, a shared library; //ffi-import:ffi-wrap's, which it reaches
    through ffi-import's library; and //th-static-c:static-c-user's, a
    static library, which the REPL links into a shared library of its own."""
    for target, expr, value in [
        ("//ffi-import:ffi-import", "FFI.C.clValue", "7"),
        ("//ffi-import:ffi-wrap", "FFI.W.wValue", "7"),
        ("//th-static-c:static-c-user", "SC.Lib.csValue", "5"),
    ]:
        code, last, out = repl_eval(target, expr)
        expect("{}[repl] evaluates {} to {} (got:\n{})".format(target, expr, value, tail(out, 10)), code == 0 and last == value)


def check_repl_home_units(st):
    """repl.bxl makes the owners of the files given home units of one
    session, so an edit to one shows in the others without a build: with
    lib's A.Mid changed to give mid another type, lib-user's B.M fails to
    reload, and it reloads again once A.Mid is restored."""
    args = session("lib-user/B/M.hs", "lib/A/Mid.hs")
    expect_set("the session's home units", unit_ids(args), {"root-lib-lib", "root-lib-user-lib-user"})
    runs = []
    def edit_and_reload():
        with open("lib/A/Mid.hs") as f:
            broken = f.read().replace("mid :: Int", "mid :: Bool").replace("mid = base + 1", "mid = True")
        with tempfile.TemporaryDirectory() as d:
            edited = os.path.join(d, "Mid.hs")
            with open(edited, "w") as f:
                f.write(broken)
            runs.append(ghci(args, ":! cp {} lib/A/Mid.hs\n:reload\n".format(edited)))
    restoring("lib/A/Mid.hs", edit_and_reload)
    p = runs[0]
    out = p.stdout + p.stderr
    expect("the session loads, then lib-user's B.M fails to reload against the edited A.Mid (got:\n{})".format(tail(out, 15)),
           "Ok, " in out and "lib-user/B/M.hs" in out and "Couldn't match" in out)
    p = ghci(args, "")
    out = p.stdout + p.stderr
    expect("the session loads again with A.Mid restored (got:\n{})".format(tail(out, 10)), "Failed" not in out and "Ok, " in out)


def check_repl_closure(st):
    """The home units are closed under dependency, as GHC requires: with
    main's Main and lib's A.Base, lib-user, which main reaches lib through,
    is a home unit too. (Main is a source of main-shared as well.)"""
    args = session("main/Main.hs", "lib/A/Base.hs")
    expect_set("the session's home units", unit_ids(args), {"root-main-main", "root-main-main-shared", "root-lib-user-lib-user", "root-lib-lib"})
    p = ghci(args, "")
    out = p.stdout + p.stderr
    expect("GHCi loads the session (got:\n{})".format(tail(out, 10)), p.returncode == 0 and "Failed" not in out)


def check_repl_targets(st):
    """repl.bxl takes targets as well as files, and patterns of them:
    //main:main and the targets of //lib:, with lib-user between them."""
    args = session(targets=["//main:main", "//lib:"])
    expect_set("the session's home units", unit_ids(args), {"root-main-main", "root-lib-user-lib-user", "root-lib-lib"})


def check_repl_splices(st):
    """A session whose home units run Template Haskell, of their own
    (th-local-splice) and of another home unit (th-gen), loads."""
    args = session("th-local-splice/C/Splice.hs", "th-gen/TH/Gen.hs")
    p = ghci(args, "")
    out = p.stdout + p.stderr
    expect("GHCi loads the session (got:\n{})".format(tail(out, 10)), p.returncode == 0 and "Failed" not in out and "Ok, " in out)


def check_repl_hie_bios(st):
    """prelude//haskell/hie-bios, the program of the README's hie-bios
    cradle, writes the session's options to HIE_BIOS_OUTPUT for the files
    that HIE_BIOS_MULTI_ARG lists, separated by NUL characters, and the
    build files of the session's home units to HIE_BIOS_DEPS."""
    with tempfile.TemporaryDirectory() as d:
        multi = os.path.join(d, "multi")
        output = os.path.join(d, "output")
        deps = os.path.join(d, "deps")
        with open(multi, "w") as f:
            f.write(os.path.abspath("lib-user/B/M.hs") + "\0" + os.path.abspath("lib/A/Mid.hs"))
        p = subprocess.run(["buck2/prelude/haskell/hie-bios", os.path.abspath("lib-user/B/M.hs")],
                           env=dict(os.environ, HIE_BIOS_OUTPUT=output, HIE_BIOS_DEPS=deps, HIE_BIOS_MULTI_ARG=multi), capture_output=True, text=True)
        expect("hie-bios succeeds (got:\n{})".format(tail(p.stderr, 10)), p.returncode == 0)
        with open(output) as f:
            args = f.read().split()
        with open(deps) as f:
            buildfiles = {os.path.relpath(l) for l in f.read().split()}
    expect_set("the home units hie-bios gives", unit_ids(args), {"root-lib-lib", "root-lib-user-lib-user"})
    expect_set("the cradle's dependencies", buildfiles, {"lib/BUCK.fixture", "lib-user/BUCK.fixture"})
