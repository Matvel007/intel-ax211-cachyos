#!/usr/bin/env bash
# Установка исправлений для Intel AX211 на CachyOS.
# Копирует конфиги в /etc, старые сохраняет рядом с суффиксом .bak-<дата>.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root: sudo ./install.sh" >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

install_file() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
        cp -a "$dst" "${dst}.bak-${STAMP}"
        echo "  старый сохранён: ${dst}.bak-${STAMP}"
    fi
    install -m 0644 "$src" "$dst"
    echo "  установлен: $dst"
}

echo "== Wi-Fi AX211 =="
install_file "$SRC/modprobe.d/iwlwifi.conf" /etc/modprobe.d/iwlwifi.conf

echo "== RTL8125 (AER-шторм) =="
install_file "$SRC/modprobe.d/blacklist-r8169.conf" /etc/modprobe.d/blacklist-r8169.conf

echo "== Энергосбережение Wi-Fi =="
install_file "$SRC/NetworkManager/conf.d/99-wifi-powersave-off.conf" \
             /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf

echo
echo "== Проверка, что modprobe видит параметры =="
modprobe --showconfig 2>/dev/null | grep -E '^(blacklist r8169|options iwl)' || {
    echo "ВНИМАНИЕ: параметры не видны modprobe" >&2
    exit 1
}

echo
echo "Готово. Перезагрузитесь, затем запустите ./diagnose.sh"
echo
echo "Примечание: параметры применятся при загрузке. Выгружать модули"
echo "на живой системе НЕ надо — при крахнутой карте это вешает машину."
