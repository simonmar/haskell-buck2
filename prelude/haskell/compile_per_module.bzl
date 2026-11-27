# Per-module compilation (`compile_granularity = "module"`): one `ghc -c`
# action per module instead of one `ghc --make` action per target. See the
# Notes at the end of this file, starting with Note [Per-module compilation].

load(
    "@prelude//haskell:compile.bzl",
    "CompileResultInfo",
    "data_dirs_env",
    "dependency_libs",
    "get_exposed_package_args",
    "get_producing_indices",
    "build_tools",
    "compile_data_dirs",
    "ghc_env",
    "ghc_flags",
    "has_modules",
    "in_env",
    "native_libs_tree",
    "splice_dep_infos",
    "splice_libraries",
    "splice_objects_kind",
    "tools_env",
    "uses_library_less_db",
)
load("@prelude//linking:shared_libraries.bzl", "EMPTY_SHARED_LIBRARY_INFO", "SharedLibraryInfo")
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
    "attr_deps",
    "variant_name",
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
# transitive. See Note [Libraries of the early package dbs].
#
# A prebuilt dependency, or a local one named in `final`, is on its final
# db, with its interface directories as inputs. Every other local
# dependency is on a db that names no library, so that the compile doesn't
# wait for its library to be built:
#
# - A dependency compiled per-module: its early db. This adds no inputs,
#   because each module's compile adds the particular interfaces it imports
#   itself.
# - A dependency built with --make: its library-less db, with the library's
#   interface directories as inputs.
#
# A module that runs Template Haskell (`runs_th`) also has the libraries of
# its final dbs as inputs, because GHC's interpreter loads them. The trees of
# the native libraries that those libraries depend on are in the result's
# `native_libs`, for the module's LD_LIBRARY_PATH.
# `below_make` names the dependencies compiled per-module that some
# dependency built with --make depends on. Their whole interface
# directories are inputs as well: see Note [Compiling against dependencies
# module by module]. `import_dirs_tag` tags all the interface inputs, so
# that a compile's dep file can list the ones it read.
#
# As well as the flags, the result has `local_import_dirs`, the interface
# directories of the --make dependencies with their library names, and
# `early_names`, the names of the dependencies on their early dbs. The
# compile tool needs both to find the interfaces that its dep file lists.
def _package_dbs(libs: list, final: set[str], below_make: set[str], import_dirs_tag, runs_th: bool):
    packagedb_args = cmd_args()
    packagedb_set = set()
    local_import_dirs = []
    early_names = set()
    native_libs = []
    for lib in libs:
        library_less = uses_library_less_db(lib, final)
        if library_less and lib.modules != None:
            packagedb_set.add(lib.early_db)
            early_names.add(lib.name)
            if lib.name in below_make:
                # A library built with --make depends on this one, and its
                # interfaces refer to this one's: see Note [Compiling against
                # dependencies module by module].
                packagedb_args.add(import_dirs_tag.tag_artifacts(cmd_args(hidden = lib.import_dirs)))
            continue
        packagedb_set.add(lib.early_db if library_less else lib.db)
        import_dirs = lib.import_dirs
        local_import_dirs += [(lib.name, d) for d in import_dirs if not d.is_source]
        # The interfaces are tagged, so that a compile's dep file can list
        # the ones it read. The libraries that a Template Haskell module
        # loads never appear in the dep file (see Note [Template Haskell
        # modules]), so they are plain inputs, and any change to one
        # compiles the module again. A module that runs no Template Haskell
        # loads none, so it doesn't wait for them to be linked.
        loads = runs_th and not library_less
        packagedb_args.add(cmd_args(hidden = [
            lib.stub_dirs,
            import_dirs_tag.tag_artifacts(cmd_args(hidden = import_dirs)),
            lib.libs if loads else [],
        ]))
        if loads:
            native_libs.append(lib.native_libs)

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])
    return struct(packagedb_args = packagedb_args, local_import_dirs = local_import_dirs, early_names = early_names, native_libs = native_libs)

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
    return "per-module-" + variant_name(link_style, enable_profiling) + "/"

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
# tools/ghc-api/PerModuleDeps.hs). It returns:
#
# - imports: for each node, the nodes of this target that it imports.
# - upstream: for each node, the modules it imports from dependencies
#   compiled per-module, as (package id, module name) pairs. Imports from
#   other dependencies are left out, since those aren't tracked module by
#   module.
# - th: the nodes that may run Template Haskell, with why (the deps tool's
#   "th_reason").
# - programs: for each node, the programs that GHC runs for it and finds on
#   PATH, by name, such as a preprocessor that -F -pgmF names.
# - splice_imports: for each node with explicit level imports, the modules
#   it imports at the splice level, as (library name, module) pairs. The
#   library is that of a dependency that the import comes through, which for
#   a re-exported module is the dependency that re-exports it.
#
# `prebuilt_names` maps the unit id of each prebuilt dependency to its name.
def _read_deps(label, deps: dict, nodes: list, module_libs: dict, prebuilt_names: dict[str, str]):
    imports = {n: [] for n, _ in nodes}
    upstream = {n: [] for n, _ in nodes}
    th = {}
    programs = {n: [] for n, _ in nodes}
    splice_imports = {}
    for n, d in deps.items():
        if n not in imports:
            fail("{}: GHC's dependency analysis found {}, but srcs has no such module (or boot file)".format(label, n))
        imports[n] = d["imports"]
        for pkg, mod in d["external"]:
            lib = module_libs.get(pkg)
            if lib != None and mod in lib.modules and (pkg, mod) not in upstream[n]:
                upstream[n].append((pkg, mod))
        if d["th"]:
            th[n] = d.get("th_reason", "module")
        programs[n] = d["programs"]
        if "splice" in d:
            splice_imports[n] = [(prebuilt_names.get(pkg, pkg), mod) for pkg, mod in d["splice"]]
    return imports, upstream, th, splice_imports, programs

# For each node, all the nodes of this target that it imports directly or
# indirectly, with its direct imports first. `order` must be a dependency
# order (each node after the nodes it imports), so that an import's closure
# has already been computed when its importers need it.
def _transitive_closure(order: list[str], imports: dict) -> dict:
    closure = {}
    for n in order:
        c = set(imports[n])
        for d in imports[n]:
            for x in closure[d]:
                c.add(x)
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
    done = set(order)
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
        diagnostics = {n: declare(n, "diag") for n, _ in nodes},
        dyn_o = {n: declare(n, "dyn_o") for n, _ in nodes} if dynamic_too else {},
        dyn_hi = {n: declare(n, "dyn_hi") for n, _ in nodes} if dynamic_too else {},
    )

# For each node, the object that a splice loads to run that module's code
# (see Note [Template Haskell modules], section 6).
#
# GHC looks for a module's dynamic object as <module>.dyn_o in the output
# directory. A profiled compile makes no dynamic objects, so it puts links
# there to the dynamic objects of the non-profiled compile, `dynamic_from`.
# compile() copies the same objects in for --make.
def _splice_objects(ctx: AnalysisContext, out_dir: str, nodes: list, o_of: dict, dynamic_objects: dict, enable_profiling: bool, dynamic_from: [CompileResultInfo, None]) -> dict:
    kind = splice_objects_kind(ctx, enable_profiling)
    if kind == "own":
        return o_of
    if kind == "dynamic":
        return dynamic_objects
    if dynamic_from == None or dynamic_from.dynamic_objects == None:
        fail("a profiled per_module compile needs a non-profiled per_module compile to take its splices' dynamic objects from")
    links = {}
    for n, _ in nodes:
        if n in dynamic_from.dynamic_objects:
            link = ctx.actions.declare_output(out_dir + "/" + _node_file(n, "dyn_o"), has_content_based_path = False)
            ctx.actions.symlink_file(link, dynamic_from.dynamic_objects[n])
            links[n] = link
    return links

# The version of the request that each compile action sends, and of the
# files that the worker writes back. The worker and the compile tool refuse a
# request of any other version, so that a worker built from another version
# of the rules reports the mismatch rather than misreading the request. When
# either the request or the worker's outputs change, bump this and the
# version in tools/ghc-api/Contract.hs.
_WORKER_CONTRACT = "6"

# The dynamic output of a per-module compile. It runs once the deps tool has
# written the module graph. It registers a compile action for each node,
# builds the target's objects and hi directories from their outputs, and
# returns each module's closure set for the target's dependents (see
# _ModuleClosureTSet). `s` carries the values that compile_per_module worked
# out during analysis.
def _register_modules_impl(actions: AnalysisActions, s: typing.Any, deps: ArtifactValue, libdir: ArtifactValue, dep_closures: dict, artifacts: list[Artifact], outputs: list[OutputArtifact]) -> list[Provider]:
    out = {a: o for a, o in zip(artifacts, outputs)}
    nodes = s.nodes
    src_of = s.src_of
    modules = s.modules
    module_libs = s.module_libs
    module_lib_dirs = s.module_lib_dirs
    splice_infos = s.splice_infos
    packages = s.packages
    early_packages = s.early_packages
    target_splice_packages = s.target_splice_packages
    splice_native_libs_dir = s.splice_native_libs_dir
    dynamic_too = s.dynamic_too
    o_of = s.o_of
    hi_of = s.hi_of
    abi_of = s.abi_of
    dyn_o_of = s.dyn_o_of
    splice_objects = s.splice_objects
    dyn_hi_of = s.dyn_hi_of
    diag_of = s.diag_of
    objects = s.objects
    hi = s.hi
    stubs = s.stubs
    prefix = s.prefix
    variant = s.variant
    osuf = s.osuf
    hisuf = s.hisuf
    tag = s.tag
    producing_indices = s.producing_indices
    src_tree = s.src_tree
    base_cmd = s.base_cmd
    data_dirs = s.data_dirs
    worker_info = s.worker_info
    tools = s.tools
    compile_script = s.compile_script

    imports, upstream, th_nodes, splice_imports, program_nodes = _read_deps(s.label, deps.read_json(), nodes, module_libs, s.prebuilt_names)
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

    # The environment of each set of build tools that some module may run,
    # made once for each set (see module_tools below).
    tools_envs = {}

    def env_with(names):
        key = ",".join(sorted(names))
        if key not in tools_envs:
            tools_envs[key] = tools_env(actions, s.compile_env, {t: tools[t] for t in names}, prefix + "build-tools/" + str(len(tools_envs)))
        return tools_envs[key]

    # The package flags of each module that has explicit level imports (see
    # Note [Explicit level imports]). Of the target's splice dependencies,
    # the module gets the final dbs of the ones whose modules it imports at
    # the splice level, and of their closures. For its other local
    # dependencies, it gets library-less dbs.
    narrowed_splice_packages = {}

    # A splice can run code of any prebuilt package, since all their
    # libraries are there from the start (see Note [Libraries of the early
    # package dbs]). So only local packages are checked here.
    prebuilt = set(s.prebuilt_names.values())

    # The package flags of a Template Haskell module. That is the target's
    # set, unless the module has explicit level imports, which may narrow it.
    def splice_packages(n):
        if n not in splice_imports:
            return target_splice_packages
        libs = {lib: m for lib, m in splice_imports[n] if lib != s.this_pkg}
        imports_own = len([lib for lib, _ in splice_imports[n] if lib == s.this_pkg]) > 0
        # An import of a module that several dependencies re-export, or that
        # its own package exposes as well, comes through each of them, and
        # any one would do. But each of them has to be covered here. That is
        # stricter than it needs to be, in a case that should be rare.
        for lib, m in libs.items():
            if lib not in target_splice_packages.final and lib not in prebuilt:
                fail("{}: {}'s splice import of {} runs code from {}, but splice_depends doesn't list it".format(s.label, _module_of(n), m, lib))
        # A dependency that isn't listed, but that a listed one's closure
        # brings in, has no closure of its own here. A module that imports
        # from one gets the target's whole set, as does a module that imports
        # one of the target's own modules.
        if [l for l in libs if l not in splice_infos.listed and l not in prebuilt] or imports_own:
            return target_splice_packages
        names = sorted([l for l in libs if l in splice_infos.listed])
        key = " ".join(names)
        if key not in narrowed_splice_packages:
            narrowed_splice_packages[key] = packages(splice_libraries(actions, splice_infos, names))
        return narrowed_splice_packages[key]

    # Register the compiles in dependency order. An action's inputs, and the
    # artifacts that a symlinked_dir links to, must be outputs of actions
    # that have already been registered.
    hie_of = {}

    # The modules compiled without the worker, with the build tools they may
    # run, for the haskell_modules_outside_worker check.
    outside_worker = {}
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
            if runs_th[n] and d in splice_objects:
                # The objects a splice may load (see _splice_objects).
                closure_files.append(splice_objects[d])
        mod_packages = splice_packages(n) if runs_th[n] else early_packages
        # These are the build tools that the module's compile may run. Only
        # these tools are on the compile's PATH, so the compile depends only
        # on them. GHC itself may run a build tool, such as a preprocessor
        # that -F -pgmF names. A splice may run any of the target's build
        # tools, so a module that runs Template Haskell gets all of them. A
        # module compiles in the worker only if it has no tools, because the
        # worker can't put a compile's tools on PATH (see Note [The
        # persistent worker]).
        module_tools = list(tools) if runs_th[n] else [p for p in program_nodes[n] if p in tools]
        # A module without Template Haskell needs no data dirs. A Template
        # Haskell module that may run build tools gets all the target's data
        # dirs. Any other Template Haskell module gets only the data dirs that
        # its splices could read. Those are the data dirs of its splices'
        # libraries, and the data dirs of any of the target's own Paths_<pkg>
        # modules that it imports. See Note [Data files of splices].
        own_modules = [_module_of(d) for d in closure[n] if not _is_boot(d)]
        module_data_dirs = compile_data_dirs(data_dirs, mod_packages.data_dirs, own_modules, len(module_tools) > 0) if runs_th[n] else {}
        hidirs = mod_packages.local_import_dirs + [(name, d) for name, d in module_lib_dirs.items() if name in mod_packages.early_names]

        # The flags specific to this module: its source and output files.
        # They go after the flags that all the target's modules share.
        stubdir = actions.declare_output(prefix + "stubs/" + n, dir = True, has_content_based_path = False)
        module_flags = cmd_args("-c", src_of[n], "-o", out[o_of[n]], "-ohi", out[hi_of[n]], "-stubdir", stubdir.as_output())
        mkdirs = [stubdir.as_output()]
        if closure[n]:
            module_flags.add(tag.tag_artifacts(cmd_args(_dir_of(hi_of[closure[n][0]], closure[n][0], hisuf), hidden = closure_files, format = "-i{}")))
        # The interfaces that the module may read from dependencies compiled
        # per-module. A Template Haskell module also gets the interfaces of the
        # dependencies whose final dbs it compiles against, through those dbs.
        module_flags.add(tag.tag_artifacts(cmd_args(hidden = upstream_closure_sets[n].project_as_args("interfaces"))))
        if dynamic_too:
            module_flags.add("-dyno", out[dyn_o_of[n]], "-dynohi", out[dyn_hi_of[n]])
        if producing_indices:
            # The module's .hie file. GHC writes it under -hiedir, at a path
            # made from the module's name. It goes in the target's hi
            # directory, which is also the target's index, as with --make.
            hie_of[n] = actions.declare_output(prefix + "hie/" + n + "/" + _node_file(n, "hie"), has_content_based_path = False)
            module_flags.add("-hiedir", _dir_of(hie_of[n].as_output(), n, "hie"))

        # The request that the action sends to the worker, or to the compile
        # tool if there is no worker (see Note [The persistent worker]).
        # Request.hs in tools/ghc-api describes each argument.
        depfile = actions.declare_output(prefix + "dep/" + n + ".dep", has_content_based_path = False)
        request = cmd_args(
            "--request",
            "--contract",
            _WORKER_CONTRACT,
            "--libdir",
            libdir.read_string().strip(),
            "--depfile",
            tag.tag_artifacts(depfile.as_output()),
            "--abi",
            out[abi_of[n]],
            "--diagnostics",
            out[diag_of[n]],
            "--module",
            _module_of(n).replace(".", "/"),
            "--source",
            src_of[n],
            "--outdir",
            _dir_of(out[hi_of[n]], n, hisuf),
            "--hisuf",
            hisuf,
            "--boot" if _is_boot(n) else [],
            # The modules in the closure (not just boot files), whose objects
            # a splice may load (see Note [Template Haskell modules]).
            ["--loadable=" + d for d in closure[n] if not _is_boot(d)] if runs_th[n] else [],
            # Where each dependency's interfaces are, so that the tool can
            # turn the usages GHC records into dep file entries. These are
            # paths only, not inputs. The interfaces themselves are inputs
            # already: through upstream_closure_sets, and, for --make
            # libraries, through the package db flags. For a dependency
            # compiled per-module, the path is worked out from one of its
            # interface files, so as an input it would make the module wait
            # for that particular interface for no reason.
            [cmd_args(d, format = "--hidir=" + unit + "={}", ignore_artifacts = True) for unit, d in hidirs],
            tag.tag_artifacts(cmd_args(src_tree, format = "--srcroot={}")) if src_tree != None else [],
            cmd_args(mkdirs, format = "--mkdir={}"),
            # See Note [Data files of splices].
            [cmd_args(d, format = "--data-dir=" + var + "={}") for var, d in module_data_dirs.items()],
            # See Note [Template Haskell modules], section 4.
            cmd_args(splice_native_libs_dir, format = "--library-path={}") if runs_th[n] and splice_native_libs_dir != None else [],
            "--",
            base_cmd,
            mod_packages.args,
            "--",
            module_flags,
        )
        # The compile tool runs the request as one `ghc -c`. With a worker,
        # buck2 sends the request to the worker instead, and runs the compile
        # tool only when it runs the action somewhere the worker isn't, such
        # as on a remote executor.
        # The worker cannot give a compile environment variables of its
        # own, since it is a single process. So a module whose splices need
        # the environment variables for the target's data dirs (see Note
        # [Data files of splices]), or an LD_LIBRARY_PATH for native
        # libraries that it loads (see Note [Template Haskell modules],
        # section 4), must also compile outside the worker.
        needs_data = len(module_data_dirs) > 0
        needs_native = runs_th[n] and splice_native_libs_dir != None
        script = in_env(env_with(module_tools), cmd_args(compile_script))
        category = "haskell_compile"
        identifier = variant + "/" + n
        in_worker = worker_info != None and not module_tools and not needs_data and not needs_native
        if worker_info != None and not in_worker:
            outside_worker[n] = struct(tools = module_tools, data_dirs = needs_data, native_libraries = needs_native)
        # For allow_dep_file_cache_upload, see Note [Early cut-off by dep files], section 5.
        if in_worker:
            actions.run(request, exe = WorkerRunInfo(worker = worker_info, exe = script), category = category, identifier = identifier, dep_files = {"hs": tag}, allow_dep_file_cache_upload = True)
        else:
            actions.run(cmd_args(script, request), category = category, identifier = identifier, dep_files = {"hs": tag}, allow_dep_file_cache_upload = True)

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

    actions.write(out[s.advice["haskell_unused_build_tools"]], json.encode(_unused_build_tools(tools, runs_th, program_nodes)))
    actions.write(out[s.advice["haskell_template_haskell_from_flags"]], json.encode(_template_haskell_from_flags(th_nodes)))
    actions.write(out[s.advice["haskell_ann_pragmas"]], json.encode(_ann_pragmas(th_nodes)))
    actions.write(out[s.advice["haskell_modules_outside_worker"]], json.encode(_modules_outside_worker(outside_worker, runs_th)))
    return [PerModuleClosures(by_module = closure_sets)]

_register_modules = dynamic_actions(
    impl = _register_modules_impl,
    attrs = {
        "artifacts": dynattrs.value(list[Artifact]),
        "dep_closures": dynattrs.dict(str, dynattrs.dynamic_value()),
        "deps": dynattrs.artifact_value(),
        "libdir": dynattrs.artifact_value(),
        "outputs": dynattrs.list(dynattrs.output()),
        "s": dynattrs.value(typing.Any),
    },
)

# The advice checks of a target compiled per-module, indexed by the names of their
# validations (see Note [Advice]).
ADVICE_CHECKS = ["haskell_unused_build_tools", "haskell_template_haskell_from_flags", "haskell_ann_pragmas", "haskell_modules_outside_worker"]

def advice_validations(compiled: CompileResultInfo) -> list[Provider]:
    if not compiled.advice:
        return []
    return [ValidationInfo(validations = [
        ValidationSpec(name = name, validation_result = result)
        for name, result in compiled.advice.items()
    ])]

# Identify modules that compile as Template Haskell modules because their
# target's flags turn on TemplateHaskell or QuasiQuotes.
def _template_haskell_from_flags(th: dict) -> dict:
    modules = sorted([_module_of(n) for n, why in th.items() if why == "flags"])
    return _advice(
        [{"module": m} for m in modules],
        "{} modules".format(len(modules)),
        "Modules that compile as if they used Template Haskell, which is slower, because their target's flags turn on TemplateHaskell or QuasiQuotes. Turn the extensions on only in the modules that need them.",
    )

# Identify modules that use ANN pragmas (which implies TH).
def _ann_pragmas(th: dict) -> dict:
    modules = sorted([_module_of(n) for n, why in th.items() if why == "ann"])
    return _advice(
        [{"module": m} for m in modules],
        ", ".join(modules),
        "Modules that compile as if they used Template Haskell only because of ANN pragmas, which is slower. For HLint's, write {- HLINT ignore ... -} comments instead.",
    )

# Identify modules that are forced to compile outside the worker.
def _modules_outside_worker(outside: dict, runs_th: dict) -> dict:
    findings = [
        {
            "module": _module_of(n),
            "tools": sorted(why.tools),
            "template_haskell": runs_th[n],
            "data_dirs": why.data_dirs,
            "native_libraries": why.native_libraries,
        }
        for n, why in sorted(outside.items())
    ]
    def describe(f):
        why = []
        if f["tools"]:
            why.append(("may run " if f["template_haskell"] else "runs ") + ", ".join(f["tools"]))
        if f["data_dirs"]:
            why.append("its splices may read data files")
        if f["native_libraries"]:
            why.append("its splices may load native libraries")
        return "{} ({})".format(f["module"], "; ".join(why))
    return _advice(
        findings,
        "; ".join([describe(f) for f in findings]),
        "Modules that compile without the persistent worker, which is slower. A module compiles outside it if it may run build tools (tools), or if its splices may read data files (data_dirs) or load native libraries (native_libraries). A module that runs Template Haskell (template_haskell) is assumed to run any of its target's build tools.",
    )

# We special-case the build tools that we run in actions of their own, so they're never run as part of a module's
# actual compilation action.
_PREPROCESSORS = ["alex", "happy", "hsc2hs"]

# Identify build tools which aren't used in compiling any module, as far as we can tell.
def _unused_build_tools(tools: dict, runs_th: dict, program_nodes: dict) -> dict:
    run = set([p for programs in program_nodes.values() for p in programs])
    splices = any(runs_th.values())
    findings = [
        {"tool": t, "splices": splices}
        for t in sorted(tools)
        if t not in run and t not in _PREPROCESSORS
    ]
    return _advice(
        findings,
        ", ".join([f["tool"] for f in findings]) + (" (unless a splice runs them)" if splices else ""),
        "Build tools that no module's compile runs, though where the target has Template Haskell splices (splices), a splice might. Remove them from build_tool_depends, or, for a program that runs them, move them to run_tool_depends.",
    )

# The result of an advice check. Advice checks always succeed, and the findings go in
# the result's data. `message` says what the check found in this target, and
# `explanation`, which is the same for every target, says what the check
# looks for and what to do about it.
def _advice(findings: list, message: str, explanation: str) -> dict:
    return {"version": 1, "data": {"status": "success", "message": message if findings else "nothing to report", "explanation": explanation, "findings": findings}}

# Whether the target is compiled per-module: its compile granularity is
# "module", and it has at least one Haskell module. A target without any
# modules always goes through compile(), which produces the empty outputs that
# such a target needs.
def compiles_per_module(ctx: AnalysisContext) -> bool:
    return _compile_granularity(ctx) == "module" and has_modules(ctx)

# The target's compile_granularity, or the toolchain's if the target doesn't
# set it. A rule that has no compile_granularity attribute always compiles
# the whole target with --make.
def _compile_granularity(ctx: AnalysisContext) -> str:
    if not hasattr(ctx.attrs, "compile_granularity"):
        return "target"
    return ctx.attrs.compile_granularity or ctx.attrs._haskell_toolchain[HaskellToolchainInfo].compile_granularity

# Compile the target's sources with one action per module (see Note
# [Per-module compilation]). It takes the same arguments as compile(), so
# that the two are interchangeable, but ignores native_libs. A splice finds
# the native libraries of the libraries it can run through a tree of their
# own (see Note [Template Haskell modules], section 4). A splice can't call
# the target's own native libraries, as with --make. A profiled compile gets
# the dynamic objects its splices load from dynamic_from (see
# _splice_objects).
def compile_per_module(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None = None, native_libs: SharedLibraryInfo = EMPTY_SHARED_LIBRARY_INFO, dynamic_too: bool = False, dynamic_from: [CompileResultInfo, None] = None) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    variant = variant_name(link_style, enable_profiling)
    osuf, hisuf = output_extensions(link_style, enable_profiling)
    prefix = per_module_dir(link_style, enable_profiling)

    # When GHC's internal interpreter loads dynamic objects, a static compile
    # makes them too, in case a splice runs one of the target's own modules
    # (see Note [Template Haskell modules], section 6).
    if link_style != LinkStyle("shared") and not enable_profiling and splice_objects_kind(ctx, False) == "dynamic":
        dynamic_too = True

    # The tag of every input a module's dep file may list: see Note [Early
    # cut-off by dep files].
    tag = ctx.actions.artifact_tag()

    # A module's package flags (see _package_dbs). They have the final dbs
    # of the prebuilt dependencies and of the local ones in `final`, and dbs
    # that name no library for the other local ones. A module that runs no
    # Template Haskell compiles against no local library.
    dep_libs = list(dependency_libs(ctx, link_style, enable_profiling).traverse())
    exposed_package_args = get_exposed_package_args(ctx, link_style, False, enable_profiling)

    # The dependencies compiled per-module that some dependency built with
    # --make depends on, found through the --make libraries' `below` sets
    # (see Note [Compiling against dependencies module by module]).
    below = ctx.actions.tset(HaskellLibraryInfoTSet, children = [lib.below for lib in dep_libs if lib.below != None])
    below_make = set([lib.name for lib in below.traverse() if lib.modules != None])

    # A module with explicit level imports calls this from the dynamic
    # output, with the packages that its splice imports need.
    def packages(final, runs_th = True):
        dbs = _package_dbs(dep_libs, final, below_make, tag, runs_th)
        return struct(
            args = cmd_args(exposed_package_args, dbs.packagedb_args),
            local_import_dirs = dbs.local_import_dirs,
            early_names = dbs.early_names,
            native_libs = dbs.native_libs,
            final = final,
            # The data dirs that the Paths_<pkg> modules of the libraries in
            # `final` read (see Note [Data files of splices]).
            data_dirs = {var: d for lib in dep_libs if lib.name in final for var, d in lib.data_dirs.items()},
        )

    early_packages = packages(set(), runs_th = False)

    # Only the actions of Template Haskell modules depend on the
    # dependencies' libraries, because only those modules load them, and so
    # only they have to wait for the libraries to be linked. Most Template
    # Haskell modules use the target's set of final dbs. A module with
    # explicit level imports narrows it to what its splices import (see Note
    # [Explicit level imports]).
    splice_infos = splice_dep_infos(ctx, link_style, enable_profiling)
    target_splice_packages = packages(splice_libraries(ctx.actions, splice_infos))
    # One tree of native libraries for every Template Haskell module: those
    # of the libraries in the target's set. A module whose set is narrowed
    # gets it too, since its native libraries are among them.
    splice_native_libs_dir = native_libs_tree(ctx, prefix + "native-libs", target_splice_packages.native_libs)
    module_libs = {lib.name: lib for lib in dep_libs if lib.modules != None}
    this_pkg = pkgname or haskell_library_unit_id(ctx.label)

    # Every module is compiled with -this-unit-id. A library's unit is the
    # `pkgname` it is registered under. A binary's is made from the target's
    # label, rather than GHC's default of `main`. Otherwise all binaries
    # would share the unit `main`. A persistent worker runs the splices of
    # many targets in one process, and its runtime would then confuse two
    # binaries' modules that have the same name.
    cmd_flags, file_flags = ghc_flags(ctx, link_style, enable_profiling, this_pkg, dynamic_too)
    # The target's other sources, such as headers that a module #includes.
    # GHC doesn't record which of these a module used, so they can't go in
    # the dep file. Instead, every module's compile has all of them as plain
    # inputs, as the --make compile does.
    other_srcs = [src for _, src in srcs_to_pairs(ctx.attrs.srcs) if not is_haskell_src(src) and not src.short_path.endswith(_BOOT)]
    # With per_module, buck2 decides when a module compiles, so GHC must
    # never reuse an earlier result. -fforce-recomp stops it from doing that
    # (see Note [Early cut-off by dep files]).
    ghc_args = cmd_args(cmd_flags, file_flags, "-fforce-recomp", hidden = other_srcs)
    base_cmd = cmd_args(haskell_toolchain.compiler, ghc_args)
    env = ghc_env(ctx, prefix + "build-tool-depends")

    # The toolchain's shared worker (see Note [The persistent worker]), or
    # None if it has none.
    worker_info = haskell_toolchain.per_module_shared_worker

    nodes = _nodes(ctx)
    src_of = {n: src for n, src in nodes}

    # With a worker, each module's session finds the target's modules in a
    # tree that holds just the target's sources (see Note [The persistent
    # worker]). The tree changes whenever any of the target's sources
    # changes, and that alone is no reason to compile every module again. So
    # the tree is a tagged input, which only matters to a compile if its dep
    # file lists it. A module's own source is an ordinary input as well.
    src_tree = None
    if worker_info != None:
        src_tree = ctx.actions.symlinked_dir(
            prefix + "srcs",
            # Each source keeps its own extension, because GHC reads a file
            # according to its extension: a .lhs file is literate Haskell,
            # for example.
            {_module_of(n).replace(".", "/") + src.extension: src for n, src in nodes},
            has_content_based_path = False,
        )

    out_dir = per_module_out_dir(ctx, link_style, enable_profiling)
    module_outputs = _declare_module_outputs(ctx, out_dir, nodes, osuf, hisuf, dynamic_too)
    o_of = module_outputs.o
    hi_of = module_outputs.hi
    abi_of = module_outputs.abi
    dyn_o_of = module_outputs.dyn_o
    dyn_hi_of = module_outputs.dyn_hi
    diag_of = module_outputs.diagnostics
    dynamic_objects = o_of if link_style == LinkStyle("shared") else dyn_o_of
    splice_objects = _splice_objects(ctx, out_dir, nodes, o_of, dynamic_objects, enable_profiling, dynamic_from)
    objects = ctx.actions.declare_output("objects-" + variant, dir = True, has_content_based_path = False)
    hi = ctx.actions.declare_output("hi-" + variant, dir = True, has_content_based_path = False)
    stubs = ctx.actions.declare_output("stubs-" + variant, dir = True, has_content_based_path = False)
    producing_indices = get_producing_indices(ctx)

    # The libdir of the GHC that compiles the target. The tools need it to
    # run GHC's code (see Libdir and Request in tools/ghc-api).
    libdir = haskell_toolchain.libdir
    if libdir == None:
        fail("{}: per_module needs the Haskell toolchain's `libdir`, which print_libdir() in prelude/haskell/toolchain.bzl makes".format(ctx.label))

    # Work out the module graph with GHC's own dependency analysis, which the
    # deps tool runs (see tools/ghc-api/PerModuleDeps.hs). For each node, it
    # finds the imports, both from this target and from dependencies,
    # whether the node may run Template Haskell, and what it imports at the
    # splice level. It runs against the early dbs, so it doesn't wait for
    # any dependency compiled per-module. (It does wait for dependencies
    # built with --make, whose interfaces are inputs of their package dbs.)
    # The tool is given each node with its source, and the GHC flags without
    # the compiler itself, because it runs GHC's analysis in-process.
    deps = ctx.actions.declare_output(prefix + "deps.json")
    ctx.actions.run(
        # The tool takes the libdir as a flag, so the shell reads it from
        # the file and puts the flag after the tool.
        in_env(struct(
            script = env.script + 'tool="$1"; libdir=$(cat "$2"); shift 2; set -- "$tool" "--libdir=$libdir" "$@"; ',
            args = env.args,
        ), cmd_args(
            haskell_toolchain.per_module_deps or ctx.attrs._per_module_deps[RunInfo],
            libdir,
            deps.as_output(),
            [cmd_args(n, src, delimiter = "=") for n, src in nodes],
            "--",
            ghc_args,
            early_packages.args,
            # The compiler command may carry files that the libdir is made
            # of, so we add a dependency on it
            hidden = haskell_toolchain.compiler,
        )),
        category = "haskell_deps",
        identifier = variant,
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

    # The prebuilt dependencies' names, by unit id. The deps tool names the
    # packages that splice imports come through by unit id.
    prebuilt_names = {lib.id: lib.name for lib in dep_libs if lib.is_prebuilt}

    modules = {
        n: HaskellModuleFiles(hi = hi_of[n], abi = abi_of[n], dyn_hi = dyn_hi_of[n] if dynamic_too else None)
        for n, _ in nodes
    }
    # The results of the advice checks (see Note [Advice]).
    advice = {name: ctx.actions.declare_output(prefix + "advice/" + name + ".json") for name in ADVICE_CHECKS}
    all_outputs = [objects, hi, stubs] + advice.values()
    for files in [o_of, hi_of, abi_of, dyn_o_of, dyn_hi_of, diag_of]:
        all_outputs += files.values()
    closures = ctx.actions.dynamic_output_new(_register_modules(
        s = struct(
            label = ctx.label,
            this_pkg = this_pkg,
            compile_script = haskell_toolchain.per_module_compile or ctx.attrs._per_module_compile[RunInfo],
            nodes = nodes,
            src_of = src_of,
            modules = modules,
            module_libs = module_libs,
            module_lib_dirs = module_lib_dirs,
            prebuilt_names = prebuilt_names,
            splice_infos = splice_infos,
            packages = packages,
            early_packages = early_packages,
            target_splice_packages = target_splice_packages,
            splice_native_libs_dir = splice_native_libs_dir,
            dynamic_too = dynamic_too,
            o_of = o_of,
            hi_of = hi_of,
            abi_of = abi_of,
            dyn_o_of = dyn_o_of,
            splice_objects = splice_objects,
            dyn_hi_of = dyn_hi_of,
            diag_of = diag_of,
            objects = objects,
            hi = hi,
            stubs = stubs,
            prefix = prefix,
            variant = variant,
            osuf = osuf,
            hisuf = hisuf,
            tag = tag,
            producing_indices = producing_indices,
            src_tree = src_tree,
            base_cmd = base_cmd,
            worker_info = worker_info,
            data_dirs = data_dirs_env(ctx),
            tools = build_tools(ctx),
            compile_env = haskell_toolchain.compile_env,
            advice = advice,
        ),
        deps = deps,
        libdir = libdir,
        dep_closures = {lib.name: lib.closures for lib in module_libs.values()},
        artifacts = all_outputs,
        outputs = [a.as_output() for a in all_outputs],
    ))
    return CompileResultInfo(objects = objects, hi = hi, stubs = stubs, producing_indices = producing_indices, diagnostics = diag_of.values(), modules = modules, closures = closures, import_dir = out_dir, advice = advice, dynamic_objects = dynamic_objects)

# Note [Advice]
#
# Some ways of declaring a target build correctly but slowly. A build tool
# that no module's compilation action runs, for example, is still built
# before the target's modules compile, and in a second configuration if the
# program also runs it. The rules can spot some of these from what they
# learn while compiling, and report them as advice.
#
# Each kind of advice is a check with a buck2 validation of its own (see
# ADVICE_CHECKS), which the target returns in its ValidationInfo. A check
# always succeeds, even when it has findings, so the advice never stops a
# build. The findings are in the result's data, as a list under "findings",
# with a "message" that sums them up and an "explanation" of what the check
# looks for and what to do about it. prelude//haskell/advice.bxl turns the
# results into one report of what there is to act on, using only these
# fields. The prelude's
# validation/audit_results.bxl gives the paths of the results themselves,
# and can pick checks out by name:
#
#     buck2 bxl prelude//validation/audit_results.bxl:main -- --take haskell_unused_build_tools --trim true --targets //...
#
# A check's result is written by the dynamic output that registers the
# target's compiles, which has the deps tool's results already, so a check
# costs no action of its own.

# Note [Per-module compilation]
#
# Normally a target is compiled by one `ghc --make` action. With
# compile_granularity = "module", it is compiled by one `ghc -c` action per
# module instead. buck2 can then:
#
# - run the target's modules in parallel with everything else in the build;
# - start each module as soon as the modules it imports are compiled, even
#   those of other targets, rather than waiting for whole targets;
# - after an edit, run again only the modules affected.
#
# The price is CPU. Each `ghc -c` reads the interfaces of everything its
# module imports (and, for Template Haskell, loads the dependencies' shared
# libraries), which `ghc --make` does only once per target. A persistent
# worker takes most of that cost away (see Note [The persistent worker]).
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
#   closure, since GHC reads them for instances and type families. A
#   Template Haskell module also needs the objects of its closure.
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
#   a "library-less" db, the final db without the library (see Note
#   [Libraries of the early package dbs]).
# - Template Haskell module: one that runs a splice, or evaluates an ANN
#   pragma (GHC uses its interpreter for those too). It runs its
#   dependencies' code at compile time, so it needs their libraries, not
#   just their interfaces. See Note [Template Haskell modules].
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
# - Note [Template Haskell modules]: what the modules that run code at
#   compile time wait for. Note [Libraries of the early package dbs] has
#   the package dbs each compile gets, and Note [Explicit level imports]
#   how a module can say what its splices run.
# - Note [The persistent worker]: compiling the modules in long-running
#   GHC sessions rather than one `ghc -c` per module.

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
# compile might read from other compiles is a tagged input: the interfaces,
# and for a Template Haskell module the objects of the target's own modules.
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
#   the interface itself (DepFile in tools/ghc-api, which the compile tool
#   and the persistent worker share).
# - The objects of the target's own modules that a splice loaded, which GHC
#   records as dependent files. (The dependencies' libraries are plain
#   inputs instead, as Note [Template Haskell modules] explains.)
#
# 3. buck2 decides, not GHC
#
# buck2 removes an action's previous outputs before running it, so GHC's
# recompilation check never has anything to compare against, and the module
# compiles whenever the action runs. GHC's check would also notice a change
# to the code a splice ran, since it records the hash of each object and
# Haskell library the splice loaded. But it doesn't record extra-libraries,
# which is how the package dbs here name a library, so the libraries are
# inputs of the compile instead (see Note [Template Haskell modules]).
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
#
# 5. With a remote cache
#
# buck2 keeps dep files in the daemon's memory, so a new daemon, or a new
# checkout, has none, and a module whose tagged inputs changed compiles
# again even if it read none of them. A remote cache can keep the dep files
# too. buck2 then also stores each compile's result under a key that leaves
# out the tagged inputs, together with its dep file, and reuses the result
# if the inputs that the dep file lists are unchanged. The compiles allow
# that with allow_dep_file_cache_upload, which only uploads where results
# are uploaded at all, and the execution platform that uses the cache turns
# it on with remote_dep_file_cache_enabled.

# Note [Template Haskell modules]
#
# 1. The problem
#
# A Template Haskell module runs its dependencies' code at compile time, so
# it needs their libraries, not just their interfaces. That means waiting
# for its dependencies to be linked, which loses much of the parallelism
# that compiling per-module gains.
#
# 2. What it waits for
#
# A Template Haskell module compiles against the final package dbs of the
# local dependencies that the target's splice_depends lists (see
# target_splice_libraries in compile.bzl), with their libraries and the native
# libraries they depend on as inputs. So it waits only for those libraries
# (and those of their own dependencies), and compiles against library-less
# dbs for the other local dependencies, like any other module. The prebuilt packages'
# libraries are there from the start, so a Template Haskell module gets
# them all.
#
# A module with explicit level imports narrows the target's list further,
# to the libraries that its splices import. See Note [Explicit level
# imports].
#
# Note [Libraries of the early package dbs] has a table of which package db
# a compile gets for each dependency. If a splice runs code from a
# dependency that was left out, the compile fails, and GHC names the symbol
# it couldn't load. In the persistent worker the compile may succeed
# instead (see section 5).
#
# 3. Why the libraries aren't in the dep file
#
# The libraries are plain inputs of the compile, rather than tagged inputs
# that its dep file lists. So the module compiles again whenever one of them
# is linked again, even if its splices didn't use it. The dep file can't
# list just the libraries that the splices used, because nothing records
# them. GHC records in a module's interface each Haskell library (from
# hs-libraries) that its splices loaded. But the package dbs here name a
# package's library as one of its extra-libraries, which GHC doesn't record.
# So a splice that ran a dependency's code leaves no trace of the
# dependency's library in the interface, and yet a change to that code must
# compile the module again.
#
# 4. Native libraries
#
# A library that buck2 links refers to the native libraries it was linked
# against by soname, but it has no RUNPATH to find them. So when a splice
# loads such a library, the dynamic loader can only find the libraries it
# needs if they are on LD_LIBRARY_PATH.
#
# Each library has the set of the shared libraries of its native
# dependencies, and of theirs in turn (see _native_libs in haskell.bzl).
# The target makes one tree, named by soname, of the sets of the libraries
# that its Template Haskell modules may load (see native_libs_tree in
# compile.bzl). Their requests name the tree with --library-path. The tree
# is an input of their compiles, and the compile tool puts it on GHC's
# LD_LIBRARY_PATH. So the modules wait for those native libraries, but not
# for any others.
#
# The dynamic loader reads LD_LIBRARY_PATH once, when a process starts, so
# the persistent worker can't give a compile action its own library path.
# A module that needs a different library path (i.e. one which has to load
# a buck2-built native library, rare without --source-deps) must compile
# outside the worker.
#
# A possible alternative: the package dbs could name the native libraries for
# GHC's interpreter, in dependency order, in extra-ghci-libraries. GHC
# would then load each one by path before the libraries that need it, and
# the dynamic loader would reuse the one already loaded. That lets the
# worker compile those modules too, but it only works for ELF libraries
# whose sonames GHC can look up, and relies on the order GHC loads
# libraries in.
#
# 5. Splices in the persistent worker
#
# GHC's internal interpreter runs splices in GHC's own process. For a
# `ghc -c`, that process compiles one module, so any state is limited in
# scope. The persistent worker is one process which is shared by every
# session for the length of a build. (buck2 starts a worker for each
# WorkerInfo, and the toolchain makes one WorkerInfo for each
# configuration. buck2 starts the worker again in each build.) This means
# we don't get proper isolation between splices. So in the worker:
#
# - A splice can run code from a library that another target's splice has
#   loaded, without having that library as an input. This means that in
#   principle a dependency left out of splice_depends can go
#   unnoticed, depending on the order the modules compile in.
# - The splices of different targets share the global state of a library
#   they both run.
# - A splice that crashes the process fails every compile action that the
#   worker is running, not just its own module's.
#
# The rules' tests have some expected-failure tests for these cases.
#
# Some modules really need a different environment (e.g. they need data
# files, or need to load buck2-built native libraries). So these have to be
# compiled outside the worker currently.
#
# A target compiled with -fexternal-interpreter (in its compiler_flags, or
# the toolchain's) runs its splices in external interpreters instead. In the
# worker, each session has an interpreter of its own, a process which loads
# the libraries that the session's splices run. (GHC chooses the interpreter
# when a session starts, so the flag has no effect in a module's
# OPTIONS_GHC pragma.) A session belongs to one target, so the splices of
# different targets don't share libraries or their state, and a splice that
# crashes its interpreter fails only the compiles of its own session. The
# splices of one session still share a library's global state, as those of
# one target do with --make. The cost is a process for each session that
# runs splices, and the time to send code and values to it. Before GHC
# 9.12, GHC doesn't stop two compiles from using one interpreter at once,
# so the compiles of a session that run splices take turns (see
# interpreterLock in the worker).
#
# An external interpreter doesn't yet work for every splice. In a static or
# profiled build (the opt and prof modes), the interpreter is static or
# profiled too. It loads a local library's archive with GHC's own linker,
# which doesn't load the shared libraries of the library's native
# dependencies, so a splice that calls them fails. That happens with --make
# as well. The package dbs would have to name those libraries for the
# interpreter.
#
# 6. Splices that run the target's own modules
#
# A splice can run code of the target's own modules, as it can with --make.
# GHC loads the objects of those modules from the output directory. So the
# compile action of a Template Haskell module has the objects of all the
# modules in its closure as tagged inputs. Its dep file lists only the
# objects that a splice actually loaded (see Note [Early cut-off by dep
# files]).
#
# When GHC loads one of the target's modules, it also loads the libraries
# that the module uses. It does this even when the splice only reads a
# value from one of those libraries, because GHC links whole modules along
# with their imports. So splice_depends has to list those libraries too,
# as it does with --make.
#
# Which objects GHC loads depends on the interpreter that runs the splice,
# as it does with --make (see _splice_objects):
#
# - The internal interpreter of a dynamically linked GHC loads dynamic
#   objects. A shared compile's own objects are dynamic. A static compile
#   makes dynamic objects, its .dyn_o files, only with -dynamic-too.
# - A profiled compile makes no dynamic objects. So the internal
#   interpreter loads the dynamic objects of the non-profiled compile
#   instead, which compile() also arranges for --make.
# - With -fexternal-interpreter, the interpreter is built in the same way
#   as the compile, so it loads the objects that the compile makes itself.
#
# --make gets GHC to add -dynamic-too for just the modules that splices
# need. A per-module compile can't do that, because it learns which modules
# those are only after the deps tool has run. So when GHC's internal
# interpreter loads dynamic objects, every non-profiled static compile uses
# -dynamic-too, even in a target with no splices. That makes such a compile
# cost about as much as two. A profiled compile takes its dynamic objects
# from the non-profiled compile that its caller passes as `dynamic_from`.
#
# A splice can't call the target's own native libraries. That isn't
# supported with --make either.
#
# 7. Modules behind boot files
#
# Say that the Template Haskell module T imports A, and that A imports B
# with {-# SOURCE #-}. T's closure has A and B's boot file, but not B
# itself, because B may not be compiled yet. If a splice in T runs A's
# code, that code may call B's, and then GHC has to link B. But B's object
# isn't an input of T's compile. So with per_module, a splice can't run
# code of a module that T reaches only through boot files. GHC might still
# find B's object in the output directory, left there by an earlier build,
# but then T's compile would depend on a file that buck2 doesn't know
# about. So the compile fails if a splice loaded such an object (see
# DepFile in tools/ghc-api).
#
# In the persistent worker, a splice like this can fail even when T also
# imports B normally. T's session sees B in the way that T's imports record
# it, and if one of those imports records only B's boot interface, GHC's
# linker won't load B.
#
# 8. Finding the Template Haskell modules
#
# Which modules run Template Haskell has to be decided before anything is
# compiled. The deps tool asks GHC which extensions each module has, from its
# pragmas and the target's flags, and looks for ANN pragmas in its
# (preprocessed) source. That can find too much (an ANN pragma in a comment,
# say), but it's better to be conservative. It doesn't catch GHC plugins.

# Note [Libraries of the early package dbs]
#
# 1. The problem
#
# A Template Haskell module runs code in GHC's interpreter, which first
# loads the library of every package on the command line, and of their
# dependencies (GHC's "preload" units), whether or not the splice uses it.
# A dynamically linked GHC tolerates a missing library file. It warns, or
# says nothing, and carries on. But a library that is there, and was linked
# against one that isn't, fails to load in the system's dynamic linker, and
# then the compile fails. buck2 doesn't sandbox local actions, so a library
# that a compile doesn't declare as an input may or may not be on disk. It
# may not have been linked yet, or not materialised, even if a library next
# to it has been.
#
# 2. The solution
#
# Every package db that a compile gets either names no library, or names
# one that the compile depends on. For each local dependency, a compile
# gets either a db that names no library (the early db of one compiled
# per-module, or the library-less db of one built with --make), or its
# final db, which names the library and brings it as an input of the
# compile. The prebuilt packages share one db, whose libraries exist before
# the build starts:
#
#                                 local dependency         prebuilt
#                                 (per-module, --make)     dependency
#   module that runs no TH        no library               final
#   TH module                     final if listed,         final
#                                 else no library
#   TH module, explicit level     final if listed and      final
#   imports                       its splice imports
#                                 need it,
#                                 else no library
#
# A final db comes with the final dbs of the dependency's closure. A module
# that runs no Template Haskell never starts the interpreter, so it doesn't
# depend on the libraries of the final dbs it gets.

# Note [Explicit level imports]
#
# 1. The idea
#
# With ExplicitLevelImports (GHC 9.14 and later), or
# NoImplicitStagePersistence, a splice or ANN pragma can only use what the
# module imports with `import splice`. Using a name imported otherwise, even
# from the Prelude, is a level error. So those imports tell us exactly what
# code the module's splices may run, and so which libraries its compile
# needs:
#
# - A module of a dependency needs that dependency's library, and the
#   libraries of its own dependencies (see Note [Libraries of the early
#   package dbs]).
# - A module of the target itself might use any of the target's splice
#   dependencies, so the module gets the target's whole set (see Note
#   [Template Haskell modules], section 6).
#
# The splice imports refine the target's splice_depends, as a module's
# imports refine its target's dependencies. The module compiles against the
# final dbs of the listed dependencies, local or prebuilt, that its splice
# imports come through, and against dbs that name no library for the
# others. So it waits only for those libraries, even if its target lists
# more. A module that a dependency re-exports comes through that
# dependency, whose closure has the package that defines it.
#
# A splice import from a dependency outside the closures of the listed ones
# is an error, as an import from a package that isn't a dependency is. A
# dependency inside one of those closures that isn't listed itself has no
# closure of its own here, so a module that imports from it gets the
# target's whole set. This works for dependencies built with --make too,
# since GHC's dependency analysis says which dependency any imported module
# comes from.
#
# 2. Finding the splice imports
#
# The deps tool reads each import's level from GHC's summary of the module,
# whose imports carry a level from GHC 9.14. It decides whether the module
# has explicit level imports from the module's extensions, which come from
# its pragmas and the target's flags.

# Note [The persistent worker]
#
# 1. The problem
#
# Compiling per-module uses more CPU than --make, and most of the extra cost
# comes from starting a new GHC for every module. Each of those GHCs reads
# the interfaces of everything its module imports, so an interface that 100
# modules import is read 100 times, where --make reads it once.
#
# 2. The solution
#
# A buck2 persistent worker is a long-running process that buck2 sends
# actions to. Ours (prelude/haskell/tools/worker) compiles each module as it arrives,
# concurrently with the others, in a GHC session that keeps the interfaces
# it has read. It is configured by `[haskell] per_module_worker` (see
# prelude/haskell/per_module_worker.bzl).
#
# 3. The request
#
# A module's action sends the same request whether or not there is a
# worker. The request goes either to the worker, or to the compile tool,
# which runs it as one `ghc -c`. It holds the module's source, the libdir
# of the GHC that compiles it, and the compile's flags. The flags come in
# two parts:
#
# - The session flags are the same for all of the target's modules that run
#   no Template Haskell. Its Template Haskell modules have session flags of
#   their own, because their package dbs differ (see Note [Libraries of the
#   early package dbs]). The worker keeps a session for each distinct set of
#   session flags.
# - The module flags are the module's own. The worker uses only the output
#   flags among them: -o, -ohi, -dyno, -dynohi, -hiedir and -stubdir.
#
# The request names its version (_WORKER_CONTRACT), so that a worker built
# for another version of the rules refuses it.
#
# 4. Which worker takes a module
#
# buck2 starts a process for each worker (WorkerInfo) that an action names,
# and keeps it until the end of the build. A worker per target would be
# hundreds of processes in a large project, each with its own runtime and
# sessions, which would take far too much memory. So the targets share one
# worker, made once by the toolchain.
#
# The worker is a single process, so it can't give each request its own
# environment variables or PATH. That means the shared worker can only
# compile modules that need nothing from their target's environment.
#
# What a module may need from that environment is its target's build tools,
# which a compile without the worker finds on PATH. Most modules never run
# one. For example, a target that uses alex has a module generated from a
# .x file, but alex runs in an action of its own, before the compile. A
# module runs a build tool in one of two ways:
#
# - GHC runs a program for it that GHC finds on PATH. An example is a
#   preprocessor that the module's OPTIONS_GHC pragma names with -F -pgmF,
#   such as hspec-discover. The target's flags can name one too, for all of
#   its modules. The deps tool reports these programs by name, and the
#   module's tools are the target's build tools of those names.
# - A splice of the module runs a program. Nothing can tell which programs
#   a splice runs, so a module that runs Template Haskell is taken to need
#   all its target's build tools.
#
# A module's compile has only its own tools on PATH, and so a change to a
# build tool recompiles only the modules that may run it. A Template Haskell
# module may also need environment variables for the libraries its splices
# run: their data dirs (see Note [Data files of splices]), and the
# directories of their native libraries on LD_LIBRARY_PATH (see Note
# [Template Haskell modules], section 4).
#
# A module with any tools is compiled without a worker, by its own `ghc -c`.
# Giving each such target a worker of its own, running in the target's
# environment, would compile them faster. But each of those
# workers would keep its memory until the end of the build, and there may be
# dozens of them.
#
# 5. The import path
#
# A session finds the modules that a compile imports by looking up their
# names on an import path. The import path is a tree that holds just the
# target's sources. The project's source directories won't do, because they
# can hold modules of other targets too, such as a sublibrary's, and the
# session could find one of those instead of the target's own module of the
# same name.
#
# 6. Memory and concurrency
#
# A worker lives for one build. It drops a target's sessions once all the
# target's modules are compiled. It also keeps a bounded number of sessions,
# dropping the least recently used idle ones (see Note [Dropping the idle
# sessions] in prelude/haskell/tools/worker/src/Worker.hs). It has no concurrency
# limit of its own. buck2's -j already limits the actions that run in workers,
# along with all the others, and a lower limit for each worker would only hold
# back a target's modules.

# Note [Data files of splices]
#
# A package's Paths_<pkg> module finds the package's data files by reading
# the environment variable <pkg>_datadir. The variable's value comes from
# the target's data_dirs attribute (see data_dirs_env). If a splice runs
# code that reads data files, the compile that runs the splice has to set
# these variables.
#
# A module whose compile needs any of these variables can't compile in the
# worker (see the last paragraph). In a large project nearly every target
# has some data dirs, so setting all of them for every Template Haskell
# module would keep most of those modules out of the worker. Instead, each
# Template Haskell module gets only the variables that its splices could
# read.
#
# Working those out relies on two facts. First, a splice can only run code
# from the libraries in its splice set, and from the target's own modules
# that the module imports, directly or indirectly (see Note [Template
# Haskell modules], section 6). Second, code can only read the data files
# of its own package, and it does that through the package's Paths_<pkg>
# module. So a module needs <pkg>_datadir only if one of the libraries in
# its splice set has a Paths_<pkg> module, or if it imports a Paths_<pkg>
# module of its own target. Each library records the data dirs that its
# own Paths_<pkg> modules read (see own_data_dirs in compile.bzl), and most
# Template Haskell modules need none of them. A --make compile works out
# its variables in the same way, but for the whole target. Its splices can
# run code of any of the target's modules, so it includes all the target's
# own Paths_<pkg> modules. compile_data_dirs in compile.bzl does this for
# both kinds of compile.
#
# Build tools are an exception. A build tool might read data files of its
# own, and we can't tell which. So a module that might run one of the
# target's build tools gets all the target's data dirs. A --make compile
# of a target that has any build tools does too.
#
# A module that needs data dirs gets them in its request, as
# --data-dir=VAR=DIR, and they are inputs of its compile. The compile tool
# sets the variables for `ghc -c`, which runs the splices in its own
# process. The worker can't do that, because all its sessions share one
# environment. So a module that needs data dirs compiles outside the
# worker.
