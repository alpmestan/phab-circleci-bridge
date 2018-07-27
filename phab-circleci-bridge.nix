{ mkDerivation, aeson, base, bytestring, circlehs, config-manager
, directory, filepath, git, http-api-data, http-client, http-client-tls
, mtl, process, serialise, servant-client, servant-server, stdenv
, stm, temporary, text, time, unordered-containers, warp
}:
mkDerivation {
  pname = "phab-circleci-bridge";
  version = "0.1";
  src = ./.;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    aeson base bytestring circlehs config-manager directory filepath
    http-api-data http-client http-client-tls mtl process serialise
    servant-client servant-server stm temporary text time
    unordered-containers warp
  ];
  executableToolDepends = [ git ];
  homepage = "https://github.com/alpmestan/phab-circleci-bridge";
  description = "A minimal web server that bridges GHC's phabricator and Circle CI";
  license = stdenv.lib.licenses.bsd3;
}
