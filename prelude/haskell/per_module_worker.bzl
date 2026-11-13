# The buckconfig setting `[haskell] per_module_worker` chooses the
# persistent worker (tools/buck2-ghc-worker) that compiles the modules of
# per-module targets. It can be:
#
# - unset, or "none". There is no worker, and each module is compiled by its
#   own `ghc -c`.
# - "local", for the worker that the project builds from source, as one of
#   the packages of its cabal.project (buck2/tools/buck2-ghc-worker). The
#   toolchain can't name this worker (see Note [The persistent worker] in
#   prelude/haskell/compile_per_module.bzl), so cabal.bzl names it in each
#   per-module target that it generates. A hand-written target has to set
#   per_module_worker itself.
# - anything else, for a worker program given as a path, or as a name to
#   look up on $PATH. The toolchain uses this worker for every per-module
#   target.

# The target that makes the project's own shared worker (see worker.bzl) is
# named after the worker's executable, with this suffix.
PER_MODULE_WORKER_SUFFIX = "-shared"

# Where the project builds the worker from source: the package that the rules'
# tools/buck2-ghc-worker becomes, since the rules are at buck2/. cabal-buck2
# names the target of a package's executable after the executable, adding
# "-exe" if the package's library has the same name, as buck2-ghc-worker's
# does.
_WORKER_PACKAGE = "buck2/tools/buck2-ghc-worker"
_WORKER_EXE = "buck2-ghc-worker-exe"

def _configured() -> str:
    return read_root_config("haskell", "per_module_worker", "") or "none"

# The worker program that the toolchain uses, or None if the toolchain has
# no worker.
def toolchain_per_module_worker() -> str | None:
    configured = _configured()
    return None if configured in ("none", "local") else configured

# The target that each per-module target names as its worker, when the
# project builds the worker from source, or else None.
def project_per_module_worker() -> str | None:
    if _configured() != "local":
        return None

    # If the project doesn't build the worker (buck2/tools/buck2-ghc-worker
    # isn't in its cabal.project), buck2 reports that this target doesn't
    # exist.
    return "//{}:{}".format(_WORKER_PACKAGE, _WORKER_EXE + PER_MODULE_WORKER_SUFFIX)

# Whether the BUCK file being loaded is in the worker's own package. That
# package's targets build the worker, so they can't be compiled in it.
def in_worker_package() -> bool:
    return native.package_name() == _WORKER_PACKAGE

# Whether the target called `name`, in the BUCK file being loaded, is the
# worker's executable.
def is_worker_target(name: str) -> bool:
    return in_worker_package() and name == _WORKER_EXE

# Whether the per-module compiles use a worker at all.
def has_per_module_worker() -> bool:
    return _configured() != "none"

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
# -j8, three runs each; see tools/buck2-ghc-worker/DESIGN.md). With 8
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
# Note [Dropping the idle sessions] in tools/buck2-ghc-worker/src/Worker.hs has
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
# See Note [One-shot sessions] in tools/buck2-ghc-worker/src/Session.hs.
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
