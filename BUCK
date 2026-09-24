# Shared helpers used by rules in haskell.bzl - kept in their own BUCK
# file (rather than folded into an existing one) since they're not
# specific to any one package, just infrastructure haskell_test() itself
# depends on.

sh_binary(
    name = "run_in_cwd",
    main = "run_in_cwd.sh",
    visibility = ["PUBLIC"],
)
