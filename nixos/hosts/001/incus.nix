{
  virtualisation.incus.enable = true;
  #virtualisation.incus.package = pkgs.incus; # do I need to set this?
  virtualisation.incus.ui.enable = true;
  #virtualisation.incus.preseed =
  networking.nftables.enable = true;
  users.users.admin.extraGroups = ["incus-admin"]; # expand this with an 'admin' module so we can set users.users.${config.admin}
}
