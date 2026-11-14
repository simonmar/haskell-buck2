# The design of buck2-ghc-worker

This document explains why the worker is built the way it is, and which
alternatives we tried or considered. The code explains how it works: start
with Note [The persistent worker] in `prelude/haskell/compile_per_module.bzl`,
then Note [How the worker works] in `src/Worker.hs`.

The figures come from the bench (`bench/Main.hs`; see the README), and each
one gives the options that reproduce it. They were measured on one laptop
with 8 cores and 16 threads, with GHC 9.12, and with 8 compiles running at
once unless stated otherwise. Each measurement was run three times, and
the ranges cover the three runs.

Some choices were based on measurements of a large private codebase. For
those we give the reason, but no figures, since nobody else can check
them.

## Goals

We want the worker:

- to be as fast as the machine's memory allows, and to slow down gracefully
  rather than fail when memory is short;
- to work with stock GHC, from 9.6 to 9.14, so that it doesn't rely on a
  patched GHC;
- to produce exactly what `ghc -c` produces, so that a module's action
  gives the same result with or without the worker.

## 1. Why a worker

With `per_module = True`, the rules compile each module of a target in a
buck2 action of its own, which runs `ghc -c` on that one module. This gives
buck2 a finer-grained build graph, but it is slow. Each `ghc -c` repeats
work that a `ghc --make` for the whole target does only once:

- it starts GHC;
- it reads the interfaces of everything its module imports;
- for Template Haskell, it loads the libraries of the target's
  dependencies.

None of this work leaves anything on disk that a later process could load
more cheaply. The only way to avoid repeating it is to keep a process
alive that has already done it. On the bench
(`cabal bench --benchmark-options='8 3'`), `ghc -c` compares with the
persistent worker like this:

| workload | `ghc -c` | worker | CPU time of `ghc -c`, as a multiple of the worker's |
|---|---|---|---|
| `wide` | 9.5-9.8s | 3.6s | 2.9 |
| `deep` | 8.8-8.9s | 3.2-3.3s | 3.2 |
| `th` | 6.4-6.5s | 2.1-2.2s | 3.5-3.7 |
| `th-heavy` | 7.4-7.5s | 2.2-2.3s | 4.1 |
| `project` | 98.9-130.2s | 22.2-24.7s | 5.4-6.4 |

The worker comes close to building the whole target with one
`ghc --make`. On `wide` and `deep`, which are single targets, we ran
`ghc --make -j8` and the worker alternately, three times each
(`BENCH_WAYS=make` and `BENCH_WAYS=worker` with
`--benchmark-options='8 1 wide'`, and likewise for `deep`). Given the
worker's allocation area (`+RTS -A64m -n4m`, by setting `GHC` to a script
that adds those options), `ghc --make -j8` took 2.5-3.1s, against the
worker's 2.7-3.4s. With GHC's default RTS options it took 4.1-5.5s, and
nearly all of the difference was time spent collecting garbage.

So the worker wins back most of what compiling per-module costs.

### What compiling per-module buys

Compiling per-module gives two things: smaller rebuilds, and more
parallelism.

#### Rebuilds

After an edit, buck2 runs again every action whose inputs changed. When
each target is compiled by one `ghc --make`, buck2 runs again:

- the edited module's target, from scratch, since buck2 doesn't keep the
  target's old outputs for GHC to compare against;
- each target that depends on a rebuilt target whose interfaces changed,
  again from scratch. The interfaces change on almost any edit, even to a
  comment, because an interface records the hash of its source.

When each module is compiled on its own, buck2 compiles again:

- the edited module;
- each module with an import whose ABI changed. A module's dep file names
  the ABI hashes of its imports, not their interfaces (see Note [Early
  cut-off by dep files] in compile_per_module.bzl).

So an edit to a comment compiles one module again, and a new definition
compiles the edited module and the modules that import it.

How much that saves depends on the module structure. It saves the most for
an edit low in the module graph, in a large target, or in a target that
many others depend on. It saves the least for an edit to a small target
that nothing depends on.

The bench rebuilds after three edits, each made on top of the one before
(see `edits` in bench/Main.hs). On `project`, with 8 compiles at once, in
one run on a busy machine (`BENCH_WAYS='make per-target ghc-c worker' cabal
bench --benchmark-options='8 1 project chain many'`):

| `project`, after | a `ghc --make` per target | one multi-unit `ghc --make -j8` | a `ghc -c` per module | worker |
|---|---|---|---|---|
| a comment at the bottom | 3 targets, 5.2s | 1 module, 2.3s | 1 module, 0.8s | 1 module, 0.7s |
| a new definition at the bottom | 6 targets, 9.1s | 7 modules, 2.4s | 7 modules, 2.5s | 7 modules, 1.1s |
| a new definition at the top | 1 target, 2.8s | 1 module, 2.2s | 1 module, 1.0s | 1 module, 0.8s |

The results for `chain` and `many` are similar. After each edit, the
worker took 0.8-1.2s, and a `ghc --make` per target took 2.0-7.6s.

- One multi-unit `ghc --make` compiles the same modules as the per-module
  builds, but first checks every module to see whether it is up to date,
  which took about 2s here.
- On a rebuild, the worker gains little over `ghc -c`. buck2 starts a fresh
  worker for each build, so on a rebuild that compiles only a few modules,
  there are few interfaces for the sessions to share. The worker gains
  more when a rebuild compiles many modules.
- None of the bench's edits changes the ABI of most of the modules above
  it. After such an edit, compiling per-module would also compile most of
  the build again, and gain little.

#### Parallelism

When each module is compiled on its own, it can start as soon as its
imports are compiled, even those in another target. That only helps when a
`ghc --make` per target can't keep every core busy. That happens when
targets depend on each other in a chain, or when the machine has more
cores than there are targets ready to build.

The bench's `chain` workload is ten targets, each depending on the one
before (`cabal bench --benchmark-options='8 3 chain'`):

| `chain` | wall | CPU |
|---|---|---|
| a `ghc --make` per target | 20.1-21.8s | 20-21s |
| worker | 5.5-5.9s | 24-26s |
| one multi-unit `ghc --make -j8`, with `-A64m -n4m` | 3.7-3.9s | 21s |

A `ghc --make` per target can only build one target at a time here, using
one core.

In `project`, each layer has ten targets, so a `ghc --make` per target
already keeps 8 cores busy, and the worker is 5-15% slower (see section
7). More cores would change that. The critical path of a build is the
least time it could take with unlimited cores. The bench measures it most
accurately with one compile at a time
(`BENCH_WAYS='per-target worker' cabal bench --benchmark-options='1 2
project'`):

| `project`, one compile at a time | wall | critical path |
|---|---|---|
| a `ghc --make` per target | 64.6-68.0s | 6.6-7.3s |
| worker | 50.2-51.4s | 1.4-1.5s |

Dividing the total time by the critical path, a `ghc --make` per target
could use about ten cores, and a per-module build about 35, if a single
worker could keep that many busy (see section 7).

## 2. One compile per request

The worker compiles each request in the thread that received it, with
GHC's `compileOne`, which is the step that `ghc --make -j` runs to compile
one module. buck2 decides when each module compiles, and the worker just
runs the compiles it is sent.

We rejected:

- Batching, that is, collecting the requests that arrive close together
  and compiling each batch with one `--make -j`. This would lose too much
  of the per-module granularity that we are trying to get, and would add a
  lot of waiting.
- A limit on how many compiles the worker runs at once. buck2 already
  limits how many actions run at once, so there is no point in the worker
  limiting them too.

## 3. One worker for all targets

We want as few worker processes as possible. Each process has overheads of
its own, and processes can't share what they have read. So as far as
possible, all targets share a single worker.

However, a process can't change its environment between requests, so the
shared worker can't compile a module that needs an environment specific to
its target. In practice, that means a target whose build tools must be on
`PATH`.

Those modules are compiled by a plain `ghc -c` instead. To keep that rare,
`per_module_worker_build_tools` puts common build tools, such as a test
discovery preprocessor, on the shared worker's `PATH`. In practice, that
leaves only test suites with build tools of their own.

We rejected:

- A worker per target. Each process has its own runtime, including an
  allocation area for each capability, and its own sessions, and buck2
  keeps it alive until the end of the build. A large project has hundreds
  of targets.
- A worker per target, used only for the modules that need the target's
  environment. A target's modules would then be split between the shared
  worker and the target's own, so neither worker would see every module of
  the target. That makes it harder to tell when a target is finished and
  its sessions can be dropped (see section 4).
- Sharding: several shared workers, each taking a fixed share of the
  targets. Each worker's major collections would be cheaper, but in our
  experiments the total memory grew too fast.

Still open:

- A supervisor, which buck2 would see as one worker, running several
  workers behind it. Unlike sharding in the rules, the supervisor would see
  the requests as they arrive. So it could:
  - place each target on the worker with the fewest active sessions when
    the target's first request comes, and keep it there;
  - prefer the worker that already has a target's dependencies, so that
    fewer interfaces are read twice;
  - stop sending new targets to a worker whose memory has grown, and
    restart it once its targets have finished, which frees the interfaces
    that a worker otherwise never frees (see section 5);
  - run more workers when memory allows, and only one when it doesn't;
  - give each worker its own environment.

  On a machine with many cores, this is probably the way to use them. One
  process keeps only about 6 of 8 cores busy (see section 7), while the
  module graph has room for far more (see section 1).

## 4. Sessions, and when to drop them

A session is a GHC session that the worker keeps for compiling requests,
along with the interfaces it has read. The worker keeps one session for
each set of session flags, that is, the flags that all the modules of a
target share. A target has one set of session flags for each way it is
built: static, shared, profiled and so on.

Sessions use most of the worker's memory, so we drop them when we no
longer need them:

- we drop a target's sessions once the worker has compiled every module of
  the target;
- when there are more sessions than a limit (`per_module_worker_sessions`),
  we drop the idle session that was least recently used.

If a target needs a session after it has been dropped, the worker has to
make it again. Note [Dropping the idle sessions] in `src/Worker.hs` has
the details.

With a lower session limit, the worker has to make sessions again more
often. How much that costs depends on the kind of session (see sections 5
and 6). A one-shot session is cheap to make again. The interfaces that the
one-shot sessions share use most of the worker's memory, so the limit
changes little. A `--make` session has to read its interfaces again, so the
limit trades memory for speed. On the bench's `project`
(`BUCK2_GHC_WORKER_SESSIONS=4 cabal bench --benchmark-options='8 3 project'`,
and likewise for the other limits), where all 30 targets are part-built at
once:

| limit | one-shot sessions: made, wall, peak | `--make` sessions: made, wall, peak |
|---|---|---|
| 4 | 120-124, 21.8-24.7s, 5.1-5.2 GB | 120-122, 38.0-44.6s, 2.4-2.5 GB |
| 16 (the default on this machine) | 93-95, 22.2-24.7s, 5.2 GB | 91-93, 32.9-40.3s, 5.1-5.5 GB |
| 32 | 30, 23.1-25.2s, 5.2 GB | 30, 22.5-23.1s, 5.2 GB |

We rejected:

- A timeout. A short timeout drops the session of a target that is waiting
  for a slow module upstream. A long one keeps nearly every target's
  sessions.
- A memory threshold. The runtime only knows the size of the live heap
  after a major collection, and a dropped session's memory only comes back
  at the next one. So the worker would overshoot the threshold.
- No limit, dropping only the sessions of finished targets. buck2 starts
  any module whose imports are compiled. So a clean build of a large
  project has well over a hundred targets part-built at once, far more
  than buck2's `-j`. A session for each of them takes more memory than a
  laptop has.
- Keeping the sessions of targets that have requests to come. The worker
  can't see buck2's queue, so it could only guess which those are.
- A heap limit (`-M`). That would turn using too much memory into failing
  partway through the build.

## 5. What the sessions share

All the sessions share:

- one name cache, so that an entity has the same `Name` in every session
  (Note [One name cache for all the sessions]);
- one cache of the hashes of the libraries that Template Haskell loads.
  GHC computes these for every module with splices, and without a shared
  cache, compiles running at the same time would all miss the cache
  together (Note [Hashing the libraries]);
- one copy of each package database, read only once (Note [One copy of
  each package database]).

These Notes are in `src/Session.hs`.

### Interfaces

Most of what a session reads is interfaces: those of the libraries, and
those of the target's dependencies. Sharing them saves the most.

GHC has two modes of compiling. `ghc -c` uses one-shot mode, and
`ghc --make` uses `--make` mode. A session in one-shot mode reads every
interface it needs into its external package state, GHC's cache of the
interfaces it has read, including the interfaces of its own target's
modules. It keeps no home package table, which is where `--make` mode
keeps the target's own modules. So one-shot sessions can share one
external package state, as long as their compiles read each interface in
the same way.

GHC reads an interface using the flags of the compile that reads it,
including those in the module's OPTIONS_GHC pragmas. So two compiles can
only share a state if they have the same build configuration and the same
flags, apart from flags that GHC doesn't consult when it reads an
interface. Notes [One-shot sessions] and [The flags an interface is read
with] in `src/Session.hs` have the details.

Sharing makes the difference when the worker drops sessions and makes them
again. On the bench (`cabal bench --benchmark-options='8 3 project
many'`; section 4 has `project` with other limits), with the default limit:

| workload | one-shot sessions | `--make` sessions |
|---|---|---|
| `project` (93-95 sessions) | 22.2-24.7s | 32.9-40.3s |
| `many` (323-335 sessions) | 17.7-21.5s | 59.2-78.1s |

With a limit high enough that no session is dropped, the two kinds of
session take the same time.

This sharing has a cost. GHC typechecks an interface's declarations
lazily, the first time they are needed. Until a declaration has been
typechecked, it keeps alive the environment of the compile that read it,
and with it that session's unit state, which is what GHC knows about the
packages. So:

- all the sessions made for a target with the same flags share one unit
  state, so that what the shared state keeps alive grows with the number
  of targets, not the number of sessions;
- the shared state itself is never freed, so the worker's memory grows
  through the build.

We rejected:

- Replacing the shared state with a fresh one from time to time. That made
  things worse. An old state lives as long as any session that uses it,
  and the fresh one reads the same interfaces again.
- Sharing one external package state between `--make` sessions. A target's
  modules are home modules in the target's own sessions, but external
  modules in its dependents' sessions. So a shared state would hold them
  twice, and their instances would overlap. Multi-unit `ghc --make` can
  share its state only because there, each unit is either home or external
  for the whole session.
- Sharing only the libraries' interfaces, in a pool separate from each
  session's own state. When GHC typechecks a declaration from the pool, it
  loads the interfaces that the declaration needs into the pool, not into
  the session. So a session could miss instances.
- Sharing only the reading of interface files. GHC 9.12 has no hook for
  it, and decoding interfaces is a small part of a compile.

Still open, as the fallback if one-shot sharing runs into trouble:

- One session with a home unit for each target in the build, as
  multi-unit `ghc --make` has. That would share interfaces without lazy
  declarations keeping sessions alive. But a module's interface would then
  record other targets' modules as home modules, so it would differ from
  what `ghc -c` produces. And each compile would need the module graphs of
  its dependencies, which GHC makes from their sources (GHC 9.14 can do
  without them).

## 6. Boot files

One-shot mode can't compile a target with `.hs-boot` files, because its
cache has no notion of a boot interface being replaced by the full module.
Say module A imports B with `{-# SOURCE #-}`, which puts B's boot
interface in the cache. Then:

- B's own compile sees B's instances twice, once from the boot interface
  and once from B itself;
- a later import of B may be given the boot interface instead of the full
  module.

So a target with boot files gets `--make` sessions. These keep their
target's interfaces to themselves, and give each compile a home package
table of its own (Note [The session's state] in `src/Session.hs`).

`per_module_worker_session_mode` chooses between the two kinds of session:

- `auto`, the default, uses one-shot sessions for the targets that can
  have them, and `--make` sessions for the others;
- `make` uses `--make` sessions for every target;
- `one-shot` uses one-shot sessions, and refuses targets with boot files.
  Compiling such a target in one-shot mode wouldn't always fail; it could
  silently produce the wrong result.

The tests run every target in both `make` and `one-shot` modes, so that
each kind of session is tested on every target it can compile.

## 7. Concurrency and garbage collection

All the compiles share one heap, so every collection stops all of them.
Separate `ghc -c` or `ghc --make` processes each collect their own heap,
without stopping the others. So the worker's GC settings matter a lot.

The rules' default RTS options for the worker are `-A64m -n4m -qn8 -I5`:

- a large allocation area for each capability, since the process runs many
  compiles at once;
- the area split into 4 MB chunks, which a capability that runs out can
  take from the others;
- 8 threads for each collection;
- a full collection only after 5 seconds of idleness (see below).

On the bench's `project`
(`BUCK2_GHC_WORKER_RTS='-A64m -n4m -qn8' BENCH_WAYS=worker cabal bench
--benchmark-options='8 3 project'`, and likewise for the other options):

| RTS options | wall | GC | peak |
|---|---|---|---|
| `-A64m -n4m -qn4` | 22.0-23.7s | 3.7-3.9s | 5.2-5.3 GB |
| `-A64m -n4m -qn8`, the default | 20.5-22.1s | 2.4-2.5s | 5.2 GB |
| `-A32m -n4m -qn8` | 21.3-25.0s | 3.1-3.5s | 5.1-5.5 GB |
| `-A128m -n4m -qn8` | 20.3-23.4s | 2.3-2.6s | 6.8 GB |
| `-A256m -n4m -qn8` | 19.6-22.5s | 1.5-2.2s | 7.4-9.0 GB |

Without `-qn`, the RTS uses a GC thread for each of the worker's 16
capabilities. That took 21.0-21.4s, with 3.5-3.6s of GC, against
20.0-20.8s, with 2.4s of GC, for `-qn8` in the same runs.

More GC threads make each collection shorter, up to a point. A larger
allocation area means fewer collections, but costs memory for each
capability, and its effect on the wall time is within the noise here.

The bench's builds keep the worker busy, so they don't show the cost of the
RTS's idle collection. By default, the RTS makes a full collection whenever
the process has been idle for 0.3 seconds (`-I0.3`). That suits an
interactive program, which waits for its user. A worker waits for buck2's
next request many times in a build, so each of those waits cost a full
collection of its heap. On a clean build of a test-suite of CircuitHub's
monorepo, whose two configurations each had a worker (one run each, so the
times are rough):

| RTS options, besides `-A64m -n4m -qn8` | wall | GC CPU of the two workers |
|---|---|---|
| none (`-I0.3`) | 252s | 259s and 265s |
| `-I5` | 179s | 41s and 48s |
| `-I0` (no idle collection) | 166-207s | 39-52s and 46-48s |

Waiting 5 seconds saves as much as turning idle collection off, and still
collects after a long wait, when the worker may have memory to give back.

`-qi1` with `-qb1`, which would leave capabilities that have been idle out
of young-generation collections, crashed both workers within a minute, with
the RTS reporting a corrupted heap. We don't know whether that is a bug of
the RTS or one that its different timing exposes in the worker.

We rejected the following, because in our measurements each was slower,
used more memory, or both:

- the non-moving collector;
- a smaller growth factor (`-F`);
- compaction;
- fewer capabilities (`-N` set to the number of physical cores).

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

With 8 compiles at once, the worker keeps about 6.2-6.4 cores busy, and a
`ghc --make` per target about 7.4. On a quieter machine, in alternating
runs with 8 at once, the worker took 14.3-15.2s on `project`, against
12.6-13.5s for a `ghc --make` per target.

One multi-unit `ghc --make -j8`, with the worker's allocation area, shows
the best that a single process can do. In the same alternating runs, it
took 3.7-3.9s on `chain`, against the worker's 5.5-5.8s, and 10.4-11.6s on
`project`, against 14.3-15.2s. It shares interfaces between targets without needing sessions,
but its outputs differ from those of `ghc -c` (see section 5).

Besides waiting for collections, the compiles wait for each other inside
GHC: on thunks that another compile is evaluating, and on locks.
Multi-unit `ghc --make -j8` has the same limit, so the limit comes from
running many compiles in one GHC process, not from the worker. It isn't
caused by the shared name cache: a worker patched to give each session a
cache of its own was no faster. Several processes (see section 3) would get
past the limit, at the cost of memory.

## 8. Correctness

Some of the worker's structure is there because a simpler version gave
wrong results:

- Each compile has a home package table of its own. One shared table,
  patched for each compile, caused several bugs with boot interfaces (Note
  [Each compile's home modules]).
- The worker passes `-fforce-recomp`. Under buck2 it makes no difference,
  since buck2 removes a module's outputs before compiling it. But without
  it, outside buck2, GHC could decide that a module is up to date when the
  inputs of one of its splices have changed (Note [Compiling whenever buck2
  asks]).
- The worker refuses flags that affect the whole process. Otherwise, a
  later session would silently ignore them (Note [Flags of the whole
  process]).
- The worker starts the object linker once, itself. Two sessions starting
  it at the same time could hang (Note [Starting the object linker once]).
- Each session has a temporary directory of its own. Otherwise, a new
  library at a path that an old session had used could be mistaken for the
  old one (Note [A temporary directory per session]).

These Notes are in `src/Session.hs` and `src/Worker.hs`.

## 9. Open questions

- The default session limit is the worker's number of capabilities. A
  higher limit is faster where memory allows (see section 4), but we
  haven't settled what the default should be.
- A memory budget could adapt to the machine better than a fixed limit.
  The worker would drop sessions, and collect garbage, before its memory
  reached a set size.
- buck2 spreads its jobs across every target that can start. It has no way
  to prefer the targets that are already part-built, which would need
  fewer sessions.
