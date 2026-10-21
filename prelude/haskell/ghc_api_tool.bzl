load("@prelude//decls:toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo")

# A program of the rules' own that uses the GHC API (prelude/haskell/tools/
# ghc-api), built with the toolchain's GHC from `srcs` and the packages that
# come with GHC. It reads what that GHC writes, such as interfaces, which
# only the same GHC can read, so it is built with the GHC in use rather than
# installed. The program gets that GHC's libdir as the CPP macro GHC_LIBDIR.
def _haskell_ghc_api_tool_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    # The toolchain's compile_env, whose values are shell-evaluated, as for
    # every GHC command (see ghc_env in compile.bzl).
    env_script = "".join(['export {}="{}"; '.format(name, value) for name, value in haskell_toolchain.compile_env.items()])

    def in_compile_env(cmd):
        return cmd_args("sh", "-c", env_script + 'exec "$@"', "sh", cmd) if env_script else cmd
    srcs = ctx.actions.symlinked_dir("srcs", {src.basename: src for src in ctx.attrs.srcs}, has_content_based_path = False)

    libdir = ctx.actions.declare_output("libdir")
    ctx.actions.run(
        in_compile_env(cmd_args("sh", "-c", 'out="$1"; shift; "$@" --print-libdir > "$out"', "sh", libdir.as_output(), haskell_toolchain.compiler)),
        category = "haskell_ghc_api_tool_libdir",
    )

    exe = ctx.actions.declare_output(ctx.attrs.name)
    ctx.actions.run(
        in_compile_env(cmd_args(
            "sh",
            "-c",
            'libdir=$(cat "$1"); shift; exec "$@" -outputdir "$BUCK_SCRATCH_PATH" "-DGHC_LIBDIR=\\"$libdir\\""',
            "sh",
            libdir,
            haskell_toolchain.compiler,
            "-v0",
            "-O",
            # Only GHC's own packages: not those of a package environment
            # file in the project, say.
            "-package-env=-",
            "-hide-all-packages",
            [["-package", p] for p in _PACKAGES],
            cmd_args(srcs, format = "-i{}"),
            cmd_args(srcs, ctx.attrs.main, delimiter = "/"),
            "-o",
            exe.as_output(),
        )),
        category = "haskell_ghc_api_tool",
    )
    return [DefaultInfo(default_output = exe), RunInfo(args = cmd_args(exe))]

# The packages the tools use, all of which come with GHC.
_PACKAGES = ["base", "bytestring", "containers", "directory", "filepath", "ghc", "ghc-boot", "process"]

haskell_ghc_api_tool = rule(
    impl = _haskell_ghc_api_tool_impl,
    attrs = {
        # The modules, all in one directory.
        "srcs": attrs.list(attrs.source()),
        # The file of the Main module, among `srcs`.
        "main": attrs.string(),
        "_haskell_toolchain": toolchains_common.haskell(),
    },
)
