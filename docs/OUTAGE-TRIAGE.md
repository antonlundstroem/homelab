# Outage triage — host001 / node01 unreachable (2026-07-01, recurred 2026-07-02)

| | |
|---|---|
| **Date of incident** | 2026-07-01 ~22:39 CEST — **recurred 2026-07-02 ~12:33 CEST** |
| **Affected host** | `host001` (192.168.1.100, NixOS baremetal running Incus) |
| **Blast radius** | host001 + every Incus VM bridged through it — `node01` (k3s server, 192.168.1.31) and `haos` (192.168.1.200) |
| **Severity** | **High** — recurring and *accelerating* (healthy interval fell from ~10 days to ~14 h); single-NIC SPOF; no remote recovery path |
| **Root-cause domain** | **Onboard Intel NIC transmit-unit hang (`e1000e`, `eno1`)** — network only; *not* CPU/RAM/disk/ZFS/kernel. After the 2nd episode, assessed as **likely failing hardware** (see *Recurrence & acceleration*). |
| **Failing cluster pods?** | Investigated and **ruled out** as cause or trigger — a separate problem (broken sealed-secrets). See *Recurrence & acceleration → Were the failing pods involved?* |
| **Current status** | ✅ Up after 2nd power-cycle (2026-07-02 16:17). Software mitigation **STAGED, not applied** (`nixos/hosts/001/networking.nix`). Root cause unresolved. |
| **Method** | Post-hoc `journalctl -b -1` analysis across both episodes + live cluster inspection |

---

## TL;DR

`host001`'s onboard Intel NIC (`eno1`, PCI `0000:00:1f.6`, `e1000e`) wedged its transmit ring. The kernel logged **`Detected Hardware Unit Hang`** every ~2 seconds — **389,842 times** — from **2026-06-22 22:04:49** until the reboot on **2026-07-01 22:39:31**, and the driver **never recovered it** (0 adapter resets). Because `node01` and `haos` are Incus VMs bridged onto `br0` whose uplink *is* `eno1`, the host NIC failure took both VMs (and the k3s control plane) off the network. The machine itself stayed alive the whole time — it shut down cleanly on a power-button press — so this was a **network-layer failure, not a crash or resource exhaustion**.

**Update 2026-07-02:** it recurred after only **~14 h** of uptime (vs ~10 days the first time) — same hang, same 2 s cadence, same 0 recoveries. That accelerating interval points to **failing NIC hardware**. A software mitigation (disable `e1000e` offloads) is now **staged** as the decisive hardware-vs-driver test before buying hardware. The cluster's failing pods were investigated and are **unrelated** (see below).

---

## Verdict

**Fault domain: the onboard NIC / `e1000e` driver.** The transmit unit hung and stopped making forward progress; the driver's recovery path never cleared it, so the host was unreachable over the LAN until a full power cycle reinitialised the hardware.

This is the well-known Intel **`e1000e: Detected Hardware Unit Hang`** failure mode, common on onboard I21x-class NICs (integrated at PCH function `00:1f.6`). It is typically triggered by TCP segmentation / checksum offload bugs or PCIe ASPM power management, and often only fully clears on a cold reset.

**After the 2026-07-02 recurrence, the leading assessment is failing hardware** (the interval is collapsing — see *Recurrence & acceleration*). The offload-disable mitigation is staged as a zero-cost test: if it holds, it was the driver/offload bug; if it doesn't, the NIC is dying and needs replacing.

---

## Impact

- **host001** — unreachable over the LAN (no SSH, no Garage S3, no Incus API). Host OS remained running internally, both times.
- **node01** — k3s **server / etcd / control-plane** node; lost network → cluster API and all ingress unreachable from the LAN.
- **haos** — Home Assistant OS VM (192.168.1.200) unreachable.
- **node02 / gpu01** — physically separate machines; not hosted on host001. node02 stayed up (own NIC) but a single-server cluster with an unreachable control-plane node is effectively down.

---

## Timeline (CEST)

| Time | Event |
|---|---|
| 2026-06-12 20:04 | host001 boots (kernel 6.18.21); `eno1` links up 1000 Mb/s full duplex, joins `br0`. Healthy. |
| **2026-06-22 22:04:49** | **Episode 1 onset** — first `e1000e … Detected Hardware Unit Hang`, ~10 days into the boot. Nothing in the journal precedes it. |
| 2026-06-22 → 07-01 | Hang repeats every ~2 s continuously (verified: 60 hits in the Jun 27 12:00–12:02 sample). **0** adapter resets. |
| 2026-07-01 22:39:09 | Operator power-cycles. `systemd-logind: Power key pressed short → Powering off`; clean shutdown (Garage flushed, `rpool` synced). |
| 2026-07-01 22:39:56 | host001 back up. `eno1` healthy. |
| 2026-07-01 22:56 / 23:21 | `homeowner`/Booli scraper redeployed (git rolls) — noted for correlation; ~13 h before the next onset. |
| **2026-07-02 12:33:16** | **Episode 2 onset** — first hang, only **~14 h** into the boot. Onset window again empty in the journal. |
| 2026-07-02 ~12:33 → 16:16 | Host isolated again. Operator confirms unreachable: LAN ARP `FAILED`, gateway + node02 up, **no Tailscale path** to host001 either. 6690 hangs, 0 resets. |
| 2026-07-02 16:16 | Operator power-cycles again → recovered. |
| 2026-07-02 ~16:19 | 2nd triage + live cluster inspection; offload mitigation **staged** (not applied). |

---

## Evidence — what it *was*

Representative kernel message, showing a stuck TX ring (head `TDH<53>` / tail `TDT<65>`, `next_to_clean` frozen at 52):

```
Jul 01 22:39:31 host001 kernel: e1000e 0000:00:1f.6 eno1: Detected Hardware Unit Hang:
                                  TDH                  <53>
                                  TDT                  <65>
                                  next_to_use          <65>
                                  next_to_clean        <52>
                                  next_to_watch.status <0>
                                MAC Status             <80083>
                                PHY Status             <796d>
```

| Metric | Episode 1 (boot Jun 12→Jul 1) | Episode 2 (boot Jul 1→Jul 2) |
|---|---|---|
| Healthy uptime before onset | **~10 days** | **~14 hours** |
| First hang | 2026-06-22 22:04:49 | 2026-07-02 12:33:16 |
| Last hang | 2026-07-01 22:39:31 | 2026-07-02 16:16:14 |
| Hang count | **389,842** | **6,690** |
| Cadence | 1 / 2 s (continuous) | 1 / 2 s (continuous) |
| Adapter resets / recoveries | **0** | **0** |
| Event in journal at onset | none | none |

Commands: `journalctl -b -1 -k | grep -c 'Detected Hardware Unit Hang'` (count); `… | head -1` / `tail -1` (first/last); `journalctl -b -1 -k | grep -ci 'reset adapter'` (recoveries).

The **0 resets** are notable: the driver detected the hang continuously but never logged a recovery — only a cold power cycle reinitialised the NIC, consistent with a hardware/PHY-level stall. Device (from the boot banner): `Intel(R) PRO/1000 Network Connection`, driver `e1000e`, MAC `f8:75:a4:37:b6:f8`, PCIe 2.5 GT/s ×1, at PCI `0000:00:1f.6`. Kernel `6.18.21`.

## Evidence — what it was *not*

| Suspect | Ruled out by |
|---|---|
| Kernel panic / crash | Boot ended with an **orderly systemd shutdown** (power-key → clean poweroff, Garage flushed, `rpool` synced). Kernel + systemd were alive. |
| OOM / memory pressure | **0** OOM kills (`grep -ci 'killed process\|oom-kill\|out of memory'`); 21 GiB free, swap 0 B used. |
| Disk full (the documented unquota'd-`rpool` risk) | Every dataset 1–2 % used, 193 G avail. |
| ZFS fault | `zpool status` → `ONLINE`, `No known data errors`. |
| Hung task / MCE / thermal / watchdog | None in the kernel log. |
| **Failing cluster pods** | See *Recurrence & acceleration → Were the failing pods involved?* — timing, topology, and direction of causation all exclude them. |

The `dnsmasq … error binding DHCP socket to incusbr0`, `lxcfs.service: Failed`, and `incusd … Failed to locate zvol … context canceled` lines are all **shutdown-teardown artifacts**, not causes.

---

## Why node01 and haos went down with the host

```
eno1  --(enslaved)-->  br0  <--(bridged uplink)--  node01 (192.168.1.31), haos (192.168.1.200)
```

- `ip -o link show eno1` → `master br0`.
- Terraform (`terraform/hosts/001/main.tf`): both VMs use `nictype = "bridged"`, `parent = "br0"`.

`br0`'s only path to the LAN is through `eno1`. When `eno1`'s TX unit hung, the bridge had no working uplink, so every VM on `br0` lost LAN connectivity even though the VMs themselves were fine. **Single onboard NIC = single point of failure for the whole host and all its guests.**

---

## Recovery / current status

Up after the 2nd power-cycle (boot at 2026-07-02 16:17):

- `eno1` UP, **0** hangs this boot.
- `kubectl get nodes`: node01 `Ready` (control-plane,etcd), node02 `Ready`; `gpu01 NotReady` (normal intermittent state).
- All Incus VMs `RUNNING`; `rpool` ONLINE.

**Root cause unresolved.** The NIC recovered on reset, but it has now failed **twice with an accelerating interval**. A software mitigation is **staged but not applied** (Remediation rung 1).

---

## Recurrence & acceleration (2026-07-02)

### The NIC is degrading

| Boot | Uptime before onset | Onset |
|---|---|---|
| Jun 12 → Jul 1 | **~10 days** | 2026-06-22 22:04:49 |
| Jul 1 → Jul 2 | **~14 hours** | 2026-07-02 12:33:16 |

Same failure (2 s cadence, 0 driver recoveries, cleared only by a cold power-cycle), but time-to-failure collapsed from ~10 days to ~14 h. That accelerating interval is the classic signature of a **marginal / failing NIC** (PHY, solder, or thermal), where the load/time needed to trigger the hang keeps dropping. Nothing in the cluster changed to cause it — the hardware is getting worse. (n = 2, so *strongly suggestive*, not proven; the staged offload mitigation is the decisive test.)

Secondary factors not ruled out: **thermal** (PCH-integrated NIC; summer ambient + load could lower the threshold — couldn't verify, `lm_sensors` isn't installed) and **load as an aggravator** (sustained TX makes a marginal NIC hang sooner).

### Were the failing pods involved? (No.)

The cluster does have real failing pods — `argocd-repo-server` (**4143 restarts**, liveness timeouts), `nfd-worker` on node02 (**CrashLoopBackOff, 2558**), `ollama` (Pending — needs the down `gpu01`) — all rooted in a **broken sealed-secrets** (`github-secrets` / `rustfs-secrets` → `ErrUnsealFailed`, so `external-secret/mlops-repo` can't resolve and repo-server can't clone). But they neither cause nor trigger the NIC hang:

1. **A healthy NIC never hangs under load.** Crash-loops, retries, git fetches, line-rate traffic are all normal. A NIC that wedges under them is itself faulty; traffic is at most an aggravator.
2. **Timing rules them out.** Both onsets were spontaneous *mid-run* (10 days / ~14 h in) with **nothing in host001's journal at the onset second** (the 2 min before the first hang are empty). The crash-loopers are *constants* — running for weeks through the healthy stretches too; a constant can't produce a sudden onset.
3. **Most aren't even on host001's NIC path.** node02 is separate hardware with its own NIC. The `homeowner`/Booli scraper (the real traffic generator), `open-webui`, and the crash-looping NFD worker all run on **node02** and egress through *its* NIC — never `eno1`. Only node01's traffic crosses host001's NIC.
4. **Causation likely runs backwards.** repo-server dies on *liveness timeouts* ("context deadline exceeded") — the signature of a network stall. During a hang window its git fetches hang → probe fails → restart. Some crash-looping is a **symptom** of the outage, not a cause.

**Fix the pods for cluster health (start with sealed-secrets), but don't expect it to stop the hangs.**

---

## Remediation ladder

Apply in order; stop when it holds.

1. **Disable `e1000e` TX/segmentation offloads on `eno1`** — the canonical "Detected Hardware Unit Hang" workaround, and the **decisive hardware-vs-driver test**. **✅ STAGED (not applied)** in `nixos/hosts/001/networking.nix` as an ethtool oneshot:

   ```nix
   systemd.services.eno1-offload-fix = {
     wantedBy = ["multi-user.target"];
     after = ["sys-subsystem-net-devices-eno1.device"];
     bindsTo = ["sys-subsystem-net-devices-eno1.device"];
     serviceConfig = {
       Type = "oneshot";
       RemainAfterExit = true;
       ExecStart = "${pkgs.ethtool}/bin/ethtool -K eno1 tso off gso off gro off";
     };
   };
   ```

   Chosen over a systemd `.link` file **on purpose**: a `.link` matching `eno1` that omits `NamePolicy` would drop the rename, detach it from `br0`, and strand this remote box. `ethtool` on the live device never touches naming.

   - **Apply:** `nixos-rebuild switch --flake .#host001 --target-host admin@192.168.1.100 --sudo`
   - **Verify:** `ethtool -k eno1 | grep -E 'tcp-segmentation|generic-'` → all `off`
   - **Roll back:** revert the block, rebuild.
   - **Watch:** if uptime blows past ~14 h and ideally ≫ 10 days, the offload bug was it. If it still hangs → the NIC is failing → rung 3.
   - Quick non-persistent check without a rebuild: `sudo ethtool -K eno1 tso off gso off gro off`.

2. **If it still recurs — disable NIC power management.** Energy-Efficient Ethernet off (`sudo ethtool --set-eee eno1 eee off`) and/or PCIe ASPM (`boot.kernelParams = [ "pcie_aspm=off" ];`).

3. **If it still recurs → it's the hardware; give `br0` a new uplink.** This is a **Lenovo ThinkCentre Tiny** (1 L). Its onboard NIC is an **Intel I219-V integrated into the PCH** (hence `e1000e` at `00:1f.6`) — **soldered, not swappable**. You don't swap it, you replace its *role*:
   - **USB3 → Ethernet dongle (easiest).** ~$15–30, no disassembly. Prefer a solid chipset (Realtek RTL8153 for 1 GbE, RTL8156 or Intel-based for 2.5 GbE). Point `br0` at the new `enpXsXuX` interface in `networking.nix`, retire `eno1`.
   - **Lenovo rear Flex I/O module (cleaner).** Most Tiny models take an optional rear port; Lenovo sells a **2nd Ethernet (RJ45)** option for several. Model-dependent — confirm the exact model (M710q / M720q / M920q / M75q…) to source the right part.
   - **M.2 route (internal).** The M.2 2230 WiFi (E-key) slot can host an A+E-key → 2.5 GbE adapter, or a WiFi card as an emergency failover uplink. Fiddlier; frees the USB port.
   - **No full-size PCIe slot** exists on the 1 L Tiny (only the larger ThinkCentre SFF has PCIe), so a standard PCIe NIC card isn't an option here.

---

## Observability — recommendations (PROPOSED)

**Design principle: put the alarm outside the room that's on fire.** The existing Prometheus / Alertmanager stack runs *in-cluster on `node01`* — itself a VM on host001, bridged through the NIC that failed. During this outage it would have gone blind **and** been unable to send a notification, because its own egress also rides `eno1`. An alert that depends on host001's network cannot report that network being down. So host001's detect-and-notify path must live **outside host001's failure domain** — on `node02` (a separate physical box) or off-site.

**Would each mechanism have caught *this* incident?**

| Mechanism | Detects host isolation | Notifies *during* outage | Auto-recovers | Effort |
|---|---|---|---|---|
| systemd / HW watchdog (`RuntimeWatchdogSec`) | ✗ kernel wasn't hung | — | reboot on kernel hang only | low |
| **Tier 0 — external dead-man's-switch** | ✓ | ✓ brain is off-host | ✗ | low ← **start here** |
| Tier 1 — external reachability probe | ✓ | ✓ | ✗ | low–med |
| Tier 2 — `node_exporter` → in-cluster Prometheus | ✓ (gap, seen after recovery) | ✗ inside failure domain | ✗ | med |
| Tier 2b — journal log alert on host001 | ✓ early / degraded phase | ~ only before full isolation | ✗ | low |
| Tier 3 — network self-heal watchdog | ✓ | n/a | ✓ | med |

Note the top row: a hardware / systemd watchdog — the reflexive "just add a watchdog" answer — would **not** have helped here. The kernel was healthy and kept petting it; only the NIC was dead. This was a network-only failure and needs network-aware detection.

### Tier 0 — external dead-man's-switch *(start here)*

host001 pings an external heartbeat on a timer; if it can't reach out, the ping stops and the **external** service alerts you after a grace window. This targets *exactly* this failure mode (host can't talk to the network) and keeps the alerting brain off-host. Use healthchecks.io (free tier) or a self-hosted Uptime Kuma "push" monitor **on node02**.

```nix
# host001 — heartbeat. The ping URL/UUID is a secret → sops, not committed
# (same pattern as the other host001 secrets; see CLAUDE.md "Secrets — sops-nix").
systemd.timers.heartbeat = {
  wantedBy = [ "timers.target" ];
  timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "2min"; };
};
systemd.services.heartbeat = {
  serviceConfig.Type = "oneshot";
  script = "${pkgs.curl}/bin/curl -fsS --max-time 10 --retry 3 $(cat ${config.sops.secrets.hc_ping_url.path})";
};
```

### Tier 1 — external reachability probe

Something *off host001* probes it: ICMP + TCP `22` + the Garage S3 port. Natural home is **node02** (separate physical box, own NIC) via `blackbox_exporter` or Uptime Kuma — it survives an `eno1` death because it isn't downstream of it.

- If you reuse the in-cluster monitoring stack instead, **pin the prober to node02** (`nodeSelector` / affinity). Otherwise k8s may schedule it onto node01 (a VM on host001) and it's right back inside the failure domain — useless for a host001 outage.

### Tier 2 — host metrics + trend history *(root-cause layer)*

host001 isn't scraped today (it lives outside the cluster). Add the exporter + a scrape target so you can *watch the degradation build* and root-cause the next one:

```nix
services.prometheus.exporters.node.enable = true;   # host001 → :9100
```

Then scrape `192.168.1.100:9100` from the in-cluster Prometheus. Alerts that fit *this* fault class:

- carrier up but no TX progress — `node_network_up{device="eno1"} == 1 and rate(node_network_transmit_packets_total{device="eno1"}[5m]) == 0`
- rising `node_network_transmit_errs_total` / `node_network_transmit_drop_total` on `eno1`.

Caveat: this Prometheus is *inside* the failure domain — excellent for trends and RCA, but it can't notify during a host001 isolation. Pair it with Tier 0/1. (Monitoring PVCs are `local-path` = disposable, so history resets on a cluster rebuild — acceptable for this purpose.)

### Tier 2b — targeted log alert on the known signature

The exact kernel string is known, so a tiny host001 service can alert the instant it returns — often in the *degraded* phase, before full isolation:

```nix
systemd.services.eno1-hang-alert = {
  wantedBy = [ "multi-user.target" ];
  serviceConfig.Restart = "always";
  script = ''
    ${pkgs.systemd}/bin/journalctl -kf -n0 --grep 'Detected Hardware Unit Hang' | \
    while read -r l; do ${pkgs.curl}/bin/curl -fsS -m10 -d "host001: $l" ntfy.sh/<topic> || true; done
  '';
};
```

(Egress rides `eno1`, so this is early-warning, not isolation-proof — it complements Tier 0, doesn't replace it.)

### Tier 3 — self-heal watchdog *(reduce MTTR, not just detect)*

Go past alerting: a host001 service that, on gateway-ping loss for N seconds *or* the hang signature appearing, escalates — `ip link set eno1 down && up` → reload the `e1000e` module → reboot as last resort. This would have turned each multi-hour isolation into a blip. Gate the reboot carefully (rate-limit; only after the softer steps fail).

---

## Follow-ups

- [ ] **Apply + watch the staged offload mitigation (rung 1).** Decisive test: does uptime clear ~14 h, then ≫ 10 days? Record the result here — it decides driver-bug vs. hardware-replacement.
- [ ] **Observability gap — the real lesson.** The NIC hung for **9 days** unnoticed the first time and recurred within **~14 h**; host001 still has no health alerting. See *Observability* — start with the Tier 0 dead-man's-switch (the only tier that both *detects* and *notifies* during an isolation).
- [ ] **Fix the broken sealed-secrets** (`github-secrets` / `rustfs-secrets` → `ErrUnsealFailed`) — unblocks `argocd-repo-server`'s 4143-restart crash-loop. Separate from the NIC, but real.
- [ ] **Hardware fallback ready?** Keep a USB3 Ethernet dongle on hand (rung 3) given the accelerating trend; identify the exact Tiny model to check the Lenovo Flex I/O 2nd-LAN option.
- [ ] SPOF: consider a second uplink / bond for `br0` so a single NIC hang can't isolate the whole host and its VMs.
- [x] ~~What triggered the onset?~~ Answered: **spontaneous in both episodes** (empty journal at onset) — supports the failing-hardware assessment, not a workload trigger.

---

## Appendix — investigation commands (to reproduce / re-run)

```sh
ssh -i ~/.ssh/homelab admin@192.168.1.100

# Identify the failed boot (after a reboot it's -1) and confirm the hang + extent
journalctl --list-boots
sudo journalctl -b -1 -k | grep -c 'Detected Hardware Unit Hang'
sudo journalctl -b -1 -k | grep 'Detected Hardware Unit Hang' | head -1   # onset time
sudo journalctl -b -1 -k | grep 'Detected Hardware Unit Hang' | tail -1   # last
sudo journalctl -b -1 -k | grep -ci 'reset adapter'                       # recoveries (0)

# Crash or clean shutdown? (expect an orderly teardown → OS was alive)
sudo journalctl -b -1 | tail -60

# Anything happening at onset? (expect: nothing — spontaneous)
sudo journalctl -b -1 --since '<onset -2min>' --until '<onset>' \
  | grep -ivE 'TDH|TDT|next_to|jiffies|MAC Status|PHY|PCI Status'

# Rule out the usual baremetal-hang suspects
sudo journalctl -b -1 | grep -ciE 'killed process|oom-kill|out of memory'  # OOM (0)
free -h ; df -h ; sudo zpool status                                        # RAM / disk / ZFS

# Reachability triage from the laptop (LAN vs host-specific)
ping -c2 192.168.1.1        # gateway/control — should be UP
ping -c2 192.168.1.100      # host001
ip neigh show               # ARP: FAILED = not answering at L2
tailscale ping home         # is there any non-LAN path in? (no — TS rides eno1)

# Cluster: are the failing pods on eno1's path? (mostly node02 = separate NIC)
kubectl get pods -A -o wide            # eyeball RESTARTS / NODE
kubectl get events -A --field-selector type=Warning
```
