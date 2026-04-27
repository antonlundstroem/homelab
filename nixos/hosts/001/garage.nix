{pkgs, ...}: {
  services.garage = {
    enable = true;
    package = pkgs.garage_2;

    settings = {
      metadata_dir = "/var/lib/garage/meta";
      data_dir = "/var/lib/garage/data";

      db_engine = "lmdb";
      replication_factor = 1;

      rpc_bind_addr = "[::]:3901";
      rpc_public_addr = "127.0.0.1:3901";
      # rpc_secret < - garage rpc secret -- SOPS

      s3_api = {
        api_bind_addr = "[::]:3900";
        s3_region = "garage";
        root_domain = ".s3.garage.lan";
      };

      s3_web = {
        bind_addr = "[::]:3902";
        root_domain = ".web.garage.lan";
        index = "index.html";
      };

      admin = {
        api_bind_addr = "[::]:3903";
        # admin_token
        # metrics_token
      };

      environmentFile = "/etc/garage/secrets.env";
    };

    networking.firewall.allowedTCPPorts = [3900];
    environment.systemPackages = [pkgs.garage_2];
  };
}
