{ config, lib, ... }:

let
  cfg = config.services.home-elixir;

  haConfigured = cfg.homeAssistant.host != null && cfg.homeAssistant.token != null;

  # A host containing "://" is used verbatim as the WebSocket URL; a bare
  # host is combined with port (+ tls) into ws(s)://host:port/api/websocket.
  haUrl =
    if cfg.homeAssistant.host == null then
      null
    else if lib.strings.hasInfix "://" cfg.homeAssistant.host then
      cfg.homeAssistant.host
    else
      let
        scheme = if cfg.homeAssistant.tls then "wss" else "ws";
      in
      "${scheme}://${cfg.homeAssistant.host}:${toString cfg.homeAssistant.port}/api/websocket";

  # Consumed by config/runtime.exs in the release via HOME_ELIXIR_CONFIG.
  # No secrets here: the file lands world-readable in the Nix store.
  homeElixirCfg =
    lib.optionalAttrs haConfigured { ha_url = haUrl; }
    // {
      web_host = cfg.host;
      web_port = cfg.port;
      node_name = cfg.nodeName;
      node_cookie = cfg.nodeCookie;
      flows_dir = cfg.flowsDir;
    }
    // cfg.config;

  configFile = lib.mkIf cfg.enable (
    config.pkgs.writeText "home-elixir-config.json" (
      builtins.toJSON {
        home_elixir = homeElixirCfg;
        mnesia = { dir = cfg.mnesiaDir; };
      }
    )
  );
in
{
  options.services.home-elixir = {
    enable = lib.mkEnableOption "HomeElixir, a Node-RED-style flow engine for Home Assistant";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The home-elixir package (from this flake's packages).";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Web UI bind address. Dotted-quad IP only — the app's parser rejects hostnames.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
    };

    homeAssistant = lib.mkOption {
      type = lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Home Assistant WebSocket endpoint: a bare host (combined with port/tls) or a full ws(s)://... URL. null runs without HA.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 8123;
            description = "Used only when host is a bare host.";
          };
          tls = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Use wss when composing the URL from a bare host.";
          };
          token = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              HA long-lived access token. Passed as the HA_TOKEN env var; systemd
              reads unit config as root, so the value only appears in the
              root-only /run/booted-system config. For stronger isolation use an
              agenix-style secret.
            '';
          };
        };
      };
    };

    mnesiaDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/home-elixir/mnesia";
      description = "Mnesia flow-state schema dir (disk persistence). The parent dir must exist and be writable by the service user (StateDirectory covers the default).";
    };

    flowsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/home-elixir/flows";
      description = "Where flow .ex files live. Seeded from the package's flows/ on first start; editable via the web UI.";
    };

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = "home_elixir";
      description = "BEAM node name (ERL_AFLAGS). Must be a named node for Mnesia disk mode; also the name the dev shell connects to (iex --remsh <name>).";
    };

    nodeCookie = lib.mkOption {
      type = lib.types.str;
      default = "home_elixir";
      description = "BEAM distribution cookie, shared with the dev shell.";
    };

    config = lib.mkOption {
      type = lib.types.attrsOf lib.types.json;
      default = { };
      description = "Extra config :home_elixir options (llm_url, llm_model, llm_api_key, ...), merged over this module's own keys. Written to a world-readable Nix store file — do not put essential secrets here.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.home-elixir = {
      isSystemUser = true;
      group = "home-elixir";
      description = "HomeElixir";
    };
    users.groups.home-elixir = { };

    environment.etc."home-elixir/config.json".source = configFile;

    systemd.services.home-elixir = {
      description = "HomeElixir flow engine";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "home-elixir";
        StateDirectory = "home-elixir";
        # mix for runtime Dep.install (flows pulling Hex deps); stdenv.cc for
        # NIF deps.
        Path = "${config.pkgs.elixir}/bin:${config.pkgs.stdenv.cc}/bin";
        Environment = [
          "ERL_AFLAGS=-sname ${cfg.nodeName} -setcookie ${cfg.nodeCookie}"
          "MIX_ENV=prod"
          # Erlang needs an existing HOME for its cookie; the runtime dep
          # cache (~/.cache/home_elixir/deps) lives under the state dir.
          "HOME=/var/lib/home-elixir"
          "HOME_ELIXIR_CONFIG=/etc/home-elixir/config.json"
        ]
        ++ lib.optional haConfigured "HA_TOKEN=${cfg.homeAssistant.token}";
        ExecStartPre = [
          # Seed the flows dir from the package on first start only.
          "${config.pkgs.bash}/bin/bash -c 'mkdir -p ${cfg.flowsDir} && { [ -n \"$(ls -A ${cfg.flowsDir} 2>/dev/null)\" ] || cp -r ${cfg.package}/flows/. ${cfg.flowsDir}/; }'"
        ];
        ExecStart = "${cfg.package}/bin/home_elixir start";
      };
    };
  };
}
