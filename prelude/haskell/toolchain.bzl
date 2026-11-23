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

# Write the libdir of `compiler` to a new file called `name`. The libdir is
# what `ghc --print-libdir` prints. The per-module tools run GHC's code
# in-process, and that code reads GHC's settings and package database from
# the libdir. A toolchain rule calls this and puts the file in the
# toolchain's `libdir`. That way the compiler runs once per configuration,
# rather than once for each target.
def print_libdir(actions: AnalysisActions, name: str, compiler, compile_env: dict[str, str]) -> Artifact:
    out = actions.declare_output(name)
    actions.run(
        # The shell sends its output, and so the compiler's, to the file.
        in_compile_env(
            compile_env_script(compile_env) + 'exec > "$1"; shift; ',
            [out.as_output()],
            cmd_args(compiler, "--print-libdir"),
        ),
        category = "haskell_libdir",
        identifier = name,
    )
    return out

# Make the WorkerInfo for a per-module worker program, `worker`. The worker
# runs with the toolchain's compile_env set. The other arguments are the
# worker's settings, which per_module_worker_rts_options,
# per_module_worker_sessions and per_module_worker_session_mode in
# prelude/haskell/per_module_worker.bzl describe.
def per_module_worker_info(worker, compile_env: dict[str, str], rts_options: list[str], sessions: int | None, session_mode: str | None) -> WorkerInfo:
    cmd = cmd_args(worker, ["+RTS"] + rts_options + ["-RTS"] if rts_options else [])
    env = {}
    if sessions != None:
        env["BUCK2_GHC_WORKER_SESSIONS"] = str(sessions)
    if session_mode != None:
        env["BUCK2_GHC_WORKER_SESSION_MODE"] = session_mode
    return WorkerInfo(
        exe = in_compile_env(compile_env_script(compile_env), [], cmd),
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
        # The version of `compiler`, such as "9.12.2", so that the rules can
        # use the flags that it supports.
        "ghc_version": provider_field(str),
        # A file that holds the libdir of `compiler`, as print_libdir writes
        # it. Targets that compile per-module need it.
        "libdir": provider_field(Artifact | None, default = None),
        # The persistent worker (prelude/haskell/tools/worker) that compiles the
        # modules of per-module targets, as a WorkerInfo made by
        # per_module_worker_info. It is None if the toolchain has no worker.
        # See Note [The persistent worker] in compile_per_module.bzl.
        "per_module_shared_worker": provider_field(typing.Any, default = None),
        # The worker's settings: its RTS options, the most sessions it keeps,
        # and its session mode.
        "per_module_worker_rts_options": provider_field(list[str], default = []),
        "per_module_worker_sessions": provider_field(int | None, default = None),
        "per_module_worker_session_mode": provider_field(str | None, default = None),
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
        # The tools of the per-module compiles (see compile_per_module in
        # compile_per_module.bzl), as RunInfo. They must be linked with the
        # GHC library of the same version as `compiler`. When they are None,
        # the rules use the tools of prelude//haskell/tools, which are built
        # with the toolchain's GHC (see haskell_ghc_api_tool()).
        "per_module_deps": provider_field(typing.Any, default = None),
        "per_module_compile": provider_field(typing.Any, default = None),
    },
)
