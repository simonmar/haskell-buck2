# Tests of the per-module rules

Builds a small project (`project/`) with `per_module = True` targets and
checks what the rules decide: which package dbs, libraries and interfaces
each module's compile gets, what its dep file lists, and which modules
compile again after an edit. Only GHC's own packages are used (`base`,
`template-haskell`), so neither Hackage nor cabal-buck2 is needed.

```
tests/rules/run.sh GHC_BIN_DIR [WORK_DIR] [-- --only CHECK ...]
```

`GHC_BIN_DIR` has `ghc` and `ghc-pkg`; `buck2`, `python3`, C compilers (`cc`
for GHC, `clang` for buck2's C toolchain, which builds `//c-lib:c-lib`) and
`g++` (that toolchain's linker) must be on `PATH`. The project is copied to
`WORK_DIR` (a new temporary directory by default), since the checks edit its
sources, and built there; each buck2 command's output is saved under
`WORK_DIR/project/buck-logs/`. It takes about 15 seconds.

`nix flake check` at the top of the repository runs the tests with each
GHC. A dev shell has what they need, so with one GHC:

```
nix develop .#ghc9141 -c sh -c 'tests/rules/run.sh "$(dirname "$(command -v ghc)")"'
```

With `BAZEL_REMOTE` set to a `bazel-remote` binary, `check_cache` runs one
as a remote cache, and checks that the rules' actions upload their results
and that a clean build finds them there. The dev shells and `nix flake
check` set it.

Each check prints `PASS` or `FAIL` (with the missing and unexpected members
of the set it compared) or `SKIP` (`check_cache` without `BAZEL_REMOTE`).
The script fails on any `FAIL`. Some checks are of what per_module doesn't
support, a splice that runs local code: they check that the compile fails,
saying how to build the target instead.

## How it works

- `gen_prebuilt.py` writes the `third-party-haskell` cell: a
  `haskell_prebuilt_library()` per package of GHC's that the fixtures use,
  and the `tools.bzl` that the rest of the support code loads.
- `check.py` runs the checks in order, in one buck2 daemon (buck2 keeps dep
  files in the daemon's memory, so the early cut-off checks need it to
  live). It reads the compiles' command lines from `buck2 log what-ran
  --format json` (the per-module compiles are registered by a
  `dynamic_output`, which `buck2 aquery` doesn't show), their dep files from
  `buck2 audit dep-files`, and the package confs from `buck2 aquery`, and
  names buck-out paths by what they are: `lib:A.Mid.abi` (a module's file),
  `th-gen:early`, `make-lib:nolib` and `th-gen:final` (a target's package dbs),
  `ghc:global`.

## The fixtures

| Target | What it is for |
| --- | --- |
| `//lib:lib` | `A.Base`; `A.Mid`, which imports it; `A.Unused` |
| `//lib-user:lib-user` | `B.M`, which imports `A.Mid` only; `B.Lit`, a literate source, whose instance `B.UsesLit` uses; `B.Safe`, a Safe module importing `A.Mid` |
| `//th-gen:th-gen` | `TH.Gen.gen`, a `Q Exp` |
| `//th-local-splice:th-local-splice` | a splice of `TH.Gen.gen`, from another local library, which isn't supported: its compile fails |
| `//th-prebuilt-splice:th-prebuilt-splice` | a splice that runs only `template-haskell` |
| `//boot-cycle:boot-cycle` | two modules in an import cycle, through an hs-boot file |
| `//ownboot:ownboot` | a module whose hs-boot file no import cycle needs |
| `//mainname:server` | a binary whose Main module is in `app/Server.hs`, without a module header |
| `//rtsflags:rtsflags` | `+RTS ... -RTS` among the compiler flags |
| `//main:main` | a binary depending on `lib-user`; `main-shared`, the same linked shared |
| `//unrelated-failure:w` | imports a module of `//unrelated-failure:s`, whose other module doesn't compile |
| `//reexport:reexport`, `//reexport-user:reexport-user` | `reexport` re-exports `A.Base`; `reexport-user` imports `A.Base` through it |
| `//th-make-dep:th-make-dep`, `//th-make-dep:mkrun` | Template Haskell modules depending on `//make-lib:make-lib`, built with `--make`: `MK.Lit`'s splice runs only `template-haskell`, `MK.Run`'s runs `make-lib`'s code, which isn't supported: its compile fails |
| `//make-between:p`, `//make-between:m`, `//make-between:t` | `t`'s module imports `m`'s, built with `--make`, whose interface refers to `p`'s, compiled per-module |
| `//flat-sources:flat-sources`, `//make-lib:make-lib` | `flat-sources`'s flat sources (`Lib.hs`), one of which imports `Q.Lib` from `make-lib` (built with `--make`), whose interface path ends in `/Lib.hi` |
| `//module-move:hi`, `//module-move:lo`, `//module-move:main` | a module that moves from `hi` to `lo`, its dependency |
| `//index:index` | built with `-fwrite-ide-info`, for its index (`index.bxl` prints it) |
| `//module-name-clash:user` | `X` uses `bar` through `second`'s `Re`, which re-exports it from `second`'s `Utils`; `first` and `user` have a module `Utils` too |
| `//header:header` | a module that `#include`s a header in the target's `srcs` (`Hdr/value.h`) |
| `//toolchain-th:toolchain-th` | a splice without a LANGUAGE pragma, for Template Haskell enabled by the toolchain's flags |
| `//c-lib:c-lib`, `//ffi-import:ffi-import` | a C library, and a library that imports its function |
| `//th-internal-splice:th-internal-splice` | a splice that runs a module of its own library, which isn't supported: its compile fails |
