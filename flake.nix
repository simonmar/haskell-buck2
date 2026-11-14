{
  description = "haskell-buck2: buck2 rules for Haskell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Keep in step with tested-with in
      # tools/buck2-ghc-worker/buck2-ghc-worker.cabal and the matrices of
      # .github/workflows/buck2-ghc-worker.yml and rules.yml.
      ghcs = [ "ghc967" "ghc984" "ghc9103" "ghc9124" "ghc9141" ];
      # What tests/rules/run.sh needs besides GHC. clang: the C compiler of
      # buck2's default C toolchain. bazel-remote: the remote cache of
      # check_cache (BAZEL_REMOTE).
      testTools = pkgs: [ pkgs.buck2 pkgs.python3 pkgs.clang pkgs.bazel-remote ];
    in
    {
      checks = forAllSystems (pkgs:
        let
          inherit (nixpkgs) lib;
          inherit (pkgs.haskell.lib.compose) appendConfigureFlags doBenchmark doCheck enableSharedExecutables overrideCabal;
          clean = src: lib.cleanSourceWith {
            inherit src;
            filter = path: type: !(lib.hasPrefix "dist-" (baseNameOf path) || baseNameOf path == "buck-out");
          };
          # We don't care about tests or dependencies here, to keep things light as these are mostly not cached by upstream.
          packages = ghc: pkgs.haskell.packages.${ghc}.override {
            overrides = self: super: {
              mkDerivation = args: super.mkDerivation (args // { doCheck = false; doHaddock = false; });
            };
          };
          # The worker's package. Its src/ links to the modules that it shares
          # with the rules' compile tool, so the source includes those too.
          workerSrc = clean (lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [ ./tools/buck2-ghc-worker ./prelude/haskell/tools/ghc-api ];
          });
          # The tests run the worker that they were built with. Unlike `cabal
          # test`, `Setup test` doesn't put the worker on PATH, so preCheck
          # points BUCK2_GHC_WORKER at it. The cabal file links the worker
          # dynamically (-dynamic), so it needs the rpath of its installed
          # library, rather than the build's.
          worker = ghc:
            overrideCabal (old: { preCheck = (old.preCheck or "") + "export BUCK2_GHC_WORKER=$PWD/dist/build/buck2-ghc-worker/buck2-ghc-worker\n"; })
              (appendConfigureFlags [ "--ghc-option=-Werror" ]
                (enableSharedExecutables (doCheck (doBenchmark (overrideCabal (old: { src = workerSrc; postUnpack = "sourceRoot+=/tools/buck2-ghc-worker"; })
                  ((packages ghc).callCabal2nix "buck2-ghc-worker" "${workerSrc}/tools/buck2-ghc-worker" { }))))));
          # The tests run inside a file system laid out as on most Linux
          # systems, with /usr/bin/env, which the build sandbox lacks. buck2
          # runs some programs through scripts that start with
          # `#!/usr/bin/env bash`, such as the launcher of an sh_binary.
          fhs = pkgs.buildFHSEnv {
            name = "rules-tests-fhs";
            targetPkgs = p: [ p.coreutils p.bash ];
            runScript = "bash";
          };
          rules = ghc: withWorker: pkgs.runCommandCC "rules-tests-${lib.optionalString withWorker "worker-"}${ghc}"
            {
              nativeBuildInputs = testTools pkgs;
              BAZEL_REMOTE = "${pkgs.bazel-remote}/bin/bazel-remote";
              BUCK2_GHC_WORKER = lib.optionalString withWorker "${worker ghc}/bin/buck2-ghc-worker";
              src = clean (lib.cleanSourceWith {
                src = ./.;
                filter = path: type: !(lib.hasPrefix (toString ./tools) path || lib.hasPrefix (toString ./.github) path);
              });
            } ''
            export HOME=$TMPDIR
            # The buck2 daemon reads them as it starts, though nothing here
            # goes to the network.
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            cp -r $src repo
            chmod -R u+w repo
            cd repo
            patchShebangs tests
            ${fhs}/bin/rules-tests-fhs tests/rules/run.sh ${pkgs.haskell.compiler.${ghc}}/bin $TMPDIR/work
            touch $out
          '';
        in
        lib.listToAttrs (lib.concatMap (ghc: [
          { name = "worker-${ghc}"; value = worker ghc; }
        ] ++ lib.optionals pkgs.stdenv.isLinux [
          # We only run the rules tests on linux currently
          { name = "rules-${ghc}"; value = rules ghc false; }
          { name = "rules-worker-${ghc}"; value = rules ghc true; }
        ]) ghcs));

      devShells = forAllSystems (pkgs:
        let
          shell = ghc: pkgs.mkShell {
            packages = [ pkgs.haskell.compiler.${ghc} pkgs.cabal-install ] ++ testTools pkgs;
            BAZEL_REMOTE = "${pkgs.bazel-remote}/bin/bazel-remote";
          };
        in
        nixpkgs.lib.genAttrs ghcs shell // { default = shell "ghc9124"; });
    };
}
