# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

HaskellPlatformInfo = provider(
    fields = {
        "name": provider_field(typing.Any, default = None),
    }
)

# The shell commands that export the variables of compile_env. The shell
# evaluates each value when the action runs, rather than buck2 passing it
# through literally. That way a value such as
# "$(clang -print-file-name=libclang_rt.asan-x86_64.so)" is worked out on
# the machine that runs the action. This follows the project's convention
# of finding tools on $PATH when an action runs, rather than writing
# absolute paths of the host into .bzl or BUCK files (see `compiler` and
# `packager` in toolchains/BUCK).
def compile_env_script(compile_env: dict[str, str]) -> str:
    return "".join([
        'export {}="{}"; '.format(name, value)
        for name, value in compile_env.items()
    ])

# Run `cmd` after the shell script `script`, such as one made by
# compile_env_script. The script's positional parameters are `args`
# followed by `cmd`. The script must shift `args` off, so that what is left
# is the command to run.
def in_compile_env(script: str, args: list, cmd: cmd_args) -> cmd_args:
    if not script:
        return cmd
    return cmd_args(["sh", "-c", script + 'exec "$@"', "sh"] + args, cmd)

# Make the WorkerInfo for a per-module worker program, `worker`. The worker
# runs with the toolchain's compile_env set, and with the shared build tools
# in `tools_dir`, if there are any, on its PATH. The other arguments are the
# worker's settings, which per_module_worker_rts_options,
# per_module_worker_sessions and per_module_worker_session_mode in
# prelude/haskell/per_module_worker.bzl describe.
def per_module_worker_info(worker, compile_env: dict[str, str], rts_options: list[str], sessions: int | None, session_mode: str | None, tools_dir: Artifact | None) -> WorkerInfo:
    cmd = cmd_args(worker, ["+RTS"] + rts_options + ["-RTS"] if rts_options else [])
    script = compile_env_script(compile_env)
    if tools_dir != None:
        script += 'export PATH="$PATH:$1"; shift; '
    env = {}
    if sessions != None:
        env["BUCK2_GHC_WORKER_SESSIONS"] = str(sessions)
    if session_mode != None:
        env["BUCK2_GHC_WORKER_SESSION_MODE"] = session_mode
    return WorkerInfo(
        exe = in_compile_env(script, [tools_dir] if tools_dir != None else [], cmd),
        env = env,
    )

HaskellToolchainInfo = provider(
    # @unsorted-dict-items
    fields = {
        "compiler": provider_field(typing.Any, default = None),
        "compiler_flags": provider_field(typing.Any, default = None),
        "compile_env": provider_field(typing.Any, default = {}),
        # Environment for the link actions, unlike `compile_env` literally
        # (not shell-evaluated).
        "link_env": provider_field(typing.Any, default = {}),
        "dynamic_ghc": provider_field(bool, default = True),
        # The persistent worker (tools/buck2-ghc-worker) that compiles the
        # modules of per-module targets, as a WorkerInfo made by
        # per_module_worker_info. It is None if the toolchain has no worker.
        # See Note [The persistent worker] in compile_per_module.bzl.
        "per_module_shared_worker": provider_field(typing.Any, default = None),
        # The worker's settings: its RTS options, the most sessions it keeps,
        # and its session mode.
        "per_module_worker_rts_options": provider_field(list[str], default = []),
        "per_module_worker_sessions": provider_field(int | None, default = None),
        "per_module_worker_session_mode": provider_field(str | None, default = None),
        # The build tools that are on the worker's PATH, as target labels,
        # and a directory that holds them.
        "per_module_worker_build_tools": provider_field(list, default = []),
        "per_module_worker_build_tools_dir": provider_field(typing.Any, default = None),
        "linker": provider_field(typing.Any, default = None),
        "linker_flags": provider_field(typing.Any, default = None),
        "haddock": provider_field(typing.Any, default = None),
        "hsc2hs": provider_field(typing.Any, default = None),
        "compiler_major_version": provider_field(typing.Any, default = None),
        "package_name_prefix": provider_field(typing.Any, default = None),
        "packager": provider_field(typing.Any, default = None),
        "support_always_use_cache": provider_field(bool, default = False),
        "use_argsfile": provider_field(typing.Any, default = None),
        "support_expose_package": provider_field(bool, default = False),
        "archive_contents": provider_field(typing.Any, default = None),
        "ghci_script_template": provider_field(typing.Any, default = None),
        "ghci_iserv_template": provider_field(typing.Any, default = None),
        "ide_script_template": provider_field(typing.Any, default = None),
        "ghci_binutils_path": provider_field(typing.Any, default = None),
        "ghci_lib_path": provider_field(typing.Any, default = None),
        "ghci_ghc_path": provider_field(typing.Any, default = None),
        "ghci_iserv_path": provider_field(typing.Any, default = None),
        "ghci_iserv_prof_path": provider_field(typing.Any, default = None),
        "ghci_cxx_path": provider_field(typing.Any, default = None),
        "ghci_cc_path": provider_field(typing.Any, default = None),
        "ghci_cpp_path": provider_field(typing.Any, default = None),
        "ghci_packager": provider_field(typing.Any, default = None),
        "cache_links": provider_field(typing.Any, default = None),
        "script_template_processor": provider_field(typing.Any, default = None),
    },
)
