# The Haskell toolchain's `per_module_worker` says whether the modules of
# per-module targets are compiled in the persistent worker, and the
# buckconfig setting `[haskell] per_module_worker` sets it for the standard
# toolchain (toolchains/defaults.bzl). It can be:
#
# - "builtin", the default. The toolchain builds the worker from its
#   sources in prelude/haskell/tools/worker, with the toolchain's own GHC, so
#   it always matches that GHC.
# - "none". There is no worker, and each module is compiled by its own
#   `ghc -c`.
#
# A toolchain of a project's own can use a worker built some other way, by
# setting HaskellToolchainInfo's per_module_shared_worker itself (see
# per_module_worker_info in prelude/haskell/toolchain.bzl).

load("@prelude//haskell:ghc_api_tool.bzl", "GHC_API_TOOL_PACKAGES", "build_ghc_api_tool")

# The value of the standard toolchain's `per_module_worker`: "builtin" or
# "none".
def toolchain_per_module_worker() -> str:
    return read_root_config("haskell", "per_module_worker", "") or "builtin"

# Whether the per-module compiles use a worker at all.
def has_per_module_worker() -> bool:
    return toolchain_per_module_worker() != "none"

# Build the persistent worker with `compiler`, from `srcs`, the directory
# that prelude//haskell/tools:worker-srcs makes. It uses only packages that
# come with GHC.
#
# The worker is linked dynamically when the GHC is. A worker compiles
# modules as that GHC would, so it has to load the code of Template Haskell
# splices the same way, which depends on how it is itself linked (see the
# notes on Template Haskell in prelude/haskell/haskell.bzl).
#
# The RTS options are the worker's defaults. The toolchain overrides -A and
# -qn with per_module_worker_rts_options. --disable-delayed-os-memory-return
# makes the RTS give the memory of dropped sessions back to the OS at once.
# By default the RTS uses MADV_FREE, and the memory stays counted against
# the process until the kernel needs it. The worker's cabal package
# (prelude/haskell/tools/worker), which builds it for its tests and
# benchmark, has the same options: keep the two in step.
def build_per_module_worker(actions: AnalysisActions, compiler, compile_env: dict[str, str], srcs: Artifact, dynamic: bool) -> Artifact:
    return build_ghc_api_tool(
        actions,
        "buck2-ghc-worker",
        compiler,
        compile_env,
        [cmd_args("-i", srcs, "/worker/src", delimiter = "")],
        cmd_args(srcs, "/worker/app/Main.hs", delimiter = ""),
        GHC_API_TOOL_PACKAGES + ["stm", "unix"],
        ["-threaded", "-rtsopts", "-with-rtsopts=-N -A16m -qn4 --disable-delayed-os-memory-return"] + (["-dynamic"] if dynamic else []),
    )

# The RTS options of the shared worker, from `[haskell]
# per_module_worker_rts_options` in the buckconfig.
#
# All the worker's compiles share one heap, and each garbage collection
# stops all of them. So the default options aim to make collections rare
# and quick:
#
# - -A64m gives a large allocation area, because the process runs many
#   compiles at once. -n4m splits the area into chunks, so that a
#   capability that runs out can take a chunk from the others.
# - -qn8 collects with 8 threads, rather than 4, or the RTS's default of one
#   for each capability.
# - -I5 makes the RTS wait for 5 seconds of idleness before a full
#   collection, rather than 0.3 seconds. A worker is idle for a moment
#   between requests all the time, and with the RTS's default, each of
#   those moments cost it a full collection of its heap. On the build of a
#   test-suite of CircuitHub's monorepo, the default took 5 times the
#   collection time of -I5, and the build took longer.
#
# We measured these with the worker's benchmark (its `project` benchmark at
# -j8, three runs each; see prelude/haskell/tools/worker/DESIGN.md). With 8
# collection threads the build took 20.5-22.1s, of which 2.4-2.5s was
# collection. With 4 threads it took 22.0-23.7s (3.7-3.9s of collection), and
# with one thread per capability 21.0-21.4s (3.5-3.6s). A larger allocation
# area means fewer collections, but costs memory: -A128m and -A256m used
# 1.6-3.8 GB more at peak, with no clear gain in time. Each capability has its
# own allocation area, kept for the whole build. So with -N, on a machine with
# many cores, a smaller -A or a -maxN keeps the memory in check.
def per_module_worker_rts_options() -> list[str]:
    return (read_root_config("haskell", "per_module_worker_rts_options", "") or "-A64m -n4m -qn8 -I5").split()

# The most sessions that the shared worker keeps at once, counting both the
# sessions in use and the idle ones, from `[haskell]
# per_module_worker_sessions` in the buckconfig. If it is unset, the limit
# is the worker's number of capabilities.
#
# If the worker drops a session while the session's target is only partly
# built, it makes the session again for the target's next module. That is
# cheap for a one-shot session, because the worker shares the interfaces it
# has read between all its one-shot sessions. But a --make session (see
# per_module_worker_session_mode) holds the interfaces that its own target
# has read, which can be a few hundred MB for a large target, and a new
# session has to read them all again. So the limit makes little difference
# to one-shot sessions, and for --make sessions it trades memory for speed.
# Note [Dropping the idle sessions] in prelude/haskell/tools/worker/src/Worker.hs has
# the benchmark's figures.
def per_module_worker_sessions() -> str:
    return read_root_config("haskell", "per_module_worker_sessions", "")

# The kind of session that the shared worker compiles each target in, from
# `[haskell] per_module_worker_session_mode` in the buckconfig. It can be:
#
# - auto, which is the worker's default when this is unset. Targets without
#   hs-boot files get one-shot sessions, which share the interfaces they
#   read. The other targets get sessions in GHC's --make mode.
# - make. Every target gets a --make session, which reads its interfaces
#   for itself.
# - one-shot. Every target gets a one-shot session, and the compiles of a
#   target with hs-boot files fail.
#
# See Note [One-shot sessions] in prelude/haskell/tools/worker/src/Session.hs.
def per_module_worker_session_mode() -> str:
    return read_root_config("haskell", "per_module_worker_session_mode", "")

# The build tools to put on the shared worker's PATH, from `[haskell]
# per_module_worker_build_tools` in the buckconfig, as target labels
# separated by spaces. The worker has a single PATH for all its compiles.
# So a target whose build tools are all in this list compiles in the shared
# worker, but a target with any other build tool compiles without a worker.
# It is worth listing the tools that many targets use, such as
# tasty-discover. A tool that is built with the Haskell toolchain can't be
# listed, because the toolchain would then depend on itself.
def per_module_worker_build_tools() -> list[str]:
    return read_root_config("haskell", "per_module_worker_build_tools", "").split()
