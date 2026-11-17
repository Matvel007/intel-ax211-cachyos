# Intel AX211 (CNVi) на CachyOS: падение при загрузке, emergency mode, зависание выключения

Разбор реальной проблемы и рабочее исправление. Всё проверено на живой машине,
данные — из `journalctl`, `dmesg` и дампов прошивки.

**TL;DR** — одна строка в `/etc/modprobe.d/iwlwifi.conf`:

```
options iwlwifi disable_11ax=1
```

Откат с 802.11ax (Wi-Fi 6) на 802.11ac убирает падения прошивки. 8 загрузок
подряд без единого сбоя, до этого — 5 провалов из 7.

---

## Железо и система

| | |
|---|---|
| Ноутбук | MECHREVO KUANGSHI Series, Intel Core i5-14450HX |
| Wi-Fi | Intel Wi-Fi 6E AX211, CNVi, PCI `8086:7a70`, PCI-адрес `0000:00:14.3` |
| Проводная | Realtek RTL8125 2.5GbE, PCI `10ec:8125`, `0000:05:00.0` |
| GPU | NVIDIA RTX 5060 Laptop + Intel iGPU |
| BIOS | AMI `N.1.21MRO16` от 24.07.2025 |
| Дистрибутив | CachyOS (Arch-based) |
| Ядра | `7.3.4-1-cachyos` (основное), `6.18.60-2-cachyos-lts` |
| Прошивка Wi-Fi | `89.735b75a4.0`, `iwlwifi-so-a0-gf-a0-89.ucode` |
| Загрузчик | Limine, btrfs + snapper |

---

## Симптомы

Три разных проявления, одна причина.

### 1. Ноутбук не загружается

```
Failed to load your GPU driver(s)
You can't get into desktop environment right now
```

Падение в emergency mode. Не помогало ничего: ни обычное ядро, ни LTS, ни
загрузка со снапшота. `systemctl --failed` показывал `avahi-daemon.service` и
`polkit.service`, что уводит в сторону — они просто жертвы.

### 2. Выключение зависает

```
[FAILED] Failed unmounting /var/cache
[  **  ] A start job is running for Generate shutdown-ramfs (1min 39s / no limit)
pcieport 0000:00:1d.0: AER: Error of this Agent is reported first
```

Помогает только кнопка питания.

### 3. Wi-Fi отваливается в работе

```
iwlwifi 0000:00:14.3: Device error - SW reset
iwlwifi 0000:00:14.3: restart completed
```

Интернет пропадает на 30 секунд — 3.5 минуты, потом возвращается сам.

---

## Диагностика

### Настоящая причина зависания загрузки

Ключ — стек заблокированного процесса:

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

Что происходит:

1. Прошивка Wi-Fi падает на инициализации
2. Драйвер пытается остановить устройство и **навсегда застревает** в
   `synchronize_irq`, ожидая прерывание, которое уже не придёт
3. Процесс `modprobe` держит `module_mutex` — глобальную блокировку загрузки модулей
4. **После этого не грузится ни один модуль.** В том числе `nvidia_drm`
5. Отсюда «Failed to load your GPU driver(s)» и emergency mode

То есть GPU-ошибка — это следствие, а не причина. Отсюда и бесполезность
снапшотов: дело не в корневой файловой системе.

### Дамп прошивки при падении

```
iwlwifi 0000:00:14.3: 0x00000084 | NMI_INTERRUPT_UNKNOWN
iwlwifi 0000:00:14.3: 0x20000066 | NMI_INTERRUPT_HOST
iwlwifi 0000:00:14.3: 0x60000000 | FSEQ_ERROR_CODE
iwlwifi 0000:00:14.3: SecBoot CPU1 Status: 0x8650, CPU2 Status: 0xb03
iwlwifi 0000:00:14.3: Failed to start RT ucode: -110
```

`FSEQ_ERROR_CODE` ненулевой — это платформенная инициализация CNVi на стороне
чипсета (CSME) проваливается **до** того, как драйвер вступает в дело.
`SecBoot CPU1 Status` появляется только в неудачных загрузках, в успешных его нет.

В работе падение выглядит иначе — предвестник:

```
iwlwifi 0000:00:14.3: Error sending SYSTEM_STATISTICS_CMD: time out after 2000ms.
iwlwifi 0000:00:14.3: Current CMD queue read_ptr 831 write_ptr 832
```

Прошивка перестаёт отвечать на команды, потом падает.

### Регрессия ядра, превращающая сбой в мёртвое зависание

Коммит [`0eaa1f245ac0`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=0eaa1f245ac0)
(«wifi: iwlwifi: mvm: don't support the reset handshake for old firmwares»),
вошёл в **v7.1-rc7**.

Код в `drivers/net/wireless/intel/iwlwifi/mvm/ops.c`:

```c
if (IWL_UCODE_MAJOR(mvm->fw->ucode_ver) <= 77)
    trans->conf.fw_reset_handshake = false;
```

Прошивка версии 89 хранит версию в новом TLV-формате как `0x59` (89).
`IWL_UCODE_MAJOR()` сдвигает на 24 бита и получает **0**. Условие `0 <= 77`
истинно → reset-handshake отключается → драйвер теряет механизм мягкого сброса
и виснет вместо перезапуска карты.

Регрессия зарегистрирована в [regzbot](https://linux-regtracking.leemhuis.info/regzbot/regression/lore/amzVtgQb2p-_nShU@debian.local/)
как «iwlwifi IO_PAGE_FAULT and Master Disable Timed Out».

**Где исправлено:** в `linux-next`, но не в mainline на момент проверки
(17.11.2026):

```c
trans->conf.fw_reset_handshake =
    fw_has_capa(&mvm->fw->ucode_capa,
                IWL_UCODE_TLV_CAPA_FW_RESET_HANDSHAKE) &&
    mvm->fw->ucode_ver > 77;
```

**Практический вывод:** `7.3.4-1-cachyos` содержит регрессию, `6.18.60-2-cachyos-lts`
— нет. Это единственное реальное различие между ядрами в контексте проблемы.

### Что НЕ является причиной

Проверялось и отброшено:

- **Прошивка.** Пробовал три билда: `735b75a4` (пакет 20260622),
  `a67023b2` (core24.90-60, upstream от 08.11.2026), `123cf747` (core102-56).
  Первый — 5 провалов из 7, второй — **11 из 12, стало хуже**, третий не
  проверялся. Смена прошивки меняет вероятность, но не убирает причину.
- **ASPM.** Уже выключен на обоих концах линка (`LnkCtl: ASPM Disabled`).
- **Быстрая перезагрузка.** Корреляция с паузой была (20–27 с → сбой,
  43 с → успех), но после фикса `disable_11ax` перезагрузки подряд без пауз
  проходят чисто.
- **`power_save` / `power_scheme`.** Помогают от другого — от высокого пинга,
  но падения на инициализации не убирают.
- **Хук `modprobe -r iwlwifi` в `system-shutdown`.** Не помогает и опасен: при
  крахнутой карте выгрузка виснет в том же `synchronize_irq`, и выключение
  зависает навсегда.
- **AER-ошибки от Realtek RTL8125.** Отдельный дефект (см. ниже), к Wi-Fi
  отношения не имеет.

---

## Исправление

### 1. Отключить Wi-Fi 6 (802.11ax) — главное

`/etc/modprobe.d/iwlwifi.conf`:

```
options iwlwifi disable_11ax=1
options iwlwifi power_save=0
options iwlmvm power_scheme=1
```

Основание: разбор AX211 в [Ubuntu Discourse](https://discourse.ubuntu.com/t/abnormal-battery-drain-during-suspend-s2idle-on-dell-latitude-7430/89171?page=3)
— «the firmware bug lives in the 802.11ax Target Wake Time path», откат на
802.11ac его обходит.

Почему работает: падение происходит в TWT-логике 802.11ax. Без ax карта
инициализируется по другому пути, и `FSEQ_ERROR_CODE` не возникает.

**Цена:** линк 802.11ac вместо 802.11ax. Скорость 1404–1733 Мбит/с вместо 1921
при ширине 160 МГц. Для домашней сети незаметно.

**Проверка:**

```bash
cat /sys/module/iwlwifi/parameters/disable_11ax    # → Y
iw dev wlan0 link | grep bitrate                   # → VHT-MCS, не HE-MCS
```

### 2. Убрать AER-шторм от RTL8125

`/etc/modprobe.d/blacklist-r8169.conf`:

```
blacklist r8169
```

Проблема: проводной порт без кабеля сыпет корректируемыми PCIe-ошибками.

```
r8169 0000:05:00.0: PCIe Bus Error: severity=Correctable, type=Data Link Layer, (Transmitter ID)
r8169 0000:05:00.0:    [12] Timeout
aer_ratelimit: 9884 callbacks suppressed
```

Почти десять тысяч подавленных сообщений за одну вспышку, до 4+ ошибок в секунду,
каждая — прерывание. Причина в драйвере, не в железе: без `r8169` за 5+ минут
**ноль** новых ошибок.

`blacklist` блокирует только автозагрузку. Понадобится проводной интернет:

```bash
sudo modprobe r8169
```

### 3. Выключить энергосбережение Wi-Fi

`/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf`:

```
[connection]
wifi.powersave = 2
```

Без этого пинг по локальной сети 40–165 мс вместо 1–3.

---

## Результаты

Замеры на `7.3.4-1-cachyos`, прошивка `735b75a4`.

### До исправления

| | |
|---|---|
| Загрузок | 7 |
| С провалом | **5** |
| Зависаний `synchronize_irq` | 4 в одной загрузке |
| `Device error - SW reset` в работе | 4 за день |

### После

| | |
|---|---|
| Загрузок на 7.3.4 | **8** |
| С провалом | **0** |
| Зависаний | 0 |
| `Failed to start RT ucode` | 0 |
| `Device error - SW reset` | 0 |
| `SecBoot CPU1 Status` | не появлялся ни разу |

Пинг по LAN: 1.0–2.5 мс, 0% потерь.
Сигнал: −47 dBm, 160 МГц, `VHT-MCS 9`.

Для сравнения, LTS `6.18.60` с тем же конфигом: **5 загрузок, 3 с провалом** (20:14, 20:44,
20:47). То есть с фиксом обычное ядро лучше LTS — регрессия `0eaa1f245ac0` там
не срабатывает, потому что прошивка больше не падает, а само ядро новее.

Оговорка: логи LTS-загрузок, сделанных **до** установки фикса, уже ротировались
из журнала, поэтому «до/после» по LTS точно не измерить. Сравнение выше —
по загрузкам после 20:07, когда `disable_11ax` уже стоял в конфиге.

---

## Установка

```bash
git clone https://github.com/Matvel007/intel-ax211-cachyos.git
cd intel-ax211-cachyos
sudo ./install.sh
sudo reboot
```

Или вручную — три `cp` и перезагрузка.

### Проверка после перезагрузки

```bash
./diagnose.sh
```

Скрипт покажет: ядро, версию прошивки, применённые параметры, скорость линка,
счётчики сбоев по всем загрузкам.

---

## Важно при переустановке системы

Все три файла живут в `/etc` — **при переустановке они пропадают**, и проблема
возвращается. Это ровно то, что случилось здесь: фикс был, переустановили
систему, фикс исчез, симптомы вернулись.

Дополнительно: `linux-firmware-intel` заморожен на `20260622-1` через
`IgnorePkg` в `/etc/pacman.conf`, потому что сборка от 19.10.2026 валит карту
намертво на **каждой** загрузке:

```
IgnorePkg   = linux-firmware-intel
```

Эту строку тоже надо вернуть вручную.

---

## Источники

- [CachyOS forum: Intel AX211 (CNVi) completely disappears](https://discuss.cachyos.org/t/intel-ax211-cnvi-completely-disappears-on-cachyos-no-wi-fi-no-bluetooth/20544)
  — тот же симптом, «only a full shutdown + power drain restores», на Windows
  с тем же железом и BIOS всё работает
- [kernelthread: 8086:7a70 probe fails with -110](https://kernelthread.org/t/871p9s34o2.fsf@chud.cyou)
  — ровно этот PCI ID, восстановление через `remove` + `/sys/bus/pci/rescan`
- [pop-os#4101: SPM / Power Management regression in linux-firmware (AX211)](https://github.com/pop-os/pop/issues/4101)
  — регрессия linux-firmware, корреляция крашей с 5 ГГц BSS
- [Ubuntu Discourse: AX211 s2idle на Dell 7430](https://discourse.ubuntu.com/t/abnormal-battery-drain-during-suspend-s2idle-on-dell-latitude-7430/89171?page=3)
  — разбор TWT-path и рецепт `disable_11ax=1`
- [CachyOS#673: Intel iwlwifi instability](https://github.com/CachyOS/linux-cachyos/issues/673)
  — `Device error - SW reset`, `SYSTEM_STATISTICS_CMD`, SW TSO workaround для Wi-Fi 7
- [regzbot: iwlwifi IO_PAGE_FAULT and Master Disable Timed Out](https://linux-regtracking.leemhuis.info/regzbot/regression/lore/amzVtgQb2p-_nShU@debian.local/)
  — регрессия `0eaa1f245ac0`
- [Ubuntu #2148754](https://www.mail-archive.com/ubuntu-bugs@lists.ubuntu.com/msg6289716.html)
  — разбор того же дампа: сбой платформенной инициализации CNVi, смена прошивки
  не помогает

---

## Оговорки

- Проверено на одной машине, один BIOS, два ядра. Не факт, что `disable_11ax`
  поможет на других моделях с AX211 — но механизм (TWT в прошивке) у карты общий.
- Восемь загрузок — достаточная выборка против пяти провалов из семи, но
  не абсолютная гарантия. Долгосрочная проверка продолжается.
- Падение прошивки на инициализации — баг ниже уровня драйвера. `disable_11ax`
  его обходит, а не исправляет. Когда выйдет ядро с фиксом `0eaa1f245ac0`,
  возможно, `disable_11ax` станет не нужен — проверять отдельно.

## Лицензия

MIT
