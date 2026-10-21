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

The main cost of `per_module` is CPU. Each module's compile starts a GHC 
and reads the interfaces of its imports, which `--make` does once per target, 
so a target's modules take several times the CPU in total. The overhead is
sufficiently high that `per_module` is often significantly worse than 
`--make`, except when rebuilding a few modules after small edits.

The recompilation check used by `per_module` is also currently slightly coarser
than GHC's, in that GHC also looks at which definitions from a dependency are
used by a module. We don't do this currently but we could do in future.

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

`template/` has the `.buckconfig` and `PACKAGE` that `cabal buck2` copies to a
project that doesn't have them.
