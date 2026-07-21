{
  description = "flake for graphify using uv2nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    py-harbor = {
      url = "git+https://codeberg.org/caniko/py-harbor.git?ref=trunk";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.pyproject-build-systems.follows = "pyproject-build-systems";
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];

      flake.nixosModules.default = {
        lib,
        pkgs,
        ...
      }: {
        imports = [./nix/nixos-module.nix];
        services.graphify.package = lib.mkDefault inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.full;
      };

      perSystem = {
        pkgs,
        lib,
        ...
      }: let
        pyproject = lib.importTOML ./pyproject.toml;
        projectMeta = pyproject.project;

        py = inputs.py-harbor.lib;

        workspace = py.loadUvWorkspace {workspaceRoot = ./.;};

        editableOverlay = workspace.mkEditablePyprojectOverlay {
          root = "$REPO_ROOT";
        };

        python = pkgs.python312;

        pythonSet = py.mkUvPythonSet {
          inherit pkgs python;
          workspaceRoot = ./.;
          sourcePreference = "wheel";
          dependencies = workspace.deps.all;
          pyprojectOverrides = final: prev: {
            numba = prev.numba.overrideAttrs (old: {
              buildInputs = (old.buildInputs or []) ++ [pkgs.tbb];
            });

            nuitka = prev.nuitka.overrideAttrs (old: {
              nativeBuildInputs =
                (old.nativeBuildInputs or [])
                ++ final.resolveBuildSystem {setuptools = [];};
            });

            jieba = prev.jieba.overrideAttrs (old: {
              nativeBuildInputs =
                (old.nativeBuildInputs or [])
                ++ final.resolveBuildSystem {setuptools = [];};
            });

            tree-sitter-dm = prev.tree-sitter-dm.overrideAttrs (old: {
              nativeBuildInputs =
                (old.nativeBuildInputs or [])
                ++ final.resolveBuildSystem {setuptools = [];};
            });

            graphifyy = prev.graphifyy.overrideAttrs (old: {
              passthru =
                (old.passthru or {})
                // {
                  tests = let
                    testVenv = final.mkVirtualEnv "graphify-test-env" (workspace.deps.default
                      // {
                        graphifyy = ["dev" "ollama" "acp"];
                      });
                  in
                    (old.passthru.tests or {})
                    // {
                      pytest = pkgs.stdenv.mkDerivation {
                        name = "${final.graphifyy.name}-pytest";
                        src = ./.;
                        nativeBuildInputs = [testVenv pkgs.git];
                        dontConfigure = true;

                        buildPhase = ''
                          runHook preBuild
                          export HOME=''${PWD}/home
                          pytest
                          runHook postBuild
                        '';

                        installPhase = ''
                          runHook preInstall
                          touch $out
                          runHook postInstall
                        '';
                      };
                    };
                };
            });
          };
        };

        editablePythonSet = pythonSet.overrideScope editableOverlay;
        virtualenv = editablePythonSet.mkVirtualEnv "graphify-dev-env" workspace.deps.all;

        graphifyEnv = pythonSet.mkVirtualEnv "graphify-env" workspace.deps.default;
        graphifyAcpEnv = pythonSet.mkVirtualEnv "graphify-acp-env" (workspace.deps.default
          // {
            graphifyy = ["acp"];
          });
        graphifyOpenaiEnv = pythonSet.mkVirtualEnv "graphify-openai-env" (workspace.deps.default
          // {
            graphifyy = ["openai"];
          });
        graphifyFullEnv = pythonSet.mkVirtualEnv "graphify-full-env" (workspace.deps.default
          // {
            graphifyy = ["all"];
          });

        # Export stable entry points while exposing the environment contract
        # used by downstream shells and services.
        mkGraphifyPackage = {
          environment,
          suffix ? "",
        }:
          py.mkPythonApplicationPackage {
            inherit pkgs environment;
            name = "${projectMeta.name}${suffix}-${projectMeta.version}";
            scripts = ["graphify" "graphify-mcp"];
            includeEnvironment = false;
            passthru = {
              graphifyEnv = environment;
            };
            meta = {
              description = projectMeta.description;
              homepage = projectMeta.urls.Homepage;
              license = lib.licenses.mit;
              mainProgram = "graphify";
              platforms = lib.platforms.unix;
            };
          };

        graphifyPackage = mkGraphifyPackage {environment = graphifyEnv;};
        graphifyFullPackage = mkGraphifyPackage {
          environment = graphifyFullEnv;
          suffix = "-full";
        };
        graphifyAcpPackage = mkGraphifyPackage {
          environment = graphifyAcpEnv;
          suffix = "-acp";
        };
        graphifyOpenaiPackage = mkGraphifyPackage {
          environment = graphifyOpenaiEnv;
          suffix = "-openai";
        };

        moduleSample = inputs.nixpkgs.lib.nixosSystem {
          system = pkgs.stdenv.hostPlatform.system;
          specialArgs.graphifyPackage = graphifyFullPackage;
          modules = [
            ./nix/nixos-module.nix
            {
              system.stateVersion = "24.11";
              services.graphify = {
                enable = true;
                instances.postgres-only = {
                  source.postgresql = {
                    enable = true;
                    database = "catalog";
                  };
                  extraction.noCluster = true;
                };
                instances.matrix = {
                  source = {
                    path = "/srv/source";
                    cargo = true;
                    postgresql = {
                      enable = true;
                      host = "/run/postgresql";
                      database = "app";
                      user = "graphify";
                      sslMode = "disable";
                      pgpassFile = "/run/keys/pgpass";
                      systemdService = "postgresql.service";
                    };
                  };
                  extraction = {
                    mode = "deep";
                    codeOnly = true;
                    noCluster = true;
                    dedup = true;
                    googleWorkspace = true;
                    global = true;
                    tag = "matrix";
                    maxWorkers = 2;
                    tokenBudget = 4096;
                    maxConcurrency = 2;
                    apiTimeout = 30;
                    resolution = 1.25;
                    excludeHubs = 0.95;
                    excludes = ["vendor" "target"];
                    timing = true;
                    onCalendar = "hourly";
                  };
                  llm = {
                    backend = "openai";
                    model = "test-model";
                    baseUrl = "http://127.0.0.1:8081/v1";
                    apiKeyFile = "/run/keys/openai";
                  };
                  watch = {
                    enable = true;
                    debounce = 1.5;
                  };
                  server = {
                    enable = true;
                    host = "0.0.0.0";
                    port = 8080;
                    path = "/mcp";
                    jsonResponse = true;
                    stateless = true;
                    sessionTimeout = 0;
                    apiKeyFile = "/run/keys/mcp";
                    openFirewall = true;
                  };
                  exports = {
                    neo4j = {
                      enable = true;
                      uri = "bolt://127.0.0.1:7687";
                      passwordFile = "/run/keys/neo4j";
                    };
                    falkordb = {
                      enable = true;
                      uri = "falkordb://127.0.0.1:6379";
                      onCalendar = "daily";
                    };
                  };
                  environment.GRAPHIFY_MAX_RETRIES = "3";
                  environmentFiles = ["/run/keys/graphify.env"];
                };
              };
            }
          ];
        };
      in {
        formatter = pkgs.writeShellApplication {
          name = "graphify-nix-format";
          runtimeInputs = [pkgs.alejandra];
          text = ''
            has_path=0
            for argument in "$@"; do
              case "$argument" in
                -*) ;;
                *) has_path=1 ;;
              esac
            done
            if [ "$has_path" -eq 0 ]; then
              set -- "$@" .
            fi
            exec alejandra "$@"
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            virtualenv
            pkgs.uv
            pkgs.python3Packages.pytest
          ];
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = editablePythonSet.python.interpreter;
            UV_PYTHON_DOWNLOADS = "never";
            UV_PROJECT_ENVIRONMENT = virtualenv.outPath;
            VIRTUAL_ENV = virtualenv.outPath;
            GRAPHIFY_PYTHON = "${virtualenv}/bin/python";
          };

          shellHook = ''
            unset PYTHONPATH
            export REPO_ROOT=$(git rev-parse --show-toplevel)
          '';
        };

        packages = {
          default = graphifyPackage;
          acp = graphifyAcpPackage;
          openai = graphifyOpenaiPackage;
          full = graphifyFullPackage;
        };

        checks = {
          inherit (pythonSet.graphifyy.passthru.tests) pytest;
          full-package = pkgs.runCommand "graphify-full-package-check" {} ''
            test -x ${graphifyFullPackage}/bin/graphify
            test -x ${graphifyFullPackage}/bin/graphify-mcp
            test -x ${graphifyFullPackage.passthru.pythonInterpreter}
            ${graphifyFullPackage.passthru.pythonInterpreter} -c 'import acp, anthropic, boto3, falkordb, mcp, neo4j, openai, psycopg'
            touch $out
          '';
          nixos-module = pkgs.runCommand "graphify-nixos-module-check" {} ''
            test '${moduleSample.config.services.graphify.instances.matrix.source.postgresql.database}' = app
            test '${toString moduleSample.config.services.graphify.instances.matrix.server.port}' = 8080
            test '${toString moduleSample.config.networking.firewall.allowedTCPPorts}' = 8080
            case ${lib.escapeShellArg (toString moduleSample.config.systemd.services.graphify-matrix-extract.serviceConfig.ExecStart)} in
              *graphify-matrix-extract*) ;;
              *) echo 'missing Graphify extract service' >&2; exit 1 ;;
            esac
            test '${moduleSample.config.services.graphify.instances.matrix.exports.neo4j.uri}' = 'bolt://127.0.0.1:7687'
            test -n '${toString moduleSample.config.systemd.services.graphify-matrix-neo4j.serviceConfig.ExecStart}'
            test '${toString moduleSample.config.systemd.timers.graphify-matrix-falkordb.timerConfig.OnCalendar}' = daily
            touch $out
          '';
        };

        apps.default = {
          type = "app";
          program = "${graphifyPackage}/bin/graphify";
          meta = graphifyPackage.meta;
        };
      };
    };
}
