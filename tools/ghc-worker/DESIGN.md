# The design of ghc-worker

This explains why the worker is built the way it is, and which alternatives
we tried or considered. How it works is in the code: start with Note [The
persistent worker] in `prelude/haskell/compile_per_module.bzl`, then Note [How
the worker works] in `src/Worker.hs`.

The figures come from the bench (`bench/Main.hs`, see the README). Each one
gives the options that reproduce it. They were measured on one laptop with
8 cores and 16 threads, with GHC 9.12, and with 8 compiles at once unless
stated. Each was run three times, and the ranges cover the three runs.

Some choices were made on measurements of a large private codebase. For
those we give the reason, but no figures, since nobody else can check them.

## Goals

We want the worker:

- to be as fast as the machine's memory allows, and to degrade gracefully
  when memory is short;
- to work with stock GHC, from 9.6 to 9.14, so we can't rely on a patched GHC;
- to produce exactly what `ghc -c` produces, so that a module's action means
  the same thing with or without the worker.

## 1. Why a worker

When we compile per-module, each module of a target is compiled using `ghc -c`.

We get a more granular build graph from this, but it's slow.
Each `ghc -c` repeats work that `ghc --make` in contrast does only once per target:

- it starts GHC;
- it reads the interfaces of everything its module imports;
- for Template Haskell, it loads its dependencies' libraries.

We can't recover any of that from disk, so the only way to keep it around is to
keep a process alive with all of it. On the benchmark
(`cabal bench --benchmark-options='8 3'`), we can compare `ghc -c` against the
persistent worker:

| workload | `ghc -c` | worker | `ghc -c`'s CPU, against the worker's |
|---|---|---|---|
| `wide` | 9.5-9.8s | 3.6s | 2.9 times |
| `deep` | 8.8-8.9s | 3.2-3.3s | 3.2 times |
| `th` | 6.4-6.5s | 2.1-2.2s | 3.5-3.7 times |
| `th-heavy` | 7.4-7.5s | 2.2-2.3s | 4.1 times |
| `project` | 98.9-130.2s | 22.2-24.7s | 5.4-6.4 times |

Building the whole target with `ghc --make` is comparable to the worker. On
a single target, `ghc --make -j8` with the worker's allocation area
(`+RTS -A64m -n4m`, with `GHC` naming a script that adds them) took
2.4-3.1s, against the worker's 2.5-3.4s. With GHC's default RTS options it
took 3.8-5.5s, nearly all of the difference being collections.

So there is a lot to be gained back!

### What per-module buys

Per module buys two things: smaller rebuilds, and more parallelism.

#### Rebuilds

After an edit, buck2 runs again the actions whose inputs changed. With a
`ghc --make` per target, that is:

- the edited module's target, from scratch, since buck2 doesn't keep its
  old outputs for GHC to check;
- each target that depends on it, if the target's interfaces changed, again
  from scratch. They change on almost any edit, even a comment, since an
  interface records the hash of its source.

Per module, buck2 compiles again:

- the edited module;
- each module with an import whose ABI changed. A module's dep file names
  its imports' ABI hashes, not their interfaces (see Note [Early cut-off by
  dep files] in compile_per_module.bzl). So a comment recompiles one module, and
  a new definition the module and those that import it.

How much that saves depends on the module structure. It saves the most for
an edit low in the module graph, in a large target, or in a target with
many dependents. It saves the least for an edit to a small target that
nothing depends on.

The bench rebuilds after three edits, each on top of the one before (see
`edits` in bench/Main.hs). On `project`, at 8 at once, in one run on a busy
machine (`BENCH_WAYS='make per-target ghc-c worker' cabal bench
--benchmark-options='8 1 project chain many'`):

| `project`, after | a `ghc --make` per target | one multi-unit `ghc --make -j8` | a `ghc -c` per module | worker |
|---|---|---|---|---|
| a comment at the bottom | 3 targets, 5.2s | 1 module, 2.3s | 1 module, 0.8s | 1 module, 0.7s |
| a new definition at the bottom | 6 targets, 9.1s | 7 modules, 2.4s | 7 modules, 2.5s | 7 modules, 1.1s |
| a new definition at the top | 1 target, 2.8s | 1 module, 2.2s | 1 module, 1.0s | 1 module, 0.8s |

`chain` and `many` look the same: after each edit, the worker took
0.8-1.2s, and a `ghc --make` per target 2.0-7.6s.

- One multi-unit `ghc --make` compiles the same modules as per module, but
  checks all of them first, which took about 2s here.
- On a rebuild, the worker gains little over `ghc -c`. buck2 starts a fresh
  worker for each build, so it has few interfaces to share; it gains when
  several modules compile.
- The bench has no edit that changes the ABI of most of the modules above
  it. Per module would then recompile most of the build too.

#### Parallelism

Per module, a module starts as soon as its imports are compiled, even
those in another target. That only helps when a `ghc --make` per target
can't keep every core busy: when targets depend on each other in a chain,
or when the machine has more cores than there are targets ready to build.

The bench's `chain` is ten targets, each depending on the one before
(`cabal bench --benchmark-options='8 3 chain'`):

| `chain` | wall | CPU |
|---|---|---|
| a `ghc --make` per target | 20.1-21.8s | 20-21s |
| worker | 5.5-5.9s | 24-26s |
| one multi-unit `ghc --make -j8`, with `-A64m -n4m` | 3.7-3.9s | 21s |

A `ghc --make` per target builds one target at a time, on one core.

In `project`, each layer has ten targets, so a `ghc --make` per target
already keeps 8 cores busy, and the worker is 10-15% slower (section 7).
More cores would change that. With one compile at a time, the bench's
critical path is the least time the build could take with unlimited cores
(`BENCH_WAYS='per-target worker' cabal bench --benchmark-options='1 2
project'`):

| `project`, one compile at a time | wall | critical path |
|---|---|---|
| a `ghc --make` per target | 64.6-68.0s | 6.6-7.3s |
| worker | 50.2-51.4s | 1.4-1.5s |

So a `ghc --make` per target can use about ten cores, and per module about
35, if one worker could keep them busy (section 7).

## 2. One compile per request

The worker compiles each request in the thread that received it. It uses
GHC's `compileOne`, which is the per-module compile step that `ghc --make -j`
runs. buck2 schedules all the compiles, the worker just executes them.

We rejected:

- Batching: collecting requests that arrive close together, and
  compiling each batch with one `--make -j`. This loses too much of the
  per-module granularity that we're trying to get, and introduces a lot more waiting.
- A limit on the compile actions that the worker runs at once. buck2 already
  restricts the number of running jobs, there is no point also limiting the worker.

## 3. One worker for all targets

Ideally we have as few processes as possible. That avoids overhead and makes
sharing easier. So we aim to have a single shared worker as much as possible.

However, a process can't change its environment between requests. So the shared
worker can't process a module that needs a target-specific environment: build
tools on `PATH`.

Those modules are compiled by a simple `ghc -c` instead. To keep that rare,
`per_module_worker_build_tools` puts common build tools, such as a test
discovery preprocessor, on the shared worker's `PATH`. What's left in
practice is test suites with tools of their own.

We rejected:

- A worker per target. Each process has its own runtime, including an
  allocation area per capability, and its own sessions, and is kept alive
  until the end of the build. A large project has hundreds of targets.
- A worker per target, but only for the modules that need their own environment.
  This makes it harder to drop targets when they are "finished" (see below),
  since some of the modules are seen by each worker.
- Sharding: several shared workers, each taking a fixed share of the
  targets. This would reduce the cost of major GCs, but in our experiments
  it grew overall memory usage too fast.

Open ideas:

- A supervisor, which buck2 would see as one worker, running several workers
  behind it. Unlike sharding in the rules, it would see the requests as they
  arrive. So it could:
  - place each target, at its first request, on the worker with the fewest
    active sessions, and keep it there;
  - prefer the worker that already has a target's dependencies, so fewer
    interfaces are read twice;
  - stop sending new targets to a worker whose memory has grown, and
    restart it once its targets have finished, which frees the interfaces
    that one worker never frees;
  - run more workers when memory allows, and one when it doesn't;
  - give each worker its environment.

  On a machine with many cores, this is probably the way to use them: one
  process keeps only about 6 of 8 cores busy (section 7), while the
  module graph has room for far more (section 1).

## 4. Sessions, and when to drop them

The worker keeps a session for each set of session flags. A target has one
set of flags for each way it's built with.

Sessions are the main source of memory usage, so we try and drop them when
we don't need them:

- we drop a target's sessions once the target has compiled every module;
- we drop sessions past a limit on their number (`per_module_worker_sessions`),
  on a LRU basis.

A dropped session has to be made again if its target needs it. Note [Dropping the
idle sessions] in `src/Worker.hs` has the details.

With a lower session limit, we have to recreate sessions more often.
How much that costs depends on the kind of session (section 5). A one-shot session
is cheap to make again, and the shared interfaces dominate the worker's memory, so the
limit changes little. A `--make` session reads its interfaces again, so the limit
trades memory for speed. On the bench's `project`
(`GHC_WORKER_SESSIONS=4 cabal bench --benchmark-options='8 3 project'`,
and so on), where all 30 targets are part-built at once:

| limit | one-shot sessions: made, wall, peak | `--make` sessions: made, wall, peak |
|---|---|---|
| 4 | 120-124, 21.8-24.7s, 5.1-5.2 GB | 120-122, 38.0-44.6s, 2.4-2.5 GB |
| 16 (the default here) | 93-95, 22.2-24.7s, 5.2 GB | 91-93, 32.9-40.3s, 5.1-5.5 GB |
| 32 | 30, 23.1-25.2s, 5.2 GB | 30, 22.5-23.1s, 5.2 GB |

We rejected:

- A timeout. A short timeout drops the session of a target that is waiting on a
  slow module from upstream. A long one effectively keeps every target.
- A memory threshold. The runtime only knows the live heap after a major
  collection, and a dropped session's memory only returns at the next one.
  So the worker would overshoot.
- No limit, dropping only finished targets. With per-module scheduling,
  buck2 starts any module whose imports are compiled. So a clean build of a
  large project has well over a hundred targets part-built at once, far
  more than buck2's `-j`. A session for each is more memory than a laptop
  has.
- Keeping the sessions of targets with requests to come. The worker can't
  see buck2's queue; it could only guess.
- A heap limit (`-M`). That turns using too much memory into failing partway
  through the build.

## 5. What the sessions share

All sessions share:

- one name cache, so that an entity has one `Name` in every session (Note
  [One name cache for all the sessions]);
- one cache of the hashes of the libraries that Template Haskell loads.
  GHC computes these for every module with splices, and concurrent compiles
  would otherwise all miss the cache at once (Note [Hashing the libraries]);
- one copy of each package database, read once (Note [One copy of each
  package database]).

The Notes are in `src/Session.hs`.

### Interfaces

Most of what a session reads is interfaces: the libraries' and those of the
target's dependencies. Sharing them is the biggest saving.

A session in one-shot mode, as `ghc -c` uses, reads every interface into
its external package state, including its own target's. It keeps no home
package table. So one-shot sessions can share one external state, as long
as they agree on what an interface means: the same configuration, the same
way, and the same choice of whether to ignore interface pragmas. Note
[One-shot sessions] in `src/Session.hs` has the details.

Where the worker drops sessions and makes them again, sharing makes the
difference. On the bench (`cabal bench --benchmark-options='8 3 project
many'`; section 4 has `project` at other limits), at the default limit:

| workload | one-shot sessions | `--make` sessions |
|---|---|---|
| `project` (93-95 sessions) | 22.2-24.7s | 32.9-40.3s |
| `many` (323-335 sessions) | 17.7-21.5s | 59.2-78.1s |

With a limit high enough that no session is dropped, the two take the same
time.

This sharing has a cost. GHC typechecks an interface's declarations lazily.
A declaration which has not yet been typechecked keeps alive the environment
of the compile that read it, and with it that session's unit state. So:

- the sessions of a target share one unit state. That bounds what the
  shared state keeps alive by the number of targets, not of sessions;
- the shared state itself is never freed, so the worker's memory grows with
  the build.

We rejected:

- Replacing the shared state with a fresh one now and then. That made
  things worse: an old state lives as long as any of its sessions, and the
  fresh one reads the same interfaces again.
- Sharing one external state between `--make` sessions. A target's modules
  are home modules in its own sessions, but external in its dependents'.
  So a shared state would hold them twice, and their instances would
  overlap. Multi-unit `ghc --make` can share the state only because there a
  unit is either home or external for the whole session.
- Sharing only the libraries' interfaces, in a pool apart from each
  session's own. A declaration from the pool loads the interfaces it needs
  into the pool's environment, not the session's. So a session can miss
  instances.
- Sharing only the reading of interface files. GHC 9.12 has no hook for it,
  and decoding is a small part of a compile.

Still open, as the fallback if one-shot sharing runs into trouble:

- One session with a home unit for each target in the build, as multi-unit
  `ghc --make` has. That shares interfaces without lazy declarations keeping
  sessions alive. But a module's interface then records other targets'
  modules as home modules, so it differs from what `ghc -c` produces. And each
  compile needs the module graphs of its dependencies, which GHC makes from
  their sources (GHC 9.14 can do without).

## 6. Boot files

One-shot mode can't compile a target with `.hs-boot` files. Its cache has
no notion of a boot interface being replaced by the full module. Once a
`{-# SOURCE #-}` import has put B's boot interface in the cache:

- B's own compile sees duplicate instances;
- a later import of B may be given the boot interface.

So a target with boot files gets `--make` sessions. These keep their own
interfaces, and give each compile a home package table (Note [The
session's state] in `src/Session.hs`).

`per_module_worker_session_mode` chooses between the two kinds:

- `auto`, the default, uses one-shot sessions for the targets that can have
  them;
- `make` uses `--make` sessions for every target;
- `one-shot` refuses targets with boot files. Compiling them in one-shot
  mode wouldn't always fail: it could be silently wrong.

The tests run every target in both `make` and `one-shot` modes, so each
kind of session is tested on every target it can compile.

## 7. Concurrency and garbage collection

All the compiles share one heap, so every collection stops all of them.
This is bad! Separate `ghc -c` or `ghc --make` processes each collect their
own heap, without stopping the others. So the worker's GC settings matter
quite a lot.

The rules' default RTS options are `-A64m -n4m -qn8`:

- a large allocation area, since the process runs many compiles at once;
- split into 4 MB chunks, which a capability that runs out can take from
  the others;
- 8 threads for each collection.

On the bench's `project`
(`GHC_WORKER_RTS='-A64m -n4m -qn8' BENCH_WAYS=worker cabal bench
--benchmark-options='8 3 project'`, and so on):

| RTS options | wall | GC | peak |
|---|---|---|---|
| `-A64m -n4m -qn4` | 22.0-23.7s | 3.7-3.9s | 5.2-5.3 GB |
| `-A64m -n4m -qn8`, the default | 20.5-22.1s | 2.4-2.5s | 5.2 GB |
| `-A32m -n4m -qn8` | 21.3-25.0s | 3.1-3.5s | 5.1-5.5 GB |
| `-A128m -n4m -qn8` | 20.3-23.4s | 2.3-2.6s | 6.8 GB |
| `-A256m -n4m -qn8` | 19.6-22.5s | 1.5-2.2s | 7.4-9.0 GB |

With no `-qn`, the RTS's default of a GC thread for each of the worker's
16 capabilities, it took 21.0-21.4s with 3.5-3.6s of GC, against
20.0-20.8s with 2.4s for `-qn8` in the same runs.

More GC threads shorten each collection, up to a point. A larger
allocation area means fewer collections, but costs memory for each
capability, and its effect on the wall time is within the noise here.

We rejected:

- the non-moving collector;
- a smaller growth factor (`-F`);
- compaction;
- fewer capabilities (`-N` set to the number of physical cores).

On our measurements, each was slower, used more memory, or both.

### Where the worker falls behind

The worker does less work than separate processes, but keeps fewer cores
busy. So its lead over a `ghc --make` per target shrinks as more compiles
run at once. On the bench's `project`
(`BENCH_WAYS='per-target worker' cabal bench --benchmark-options='N 1
project'`, one run each):

| compiles at once | `ghc --make` per target | worker |
|---|---|---|
| 1 | 67.1s | 53.2s |
| 2 | 39.0s | 34.3s |
| 4 | 25.9s | 28.4s |
| 8 | 19.6s | 20.5s, with 11% less CPU |

At 8 at once, the worker keeps about 6.2-6.4 cores busy, and a `ghc
--make` per target about 7.4. On a quieter machine, in alternating runs,
the worker took 14.3-15.2s on `project` against 12.6-13.5s.

One multi-unit `ghc --make -j8`, with the worker's allocation area, bounds
what one process can do: 3.7-3.9s on `chain` against the worker's
5.5-5.8s, and 10.4-11.6s on `project` against 14.3-15.2s. It shares
interfaces between targets without sessions, and writes outputs that
differ from `ghc -c`'s (section 5).

Besides collections, the compiles wait on each other inside GHC: on thunks
that another compile is evaluating, and on locks. Multi-unit `ghc --make
-j8` shows the same limit, so it comes from running many compiles in one
GHC, not from the worker. It isn't the shared name cache: a worker patched
to give each session its own was no faster. Several processes (section 3)
would get past it, at the cost of memory.

## 8. Correctness

Some of the worker's structure is there because the simpler version was
wrong:

- Each compile has a home package table of its own. One shared table,
  patched for each compile, gave several bugs with boot interfaces (Note
  [Each compile's home modules]).
- The worker passes `-fforce-recomp`. Under buck2 it makes no difference,
  since buck2 removes a module's outputs before compiling it. Outside
  buck2, GHC can judge a module up to date when a splice's inputs have
  changed (Note [Compiling whenever buck2 asks]).
- It refuses flags that affect the whole process. A later session would
  silently ignore them (Note [Flags of the whole process]).
- The object linker starts once. Two sessions starting it at once could
  hang (Note [Starting the object linker once]).
- Each session has a temporary directory of its own. Otherwise a library at
  a reused path could be confused with an old one (Note [A temporary
  directory per session]).

## 9. Open questions

- The default session limit is the worker's number of capabilities. A
  higher one is faster where memory allows (section 4), but we haven't
  settled what the default should be.
- A memory budget could adapt to the machine better than a fixed limit. The
  worker would drop sessions, and collect, before its memory reached a set
  size.
- buck2 spreads its jobs across every target that can start. It has no way
  to prefer targets that are already part-built, which would need fewer
  sessions.
