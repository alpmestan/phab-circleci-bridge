{ pkgs ? import <nixpkgs> {} }:

let
  tweak = p: pkgs.haskell.lib.dontCheck (pkgs.haskell.lib.doJailbreak p);
  hsPkgs = pkgs.haskell.packages.ghc822.override ({
    all-cabal-hashes = pkgs.fetchurl {
      url = "https://github.com/commercialhaskell/all-cabal-hashes/archive/a4416d2560b0ef1ce598737259b4fa989694ac57.tar.gz";
      sha256 = "1i2ifla8g7znqv82qja21aw0251jnx2cpj4zmqkqjy8bziq7l2yd";
    };
    overrides = self: super: {
      circlehs = tweak (super.callPackage ./circlehs.nix {
        sources = pkgs.fetchFromGitHub {
          owner = "alpmestan";
          repo = "circlehs";
          rev = "999dc797970c394016ad31ef219de4048acc9e0e";
          sha256 = "090b2zdpg2kh6p8yd9pl5jvnpgy00zi10cgnwiszzz02b0hgrg6d";
        };
      });
      servant = tweak (self.callHackage "servant" "0.14" {});
      servant-client = tweak (self.callHackage "servant-client" "0.14" {});
      servant-client-core = tweak (self.callHackage "servant-client-core" "0.14" {});
      servant-server = tweak (self.callHackage "servant-server" "0.14" {});
    };
  });
in

  (hsPkgs.callPackage ./phab-circleci-bridge.nix {}).overrideAttrs (old: {
    buildInputs = old.buildInputs ++ [pkgs.gitAndTools.gitFull];
  })
