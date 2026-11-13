# buck2-ghc-worker

A [buck2 persistent worker](https://buck2.build/docs/users/advanced/persistent_workers/)
for the per-module compiles of targets with `per_module = True` (see the
repository README). Without the worker, each module is compiled by a
`ghc -c` process of its own, which has to start GHC and read the interfaces
of all the module's imports again. With the worker, buck2 sends the
compiles to one long-running process that serves many targets. The worker
compiles each module as its request arrives, concurrently with the others,
in a GHC session for the module's set of flags. The sessions share the
interfaces they read, so the worker reads each interface once, however
many targets import it. buck2 still schedules each module's compile as a
separate action, and still skips a module whose imports' ABIs haven't
changed, as it does without the worker.

DESIGN.md explains why the worker is built this way, and which
alternatives we tried.

## Building

The worker links against the `ghc` library of the GHC that builds it, so it
has to be built with the same GHC as the project. It uses GHC's API, which
changes with each major release, so the code has some CPP and quirks for
particular versions. For example, GHC before 9.12 has no
`-fobject-determinism`, so a module's object may differ from one compile to
the next, and buck2 then links again more often than it needs to.

The toolchain builds the worker itself, with the project's GHC, from the
modules in `src` and `app` (some of which are links to modules of the rules'
GHC-API tools, in `prelude/haskell/tools/ghc-api`). It uses only the packages
that come with GHC, so building it is a single `ghc` command, which takes a
few seconds, and an edit to its sources takes effect in the next build. To
compile without the worker, with a `ghc -c` for each module, set
`per_module_worker` in the `[haskell]` section of the project's buckconfig
(`.buckconfig.local`, for example):

```
[haskell]
  per_module_worker = none
```

A project's own toolchain can use a worker built some other way, such as a
profiled build (see `prelude/haskell/per_module_worker.bzl`). It must be
built with the project's GHC. Nothing checks that, and a worker built with
another GHC fails in obscure ways.

This directory's cabal package is for the worker's tests and benchmark,
which `cabal test` and `cabal bench` run. Only those use packages beyond
GHC's own: `http2`, `http-types` and `network` for their gRPC client, and
the test frameworks.

A worker built from a different version of the rules refuses their
requests, with an error that says so.

## Sessions and memory

buck2 sends the worker as many compiles at once as its `-j` allows,
counting the other actions it runs, and keeps the worker running until the
end of the build. The worker keeps a session for each set of flags it has
seen, and drops sessions so that its memory doesn't grow without bound:

- Once it has compiled all of a target's modules, it drops that target's
  sessions.
- While it has more sessions than its limit, it drops the idle session
  that was least recently used.

If a request comes for a session that was dropped, the worker makes the
session again. A target with hs-boot files has sessions that don't share
the interfaces they read, so a new session for it reads them all again.

The worker that the targets share runs with the RTS options in
`per_module_worker_rts_options`, in the `[haskell]` section of the
buckconfig. The default is `-A64m -n4m -qn8 -I5`, and
`prelude/haskell/per_module_worker.bzl` explains why, and what to change on a
machine with many cores. The worker keeps at most
`per_module_worker_sessions` sessions, by default as many as it has
capabilities.

Most of the worker's memory holds the interfaces that its one-shot sessions
share. That grows with the build rather than with the session limit, so the
limit makes little difference to memory by default. On a machine that is
short of memory, `per_module_worker_session_mode = make` with a low limit
uses less, at the cost of reading interfaces again. On the bench's
`project`, `make` sessions with a limit of 4 used 2.4-2.5 GB at peak and
took 38.0-44.6s, against 5.2 GB and 22.2-24.7s with the defaults. Section 4
of DESIGN.md has the figures.

To see what the worker does, set `BUCK2_GHC_WORKER_VERBOSE=1` in the environment
of the buck2 daemon. Each worker then logs the time of each compile, and
the sessions it makes and drops, to its stderr file under
`/tmp/buck2_worker/`. If its RTS options also include `-T`, it logs its
peak memory, largest live heap, time spent collecting garbage, and the CPU
time of its mutator and of its collections when it ends.

## Known issues

A few of GHC's flags set state for the whole process, not just for one
compile. Note [Flags of the whole process] in `src/Session.hs` lists them.
The worker refuses a target whose flags include one of them, so such a
target has to be compiled without the worker.

## Testing

`cabal test`, or the `nix flake` checks, run two test suites against the
built worker:

- `spec` compiles a small package through the worker, sending one request
  per module as the rules do. It checks the files the worker writes, and
  the sessions it keeps and drops.
- `props` generates histories of a small package, with boot files, splices,
  and a dependency package imported through an early package db. It builds
  each history again and again through the worker, as buck2 would, using
  the worker's own dep files to decide what to compile again. After each
  build it compares every module with a clean build by `ghc -c`. The
  module must compile in both or fail in both, and have the same ABI hash.
  From GHC 9.12, whose objects are deterministic, the objects must be the
  same too. Before 9.12, the hashes of imports that the interfaces record
  must be the same instead.

## Benchmarking

`cabal bench` builds a few generated workloads (`wide`, `deep`, `th`,
`th-heavy`, `many`, `project` and `chain`) in several ways:

- through a worker, sending the modules as buck2 would with `-j 8`, once in
  the worker's default session mode and once with `--make` sessions only;
- with a `ghc -c` per module, as the rules compile per-module without the
  worker;
- with a `ghc --make` per target, as the rules compile without
  `per_module`;
- with one multi-unit `ghc --make -j8` for all the targets.

For each build it prints the wall time, CPU time, peak memory, largest
live heap and GC time, and the number of sessions the worker made. It also
prints the critical path, which is the least time the build could take
with unlimited cores, and, where one process does the whole build, the CPU
time of its mutator and of its collections.

`many` and `project` have many targets that depend on each other, so that
many targets are part-built at once, as in a clean build of a large
project. That is what fills a worker's memory. `chain` is a line of
targets, each depending on the one before, which a `ghc --make` per target
has to build one at a time. `bench/Main.hs` describes each workload.

`cabal bench --benchmark-options='N REPETITIONS [WORKLOAD...]'` sets how
many compiles run at once, how many times each build is repeated, and which
workloads to run. `GHC_FLAGS` sets the compiles' flags (`-O` by default),
and the worker's own environment variables, such as
`BUCK2_GHC_WORKER_SESSIONS`, are passed on to it.

## How the worker works

The code describes how the worker works. Start with Note [The persistent
worker] in the rules' `prelude/haskell/compile_per_module.bzl`, then Note
[The session's state] and Note [Each compile's home modules] in
`src/Session.hs`, and Note [Dropping the idle sessions] in `src/Worker.hs`.
