#!/usr/bin/env python3
"""The checks of the rules, run in the test project by run.sh.

Each check builds what it needs, reads what the rules decided from buck2
(the command lines of `buck2 log what-ran`, `buck2 audit dep-files`, the
static actions of `buck2 aquery`) and compares sets of short names (see
short() in harness.py) with what it expects, saying what is missing and what
is not expected. The checks run in order, on one project: some edit its
sources.

- per_module.py: what the per-module rules decide for each module.
- both_ways.py: what holds both per-module and with --make.
- other_rules.py: haskell_test, linking, the toolchains and a remote cache.
"""

import argparse
import sys
import time
import traceback

from both_ways import (
    check_configurations,
    check_data_dirs,
    check_header_change,
    check_index,
    check_local_splices,
    check_make_build,
    check_module_moved,
    check_native_library_change,
    check_native_soname_for_splices,
    check_own_native_libraries_for_splices,
    check_rts_flags,
    check_th_body_change,
    check_th_boot_cycles,
    check_th_modes,
    check_toolchain_index,
    check_toolchain_th,
)
from harness import CheckFailed, Skipped, State
from other_rules import (
    check_data_files,
    check_profiled_shared_only,
    check_test_build_tools,
    check_test_labels,
    check_cache,
    check_toolchain_paths,
)
from per_module import (
    check_binary_unit,
    check_boot,
    check_clean_build,
    check_cross_package_dep_file,
    check_cutoff_abi_base,
    check_cutoff_abi_mid,
    check_cutoff_comment,
    check_cutoff_instances,
    check_early_db_conf,
    check_interfaces_subtarget,
    check_main_file,
    check_module_name_clash,
    check_opt_shared_consumer,
    check_opt_static,
    check_own_boot,
    check_plain_module_uses_early_dbs,
    check_th_modules_dbs,
    check_unrelated_modules,
)

CHECKS = [
    check_clean_build,
    check_make_build,
    check_early_db_conf,
    check_cross_package_dep_file,
    check_module_name_clash,
    check_plain_module_uses_early_dbs,
    check_binary_unit,
    check_th_modules_dbs,
    check_local_splices,
    check_th_boot_cycles,
    check_own_boot,
    check_main_file,
    check_rts_flags,
    check_boot,
    check_index,
    check_cutoff_comment,
    check_interfaces_subtarget,
    check_cutoff_abi_base,
    check_cutoff_abi_mid,
    check_cutoff_instances,
    check_unrelated_modules,
    check_opt_static,
    check_th_modes,
    check_opt_shared_consumer,
    check_module_moved,
    check_header_change,
    check_th_body_change,
    check_native_library_change,
    check_native_soname_for_splices,
    check_own_native_libraries_for_splices,
    check_configurations,
    check_data_dirs,
    check_test_build_tools,
    check_data_files,
    check_test_labels,
    check_profiled_shared_only,
    check_toolchain_th,
    check_toolchain_index,
    check_toolchain_paths,
    check_cache,
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", action="append", help="run only this check (by name, without check_); repeatable")
    ap.add_argument("--bazel-remote", help="a bazel-remote binary, for check_cache")
    args = ap.parse_args()
    unknown = set(args.only or []) - {check.__name__[len("check_"):] for check in CHECKS}
    if unknown:
        ap.error("no such check: " + " ".join(sorted(unknown)))
    st = State(bazel_remote=args.bazel_remote)
    failed = []
    for check in CHECKS:
        name = check.__name__[len("check_"):]
        if args.only and name not in args.only and check is not check_clean_build:
            continue
        if check is check_cache and not st.bazel_remote:
            print("SKIP   {} (no BAZEL_REMOTE)".format(name))
            continue
        start = time.time()
        skipped = None
        try:
            check(st)
            error = None
        except Skipped as e:
            error, skipped = None, str(e)
        except CheckFailed as e:
            error = str(e)
        except Exception:
            # Most likely a change to buck2's logs or the rules' command
            # lines that the harness can't read.
            error = traceback.format_exc()
        took = "{:.0f}s".format(time.time() - start)
        known = getattr(check, "known_failure", None)
        if skipped is not None:
            print("SKIP   {} ({})".format(name, skipped))
        elif known is not None and error is not None:
            print("XFAIL  {} ({}): {}".format(name, took, known))
        elif known is not None:
            failed.append(name)
            print("XPASS  {} ({}): it passes, so the bug it is marked with is fixed: {}".format(name, took, known))
        elif error is None:
            print("PASS   {} ({})".format(name, took))
        else:
            failed.append(name)
            print("FAIL   {} ({}): {}\n       {}".format(name, took,
                                                   check.__doc__.split("\n")[0], error.replace("\n", "\n       ")))
        sys.stdout.flush()
        if check is check_clean_build and error is not None:
            print("(the other checks need the clean build)")
            break
    print("{} failed: {}".format(len(failed), " ".join(failed)) if failed else "all passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
