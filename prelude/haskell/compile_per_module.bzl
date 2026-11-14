# Per-module compilation (`per_module = True`): one `ghc -c` action per module
# instead of one `ghc --make` action per target. See the Notes at the end of
# this file, starting with Note [Per-module compilation].

load(
    "@prelude//haskell:compile.bzl",
    "CompileResultInfo",
    "data_dirs_env",
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
# its final dbs as inputs, because GHC's interpreter loads them.
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
#
# This also runs in the dynamic output, for the modules that choose their
# own final dbs, so it takes the libraries rather than an analysis context.
def _package_dbs(libs: list, final: dict[str, bool], below_make: dict[str, bool], import_dirs_tag, runs_th: bool, strict_db = None):
    packagedb_args = cmd_args()
    packagedb_set = {}
    local_import_dirs = []
    early_names = {}

    # The prebuilt packages share their db. For a Template Haskell module,
    # each prebuilt db is replaced below by a copy in which only the
    # packages in `final` name their libraries (see Note [Libraries of the
    # early package dbs]), unless all of them are in `final`.
    prebuilt_allowed = {}
    prebuilt_all = {}
    for lib in libs:
        if lib.is_prebuilt and runs_th:
            prebuilt_all.setdefault(lib.db, True)
            prebuilt_allowed.setdefault(lib.db, [])
            if lib.name in final:
                prebuilt_allowed[lib.db].append(lib.id)
            else:
                prebuilt_all[lib.db] = False
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
        # The interfaces are tagged, so that a compile's dep file can list
        # the ones it read. The libraries that a Template Haskell module
        # loads never appear in the dep file (see Note [Template Haskell
        # modules]), so they are plain inputs, and any change to one
        # compiles the module again. A module that runs no Template Haskell
        # loads none, so it doesn't wait for them to be linked.
        loads = runs_th and not library_less and (not lib.is_prebuilt or lib.name in final or strict_db == None)
        packagedb_args.add(cmd_args(hidden = [
            lib.stub_dirs,
            import_dirs_tag.tag_artifacts(cmd_args(hidden = import_dirs)),
            lib.libs if loads else [],
            lib.native_libs_dir if loads and lib.native_libs_dir != None else [],
        ]))

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    dbs = []
    for db in packagedb_set:
        if strict_db != None and db in prebuilt_all and not prebuilt_all[db]:
            db = strict_db(db, sorted(prebuilt_allowed[db]))
        dbs.append(db)
    packagedb_args.add([cmd_args("-package-db", x) for x in dbs])
    return struct(packagedb_args = packagedb_args, local_import_dirs = local_import_dirs, early_names = early_names)

# Make a copy of a prebuilt package db in which only some packages name
# their libraries: the given ones, template-haskell, and the packages that
# those depend on, directly or indirectly. GHC's interpreter can then load
# only those (see Note [Libraries of the early package dbs]). The packager
# is the rest of the arguments.
_STRICT_PREBUILT_DB = """\
set -eu
src=$1
out=$2
roots=$3
shift 3
mkdir -p "$out"
# GHC reads ${pkgroot} as the directory that holds the db, so a copy's
# entries must say where the original's is. A relative path is relative to
# the project root, as the copy's is, so it becomes one relative to the
# copy's directory.
case "$src" in
  /*) root=$(dirname "$src") ;;
  *) root='${pkgroot}/'$(dirname "$out" | sed 's|[^/][^/]*|..|g')/$(dirname "$src") ;;
esac
# A long id, such as the Cabal store's, is on the line after "id:".
keep=$(awk -v roots="$roots" '
  FNR == 1 { in_deps = 0; id_next = 0 }
  /^id:/ { if (NF > 1) id[FILENAME] = $2; else id_next = 1; in_deps = 0; next }
  id_next { id[FILENAME] = $1; id_next = 0; next }
  /^depends:/ { in_deps = 1; sub(/^depends:/, ""); deps[FILENAME] = deps[FILENAME] " " $0; next }
  in_deps && /^[ \t]/ { deps[FILENAME] = deps[FILENAME] " " $0; next }
  { in_deps = 0 }
  END {
    for (f in id) d[id[f]] = deps[f]
    n = split(roots, todo, " ")
    for (k in d) if (k ~ /^template-haskell-[0-9]/) todo[++n] = k
    while (n > 0) {
      x = todo[n--]
      if (x == "" || x in seen) continue
      seen[x] = 1
      m = split(d[x], ds, /[ ,\t]+/)
      for (j = 1; j <= m; j++) if (ds[j] != "") todo[++n] = ds[j]
    }
    for (k in seen) print k
  }' "$src"/*.conf)
# Copy each entry, without its libraries unless it is kept. An entry's id
# comes after its first lines, so each file is read whole before it is
# written.
KEEP=$keep awk -v root="$root" -v out="$out" '
  BEGIN { n = split(ENVIRON["KEEP"], k, "\\n"); for (i = 1; i <= n; i++) kept[k[i]] = 1 }
  function flush(   f, i, l, skip) {
    if (lines == 0) return
    f = out "/" base
    skip = 0
    for (i = 1; i <= lines; i++) {
      l = line[i]
      if (!(id in kept)) {
        if (l ~ /^(hs-libraries|extra-libraries|extra-ghci-libraries|library-dirs|dynamic-library-dirs|library-dirs-static|extra-libraries-static):/) { skip = 1; continue }
        if (l ~ /^[^ \\t]/) skip = 0
        if (skip) continue
      }
      gsub(/\\$\\{pkgroot\\}/, root, l)
      print l > f
    }
    close(f)
    lines = 0
  }
  FNR == 1 { flush(); base = FILENAME; sub(/.*\\//, "", base); id = ""; id_next = 0 }
  id_next { id = $1; id_next = 0 }
  /^id:/ { if (NF > 1) id = $2; else id_next = 1 }
  { line[++lines] = $0 }
  END { flush() }' "$src"/*.conf
"$@" recache --package-db "$out"
"""

def _strict_prebuilt_db(actions: AnalysisActions, packager, name: str, db: Artifact, ids: list[str]) -> Artifact:
    out = actions.declare_output(name + "-" + str(hash(" ".join(ids)) & 0xffffffff), dir = True)
    actions.run(
        cmd_args("sh", "-c", _STRICT_PREBUILT_DB, "", db, out.as_output(), " ".join(ids), packager),
        category = "haskell_strict_prebuilt_db",
        identifier = out.short_path,
    )
    return out

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
# tools/ghc-api/PerModuleDeps.hs). It returns:
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

# What decides which final dbs a Template Haskell module compiles against,
# which depends on the direct dependencies whose code its splices run (see
# Note [Template Haskell modules]). The result has three fields:
#
# - closures maps the name of each direct Haskell dependency, local or
#   prebuilt, to the names of the dependency's closure. (A local library's
#   name is its package id.) A module that uses a dependency's final db uses the final dbs
#   of the dependency's whole closure too, because the dependency's library
#   was linked against their libraries (see Note [Libraries of the early
#   package dbs]).
# - labels maps the target of each of those dependencies to its name.
# - base holds the names of the dependencies that are neither local nor
#   prebuilt Haskell libraries, and of their closures. Every Template
#   Haskell module gets their final dbs.
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
        if lib == None or (lib.early_db == None and not lib.is_prebuilt):
            if info != None:
                base_infos.append(info)
            continue
        labels[d.label.raw_target()] = lib.name
        closures[lib.name] = [l.name for l in ctx.actions.tset(HaskellLibraryInfoTSet, children = [info] if info != None else []).traverse()]
    base = [l.name for l in ctx.actions.tset(HaskellLibraryInfoTSet, children = base_infos).traverse()]
    return struct(closures = closures, labels = labels, base = base)

# The package ids whose final dbs a Template Haskell module gets, when its
# splices run code from the dependencies with the given names. The result
# includes each of those dependencies' closures.
def _splice_set(splice_deps, names: list[str]):
    final = {n: True for n in splice_deps.base}
    for name in names:
        # A name may not be a direct dependency, if the module came through a
        # dependency that re-exports it. Then every direct dependency whose
        # closure includes that package is brought in.
        via = [name] if name in splice_deps.closures else [d for d in sorted(splice_deps.closures.keys()) if name in splice_deps.closures[d]]
        for d in via:
            for n in splice_deps.closures[d]:
                final[n] = True
    return final

# The package ids whose final dbs the target's Template Haskell modules get
# (see _splice_set): those of the dependencies that template_haskell_depends
# lists.
def _th_set(ctx: AnalysisContext, splice_deps):
    names = []
    deps = {d.label.raw_target(): True for d in attr_deps(ctx) + ctx.attrs.template_deps}
    for d in ctx.attrs.template_haskell_depends:
        t = d.label.raw_target()
        if t not in deps:
            fail("{}: template_haskell_depends names {}, which is not a dependency".format(ctx.label.raw_target(), t))
        if t in splice_deps.labels:
            names.append(splice_deps.labels[t])
    return _splice_set(splice_deps, names)

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

# The persistent worker that compiles the target's modules: the toolchain's
# shared worker (see Note [The persistent worker]). The result is None if
# there is no worker, or if the target has a build tool that isn't on the
# worker's PATH (see per_module_worker_build_tools), because then the
# modules have to be compiled in the target's own environment.
def _per_module_worker(ctx: AnalysisContext) -> WorkerInfo | None:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    shared_tools = haskell_toolchain.per_module_worker_build_tools
    if any([t.label.raw_target() not in shared_tools for t in ctx.attrs.build_tool_depends]):
        return None
    return haskell_toolchain.per_module_shared_worker

# The version of the request that each compile action sends, and of the
# files that the worker writes back. The worker and the compile tool refuse a
# request of any other version, so that a worker built from another version
# of the rules reports the mismatch rather than misreading the request. When
# either the request or the worker's outputs change, bump this and the
# version in tools/ghc-api/Contract.hs.
_WORKER_CONTRACT = "2"

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
    data_dirs = s.data_dirs
    worker_info = s.worker_info
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
        mod_packages = target_th if runs_th[n] else early_set
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
            "--boot" if _is_boot(n) else [],
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
            [cmd_args(d, format = "--data-dir=" + var + "={}") for var, d in data_dirs.items()] if runs_th[n] else [],
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
# dynamic_from. A splice finds the native libraries it loads through the
# package dbs instead (see _native_ghci_libs in haskell.bzl). dynamic_from
# is only needed for splices that run code of their own target, which
# per-module compilation doesn't support (see Note [Template Haskell
# modules]).
def compile_per_module(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None = None, native_shared_libs_dir: [Artifact, None] = None, dynamic_too: bool = False, dynamic_from: [CompileResultInfo, None] = None) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    suffix = get_artifact_suffix(link_style, enable_profiling)
    osuf, hisuf = output_extensions(link_style, enable_profiling)
    prefix = per_module_dir(link_style, enable_profiling)

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
    below_make = {lib.name: True for lib in below.traverse() if lib.modules != None}

    # `actions` makes the copies of the prebuilt db that the flags need.
    def packages(final, actions, runs_th = True, db_name = prefix + "th-db"):
        def strict_db(db, ids):
            return _strict_prebuilt_db(actions, haskell_toolchain.packager, db_name, db, ids)

        dbs = _package_dbs(dep_libs, final, below_make, tag, runs_th, strict_db)
        return struct(
            # A module that runs splices runs them in an external
            # interpreter, which is a process of its own (see Note [Template
            # Haskell modules]).
            args = cmd_args(exposed_package_args, dbs.packagedb_args, ["-fexternal-interpreter"] if runs_th else []),
            local_import_dirs = dbs.local_import_dirs,
            early_names = dbs.early_names,
        )

    early_set = packages({}, ctx.actions, runs_th = False)

    # Only the actions of Template Haskell modules depend on the
    # dependencies' libraries, because only those modules load them, and so
    # only they have to wait for the libraries to be linked. Most Template
    # Haskell modules use the target's set of final dbs.
    splice_deps = _splice_deps(ctx, link_style, enable_profiling)
    target_th = packages(_th_set(ctx, splice_deps), ctx.actions)
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
    ghc_args = cmd_args(cmd_flags, file_flags, hidden = other_srcs)
    base_cmd = cmd_args(haskell_toolchain.compiler, ghc_args)
    env = ghc_env(ctx, prefix + "build-tool-depends")

    worker_info = _per_module_worker(ctx)

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
    objects = ctx.actions.declare_output("objects-" + suffix, dir = True, has_content_based_path = False)
    hi = ctx.actions.declare_output("hi-" + suffix, dir = True, has_content_based_path = False)
    stubs = ctx.actions.declare_output("stubs-" + suffix, dir = True, has_content_based_path = False)
    producing_indices = get_producing_indices(ctx)

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
            compile_script = ctx.attrs._per_module_compile[RunInfo],
            nodes = nodes,
            src_of = src_of,
            modules = modules,
            module_libs = module_libs,
            module_lib_dirs = module_lib_dirs,
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
            data_dirs = data_dirs_env(ctx),
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
#   the package dbs each compile gets.
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
# A Template Haskell module compiles against the final package dbs of the
# dependencies, local or prebuilt, that the target's template_haskell_depends
# lists (see _th_set), with their libraries and the native libraries they
# depend on as inputs. So it waits only for those libraries (and those of
# their own dependencies), and compiles against dbs that name no library for
# the rest, like any other module. template-haskell's libraries are always
# available. Listing prebuilt dependencies matters less for waiting, since
# their libraries are there from the start, than for what GHC's interpreter
# loads: it loads every library on its dbs when it starts, which for a
# target with many dependencies costs more time and memory than the splices
# themselves.
#
# Note [Libraries of the early package dbs] has a table of which package db
# a compile gets for each dependency. If a splice runs code from a
# dependency that was left out, the compile fails and names the symbol it
# couldn't load, and the compile suggests template_haskell_depends.
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
# against by soname, but it has no RUNPATH to find them, and a compile has
# nothing on LD_LIBRARY_PATH. So when a splice loads such a library, the
# dynamic loader can't find the libraries it needs, and the splice fails.
#
# Instead, a package db lists the native libraries that its library depends
# on in extra-ghci-libraries, which only GHC's interpreter reads (see
# _native_ghci_libs in haskell.bzl). They come in dependency order, before
# the package's own library, and the db gives the directory they are in.
# GHC loads them by path in that order, so each library finds the ones it
# needs already loaded. The db gives the directory in both library-dirs and
# dynamic-library-dirs. The interpreter is built for the compile's way, and
# only a dynamic interpreter reads dynamic-library-dirs.
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
# library under that name. If a library's soname isn't of that form (for
# example libfoo.so.1), the directory has it under its whole soname. A
# library whose soname is only known once it has been built can't be named
# this way, so a library that depends on it fails to load, with an error
# that says so.
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
# Splices run in an external interpreter (-fexternal-interpreter), built for
# the compile's way: ghc-iserv, ghc-iserv-prof or ghc-iserv-dyn. There is
# one interpreter for each `ghc -c`, or one for each session of the
# persistent worker (see Note [The persistent worker]). The libraries that a
# splice loads stay in the interpreter's process. If splices ran in the
# worker's own process, which every target's sessions share, three things
# could go wrong:
#
# - A splice could run code from a library that another target's splice had
#   loaded, without having that library as an input. A dependency left out of
#   template_haskell_depends would then go unnoticed, and the module wouldn't
#   compile again when the library changed.
# - A library that is built in two configurations, such as a build tool's
#   and a target's, has the same unit id and soname in both. So a splice in
#   one configuration could run the library of the other.
# - A crash in one splice, or a library's global state, would affect the
#   splices of other targets.
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
# DepFile in tools/ghc-api).
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
# the build starts. A Template Haskell module whose splices may not run some
# of them gets a copy of that db instead, in which only the others name
# their libraries (_strict_prebuilt_db):
#
#                                 local dependency         prebuilt
#                                 (per-module, --make)     dependency
#   module that runs no TH        no library               final
#   TH module                     final if listed,         final if listed,
#                                 else no library          else no library
#
# A final db comes with the final dbs of the dependency's closure, and
# template-haskell's closure is always final. A splice can also always run
# the code of the packages that GHC's external interpreter is itself linked
# with (ghc-iserv-dyn links base, containers, bytestring and others that
# come with GHC), whatever its dbs say, because that code is in the
# interpreter's process already. A module that runs no Template
# Haskell never starts the interpreter, so it doesn't depend on the
# libraries of the final dbs it gets.

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
# actions to. Ours (tools/buck2-ghc-worker) compiles each module as it arrives,
# concurrently with the others, in a GHC session that keeps the interfaces
# it has read. It is configured by `[haskell] per_module_worker` (see
# prelude/haskell/per_module_worker.bzl).
#
# 3. The request
#
# A module's action sends the same request whether or not there is a
# worker. The request goes either to the worker, or to the compile tool,
# which runs it as one `ghc -c`. It holds the module's source and the
# compile's flags, which come in two parts:
#
# - The session flags are the same for all the target's modules. The worker
#   keeps a session for each distinct set of session flags. A target's
#   Template Haskell modules have session flags of their own, because their
#   package dbs differ (see Note [Libraries of the early package dbs]).
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
# compile modules that need nothing from their target's environment. Those
# are the modules of targets whose build tools are all on the worker's PATH
# (see per_module_worker_build_tools in prelude/haskell/per_module_worker.bzl).
# Template Haskell modules don't need the target's environment either (see
# Note [Template Haskell modules]).
#
# The other modules are compiled without a worker, each by its own
# `ghc -c`. Giving each such target a worker of its own, running in the
# target's environment, would compile them faster. But each of those
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
# sessions] in tools/buck2-ghc-worker/src/Worker.hs). It has no concurrency
# limit of its own. buck2's -j already limits the actions that run in workers,
# along with all the others, and a lower limit for each worker would only hold
# back a target's modules.

# Note [Data files of splices]
#
# A package's Paths_<pkg> module finds the package's data files through the
# environment variable <pkg>_datadir, which the target's data_dirs attribute
# sets (see data_dirs_env). A splice that runs code of a local library may
# read that library's data files, so the interpreter that runs the splice
# needs the variables.
#
# So a module that runs splices gets the data dirs in its request
# (--data-dir=VAR=DIR), and has them as inputs. The compile tool gives their
# variables to `ghc -c`, and GHC's interpreter inherits them. The worker
# can't do that, because its own environment is shared by all its sessions.
# Instead, it starts each session's interpreter with the variables (see
# Note [Template Haskell modules]), and keeps sessions with different data
# dirs apart.
#
# Other modules don't get the data dirs. They run no splices, and if the
# data dirs were inputs, they would compile again whenever a data file
# changed.
