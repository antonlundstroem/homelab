{
  pkgs,
  lib,
  config,
  ...
}: let
  zone = "lan";
  capacity = "50GB";
  tags = ["main"]; # e.g. ["primary" "ssd"] — purely informational, surfaced in `garage status`
  buckets = ["nix-cache" "tofu-state"];

  tagFlags = lib.concatMapStringsSep " " (t: "-t ${t}") tags;
in {
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
    };

    #environmentFile = "/etc/garage/secrets.env";
    environmentFile = config.sops.secrets.garage_env.path;
  };

  systemd.services.garage-bootstrap = {
    description = "Bootstrap Garage layout, buckets, keys";
    after = ["garage.service"];
    wants = ["garage.service"];
    wantedBy = ["multi-user.target"];

    path = [pkgs.garage_2 pkgs.coreutils pkgs.gawk];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      #EnvironmentFile = "/etc/garage/secrets.env";
      EnvironmentFile = config.sops.secrets.garage_env.path;
    };

    script = ''
      set -euo pipefail

      # Wait for the admin API to answer (garage takes a sec on boot).
      for _ in $(seq 1 30); do
        garage status >/dev/null 2>&1 && break
        sleep 1
      done

      # Capture command output into variables and match in-shell, rather than
      # piping into `grep -q` / `awk … exit`. Garage v2 panics on EPIPE, so any
      # consumer that closes the pipe early will SIGPIPE garage and crash it.
      NODE_ID_RAW=$(garage node id -q)
      NODE_ID="''${NODE_ID_RAW%@*}"

      # Gate on the *committed* layout version, not the status string: v2 reports
      # "pending..." once a change is staged but not applied, which makes a
      # status-based check fail to retry across reboots if a previous apply
      # silently no-op'd.
      LAYOUT=$(garage layout show)
      CURRENT_VERSION=$(printf '%s\n' "$LAYOUT" | awk '/Current cluster layout version/ {print $NF}')

      if [[ "''${CURRENT_VERSION:-0}" -eq 0 ]]; then
        # `-t` is variadic, so it greedily eats the next positional unless we
        # cap it with `--`. Without this, NODE_ID gets parsed as another tag
        # value and garage errors with "no node-ids provided".
        garage layout assign -z ${zone} -c ${capacity} ${tagFlags} -- "$NODE_ID"

        # Wait for the stage to be visible before applying — `assign` occasionally
        # returns before the daemon has the change queryable, and `apply` silently
        # exits 0 if there's nothing staged to commit.
        for _ in $(seq 1 10); do
          STAGE=$(garage layout show)
          [[ "$STAGE" == *"STAGED ROLE CHANGES"*"$NODE_ID"* ]] && break
          sleep 1
        done

        garage layout apply --version 1

        # Verify the apply actually committed; if not, fail loudly so the next
        # rebuild surfaces the problem instead of cascading into bucket failures.
        POST_LAYOUT=$(garage layout show)
        POST_VERSION=$(printf '%s\n' "$POST_LAYOUT" | awk '/Current cluster layout version/ {print $NF}')
        if [[ "''${POST_VERSION:-0}" -lt 1 ]]; then
          echo "garage layout apply did not commit (current version still ''${POST_VERSION:-0})" >&2
          exit 1
        fi
      fi

      # Layout changes propagate asynchronously even on single-node; bucket
      # ops fail with "Layout not ready" if attempted too soon. Poll the
      # actual gate (bucket list) until it answers cleanly.
      for _ in $(seq 1 30); do
        garage bucket list >/dev/null 2>&1 && break
        sleep 1
      done

      # Buckets: create-if-missing. `bucket info` writes to /dev/null which is
      # safe (kernel never closes /dev/null), so no SIGPIPE risk here.
      for bucket in ${lib.concatStringsSep " " buckets}; do
        garage bucket info "$bucket" >/dev/null 2>&1 || garage bucket create "$bucket"
      done

      # TODO(sops): once sops-nix lands, supply LAPTOP_KEY_ID + LAPTOP_KEY_SECRET
      # via the env file and uncomment to make the laptop key fully declarative.
      # `key import` is idempotent — re-importing the same pair is a no-op.
      #
      # garage key list | grep -qw laptop || \
      #   garage key import --key-id "$LAPTOP_KEY_ID" --secret "$LAPTOP_KEY_SECRET" --name laptop
      # garage bucket allow --read --write --owner nix-cache  --key laptop
      # garage bucket allow --read --write --owner tofu-state --key laptop
    '';
  };

  networking.firewall.allowedTCPPorts = [3900];
  environment.systemPackages = [pkgs.garage_2];
}
