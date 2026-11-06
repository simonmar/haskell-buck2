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
#
# A compile never sees a local dependency's library, since libraries are
# only needed for splices, and splices only run code of prebuilt packages
# (see Note [Template Haskell modules]):
#
# - A dependency compiled per-module is on its early db. That needs no
#   inputs: the compile declares the interfaces it imports itself.
# - A dependency built with --make is on its library-less db, and needs its
#   interface directories.
#
# A prebuilt dependency is on its normal db. A module that runs Template
# Haskell (`runs_th`) also needs its libraries, which the interpreter loads.
# `below_make` names the dependencies compiled per-module that some
# dependency built with --make depends on.
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
        # The interfaces a compile reads go in its dep file, but the
        # libraries a Template Haskell module loads don't (see Note [Template
        # Haskell modules]), so those are plain inputs.
        packagedb_args.add(cmd_args(hidden = [
            lib.stub_dirs,
            import_dirs_tag.tag_artifacts(cmd_args(hidden = import_dirs)),
            lib.libs if runs_th and lib.is_prebuilt else [],
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

# The node of a source, from the path that `ghc -M` or the deps script uses
# for it. That's the source's project path, or for a generated source its
# path in buck-out, which ends with the project path. So we match paths
# without their extensions, and take the longest match, since src/Bar is
# also the end of src/Foo/Bar. Sources are never at absolute paths.
def _node_from_path(path: str, by_stem: dict[str, str]) -> str | None:
    if path.startswith("/"):
        return None
    stem, ext = _split_ext(path)
    found = None
    for tail, mod in by_stem.items():
        if (stem == tail or stem.endswith("/" + tail)) and (found == None or len(tail) > len(found[0])):
            found = (tail, mod)
    if found == None:
        return None
    return found[1] + _BOOT if ext.endswith(_BOOT) else found[1]

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

# The dependency compiled per-module that an interface path is below, and
# the path below that dependency's output directory. `lib_by_dir` maps the
# output directories of those dependencies to their names. None for any
# other path.
def _per_module_dep(path: str, lib_by_dir: dict[str, str]) -> (str, str) | None:
    parts = path.split("/")
    for i in range(len(parts) - 1, 0, -1):
        name = lib_by_dir.get("/".join(parts[:i]))
        if name != None:
            return name, "/".join(parts[i:])
    return None

# From `ghc -M` output: each node's imports among the target's nodes, and
# the (package id, module) pairs it imports from dependencies compiled
# per-module.
#
# Each source has a line of its own ("src/Foo.o : src/Foo.hs"), which
# tells us how `ghc -M` printed that module's path. The objects
# and interfaces of the target's modules have the same path with other
# extensions.
def _read_deps_makefile(label, text: str, nodes: list, module_libs: dict, lib_by_dir: dict[str, str]):
    by_stem = {_split_ext(src.short_path)[0]: n for n, src in nodes if not _is_boot(n)}
    lines = []
    exact = {}
    for line in text.splitlines():
        if line.startswith("#") or ":" not in line:
            continue
        lhs, rhs = line.split(":", 1)
        lines.append((lhs.strip(), rhs.strip()))
        stem, ext = _split_ext(rhs.strip())
        if ext in ["hs", "lhs", "hs-boot", "lhs-boot"]:
            n = _node_from_path(rhs.strip(), by_stem)
            if n != None:
                exact[stem] = _module_of(n)

    def node_of(path):
        stem, ext = _split_ext(path)
        mod = exact.get(stem)
        if mod == None:
            return None
        return mod + _BOOT if ext.endswith(_BOOT) else mod

    imports = {n: [] for n, _ in nodes}
    upstream = {n: [] for n, _ in nodes}
    for lhs, rhs in lines:
        tgt = node_of(lhs)
        if tgt == None:
            continue
        # An interface of a dependency compiled per-module. Its path below
        # the dependency's output directory says which module it is. That
        # directory is the one for the way the interfaces were compiled in,
        # which needn't be this target's way: a "shared" library made by a
        # -dynamic-too compile has them in the static way's directory.
        owned = _per_module_dep(rhs, lib_by_dir)
        if owned != None:
            lib = module_libs[owned[0]]
            mod_path = owned[1]
            dot = mod_path.rfind(".")
            ext = mod_path[dot + 1:]
            mod = mod_path[:dot].replace("/", ".") + (_BOOT if ext.endswith(_BOOT) else "")
            if mod in lib.modules and (lib.name, mod) not in upstream[tgt]:
                upstream[tgt].append((lib.name, mod))
            continue
        dep = node_of(rhs)
        if dep == None or tgt == dep:
            # A module's dependency on its own source, or a file that
            # isn't the target's (an interface of a prebuilt dependency or
            # one built with --make, a header, ...).
            continue
        if tgt not in imports or dep not in imports:
            fail("{}: `ghc -M` says {} depends on {}, but srcs has no such module (or boot file)".format(label, tgt, dep))
        if dep not in imports[tgt]:
            imports[tgt].append(dep)
    return imports, upstream

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

# From the deps script's output: the nodes that use Template Haskell (or
# an ANN pragma). Each line is a source's path as the script was given
# it, the same as `ghc -M`'s. A boot file's line is ignored.
def _read_splices(text: str, nodes: list) -> dict[str, bool]:
    by_stem = {_split_ext(src.short_path)[0]: n for n, src in nodes if not _is_boot(n)}
    th = {}
    for line in text.splitlines():
        n = _node_from_path(line.strip(), by_stem) if line.strip() else None
        if n != None and not _is_boot(n):
            th[n] = True
    return th

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

# Once the target's module graph is known, this registers a compile action
# for each node, and makes its modules' closure sets for its dependents
# (see _ModuleClosureTSet). `s` holds compile_per_module's values.
def _register_modules_impl(actions: AnalysisActions, s: typing.Any, deps_mk: ArtifactValue, splices_file: ArtifactValue, lib_dirs: ArtifactValue, dep_closures: dict, artifacts: list[Artifact], outputs: list[OutputArtifact]) -> list[Provider]:
    out = {a: o for a, o in zip(artifacts, outputs)}
    nodes = s.nodes
    src_of = s.src_of
    modules = s.modules
    module_libs = s.module_libs
    module_lib_dirs = s.module_lib_dirs
    th_target = s.th_target
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

    # (write_json writes each directory as a list of one path.)
    lib_by_dir = {d[0]: name for name, d in lib_dirs.read_json().items()}
    imports, upstream = _read_deps_makefile(s.label, deps_mk.read_string(), nodes, module_libs, lib_by_dir)
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

    th_nodes = _read_splices(splices_file.read_string(), nodes)

    runs_th = {n: not _is_boot(n) and (th_target or n in th_nodes) for n, _ in nodes}

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
        mod_packages = th_set if runs_th[n] else early_set
        hidirs = mod_packages.local_import_dirs + [(name, d) for name, d in module_lib_dirs.items() if name in mod_packages.early_names]

        # The module's own flags, which come after the target's.
        stubdir = actions.declare_output(prefix + "stubs/" + n, dir = True, has_content_based_path = False)
        module_flags = cmd_args("-c", src_of[n], "-o", out[o_of[n]], "-ohi", out[hi_of[n]], "-stubdir", stubdir.as_output())
        mkdirs = [stubdir.as_output()]
        module_flags.add("-ddump-hi", "-ddump-to-file", cmd_args(out[abi_of[n]], format = "-ddump-file-prefix={}"))
        if closure[n]:
            module_flags.add(tag.tag_artifacts(cmd_args(_dir_of(hi_of[closure[n][0]], closure[n][0], hisuf), hidden = closure_files, format = "-i{}")))
        # The interfaces it may read from dependencies compiled per-module.
        module_flags.add(tag.tag_artifacts(cmd_args(hidden = upstream_closure_sets[n].project_as_args("interfaces"))))
        if dynamic_too:
            module_flags.add("-dyno", out[dyn_o_of[n]], "-dynohi", out[dyn_hi_of[n]])
        if producing_indices:
            # The module's .hie file, which GHC writes below -hiedir at the
            # module's path. The target's index (its hi directory) includes
            # it, as --make's does.
            hie_of[n] = actions.declare_output(prefix + "hie/" + n + "/" + _node_file(n, "hie"), has_content_based_path = False)
            module_flags.add("-hiedir", _dir_of(hie_of[n].as_output(), n, "hie"))

        # The compile script's request (see the script).
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
            "--unit",
            s.unit,
            # Paths only, not inputs: the interfaces the module reads are
            # inputs already (upstream_closure_sets, and the import
            # directories of --make libraries, with the package dbs). A
            # dependency compiled per-module is given by the directory of one
            # of its interfaces, which as an input would make the module wait
            # for that interface.
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
            allow_cache_upload = s.allow_cache_upload,
            allow_dep_file_cache_upload = s.allow_dep_file_cache_upload,
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
        "deps_mk": dynattrs.artifact_value(),
        "lib_dirs": dynattrs.artifact_value(),
        "outputs": dynattrs.list(dynattrs.output()),
        "s": dynattrs.value(typing.Any),
        "splices_file": dynattrs.artifact_value(),
    },
)

# Whether the target is compiled per-module: it has `per_module = True`, and
# modules to compile (compile() makes the empty outputs of a target without
# any).
def compiles_per_module(ctx: AnalysisContext) -> bool:
    return getattr(ctx.attrs, "per_module", False) and has_modules(ctx)

# Compile the context's sources with one action per module: see Note
# [Per-module compilation]. Takes compile()'s arguments. native_shared_libs_dir
# and dynamic_from go unused, since splices run only prebuilt code (see Note
# [Template Haskell modules]).
def compile_per_module(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None = None, native_shared_libs_dir: [Artifact, None] = None, dynamic_too: bool = False, dynamic_from: [CompileResultInfo, None] = None) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    suffix = get_artifact_suffix(link_style, enable_profiling)
    osuf, hisuf = output_extensions(link_style, enable_profiling)
    prefix = per_module_dir(link_style, enable_profiling)

    # The tag of every input a module's dep file may list: see Note [Early
    # cut-off by dep files].
    tag = ctx.actions.artifact_tag()

    # A module's package flags (see _package_dbs): one set for a module that
    # runs no Template Haskell, and one for a module that does, which loads
    # the prebuilt libraries.
    dep_libs = list(dependency_libs(ctx, link_style, enable_profiling).traverse())
    exposed_package_args = get_exposed_package_args(ctx, link_style, False, enable_profiling)

    # The dependencies compiled per-module that a dependency built with
    # --make depends on.
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

    # The extensions that the target's or the toolchain's flags enable for
    # every module.
    flags = (haskell_toolchain.compiler_flags or []) + ctx.attrs.compiler_flags
    th_target = "-XTemplateHaskell" in flags or "-XQuasiQuotes" in flags
    module_libs = {lib.name: lib for lib in dep_libs if lib.modules != None}
    this_pkg = pkgname or haskell_library_unit_id(ctx.label)

    # A binary's modules also get a unit named after the target, rather than
    # GHC's default `main`, which every binary would share.
    cmd_flags, file_flags = ghc_flags(ctx, link_style, enable_profiling, this_pkg, dynamic_too)
    # The target's other sources (headers a module #includes, say), whose
    # use GHC doesn't record: plain inputs of every compile, as with --make.
    other_srcs = [src for _, src in srcs_to_pairs(ctx.attrs.srcs) if not is_haskell_src(src) and not src.short_path.endswith(_BOOT)]
    base_cmd = cmd_args(haskell_toolchain.compiler, cmd_flags, file_flags, hidden = other_srcs)
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

    # The module graph, with the interfaces each module imports from
    # dependencies (by the paths their package dbs give them, which need not
    # exist yet), and which modules run Template Haskell (see the script).
    # It runs against the early dbs, so it needs nothing built. Boot files
    # aren't arguments: GHC finds them next to their sources.
    deps_mk = ctx.actions.declare_output(prefix + "deps.mk")
    splices_file = ctx.actions.declare_output(prefix + "splices.txt")
    hs_srcs = [src for n, src in nodes if not _is_boot(n)]
    deps_cmd = cmd_args(
        base_cmd,
        early_set.args,
        "-M",
        "-include-pkg-deps",
        "-dep-makefile",
        deps_mk.as_output(),
        "-dep-suffix",
        "",
        hs_srcs,
        hidden = [src for n, src in nodes if _is_boot(n)],
    )
    ctx.actions.run(
        in_env(env, cmd_args(ctx.attrs._per_module_deps[RunInfo], splices_file.as_output(), hs_srcs, "--", deps_cmd)),
        category = "haskell_deps_" + suffix.replace("-", "_"),
        allow_cache_upload = haskell_toolchain.allow_cache_upload,
    )

    # The output directory of each dependency compiled per-module, where the
    # compile script looks up its interfaces. (Each such dependency has a
    # module: compile() handles a target with none, and leaves its `modules`
    # None.)
    def out_dir_of(lib):
        m, files = list(lib.modules.items())[0]
        return _dir_of(files.hi, m, hisuf)

    module_lib_dirs = {name: out_dir_of(lib) for name, lib in module_libs.items()}

    # The paths of those directories, which tell us which dependency an
    # interface in `ghc -M` output belongs to (see _per_module_dep). This
    # has to be all of them transitively, not just the direct dependencies',
    # since a dependency may re-export another's module. Written without the
    # directories as inputs: only their paths are needed, before anything
    # is compiled.
    lib_dirs = ctx.actions.write_json(prefix + "dep-dirs.json", module_lib_dirs, with_inputs = False)

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
            th_target = th_target,
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
            allow_cache_upload = haskell_toolchain.allow_cache_upload,
            allow_dep_file_cache_upload = haskell_toolchain.allow_dep_file_cache_upload,
        ),
        deps_mk = deps_mk,
        splices_file = splices_file,
        lib_dirs = lib_dirs,
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
# - Module graph: the target's nodes and their imports, computed from one
#   `ghc -M` action over all of its sources. This action needs only the
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
#   edit. Note [Reading the interface text] is how the dep files are made.
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
# `early` argument of _make_package in haskell.bzl). It is registered before
# anything is compiled, names no library, and has D's output directory as
# its import directory, which fills up as D's modules compile. X compiles
# against D's early db, and depends on just the interface files it needs.
# (D's final db, registered once its library is linked, is the normal one
# that `ghc --make` would use.)
#
# Two things tell us which interface files X needs:
#
# - X's own imports from dependencies come from `ghc -M -include-pkg-deps`,
#   which names each interface by the path the package db gives it, before
#   the file exists. The path says which dependency the interface belongs
#   to: it is below that dependency's output directory (_per_module_dep).
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
# also what GHC's own recompilation check reads (see Note [Reading the
# interface text]):
#
# - For each imported module, its .abi file, which holds just the
#   interface's ABI hash. Each action writes one next to its interface.
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

# Note [Reading the interface text]
#
# 1. The problem
#
# The compile script makes a module's .abi file and dep file from the
# interface GHC wrote (see Note [Early cut-off by dep files]). But an
# interface is binary, and the only reader GHC ships is the pretty-printer
# behind --show-iface and -ddump-hi, whose output is meant for people. GHC
# doesn't promise to keep that output stable, and as of 9.14 has no
# machine-readable form (GHC issue #25562 asks for one).
#
# 2. The solution
#
# The script parses three things out of the -ddump-hi output:
#
# - the "ABI hash:" line;
# - the usage lines of the imported modules, "import  -/  Mod hash"
#   ("import safe Mod hash" for a safe import; GHC 9.14 prints the first of
#   them on the "usages: [" line);
# - the addDependentFile "path" lines, for what a splice loaded.
#
# tests/rules/test_scripts.py checks these against a dump from each GHC the
# rules support. If the format changes, the script should fail rather than
# write a wrong dep file, so it fails the compile when it finds no ABI hash,
# or finds usages but no import line it can read. Some changes would look
# just like having no usages (a change to the addDependentFile lines, say).
# Those would leave entries out of the dep files, and a module wouldn't
# compile again when it should.
#
# The proper way to read an interface is the GHC API, in a small executable
# built with the GHC in use, which a project could build like its other
# tools. We don't do that yet.

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
# script says how to fix it.
#
# Nor can a splice run code of the target's own modules: their objects, and
# those of the modules behind any boot files among them, would have to be
# inputs of the compile. GHC can still find an object that another module's
# compile left in the output directory, though. So the compile script fails
# the compile if a splice loaded one, which GHC records as a dependent file.
#
# 3. Finding the Template Haskell modules
#
# Which modules run Template Haskell has to be decided before anything is
# compiled, from the target's flags and the sources. The deps script
# (tools/per_module_deps.py) looks for the extensions' names, and for ANN
# pragmas. It can find too much (a name in a comment, say), but it's better
# to be conservative. It doesn't catch GHC plugins.
