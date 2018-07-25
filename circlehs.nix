{ mkDerivation, aeson, base, http-client, http-client-tls, mtl
, servant, servant-client, sources ? ./circlehs , stdenv, text, time, transformers
, unordered-containers
}:
mkDerivation {
  pname = "circlehs";
  version = "0.0.3";
  src = sources;
  libraryHaskellDepends = [
    aeson base http-client http-client-tls mtl servant servant-client
    text time transformers unordered-containers
  ];
  testHaskellDepends = [ base ];
  homepage = "https://github.com/denisshevchenko/circlehs";
  description = "The CircleCI REST API for Haskell";
  license = stdenv.lib.licenses.mit;
}
