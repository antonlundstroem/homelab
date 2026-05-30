{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-CHANGE";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          swap = {
            size = "4G";
            content.type = "swap";
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    zpool.rpool = {
      type = "zpool";
      options = {
        ashift = "12";
        autotrim = "on";
      };
      rootFsOptions = {
        compression = "zstd";
        atime = "off";
        xattr = "sa";
        acltype = "posixacl";
        mountpoint = "none";
        canmount = "off";
      };
      datasets = {
        root = {
          type = "zfs_fs";
          mountpoint = "/";
          options.mountpoint = "legacy";
          # OS floor: guarantee /'s dataset room from pool free space so a full
          # (thin, unquota'd) Incus VM can't starve the host. See nix below.
          options.reservation = "5G";
        };
        nix = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options.mountpoint = "legacy";
          # Largest OS consumer (store + rebuilds + GC). Reserved so VM growth
          # hits ENOSPC in-guest (recoverable) instead of wedging the host at a
          # 100%-full CoW pool. rpool/incus is intentionally left unquota'd so
          # Incus stays elastic on the disk. Tunable live via `zfs set`.
          options.reservation = "15G";
        };
        home = {
          type = "zfs_fs";
          mountpoint = "/home";
          options.mountpoint = "legacy";
        };
        var-log = {
          type = "zfs_fs";
          mountpoint = "/var/log";
          options.mountpoint = "legacy";
        };
        incus = {
          type = "zfs_fs";
          mountpoint = "/var/lib/incus";
          options.mountpoint = "legacy";
        };
        #garage = {
        #  type = "zfs_fs";
        #  mountpoint = "/var/lib/garage";
        #  options.mountpoint = "legacy";
        #};
      };
    };
  };
}
