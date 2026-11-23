# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load("@prelude//haskell:compile.bzl", "compile_args", "ghc_file_args", "run_ghc", "target_splice_env")
load("@prelude//haskell:link_info.bzl", "cxx_toolchain_link_style")
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
)
load("@prelude//linking:shared_libraries.bzl", "SharedLibraryInfo")

HaskellHaddockInfo = provider(
    fields = {
        "html": provider_field(typing.Any, default = None),
        "interface": provider_field(typing.Any, default = None),
    },
)

# The documentation of a library. `native_libs` are the library's own native
# libraries, as for compile().
def haskell_haddock_lib(ctx: AnalysisContext, pkgname: str, native_libs: SharedLibraryInfo) -> Provider:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    iface = ctx.actions.declare_output("haddock-interface", has_content_based_path = False)
    odir = ctx.actions.declare_output("haddock-html", dir = True, has_content_based_path = False)

    # Haddock compiles the library's modules as `ghc --make` would, so its
    # splices see what the compile's do.
    link_style = cxx_toolchain_link_style(ctx)
    splices = target_splice_env(ctx, link_style, False, native_libs)
    args = compile_args(
        ctx,
        link_style,
        enable_profiling = False,
        pkgname = pkgname,
        final = splices.final,
    )

    cmd = cmd_args(haskell_toolchain.haddock)
    cmd.add(cmd_args(args.args_for_cmd, format = "--optghc={}"))
    cmd.add(
        "--use-index",
        "doc-index.html",
        "--use-contents",
        "index.html",
        "--html",
        "--hoogle",
        "--no-warnings",
        "--dump-interface",
        iface.as_output(),
        "--odir",
        odir.as_output(),
        "--package-name",
        pkgname,
    )

    for lib in attr_deps(ctx):
        hi = lib.get(HaskellHaddockInfo)
        if hi != None:
            cmd.add("--read-interface", hi.interface)

    cmd.add(ctx.attrs.haddock_flags)

    source_entity = read_root_config("haskell", "haddock_source_entity", None)
    if source_entity:
        cmd.add("--source-entity", source_entity)

    if args.args_for_file:
        cmd.add(ghc_file_args(ctx, "args-" + args.variant + ".haskell_haddock_argsfile", cmd_args(args.args_for_file, format = "--optghc={}"), args.srcs))

    # Haddock compiles in a temporary directory of its own.
    run_ghc(ctx, cmd, splices, args.variant, "haddock-" + args.variant, "", [], "haskell_haddock")

    return HaskellHaddockInfo(interface = iface, html = odir)

def haskell_haddock_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    out = ctx.actions.declare_output("haddock-html", dir = True, has_content_based_path = False)

    cmd = cmd_args(haskell_toolchain.haddock)

    cmd.add(
        "--gen-index",
        "--gen-contents",
        "-o",
        out.as_output(),
    )

    dep_htmls = []
    for lib in attr_deps(ctx):
        hi = lib.get(HaskellHaddockInfo)
        if hi != None:
            cmd.add("--read-interface", hi.interface)
            dep_htmls.append(hi.html)

    cmd.add(ctx.attrs.haddock_flags)

    script = ctx.actions.declare_output("haddock-script", has_content_based_path = False)
    script_args = cmd_args([
        "#!/usr/bin/env bash",
        "set -ueo pipefail",
        cmd_args(cmd, delimiter = " ", quote = "shell"),
    ])
    for dir in dep_htmls:
        script_args.add(
            cmd_args(
                ["cp", "-Rf", cmd_args(dir, format = "{}/*"), out.as_output()],
                delimiter = " ",
            ),
        )
    ctx.actions.write(
        script,
        script_args,
        is_executable = True,
        allow_args = True,
    )

    ctx.actions.run(
        cmd_args(script, hidden = script_args),
        category = "haskell_haddock",
        no_outputs_cleanup = True,
    )

    return [DefaultInfo(default_outputs = [out])]
