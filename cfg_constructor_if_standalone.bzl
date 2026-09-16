# A PACKAGE file (unlike a BUCK/.bzl file) can only contain a flat
# sequence of top-level calls - no `if`/`def` allowed directly in it
# ("if cannot be used outside def", then "def is not allowed in this
# dialect" once wrapped - both confirmed directly). The conditional logic
# hsthrift/PACKAGE needs (call set_cfg_constructor() only when this
# checkout is genuinely standalone - see that file's own comment) has to
# live in a real .bzl file instead, called as a single top-level
# statement from the PACKAGE file itself.
#
# set_cfg_modifiers() itself can't be wrapped the same way, though -
# unlike set_cfg_constructor() (a builtin, no such restriction), it's a
# plain prelude .bzl function that inspects its *immediate* caller's own
# module path (_is_buck_tree_file(), buck2/prelude/cfg/modifier/
# set_cfg_modifiers.bzl) and requires it to literally end in "/PACKAGE" -
# confirmed directly (its own docstring claims "or a bzl file
# transitively loaded by a PACKAGE file" is also fine, but that isn't
# what the check actually does). Calling it from inside this file's own
# cfg_constructor_if_standalone() - one frame removed from PACKAGE -
# fails that check even though PACKAGE is what ultimately triggered it.
# So PACKAGE has to call set_cfg_modifiers() itself, directly - the
# standalone-or-not decision instead has to be *returned* from a helper
# here (dev_modifiers_if_standalone(), below) rather than guarding the
# call itself.
load(
    "@prelude//cfg/modifier/cfg_constructor.bzl",
    "cfg_constructor_post_constraint_analysis",
    "cfg_constructor_pre_constraint_analysis",
)
load("@prelude//cfg/modifier/common.bzl", "MODIFIER_METADATA_KEY")

def cfg_constructor_if_standalone():
    # get_cell_name() gives the name of *this* PACKAGE file's own cell -
    # "root" when this checkout's own .buckconfig is the outermost one
    # (genuinely standalone), or "hsthrift" when nested inside another
    # project's cell graph (see buck2.md's hsthrift-cell entry for why
    # cell names are global to whichever project is outermost - that's
    # exactly what makes this check correct: a plain read_config() flag
    # in this project's own .buckconfig does *not* work here, since a
    # cell's own .buckconfig is still consulted for ordinary config
    # values even when nested, unlike the special-cased [cells] section -
    # confirmed directly, the first version of this check used that and
    # it read as true (and hard-errored the nested build) either way.
    if get_cell_name() != "root":
        return

    set_cfg_constructor(
        stage0 = cfg_constructor_pre_constraint_analysis,
        stage1 = cfg_constructor_post_constraint_analysis,
        key = MODIFIER_METADATA_KEY,
        aliases = struct(
            dev = "root//buck2/constraints:dev",
            opt = "root//buck2/constraints:opt",
        ),
        extra_data = struct(),
    )

# `dev` is the default build mode when no -m flag is given - but only
# when standalone (same reasoning as cfg_constructor_if_standalone()
# above); when nested, an empty list is the no-op equivalent of "don't
# call this at all", since set_cfg_modifiers() itself has no comparable
# once-per-project restriction (it's package-scoped, not project-wide) -
# unlike set_cfg_constructor(), calling it with `[]` when nested is
# harmless.
def dev_modifiers_if_standalone():
    if get_cell_name() != "root":
        return []
    return ["root//buck2/constraints:dev"]
