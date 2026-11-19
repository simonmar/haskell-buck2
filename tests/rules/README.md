# Tests of the rules

Builds a small project (`project/`) and checks what the rules do:

- `per_module.py`: what the per-module rules decide: which package dbs,
  libraries and interfaces each module's compile gets, what its dep file
  lists, and which modules compile again after an edit.
- `both_ways.py`: what should hold however a target is compiled. Each check
  builds its fixtures both per-module and with `--make`, and says where the
  two differ.
- `other_rules.py`: `haskell_test`, linking and the toolchains.

Only GHC's own packages are used (`base`, `template-haskell`, `process`), so
neither Hackage nor cabal-buck2 is needed.

```
tests/rules/run.sh GHC_BIN_DIR [WORK_DIR] [-- --only CHECK ...]
```

`GHC_BIN_DIR` has `ghc` and `ghc-pkg`; `buck2`, `python3`, C compilers (`cc`
for GHC, `clang` for buck2's C toolchain, which builds `//c-lib:c-lib`) and
`g++` (that toolchain's linker) must be on `PATH`. The project is copied to
`WORK_DIR` (a new temporary directory by default), since the checks edit its
sources, and built there; each buck2 command's output is saved under
`WORK_DIR/project/buck-logs/`. It takes about a minute and a half.

`nix flake check` at the top of the repository runs the tests with each
GHC. A dev shell has what they need, so with one GHC:

```
nix develop .#ghc9141 -c sh -c 'tests/rules/run.sh "$(dirname "$(command -v ghc)")"'
```

With `BAZEL_REMOTE` set to a `bazel-remote` binary, `check_cache` runs one
as a remote cache, and checks that the rules' actions upload their results
and that a clean build finds them there. The dev shells and `nix flake
check` set it.

With `PER_MODULE_WORKER=builtin`, `run.sh` sets `[haskell]
per_module_worker` so that the modules are compiled in the worker that the
toolchain builds (`prelude/haskell/tools/worker`). By default, it sets it to
`none`. The same checks apply.
`check_workers` also checks that the modules were compiled in the worker,
apart from those that need their target's environment. `nix flake check`
runs the tests both with and without the worker.

With `EXTERNAL_INTERPRETER=true`, `run.sh` adds `-fexternal-interpreter` to
the toolchain's `[haskell] compiler_flags`, so splices run in external
interpreters. The checks that are known to fail in the worker because its
splices share its process then pass.

Each check prints `PASS` or `FAIL` (with the missing and unexpected members
of the set it compared) or `SKIP` (a check of what the platform doesn't
have, `check_cache` without `BAZEL_REMOTE`, or the explicit level imports
check before GHC 9.14). A check of a known bug in the rules (marked with
`known_failure` in harness.py, for all runs or only for some, such as those
with the worker) prints `XFAIL` when it fails, and `XPASS` when it passes,
which means the bug is fixed and the mark should go.
The script fails on any `FAIL` or `XPASS`. Some checks are of what
per_module doesn't support, such as a splice that runs its own target's
code, or of a mistake in `splice_depends`. They check that the
compile fails.

## How it works

- `gen_prebuilt.py` writes the `third-party-haskell` cell: a
  `haskell_prebuilt_library()` per package of GHC's that the fixtures use,
  and the `tools.bzl` that the rest of the support code loads.
- `check.py` runs the checks in order, in one buck2 daemon (buck2 keeps dep
  files in the daemon's memory, so the early cut-off checks need it to
  live). `harness.py` has what they share.
- A fixture that sets `per_module = PER_MODULE` (`project/compile/defs.bzl`)
  is compiled per-module, and with `--make` when it is built with the
  `//compile:make` modifier, as in `//lib:lib?//compile:make`. The two are
  different configurations, so a check can build both in the same daemon.
  The fixtures that are about per-module compilation alone set `per_module
  = True`. It reads the compiles' command lines from `buck2 log what-ran
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
| `//th-local-splice:th-local-splice` | `splice_depends = ["//th-gen:th-gen"]`: `C.Splice`, a splice of `gen`; `C.Plain`, a module without Template Haskell; `C.Ann`, an `ANN` pragma |
| `//th-local-splice:show` | prints `C.Splice`'s value, which comes from `gen` |
| `//data-dirs:data-dirs` | a splice that runs `//data-dirs:paths`'s code, which reads a data file through the variable that `data_dirs` sets |
| `//th-prebuilt-splice:th-prebuilt-splice` | `splice_depends = []`: a splice that runs only `template-haskell` |
| `//eli:eli`, `//eli:eli-unlisted`, `//eli:eli-own` | GHC 9.14: `import splice TH.Gen`, `import splice Q.Lib` (from `//make-lib`, built with --make) and `import splice Language.Haskell.TH`, in a target that lists `th-gen` and `make-lib` in `splice_depends`; `import splice TH.Gen` in one that doesn't list `th-gen`; and an `import splice` of a module of the target itself |
| `//eli-reexport:eli-reexport`, `//eli-reexport:eli-reexport-wide` | GHC 9.14: `import splice A.Base`, which `//reexport:reexport` re-exports, and the same import in a target that also depends on `//lib`, without listing it |
| `//eli-persist:eli-persist` | GHC 9.14: a splice that runs `TH.Gen`, imported without `splice`, in a module with `ExplicitLevelImports` and then `ImplicitStagePersistence` |
| `//boot-cycle:boot-cycle` | two modules in an import cycle, through an hs-boot file |
| `//boot-cycle-inline:boot-cycle-inline` | with -O, a module that needs the interface of a module in an import cycle that it reaches only through an unfolding |
| `//ownboot:ownboot` | a module whose hs-boot file no import cycle needs |
| `//mainname:server` | a binary whose Main module is in `app/Server.hs`, without a module header |
| `//rtsflags:rtsflags` | `+RTS ... -RTS` among the compiler flags |
| `//main:main` | a binary depending on `lib-user`; `main-shared`, the same linked shared |
| `//unrelated-failure:w` | imports a module of `//unrelated-failure:s`, whose other module doesn't compile |
| `//reexport:reexport`, `//reexport-user:reexport-user` | `reexport` re-exports `A.Base`; `reexport-user` imports `A.Base` through it |
| `//th-make-dep:th-make-dep`, `//th-make-dep:mkrun`, `//th-make-dep:mkmiss` | Template Haskell modules depending on `//make-lib:make-lib`, built with `--make`: `MK.Lit`'s splice runs only `template-haskell`, and its `splice_depends` leaves `make-lib` out; `MK.Run`'s runs `make-lib`'s code, which it lists; `MK.Miss`'s does too, without listing it, so its compile fails |
| `//th-isolation:show`, `//th-isolation:crash`, `//th-isolation:slow` | splices that would be isolated in processes of their own: `show` prints two splices' calls of a global counter; `crash`'s splice aborts its process while `slow`'s is still running |
| `//make-between:p`, `//make-between:m`, `//make-between:t` | `t`'s module imports `m`'s, built with `--make`, whose interface refers to `p`'s, compiled per-module |
| `//flat-sources:flat-sources`, `//make-lib:make-lib` | `flat-sources`'s flat sources (`Lib.hs`), one of which imports `Q.Lib` from `make-lib` (built with `--make`), whose interface path ends in `/Lib.hi` |
| `//module-move:hi`, `//module-move:lo`, `//module-move:main` | a module that moves from `hi` to `lo`, its dependency |
| `//build-tools:own`, `//build-tools:flags` | modules that run build tools: preprocessors (`-pgmF`) named in a module's pragma or the target's flags, and a splice; and a module that runs none |
| `//build-tools:discover` | a preprocessor that, like `hspec-discover`, imports the modules it finds by listing a directory |
| `//build-tools:unused`, `//build-tools:unused-splice` | a build tool that no module runs; `unused-splice` runs a splice, which might |
| `//advice:th-flags`, `//advice:ann` | `th-flags`'s flags turn on Template Haskell for all its modules; `ann`'s `AD.Ann` has an HLint ANN pragma |
| `//index:index` | built with `-fwrite-ide-info`, for its index (`index.bxl` prints it) |
| `//module-name-clash:user` | `X` uses `bar` through `second`'s `Re`, which re-exports it from `second`'s `Utils`; `first` and `user` have a module `Utils` too |
| `//header:header` | a module that `#include`s a header in the target's `srcs` (`Hdr/value.h`) |
| `//toolchain-th:toolchain-th` | a splice without a LANGUAGE pragma, for Template Haskell enabled by the toolchain's flags |
| `//c-lib:c-lib`, `//ffi-import:ffi-import`, `//th-ffi-splice:th-ffi-splice` | a C library, a library that imports its function, and a splice that calls it; `//th-ffi-splice:show` prints the splice |
| `//th-native-soname:show` | prints a splice that runs code calling a C library whose soname is `libver.so.1` |
| `//th-internal-splice:th-internal-splice`, `//th-internal-splice:use` | a splice that runs a module of its own library, which isn't supported: its compile fails. With `--make` it compiles, and `use` prints the value it made |
| `//test-suite:uses-tool`, `//test-suite:reads-data`, `//test-suite:manual` | `haskell_test`s: one that runs its build tool (`//test-suite:tool`), one that reads a data file through `data_dirs`, and one that fails, labelled `manual` |
| `//test-suite:uses-run-tool`, `//test-suite:runs-tool`, `//test-suite:build-tool-only` | `uses-run-tool` (a test) and `runs-tool` (an executable) have `//test-suite:tool` as a run tool only, and `build-tool-only` has it as a build tool only |
| `//instances:low`, `//instances:mid`, `//instances:high` | `high`'s module sees orphan instances (a class instance, a type family instance) of `low` only through `mid`, so an edit to one of them must compile it again |
| `//prof-shared:static`, `//prof-shared:static-pic` | profiled binaries, linked `static` and `static_pic`, of a library that is otherwise only linked shared |
