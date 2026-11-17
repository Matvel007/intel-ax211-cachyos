#!/usr/bin/env bash
# Диагностика состояния Wi-Fi AX211 и сетевых устройств.
# Запускать без root — только чтение.
set -uo pipefail

echo "=== Ядро ==="
uname -r

echo
echo "=== Прошивка ==="
echo -n "на диске: "
if [ -f /usr/lib/firmware/intel/iwlwifi/iwlwifi-so-a0-gf-a0-89.ucode.zst ]; then
    zstd -dc /usr/lib/firmware/intel/iwlwifi/iwlwifi-so-a0-gf-a0-89.ucode.zst 2>/dev/null \
        | head -c 60 | strings | head -1
else
    echo "файл не найден"
fi
echo -n "загружена: "
journalctl -b 0 --no-pager 2>/dev/null | grep -oE '[0-9]+\.[0-9a-f]{8}\.0' | head -1 || echo "нет данных"

echo
echo "=== Параметры модулей ==="
for p in disable_11ax power_save swcrypto bt_coex_active; do
    printf 'iwlwifi.%-15s = %s\n' "$p" "$(cat /sys/module/iwlwifi/parameters/$p 2>/dev/null || echo '?')"
done
printf 'iwlmvm.%-16s = %s\n' power_scheme "$(cat /sys/module/iwlmvm/parameters/power_scheme 2>/dev/null || echo '?')"

echo
echo "=== Линк ==="
iw dev wlan0 link 2>/dev/null | grep -E 'SSID|signal|freq|bitrate' || echo "wlan0 не подключён"
echo -n "power save: "
iw dev wlan0 get power_save 2>/dev/null | sed 's/Power save: //'

echo
echo "=== RTL8125 ==="
if lsmod | grep -q '^r8169'; then
    echo "r8169 загружен (проводной порт активен)"
else
    echo "r8169 не загружен (blacklist работает)"
fi
echo -n "AER-ошибок в текущей загрузке: "
dmesg 2>/dev/null | grep -c 'AER' || echo 0

echo
echo "=== Сбои iwlwifi по загрузкам ==="
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
echo "=== Итог ==="
total=0; bad=0
for b in $(journalctl --list-boots --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^-?[0-9]+$'); do
    total=$((total+1))
    if [ "$(journalctl -b "$b" --no-pager 2>/dev/null | grep -cE 'Failed to start RT|NMI_INTERRUPT_UNKNOWN|Device error - SW reset')" != "0" ]; then
        bad=$((bad+1))
    fi
done
echo "загрузок: $total, с проблемами: $bad"
