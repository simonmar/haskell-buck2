# Buck2 prelude for Haskell projects

This is a version of the [Buck2
prelude](https://github.com/facebook/buck2/tree/main/prelude) with a
few tweaks (that will hopefully be upstreamed at some point) and some
support code for building Haskell projects.

You probably don't want this by itself---instead take a look at
[cabal-buck2](https://hackage.haskell.org/package/cabal-buck2) which
extends `cabal` with a `buck2` command so that you can use Buck2 as
the build tool for your Cabal project.

# Build modes

The Buck2 build system has two build modes:

  * `dev`: the default, builds everything with `-O0` and dynamic linking. This is intended to give you the quickest edit-compile-test turnaround.
  * `opt`: enable `-O` and link statically. This takes longer but the code runs faster.

To build with `opt`, use `-m opt`, e.g.

```
buck2 build my-package:my-program -m opt
```

There are other build options that can be selected in a similar way, such as `-m prof` to enable profiling. See `constraints/BUCK` for details.

# Checking without linking

`buck2 build my-package:my-program[interfaces]` compiles a target without
linking it, which is enough to see its type errors.

# Documentation

`haskell_haddock` builds the haddock for libraries libraries. A library compiled 
with `-haddock` (in its `compiler_flags` or the toolchain's) will build the documentation 
from the interfaces on GHC 9.12+, which is more efficient.

# Warnings

buck2 shows warnings only when it runs a compilation action, and not
when it finds the result in a cache. `buck2 build
my-package:my-program[diagnostics.txt] --out -` prints all the diagnostics 
from compiling a target's modules, whether they were compiled in this build or not. 

A target compiled with `--make` will show the diagnostics from the modules that it
re-compiled on the last run.

# Splice dependencies

A Template Haskell splice, quasiquote or `ANN` pragma needs the linked libraries
of dependencies that it uses. A target must list the local dependencies that it uses 
in this way in `splice_depends`. The default, an empty list, means that they use none. 
A splice that runs code of the target's own modules also uses the libraries that
those modules use, so they must be listed too.

# Per-module compilation (experimental)

By default each `haskell_library()`/`haskell_binary()` is compiled by one
`ghc --make` action. With `per_module = True`, each module is compiled
by an action of its own. That means that `buck2` can compile a target's
modules in parallel with everything else it has to do, and rebuilds can
be more minimal. Notably the dependency graph is cross-package, so modules
in later packages can start compiling as soon as the specific modules they
depend on are done, without having to wait for the full package.

`per_module` is only tested on Linux.

The main thing that still leads to suboptimal dependency graphs is Template
Haskell. A module that runs Template Haskell waits for the libraries that
its target lists in `splice_depends` (see above) to be linked.
The target's other modules don't wait for them. A splice that runs code of
a local library that isn't listed fails to compile, saying so. (The
persistent worker doesn't always catch it. See "Known issues" in
`prelude/haskell/tools/worker/README.md`.)

On GHC 9.14, a module that uses `ExplicitLevelImports` narrows its target's
list further, to the dependencies that its `import splice`s come through.

`per_module` is often much faster at rebuilds:

- With `--make`, an edit to any module rebuilds its whole target from
  scratch, and then the targets that depend on it, since even a comment
  changes the target's interfaces.
- With `per_module`, buck2 compiles the edited module, and then only the
  modules whose imports' ABI changed. After a comment, that's just the
  edited module. After a new definition, it's that module and the modules
  that import it.

How much this saves depends on the module structure. It saves the most for
edits low in the module graph, in large targets, or in targets that much
else depends on, and the least for edits to a small target that nothing
depends on. On the worker's bench, rebuilds after such edits took 0.7-1.2s
with `per_module` and the worker, against 2-9s with `--make` per target
(see `prelude/haskell/tools/worker/DESIGN.md`).

The main cost of `per_module` is CPU on clean builds. Without the
persistent worker (below), each module's compile starts a GHC and reads the
interfaces of its imports, which `--make` does once per target, so a clean
build takes several times as long. Rebuilds pay that cost only for the
modules they compile, so they are mostly faster than with `--make` even
without the worker.

The persistent worker in `prelude/haskell/tools/worker` removes most of that cost by
sending the compiles to a long-running process that keeps what it has
read, so a module's imports are read once rather than once per module.
With it, clean builds on the bench were as fast as with a `--make` per
target or faster, and much faster where `--make` per target can't use all
the cores, as in a chain of libraries that each depend on the one before.

`per_module_worker` in the `[haskell]` section of the buckconfig says
whether to use the worker:

- `builtin`, the default: the toolchain builds the worker with the
  project's GHC.
- `none`: no worker.

The worker compiles every module except those that may run one of their
target's build tools, which are compiled by their own `ghc -c`. Those are
the modules that GHC runs a build tool for, such as a preprocessor named
by `-F -pgmF`, and, in a target with build tools, the modules that run
Template Haskell.

The same section has options for the worker that the targets share:

- `per_module_worker_rts_options`: its RTS options (`-A64m -n4m -qn8 -I5`
  by default, see the worker's README).
- `per_module_worker_sessions`: the most sessions it keeps. This bounds its
  memory only with `make` sessions (see the worker's README).
- `per_module_worker_session_mode`: how its sessions compile. `auto` is the
  default, and `make` turns off sharing interfaces between targets (see
  `prelude/haskell/per_module_worker.bzl`).

The recompilation check used by `per_module` is also currently slightly coarser
than GHC's, in that GHC also looks at which definitions from a dependency are
used by a module. We don't do this currently but we could do in future.

With `per_module`, `[interfaces]` (above) doesn't link the target's
dependencies either, because a module's compile needs only the interfaces of
its imports.

# Advice

The rules can spot some ways of declaring a target that
build correctly but slowly, and can report them as advice. 
After a build, the prelude's `validation/audit_results.bxl` can be used to get 
the check results: 

```
buck2 build //...
buck2 bxl prelude//validation/audit_results.bxl:main -- --targets //... --trim true
```

A result is a JSON file whose `data` has a `message` for people and a list
of `findings` for tools. `--take NAME` picks out one check. The checks are:

- `haskell_unused_build_tools`: build tools that are not used by any module's 
  compilation. If the program uses them at runtime, they belong in
  `run_tool_depends`; otherwise they can go.
- `haskell_template_haskell_from_flags`: the target's flags turn on
  `TemplateHaskell` or `QuasiQuotes`, so every module must be compiled as
  if it used Template Haskell.
- `haskell_ann_pragmas`: modules that must be compiled as if they used
  Template Haskell only because of `ANN` pragmas.
- `haskell_modules_outside_worker`: modules which must be compiled outside the
  persistent worker, and an explanation for why.

# Compiler and linker flags from the environment

buck2 runs every build action with a clean environment, so directories that
a shell makes visible to the compiler and linker through variables such as
`LIBRARY_PATH` or `CPATH` (a Nix or Homebrew shell, say) are not seen by GHC.
Give them to the Haskell toolchain through the project's buckconfig instead,
normally in a `.buckconfig.local` next to the `.buckconfig` at the root of
the project (it is read in addition to `.buckconfig`, and is for files that
don't belong in version control):

```
[haskell]
  compiler_flags = -I/opt/homebrew/include
  linker_flags = -L/opt/homebrew/lib -L/opt/zlib/lib
```

Both are space-separated lists of flags for every GHC invocation;
`compiler_flags` go to each compile and `linker_flags` to each link.

# Testing this repo

This is the Buck2 support code for
[cabal-buck2](https://github.com/simonmar/cabal-buck2), which includes it as a
submodule (`buck2/`) and tests it, with an example project (`example/`:
Template Haskell, hsc2hs, C++ via FFI and a Hackage dependency) and with its
own build. Update the submodule there to test a change here.

Some of the rules also have tests of their own, which don't rely
on cabal-buck2 or Hackage: `tests/rules/run.sh GHC_BIN_DIR`, with `buck2` on
`PATH`. See [tests/rules/README.md](tests/rules/README.md).

With Nix, `nix flake check -L` runs those and the persistent worker's tests
(`prelude/haskell/tools/worker`) with each GHC the worker supports, in parallel, and
`nix develop .#ghc9141` (say) gives a shell with that GHC and cabal.

`template/` has the `.buckconfig` and `PACKAGE` that `cabal buck2` copies to a
project that doesn't have them.
