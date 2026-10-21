#!/usr/bin/env python3
# Tests of what the per-module scripts (prelude/haskell/tools) read from
# their inputs: the compile script from GHC's interface dumps, and the deps
# script from the sources.
#
# dumps/M-<version>.dump-hi is the -ddump-hi of this module, compiled with
# each GHC the rules support, its imports compiled first:
#
#   {-# LANGUAGE TemplateHaskell, Trustworthy #-}
#   module Fix.M where
#   import Fix.A (a)
#   import safe Fix.S (s)
#   import {-# SOURCE #-} Fix.B (b)
#   import Data.List (sort)
#   import Language.Haskell.TH.Syntax (addDependentFile, lift)
#   m :: Int
#   m = a + s + sum (sort [1, 2]) + $(addDependentFile "data.txt" >> lift (4 :: Int))
#   mb :: () -> Int
#   mb () = b

import glob
import os
import sys
import tempfile
import unittest

here = os.path.dirname(os.path.abspath(__file__))
# (No __pycache__ in the prelude.)
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(here, "..", "..", "prelude", "haskell", "tools"))

from per_module_compile import Dump, dep_file_entries  # noqa: E402
from per_module_deps import may_run_th  # noqa: E402


class InterfaceDump(unittest.TestCase):
    def test_each_ghc(self):
        dumps = sorted(glob.glob(os.path.join(here, "dumps", "M-*.dump-hi")))
        self.assertTrue(dumps)
        for path in dumps:
            with self.subTest(os.path.basename(path)):
                with open(path) as f:
                    dump = Dump(f.read())
                self.assertEqual(len(dump.abi_hashes), 1)
                self.assertRegex(dump.abi_hashes[0], r"^[0-9a-f]{32}$")
                home = {i.split(":", 1)[-1] for i in dump.imports if i.endswith(("Fix.A", "Fix.B", "Fix.S"))}
                self.assertEqual(home, {"Fix.A", "Fix.B", "Fix.S"})
                self.assertEqual(dump.boots, {"Fix.B"})
                self.assertIn("data.txt", dump.dependent_files)
                self.assertTrue(dump.readable())

    def test_unreadable(self):
        # Usages in a form the script doesn't know.
        dump = Dump("  ABI hash: 0123\n  usages: [usage  -/  Fix.A 0123]\n")
        self.assertFalse(dump.readable())
        self.assertFalse(Dump("  usages: []\n").readable())
        # A module may import nothing.
        self.assertTrue(Dump("  ABI hash: 0123\n").readable())


class DepFile(unittest.TestCase):
    def test_by_unit(self):
        # Three units have a module Utils: the module's own, and two
        # dependencies'. A usage of one is looked up in that unit's dirs only.
        cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as root:
            os.chdir(root)
            try:
                for d in ["out", "d1", "d2"]:
                    os.makedirs(d)
                    open(os.path.join(d, "Utils.abi"), "w").close()
                request = {"unit": "me", "module": "X", "abi": "out/X.abi", "outdir": "out", "hisuf": "hi",
                           "hidirs": {"d1": ["d1"], "d2": ["d2"]}}

                def entries(unit):
                    dump = Dump("  ABI hash: 0123\n  usages: [import  -/  {}:Utils 0123]\n".format(unit))
                    return list(dep_file_entries(request, dump))

                self.assertEqual(entries("d2"), ["d2/Utils.abi"])
                self.assertEqual(entries("me"), ["out/Utils.abi"])
                self.assertEqual(entries("base"), [])
            finally:
                os.chdir(cwd)


class Sources(unittest.TestCase):
    def test_may_run_th(self):
        self.assertTrue(may_run_th("{-# LANGUAGE TemplateHaskell #-}\nmodule M where\n"))
        self.assertTrue(may_run_th("{-# OPTIONS_GHC -XQuasiQuotes #-}\nmodule M where\n"))
        self.assertTrue(may_run_th("module M where\n{-# ANN module () #-}\n"))
        self.assertFalse(may_run_th("module M where\nf :: Int\nf = 1\n"))
        self.assertFalse(may_run_th("{-# LANGUAGE TemplateHaskellQuotes #-}\nmodule M where\n"))
        self.assertTrue(may_run_th("{-# LANGUAGE TemplateHaskellQuotes, TemplateHaskell #-}\nmodule M where\n"))


if __name__ == "__main__":
    unittest.main()
