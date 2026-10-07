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

# Testing this repo

`example/` is a small, self-contained Cabal package used to test-drive
this repo's own Buck2 support: a library with a Template Haskell
splice, an `.hsc` file (hsc2hs), C++ code linked in via FFI
(`cxx-sources`), and a dependency on a real Hackage package (`safe`, to
exercise `gen-haskell-prebuilt.py`'s cabal-store support, as opposed to
GHC's own bundled packages) - plus a `cabal test` test-suite exercising
all of it.

To try it locally:

```
example/setup.sh
cd example
buck2 build //...          # dev
buck2 test //...
buck2 build -m opt //...   # opt
buck2 test -m opt //...
buck2 build -m prof //...  # profiling
buck2 test -m prof //...
```

`.github/workflows/ci.yml` runs the same steps (plus the plain `cabal
build --only-dependencies` this all depends on) on every push and pull
request, in `dev`, `opt` and `prof` mode.
