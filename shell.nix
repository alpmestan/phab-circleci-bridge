{ pkgs ? import <nixpkgs> {}
, compiler ? "ghc822"
}:

with pkgs;

let
  ghc = haskell.packages.${compiler}.ghcWithPackages (ps: [ps.cabal-install]);
in

stdenv.mkDerivation {
    name = "ghc-cabal-dev";
    buildInputs = [ ghc zlib wget ];
    shellHook = ''
      eval $(grep export ${ghc}/bin/ghc)
      export LD_LIBRARY_PATH="${zlib}/lib";
    '';
}
