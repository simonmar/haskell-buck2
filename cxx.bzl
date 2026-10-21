_ASAN_CXX_FLAGS = select({
    "root//buck2/constraints:asan": ["-fsanitize=address"],
    "DEFAULT": [],
})

_BUILD_MODE_CXX_FLAGS = select({
    "root//buck2/constraints:opt": select({
        "root//buck2/constraints:asan": ["-g"],
        "DEFAULT": ["-O3", "-DNDEBUG"],
    }),
    "DEFAULT": ["-g"],
})

_COMMON_CXX_FLAGS = ["-fno-omit-frame-pointer"] + _ASAN_CXX_FLAGS + _BUILD_MODE_CXX_FLAGS

# The languages of lang_compiler_flags (by their sources' kind).
_LANGUAGES = ["c", "cxx", "objc", "objcxx", "assembler_with_cpp", "cuda", "hip", "asm_with_cpp"]

def _lang_compiler_flags(lang_compiler_flags):
    # The build mode's flags come first, so that a target's own win (-Og, or
    # -fomit-frame-pointer, say): its lang_compiler_flags (a Cabal package's
    # cc-options), and then its compiler_flags.
    flags = dict(lang_compiler_flags)
    for lang in _LANGUAGES:
        flags[lang] = _COMMON_CXX_FLAGS + flags.get(lang, [])
    return flags

def cxx_library(name, lang_compiler_flags = {}, linker_flags = [], **kwargs):
    native.cxx_library(
        name = name,
        lang_compiler_flags = _lang_compiler_flags(lang_compiler_flags),
        # -fsanitize=address has to reach the *linker* too
        linker_flags = _ASAN_CXX_FLAGS + linker_flags,
        **kwargs
    )

def cxx_binary(name, lang_compiler_flags = {}, linker_flags = [], **kwargs):
    native.cxx_binary(
        name = name,
        lang_compiler_flags = _lang_compiler_flags(lang_compiler_flags),
        linker_flags = _ASAN_CXX_FLAGS + linker_flags,
        **kwargs
    )
