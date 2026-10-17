# herdr: terminal multiplexer for agent sessions, headless on the VM. Attach from
# the laptop with `herdr --remote claude` over SSH. Config is declarative via
# HERDR_CONFIG_PATH; plugin registrations (~/.config/herdr/plugins.json) stay imperative.
{
  inputs,
  pkgs,
  ...
}: let
  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default;
  configPath = "/etc/herdr/config.toml";
in {
  environment.systemPackages = [herdr];

  environment.etc."herdr/config.toml".text = ''
    onboarding = false

    [session]
    resume_agents_on_restore = true

    [server]
    headless_cols = 160
    headless_rows = 50
  '';

  # Clients (SSH sessions, `herdr --remote`) must read the same file as the server.
  environment.variables.HERDR_CONFIG_PATH = configPath;

  systemd.user.services.herdr-server = {
    description = "herdr server (headless multiplexer for Claude panes)";
    wantedBy = ["default.target"];
    unitConfig.ConditionUser = "claude";
    path = ["/run/current-system/sw"];
    environment.HERDR_CONFIG_PATH = configPath;
    serviceConfig = {
      WorkingDirectory = "/home/claude";
      ExecStart = "${herdr}/bin/herdr server";
      Restart = "always";
      RestartSec = 5;
    };
  };
}
