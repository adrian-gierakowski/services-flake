{ pkgs, lib, name, config, ... }:
let
  inherit (lib) types;
in
{
  options = {
    package = lib.mkPackageOption pkgs "mongodb-ce" { };

    bind = lib.mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      description = ''
        The IP interface to bind to.
        `null` means "all interfaces".
      '';
      example = "127.0.0.1";
    };

    port = lib.mkOption {
      type = types.port;
      default = 27017;
      description = ''
        The TCP port to accept connections.
      '';
    };

    user = lib.mkOption {
      type = types.str;
      default = "default";
      description = ''
        The name of the first user to create in
        Mongo.
      '';
      example = "my_user";
    };

    password = lib.mkOption {
      type = types.str;
      default = "password";
      description = ''
        The password of the user to configure
        for initial access.
      '';
    };

    extraConfig = lib.mkOption {
      type = types.lines;
      default = "";
      description = "Additional text to be appended to `mongodb.conf`.";
    };

    replicaSetName = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The name of the replica set to configure.";
      example = "rs0";
    };

    ulimit = lib.mkOption {
      type = types.ints.unsigned;
      default = 100000;
      description = "The maximum number of open file descriptors for mongod.";
    };
  };

  config = {
    outputs = {
      settings = {
        processes = {
          "${name}" =
            let
              mongoConfig = pkgs.writeText "mongodb.conf" ''
                net.port: ${toString config.port}
                net.bindIp: ${config.bind}
                storage.dbPath: ${config.dataDir}
                ${lib.optionalString (config.replicaSetName != null) ''
                  replication:
                    replSetName: "${config.replicaSetName}"
                ''}
                ${config.extraConfig}
              '';

              startScript = pkgs.writeShellApplication {
                name = "start-mongodb";
                runtimeInputs = [ pkgs.coreutils config.package ];
                text = ''
                  export MONGODATA="${config.dataDir}"

                  if [[ ! -d "$MONGODATA" ]]; then
                    mkdir -p "$MONGODATA"
                  fi

                  ulimit -n ${toString config.ulimit}

                  exec mongod --config "${mongoConfig}"
                '';
              };
            in
            {
              command = startScript;

              readiness_probe = {
                exec.command = ''
                  HOST_ARG=""
                  if [[ -n "${config.bind}" && "${config.bind}" != "0.0.0.0" && "${config.bind}" != "::" ]]; then
                    HOST_ARG="--host ${config.bind}"
                  fi
                  ${pkgs.mongosh}/bin/mongosh $HOST_ARG --port ${toString config.port} --eval "db.version()" > /dev/null 2>&1
                '';
                initial_delay_seconds = 2;
                period_seconds = 10;
                timeout_seconds = 4;
                success_threshold = 1;
                failure_threshold = 5;
              };

              # https://github.com/F1bonacc1/process-compose#-auto-restart-if-not-healthy
              availability = {
                restart = "on_failure";
                max_restarts = 5;
              };
            };
          "${name}-configure" =
            let
              configScript = pkgs.writeShellApplication {
                name = "configure-mongo";
                text = ''
                  ${lib.optionalString (config.replicaSetName != null) ''
                    # Configure replica set
                    echo "Configuring replica set ${config.replicaSetName}..."
                    REPL_HOST_ARG=""
                    if [[ -n "${config.bind}" && "${config.bind}" != "0.0.0.0" && "${config.bind}" != "::" ]]; then
                      REPL_HOST_ARG="--host ${config.bind}"
                    fi

                    # Check if replica set is already configured
                    if ! ${pkgs.mongosh}/bin/mongosh $REPL_HOST_ARG --port ${toString config.port} --eval "try { rs.status().ok } catch (e) { quit(10) }" --quiet; then
                      ${pkgs.mongosh}/bin/mongosh $REPL_HOST_ARG --port ${toString config.port} --eval "rs.initiate({ _id: \"${config.replicaSetName}\", members: [ { _id: 0, host: \"${config.bind}:${toString config.port}\" } ] })"
                      
                      echo "Waiting for replica set to stabilize..."
                      success=0
                      for i in $(seq 1 15); do
                        # Try to check if this node has become primary.
                        # rs.isMaster().ismaster returns true if primary, false otherwise.
                        # If the command fails (e.g. server not ready), mongosh will exit with a non-zero code due to quit(10).
                        if ${pkgs.mongosh}/bin/mongosh $REPL_HOST_ARG --port ${toString config.port} --eval "try { if (rs.isMaster().ismaster) { quit(0) } else { quit(1) } } catch (e) { quit(10) }" --quiet; then
                          echo "Replica set primary is active."
                          success=1
                          break
                        fi
                        echo "Attempt $i/15: Replica set not yet stable, retrying in 2 seconds..."
                        sleep 2
                      done

                      if [[ $success -eq 0 ]]; then
                        echo "Error: Replica set did not stabilize after 30 seconds."
                        exit 1
                      fi
                    else
                      echo "Replica set ${config.replicaSetName} already configured."
                    fi
                  ''}

                  # Configure user
                  if ! test -e "${config.dataDir}/.auth_configured"; then
                    USER_HOST_ARG=""
                    if [[ -n "${config.bind}" && "${config.bind}" != "0.0.0.0" && "${config.bind}" != "::" ]]; then
                      USER_HOST_ARG="--host ${config.bind}"
                    fi
                    ${pkgs.mongosh}/bin/mongosh $USER_HOST_ARG --port ${toString config.port} <<EOF
                      use admin
                      db.createUser({
                        user: "${config.user}",
                        pwd: "${config.password}",
                        roles: [
                          { role: "userAdminAnyDatabase", db: "admin" },
                          { role: "dbAdminAnyDatabase", db: "admin" },
                          { role: "readWriteAnyDatabase", db: "admin" }
                        ]
                      })
                  EOF
                    touch "${config.dataDir}/.auth_configured"
                  else
                    echo "Database previously configured. If this is in error, remove"
                    echo "the file at '${config.dataDir}/.auth_configured' and restart"
                    echo "this process."
                  fi
                '';
              };
            in
            {
              command = configScript;
              depends_on."${name}".condition = "process_healthy";
            };
        };
      };
    };
  };
}
