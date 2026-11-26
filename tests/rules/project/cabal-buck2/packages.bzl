# As `cabal buck2` would write it for the packages under cabal-*/ (see
# cabal.bzl at the root of the repository).

# As a project's cabal-buck2.bzl might set it.
DEFAULTS = {"*": {"*": {"compile_granularity": "module"}}}
OVERRIDES = {}

PACKAGES = {
    "cabal-example": "cabal-example",
}

DATA_PACKAGES = {}
