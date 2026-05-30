# Disk layout for node02 — bare-metal k3s agent (the primary workload node).
# Sized for a small (~120 GB / ~111-119 GiB) SSD.
#
# BEFORE installing on the real box:
#   1. `device` is pre-set to the old host001 box's NVMe by-id — node02 IS that
#      machine, repurposed (same disk). Re-verify it still matches on install
#      (`ls -l /dev/disk/by-id/`); it's the wipe target, so a wrong value
#      destroys the wrong disk.
#   2. Confirm the disk size with `lsblk`. Only ESP/root/etcd are fixed (49G total);
#      `data` is greedy (`size = "100%"`) and takes the rest, so it auto-fits any
#      disk larger than ~49G — no need to match the size exactly.
#
# ext4 throughout — etcd dislikes ZFS copy-on-write, and node02 may later hold an
# etcd member. Splitting k3s data off the OS root keeps a runaway image pull or PVC
# from filling `/` and taking the node (and, post-promotion, the control plane) down.
#
# No Longhorn partition today (2-node build; this disk has no room for a useful
# replica reserve). When Longhorn is turned on at the 3-node build (CLAUDE.md
# "Storage strategy"), pick ONE of:
#   (a) DEDICATED 2nd disk for /var/lib/longhorn — preferred. Replica I/O and
#       PVC/image churn don't contend; a runaway replica can't fill the k3s data
#       partition (or, post-promotion, etcd). Needs hardware.
#   (b) /var/lib/longhorn as a DIRECTORY on this `data` partition, with Longhorn's
#       per-node "Storage Reserved" set so it never eats the whole partition.
#       Zero hardware, but replicas/images/local-path PVCs share one ext4 fs and
#       the reserve is a SOFT limit, not an fs quota. Fallback when (a) isn't possible.
#
# disko creates partitions in ascending `priority` order (lib/types/gpt.nix); the
# greedy `data` partition has the highest priority so it is created last — required
# for a `size = "100%"` partition to fill the remainder.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-SAMSUNG_MZVLW128HEGR-000L1_S341NX1K479197";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = ["fmask=0077" "dmask=0077"];
            };
          };

          # OS + /nix. 40G holds many generations of a node's system closure
          # (raise it, or wire up nix.gc, if /nix gets tight).
          root = {
            priority = 2;
            size = "40G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };

          # Small embedded-etcd reserve, isolated so image/PVC churn can't push etcd
          # into its NOSPACE alarm. Empty until node02 is promoted to a server;
          # mounting it now (nested under the data partition) keeps promotion a
          # config flip, not a reinstall. Drop it if you'd rather give `data` the
          # extra 8G and let etcd share the data partition when promoted.
          etcd = {
            priority = 3;
            size = "8G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/var/lib/rancher/k3s/server/db";
            };
          };

          # k3s agent working set: containerd images + local-path PVCs. Greedy —
          # absorbs the rest of the disk (~62-70 GiB here). Must stay the
          # highest-priority (last-created) partition.
          data = {
            priority = 4;
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/var/lib/rancher";
            };
          };
        };
      };
    };
  };
}
