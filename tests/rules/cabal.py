"""Checks of the targets that cabal.bzl generates from a build spec, for the
packages under cabal-*/ in the project."""

import difflib
import json
import os

from harness import CheckFailed, buck2

GOLDEN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden")


def render(value, indent=""):
    """JSON, with each list of strings on one line, so that a golden file is
    short enough to read and its diffs show which flags changed."""
    inner = indent + "  "
    if isinstance(value, dict) and value:
        items = [inner + json.dumps(k) + ": " + render(v, inner) for k, v in sorted(value.items())]
        return "{\n" + ",\n".join(items) + "\n" + indent + "}"
    if isinstance(value, list) and value and not all(isinstance(v, str) for v in value):
        return "[\n" + ",\n".join(inner + render(v, inner) for v in value) + "\n" + indent + "]"
    return json.dumps(value)


def check_cabal_targets(st):
    """The targets that cabal.bzl generates from cabal-example's spec have
    the attributes in golden/cabal-example.json. Only the attributes that
    differ from their defaults are compared. With --accept-golden, the file
    is rewritten with the targets as they are instead, for a change to
    cabal.bzl (or the rules) that changes them on purpose."""
    targets = json.loads(buck2("targets", "//cabal-example:", "--output-basic-attributes").stdout)
    actual = render(sorted(targets, key=lambda t: t["name"])) + "\n"
    path = os.path.join(GOLDEN_DIR, "cabal-example.json")
    if st.accept_golden:
        with open(path, "w") as f:
            f.write(actual)
        return
    with open(path) as f:
        expected = f.read()
    if actual != expected:
        diff = difflib.unified_diff(expected.splitlines(keepends=True), actual.splitlines(keepends=True), "golden/cabal-example.json", "generated")
        raise CheckFailed("the targets of //cabal-example: differ from the golden file (rerun with --accept-golden to update it):\n" + "".join(diff))


def check_cabal_test(st):
    """cabal-example's targets build, and its test-suite passes."""
    buck2("test", "//cabal-example:tests")
