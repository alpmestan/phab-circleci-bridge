{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.phab-circleci-bridge;
  configFile = pkgs.writeText "phab-circleci-bridge.cfg" ''
    http_port = ${builtins.toString cfg.port}
    state_file = "${cfg.state-file}"
    github_repo_user = "${cfg.github-user}"
    github_repo_project = "${cfg.github-repo}"
    circle_api_token = "${cfg.circleci-token}"
    phabricator_api_token = "${cfg.phabricator-token}"
  '';
in {
  options.services.phab-circleci-bridge = {
    enable = mkEnableOption "GHC Phabricator <-> Circle CI bridge";
    port = mkOption {
      default = 8080;
      type = types.nullOr types.int;
      description = "Port to listen to for incoming (HTTP) requests";
    };
    github-user = mkOption {
      default = "ghc";
      type = types.nullOr types.str;
      description = "Github username";
    };
    github-repo = mkOption {
      default = "ghc-diffs";
      type = types.nullOr types.str;
      description = "Github repository name";
    };
    circleci-token = mkOption {
      default = "";
      type = types.str;
      description = "CircleCI API Token";
    };
    phabricator-token = mkOption {
      default = "";
      type = types.str;
      description = "Phabricator (Conduit) API Token";
    };
    pkg = mkOption {
      default = null;
      type = types.package;
      description = "The phab-circleci-bridge package to use";
    };
    state-file = mkOption {
      default = "/var/phab-circleci/builds.bin";
      type = types.nullOr types.str;
      description = "Desired location for the 'ongoing job queue' dumps";
    };
    user = mkOption {
      default = "phab-circleci";
      type = types.str;
      description = "UNIX user under which to run the service";
    };
    group = mkOption {
      default = "users";
      type = types.str;
      description = "UNIX group under which to run the service";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.phab-circleci-bridge = {
      description = "Phabricator <-> Circle CI bridge";
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.gitAndTools.gitFull ];
      serviceConfig = {
        ExecStart = ''
          ${cfg.pkg}/bin/phab-circleci-bridge ${configFile} +RTS -N
        '';
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
      };
    };
  };
}
