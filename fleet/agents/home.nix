# Shared agent command-line wiring for the HP-OS desktop fleet.
#
# This module owns the parts that must behave the same on every desktop: the
# launchers, the activation step that applies the Pi harness settings, and the
# user service that keeps the DeepSeek Harness terminal UI installed.
#
# It does not package the agents. The private consumer supplies the packages it
# already builds, so there is one copy of each package in the fleet:
#
#   programs.hp-os-fleet.agents.packages = {
#     pi = ...;           # Pi engine
#     piHarness = ...;    # pi-harness wrappers and declared configuration
#     deepseek = ...;     # dsh CLI
#     antigravity = ...;  # Antigravity CLI (provides `agy`)
#     grok = ...;         # Grok Build CLI
#   };
#
# Credentials stay out of this public module. `pi-harness switch` reads provider
# API keys from `agents.pi.secretRoot`, which the host provisions.
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.hp-os-fleet.agents;
  pkg = cfg.packages;

  # The terminal UI is a community bundle in its own dsh profile. It reads the
  # same sessions store as the web profile, so /resume reaches web
  # conversations. `dsh-tui-ensure` owns what Nix cannot: the profile install,
  # the `dsh tui` alias, and the Node flag its direct children need.
  dshTuiPackage = "@deepseek-harness-tui/dsh-tui";
  dshTuiVersion = "0.20.1";
  dshTuiEntry = "${cfg.deepseek.home}/profiles/dsh-tui/node_modules/${dshTuiPackage}/bin/dsh-tui.js";

  dshBin =
    if pkg.deepseek == null then
      "dsh"
    else
      "${pkg.deepseek}/bin/dsh";

  dshTuiLauncher = pkgs.writeShellScriptBin "dsh-tui" ''
    export DSH_HOME=${lib.escapeShellArg cfg.deepseek.home}
    entry=${lib.escapeShellArg dshTuiEntry}
    if [ ! -f "$entry" ]; then
      echo "dsh-tui: the TUI profile is not installed; run 'dsh plugin --profile dsh-tui add ${dshTuiPackage}'" >&2
      exit 1
    fi
    exec ${pkgs.nodejs_22}/bin/node "$entry" "$@"
  '';

  # The upstream package ships both bin names; keep the short alias as well.
  dshTuiAlias = pkgs.writeShellScriptBin "dst" ''
    exec ${dshTuiLauncher}/bin/dsh-tui "$@"
  '';

  dshTuiEnsure = pkgs.writeShellScript "dsh-tui-ensure" (
    builtins.readFile ./dsh-tui-ensure.sh
  );

  # pnpm is required by `dsh plugin`. The harness wrapper does not carry it, so
  # the ensure unit supplies it on PATH together with the profile owner's node.
  dshEnsurePath = lib.makeBinPath [
    pkgs.pnpm
    pkgs.nodejs_22
    pkgs.git
    pkgs.coreutils
  ];

  # Antigravity's published binary provides `agy`. The `gemini` alias keeps the
  # command name the Pi extension and muscle memory already use.
  gemini = pkgs.writeShellScriptBin "gemini" ''
    exec ${pkg.antigravity}/bin/agy "$@"
  '';

  secretKey = name: "${cfg.pi.secretRoot}/${name}";
in
{
  options.programs.hp-os-fleet.agents = {
    enable = lib.mkEnableOption "shared agent command-line wiring" // {
      default = true;
    };

    packages = {
      pi = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Pi engine to install. Null keeps the host's own engine.";
      };
      piHarness = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "pi-harness package with the declared wrappers and configuration.";
      };
      deepseek = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "DeepSeek Harness CLI (`dsh`) to install. Null keeps the host's copy.";
      };
      antigravity = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Antigravity CLI package that provides `agy`.";
      };
      grok = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Grok Build CLI package.";
      };
    };

    pi = {
      enable = lib.mkEnableOption "the Pi coding agent and its harness" // {
        default = true;
      };
      secretRoot = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.config/pi/secrets";
        description = ''
          Directory that holds the provider API keys as single-line files:
          `deepseek-api-key`, `kimi-k3-api-key`, and
          `glm-coding-pro-api-key`. The host provisions these files.
        '';
      };
      switchOnActivation = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run `pi-harness switch` during Home Manager activation when the
          provider keys are present. Without the keys, activation prints the
          command to run after provisioning.
        '';
      };
    };

    deepseek = {
      enable = lib.mkEnableOption "the DeepSeek Harness CLI" // {
        default = true;
      };
      home = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.dsh";
        description = ''
          Harness state directory. Give this CLI its own directory on a host
          that also runs a differently versioned harness web service, so
          neither version migrates the other's sessions and settings.
        '';
      };
      tui = {
        enable = lib.mkEnableOption "the DeepSeek Harness terminal UI launchers" // {
          default = true;
        };
      };
    };

    antigravity = {
      enable = lib.mkEnableOption "the Antigravity CLI and the `gemini` alias" // {
        default = true;
      };
    };

    grok = {
      enable = lib.mkEnableOption "the Grok Build CLI" // {
        default = true;
      };
    };
  };

  config = lib.mkIf (config.programs.hp-os-fleet.enable && cfg.enable) {
    home.packages =
      lib.optional (cfg.pi.enable && pkg.pi != null) pkg.pi
      ++ lib.optional (cfg.pi.enable && pkg.piHarness != null) pkg.piHarness
      ++ lib.optional (cfg.deepseek.enable && pkg.deepseek != null) pkg.deepseek
      ++ lib.optionals (cfg.deepseek.enable && cfg.deepseek.tui.enable) [
        dshTuiLauncher
        dshTuiAlias
      ]
      ++ lib.optionals (cfg.antigravity.enable && pkg.antigravity != null) [
        pkg.antigravity
        gemini
      ]
      ++ lib.optional (cfg.grok.enable && pkg.grok != null) pkg.grok;

    home.activation.piHarness = lib.mkIf (
      cfg.pi.enable && cfg.pi.switchOnActivation && pkg.piHarness != null
    ) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        if [ -s ${lib.escapeShellArg (secretKey "deepseek-api-key")} ]; then
          run ${pkg.piHarness}/bin/pi-harness switch --secret-root ${lib.escapeShellArg cfg.pi.secretRoot}
        else
          echo "pi-harness: provider keys are missing under ${cfg.pi.secretRoot}." >&2
          echo "pi-harness: provision them, then run 'pi-harness switch --secret-root ${cfg.pi.secretRoot}'." >&2
        fi
      ''
    );

    systemd.user.services.dsh-tui-ensure = lib.mkIf (cfg.deepseek.enable && cfg.deepseek.tui.enable) {
      Unit = {
        Description = "Keep the DeepSeek Harness TUI profile installed and usable";
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = [
          "DSH_BIN=${dshBin}"
          "DSH_HOME=${cfg.deepseek.home}"
          "DSH_TUI_PACKAGE=${dshTuiPackage}"
          "DSH_TUI_VERSION=${dshTuiVersion}"
          "PYTHON=${pkgs.python3}/bin/python3"
          "HOME=${config.home.homeDirectory}"
          "PATH=${dshEnsurePath}"
        ];
        ExecStart = "${dshTuiEnsure}";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
