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

# Per-module compilation (experimental)

By default each `haskell_library()`/`haskell_binary()` is compiled by one
`ghc --make` action. With `per_module = True`, each module is compiled
by an action of its own. That means that `buck2` can compile a target's
modules in parallel with everything else it has to do, and rebuilds can
be more minimal. Notably the dependency graph is cross-package, so modules
in later packages can start compiling as soon as the specific modules they
depend on are done, without having to wait for the full package.

`per_module` is only tested on Linux.

Template Haskell is supported with one restriction: a splice can only run
code of prebuilt packages (from Hackage, say), not of the project's other
libraries or of the target's own modules. So a module with Template Haskell
doesn't wait for its dependencies' libraries to be linked, and keeps the
cross-package parallelism. A target whose splices do run local code fails
to compile, saying so: build it with `per_module = False`.

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
(see `tools/buck2-ghc-worker/DESIGN.md`).

The main cost of `per_module` is CPU on clean builds. Without the
persistent worker (below), each module's compile starts a GHC and reads the
interfaces of its imports, which `--make` does once per target, so a clean
build takes several times as long. Rebuilds pay that cost only for the
modules they compile, so they are mostly faster than with `--make` even
without the worker.

The persistent worker in `tools/buck2-ghc-worker` removes most of that cost by
sending the compiles to a long-running process that keeps what it has
read, so a module's imports are read once rather than once per module.
With it, clean builds on the bench were as fast as with a `--make` per
target or faster, and much faster where `--make` per target can't use all
the cores, as in a chain of libraries that each depend on the one before.

`per_module_worker` in the `[haskell]` section of the buckconfig says how
to get the worker:

- `local`: a worker defined in the project itself, which buck2 builds with
  the project's GHC. Add it to the packages in `cabal.project`, without its
  tests (otherwise they become tests of the project), and run `cabal buck2`:

  ```
  packages: . buck2/tools/buck2-ghc-worker

  package buck2-ghc-worker
    tests: False
  ```
- a path, or a name on `$PATH`: a worker built by some other means.
- `none`, or unset: no worker.

The same section has options for the worker that the targets share:

- `per_module_worker_rts_options`: its RTS options (`-A64m -n4m -qn8 -I5`
  by default, see the worker's README).
- `per_module_worker_sessions`: the most sessions it keeps. This bounds its
  memory only with `make` sessions (see the worker's README).
- `per_module_worker_session_mode`: how its sessions compile. `auto` is the
  default, and `make` turns off sharing interfaces between targets (see
  `prelude/haskell/per_module_worker.bzl`).
- `per_module_worker_build_tools`: the build tools on its `PATH`, as
  targets separated by spaces. A target with a build tool that isn't among
  them is compiled without the worker, one `ghc -c` per module, so list the
  tools that many targets use (a test-discovery preprocessor, say).

The recompilation check used by `per_module` is also currently slightly coarser
than GHC's, in that GHC also looks at which definitions from a dependency are
used by a module. We don't do this currently but we could do in future.

With `per_module`, `[interfaces]` (above) doesn't link the target's
dependencies either, because a module's compile needs only the interfaces of
its imports.

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
(`tools/buck2-ghc-worker`) with each GHC the worker supports, in parallel, and
`nix develop .#ghc9141` (say) gives a shell with that GHC and cabal.

`template/` has the `.buckconfig` and `PACKAGE` that `cabal buck2` copies to a
project that doesn't have them.
