# Per-module compilation (`per_module = True`): one `ghc -c` action per module
# instead of one `ghc --make` action per target. See the Notes at the end of
# this file, starting with Note [Per-module compilation].

load(
    "@prelude//haskell:compile.bzl",
    "CompileResultInfo",
    "dependency_libs",
    "get_exposed_package_args",
    "get_producing_indices",
    "ghc_env",
    "ghc_flags",
    "has_modules",
    "in_env",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfoTSet",
    "HaskellModuleFiles",
)
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "get_artifact_suffix",
    "haskell_library_unit_id",
    "is_haskell_src",
    "module_name_to_file",
    "output_extensions",
    "srcs_to_pairs",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
)

# A module's closure set holds the interface files of the module's closure:
# the module itself, and everything it imports, directly or indirectly, from
# targets compiled per-module (see Note [Per-module compilation]). It is a
# transitive set whose value is the module's own files, and whose children
# are the closure sets of the modules it imports. Each target passes its
# modules' closure sets on to its dependents (in PerModuleClosures), so no
# target ever has to list a whole closure itself.
def _interfaces(files: HaskellModuleFiles):
    return [files.hi, files.abi] + ([files.dyn_hi] if files.dyn_hi != None else [])

_ModuleClosureTSet = transitive_set(args_projections = {"interfaces": _interfaces})

# The provider that a per-module target's dynamic output returns: the
# closure set of each of the target's modules, keyed by node name (see
# _nodes).
PerModuleClosures = provider(fields = {"by_module": provider_field(dict)})

# The package db flags for a per-module compile, and the inputs that go
# with them. `libs` are all of the target's dependencies, direct and
# transitive.
#
# A per-module compile never uses the library file of a dependency that
# this build makes. Library files are only needed to run splices, and
# splices may only run code of prebuilt packages (see Note [Template Haskell
# modules]). So each kind of dependency is given by a different package db:
#
# - A dependency compiled per-module: its early db. This adds no inputs,
#   because each module's compile adds the particular interfaces it imports
#   itself.
# - A dependency built with --make: its library-less db, with the library's
#   interface directories as inputs.
# - A prebuilt dependency: its normal db, with its interface directories as
#   inputs. For a module that runs Template Haskell (`runs_th`), its library
#   files are inputs too, because GHC's interpreter loads them.
#
# `below_make` names the dependencies compiled per-module that some
# dependency built with --make depends on. Their whole interface
# directories are inputs as well: see Note [Compiling against dependencies
# module by module]. `import_dirs_tag` tags all the interface inputs, so
# that a compile's dep file can list the ones it read.
#
# As well as the flags, the result has `local_import_dirs`, the interface
# directories of the --make dependencies with their library names, and
# `early_names`, the names of the dependencies compiled per-module. The
# compile tool needs both to find the interfaces that its dep file lists.
def _package_dbs(libs: list, below_make: dict[str, bool], import_dirs_tag, runs_th: bool):
    packagedb_args = cmd_args()
    packagedb_set = {}
    local_import_dirs = []
    early_names = {}
    for lib in libs:
        if lib.modules != None:
            packagedb_set[lib.early_db] = None
            early_names[lib.name] = True
            if lib.name in below_make:
                # A library built with --make depends on this one, and its
                # interfaces refer to this one's: see Note [Compiling against
                # dependencies module by module].
                packagedb_args.add(import_dirs_tag.tag_artifacts(cmd_args(hidden = list(lib.import_dirs.values()))))
            continue
        packagedb_set[lib.early_db if lib.early_db != None else lib.db] = None
        import_dirs = list(lib.import_dirs.values())
        local_import_dirs += [(lib.name, d) for d in import_dirs if not d.is_source]
        # The interfaces are tagged, so that a compile's dep file can list
        # the ones it read. The libraries that a Template Haskell module
        # loads never appear in the dep file (see Note [Template Haskell
        # modules]), so they are plain inputs, and any change to one
        # compiles the module again.
        packagedb_args.add(cmd_args(hidden = [
            lib.stub_dirs,
            import_dirs_tag.tag_artifacts(cmd_args(hidden = import_dirs)),
            lib.libs if runs_th and lib.is_prebuilt else [],
        ]))

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])
    return struct(packagedb_args = packagedb_args, local_import_dirs = local_import_dirs, early_names = early_names)

# The suffix that marks a boot source or interface (.hs-boot or
# .hi-boot). A boot file's node name (its key in srcs) is
# "<module>-boot".
_BOOT = "-boot"

def _is_boot(node: str) -> bool:
    return node.endswith(_BOOT)

def _module_of(node: str) -> str:
    return node[:-len(_BOOT)] if _is_boot(node) else node

# The path of a node's output file with the given extension, relative to
# the output directory. For example, with ext = "dyn_hi", it is
# Foo/Bar.dyn_hi for the module Foo.Bar, and Foo/Bar.dyn_hi-boot for its
# boot file.
def _node_file(node: str, ext: str) -> str:
    return module_name_to_file(_module_of(node), ext + (_BOOT if _is_boot(node) else ""))

# The directory, relative to the target's outputs, that holds everything a
# per-module compile of the target writes for one combination of link style
# and profiling (static, shared, profiled and so on). The modules' own
# outputs are in a subdirectory of it (see per_module_out_dir).
def per_module_dir(link_style: LinkStyle, enable_profiling: bool) -> str:
    return "per-module-" + get_artifact_suffix(link_style, enable_profiling) + "/"

# The directory, relative to the target's outputs, where the target's
# modules write their objects and interfaces, for one combination of link
# style and profiling. Every module's compile has it on its import path, and
# it is the import directory of the target's early package db, which is how
# dependents find the interfaces there too.
#
# It is named after the target's set of modules. buck2 doesn't delete the
# outputs of an action that no longer exists, so if a module moved to another
# target, GHC would still find its old interface here. A new set of modules
# gets a fresh directory instead. The cost is that adding, removing or
# renaming a module compiles the whole target again.
def per_module_out_dir(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool) -> str:
    names = " ".join(sorted([n for n, _ in _nodes(ctx)]))
    return per_module_dir(link_style, enable_profiling) + "out-" + str(hash(names) & 0xffffffff)

# The directory to give GHC as an import or output directory, worked out
# from one node's output file in it. `artifact` is the node's file with
# extension `ext`, and the result is the directory above the module's own
# path: for the module Foo.Bar, whose interface is <dir>/Foo/Bar.hi, the
# result is <dir>.
def _dir_of(artifact, node: str, ext: str) -> cmd_args:
    return cmd_args(artifact, parent = _node_file(node, ext).count("/") + 1)

# Read the module graph that the deps tool wrote (see
# tools/ghc-api/PerModuleDeps.hs). It returns three things:
#
# - imports: for each node, the nodes of this target that it imports.
# - upstream: for each node, the modules it imports from dependencies
#   compiled per-module, as (package id, module name) pairs. Imports from
#   other dependencies are left out, since those aren't tracked module by
#   module.
# - th: the nodes that may run Template Haskell.
def _read_deps(label, deps: dict, nodes: list, module_libs: dict):
    imports = {n: [] for n, _ in nodes}
    upstream = {n: [] for n, _ in nodes}
    th = {}
    for n, d in deps.items():
        if n not in imports:
            fail("{}: GHC's dependency analysis found {}, but srcs has no such module (or boot file)".format(label, n))
        imports[n] = d["imports"]
        for pkg, mod in d["external"]:
            lib = module_libs.get(pkg)
            if lib != None and mod in lib.modules and (pkg, mod) not in upstream[n]:
                upstream[n].append((pkg, mod))
        if d["th"]:
            th[n] = True
    return imports, upstream, th

# For each node, all the nodes of this target that it imports directly or
# indirectly, with its direct imports first. `order` must be a dependency
# order (each node after the nodes it imports), so that an import's closure
# has already been computed when its importers need it.
def _transitive_closure(order: list[str], imports: dict) -> dict:
    closure = {}
    for n in order:
        c = {d: True for d in imports[n]}
        for d in imports[n]:
            for x in closure[d]:
                c[x] = True
        closure[n] = list(c)
    return closure

# Sort the nodes into dependency order, so that each node comes after the
# nodes it imports. It returns the sorted nodes, and the nodes that couldn't
# be sorted because they are in an import cycle or import something that
# is.
#
# This is Kahn's algorithm. Starlark has no while loop, so instead of a work
# queue we iterate over `order` while appending to it, so it's linear in the
# size of the graph.
def _dependency_order(nodes: list, imports: dict) -> (list[str], list[str]):
    importers = {n: [] for n, _ in nodes}
    waiting = {}
    for n, _ in nodes:
        waiting[n] = len(imports[n])
        for d in imports[n]:
            importers[d].append(n)
    order = [n for n, _ in nodes if waiting[n] == 0]
    for i in range(len(nodes)):
        if i >= len(order):
            break
        for m in importers[order[i]]:
            waiting[m] -= 1
            if waiting[m] == 0:
                order.append(m)
    done = {n: True for n in order}
    return order, [n for n, _ in nodes if n not in done]

# The nodes of the target's module graph, as (node name, source) pairs. A
# module's node name is the module's name, and a boot file's is
# "<module>-boot". When srcs is a dict, a boot file's key is already
# "<module>-boot". When it is a list, srcs_to_pairs names a boot file after
# its module, so "-boot" is added here.
def _nodes(ctx: AnalysisContext) -> list:
    nodes = []
    for name, src in srcs_to_pairs(ctx.attrs.srcs):
        if is_haskell_src(src):
            nodes.append((name, src))
        elif src.short_path.endswith(_BOOT):
            nodes.append((name if _is_boot(name) else name + _BOOT, src))
    return nodes

# Declare each node's output files, all in the target's output directory
# (see per_module_out_dir). They are at fixed paths rather than
# content-based ones, so that GHC can find a module's interface from the
# module's name.
#
# They are declared here, before the module graph is known, rather than in
# the dynamic output that registers the compiles. That way the target can
# give them to its dependents directly (in HaskellModuleFiles), and not only
# through the objects and hi directories that the dynamic output builds.
def _declare_module_outputs(ctx: AnalysisContext, out_dir: str, nodes: list, osuf: str, hisuf: str, dynamic_too: bool):
    def declare(n, ext):
        return ctx.actions.declare_output(out_dir + "/" + _node_file(n, ext), has_content_based_path = False)

    return struct(
        o = {n: declare(n, osuf) for n, _ in nodes},
        hi = {n: declare(n, hisuf) for n, _ in nodes},
        abi = {n: declare(n, "abi") for n, _ in nodes},
        dyn_o = {n: declare(n, "dyn_o") for n, _ in nodes} if dynamic_too else {},
        dyn_hi = {n: declare(n, "dyn_hi") for n, _ in nodes} if dynamic_too else {},
    )

# The dynamic output of a per-module compile. It runs once the deps tool has
# written the module graph. It registers a compile action for each node,
# builds the target's objects and hi directories from their outputs, and
# returns each module's closure set for the target's dependents (see
# _ModuleClosureTSet). `s` carries the values that compile_per_module worked
# out during analysis.
def _register_modules_impl(actions: AnalysisActions, s: typing.Any, deps: ArtifactValue, dep_closures: dict, artifacts: list[Artifact], outputs: list[OutputArtifact]) -> list[Provider]:
    out = {a: o for a, o in zip(artifacts, outputs)}
    nodes = s.nodes
    src_of = s.src_of
    modules = s.modules
    module_libs = s.module_libs
    module_lib_dirs = s.module_lib_dirs
    early_set = s.early_set
    th_set = s.th_set
    dynamic_too = s.dynamic_too
    o_of = s.o_of
    hi_of = s.hi_of
    abi_of = s.abi_of
    dyn_o_of = s.dyn_o_of
    dyn_hi_of = s.dyn_hi_of
    objects = s.objects
    hi = s.hi
    stubs = s.stubs
    prefix = s.prefix
    suffix = s.suffix
    osuf = s.osuf
    hisuf = s.hisuf
    tag = s.tag
    producing_indices = s.producing_indices
    base_cmd = s.base_cmd
    env = s.env
    compile_script = s.compile_script

    imports, upstream, th_nodes = _read_deps(s.label, deps.read_json(), nodes, module_libs)
    order, left = _dependency_order(nodes, imports)
    if left:
        fail("{}: import cycle among {}".format(s.label, ", ".join(left)))
    closure = _transitive_closure(order, imports)

    # Make two transitive sets for each node, in dependency order:
    #
    # - closure_sets[n] is the node's closure set, for the target's
    #   dependents. It includes the node's own files.
    # - upstream_closure_sets[n] holds the interfaces from dependencies
    #   compiled per-module that the node's compile may read: the closure
    #   sets of the modules that the node imports from those dependencies,
    #   or that anything it imports from this target does. It doesn't
    #   include this target's own interfaces, which are added separately
    #   below.
    dep_closure_sets = {name: dv.providers[PerModuleClosures].by_module for name, dv in dep_closures.items()}
    closure_sets = {}
    upstream_closure_sets = {}
    for n in order:
        ups = [dep_closure_sets[pkg][mod] for pkg, mod in upstream[n] if mod in dep_closure_sets.get(pkg, {})]
        upstream_closure_sets[n] = actions.tset(_ModuleClosureTSet, children = [upstream_closure_sets[i] for i in imports[n]] + ups)
        closure_sets[n] = actions.tset(_ModuleClosureTSet, value = modules[n], children = [closure_sets[i] for i in imports[n]] + ups)

    runs_th = {n: n in th_nodes for n, _ in nodes}

    # Register the compiles in dependency order. An action's inputs, and the
    # artifacts that a symlinked_dir links to, must be outputs of actions
    # that have already been registered.
    hie_of = {}
    for n in order:
        # The module finds the interfaces it imports from this target in
        # the target's output directory, which all the target's modules
        # share, and which is on the module's import path. The interface
        # files of the module's closure are tagged inputs, so the module
        # waits for exactly those, and its dep file can list them. (Giving
        # each module a symlink tree of just its own closure was tried, but
        # the trees took longer to materialise than the compiles
        # themselves.)
        closure_files = []
        for d in closure[n]:
            closure_files += [hi_of[d], abi_of[d]]
            if dynamic_too:
                closure_files.append(dyn_hi_of[d])
        mod_packages = th_set if runs_th[n] else early_set
        hidirs = mod_packages.local_import_dirs + [(name, d) for name, d in module_lib_dirs.items() if name in mod_packages.early_names]

        # The flags specific to this module: its source and output files.
        # They go after the flags that all the target's modules share.
        stubdir = actions.declare_output(prefix + "stubs/" + n, dir = True, has_content_based_path = False)
        module_flags = cmd_args("-c", src_of[n], "-o", out[o_of[n]], "-ohi", out[hi_of[n]], "-stubdir", stubdir.as_output())
        mkdirs = [stubdir.as_output()]
        if closure[n]:
            module_flags.add(tag.tag_artifacts(cmd_args(_dir_of(hi_of[closure[n][0]], closure[n][0], hisuf), hidden = closure_files, format = "-i{}")))
        # The interfaces it may read from dependencies compiled per-module.
        module_flags.add(tag.tag_artifacts(cmd_args(hidden = upstream_closure_sets[n].project_as_args("interfaces"))))
        if dynamic_too:
            module_flags.add("-dyno", out[dyn_o_of[n]], "-dynohi", out[dyn_hi_of[n]])
        if producing_indices:
            # The module's .hie file. GHC writes it under -hiedir, at a path
            # made from the module's name. It goes in the target's hi
            # directory, which is also the target's index, as with --make.
            hie_of[n] = actions.declare_output(prefix + "hie/" + n + "/" + _node_file(n, "hie"), has_content_based_path = False)
            module_flags.add("-hiedir", _dir_of(hie_of[n].as_output(), n, "hie"))

        # The arguments of the compile tool, which wraps GHC (see Request.hs
        # in tools/ghc-api for what each one means).
        depfile = actions.declare_output(prefix + "dep/" + n + ".dep", has_content_based_path = False)
        request = cmd_args(
            "--depfile",
            tag.tag_artifacts(depfile.as_output()),
            "--abi",
            out[abi_of[n]],
            "--module",
            _module_of(n).replace(".", "/"),
            "--outdir",
            _dir_of(out[hi_of[n]], n, hisuf),
            "--hisuf",
            hisuf,
            # Where each dependency's interfaces are, so that the tool can
            # turn the usages GHC records into dep file entries. These are
            # paths only, not inputs. The interfaces themselves are inputs
            # already: through upstream_closure_sets, and, for --make
            # libraries, through the package db flags. For a dependency
            # compiled per-module, the path is worked out from one of its
            # interface files, so as an input it would make the module wait
            # for that particular interface for no reason.
            [cmd_args(d, format = "--hidir=" + unit + "={}", ignore_artifacts = True) for unit, d in hidirs],
            cmd_args(mkdirs, format = "--mkdir={}"),
            "--",
            base_cmd,
            mod_packages.args,
            "--",
            module_flags,
        )
        actions.run(
            in_env(env, cmd_args(compile_script, request)),
            category = "haskell_compile_module_" + suffix.replace("-", "_"),
            identifier = n,
            dep_files = {"hs": tag},
        )

    obj_map = {}
    hi_map = {}
    for n, _ in nodes:
        obj_map[_node_file(n, osuf)] = o_of[n]
        hi_map[_node_file(n, hisuf)] = hi_of[n]
        hi_map[_node_file(n, "abi")] = abi_of[n]
        if n in hie_of:
            hi_map[_node_file(n, "hie")] = hie_of[n]
        if dynamic_too:
            obj_map[_node_file(n, "dyn_o")] = dyn_o_of[n]
            hi_map[_node_file(n, "dyn_hi")] = dyn_hi_of[n]
    actions.symlinked_dir(out[objects], obj_map, has_content_based_path = False)
    actions.symlinked_dir(out[hi], hi_map, has_content_based_path = False)
    # The target's stubs directory is left empty. Each module writes its
    # stub headers (the _stub.h files of its foreign exports) to a directory
    # of its own instead. Nothing looks inside a target's stubs directory:
    # with --make too, it is only ever an input of other actions, so an
    # empty one is enough.
    actions.symlinked_dir(out[stubs], {}, has_content_based_path = False)
    return [PerModuleClosures(by_module = closure_sets)]

_register_modules = dynamic_actions(
    impl = _register_modules_impl,
    attrs = {
        "artifacts": dynattrs.value(list[Artifact]),
        "dep_closures": dynattrs.dict(str, dynattrs.dynamic_value()),
        "deps": dynattrs.artifact_value(),
        "outputs": dynattrs.list(dynattrs.output()),
        "s": dynattrs.value(typing.Any),
    },
)

# Whether the target is compiled per-module: it has per_module = True, and at
# least one Haskell module. A target without any modules always goes through
# compile(), which produces the empty outputs that such a target needs.
def compiles_per_module(ctx: AnalysisContext) -> bool:
    return getattr(ctx.attrs, "per_module", False) and has_modules(ctx)

# Compile the target's sources with one action per module (see Note
# [Per-module compilation]). It takes the same arguments as compile(), so
# that the two are interchangeable, but ignores native_shared_libs_dir and
# dynamic_from. Those are only needed for splices that run code of this
# build's own libraries, which per-module compilation doesn't support (see
# Note [Template Haskell modules]).
def compile_per_module(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None = None, native_shared_libs_dir: [Artifact, None] = None, dynamic_too: bool = False, dynamic_from: [CompileResultInfo, None] = None) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    suffix = get_artifact_suffix(link_style, enable_profiling)
    osuf, hisuf = output_extensions(link_style, enable_profiling)
    prefix = per_module_dir(link_style, enable_profiling)

    # The tag of every input a module's dep file may list: see Note [Early
    # cut-off by dep files].
    tag = ctx.actions.artifact_tag()

    # Two sets of package flags (see _package_dbs): one for the modules that
    # run no Template Haskell, and one for the modules that do. The second
    # also has the prebuilt libraries as inputs, because GHC's interpreter
    # loads them.
    dep_libs = list(dependency_libs(ctx, link_style, enable_profiling).traverse())
    exposed_package_args = get_exposed_package_args(ctx, link_style, False, enable_profiling)

    # The dependencies compiled per-module that some dependency built with
    # --make depends on, found through the --make libraries' `below` sets
    # (see Note [Compiling against dependencies module by module]).
    below = ctx.actions.tset(HaskellLibraryInfoTSet, children = [lib.below for lib in dep_libs if lib.below != None])
    below_make = {lib.name: True for lib in below.traverse() if lib.modules != None}

    def packages(runs_th):
        dbs = _package_dbs(dep_libs, below_make, tag, runs_th)
        return struct(
            args = cmd_args(exposed_package_args, dbs.packagedb_args),
            local_import_dirs = dbs.local_import_dirs,
            early_names = dbs.early_names,
        )

    early_set = packages(runs_th = False)
    th_set = packages(runs_th = True)

    module_libs = {lib.name: lib for lib in dep_libs if lib.modules != None}
    this_pkg = pkgname or haskell_library_unit_id(ctx.label)

    # Every module is compiled with -this-unit-id. A library's unit is the
    # `pkgname` it is registered under. A binary's is made from the target's
    # label, rather than GHC's default of `main`, which every binary would
    # otherwise share.
    cmd_flags, file_flags = ghc_flags(ctx, link_style, enable_profiling, this_pkg, dynamic_too)
    # The target's other sources, such as headers that a module #includes.
    # GHC doesn't record which of these a module used, so they can't go in
    # the dep file. Instead, every module's compile has all of them as plain
    # inputs, as the --make compile does.
    other_srcs = [src for _, src in srcs_to_pairs(ctx.attrs.srcs) if not is_haskell_src(src) and not src.short_path.endswith(_BOOT)]
    ghc_args = cmd_args(cmd_flags, file_flags, hidden = other_srcs)
    base_cmd = cmd_args(haskell_toolchain.compiler, ghc_args)
    env = ghc_env(ctx, prefix + "build-tool-depends")

    nodes = _nodes(ctx)
    src_of = {n: src for n, src in nodes}

    out_dir = per_module_out_dir(ctx, link_style, enable_profiling)
    module_outputs = _declare_module_outputs(ctx, out_dir, nodes, osuf, hisuf, dynamic_too)
    o_of = module_outputs.o
    hi_of = module_outputs.hi
    abi_of = module_outputs.abi
    dyn_o_of = module_outputs.dyn_o
    dyn_hi_of = module_outputs.dyn_hi
    objects = ctx.actions.declare_output("objects-" + suffix, dir = True, has_content_based_path = False)
    hi = ctx.actions.declare_output("hi-" + suffix, dir = True, has_content_based_path = False)
    stubs = ctx.actions.declare_output("stubs-" + suffix, dir = True, has_content_based_path = False)
    producing_indices = get_producing_indices(ctx)

    # Work out the module graph with GHC's own dependency analysis, which the
    # deps tool runs (see tools/ghc-api/PerModuleDeps.hs). For each node, it
    # finds the imports, both from this target and from dependencies, and
    # whether the node may run Template Haskell. It runs against the early
    # dbs, so it doesn't wait for any dependency compiled per-module. (It
    # does wait for dependencies built with --make, whose interfaces are
    # inputs of their package dbs.) The tool is given each node with its
    # source, and the GHC flags without the compiler itself, because it runs
    # GHC's analysis in-process.
    deps = ctx.actions.declare_output(prefix + "deps.json")
    ctx.actions.run(
        in_env(env, cmd_args(
            haskell_toolchain.per_module_deps or ctx.attrs._per_module_deps[RunInfo],
            deps.as_output(),
            [cmd_args(n, src, delimiter = "=") for n, src in nodes],
            "--",
            ghc_args,
            early_set.args,
        )),
        category = "haskell_deps_" + suffix.replace("-", "_"),
    )

    # The output directory of each dependency compiled per-module, where the
    # compile tool looks up its interfaces. It is worked out from the
    # interface of the dependency's first module. Every such dependency has
    # at least one module, since a target without any goes through compile()
    # instead (see compiles_per_module).
    def out_dir_of(lib):
        m, files = list(lib.modules.items())[0]
        return _dir_of(files.hi, m, hisuf)

    module_lib_dirs = {name: out_dir_of(lib) for name, lib in module_libs.items()}

    modules = {
        n: HaskellModuleFiles(hi = hi_of[n], abi = abi_of[n], dyn_hi = dyn_hi_of[n] if dynamic_too else None)
        for n, _ in nodes
    }
    all_outputs = [objects, hi, stubs]
    for files in [o_of, hi_of, abi_of, dyn_o_of, dyn_hi_of]:
        all_outputs += files.values()
    closures = ctx.actions.dynamic_output_new(_register_modules(
        s = struct(
            label = ctx.label,
            compile_script = haskell_toolchain.per_module_compile or ctx.attrs._per_module_compile[RunInfo],
            nodes = nodes,
            src_of = src_of,
            modules = modules,
            module_libs = module_libs,
            module_lib_dirs = module_lib_dirs,
            early_set = early_set,
            th_set = th_set,
            dynamic_too = dynamic_too,
            o_of = o_of,
            hi_of = hi_of,
            abi_of = abi_of,
            dyn_o_of = dyn_o_of,
            dyn_hi_of = dyn_hi_of,
            objects = objects,
            hi = hi,
            stubs = stubs,
            prefix = prefix,
            suffix = suffix,
            osuf = osuf,
            hisuf = hisuf,
            tag = tag,
            producing_indices = producing_indices,
            base_cmd = base_cmd,
            env = env,
        ),
        deps = deps,
        dep_closures = {lib.name: lib.closures for lib in module_libs.values()},
        artifacts = all_outputs,
        outputs = [a.as_output() for a in all_outputs],
    ))
    return CompileResultInfo(objects = objects, hi = hi, stubs = stubs, producing_indices = producing_indices, modules = modules, closures = closures)

# Note [Per-module compilation]
#
# Normally a target is compiled by one `ghc --make` action. With
# `per_module = True`, it is compiled by one `ghc -c` action per module
# instead. buck2 can then:
#
# - run the target's modules in parallel with everything else in the build;
# - start each module as soon as the modules it imports are compiled, even
#   those of other targets, rather than waiting for whole targets;
# - after an edit, run again only the modules affected.
#
# The price is CPU. Each `ghc -c` reads the interfaces of everything its
# module imports (and, for Template Haskell, loads the prebuilt libraries),
# which `ghc --make` does only once per target.
#
# Terms
#
# - Node: a module, or a module's boot file (.hs-boot). Each node has an
#   action of its own; a boot file's comes from the "<module>-boot" entry of
#   srcs (see _nodes). The modules that import a boot file with
#   {-# SOURCE #-} depend on it, and so does the module itself, since GHC
#   checks that the two agree.
# - Module graph: the target's nodes and their imports, from GHC's own
#   dependency analysis of all of its sources, in one action (the deps tool,
#   tools/ghc-api/PerModuleDeps.hs). This action needs only the
#   sources and the package dbs, not any compiled dependency, and runs again
#   whenever a source changes. A dynamic_output reads the graph and
#   registers the nodes' actions.
# - Closure: everything a module imports, directly or indirectly, from the
#   targets compiled per-module. A compile needs the interfaces of its whole
#   closure, since GHC reads them for instances and type families.
#   Dependencies that are prebuilt or built with `ghc --make` aren't part of
#   closures: a compile gets their modules whole, through their normal
#   package dbs.
# - Output directory: where all of a target's modules write their objects
#   and interfaces. It is on the import path of every compile of the
#   target. Its files are at fixed paths rather than content-based ones, so
#   that GHC can find them by module name. A target has one output
#   directory for each way it is compiled in (static, shared, profiled),
#   named after its set of modules (see per_module_out_dir). The objects
#   and hi directories that the rest of the rules use are built from the
#   output directories with symlinked_dir.
# - Early and final package db: a dependency compiled per-module is
#   registered twice. Its "early" db names no library, and its interfaces
#   appear one by one as its modules compile. Its "final" db is the normal
#   one, registered once its library is linked. See Note [Compiling against
#   dependencies module by module]. A dependency built with --make also has
#   a "library-less" db, the final db without the library, which is the one
#   a per-module compile uses (see Note [Template Haskell modules]).
# - Template Haskell module: one that runs a splice, or evaluates an ANN
#   pragma (GHC uses its interpreter for those too). With per_module, its
#   splices can only run code of prebuilt packages. See Note [Template
#   Haskell modules].
# - Dep file: the list of the inputs an action actually read, which buck2
#   uses to decide whether to run the action again. See Note [Early cut-off
#   by dep files].
#
# The other Notes, in reading order
#
# - Note [Compiling against dependencies module by module]: how a module
#   can compile before its dependencies are finished.
# - Note [Early cut-off by dep files]: which modules compile again after an
#   edit.
# - Note [Template Haskell modules]: what code the modules that run code at
#   compile time can run.

# Note [Compiling against dependencies module by module]
#
# 1. The problem
#
# Say module X of target T imports module Y of dependency D, and X runs no
# Template Haskell (for those, see Note [Template Haskell modules]). X needs
# the interfaces of Y and of Y's closure. It doesn't need the rest of D: not
# D's other interfaces, and not D's library. So X should be able to start as
# soon as Y and its closure are compiled, however much of D is left.
#
# But GHC finds D's interfaces through D's package db, and a normal package
# db is only registered once D's library is built.
#
# 2. The solution
#
# A dependency compiled per-module also has an "early" package db (see the
# `early_db` field of HaskellLibraryInfo). It is registered before
# anything is compiled, names no library, and has D's output directory as
# its import directory, which fills up as D's modules compile. X compiles
# against D's early db, and depends on just the interface files it needs.
# (D's final db, registered once its library is linked, is the normal one
# that `ghc --make` would use.)
#
# Two things tell us which interface files X needs:
#
# - X's own imports from dependencies come from GHC's dependency analysis,
#   which finds each imported module in the package dbs, before its
#   interface exists, and says which dependency (unit) it belongs to.
# - Their closures come from the dependencies themselves. Each per-module
#   target's dynamic output makes a closure set for each of its modules (a
#   transitive set of the interfaces of its closure), and passes them on to
#   its dependents (_ModuleClosureTSet). A compile's inputs are a projection
#   of its imports' closure sets, so no target lists a whole closure.
#
# A dependency built with --make breaks that chain. Say library M is built
# with --make, and imports module Y of D, which is compiled per-module. When
# GHC reads one of M's interfaces, it may need Y's too, because M's
# interfaces refer to things defined in Y. But M has no closure sets, so
# nothing tells a module that imports M that it needs Y's interface.
#
# To cover this, each library built with --make records the libraries it
# depends on, in the `below` field of HaskellLibraryInfo. A per-module
# compile collects these, picks out the libraries compiled per-module
# (below_make), and gives every one of its modules their whole interface
# directories as tagged inputs. That doesn't make anything wait longer than
# it already does. Every module of the target already waits for M's
# interfaces, and M, being built with --make, can't be compiled until all of
# D has been.

# Note [Early cut-off by dep files]
#
# 1. The problem
#
# After an edit, a module should compile again only if one of the modules
# it imports changed its ABI. (GHC's own recompilation check goes further:
# it also looks at which of the imported module's entities the module
# uses.) Comparing the imported modules' interface files isn't enough: an
# interface includes a hash of its source, so even a comment-only edit
# changes it.
#
# 2. The solution
#
# buck2 decides this for each action, from a dep file. Every file a module's
# compile might read from other compiles, the interfaces, is a tagged input.
# (Its own source is an ordinary input, so editing it always compiles it
# again.) After the compile, the action lists the tagged inputs it actually
# read. On the next build, buck2 runs the action again only if one of those
# has changed.
#
# The list comes from the usages GHC records in the new interface, which are
# also what GHC's own recompilation check reads:
#
# - For each imported module, its .abi file, which holds just the
#   interface's ABI hash. Each action writes one next to its interface, from
#   the interface itself (DepFile in tools/ghc-api).
# - Each file a Template Haskell splice read, which GHC records as a
#   dependent file (addDependentFile). (The libraries the splices loaded are
#   plain inputs instead: see Note [Template Haskell modules].)
#
# 3. buck2 decides, not GHC
#
# buck2 removes an action's previous outputs before running it, so GHC's
# recompilation check never has anything to compare against, and the module
# compiles whenever the action runs. (GHC's check would also notice a change
# to the code a splice ran, from the hash it records of each Haskell library
# the splice loaded. Here those are prebuilt libraries, which are plain
# inputs of the compile.)
#
# 4. Coarser than GHC's check
#
# The dep file names a whole imported module's ABI. So a module that imports
# `A (f)` compiles again when A gains an export, or when A's g changes,
# though GHC's check would know that neither matters to it. The cascade
# usually stops there: the module's _own_ ABI comes out the same, so its
# importers don't compile again.
#
# GHC's interface has what we'd need for a finer cut-off: the hash of the
# export list, and of each entity the module used. A module's compile could
# write those as separate files (a directory per module), and its importers'
# dep files would list only the ones they used.

# Note [Template Haskell modules]
#
# 1. The problem
#
# A Template Haskell module runs code at compile time, in its splices and
# ANN pragmas. GHC runs it in its interpreter, which first loads the library
# of every package on the command line (GHC's "preload" units), and then the
# objects of any of the target's own modules that a splice runs. But a
# dependency's library only exists once all of its modules are compiled and
# linked, so a module that needed it would wait for the whole dependency,
# losing much of what compiling per-module gains. And to load a library
# that this build makes, the interpreter would need the libraries it
# depends on in a directory on its LD_LIBRARY_PATH.
#
# 2. The solution: splices run only prebuilt code
#
# With per_module, a splice can only run code of prebuilt packages, whose
# libraries exist before the build starts and can find their own
# dependencies. Every local dependency of a per-module compile is on a db
# that names no library: its early db if it's compiled per-module, or its
# library-less db if it's built with --make (see _package_dbs). So a
# Template Haskell module waits for nothing that a plain module doesn't, and
# needs nothing on its LD_LIBRARY_PATH. The prebuilt libraries are plain
# inputs of its compile, so a change to one compiles it again.
#
# A target whose splices run code of another local library has to be built
# with per_module = False. With per_module, such a splice can't load that
# code, so its compile fails, naming the missing symbol, and the compile
# tool says how to fix it.
#
# Nor can a splice run code of the target's own modules: their objects, and
# those of the modules behind any boot files among them, would have to be
# inputs of the compile. GHC can still find an object that another module's
# compile left in the output directory, though. So the compile tool fails
# the compile if a splice loaded one, which GHC records as a dependent file.
#
# 3. Finding the Template Haskell modules
#
# Which modules run Template Haskell has to be decided before anything is
# compiled. The deps tool asks GHC which extensions each module has, from its
# pragmas and the target's flags, and looks for ANN pragmas in its
# (preprocessed) source. That can find too much (an ANN pragma in a comment,
# say), but it's better to be conservative. It doesn't catch GHC plugins.
