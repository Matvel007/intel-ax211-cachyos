#!/usr/bin/env bash
# Diagnose the RTL8125 AER storm that crashes Wi-Fi and blocks boot.
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
say "=== Kernel command line: is the fix applied? ===" \
    "=== Параметры ядра: применён ли фикс? ==="
if grep -q 'pcie_aspm=off' /proc/cmdline 2>/dev/null; then
    say "pcie_aspm=off PRESENT - fix is active" "pcie_aspm=off ЕСТЬ - фикс работает"
else
    say "pcie_aspm=off MISSING - AER storm will continue" \
        "pcie_aspm=off НЕТ - AER-шторм продолжится"
fi
sayn "cmdline: " "cmdline: "
cat /proc/cmdline

echo
echo
say "=== ASPM ===" "=== ASPM ==="
sayn "policy: " "policy: "
cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo '?'
say "Note: lspci keeps showing 'ASPM L1 Enabled' even with the fix - the kernel" \
    "Примечание: lspci продолжает показывать 'ASPM L1 Enabled' и с фиксом - ядро"
say "just stops managing it. Judge by the AER counter, not by lspci." \
    "просто перестаёт им управлять. Судить надо по счётчику AER, а не по lspci."

echo
say "=== AER errors (the actual problem) ===" "=== AER-ошибки (настоящая проблема) ==="
aer_boot=$(journalctl -b 0 --no-pager 2>/dev/null | grep -c 'PCIe Bus Error')
sayn "in this boot:            " "в текущей загрузке:      "
printf '%s\n' "$aer_boot"
sayn "in the last 5 minutes:   " "за последние 5 минут:    "
journalctl -b 0 --since '-5 min' --no-pager 2>/dev/null | grep -c 'PCIe Bus Error'

echo
say "which devices report errors:" "какие устройства сообщают об ошибках:"
journalctl -b 0 --no-pager 2>/dev/null | grep 'PCIe Bus Error' \
    | grep -oE 'pci [0-9a-f:]+' | sort | uniq -c \
    || say "  none" "  нет"

echo
say "error types:" "типы ошибок:"
journalctl -b 0 --no-pager 2>/dev/null \
    | grep -oE '\[[0-9 ]+\] [A-Za-z]+ +\| [A-Za-z ]+' | sort | uniq -c | head -6 \
    || say "  none" "  нет"

echo
sayn "suppressed by ratelimit: " "подавлено ratelimit:     "
journalctl -b 0 --no-pager 2>/dev/null \
    | grep -oE 'aer_ratelimit: [0-9]+' | awk '{s+=$2} END {print s+0}'

echo
say "=== iwlwifi failures ===" "=== Сбои iwlwifi ==="
sayn "in this boot: " "в текущей загрузке: "
journalctl -b 0 --no-pager 2>/dev/null \
    | grep -cE 'NMI_INTERRUPT_UNKNOWN|Device error - SW reset|Failed to start RT'

echo
say "=== Link ===" "=== Линк ==="
iw dev wlan0 link 2>/dev/null | grep -E 'SSID|signal|freq|bitrate' \
    || say "wlan0 not connected" "wlan0 не подключён"
sayn "power save: " "power save: "
iw dev wlan0 get power_save 2>/dev/null | sed 's/Power save: //'

echo
say "=== RTL8125 driver ===" "=== Драйвер RTL8125 ==="
if lsmod | grep -q '^r8169'; then
    say "r8169 loaded (wired port active)" "r8169 загружен (проводной порт активен)"
else
    say "r8169 not loaded (blacklist working)" "r8169 не загружен (blacklist работает)"
fi

echo
say "=== Boot history: AER storm vs Wi-Fi failures ===" \
    "=== История загрузок: AER-шторм против сбоев Wi-Fi ==="
printf '%-6s %-26s %8s %8s %8s %8s\n' "boot" "kernel" "AER" "iwl" "graph" "startup"
for b in $(journalctl --list-boots --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^-?[0-9]+$'); do
    log=$(journalctl -b "$b" --no-pager 2>/dev/null)
    k=$(printf '%s' "$log" | grep -m1 -oE 'Linux version [^ ]+' | awk '{print $3}')
    a=$(printf '%s' "$log" | grep -c 'PCIe Bus Error')
    i=$(printf '%s' "$log" | grep -cE 'NMI_INTERRUPT_UNKNOWN|Device error - SW reset')
    g=$(printf '%s' "$log" | grep -c 'Reached target Graphical Interface')
    s=$(printf '%s' "$log" | grep -c 'Startup finished')
    printf '%-6s %-26s %8s %8s %8s %8s\n' "$b" "${k:-?}" "$a" "$i" "$g" "$s"
done

echo
say "AER = PCIe bus errors, iwl = Wi-Fi firmware failures," \
    "AER = ошибки шины PCIe, iwl = сбои прошивки Wi-Fi,"
say "graph = reached graphical interface (1 = boot completed)." \
    "graph = дошло до графики (1 = загрузка завершилась)."

echo
say "=== Verdict ===" "=== Итог ==="
has_rtl=$(lspci -nn 2>/dev/null | grep -c '10ec:8125' || true)
has_fix=0
grep -q 'pcie_aspm=off' /proc/cmdline 2>/dev/null && has_fix=1

if [ "$has_rtl" -eq 0 ]; then
    say "No Realtek RTL8125 in this machine - nothing to fix here." \
        "В этой машине нет Realtek RTL8125 - лечить нечего."
elif [ "$aer_boot" -gt 0 ] && [ "$has_fix" -eq 0 ]; then
    say "AER storm is active and the fix is not applied." \
        "AER-шторм активен, фикс не применён."
    say "Run: sudo ./install.sh" "Запустите: sudo ./install.sh"
elif [ "$aer_boot" -eq 0 ]; then
    say "No AER errors - the fix is working." "AER-ошибок нет - фикс работает."
else
    say "Fix is applied but errors remain. Try a BIOS setting:" \
        "Фикс применён, но ошибки остались. Попробуйте настройку BIOS:"
    say "disable PCIe native power management / ASPM for the LAN controller." \
        "отключить PCIe native power management / ASPM для LAN-контроллера."
fi
