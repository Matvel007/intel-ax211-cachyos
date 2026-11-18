# CachyOS laptop won't boot, Wi-Fi "crashes": the RTL8125 AER storm

[🇷🇺 Русская версия](README.ru.md)

A real-world problem breakdown and a working fix. Everything was verified on live
hardware — data comes from `journalctl`, `dmesg`, `lspci` and AER counters.

**TL;DR** — one kernel parameter, `pcie_aspm=off`:

```bash
# /etc/default/limine
KERNEL_CMDLINE[default]+="quiet nowatchdog splash pcie_aspm=off rw rootflags=subvol=/@ root=UUID=..."
```

```bash
sudo limine-update
```

The wired Realtek RTL8125 floods the PCIe bus with correctable AER errors because
PCIe ASPM L1 power saving does not wake it fast enough. Those errors start before
any driver loads and drag the whole chipset down with them — including the Intel
CNVi Wi-Fi. After the fix: **0 AER errors, 0 Wi-Fi failures, Wi-Fi 6 back at
1921 Mbit/s**.

> **A correction to the earlier version of this repository.** It used to blame the
> AX211 firmware and recommend `disable_11ax=1` (dropping to 802.11ac). That was
> wrong. It reduced failures only by reducing bus traffic, not by fixing anything.
> With the real fix applied, Wi-Fi 6 runs with zero failures and `disable_11ax` is
> gone. See [What is NOT the cause](#what-is-not-the-cause).

---

## Hardware and system

| | |
|---|---|
| Laptop | MECHREVO KUANGSHI Series, Intel Core i5-14450HX |
| Wi-Fi | Intel Wi-Fi 6E AX211, CNVi, PCI `8086:7a70`, address `0000:00:14.3` |
| Ethernet | Realtek RTL8125 2.5GbE, PCI `10ec:8125`, `0000:05:00.0` |
| GPU | NVIDIA RTX 5060 Laptop + Intel iGPU |
| BIOS | AMI `N.1.21MRO16`, 2025-07-24 |
| Distro | CachyOS (Arch-based) |
| Kernels | `7.3.4-1-cachyos` (main), `6.18.60-2-cachyos-lts` |
| Wi-Fi firmware | `89.735b75a4.0`, `iwlwifi-so-a0-gf-a0-89.ucode` |
| Bootloader | Limine, btrfs + snapper |

The Ethernet port is unused — the laptop runs on Wi-Fi. No cable was plugged in
during any of this.

---

## Symptoms

Three different manifestations, one root cause.

### 1. The laptop does not boot

Stops at the CachyOS logo. On screen — dozens of red kernel lines scrolling.
Never reaches the desktop.

Five consecutive boots, same picture:

```
boot   kernel              AER   iwl   graph
-5     7.3.4-1-cachyos     220     0       0
-4     7.3.4-1-cachyos     180     0       0
-3     7.3.4-1-cachyos     160     0       0
-2     7.3.4-1-cachyos     100     0       0
-1     7.3.4-1-cachyos     240     0       0
 0     7.3.4-1-cachyos     440     0       1   <- only this one made it
```

`graph = 0` means `Reached target Graphical Interface` never happened. The kernel
spent the entire boot printing AER errors instead of starting systemd.

In an earlier phase the failure looked different — emergency mode with
`Failed to load your GPU driver(s)`, and `systemctl --failed` blaming
`avahi-daemon.service` and `polkit.service`. Both are casualties, not causes.

### 2. Shutdown hangs

```
[FAILED] Failed unmounting /var/cache
[  **  ] A start job is running for Generate shutdown-ramfs (1min 39s / no limit)
pcieport 0000:00:1d.0: AER: Error of this Agent is reported first
```

Only the power button gets you out. Note the root port — `0000:00:1d.0`, the parent
of the Realtek controller.

### 3. Wi-Fi drops while working

```
iwlwifi 0000:00:14.3: 0x00000084 | NMI_INTERRUPT_UNKNOWN
iwlwifi 0000:00:14.3: Device error - SW reset
iwlwifi 0000:00:14.3: restart completed
```

The firmware resets itself and recovers within seconds — three times in twenty
minutes in one session. From the user's side it looks like "Wi-Fi hung". If the
reset does not complete, the machine hangs and needs a hard power-off.

---

## Diagnosis

### Everything points at one device

Out of **690 AER errors** in a single boot, **690 belong to `0000:05:00.0`** — the
Realtek RTL8125. The Wi-Fi controller `0000:00:14.3` is not mentioned once:

```bash
journalctl -b 0 | grep 'PCIe Bus Error' | grep -oE 'pci [0-9a-f:]+' | sort | uniq -c
```

```
    690 pci 0000:05:00
```

Error types:

```
    403 [12] Timeout   | Transmitter | Data Link Layer
    400 [ 0] RxErr     | Receiver    | Physical Layer
      7 [ 6] BadTLP    | Receiver
      3 [ 8] Rollover  | Transmitter
```

`RxErr` on the **Physical Layer** is the giveaway: the link itself fails to train,
not a software protocol issue.

### It starts before any driver

The storm begins at **0.8 seconds into boot**, while the journal still shows the
bare hostname (`cachyos`, not `cachyos-x8664`) — that is initramfs, before systemd
and before any module loads:

```
Nov 18 20:57:36 cachyos kernel: pcieport 0000:00:1d.0: PCIe Bus Error: severity=Correctable
```

So `r8169` is not the culprit. Blacklisting the driver changes nothing — the
device still sits on the bus and still floods it. Verified.

### The scale

```
aer_ratelimit: 34739 callbacks suppressed
```

34,739 suppressed callbacks in a single burst. The kernel's AER ratelimiter prints
a few and silently drops the rest, which is why the log looks survivable while the
bus is actually saturated.

### The cause: ASPM L1

```
$ lspci -vv -s 05:00.0 | grep LnkCtl
    LnkCtl: ASPM L1 Enabled; RCB 64 bytes, LnkDisable- CommClk+
```

PCIe Active State Power Management puts the link into a low-power state. The
RTL8125 does not wake up within the hardware limit (16 µs), so every wake attempt
produces a correctable error. Correctable means the link recovers by itself — data
integrity is intact, but the bus is hammered thousands of times per second.

This is a known Realtek problem documented across many distros and boards — see
[References](#references).

### Why it takes Wi-Fi down with it

The Wi-Fi CNVi module and the Ethernet controller share the same chipset. When the
bus is saturated with error handling, the Wi-Fi firmware misses its own deadlines
and resets. Correlate timestamps and the match is exact:

```
20:45:11  PCIe Bus Error from 05:00.0
20:45:13  iwlwifi: NMI_INTERRUPT_UNKNOWN -> SW reset
20:47:06  PCIe Bus Error from 05:00.0
20:47:08  iwlwifi: NMI_INTERRUPT_UNKNOWN -> SW reset
```

**Honest caveat:** this is correlation, not a proven mechanism. One boot had 6 AER
errors and zero Wi-Fi failures, so AER volume alone does not guarantee a reset.
What is proven: after removing the storm, Wi-Fi failures stopped completely.

### How it looked when the Wi-Fi driver got stuck

Before the root cause was clear, the boot failure sometimes showed a hung
`modprobe` holding the global module lock:

```bash
journalctl --directory=/mnt/root/var/log/journal -b -1 | grep -A25 'task:modprobe'
```

```
task:modprobe  state:D
  __schedule
  synchronize_irq
  iwl_pcie_synchronize_irqs
  iwl_trans_pcie_gen2_stop_device
  iwl_mvm_start_get_nvm
  iwl_op_mode_mvm_start
  do_init_module
```

The driver tried to stop a misbehaving device and stuck forever in
`synchronize_irq`, waiting for an interrupt that never came. Because `modprobe`
held `module_mutex`, no module loaded afterwards — including `nvidia_drm`, hence
"Failed to load your GPU driver(s)". The GPU error was a consequence, not a cause,
and snapshots could not help because the root filesystem was never the problem.

### What is NOT the cause

- **The Wi-Fi firmware.** `disable_11ax=1` was applied for a month and a half on
  the theory that the 802.11ax Target Wake Time path crashed the firmware. It
  reduced failures by reducing bus traffic, not by fixing anything. After the real
  fix, Wi-Fi 6 runs with **zero** failures and `disable_11ax` is removed.
- **The `r8169` driver.** Blacklisting it does not stop the errors.
- **The kernel.** Tested on `7.3.4` and `6.18.60-lts` — same behaviour. The
  `0eaa1f245ac0` regression in the main kernel makes a hang *worse* when it
  happens, but it does not cause it.
- **The firmware package version.** Three builds tried; changing firmware changed
  the probability, never eliminated the problem.
- **A btrfs or snapshot problem.** Booting from a snapshot failed identically.

---

## The fix

### Disable PCIe ASPM

Add to the kernel command line:

```
pcie_aspm=off
```

On Limine (CachyOS, Arch) the generated `/boot/limine.conf` must not be edited by
hand — edit its source instead:

```bash
# /etc/default/limine
KERNEL_CMDLINE[default]+="quiet nowatchdog splash pcie_aspm=off rw rootflags=subvol=/@ root=UUID=<your-uuid>"
```

```bash
sudo limine-update
```

On GRUB-based systems:

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=off"
```

```bash
sudo update-grub
```

### Verify

**Do not judge by `lspci`.** It keeps showing `ASPM L1 Enabled` after the fix,
because the parameter tells the kernel to stop *managing* ASPM — it does not
rewrite what the BIOS already configured. Judge by the error counter:

```bash
journalctl -b 0 | grep -c 'PCIe Bus Error'
```

Zero means it works.

### Cost

About +0.9 W idle per port. On a laptop that is a real but small hit on battery.
If that matters, try `pcie_aspm.policy=performance` first — it keeps ASPM enabled
but avoids the deepest states, and is sometimes enough.

### What does not work

`pci=noaer` **hides** the errors instead of fixing them. It stops the boot hang
(because the hang came from printing 34k lines) but the bus keeps being hammered
silently. Use it only as a last resort.

### Optional: stop loading the unused driver

If the wired port is never used, `blacklist r8169` keeps the interface from coming
up. It does **not** fix the AER storm — that is worth repeating, because it was
believed for a long time. To use the cable later:

```bash
sudo modprobe r8169
```

### Optional: Wi-Fi power saving

`/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf`:

```
[connection]
wifi.powersave = 2
```

Without this, LAN ping is 40–165 ms instead of 1–3 ms. Unrelated to the AER storm,
but a genuine quality-of-life fix.

---

## Results

| | Before | After |
|---|---|---|
| AER errors per boot | 875 | **0** |
| Wi-Fi firmware failures | 3 in 20 min | **0** |
| Boots reaching graphical target | 1 of 6 | **all** |
| Wi-Fi standard | 802.11ac (`VHT-MCS 9`) | **802.11ax (`HE-MCS 9`)** |
| Wi-Fi rx bitrate | 1404 Mbit/s | **1921 Mbit/s** |
| LAN ping | 1.0–2.5 ms | 1.0–2.5 ms |

After the fix, `disable_11ax=1` was removed and Wi-Fi 6 works with no failures —
which confirms the firmware was never the problem.

---

## Installation

```bash
git clone https://github.com/Matvel007/rtl8125-aer-storm.git
cd rtl8125-aer-storm
sudo ./install.sh
sudo reboot
```

The script:

1. adds `pcie_aspm=off` to the kernel command line (`/etc/default/limine` or
   `/etc/default/grub`) and regenerates the bootloader config;
2. installs Wi-Fi power-saving configs;
3. optionally blacklists `r8169`;
4. keeps every file it touches as `.bak-<date>`.

Both scripts follow your locale (`$LC_ALL` / `$LC_MESSAGES` / `$LANG`): Russian
output on `ru_*` locales, English otherwise. No flags to remember.

### Verify after reboot

```bash
./diagnose.sh
```

Read-only, no root needed. Prints: whether the fix is applied, AER counts for the
current boot, which device reports them, Wi-Fi failure counts, and a per-boot
history table correlating AER with boot success.

---

## Important when reinstalling the OS

- The fix lives in the **kernel command line**, not in a module config. A new
  kernel keeps it; reinstalling the bootloader or recreating `/etc/default/limine`
  loses it.
- If the machine becomes unbootable after a change, hold `Shift`/`Esc` at the
  Limine menu and pick a snapshot.
- After a BIOS update, re-check — some firmwares reset the ASPM policy.

---

## References

- [AskUbuntu: PCIe Bus Error severity=Corrected, Physical Layer](https://askubuntu.com/questions/863150/pcie-bus-error-severity-corrected-type-physical-layer-id-00e5receiver-id)
  — `pcie_aspm=off` as the accepted answer, with a note that `pci=noaer` only masks
- [Proxmox forum: AER Correctable error message received](https://forum.proxmox.com/threads/aer-correctable-error-message-received.156497/)
  — same root port `00:1d.0`, same `RxErr`, solved by `pcie_aspm=off`
- [Gentoo forums: PCI ethernet device issue related to AER](https://forums.gentoo.org/viewtopic-p-8819315.html)
  — errors start at 0.8 s, before the driver loads
- [Launchpad #2015670: r8169 kernel loop PCIe Bus Error](https://bugs.launchpad.net/bugs/2015670)
  — Realtek-specific report
- [Ubuntu #2148754](https://www.mail-archive.com/ubuntu-bugs@lists.ubuntu.com/msg6289716.html)
  — platform-side CNVi init failure, changing firmware does not help
- [CachyOS forum: Intel AX211 (CNVi) completely disappears](https://discuss.cachyos.org/t/intel-ax211-cnvi-completely-disappears-on-cachyos-no-wi-fi-no-bluetooth/20544)
  — same hardware, Windows unaffected

Earlier, when the Wi-Fi firmware was suspected:

- [pop-os#4101: SPM / Power Management regression in linux-firmware (AX211)](https://github.com/pop-os/pop/issues/4101)
- [CachyOS#673: Intel iwlwifi instability](https://github.com/CachyOS/linux-cachyos/issues/673)
- [Ubuntu Discourse: AX211 s2idle on Dell 7430](https://discourse.ubuntu.com/t/abnormal-battery-drain-during-suspend-s2idle-on-dell-latitude-7430/89171?page=3)
  — the source of the `disable_11ax=1` recipe that turned out to be unnecessary here

---

## Caveats

- Verified on one machine, one BIOS, two kernels. The mechanism (ASPM L1 wake
  latency on Realtek) is common, but other models may behave differently.
- The causal link between AER volume and the Wi-Fi firmware reset is **correlated,
  not proven**. One boot had AER errors without Wi-Fi failures.
- Correctable errors mean data integrity is intact. This is a stability and
  performance problem, not corruption.
- `pcie_aspm=off` is global — it affects all PCIe devices, not just the Realtek.
  No side effects were observed, but it is a system-wide setting.
- If errors persist with the fix applied, the next step is the BIOS: disable
  *PCIe native power management* / ASPM for the LAN controller.

---

## License

MIT — see [LICENSE](LICENSE).
