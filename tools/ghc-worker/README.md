# ghc-worker

A [buck2 persistent worker](https://buck2.build/docs/users/advanced/persistent_workers/)
for the per-module compiles of targets with `per_module = True` (see the
repository README). Without it each module is compiled by its own
`ghc -c` process, which starts GHC and reads the interfaces of every import
again. With it, buck2 sends the compiles to a long-running process that
serves many targets, compiling each module as it arrives, concurrently, in a
GHC session per set of flags. The sessions share the interfaces they read,
so the worker reads each one once, however many targets import it. The
per-action scheduling and early cut-off of the per-module build are
unchanged.

DESIGN.md explains why the worker is built this way, and the alternatives
we tried.

## Building or installing

The worker links against the `ghc` library of the GHC it compiles with.
It uses GHC's API, which changes with each major release. This sadly requires
some CPP and per-version quirks, e.g. before GHC 9.12 there is no
`-fobject-determinism`, so a module's object may differ from one compile
to the next and buck2 will do extra re-linking.

The rules use the worker only when `per_module_worker` in the `[haskell]` section
of the project's buckconfig (`.buckconfig.local`, say) says so. With it
unset, or `none`, each module is compiled by a `ghc -c` of its own.

The simplest way to bring in the worker is as a package of the project:

```
packages: . buck2/tools/ghc-worker
```

in `cabal.project`. `cabal buck2` then generates a target for it like any
other package, and buck2 builds it with the project's GHC before the first
per-module compile, when the buckconfig says:

```
[haskell]
  per_module_worker = local
```

Or, to keep it out of the project's plan, build it with the project's
GHC:
```
cd buck2/tools/ghc-worker
cabal install --program-suffix=-$(ghc --numeric-version) exe:ghc-worker
```

and name it in the buckconfig, by its path or its name on `$PATH`:

```
[haskell]
  per_module_worker = ghc-worker-9.10.3
```

A worker installed for the wrong version of the rules should fail to run.

buck2 sends a worker as many compiles at once as its `-j` allows, with the
other actions, and keeps it until the end of the build. So the worker drops
a target's sessions once it has compiled all the target's modules, and
while it has more sessions than its limit (see below), drops the least
recently used idle one; the next request with a dropped session's
flags makes it again. (A target with hs-boot files has sessions of its
own, which read its imports again.)
`GHC_WORKER_VERBOSE=1` in the environment of the buck2 daemon makes each
worker log the time of each compile, and the sessions it makes and drops,
to its stderr file under `/tmp/buck2_worker/`; with `-T` among its RTS
options, it also logs its peak memory, largest live heap, time spent
collecting garbage, and the CPU time of its mutator and its collections as
it ends.

The worker that the targets share runs with the RTS options of
`per_module_worker_rts_options` in the `[haskell]` section of the
buckconfig (`-A64m -n4m -qn8` by default: see
`toolchains/per_module_worker.bzl` for why, and for a machine with many
cores), and keeps at most `per_module_worker_sessions` sessions (as many
as it has capabilities by default). Its memory is mostly the interfaces
that its one-shot sessions share, which grow with the build rather than
with that limit, so the limit changes little. On a machine short of
memory, `per_module_worker_session_mode = make` with a low limit uses less,
at the cost of reading interfaces again: on the bench's `project`, a limit
of 4 took the worker's peak memory from 5.2 GB to 2.4 GB, and 1.6-1.9
times as long. DESIGN.md, section 4, has the figures.

## Known issues

A few of GHC's flags set the state of the whole process, not of one
compile (see Note [Flags of the whole process] in `src/Session.hs` for
the list). The worker refuses a target whose flags have one; compile such
a target without the worker.

## Testing

`cabal test` runs two suites against the built worker. `spec` compiles a
small package through it, one request per module as the rules send them,
and checks what it writes and the state the worker keeps. `props`
generates histories of a small package (boot files, splices, a dependency
package imported through an early package db), builds them again and again
through the worker as buck2 would, deciding what to recompile from the
worker's own dep files, and compares each build with a clean `ghc -c` one:
whether each module compiles, its ABI hash, and its object (from GHC 9.12,
whose objects are deterministic) or else the imports' hashes its interface
records.

The tests can be run with `cabal test` or via the `nix flake` checks.

`cabal bench` builds a few generated packages (`wide`, `deep`, `th`,
`th-heavy`, `many`, `project` and `chain`) in several ways: through a worker, sending the
modules as buck2 would with `-j 8`, once with the sessions it chooses and
once with --make sessions only; with a `ghc -c` per module, as the rules
compile without a worker; with a `ghc --make` per target, as the rules
compile without per_module; and with one `ghc --make -j8`, which compiles
several targets as one multi-unit build. It prints the wall time, CPU
time, peak memory, largest live heap and GC time of each, the sessions
the worker made, the critical path, the least time a build could take
with unlimited cores, and the CPU time of the mutator and of collections
where one process does the build. `many` and `project` have many targets, depending on
each other, part-built at once, as a clean build of a large project does,
which is what fills a worker's memory. `chain` is a line of targets, each
depending on the one before, which a `ghc --make` per target must build
one at a time: see bench/Main.hs.
`cabal bench --benchmark-options='N REPETITIONS [WORKLOAD...]'` sets the
concurrency, the repetitions and the workloads, `GHC_FLAGS` the compiles'
flags (`-O` by default), and the worker's own settings
(`GHC_WORKER_SESSIONS`, say) are passed on to it.

How the worker works is described in the code: Note [The persistent
worker] in the rules' `prelude/haskell/compile_per_module.bzl`, Note [The
session's state] and Note [Each compile's home modules] in `src/Session.hs`, and
Note [Dropping the idle sessions] in `src/Worker.hs`.
