{ ... }:
{
  system.stateVersion = "25.11";

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # users.users.root.openssh.authorizedKeys.keys = [
  #   "ssh-ed25519 AAAA... your key here"
  # ];
}
