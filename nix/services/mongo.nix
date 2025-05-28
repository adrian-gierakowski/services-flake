# inspired by https://github.com/cachix/devenv/blob/6f8add968bc12bf81d845eb7dc684a0733bb1518/src/modules/services/mongodb.nix
{ pkgs
, lib
, name
, config
, ...
}:
let
  inherit (lib) types;
in
{
  options = {
    package = lib.mkPackageOption pkgs "mongodb" { };

    bind = lib.mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      description = ''
        IP address interface for MongoDB to bind to.
        Setting to `null` binds to all interfaces (using --bind_ip_all flag).
      '';
      example = "127.0.0.1";
    };

    port = lib.mkOption {
      type = types.port;
      default = 27017;
      description = "TCP port for MongoDB to accept connections.";
    };

    replicaSetName = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Name of the replica set to use for MongoDB.
        Required for change streams to work, even with a single instance.
      '';
    };

    extraArgs = lib.mkOption {
      type = types.listOf types.lines;
      default = [ ];
      example = [ "--ipv6" ];
      description = "Additional arguments to pass to both `mongod` and `mongo` commands.";
    };

    extraMongodArgs = lib.mkOption {
      type = types.listOf types.lines;
      default = [ ];
      example = [ "--noauth" ];
      description = "Additional arguments specific to `mongod` command.";
    };

    extraUnescapedMongodArgs = lib.mkOption {
      type = types.listOf types.lines;
      default = [ ];
      example = [ "--logpath=$out/mongodb.log" ];
      description = ''
        Arguments for `mongod` without shell escaping, useful when values need runtime resolution from environment variables or subshell commands.
      '';
    };

    ulimit = lib.mkOption {
      type = types.ints.unsigned;
      default = 100000;
      example = 100000;
      description = "Maximum number of open file handles (ulimit -n) before starting mongod.";
    };
  };
  config.outputs.settings.processes =
    let
      mongo = if pkgs.stdenv.isDarwin then lib.getExe pkgs.mongosh else "${config.package}/bin/mongo";
      port = toString config.port;
      mongoArgs =
        [
          "--port"
          port
        ]
        ++
        # If not explicitly binding to a specific IP, assume default host.
        (lib.optionals (config.bind == null) [
          "--host"
          config.bind
        ])
        ++ config.extraArgs;
      rsInitArgs = mongoArgs ++ [
        "--eval"
        "rs.initiate()"
      ];
      isReplicaSet = config.replicaSetName != null;
    in
    {
      "${name}" =
        let
          mongod = "${config.package}/bin/mongod";
          bindArgs =
            if config.bind == null then
              [ "--bind_ip_all" ]
            else
              [
                "--bind_ip"
                config.bind
              ];
          startArgs =
            [
              "--port"
              port
              "--dbpath"
              "${config.dataDir}"
            ]
            ++ bindArgs
            ++ (lib.optionals isReplicaSet [
              "--replSet"
              "rs0"
            ])
            ++ config.extraArgs
            ++ config.extraMongodArgs;
          startCommand = pkgs.writeShellScriptBin "mongodb-start" ''
            set -euo pipefail

            mkdir -p '${config.dataDir}'

            ulimit -n ${toString config.ulimit}
            exec ${mongod} ${lib.escapeShellArgs startArgs} ${lib.concatStringsSep " " config.extraUnescapedMongodArgs}
          '';
          probeArgs = mongoArgs ++ [
            "--eval"
            "db.adminCommand('ping')"
          ];
          probeCommand = "${mongo} ${lib.escapeShellArgs probeArgs}";
        in
        {
          command = "${startCommand}/bin/mongodb-start";

          readiness_probe = {
            exec.command = probeCommand;
            initial_delay_seconds = 2;
            period_seconds = 5;
            timeout_seconds = 4;
            success_threshold = 1;
            failure_threshold = 5;
          };

          availability.restart = "on_failure";
        };
    }
    // (lib.optionalAttrs isReplicaSet {
      "${name}-rs-init" = {
        command = "${mongo} ${lib.escapeShellArgs rsInitArgs}";
        depends_on."${name}".condition = "process_healthy";
      };
    });
}
