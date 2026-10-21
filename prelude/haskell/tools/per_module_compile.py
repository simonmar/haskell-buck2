#!/usr/bin/env python3
# Compiles one module of a target compiled per-module with `ghc -c`, then
# writes the module's .abi file and buck2 dep file (see compile_per_module
# in prelude/haskell/compile_per_module.bzl):
#
#   --depfile FILE --abi FILE --module Foo/Bar --outdir DIR --hisuf SUF
#   --unit UNIT [--hidir=UNIT=DIR]... [--mkdir=DIR]...
#   -- GHC SESSION_FLAGS... -- MODULE_FLAGS...
#
# --unit is the module's unit id. Each --hidir=UNIT=DIR gives DIR, an
# interface directory of the dependency whose unit id is UNIT.
#
# The compile is GHC with the session's flags then the module's. The
# session's flags are those the target's modules share (with the same
# package dbs); the module's own are its source and outputs. The .abi file
# and the dep file come from the text of the new interface, which the
# compile dumps itself with -ddump-hi. That is the same text that
# --show-iface prints, without a second GHC start per module. See Note
# [Reading the interface text] in compile_per_module.bzl.

import glob
import os
import re
import subprocess
import sys

# The lines of the interface dump that this script reads. See Note [Reading
# the interface text] in compile_per_module.bzl.

# "ABI hash: <hash>"
ABI_HASH = re.compile(r"ABI hash:\s+(\S+)")
# A usage of an imported module: "import  -/  Mod hash", or "import safe Mod
# hash" for a safe import. GHC 9.14 prints the first of them on the
# "usages: [" line, so the import is the last one on its line.
IMPORT = re.compile(r"^.*import +(?:-/|safe) +([^ ,]*)")
# What looks like a usage, which some IMPORT line must match.
LOOKS_LIKE_IMPORT = re.compile(r" -/ |import safe ")
# GHC's error when a splice runs code it can't load: with per_module, the
# code of this project's other libraries (see Note [Template Haskell
# modules] in compile_per_module.bzl).
UNLINKED_SPLICE = "couldn't find the following symbol"
SPLICE_HINT = ("\n{}: per_module: a splice can run only the code of prebuilt packages, not of this "
               "project's other libraries: build the target with per_module = False\n")

# A file a splice loaded: `addDependentFile "path"`.
DEPENDENT_FILE = re.compile(r'^ *addDependentFile "([^"]*)"')
# The direct module dependencies, which mark a module imported only as a
# boot file "[boot]": "direct module dependencies: unit:Mod [boot] ...",
# wrapped onto lines that start with a space.
DIRECT_DEPS = "direct module dependencies:"


class Dump:
    """What the script reads from an interface dump."""

    def __init__(self, text):
        lines = text.splitlines()
        self.abi_hashes = [m.group(1) for m in map(ABI_HASH.search, lines) if m]
        self.imports = [m.group(1) for m in map(IMPORT.match, lines) if m]
        self.looks_like_imports = any(LOOKS_LIKE_IMPORT.search(line) for line in lines)
        self.dependent_files = [m.group(1) for m in map(DEPENDENT_FILE.match, lines) if m]
        self.boots = set()
        words = []
        in_deps = False
        for line in lines:
            if line.startswith(DIRECT_DEPS):
                in_deps = True
                words += line[len(DIRECT_DEPS):].split()
            elif in_deps and line.startswith(" "):
                words += line.split()
            else:
                in_deps = False
        for prev, word in zip(words, words[1:]):
            if word == "[boot]":
                self.boots.add(prev.rsplit(":", 1)[-1])

    def readable(self):
        """Whether the dump has what the script needs: an ABI hash, and
        import lines if it has anything that looks like a usage (a module
        may import nothing). A dump the script can't read would make an empty
        or partial dep file, and the module would never be compiled again."""
        return bool(self.abi_hashes) and (any(self.imports) or not self.looks_like_imports)


def parse_args(args):
    request = {"hidirs": {}}
    i = 0
    while args[i] != "--":
        a = args[i]
        if a in ("--depfile", "--abi", "--module", "--outdir", "--hisuf", "--unit"):
            request[a[2:]] = args[i + 1]
            i += 2
        elif a.startswith("--hidir="):
            unit, d = a[len("--hidir="):].split("=", 1)
            request["hidirs"].setdefault(unit, []).append(d)
            i += 1
        elif a.startswith("--mkdir="):
            os.makedirs(a[len("--mkdir="):], exist_ok=True)
            i += 1
        else:
            print("per_module_compile.py: unexpected argument " + a, file=sys.stderr)
            sys.exit(2)
    # The compile's command: everything left but the "--" between the
    # session's flags and the module's.
    rest = args[i + 1:]
    if "--" in rest:
        rest.remove("--")
    return request, rest


def dep_file_entries(request, dump):
    """The dep file's entries, as paths from the project root to the real
    files: a tree entry is a symlink, and buck2 digests the link itself.

    An imported module is looked up by its unit, not by its name alone,
    since another unit may have a module of the same name:

    - a module of the target is in the modules' output directory;
    - a module of a local dependency is in that dependency's interface dirs,
      as an .abi file, or as an interface if the dependency is built with
      --make (which writes no .abi).

    A module of the target imported only {-# SOURCE #-} is looked up by its
    boot file's .abi (".abi-boot"). The files a splice read are listed at
    the paths GHC read them from. Files outside the project (the libraries
    of GHC's own package db) are not inputs of the action, and are left
    out."""
    root = os.getcwd()
    outdir = request["outdir"]

    def rel(path):
        real = os.path.realpath(path)
        if real.startswith(root + os.sep):
            yield os.path.relpath(real, root)

    for usage in dump.imports:
        if not usage:
            continue
        unit, _, mod = usage.rpartition(":")
        p = mod.replace(".", "/")
        if unit == request["unit"]:
            f = os.path.join(outdir, p + (".abi-boot" if mod in dump.boots else ".abi"))
            if os.path.exists(f):
                yield from rel(f)
            continue
        for d in request["hidirs"].get(unit, []):
            found = [f for f in (os.path.join(d, p + ".abi"), os.path.join(d, p + "." + request["hisuf"])) if os.path.exists(f)]
            if found:
                yield from rel(found[0])
                break
    # A module with a boot file depends on the boot's interface too (GHC
    # checks they agree), except in the boot's own compile, which writes it.
    own_boot = os.path.join(outdir, request["module"] + ".abi-boot")
    if request["abi"] != own_boot and os.path.exists(own_boot):
        yield from rel(own_boot)
    for f in dump.dependent_files:
        yield from rel(f)


def main():
    request, command = parse_args(sys.argv[1:])
    p = subprocess.run(command, stderr=subprocess.PIPE, text=True, errors="replace")
    sys.stderr.write(p.stderr)
    if p.returncode != 0:
        if UNLINKED_SPLICE in p.stderr:
            sys.stderr.write(SPLICE_HINT.format(request["module"].replace("/", ".")))
        sys.exit(p.returncode if p.returncode > 0 else 128 - p.returncode)

    abi = request["abi"]
    # The dump's name carries the way (Mod.dyn.dump-hi, Mod.p.dump-hi); a
    # -dynamic-too compile writes one per way, with the same usages.
    dumps = sorted(glob.glob(glob.escape(abi) + ".*dump-hi"))
    if not dumps:
        sys.exit("no interface dump next to " + abi)
    with open(dumps[0], encoding="utf-8", errors="replace") as f:
        dump = Dump(f.read())
    with open(abi, "w") as f:
        f.writelines(h + "\n" for h in dump.abi_hashes)
    # A splice can't run code of the target's own modules (see Note
    # [Template Haskell modules] in compile_per_module.bzl): their objects
    # aren't inputs of the compile, so GHC found them only because an
    # earlier compile left them there.
    outdir = os.path.realpath(request["outdir"]) + os.sep
    own = [f for f in dump.dependent_files if os.path.realpath(f).startswith(outdir)]
    if own:
        sys.exit("{}: a splice ran code of this target's own modules ({}), which per_module doesn't support: build the target with per_module = False".format(
            request["module"].replace("/", "."), ", ".join(sorted(os.path.basename(f) for f in own))))
    if not dump.readable():
        sys.exit("per_module_compile.py: can't read the ABI hash or usages in {}; has the format of GHC's interface dump changed?".format(dumps[0]))
    entries = list(dep_file_entries(request, dump))
    with open(request["depfile"], "w") as f:
        f.writelines(e + "\n" for e in entries)
    for d in dumps:
        os.remove(d)


if __name__ == "__main__":
    main()
