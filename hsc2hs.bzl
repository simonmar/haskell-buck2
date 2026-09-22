# A rule for running hsc2hs.
#
load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load("@prelude//cxx:preprocessor.bzl", "cxx_inherited_preprocessor_infos", "cxx_merge_cpreprocessors")
load("@prelude//decls/toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo")

def _hsc2hs_include_args(pp_info):
    return [
        cmd_args(pp_info.set.project_as_args("include_dirs"), format = "--cflag={}"),
        cmd_args(pp_info.set.project_as_args("args"), format = "--cflag={}"),
    ]

def _hsc2hs_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.out)

    pp_infos = cxx_inherited_preprocessor_infos(ctx.attrs.deps)
    merged = cxx_merge_cpreprocessors(ctx.actions, [], pp_infos)

    # hsc2hs ships with GHC itself (as hsc2hs-<version>, e.g. hsc2hs-9.4.8),
    # not as a separately built/versioned tool, so there's no dedicated
    # toolchain field for it (unlike ALEX/HAPPY in third-party/haskell/
    # tools.bzl, which really are separate Cabal packages) - derive the
    # version from the haskell toolchain's own compiler name instead
    # (buck2/toolchains/BUCK sets compiler = "ghc-" + GHC_VERSION, read
    # from Cabal's own resolved plan - see buck2/gen-haskell-prebuilt.py).
    ghc_compiler = ctx.attrs._haskell_toolchain[HaskellToolchainInfo].compiler
    ghc_version = ghc_compiler[len("ghc-"):] if ghc_compiler.startswith("ghc-") else ghc_compiler
    hsc2hs_tool = "hsc2hs-" + ghc_version

    cxx_compiler = get_cxx_toolchain_info(ctx).cxx_compiler_info.compiler

    cmd = cmd_args(
        hsc2hs_tool,
        cmd_args("--cc=", cxx_compiler, delimiter = ""),
        "-C",
        "-std=c++20",
        "-C",
        "-D__HSC2HS__=1",
        ctx.attrs.extra_flags,
        # The hsc file's own package dir, so `#include "foo.h"`/`<foo.h>`
        # against a local (non-exported) header resolves, same as it would
        # when compiling a sibling cxx_library() source in this package.
        "-I" + ("." if ctx.label.package == "" else ctx.label.package),
        _hsc2hs_include_args(merged),
        "-o",
        out.as_output(),
        ctx.attrs.hsc_file,
    )
    ctx.actions.run(cmd, category = "hsc2hs")

    return [DefaultInfo(default_output = out)]

# Runs hsc2hs on `hsc_file`, producing `out`. `deps` is used purely to
# collect C/C++ include paths (via CPreprocessorInfo); it doesn't need to be
# (and usually isn't) the same as the consuming haskell_library()'s deps.
hsc2hs = rule(
    impl = _hsc2hs_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "extra_flags": attrs.list(attrs.string(), default = []),
        "hsc_file": attrs.source(),
        "out": attrs.string(),
        "_cxx_toolchain": toolchains_common.cxx(),
        "_haskell_toolchain": toolchains_common.haskell(),
    },
)
