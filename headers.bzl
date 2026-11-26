# The headers of other targets, without their libraries: for C code that
# GHC would have given the include directories of the packages it depends on.
# Depending on the packages themselves would link them in as well, and in a
# profiling build, with the wrong libraries.

load("@prelude//cxx:preprocessor.bzl", "cxx_inherited_preprocessor_infos", "cxx_merge_cpreprocessors")

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
# install-includes at its path in the directory. `srcs` are files of the
# package, `generated_headers` are in `generated_dir` (the directory of the
# headers that the package's configure script generated), and
# `provided_headers` are in `provided_dir`, a directory that the build makes.
#
# The directory holds symlinks to the headers, not copies. A compile can
# reach a header both through this directory and by another path: the
# library's own C, say, includes a header next to it by its path in the
# source tree. A header with `#pragma once` is skipped the second time only
# if both paths lead to the same file.
def _install_include_dir_impl(ctx: AnalysisContext) -> list[Provider]:
    files = dict(ctx.attrs.srcs)
    for path in ctx.attrs.generated_headers:
        files[path] = ctx.attrs.generated_dir.project(path)
    for path in ctx.attrs.provided_headers:
        if ctx.attrs.provided_dir == None:
            fail("{}: {} is neither in the package nor among the headers that its configure script generated, and no directory provides it".format(ctx.label, path))
        files[path] = ctx.attrs.provided_dir.project(path)
    return [DefaultInfo(default_output = ctx.actions.symlinked_dir("include", files))]

install_include_dir = rule(
    impl = _install_include_dir_impl,
    attrs = {
        "generated_dir": attrs.option(attrs.source(allow_directory = True), default = None),
        "generated_headers": attrs.list(attrs.string(), default = []),
        "provided_dir": attrs.option(attrs.source(allow_directory = True), default = None),
        "provided_headers": attrs.list(attrs.string(), default = []),
        "srcs": attrs.dict(attrs.string(), attrs.source(), default = {}),
    },
)
