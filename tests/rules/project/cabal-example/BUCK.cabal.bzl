# A build spec as `cabal buck2` would write it for an ordinary Haskell
# package: a library with a hidden module, a private sub-library, an
# executable, and a test-suite that has the executable as a build tool.

load("//buck2:cabal.bzl", "cabal_targets")

local_build_spec = {
    "cabal_buck2": "0.6.0.0",
    "package": {"name": "cabal-example", "version": "0.1.0.0"},
    "ghc_options": ["-Wall"],
    "components": [
        {
            "kind": "library",
            "name": "cabal-example",
            "srcs": {"Example": "src/Example.hs", "Example.Hidden": "src/Example/Hidden.hs"},
            "hidden_modules": ["Example.Hidden"],
            "language": "Haskell2010",
            "extensions": ["LambdaCase"],
            "deps": [{"package": "base"}, {"package": "cabal-example", "library": "internal"}],
        },
        {
            "kind": "library",
            "name": "internal",
            "srcs": {"Internal": "internal/Internal.hs"},
            "language": "Haskell2010",
            "deps": [{"package": "base"}],
            "exposed": False,
        },
        {
            "kind": "executable",
            "name": "cabal-example-exe",
            "exe_name": "cabal-example",
            "main_is": "app/Main.hs",
            "language": "Haskell2010",
            "ghc_options": ["-threaded"],
            "deps": [{"package": "base"}, {"package": "cabal-example"}],
        },
        {
            "kind": "test-suite",
            "name": "tests",
            "main_is": "test/Main.hs",
            "language": "Haskell2010",
            "deps": [{"package": "base"}, {"package": "process"}, {"package": "cabal-example"}],
            "build_tools": [{"exe": "cabal-example-exe", "package": "cabal-example"}],
            "test_args": ["--quick"],
        },
    ],
}

def generated_targets(**kwargs):
    cabal_targets(local_build_spec, **kwargs)
