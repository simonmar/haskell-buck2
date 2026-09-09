# Buck2 build system for Haskell projects

This is a version of the Buck2 prelude with a few tweaks (that will
hopefully be upstreamed at some point) and some supporting tooling to
enable Haskell projects to be built with Buck2.

Why might you want to do that compared with, say, just using Cabal to
build your code? Well, first off let me be clear that you *still* need
Cabal, because this build system doesn't know how to solve package
dependencies or build them. But once you've built your package
dependencies using Cabal, you can use Buck2 for your edit-compile-test
loop, and in many ways it's a more pleasant experience than using
Cabal because:

* It's much faster than Cabal
* It's much more extensible than Cabal. If you have anything that
  needs to be generated as part of your build, or any non-standard
  tooling, then hooking that up using Buck2 is far easier than Cabal.
  Furthermore Buck2 knows how to rebuild things correctly when
  either the build system or the code generator components change.
* It works a lot better when you have C/C++ components in your project, because
  * Buck2 understands dependencies between C/C++ source files and header files (Cabal doesn't), so when you modify a C/C++ header the correct things are rebuilt.
  * Buck2 builds C/C++ files in parallel (Cabal doesn't)
* You can integrate remote caching and execution (although I haven't tried that).

The main disadvantage of course is that you have to maintain
additional build instructions in the form of `BUCK` files for your
project, which duplicate some of what is in your `.cabal` file. In the
future I hope to be able to generate the `BUCK` files from the
`.cabal` file, but how to do that in the presence of custom build
stuff is an open question.

# How to use it

First, clone this repo as `buck2/` in your Cabal project

Next, create a `.buckconfig` containing

```
[cells]
  root = .
  prelude = buck2/prelude
  toolchains = buck2/toolchains
  third-party = third-party
  none = none

[cell_aliases]
  config = prelude
  ovr_config = prelude
  fbcode = none
  fbsource = none
  buck = none

[parser]
  target_platform_detector_spec = target:root//...->prelude//platforms:default \
    target:prelude//...->prelude//platforms:default \
    target:toolchains//...->prelude//platforms:default \
    target:third-party//...->prelude//platforms:default

[build]
  execution_platforms = prelude//platforms:default
```

Next, create `PACKAGE` containing

```
load("//buck2:cfg_constructor_if_standalone.bzl", "cfg_constructor_if_standalone", "dev_modifiers_if_standalone")
load("@prelude//cfg/modifier/set_cfg_modifiers.bzl", "set_cfg_modifiers")

cfg_constructor_if_standalone()

set_cfg_modifiers(
    cfg_modifiers = dev_modifiers_if_standalone(),
)
```

Next ask Cabal to build your dependencies:

```
cabal build all --only-dependencies --enable-tests
```

And set up the Buck2 build:

```
python3 buck2/gen-haskell-prebuilt.py
```

Next, create `BUCK` file(s) containing your build targets. These
should go in the same directory as your source files. For example, the
`BUCK` file for a simple Haskell library might look something like

```
load("//buck2:haskell.bzl", "haskell_library")

haskell_library(
    name = "my-package",
    srcs = [
        "Some/Module.hs",
    ],
    packages = [
        "unordered-containers",
    ],
    visibility = ["PUBLIC"],
)
```

and the `BUCK` file for a test might look like

```
load("//buck2:haskell.bzl", "haskell_test")

haskell_test(
    name = "my-test",
    srcs = {
        "Main.hs" : "my-test.hs",
    },
    deps = [
        "//:my-package",
    ],
    packages = [
        "test-framework",
        "test-framework-hunit",
        "HUnit",
    ],
)
```

You can find docs on how to write `BUCK` files in the Buck2 docs, e.g. [haskell_library](https://buck2.build/docs/prelude/rules/haskell/haskell_library/).

Then build your code:

```
buck2 build //...
```

and run your tests:

```
buck2 test //...
```

