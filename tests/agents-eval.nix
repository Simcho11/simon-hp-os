{ nixpkgs, home-manager }:
let
  systems = [ "aarch64-linux" "x86_64-linux" ];

  stub = system: name: nixpkgs.legacyPackages.${system}.runCommand name { } "mkdir -p $out";

  supplied = system: {
    pi = stub system "pi-coding-agent-test";
    piHarness = stub system "pi-harness-test";
    deepseek = stub system "deepseek-harness-test";
    antigravity = stub system "antigravity-cli-test";
    grok = stub system "grok-cli-test";
  };

  evaluate = system: extraModules:
    (home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs { inherit system; };
      modules = [
        ../fleet/agents/home.nix
        ({ lib, ... }: {
          options.programs.hp-os-fleet.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          config = {
            home.username = "fleet-test";
            home.homeDirectory = "/home/fleet-test";
            home.stateVersion = "26.05";
          };
        })
        extraModules
      ];
    }).config;

  names = system: extraModules: map (package: package.name) (evaluate system extraModules).home.packages;

  withPackages = system: {
    programs.hp-os-fleet.agents.packages = supplied system;
  };

  contract = system:
    let
      wired = evaluate system (withPackages system);
      wiredNames = names system (withPackages system);
      unwired = names system { };
      disabled = names system (withPackages system // {
        programs.hp-os-fleet.agents.enable = false;
      });
      has = prefix: builtins.any (
        name: builtins.substring 0 (builtins.stringLength prefix) name == prefix
      );
    in
    assert has "pi-coding-agent-test" wiredNames;
    assert has "pi-harness-test" wiredNames;
    assert has "deepseek-harness-test" wiredNames;
    assert builtins.elem "dsh-tui" wiredNames;
    assert builtins.elem "dst" wiredNames;
    assert has "antigravity-cli-test" wiredNames;
    assert builtins.elem "gemini" wiredNames;
    assert has "grok-cli-test" wiredNames;
    assert wired.home.activation ? piHarness;
    assert wired.systemd.user.services ? dsh-tui-ensure;
    # Without supplied packages the module stays inert, which keeps hosts that
    # already own the CLIs free of duplicate installs.
    assert !(has "pi-harness-test" unwired);
    assert !(has "deepseek-harness-test" unwired);
    assert !(builtins.elem "gemini" unwired);
    # The enable switch removes every package and the activation step.
    assert !(builtins.elem "dsh-tui" disabled);
    assert !(has "pi-harness-test" disabled);
    {
      inherit system;
      packages = wiredNames;
    };
in
builtins.listToAttrs (map (system: {
  name = system;
  value = {
    fleet-agents-eval =
      nixpkgs.legacyPackages.${system}.runCommand "fleet-agents-eval-${system}" { } ''
        {
          echo "system=${system}"
          printf '%s\n' ${nixpkgs.lib.escapeShellArgs (contract system).packages}
        } > $out
      '';
  };
}) systems)
