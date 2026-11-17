# Intel AX211 (CNVi) on CachyOS: boot-time firmware crash, emergency mode, shutdown hang

[🇷🇺 Русская версия](README.ru.md)

A real-world problem breakdown and a working fix. Everything was verified on live
hardware — data comes from `journalctl`, `dmesg` and firmware crash dumps.

**TL;DR** — one line in `/etc/modprobe.d/iwlwifi.conf`:

```
options iwlwifi disable_11ax=1
```

Dropping from 802.11ax (Wi-Fi 6) to 802.11ac eliminates the firmware crashes.
8 consecutive clean boots, down from 5 failures out of 7.

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

---

## Symptoms

Three different manifestations, one root cause.

### 1. The laptop does not boot

```
Failed to load your GPU driver(s)
You can't get into desktop environment right now
```

Drops into emergency mode. Nothing helped: neither the main kernel, nor LTS, nor
booting from a snapshot. `systemctl --failed` reported `avahi-daemon.service` and
`polkit.service`, which sends you down the wrong path — they are just casualties.

### 2. Shutdown hangs

```
[FAILED] Failed unmounting /var/cache
[  **  ] A start job is running for Generate shutdown-ramfs (1min 39s / no limit)
pcieport 0000:00:1d.0: AER: Error of this Agent is reported first
```

Only the power button gets you out.

### 3. Wi-Fi drops while working

```
iwlwifi 0000:00:14.3: Device error - SW reset
iwlwifi 0000:00:14.3: restart completed
```

Connectivity disappears for 30 seconds to 3.5 minutes, then comes back by itself.

---

## Diagnosis

### The real cause of the boot hang

The key is the stack of the blocked process:

```bash
journalctl --directory=/mnt/root/var/log/journal -b -1 | grep -A25 'task:modprobe'
```

```
task:modprobe  state:D
  __schedule
  synchronize_irq
  iwl_pcie_synchronize_irqs
  iwl_trans_pcie_gen2_stop_device
  iwl_trans_stop_device
  iwl_mvm_start_get_nvm
  iwl_op_mode_mvm_start
  iwl_opmode_register
  iwl_mvm_init
  do_init_module
```

What happens:

1. The Wi-Fi firmware crashes during initialization
2. The driver tries to stop the device and **gets stuck forever** in
   `synchronize_irq`, waiting for an interrupt that will never arrive
3. The `modprobe` process holds `module_mutex` — the global module loading lock
4. **After that no module loads at all.** Including `nvidia_drm`
5. Hence "Failed to load your GPU driver(s)" and emergency mode

So the GPU error is a consequence, not the cause. That is also why snapshots did
nothing — the root filesystem was never the problem.

### Firmware dump on crash

```
iwlwifi 0000:00:14.3: 0x00000084 | NMI_INTERRUPT_UNKNOWN
iwlwifi 0000:00:14.3: 0x20000066 | NMI_INTERRUPT_HOST
iwlwifi 0000:00:14.3: 0x60000000 | FSEQ_ERROR_CODE
iwlwifi 0000:00:14.3: SecBoot CPU1 Status: 0x8650, CPU2 Status: 0xb03
iwlwifi 0000:00:14.3: Failed to start RT ucode: -110
```

`FSEQ_ERROR_CODE` is non-zero — this is the platform-side CNVi initialization on
the chipset (CSME) failing **before** the driver gets involved. `SecBoot CPU1
Status` appears only in failed boots; successful ones never show it.

A crash during normal operation looks different — the precursor is:

```
iwlwifi 0000:00:14.3: Error sending SYSTEM_STATISTICS_CMD: time out after 2000ms.
iwlwifi 0000:00:14.3: Current CMD queue read_ptr 831 write_ptr 832
```

The firmware stops answering commands, then crashes.

### The kernel regression that turns a crash into a hard hang

Commit [`0eaa1f245ac0`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=0eaa1f245ac0)
("wifi: iwlwifi: mvm: don't support the reset handshake for old firmwares"),
landed in **v7.1-rc7**.

The code in `drivers/net/wireless/intel/iwlwifi/mvm/ops.c`:

```c
if (IWL_UCODE_MAJOR(mvm->fw->ucode_ver) <= 77)
    trans->conf.fw_reset_handshake = false;
```

Firmware version 89 stores its version in the new TLV format as `0x59` (89).
`IWL_UCODE_MAJOR()` shifts by 24 bits and gets **0**. The `0 <= 77` condition is
true → reset-handshake is disabled → the driver loses its soft-reset mechanism and
hangs instead of restarting the card.

The regression is tracked in [regzbot](https://linux-regtracking.leemhuis.info/regzbot/regression/lore/amzVtgQb2p-_nShU@debian.local/)
as "iwlwifi IO_PAGE_FAULT and Master Disable Timed Out".

**Where it is fixed:** in `linux-next`, but not in mainline as of the time of
testing (2026-11-17):

```c
trans->conf.fw_reset_handshake =
    fw_has_capa(&mvm->fw->ucode_capa,
                IWL_UCODE_TLV_CAPA_FW_RESET_HANDSHAKE) &&
    mvm->fw->ucode_ver > 77;
```

**Practical takeaway:** `7.3.4-1-cachyos` contains the regression,
`6.18.60-2-cachyos-lts` does not. That is the only real difference between the
kernels in the context of this problem.

### What is NOT the cause

Tested and ruled out:

- **Firmware.** Tried three builds: `735b75a4` (package 20260622), `a67023b2`
  (core24.90-60, upstream 2026-11-08), `123cf747` (core102-56). First: 5 failures
  out of 7. Second: **11 out of 12, made it worse**. Third: not tested. Changing
  firmware changes the probability, not the cause.
- **ASPM.** Already disabled on both link ends (`LnkCtl: ASPM Disabled`).
- **Warm vs cold reboot.** There was a correlation with the pause between boots
  (20–27 s → failure, 43 s → success), but after the `disable_11ax` fix, back-to-back
  reboots pass cleanly.
- **`power_save` / `power_scheme`.** These fix something else — high latency — but
  do not eliminate the initialization crashes.
- **A `modprobe -r iwlwifi` hook in `system-shutdown`.** Does not help and is
  dangerous: with a crashed card, unloading hangs in the very same
  `synchronize_irq`, and shutdown hangs forever.
- **AER errors from the Realtek RTL8125.** A separate defect (see below), unrelated
  to Wi-Fi.

---

## The fix

### 1. Disable Wi-Fi 6 (802.11ax) — the main one

`/etc/modprobe.d/iwlwifi.conf`:

```
options iwlwifi disable_11ax=1
options iwlwifi power_save=0
options iwlmvm power_scheme=1
```

Basis: the AX211 analysis in [Ubuntu Discourse](https://discourse.ubuntu.com/t/abnormal-battery-drain-during-suspend-s2idle-on-dell-latitude-7430/89171?page=3)
— "the firmware bug lives in the 802.11ax Target Wake Time path"; falling back to
802.11ac avoids it.

Why it works: the crash happens in the 802.11ax TWT logic. Without ax the card
initializes through a different path, and `FSEQ_ERROR_CODE` never shows up.

**Cost:** an 802.11ac link instead of 802.11ax. 1404–1733 Mbit/s instead of 1921
at 160 MHz width. Negligible for a home network.

**Verification:**

```bash
cat /sys/module/iwlwifi/parameters/disable_11ax    # → Y
iw dev wlan0 link | grep bitrate                   # → VHT-MCS, not HE-MCS
```

### 2. Stop the AER storm from the RTL8125

`/etc/modprobe.d/blacklist-r8169.conf`:

```
blacklist r8169
```

Problem: the wired port, with no cable plugged in, floods the log with correctable
PCIe errors.

```
r8169 0000:05:00.0: PCIe Bus Error: severity=Correctable, type=Data Link Layer, (Transmitter ID)
r8169 0000:05:00.0:    [12] Timeout
aer_ratelimit: 9884 callbacks suppressed
```

Almost ten thousand suppressed messages in a single burst, 4+ errors per second,
each one an interrupt. The cause is in the driver, not the hardware: without
`r8169` there were **zero** new errors over 5+ minutes.

`blacklist` only blocks autoloading. If you need wired networking:

```bash
sudo modprobe r8169
```

### 3. Disable Wi-Fi power saving

`/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf`:

```
[connection]
wifi.powersave = 2
```

Without this, LAN ping is 40–165 ms instead of 1–3 ms.

---

## Results

Measured on `7.3.4-1-cachyos`, firmware `735b75a4`.

### Before the fix

| | |
|---|---|
| Boots | 7 |
| Failed | **5** |
| `synchronize_irq` hangs | 4 in a single boot |
| `Device error - SW reset` during use | 4 per day |

### After

| | |
|---|---|
| Boots on 7.3.4 | **8** |
| Failed | **0** |
| Hangs | 0 |
| `Failed to start RT ucode` | 0 |
| `Device error - SW reset` | 0 |
| `SecBoot CPU1 Status` | never appeared |

LAN ping: 1.0–2.5 ms, 0% loss.
Signal: −47 dBm, 160 MHz, `VHT-MCS 9`.

For comparison, LTS `6.18.60` with the same config: **5 boots, 3 failed**
(20:14, 20:44, 20:47). So with the fix the main kernel beats LTS — the
`0eaa1f245ac0` regression never triggers because the firmware no longer crashes,
and the kernel itself is newer.

Caveat: logs from LTS boots made **before** the fix was installed have already
rotated out of the journal, so a precise before/after comparison for LTS is not
possible. The comparison above is limited to boots after 20:07, when
`disable_11ax` was already in the config.

---

## Installation

```bash
git clone https://github.com/Matvel007/intel-ax211-cachyos.git
cd intel-ax211-cachyos
sudo ./install.sh
sudo reboot
```

Or manually — three `cp` calls and a reboot.

Both scripts follow your locale (`$LC_ALL` / `$LC_MESSAGES` / `$LANG`): Russian
output on `ru_*` locales, English otherwise. No flags to remember.

### Verify after reboot

```bash
./diagnose.sh
```

The script reports the kernel, firmware version, applied parameters, link rate,
and crash counters across all boots.

---

## Important when reinstalling the OS

All three files live in `/etc` — **they are lost on a reinstall**, and the problem
comes back. That is exactly what happened here: the fix existed, the system was
reinstalled, the fix vanished, the symptoms returned.

Additionally: `linux-firmware-intel` is pinned to `20260622-1` via `IgnorePkg` in
`/etc/pacman.conf`, because the 2026-10-19 build crashes the card on **every**
boot:

```
IgnorePkg   = linux-firmware-intel
```

That line also has to be restored by hand.

---

## References

- [CachyOS forum: Intel AX211 (CNVi) completely disappears](https://discuss.cachyos.org/t/intel-ax211-cnvi-completely-disappears-on-cachyos-no-wi-fi-no-bluetooth/20544)
  — same symptom, "only a full shutdown + power drain restores"; on Windows with
  the same hardware and BIOS everything works
- [kernelthread: 8086:7a70 probe fails with -110](https://kernelthread.org/t/871p9s34o2.fsf@chud.cyou)
  — exactly this PCI ID, recovery via `remove` + `/sys/bus/pci/rescan`
- [pop-os#4101: SPM / Power Management regression in linux-firmware (AX211)](https://github.com/pop-os/pop/issues/4101)
  — linux-firmware regression, crash correlation with a 5 GHz BSS
- [Ubuntu Discourse: AX211 s2idle on Dell 7430](https://discourse.ubuntu.com/t/abnormal-battery-drain-during-suspend-s2idle-on-dell-latitude-7430/89171?page=3)
  — TWT-path analysis and the `disable_11ax=1` recipe
- [CachyOS#673: Intel iwlwifi instability](https://github.com/CachyOS/linux-cachyos/issues/673)
  — `Device error - SW reset`, `SYSTEM_STATISTICS_CMD`, SW TSO workaround for Wi-Fi 7
- [regzbot: iwlwifi IO_PAGE_FAULT and Master Disable Timed Out](https://linux-regtracking.leemhuis.info/regzbot/regression/lore/amzVtgQb2p-_nShU@debian.local/)
  — regression `0eaa1f245ac0`
- [Ubuntu #2148754](https://www.mail-archive.com/ubuntu-bugs@lists.ubuntu.com/msg6289716.html)
  — same dump analyzed: platform-side CNVi init failure, changing firmware does not help

---

## Caveats

- Verified on one machine, one BIOS, two kernels. `disable_11ax` may not help other
  AX211 models — but the mechanism (TWT in firmware) is common to the card.
- Eight boots is a solid sample against five failures out of seven, but not an
  absolute guarantee. Long-term observation is ongoing.
- The initialization crash is a bug below the driver level. `disable_11ax` works
  around it rather than fixing it. Once a kernel with the `0eaa1f245ac0` fix ships,
  `disable_11ax` may become unnecessary — retest separately.

## License

MIT
