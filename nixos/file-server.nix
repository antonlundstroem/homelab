{...}: let
  imagesPath = "/srv/images";
in {
  services.nginx = {
    enable = true;
    virtualHosts."files.lan" = {
      default = true;
      root = imagesPath;
      locations."/".extraConfig = "autoindex on;";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${imagesPath} 0755 admin users -"
  ];

  networking.firewall.allowedTCPPorts = [80];
}
