# The headers of other targets, without their libraries: for C code that
# GHC would have given the include directories of the packages it depends on.
# Depending on the packages themselves would link them in as well, and in a
# profiling build, with the wrong libraries.

load("@prelude//cxx:preprocessor.bzl", "CPreprocessor", "CPreprocessorArgs", "cxx_inherited_preprocessor_infos", "cxx_merge_cpreprocessors")

def _headers_of_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        cxx_merge_cpreprocessors(ctx.actions, [], cxx_inherited_preprocessor_infos(ctx.attrs.deps)),
    ]

headers_of = rule(
    impl = _headers_of_impl,
    attrs = {"deps": attrs.list(attrs.dep(), default = [])},
)

# A library's include directory as Cabal installs it, with each of its
# install-includes at its path in the directory. `srcs` maps those paths to
# the files of the package.
#
# What is compiled against the library sees the directory, through the
# preprocessor flags that this target exports, and also sees
# `exported_include_dirs`. Those are directories that the build doesn't
# track, such as the one where the package's configure script generated
# headers.
#
# The directory holds symlinks to the headers, not copies. A compile can
# reach a header both through this directory and by another path: the
# library's own C, say, includes a header next to it by its path in the
# source tree. A header with `#pragma once` is skipped the second time only
# if both paths lead to the same file.
def _install_include_dir_impl(ctx: AnalysisContext) -> list[Provider]:
    include = ctx.actions.symlinked_dir("include", ctx.attrs.srcs)
    flags = [cmd_args(include, format = "-I{}")] + ["-I" + d for d in ctx.attrs.exported_include_dirs]
    return [
        DefaultInfo(default_output = include),
        cxx_merge_cpreprocessors(ctx.actions, [CPreprocessor(args = CPreprocessorArgs(args = flags))], []),
    ]

install_include_dir = rule(
    impl = _install_include_dir_impl,
    attrs = {
        "exported_include_dirs": attrs.list(attrs.string(), default = []),
        "srcs": attrs.dict(attrs.string(), attrs.source(), default = {}),
    },
)
