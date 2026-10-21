{
  description = "haskell-buck2: buck2 rules for Haskell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Keep in step with the matrix of .github/workflows/rules.yml.
      ghcs = [ "ghc967" "ghc984" "ghc9103" "ghc9124" "ghc9141" ];
      # What tests/rules/run.sh needs besides GHC. clang: the C compiler of
      # buck2's default C toolchain.
      testTools = pkgs: [ pkgs.buck2 pkgs.python3 pkgs.clang ];
    in
    {
      checks = forAllSystems (pkgs:
        let
          inherit (nixpkgs) lib;
          clean = src: lib.cleanSourceWith {
            inherit src;
            filter = path: type: !(lib.hasPrefix "dist-" (baseNameOf path) || baseNameOf path == "buck-out");
          };
          rules = ghc: pkgs.runCommandCC "rules-tests-${ghc}"
            {
              nativeBuildInputs = testTools pkgs;
              src = clean (lib.cleanSourceWith {
                src = ./.;
                filter = path: type: !(lib.hasPrefix (toString ./.github) path);
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
            tests/rules/run.sh ${pkgs.haskell.compiler.${ghc}}/bin $TMPDIR/work
            touch $out
          '';
        in
        # We only run the rules tests on linux currently
        lib.optionalAttrs pkgs.stdenv.isLinux
          (lib.listToAttrs (map (ghc: { name = "rules-${ghc}"; value = rules ghc; }) ghcs)));

      devShells = forAllSystems (pkgs:
        let
          shell = ghc: pkgs.mkShell {
            packages = [ pkgs.haskell.compiler.${ghc} pkgs.cabal-install ] ++ testTools pkgs;
          };
        in
        nixpkgs.lib.genAttrs ghcs shell // { default = shell "ghc9124"; });
    };
}
