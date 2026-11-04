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
    "HaskellLibraryProvider",
    "HaskellModuleFiles",
)
load(
    "@prelude//haskell:link_info.bzl",
    "HaskellLinkInfo",
)
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
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

# A module's closure set: the interface files of its closure (see Note
# [Per-module compilation]), as a transitive set. The module's own files are
# the set's value, and the closure sets of the modules it imports are its
# children. A target passes its modules' closure sets on to its dependents
# (PerModuleClosures), so no target has to list a whole closure.
def _interfaces(files: HaskellModuleFiles):
    return [files.hi, files.abi] + ([files.dyn_hi] if files.dyn_hi != None else [])

_ModuleClosureTSet = transitive_set(args_projections = {"interfaces": _interfaces})

# A target's modules' closure sets, by node (see _nodes).
PerModuleClosures = provider(fields = {"by_module": provider_field(dict)})

# The package db flags of a per-module compile against the given libraries
# (all its dependencies, direct and transitive), and the inputs they need.
# See Note [Libraries of the early package dbs].
#
# A prebuilt dependency, or a local one named in `final`, is on its final
# db. Every other local dependency is on a db that names no library, so the
# compile doesn't wait for its library:
#
# - A dependency compiled per-module is on its early db. That needs no
#   inputs: the compile declares the interfaces it imports itself.
# - A dependency built with --make is on its library-less db, and needs its
#   interface directories.
#
# A module that runs Template Haskell (`runs_th`) also needs the libraries
# of its final dbs, which the interpreter loads. `below_make` names the
# dependencies compiled per-module that some dependency built with --make
# depends on.
#
# This also runs in the dynamic output, for the modules that choose their
# own final dbs, so it takes the libraries rather than an analysis context.
def _package_dbs(libs: list, final: dict[str, bool], below_make: dict[str, bool], import_dirs_tag, runs_th: bool):
    packagedb_args = cmd_args()
    packagedb_set = {}
    local_import_dirs = []
    early_names = {}
    for lib in libs:
        library_less = lib.early_db != None and lib.name not in final
        if library_less and lib.modules != None:
            packagedb_set[lib.early_db] = None
            early_names[lib.name] = True
            if lib.name in below_make:
                # A library built with --make depends on this one, and its
                # interfaces refer to this one's: see Note [Compiling against
                # dependencies module by module].
                packagedb_args.add(import_dirs_tag.tag_artifacts(cmd_args(hidden = list(lib.import_dirs.values()))))
            continue
        packagedb_set[lib.early_db if library_less else lib.db] = None
        import_dirs = list(lib.import_dirs.values())
        local_import_dirs += [(lib.name, d) for d in import_dirs if not d.is_source]
        # The interfaces a compile reads go in its dep file, but the
        # libraries a Template Haskell module loads don't (see Note [Template
        # Haskell modules]), so those are plain inputs. A module that runs no
        # Template Haskell loads none, so it doesn't wait for them to be
        # linked.
        packagedb_args.add(cmd_args(hidden = [
            lib.stub_dirs,
            import_dirs_tag.tag_artifacts(cmd_args(hidden = import_dirs)),
            lib.libs if runs_th and not library_less else [],
            lib.native_libs_dir if runs_th and not library_less and lib.native_libs_dir != None else [],
        ]))

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])
    return struct(packagedb_args = packagedb_args, local_import_dirs = local_import_dirs, early_names = early_names)

# The suffix of a boot file's node (its srcs key), and of its outputs.
_BOOT = "-boot"

def _is_boot(node: str) -> bool:
    return node.endswith(_BOOT)

def _module_of(node: str) -> str:
    return node[:-len(_BOOT)] if _is_boot(node) else node

# A node's file with the given extension, relative to an output
# directory: Foo/Bar.dyn_hi, or Foo/Bar.dyn_hi-boot for a boot file.
def _node_file(node: str, ext: str) -> str:
    return module_name_to_file(_module_of(node), ext + (_BOOT if _is_boot(node) else ""))

# A path's stem and extension: src/Foo.hs-boot gives src/Foo and
# hs-boot.
def _split_ext(path: str) -> (str, str):
    dot = path.rfind(".")
    if dot < 0 or "/" in path[dot:]:
        return path, ""
    return path[:dot], path[dot + 1:]

# The directory of a target's per-module compile in one way, relative to the
# target's outputs. The modules' outputs are below it, in per_module_out_dir.
def per_module_dir(link_style: LinkStyle, enable_profiling: bool) -> str:
    return "per-module-" + get_artifact_suffix(link_style, enable_profiling) + "/"

# The directory of the outputs of a target's modules in one way, relative to
# the target's outputs. Every module's compile has it on its import path,
# and dependents find it through the target's early package db.
#
# It is named after the target's set of modules. buck2 doesn't delete the
# outputs of an action that no longer exists, so if a module moved to another
# target, GHC would still find its old interface here. A new set of modules
# gets a fresh directory instead. The cost is that adding, removing or
# renaming a module compiles the whole target again.
def per_module_out_dir(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool) -> str:
    names = " ".join(sorted([n for n, _ in _nodes(ctx)]))
    return per_module_dir(link_style, enable_profiling) + "out-" + str(hash(names) & 0xffffffff)

# The directory that a node's file (`artifact`, with extension `ext`) is
# in, less the module's own path: for Foo/Bar.hi, the directory that Foo
# is in.
def _dir_of(artifact, node: str, ext: str) -> cmd_args:
    return cmd_args(artifact, parent = _node_file(node, ext).count("/") + 1)

# From the deps tool's output (see tools/ghc-api/PerModuleDeps.hs), for each
# node:
#
# - imports: its imports among the target's nodes.
# - upstream: the (package id, module) pairs it imports from dependencies
#   compiled per-module.
# - made: the pairs it imports from local dependencies built with --make, for
#   explicit level imports (see eli_packages).
#
# And the nodes that may run Template Haskell, and for each node with
# explicit level imports, the modules it imports at the splice level.
# `make_names` are the names of the local dependencies built with --make.
def _read_deps(label, deps: dict, nodes: list, module_libs: dict, make_names: dict[str, bool]):
    imports = {n: [] for n, _ in nodes}
    upstream = {n: [] for n, _ in nodes}
    made = {n: [] for n, _ in nodes}
    th = {}
    splice_imports = {}
    for n, d in deps.items():
        if n not in imports:
            fail("{}: GHC's dependency analysis found {}, but srcs has no such module (or boot file)".format(label, n))
        imports[n] = d["imports"]
        for pkg, mod in d["external"]:
            lib = module_libs.get(pkg)
            if lib != None and mod in lib.modules and (pkg, mod) not in upstream[n]:
                upstream[n].append((pkg, mod))
            elif pkg in make_names and (pkg, mod) not in made[n]:
                made[n].append((pkg, mod))
        if d["th"]:
            th[n] = True
        if "splice" in d:
            splice_imports[n] = d["splice"]
    return imports, upstream, made, th, splice_imports

# Each node's transitive imports, direct ones first. `order` is
# dependency order, so each import's closure is done before its
# importers' are.
def _transitive_closure(order: list[str], imports: dict) -> dict:
    closure = {}
    for n in order:
        c = {d: True for d in imports[n]}
        for d in imports[n]:
            for x in closure[d]:
                c[x] = True
        closure[n] = list(c)
    return closure

# The nodes in dependency order, and the nodes in or behind a cycle.
# Kahn's algorithm: Starlark has no while loop, so we loop over the order
# as it grows.
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

# The package ids whose final dbs a Template Haskell module may compile
# against, depending on which direct dependencies its splices run code from
# (see Note [Template Haskell modules]):
#
# - closures: maps the package id of each direct local dependency (compiled
#   per-module, or built with --make) to the package ids of its closure. A
#   module that uses the dependency's final db uses the final dbs of its
#   whole closure, since its library was linked against theirs (see Note
#   [Libraries of the early package dbs]).
# - labels: maps the target of each of those dependencies to its package
#   id.
# - base: the package ids of the prebuilt dependencies and their closures,
#   whose final dbs every Template Haskell module gets.
def _splice_deps(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool):
    closures = {}
    labels = {}
    base_infos = []

    def link_info(d):
        link = d.get(HaskellLinkInfo)
        if link == None:
            return None
        return link.prof_info[link_style] if enable_profiling else link.info[link_style]

    for d in attr_deps(ctx) + ctx.attrs.template_deps:
        provider = d.get(HaskellLibraryProvider)
        lib = (provider.prof_lib if enable_profiling else provider.lib)[link_style] if provider != None else None
        info = link_info(d)
        if lib == None or lib.early_db == None:
            if info != None:
                base_infos.append(info)
            continue
        labels[d.label.raw_target()] = lib.name
        closures[lib.name] = [l.name for l in ctx.actions.tset(HaskellLibraryInfoTSet, children = [info] if info != None else []).traverse()]
    base = [l.name for l in ctx.actions.tset(HaskellLibraryInfoTSet, children = base_infos).traverse()]
    return struct(closures = closures, labels = labels, base = base)

# The final dbs of a Template Haskell module whose splices run code from
# the given local dependencies (by package id). Every prebuilt dependency
# is included too.
def _splice_set(splice_deps, names: list[str]):
    final = {n: True for n in splice_deps.base}
    for name in names:
        # A package that isn't a direct dependency (one whose module a
        # dependency re-exports) brings in every direct dependency whose
        # closure includes it.
        via = [name] if name in splice_deps.closures else [d for d in sorted(splice_deps.closures.keys()) if name in splice_deps.closures[d]]
        for d in via:
            for n in splice_deps.closures[d]:
                final[n] = True
    return final

# The final dbs of the target's Template Haskell modules: those of all its
# local dependencies, or only of the ones that th_build_depends lists, if
# the target has it (see _splice_set).
def _th_set(ctx: AnalysisContext, splice_deps):
    th_deps = getattr(ctx.attrs, "th_build_depends", None)
    if th_deps == None:
        return _splice_set(splice_deps, sorted(splice_deps.closures.keys()))
    names = []
    deps = {d.label.raw_target(): True for d in attr_deps(ctx) + ctx.attrs.template_deps}
    for d in th_deps:
        t = d.label.raw_target()
        if t not in deps:
            fail("{}: th_build_depends names {}, which is not a dependency".format(ctx.label.raw_target(), t))
        if t in splice_deps.labels:
            names.append(splice_deps.labels[t])
    return _splice_set(splice_deps, names)

# The nodes of a target's module graph, each with its source: the
# modules, and their boot files as "<module>-boot". In a srcs dict a boot
# file has that key already; in a list it has its module's name.
def _nodes(ctx: AnalysisContext) -> list:
    nodes = []
    for name, src in srcs_to_pairs(ctx.attrs.srcs):
        if is_haskell_src(src):
            nodes.append((name, src))
        elif src.short_path.endswith(_BOOT):
            nodes.append((name if _is_boot(name) else name + _BOOT, src))
    return nodes

# Each node's outputs, all in the output directory (so not at
# content-based paths: see per_module_out_dir). They're declared here,
# outside the dynamic output, so that the target can export them, as
# well as the directories built from them.
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

# The persistent worker for a target's compile actions (see Note [The
# persistent worker]). That's the worker the target names
# (per_module_worker), or else the toolchain's shared one. It's None if
# there's no worker, or if the target has a build tool that isn't on the
# worker's PATH (see per_module_worker_build_tools).
def _per_module_worker(ctx: AnalysisContext) -> WorkerInfo | None:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    shared_tools = haskell_toolchain.per_module_worker_build_tools
    if any([t.label.raw_target() not in shared_tools for t in ctx.attrs.build_tool_depends]):
        return None
    own_worker = getattr(ctx.attrs, "per_module_worker", None)
    return own_worker[WorkerInfo] if own_worker != None else haskell_toolchain.per_module_shared_worker

# The version of the request that the worker takes (as does the per-module
# compile tool), and of what the worker writes back. The worker refuses a
# request of any other version. When either changes, bump this and the
# worker's version in tools/ghc-worker/src/Contract.hs.
_WORKER_CONTRACT = "3"

# Once the target's module graph is known, this registers a compile action
# for each node, and makes its modules' closure sets for its dependents
# (see _ModuleClosureTSet). `s` holds compile_per_module's values.
def _register_modules_impl(actions: AnalysisActions, s: typing.Any, deps: ArtifactValue, dep_closures: dict, artifacts: list[Artifact], outputs: list[OutputArtifact]) -> list[Provider]:
    out = {a: o for a, o in zip(artifacts, outputs)}
    nodes = s.nodes
    src_of = s.src_of
    modules = s.modules
    module_libs = s.module_libs
    module_lib_dirs = s.module_lib_dirs
    splice_deps = s.splice_deps
    packages = s.packages
    early_set = s.early_set
    target_th = s.target_th
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
    src_tree = s.src_tree
    base_cmd = s.base_cmd
    env = s.env
    worker_info = s.worker_info
    compile_script = s.compile_script

    imports, upstream, made, th_nodes, splice_imports = _read_deps(s.label, deps.read_json(), nodes, module_libs, s.make_names)
    order, left = _dependency_order(nodes, imports)
    if left:
        fail("{}: import cycle among {}".format(s.label, ", ".join(left)))
    closure = _transitive_closure(order, imports)

    # Each node's closure set. Also the interfaces that a node's compile may
    # read from dependencies compiled per-module: the closure sets of the
    # modules that the node, or anything it imports from this target,
    # imports from those dependencies.
    dep_closure_sets = {name: dv.providers[PerModuleClosures].by_module for name, dv in dep_closures.items()}
    closure_sets = {}
    upstream_closure_sets = {}
    for n in order:
        ups = [dep_closure_sets[pkg][mod] for pkg, mod in upstream[n] if mod in dep_closure_sets.get(pkg, {})]
        upstream_closure_sets[n] = actions.tset(_ModuleClosureTSet, children = [upstream_closure_sets[i] for i in imports[n]] + ups)
        closure_sets[n] = actions.tset(_ModuleClosureTSet, value = modules[n], children = [closure_sets[i] for i in imports[n]] + ups)

    runs_th = {n: n in th_nodes for n, _ in nodes}

    # The package flags of a module with explicit level imports. It gets the
    # final dbs of the packages whose modules it imports at the splice level
    # (and of their closures), and dbs that name no library for the rest.
    # Modules that import from the same packages share their flags.
    eli_sets = {}

    def eli_packages(n):
        pkgs = {}
        for m in splice_imports[n]:
            if m in src_of:
                fail("{}: {} imports {} at the splice level, but with per_module a splice can't run code of its own target (see Note [Template Haskell modules]): build the target with per_module = False".format(s.label, _module_of(n), m))
            for pkg, mod in upstream[n] + made[n]:
                if mod == m:
                    pkgs[pkg] = True
        names = sorted(pkgs.keys())
        key = " ".join(names)
        if key not in eli_sets:
            eli_sets[key] = packages(_splice_set(splice_deps, names))
        return eli_sets[key]

    # In dependency order, since an action's inputs, and the artifacts a
    # symlinked_dir links, must be outputs of actions already registered.
    hie_of = {}
    for n in order:
        # A module finds its imports from this target in the output
        # directory they all share, and has its closure's files as tagged
        # inputs. We tried a symlink tree per module, but that took longer
        # to materialise than the compiles themselves.
        closure_files = []
        for d in closure[n]:
            closure_files += [hi_of[d], abi_of[d]]
            if dynamic_too:
                closure_files.append(dyn_hi_of[d])
        if not runs_th[n]:
            mod_packages = early_set
        elif n in splice_imports:
            mod_packages = eli_packages(n)
        else:
            mod_packages = target_th
        hidirs = mod_packages.local_import_dirs + [(name, d) for name, d in module_lib_dirs.items() if name in mod_packages.early_names]

        # The module's own flags, which come after the target's.
        stubdir = actions.declare_output(prefix + "stubs/" + n, dir = True, has_content_based_path = False)
        module_flags = cmd_args("-c", src_of[n], "-o", out[o_of[n]], "-ohi", out[hi_of[n]], "-stubdir", stubdir.as_output())
        mkdirs = [stubdir.as_output()]
        if closure[n]:
            module_flags.add(tag.tag_artifacts(cmd_args(_dir_of(hi_of[closure[n][0]], closure[n][0], hisuf), hidden = closure_files, format = "-i{}")))
        # The interfaces it may read from dependencies compiled per-module. (A
        # Template Haskell module also gets those of the dependencies whose
        # final dbs it compiles against, through those dbs.)
        module_flags.add(tag.tag_artifacts(cmd_args(hidden = upstream_closure_sets[n].project_as_args("interfaces"))))
        if dynamic_too:
            module_flags.add("-dyno", out[dyn_o_of[n]], "-dynohi", out[dyn_hi_of[n]])
        if producing_indices:
            # The module's .hie file, which GHC writes below -hiedir at the
            # module's path. The target's index (its hi directory) includes
            # it, as --make's does.
            hie_of[n] = actions.declare_output(prefix + "hie/" + n + "/" + _node_file(n, "hie"), has_content_based_path = False)
            module_flags.add("-hiedir", _dir_of(hie_of[n].as_output(), n, "hie"))

        # The request goes to the worker if there is one, or else to the
        # compile tool: see Note [The persistent worker].
        depfile = actions.declare_output(prefix + "dep/" + n + ".dep", has_content_based_path = False)
        request = cmd_args(
            "--request",
            "--contract",
            _WORKER_CONTRACT,
            "--depfile",
            tag.tag_artifacts(depfile.as_output()),
            "--abi",
            out[abi_of[n]],
            "--module",
            _module_of(n).replace(".", "/"),
            "--source",
            src_of[n],
            "--outdir",
            _dir_of(out[hi_of[n]], n, hisuf),
            "--hisuf",
            hisuf,
            "--unit",
            s.unit,
            "--boot" if _is_boot(n) else [],
            # Paths only, not inputs: the interfaces the module reads are
            # inputs already (upstream_closure_sets, and the import
            # directories of --make libraries, with the package dbs). A
            # dependency compiled per-module is given by the directory of one
            # of its interfaces, which as an input would make the module wait
            # for that interface.
            [cmd_args(d, format = "--hidir=" + unit + "={}", ignore_artifacts = True) for unit, d in hidirs],
            tag.tag_artifacts(cmd_args(src_tree, format = "--srcroot={}")) if src_tree != None else [],
            cmd_args(mkdirs, format = "--mkdir={}"),
            "--",
            base_cmd,
            mod_packages.args,
            "--",
            module_flags,
        )
        # The compile tool, which runs the request as one `ghc -c`.
        script = in_env(env, cmd_args(compile_script))
        category = "haskell_compile_module_" + suffix.replace("-", "_")
        if worker_info != None:
            actions.run(request, exe = WorkerRunInfo(worker = worker_info, exe = script), category = category, identifier = n, dep_files = {"hs": tag})
        else:
            actions.run(cmd_args(script, request), category = category, identifier = n, dep_files = {"hs": tag})

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
    # Empty: each module writes its stubs (the _stub.h of its foreign
    # exports) to a directory of its own. A target's stubs directory is only
    # ever an input, with --make too, so an empty one will do.
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

# Whether the target is compiled per-module: it has `per_module = True`, and
# modules to compile (compile() makes the empty outputs of a target without
# any).
def compiles_per_module(ctx: AnalysisContext) -> bool:
    return getattr(ctx.attrs, "per_module", False) and has_modules(ctx)

# Compile the context's sources with one action per module: see Note
# [Per-module compilation]. Takes compile()'s arguments.
# native_shared_libs_dir goes unused, since a splice finds the native
# libraries it loads through the package dbs (see _native_ghci_libs in
# haskell.bzl). dynamic_from goes unused, since a splice can't run code of
# its own target (see Note [Template Haskell modules]).
def compile_per_module(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None = None, native_shared_libs_dir: [Artifact, None] = None, dynamic_too: bool = False, dynamic_from: [CompileResultInfo, None] = None) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    suffix = get_artifact_suffix(link_style, enable_profiling)
    osuf, hisuf = output_extensions(link_style, enable_profiling)
    prefix = per_module_dir(link_style, enable_profiling)

    # The tag of every input a module's dep file may list: see Note [Early
    # cut-off by dep files].
    tag = ctx.actions.artifact_tag()

    # A module's package flags (see _package_dbs): the final dbs of the
    # local dependencies in `final` and of the prebuilt ones, and dbs that
    # name no library for the other local ones. A module that runs no
    # Template Haskell compiles against no local library.
    dep_libs = list(dependency_libs(ctx, link_style, enable_profiling).traverse())
    exposed_package_args = get_exposed_package_args(ctx, link_style, False, enable_profiling)

    # The dependencies compiled per-module that a dependency built with
    # --make depends on.
    below = ctx.actions.tset(HaskellLibraryInfoTSet, children = [lib.below for lib in dep_libs if lib.below != None])
    below_make = {lib.name: True for lib in below.traverse() if lib.modules != None}

    def packages(final, runs_th = True):
        dbs = _package_dbs(dep_libs, final, below_make, tag, runs_th)
        return struct(
            # A splice runs in an interpreter process of its own: see Note
            # [Template Haskell modules].
            args = cmd_args(exposed_package_args, dbs.packagedb_args, ["-fexternal-interpreter"] if runs_th else []),
            local_import_dirs = dbs.local_import_dirs,
            early_names = dbs.early_names,
        )

    early_set = packages({}, runs_th = False)

    # Only the Template Haskell modules' actions depend on the libraries:
    # they load them, so they have to wait for them to be linked. A module
    # with explicit level imports chooses its own libraries (see Note
    # [Explicit level imports]), and the others take the target's.
    splice_deps = _splice_deps(ctx, link_style, enable_profiling)
    target_th = packages(_th_set(ctx, splice_deps))
    module_libs = {lib.name: lib for lib in dep_libs if lib.modules != None}
    this_pkg = pkgname or haskell_library_unit_id(ctx.label)

    # A binary's modules also get a unit named after the target, rather than
    # GHC's default `main`. A persistent worker runs the splices of many
    # targets in one process, and its runtime would confuse two targets'
    # modules with the same unit and name.
    cmd_flags, file_flags = ghc_flags(ctx, link_style, enable_profiling, this_pkg, dynamic_too)
    # The target's other sources (headers a module #includes, say), whose
    # use GHC doesn't record: plain inputs of every compile, as with --make.
    other_srcs = [src for _, src in srcs_to_pairs(ctx.attrs.srcs) if not is_haskell_src(src) and not src.short_path.endswith(_BOOT)]
    ghc_args = cmd_args(cmd_flags, file_flags, hidden = other_srcs)
    base_cmd = cmd_args(haskell_toolchain.compiler, ghc_args)
    env = ghc_env(ctx, prefix + "build-tool-depends")

    worker_info = _per_module_worker(ctx)

    nodes = _nodes(ctx)
    src_of = {n: src for n, src in nodes}

    # A tree of the target's sources, which is the worker's import path (see
    # Note [The persistent worker]). It's a tagged input: the tree changes
    # with any of the target's sources, which is no reason to compile the
    # other modules again. A module's own source is an ordinary input anyway.
    src_tree = None
    if worker_info != None:
        src_tree = ctx.actions.symlinked_dir(
            prefix + "srcs",
            # Each source keeps its extension: .lhs, say, is literate.
            {_module_of(n).replace(".", "/") + "." + _split_ext(src.short_path)[1]: src for n, src in nodes},
            has_content_based_path = False,
        )

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

    # The module graph, from GHC's own dependency analysis (see
    # tools/ghc-api/PerModuleDeps.hs): each node's imports, from the target
    # and from dependencies, whether it may run Template Haskell, and what it
    # imports at the splice level. It runs against the early dbs, so it needs
    # nothing built. The tool gets each node with its source, and the GHC
    # flags without the compiler, since the analysis is its own.
    deps = ctx.actions.declare_output(prefix + "deps.json")
    ctx.actions.run(
        in_env(env, cmd_args(
            ctx.attrs._per_module_deps[RunInfo],
            deps.as_output(),
            [cmd_args(n, src, delimiter = "=") for n, src in nodes],
            "--",
            ghc_args,
            early_set.args,
        )),
        category = "haskell_deps_" + suffix.replace("-", "_"),
    )

    # The output directory of each dependency compiled per-module, where the
    # compile tool looks up its interfaces. (Each such dependency has a
    # module: compile() handles a target with none, and leaves its `modules`
    # None.)
    def out_dir_of(lib):
        m, files = list(lib.modules.items())[0]
        return _dir_of(files.hi, m, hisuf)

    module_lib_dirs = {name: out_dir_of(lib) for name, lib in module_libs.items()}

    # The local dependencies built with --make, whose modules a module may
    # import at the splice level.
    make_names = {lib.name: True for lib in dep_libs if lib.modules == None and lib.early_db != None}

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
            unit = this_pkg,
            compile_script = ctx.attrs._per_module_compile[RunInfo],
            nodes = nodes,
            src_of = src_of,
            modules = modules,
            module_libs = module_libs,
            module_lib_dirs = module_lib_dirs,
            make_names = make_names,
            splice_deps = splice_deps,
            packages = packages,
            early_set = early_set,
            target_th = target_th,
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
            src_tree = src_tree,
            base_cmd = base_cmd,
            env = env,
            worker_info = worker_info,
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
# `early` argument of _make_package in haskell.bzl). It is registered before
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
# A dependency built with --make breaks that chain. Say D's module Y is
# compiled per-module, and M, built with --make, imports it. M's interfaces
# refer to Y's, which GHC reads whenever it reads M's, but no closure lists
# Y for a module that imports M. So every compile gets the final interface
# directories of the libraries compiled per-module below a --make one
# (below_make), as tagged inputs. That doesn't make anything wait longer: a
# compile already waits for M's interfaces, and M waits for all of D.

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
#   the interface itself (DepFile in tools/ghc-api, which the compile tool
#   and the persistent worker share).
# - Each file a Template Haskell splice read, which GHC records as a
#   dependent file (addDependentFile). (The libraries the splices loaded are
#   plain inputs instead: see Note [Template Haskell modules].)
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
# By default, a Template Haskell module compiles against the final package
# dbs of all its dependencies, with their libraries and the native
# libraries they depend on as inputs. So it waits for all of them to be
# linked, as a --make compile does. Two things narrow that:
#
# - th_build_depends: the target lists the local dependencies, compiled
#   per-module or built with --make, whose code its splices need (see
#   _th_set). Its Template Haskell modules then wait only for the libraries
#   of those (and of their own dependencies), and compile against dbs that
#   name no library for the rest, like any other module. Prebuilt
#   dependencies are always included: their libraries are there from the
#   start.
# - Explicit level imports: a module that uses them chooses its own
#   libraries, whatever th_build_depends says. See Note [Explicit level
#   imports].
#
# Note [Libraries of the early package dbs] has a table of which package db
# a compile gets for each dependency. If a splice runs code from a
# dependency that was left out, the compile fails and names the symbol it
# couldn't load, and the compile suggests th_build_depends.
#
# 3. Why the libraries aren't in the dep file
#
# The libraries are plain inputs of the compile, not tagged inputs that its
# dep file lists, so the module compiles again whenever one of them is
# relinked. The dep file can't list them. GHC records in the interface the
# Haskell libraries (hs-libraries) that a splice loaded, but a package db
# here names its library as one of its extra-libraries. So a splice that
# ran a _dependency's_ code leaves no trace of that library in the
# interface, but we do want a change to that code to compile the module
# again.
#
# 4. Native libraries
#
# A library that buck2 links refers to the native libraries it was linked
# against by soname, but it has no RUNPATH to find them, and a compile has
# nothing on LD_LIBRARY_PATH. So when a splice loads such a library, the
# dynamic loader can't find the libraries it needs, and the splice fails.
#
# Instead, a package db lists the native libraries that its library depends
# on in extra-ghci-libraries, which only GHC's interpreter reads (see
# _native_ghci_libs in haskell.bzl). They come in dependency order, before
# the package's own library, and the db gives the directory they are in.
# GHC loads them by path in that order, so each library finds the ones it
# needs already loaded. The directory is in both library-dirs and
# dynamic-library-dirs, since the interpreter is of the compile's way, and
# only a dynamic one reads dynamic-library-dirs.
#
# So a compile needs nothing in its environment. That is what lets the
# persistent worker compile Template Haskell modules, since its environment
# can't change between requests.
#
# Loading the native libraries this way relies on three things:
#
# - GHC loads a package's dependencies first, and a package's libraries in
#   the order its db lists them. (GHC 9.6 loads hs-libraries before extra
#   ones, so the rules list a package's own library as an extra one.)
# - The dynamic loader reuses a library already loaded under the soname it
#   is looking for.
# - buck2's graph of native libraries matches what each was linked against.
#
# GHC looks up a library named foo as libfoo.so, so the directory has each
# library under that name, or under its whole soname if the soname isn't of
# that form (libfoo.so.1, say). A library whose soname is only known once
# it's built can't be named, and a library that depends on it fails to
# load, saying so.
#
# This only works for ELF libraries and a GNU linker. Elsewhere the package
# dbs name no native libraries. On macOS, the libraries would need to be
# named as GHC looks them up there (libfoo.dylib), and a library would need
# to find a dependency that is already loaded by its install name
# (@rpath/libfoo.dylib). We haven't tried that.
#
# The road not taken: a tree of the dependencies' shared libraries on each
# Template Haskell compile's LD_LIBRARY_PATH. That needs nothing in the
# package dbs and copes with any soname. But the persistent worker can't
# change its environment for each compile, so each of those modules would
# need a `ghc -c` of its own. That is the slowest kind of compile, and it
# would fall on the targets that run the most splices. It remains an option
# for a library the dbs can't name, or for a platform whose loader doesn't
# reuse a loaded library by its soname (macOS matches install names
# instead, and hasn't been tried).
#
# 5. The external interpreter
#
# Splices run in an external interpreter (-fexternal-interpreter) of the
# compile's way (ghc-iserv, ghc-iserv-prof or ghc-iserv-dyn). There is one
# for each `ghc -c`, or one for each session of the persistent worker (see
# Note [The persistent worker]). The libraries a splice loads stay in that
# process. If splices ran in the worker's own process, which every target's
# sessions share:
#
# - A splice could run a library that another target's splice had loaded,
#   without having it as an input: a dependency left out of th_build_depends
#   would go unnoticed, and the module would go stale when the library
#   changed.
# - A library built in two configurations (a build tool's and a target's)
#   has the same unit id and soname in both, so a splice of one
#   configuration could run the other's.
# - One splice's crash, or a library's global state, would reach the
#   others.
#
# The cost is a process for each session that runs Template Haskell, and the
# time to send code and values to it. Before GHC 9.12, GHC doesn't lock the
# interpreter, so the worker lets only one compile of a session use it at a
# time (see interpreterLock in the worker). So with those GHCs, a target's
# Template Haskell modules, which share a session, compile one at a time in
# the worker.
#
# 6. Code of the target's own modules
#
# A splice can't run code of the target's own modules. GHC would load their
# objects from the output directory, so they would have to be inputs of the
# compile, along with the modules behind any boot files among them. A
# target whose splices need that is built with per_module = False instead.
# The compile fails if a splice loaded one of the target's objects (see
# DepFile in tools/ghc-api), and the analysis fails if a module imports one
# of the target's modules at the splice level (see Note [Explicit level
# imports]).
#
# 7. Finding the Template Haskell modules
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
# A dynamically linked GHC tolerates a missing library file: it warns, or
# says nothing, and carries on. But a library that is there, and was linked
# against one that _isn't_, fails to load in the system's dynamic linker,
# and then the compile fails. buck2 doesn't sandbox local actions, so a
# library that a compile doesn't declare as an input may or may not be on
# disk. It may not be linked yet, or not materialised, even if one next to
# it is.
#
# 2. The solution
#
# Every package db that a compile gets either names no library, or names
# one that the compile depends on. For each local dependency, a compile
# gets either a db that names no library (the early db of one compiled
# per-module, or the library-less db of one built with --make), or its
# final db, which names the library and brings it as an input of the
# compile. A prebuilt dependency's library exists before the build starts,
# so a compile always gets its final db:
#
#                                 local dependency         prebuilt
#                                 (per-module, --make)     dependency
#   module that runs no TH        no library               final
#   TH module                     final                    final
#   TH module, th_build_depends   final if listed,         final
#                                 else no library
#   TH module, explicit level     final if its splice      final
#   imports                       imports need it,
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
# - A module of the target itself is an error, since splices can't run code
#   of their own target (see Note [Template Haskell modules]).
#
# A module with explicit level imports compiles against the final dbs of
# those dependencies and of the prebuilt ones, whatever th_build_depends
# says. It gets dbs that name no library for the other local dependencies.
# So each module can have different libraries. This works for dependencies
# built with --make too, since GHC's dependency analysis says which
# dependency any imported module comes from.
#
# 2. Finding the splice imports
#
# The deps tool takes the levels from GHC's summary of each module, whose
# imports carry them from GHC 9.14, and whether the module has explicit
# level imports from its extensions (its pragmas and the target's flags).

# Note [The persistent worker]
#
# 1. The problem
#
# Most of what compiling per-module costs over --make is starting a GHC for
# every module, which reads the interfaces of the module's imports all over
# again.
#
# 2. The solution
#
# A buck2 persistent worker is a long-running process that buck2 sends
# actions to. Ours (tools/ghc-worker) compiles each module as it arrives,
# concurrently with the others, in a GHC session that keeps the interfaces
# it has read. It is configured by `[haskell] per_module_worker` (see
# toolchains/per_module_worker.bzl).
#
# 3. The request
#
# A module's action sends the same request with or without a worker. It
# goes either to the worker, or to the compile tool, which runs it as one
# `ghc -c`. The request has the module's source and the compile's flags,
# which come in two parts:
#
# - The session flags, shared by all the target's modules. The worker keeps
#   a session for each set of session flags. A target's Template Haskell
#   modules have session flags of their own, since their package dbs differ
#   (see Note [Libraries of the early package dbs]).
# - The module's own flags, of which the worker takes only the outputs: -o,
#   -ohi, -dyno, -dynohi, -hiedir and -stubdir.
#
# _WORKER_CONTRACT is the version of the request, so that a worker
# installed for another version of the rules refuses it.
#
# 4. Which worker takes a module
#
# buck2 starts a process for each worker (WorkerInfo) that an action names,
# and keeps it until the end of the build. A worker per target would be
# hundreds of processes in a large project, each with its own runtime and
# sessions, which would take far too much memory. So the targets share one
# worker, made once by the toolchain.
#
# A process can't change its environment from one request to the next, so
# the shared worker can only take modules that need nothing from their
# target's environment. Those are the modules of targets whose build tools
# are all on the worker's PATH (see per_module_worker_build_tools in
# toolchains/per_module_worker.bzl). Template Haskell modules need nothing
# from it either (see Note [Template Haskell modules]).
#
# The other modules are compiled without a worker, each by its own
# `ghc -c`. A worker for each such target, in its environment, would compile
# them faster. But each would keep its memory until the end of the build,
# and there may be dozens.
#
# With a local worker (`per_module_worker = local`), the worker is a
# haskell_binary built with the Haskell toolchain, so the toolchain can't
# depend on it without a cycle. Instead the targets name it themselves
# (per_module_worker), through a target that wraps it (see worker.bzl).
#
# 5. The import path
#
# A session finds the modules a compile imports by name, on an import path.
# This is a tree of just the target's sources. In the project's source
# directories, a module of another target (a sublibrary's, say) could be
# found before the current target's.
#
# 6. Memory and concurrency
#
# A worker lives for one build. It drops a target's sessions once all the
# target's modules are compiled. It also keeps a bounded number of sessions,
# dropping the least recently used idle ones (see Note [Dropping the idle
# sessions] in tools/ghc-worker/src/Worker.hs). It has no concurrency limit
# of its own: buck2's -j limits the actions in workers along with all the
# others, and a lower limit per worker would only hold a target's modules
# back.
