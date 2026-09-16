#!/usr/bin/env bash
# Sets up example/ for local buck2 builds: points buck2/ at this checkout
# (README's "clone this repo as buck2/" becomes a symlink here, since
# it's already checked out), then runs the two Cabal/gen-haskell-prebuilt
# steps buck2 depends on. Re-run any time GHC or the resolved dependency
# set changes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ln -sfn "$(cd .. && pwd)" buck2

cabal build all --only-dependencies --enable-tests
python3 buck2/gen-haskell-prebuilt.py

cat <<'EOF'

Done. Now try:
  cd example
  buck2 build //...          # dev
  buck2 test //...
  buck2 build -m opt //...   # opt
  buck2 test -m opt //...
EOF
