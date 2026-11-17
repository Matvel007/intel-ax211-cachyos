#!/usr/bin/env bash
# Diagnose Intel AX211 Wi-Fi and network device state.
# Read-only, no root needed.
# Language follows the locale ($LC_ALL / $LC_MESSAGES / $LANG).
set -uo pipefail

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
# sayn <english> <russian>  -- no trailing newline
sayn() {
    if [ "$L" = ru ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

say "=== Kernel ===" "=== Ядро ==="
uname -r

echo
say "=== Firmware ===" "=== Прошивка ==="
sayn "on disk:   " "на диске: "
if [ -f /usr/lib/firmware/intel/iwlwifi/iwlwifi-so-a0-gf-a0-89.ucode.zst ]; then
    zstd -dc /usr/lib/firmware/intel/iwlwifi/iwlwifi-so-a0-gf-a0-89.ucode.zst 2>/dev/null \
        | head -c 60 | strings | head -1
else
    say "not found" "файл не найден"
fi
sayn "loaded:    " "загружена: "
journalctl -b 0 --no-pager 2>/dev/null | grep -oE '[0-9]+\.[0-9a-f]{8}\.0' | head -1 \
    || say "no data" "нет данных"

echo
say "=== Module parameters ===" "=== Параметры модулей ==="
for p in disable_11ax power_save swcrypto bt_coex_active; do
    printf 'iwlwifi.%-15s = %s\n' "$p" "$(cat /sys/module/iwlwifi/parameters/$p 2>/dev/null || echo '?')"
done
printf 'iwlmvm.%-16s = %s\n' power_scheme "$(cat /sys/module/iwlmvm/parameters/power_scheme 2>/dev/null || echo '?')"

echo
say "=== Link ===" "=== Линк ==="
iw dev wlan0 link 2>/dev/null | grep -E 'SSID|signal|freq|bitrate' \
    || say "wlan0 not connected" "wlan0 не подключён"
sayn "power save: " "power save: "
iw dev wlan0 get power_save 2>/dev/null | sed 's/Power save: //'

echo
say "=== RTL8125 ===" "=== RTL8125 ==="
if lsmod | grep -q '^r8169'; then
    say "r8169 loaded (wired port active)" "r8169 загружен (проводной порт активен)"
else
    say "r8169 not loaded (blacklist working)" "r8169 не загружен (blacklist работает)"
fi
sayn "AER errors in this boot: " "AER-ошибок в текущей загрузке: "
dmesg 2>/dev/null | grep -cE 'PCIe Bus Error|aer_ratelimit|AER: (Corrected|Uncorrected)' || true

echo
say "=== iwlwifi failures per boot ===" "=== Сбои iwlwifi по загрузкам ==="
for b in $(journalctl --list-boots --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^-?[0-9]+$'); do
    k=$(journalctl -b "$b" --no-pager 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-cachyos(-lts)?')
    n=$(journalctl -b "$b" --no-pager 2>/dev/null | grep -cE 'Failed to start RT|NMI_INTERRUPT_UNKNOWN')
    h=$(journalctl -b "$b" --no-pager 2>/dev/null | grep -cE 'blocked on a mutex|synchronize_irq')
    s=$(journalctl -b "$b" --no-pager 2>/dev/null | grep -c 'Device error - SW reset')
    f=$(journalctl -b "$b" --no-pager 2>/dev/null | grep -c 'loaded firmware version')
    printf 'boot %-3s | %-24s | init=%s hang=%s swreset=%s fw_ok=%s\n' \
        "$b" "${k:-?}" "$n" "$h" "$s" "$f"
done

echo
say "=== Summary ===" "=== Итог ==="
total=0; bad=0
for b in $(journalctl --list-boots --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^-?[0-9]+$'); do
    total=$((total+1))
    if [ "$(journalctl -b "$b" --no-pager 2>/dev/null | grep -cE 'Failed to start RT|NMI_INTERRUPT_UNKNOWN|Device error - SW reset')" != "0" ]; then
        bad=$((bad+1))
    fi
done
say "boots: $total, with problems: $bad" "загрузок: $total, с проблемами: $bad"
