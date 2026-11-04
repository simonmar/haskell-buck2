"""What the checks (see check.py) share: running buck2, reading what the
rules decided from its logs, naming buck-out paths, and comparing what a
check finds with what it expects."""

import glob
import json
import os
import re
import subprocess
import sys

MAIN_TARGETS = ["//lib:lib", "//lib-user:lib-user", "//th-gen:th-gen", "//th-prebuilt-splice:th-prebuilt-splice", "//th-make-dep:th-make-dep", "//ffi-import:ffi-import", "//make-between:t", "//boot-cycle:boot-cycle", "//main:main", "//reexport:reexport", "//reexport-user:reexport-user", "//flat-sources:flat-sources"]

LOG_DIR = "buck-logs"

# The link styles of dev mode's compiles and of opt mode's static ones, which
# name their actions and output directories. On macOS code is always
# position-independent, so both are static_pic.
DEV_STYLE = "static_pic" if sys.platform == "darwin" else "shared"
OPT_STATIC_STYLE = "static_pic" if sys.platform == "darwin" else "static"


class CheckFailed(Exception):
    pass


class Skipped(Exception):
    """Raised by a check of what this platform doesn't have."""


# --- Running buck2 ---------------------------------------------------------

_run_count = 0


def buck2(*args, ok=True, env=None):
    """Runs buck2 with the args, saving its output under LOG_DIR. Fails the
    check if `ok` and buck2 fails. `env` is the environment of buck2, and so
    of the daemon if this command starts one."""
    global _run_count
    _run_count += 1
    os.makedirs(LOG_DIR, exist_ok=True)
    log = os.path.join(LOG_DIR, "{:02d}-{}.log".format(_run_count, args[0]))
    p = subprocess.run(["buck2", *args], capture_output=True, text=True, env=env)
    with open(log, "w") as f:
        f.write("$ buck2 " + " ".join(args) + "\n" + p.stdout + p.stderr)
    if ok and p.returncode != 0:
        raise CheckFailed("`buck2 {}` failed (see {}):\n{}".format(" ".join(args), log, tail(p.stderr)))
    return p


def tail(text, n=30):
    return "\n".join(text.splitlines()[-n:])


def build(*targets, mode=None, keep_going=False):
    args = ["build"] + (["-m", mode] if mode else []) + (["--keep-going"] if keep_going else []) + list(targets)
    return buck2(*args, ok=not keep_going)


# How a fixture with `per_module = PER_MODULE` is compiled (see
# project/compile/BUCK.fixture).
COMPILES = ["per-module", "make"]


def configured(target, compile="per-module", mode=None):
    """The target with the modifiers that build it in the build mode, and
    compiled per-module or with --make. buck2 doesn't take -m together with
    a target's modifiers, so the mode is a modifier too."""
    modifiers = ([mode] if mode else []) + (["//compile:make"] if compile == "make" else [])
    return target + ("?" + "+".join(modifiers) if modifiers else "")


def expect_output(target, when, value, mode=None):
    out = buck2("run", *(["-m", mode] if mode else []), target).stdout.strip()
    expect("{} should print {} {}; it printed {}".format(target, value, when, out), out == value)


IDENTITY = re.compile(r"^(\S+) \(cfg:[^)]*\) \((\S+)(?: (.+))?\)$")


def what_ran_entries():
    """The entries of `buck2 log what-ran` for the last build, as JSON."""
    out = buck2("log", "what-ran", "--format", "json").stdout
    return [json.loads(line) for line in out.splitlines() if line.startswith("{")]


def what_ran(entries=None):
    """The actions that the last build ran, or those in the given what-ran
    entries, as (target, category, identifier, command) tuples. The target
    has no cell, as in "th-local-splice:th-local-splice".

    This leaves out the actions that buck2 didn't run, because their dep
    files showed they were up to date or because it found their results in a
    cache, though what-ran lists those too. It also leaves out the start of a
    persistent worker, which what-ran lists as an entry for the first action
    that buck2 sent to the worker."""
    actions = []
    for entry in (what_ran_entries() if entries is None else entries):
        m = IDENTITY.match(entry["identity"])
        executor = entry["reproducer"].get("executor", "")
        if not m or executor.endswith("Cache") or executor == "WorkerInit":
            continue
        target = m.group(1).split("//", 1)[1].lstrip(":")
        cmd = entry.get("reproducer", {}).get("details", {}).get("command", [])
        actions.append((target, m.group(2), m.group(3), cmd))
    return actions


def compiled_modules(actions):
    """The per-module compiles that ran, as "target-name:Module"."""
    return {target_name(t) + ":" + i for t, c, i, _ in actions if c.startswith("haskell_compile_module_")}


def compiled(actions):
    """The compiles that ran: a per-module one as "target-name:Module", one
    with --make as "target-name"."""
    names = set()
    for t, c, i, _ in actions:
        if c.startswith("haskell_compile_module_"):
            names.add(target_name(t) + ":" + i)
        elif c.startswith("haskell_compile_"):
            names.add(target_name(t))
    return names


def target_name(target):
    return target.split(":")[-1]


def dep_file(target, category, identifier, mode=None):
    """The entries of an action's dep file (its tagged inputs that it read),
    by short name, and its untagged inputs, by short name."""
    args = ["audit", "dep-files"] + (["-m", mode] if mode else []) + ["root" + target, category, identifier]
    out = buck2(*args).stdout
    tagged, untagged = set(), set()
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        (untagged if parts[0] == "untagged" else tagged).add(short(parts[1]))
    return tagged, untagged


def raw_dep_file(package, name, node):
    """The entries of a per-module compile's dep file as its action wrote
    them, by short name."""
    paths = glob.glob("buck-out/v2/art/root/*/{}/__{}__/__action___*/per-module-{}/dep/{}.dep".format(package, name, DEV_STYLE, node))
    if len(paths) != 1:
        raise CheckFailed("no single dep file of {}:{} {} (found {})".format(package, name, node, paths))
    with open(paths[0]) as f:
        return {short(line.strip()) for line in f if line.strip()}


def index_files(target, *config, compile="per-module"):
    """The names of the .hie files in the target's index (HaskellIndexInfo).
    BXL doesn't take a target's modifiers, so index.bxl adds --make's
    itself."""
    args = ["--target", target] + (["--make", "true"] if compile == "make" else [])
    path = buck2("bxl", *config, "//index.bxl:index", "--", *args).stdout.strip().splitlines()[-1]
    hie = set()
    for root, _, files in os.walk(path, followlinks=True):
        hie |= {f for f in files if f.endswith(".hie")}
    return hie


# --- Naming buck-out paths ---------------------------------------------------


OWN = r"buck-out/v2/art/root/[0-9a-f]+/(?:[^ ]*/)?__([^/]+)__/"


SHORT_NAMES = [
    # A module's outputs: lib:A.Mid.abi, boot-cycle:Cyc.B.abi-boot.
    (OWN + r"per-module-[^/]+/out-[0-9]+/(.+)\.([a-z_]+(?:-boot)?)$", lambda m: "{}:{}.{}".format(m[1], m[2].replace("/", "."), m[3])),
    (OWN + r"per-module-[^/]+/out-[0-9]+$", lambda m: m[1] + ":out"),
    (OWN + r"db-early-[^/]+(/.*)?$", lambda m: m[1] + ":early"),
    (OWN + r"db-nolib-[^/]+(/.*)?$", lambda m: m[1] + ":nolib"),
    (OWN + r"db-[^/]+(/.*)?$", lambda m: m[1] + ":final"),
    (OWN + r"hi-[^/]+$", lambda m: m[1] + ":hi"),
    (OWN + r"lib-[^/]+/.*$", lambda m: m[1] + ":lib"),
    (r"third-party/haskell/ghc-[^/]+(/package\.conf\.d)?$", lambda m: "ghc:global"),
]


def short(path):
    for pattern, name in SHORT_NAMES:
        m = re.match(pattern, path)
        if m:
            return name(m)
    return path


# --- Reading a per-module compile's command line -----------------------------


def parse_compile(cmd):
    """The parts of a per-module compile's request that the rules decide,
    such as the package dbs and the interface directories. The request is
    the same whether it goes to the worker or to the compile tool."""
    args = cmd[cmd.index("--request"):]
    sep = args.index("--")
    script, rest = args[:sep], args[sep + 1:]
    session = rest[:rest.index("--")]
    hidirs = {short(a[len("--hidir="):].split("=", 1)[1]) for a in script if a.startswith("--hidir=")}
    dbs = {short(session[n + 1]) for n, a in enumerate(session) if a == "-package-db"}
    units = [session[n + 1] for n, a in enumerate(session) if a == "-this-unit-id"]
    return {"dbs": dbs, "hidirs": hidirs, "unit": units[-1] if units else None}


def find_compile(actions, target, module):
    for t, c, i, cmd in actions:
        if target_name(t) == target and c.startswith("haskell_compile_module_") and i == module:
            return parse_compile(cmd)
    raise CheckFailed("no compile of {}:{} in the build".format(target, module))


# --- Assertions ----------------------------------------------------------------


def expect_set(what, actual, expected):
    actual, expected = set(actual), set(expected)
    if actual != expected:
        raise CheckFailed("{}:\n  missing:    {}\n  unexpected: {}\n  (actual:    {})".format(
            what, sorted(expected - actual) or "-", sorted(actual - expected) or "-", sorted(actual)))


def expect(what, cond):
    if not cond:
        raise CheckFailed(what)


# --- Editing sources ------------------------------------------------------------


def append(path, text):
    with open(path, "a") as f:
        f.write(text)


def replace(path, old, new):
    with open(path) as f:
        s = f.read()
    expect("{} contains {!r}".format(path, old), old in s)
    with open(path, "w") as f:
        f.write(s.replace(old, new))


def write(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


# --- What the checks share -------------------------------------------------------

class State:
    def __init__(self, bazel_remote=None, worker=False):
        self.bazel_remote = bazel_remote
        self.worker = worker
        self.targets = MAIN_TARGETS
        self.entries = None
        self.actions = None


def known_failure(issue):
    """Marks a check that fails because of a known bug in the rules (`issue`
    says which). check.py reports its failure as XFAIL, without failing the
    run, and fails the run if the check passes, so that its mark is taken
    off once the bug is fixed."""

    def mark(check):
        check.known_failure = issue
        return check

    return mark
