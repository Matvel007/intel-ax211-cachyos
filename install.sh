#!/usr/bin/env bash
# Install fixes for the RTL8125 AER storm that crashes Wi-Fi and blocks boot.
# Copies configs into /etc, keeping old files as .bak-<date>.
# Language follows the locale ($LC_ALL / $LC_MESSAGES / $LANG).
set -euo pipefail

detect_lang() {
    local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    case "$l" in
        ru*|*_RU*|*_RU.*|*_ru*) echo ru ;;
        *) echo en ;;
    esac
}
L="$(detect_lang)"

# say <english> <russian>
say() {
    if [ "$L" = ru ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

if [ "$(id -u)" -ne 0 ]; then
    say "Root required: sudo ./install.sh" "Нужен root: sudo ./install.sh" >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

install_file() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
        cp -a "$dst" "${dst}.bak-${STAMP}"
        say "  old file saved: ${dst}.bak-${STAMP}" \
            "  старый сохранён: ${dst}.bak-${STAMP}"
    fi
    install -m 0644 "$src" "$dst"
    say "  installed: $dst" "  установлен: $dst"
}

# ---------------------------------------------------------------------------
# 1. The actual fix: disable PCIe ASPM.
#
# The RTL8125 keeps its link in ASPM L1 and fails to wake up within the 16 us
# hardware limit, so it floods the bus with correctable AER errors. Those
# errors start ~0.8 s into boot, before any driver loads, and drag the whole
# chipset with them - including the CNVi Wi-Fi. Hence Wi-Fi "crashes" and
# boot hangs that look like a firmware bug.
# ---------------------------------------------------------------------------
say "== PCIe ASPM (the actual fix) ==" "== PCIe ASPM (настоящее лечение) =="

add_cmdline_param() {
    local param="$1"

    # Limine on CachyOS/Arch: the generated /boot/limine.conf must not be edited
    # by hand, /etc/default/limine is its source.
    if [ -f /etc/default/limine ]; then
        if grep -q "$param" /etc/default/limine 2>/dev/null; then
            say "  already present in /etc/default/limine" \
                "  уже есть в /etc/default/limine"
        else
            cp -a /etc/default/limine "/etc/default/limine.bak-${STAMP}"
            say "  old file saved: /etc/default/limine.bak-${STAMP}" \
                "  старый сохранён: /etc/default/limine.bak-${STAMP}"
            # Append to every KERNEL_CMDLINE[...] assignment.
            sed -i "s|\(KERNEL_CMDLINE\[[^]]*\]+=\"[^\"]*\)\"|\1 ${param}\"|" /etc/default/limine
            say "  added $param to /etc/default/limine" \
                "  добавлен $param в /etc/default/limine"
        fi
        if command -v limine-update >/dev/null 2>&1; then
            say "  regenerating bootloader config..." "  пересборка конфига загрузчика..."
            limine-update >/dev/null 2>&1 \
                && say "  bootloader config updated" "  конфиг загрузчика обновлён" \
                || { say "  ERROR: limine-update failed" "  ОШИБКА: limine-update не отработал" >&2; return 1; }
        else
            say "  WARNING: limine-update not found, regenerate manually" \
                "  ВНИМАНИЕ: limine-update не найден, пересоберите вручную" >&2
        fi
        return 0
    fi

    # GRUB fallback for other distributions.
    if [ -f /etc/default/grub ]; then
        if grep -q "$param" /etc/default/grub 2>/dev/null; then
            say "  already present in /etc/default/grub" "  уже есть в /etc/default/grub"
        else
            cp -a /etc/default/grub "/etc/default/grub.bak-${STAMP}"
            say "  old file saved: /etc/default/grub.bak-${STAMP}" \
                "  старый сохранён: /etc/default/grub.bak-${STAMP}"
            sed -i "s|\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 ${param}\"|" /etc/default/grub
            say "  added $param to /etc/default/grub" "  добавлен $param в /etc/default/grub"
        fi
        if command -v update-grub >/dev/null 2>&1; then
            update-grub >/dev/null 2>&1 && say "  grub config updated" "  конфиг grub обновлён"
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
                && say "  grub config updated" "  конфиг grub обновлён"
        else
            say "  WARNING: no grub regeneration tool found" \
                "  ВНИМАНИЕ: не найден инструмент пересборки grub" >&2
        fi
        return 0
    fi

    say "  ERROR: neither /etc/default/limine nor /etc/default/grub found." \
        "  ОШИБКА: не найден ни /etc/default/limine, ни /etc/default/grub." >&2
    say "  Add '$param' to the kernel command line manually." \
        "  Добавьте '$param' в параметры ядра вручную." >&2
    return 1
}

add_cmdline_param "pcie_aspm=off"

echo
say "== Wi-Fi power saving ==" "== Энергосбережение Wi-Fi =="
install_file "$SRC/modprobe.d/iwlwifi.conf" /etc/modprobe.d/iwlwifi.conf
install_file "$SRC/NetworkManager/conf.d/99-wifi-powersave-off.conf" \
             /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf

echo
say "== RTL8125 driver blacklist (optional) ==" "== Blacklist драйвера RTL8125 (опционально) =="
install_file "$SRC/modprobe.d/blacklist-r8169.conf" /etc/modprobe.d/blacklist-r8169.conf

echo
say "== Verifying modprobe sees the parameters ==" \
    "== Проверка, что modprobe видит параметры =="
modprobe --showconfig 2>/dev/null | grep -E '^(blacklist r8169|options iwl)' || {
    say "WARNING: modprobe does not see the parameters" \
        "ВНИМАНИЕ: параметры не видны modprobe" >&2
    exit 1
}

echo
say "Done. Reboot, then run ./diagnose.sh" \
    "Готово. Перезагрузитесь, затем запустите ./diagnose.sh"
echo
say "Note: kernel parameters apply at boot. Do NOT unload modules on a live" \
    "Примечание: параметры ядра применятся при загрузке. Выгружать модули"
say "system - with a crashed card this hangs the machine." \
    "на живой системе НЕ надо - при крахнутой карте это вешает машину."
