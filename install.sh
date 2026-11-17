#!/usr/bin/env bash
# Install fixes for Intel AX211 on CachyOS.
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

say "== Wi-Fi AX211 ==" "== Wi-Fi AX211 =="
install_file "$SRC/modprobe.d/iwlwifi.conf" /etc/modprobe.d/iwlwifi.conf

say "== RTL8125 (AER storm) ==" "== RTL8125 (AER-шторм) =="
install_file "$SRC/modprobe.d/blacklist-r8169.conf" /etc/modprobe.d/blacklist-r8169.conf

say "== Wi-Fi power saving ==" "== Энергосбережение Wi-Fi =="
install_file "$SRC/NetworkManager/conf.d/99-wifi-powersave-off.conf" \
             /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf

echo
say "== Checking that modprobe picks up the parameters ==" \
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
say "Note: parameters apply at boot. Do NOT unload modules on a live" \
    "Примечание: параметры применятся при загрузке. Выгружать модули"
say "system - with a crashed card this hangs the machine." \
    "на живой системе НЕ надо - при крахнутой карте это вешает машину."
