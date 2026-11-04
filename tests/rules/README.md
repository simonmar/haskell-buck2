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

With `GHC_WORKER` set to a `ghc-worker` (`tools/ghc-worker`) built with the
same GHC, the modules are compiled in that worker (`[haskell]
per_module_worker`). The same checks apply, and `check_workers` checks that
the modules were compiled in the worker, except those that need their
target's environment. `nix flake check` runs the tests both ways.

Each check prints `PASS` or `FAIL` (with the missing and unexpected members
of the set it compared) or `SKIP` (the explicit level imports check,
before GHC 9.14). The script fails on any `FAIL`. Some checks are of what
per_module doesn't support, or of a mistake in `th_build_depends`: they
check that the compile fails, saying what to do instead.

## How it works

- `gen_prebuilt.py` writes the `third-party-haskell` cell: a
  `haskell_prebuilt_library()` per package of GHC's that the fixtures use,
  and the `tools.bzl` that the rest of the support code loads.
- `check.py` runs the checks in order, in one buck2 daemon (buck2 keeps dep
  files in the daemon's memory, so the early cut-off checks need it to live).
  It reads the compiles' command lines from `buck2 log what-ran --format json`
  (the per-module compiles are registered by a `dynamic_output`, which `buck2
  aquery` doesn't show), their dep files from `buck2 audit dep-files`, and the
  package confs from `buck2 aquery`, and names buck-out paths by what they are:
  `lib:A.Mid.abi` (a module's file), `th-gen:early`, `make-lib:nolib` and
  `th-gen:final` (a target's package dbs), `ghc:global`.

## The fixtures

| Target | What it is for |
| --- | --- |
| `//lib:lib` | `A.Base`; `A.Mid`, which imports it; `A.Unused` |
| `//lib-user:lib-user` | `B.M`, which imports `A.Mid` only; `B.Lit`, a literate source, whose instance `B.UsesLit` uses; `B.Safe`, a Safe module importing `A.Mid` |
| `//th-gen:th-gen` | `TH.Gen.gen`, a `Q Exp` |
| `//th-local-splice:th-local-splice` | `th_build_depends = ["//th-gen:th-gen"]`: `C.Splice`, a splice of `gen`; `C.Plain`, a module without Template Haskell; `C.Ann`, an `ANN` pragma |
| `//th-local-splice:show` | prints `C.Splice`'s value, which comes from `gen` |
| `//th-prebuilt-splice:th-prebuilt-splice` | `th_build_depends = []`: a splice that runs only `template-haskell` |
| `//eli:eli` | GHC 9.14: `import splice TH.Gen`, and `import splice Language.Haskell.TH` |
| `//eli-reexport:eli-reexport` | GHC 9.14: `import splice A.Base`, which `//reexport:reexport` re-exports |
| `//eli-persist:eli-persist` | GHC 9.14: a splice that runs `TH.Gen`, imported without `splice`, in a module with `ExplicitLevelImports` and then `ImplicitStagePersistence` |
| `//boot-cycle:boot-cycle` | two modules in an import cycle, through an hs-boot file |
| `//ownboot:ownboot` | a module whose hs-boot file no import cycle needs |
| `//mainname:server` | a binary whose Main module is in `app/Server.hs`, without a module header |
| `//rtsflags:rtsflags` | `+RTS ... -RTS` among the compiler flags |
| `//boot-cycle-inline:boot-cycle-inline` | with -O, a module that needs the interface of a module in an import cycle that it reaches only through an unfolding |
| `//main:main` | a binary depending on `lib-user`; `main-shared`, the same linked shared |
| `//unrelated-failure:w` | imports a module of `//unrelated-failure:s`, whose other module doesn't compile |
| `//reexport:reexport`, `//reexport-user:reexport-user` | `reexport` re-exports `A.Base`; `reexport-user` imports `A.Base` through it |
| `//th-make-dep:th-make-dep`, `//th-make-dep:mkrun`, `//th-make-dep:mkmiss` | Template Haskell modules depending on `//make-lib:make-lib`, built with `--make`: `MK.Lit`'s splice runs only `template-haskell`, and its `th_build_depends` leaves `make-lib` out; `MK.Run`'s runs `make-lib`'s code, which it lists; `MK.Miss`'s does too, without listing it, so its compile fails |
| `//make-between:p`, `//make-between:m`, `//make-between:t` | `t`'s module imports `m`'s, built with `--make`, whose interface refers to `p`'s, compiled per-module |
| `//flat-sources:flat-sources`, `//make-lib:make-lib` | `flat-sources`'s flat sources (`Lib.hs`), one of which imports `Q.Lib` from `make-lib` (built with `--make`), whose interface path ends in `/Lib.hi` |
| `//module-move:hi`, `//module-move:lo`, `//module-move:main` | a module that moves from `hi` to `lo`, its dependency |
| `//worker-attr:worker-attr` | with `GHC_WORKER`: a target that names its worker (`//worker-attr:w`) |
| `//build-tools:shared`, `//build-tools:own` | a module run through a preprocessor (`-pgmF`), a build tool: `bt-shared`, which the project's buckconfig puts on the worker's `PATH`, and `bt-own`, which it doesn't |
| `//index:index` | built with `-fwrite-ide-info`, for its index (`index.bxl` prints it) |
| `//module-name-clash:user` | `X` uses `bar` through `second`'s `Re`, which re-exports it from `second`'s `Utils`; `first` and `user` have a module `Utils` too |
| `//header:header` | a module that `#include`s a header in the target's `srcs` (`Hdr/value.h`) |
| `//toolchain-th:toolchain-th` | a splice without a LANGUAGE pragma, for Template Haskell enabled by the toolchain's flags |
| `//c-lib:c-lib`, `//ffi-import:ffi-import`, `//th-ffi-splice:th-ffi-splice` | a C library, a library that imports its function, and a splice that calls it; `//th-ffi-splice:show` prints the splice |
| `//th-native-soname:show` | prints a splice that runs code calling a C library whose soname is `libver.so.1` |
| `//th-internal-splice:th-internal-splice` | a splice that runs a module of its own library, which isn't supported: its compile fails |
