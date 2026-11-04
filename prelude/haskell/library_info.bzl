# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

# If the target is a haskell library, the HaskellLibraryProvider
# contains its HaskellLibraryInfo. (in contrast to a HaskellLinkInfo,
# which contains the HaskellLibraryInfo for all the transitive
# dependencies). Direct dependencies are treated differently from
# indirect dependencies for the purposes of module visibility.
HaskellLibraryProvider = provider(
    fields = {
        "lib": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellLibraryInfo]
        "prof_lib": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellLibraryInfo]
    },
)

# The files of one module of a library compiled per-module that modules of
# other targets need when they import it:
#
# - hi: the module's interface.
# - abi: a file containing just the interface's ABI hash, which is what the
#   importers' dep files refer to (see Note [Early cut-off by dep files] in
#   compile_per_module.bzl).
# - dyn_hi: the module's dynamic interface, if it was compiled with
#   -dynamic-too, and None otherwise.
HaskellModuleFiles = record(
    hi = field(Artifact),
    abi = field(Artifact),
    dyn_hi = field(Artifact | None, None),
)

# A record of a Haskell library.
HaskellLibraryInfo = record(
    # The library target name: e.g. "rts"
    name = str,
    # package config database: e.g. platform009/build/ghc/lib/package.conf.d
    db = Artifact,
    # e.g. "base-4.13.0.0"
    id = str,
    # Import dirs indexed by profiling enabled/disabled
    import_dirs = dict[bool, Artifact],
    stub_dirs = list[Artifact],
    # This field is only used as hidden inputs to compilation, to
    # support Template Haskell which may need access to the libraries
    # at compile time.  The real library flags are propagated up the
    # dependency graph via MergedLinkInfo.
    libs = field(list[Artifact], []),
    # Package version, used to specify the full package when exposing it,
    # e.g. filepath-1.4.2.1, deepseq-1.4.4.0.
    # Internal packages default to 1.0.0, e.g. `fbcode-dsi-logger-hs-types-1.0.0`.
    version = str,
    is_prebuilt = bool,
    profiling_enabled = bool,
    # A package db for this library that doesn't name its library file.
    # Per-module compiles of the library's dependents use this db instead of
    # `db`. It is None for a prebuilt library, whose normal db is used.
    #
    # - For a library compiled per-module, this is its "early" db. It is
    #   registered before any of the library's modules are compiled, so that
    #   a dependent's module can start compiling as soon as the particular
    #   modules it imports are done (see Note [Compiling against dependencies
    #   module by module] in compile_per_module.bzl).
    # - For a library built with --make, it is its "library-less" db: the
    #   normal package, but without the library file. A dependent's compile
    #   then waits for the library's interfaces but not for the library to be
    #   linked, and a Template Haskell splice in it can't load the library's
    #   code (see Note [Template Haskell modules] in compile_per_module.bzl).
    early_db = field(Artifact | None, None),
    # see Note [Compiling against dependencies module by module]
    # in compile_per_module.bzl.
    below = field(TransitiveSet | None, None),
    # The tree of the native shared libraries the library depends on, which
    # its package db names for GHC's interpreter (see _native_ghci_libs in
    # haskell.bzl). A compile whose splices may load the library has it as an
    # input.
    native_libs_dir = field(Artifact | None, None),
    # The remaining fields are only set for a library compiled per-module.
    #
    # The files of each of the library's modules and boot files, keyed by
    # node name: the module's name, or "<module>-boot" for a boot file.
    modules = field(dict[str, HaskellModuleFiles] | None, None),
    # For each module, the interface files of the module itself and of
    # everything it imports, directly or indirectly, from libraries compiled
    # per-module. A dependent's module uses these to depend on exactly the
    # interfaces it needs. This is a DynamicValue, because a library's
    # imports are only known once its dependency analysis has run. Its
    # PerModuleClosures provider (see compile_per_module.bzl) maps each
    # module to its closure set.
    closures = field(typing.Any, None),
)

HaskellLibraryInfoTSet = transitive_set()
