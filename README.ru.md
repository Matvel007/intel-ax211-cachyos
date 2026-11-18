# CachyOS не грузится, Wi-Fi «падает»: AER-шторм от RTL8125

[🇬🇧 English version](README.md)

Разбор реальной проблемы и рабочее исправление. Всё проверено на живой машине,
данные — из `journalctl`, `dmesg`, `lspci` и счётчиков AER.

**TL;DR** — один параметр ядра, `pcie_aspm=off`:

```bash
# /etc/default/limine
KERNEL_CMDLINE[default]+="quiet nowatchdog splash pcie_aspm=off rw rootflags=subvol=/@ root=UUID=..."
```

```bash
sudo limine-update
```

Проводной Realtek RTL8125 заваливает шину PCIe корректируемыми AER-ошибками:
энергосбережение PCIe ASPM L1 не успевает его разбудить. Ошибки начинаются ещё
до загрузки любого драйвера и тянут за собой весь чипсет — включая Wi-Fi Intel
CNVi. После фикса: **0 AER-ошибок, 0 сбоев Wi-Fi, Wi-Fi 6 снова на 1921 Мбит/с**.

> **Поправка к прежней версии этого репозитория.** Раньше здесь винили прошивку
> AX211 и советовали `disable_11ax=1` (откат на 802.11ac). Это было неверно.
> Откат снижал число сбоев только потому, что снижал нагрузку на шину, — а не
> потому, что что-то исправлял. С настоящим фиксом Wi-Fi 6 работает без единого
> сбоя, и `disable_11ax` убран. См. [Что НЕ является причиной](#что-не-является-причиной).

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

Проводной порт не используется — ноутбук работает по Wi-Fi. Кабель за всё время
не подключался ни разу.

---

## Симптомы

Три разных проявления, одна причина.

### 1. Ноутбук не загружается

Встаёт на логотипе CachyOS. На экране — десятки красных строк ядра. До рабочего
стола не доходит.

Пять загрузок подряд, одна и та же картина:

```
boot   kernel              AER   iwl   graph
-5     7.3.4-1-cachyos     220     0       0
-4     7.3.4-1-cachyos     180     0       0
-3     7.3.4-1-cachyos     160     0       0
-2     7.3.4-1-cachyos     100     0       0
-1     7.3.4-1-cachyos     240     0       0
 0     7.3.4-1-cachyos     440     0       1   <- дошла только эта
```

`graph = 0` значит, что `Reached target Graphical Interface` так и не наступил.
Ядро всю загрузку печатало AER-ошибки вместо запуска systemd.

На более раннем этапе сбой выглядел иначе — emergency mode с
`Failed to load your GPU driver(s)`, а `systemctl --failed` показывал
`avahi-daemon.service` и `polkit.service`. Оба — жертвы, а не причины.

### 2. Выключение зависает

```
[FAILED] Failed unmounting /var/cache
[  **  ] A start job is running for Generate shutdown-ramfs (1min 39s / no limit)
pcieport 0000:00:1d.0: AER: Error of this Agent is reported first
```

Помогает только кнопка питания. Обратите внимание на root port в этой строке —
`0000:00:1d.0`, это родитель контроллера Realtek.

### 3. Wi-Fi отваливается в работе

```
iwlwifi 0000:00:14.3: 0x00000084 | NMI_INTERRUPT_UNKNOWN
iwlwifi 0000:00:14.3: Device error - SW reset
iwlwifi 0000:00:14.3: restart completed
```

Прошивка сбрасывается сама и восстанавливается за секунды — три раза за двадцать
минут в одной сессии. Со стороны пользователя это выглядит как «Wi-Fi завис».
Если сброс не завершается, машина виснет и нужна жёсткая перезагрузка.

---

## Диагностика

### Всё указывает на одно устройство

Из **690 AER-ошибок** за одну загрузку **690 принадлежат `0000:05:00.0`** —
проводному Realtek RTL8125. Wi-Fi-контроллер `0000:00:14.3` не упоминается
ни разу:

```bash
journalctl -b 0 | grep 'PCIe Bus Error' | grep -oE 'pci [0-9a-f:]+' | sort | uniq -c
```

```
    690 pci 0000:05:00
```

Типы ошибок:

```
    403 [12] Timeout   | Transmitter | Data Link Layer
    400 [ 0] RxErr     | Receiver    | Physical Layer
      7 [ 6] BadTLP    | Receiver
      3 [ 8] Rollover  | Transmitter
```

`RxErr` на **физическом уровне** — главная улика: линк не тренируется, это не
проблема программного протокола.

### Начинается до загрузки любого драйвера

Шторм стартует на **0.8 секунде загрузки**, когда в журнале ещё голое имя хоста
(`cachyos`, а не `cachyos-x8664`) — это initramfs, до systemd и до загрузки
модулей:

```
Nov 18 20:57:36 cachyos kernel: pcieport 0000:00:1d.0: PCIe Bus Error: severity=Correctable
```

То есть `r8169` не виноват. Blacklist драйвера ничего не меняет — устройство
всё равно висит на шине и всё равно её заваливает. Проверено.

### Масштаб

```
aer_ratelimit: 34739 callbacks suppressed
```

34 739 подавленных колбэков за одну вспышку. Ratelimiter ядра печатает несколько
и молча отбрасывает остальные — поэтому журнал выглядит терпимо, хотя шина
фактически насыщена.

### Причина: ASPM L1

```
$ lspci -vv -s 05:00.0 | grep LnkCtl
    LnkCtl: ASPM L1 Enabled; RCB 64 bytes, LnkDisable- CommClk+
```

PCIe Active State Power Management уводит линк в состояние пониженного
энергопотребления. RTL8125 не успевает проснуться в аппаратный лимит (16 мкс),
и каждая попытка пробуждения даёт корректируемую ошибку. Корректируемая значит,
что линк восстанавливается сам — целостность данных в порядке, но шину молотят
тысячи раз в секунду.

Это известная проблема Realtek, описанная в разных дистрибутивах и на разных
платах — см. [Источники](#источники).

### Почему это валит Wi-Fi

Модуль Wi-Fi CNVi и контроллер Ethernet сидят на одном чипсете. Когда шина
насыщена обработкой ошибок, прошивка Wi-Fi не укладывается в свои сроки и
сбрасывается. Сопоставьте время — совпадение точное:

```
20:45:11  PCIe Bus Error от 05:00.0
20:45:13  iwlwifi: NMI_INTERRUPT_UNKNOWN -> SW reset
20:47:06  PCIe Bus Error от 05:00.0
20:47:08  iwlwifi: NMI_INTERRUPT_UNKNOWN -> SW reset
```

**Честная оговорка:** это корреляция, а не доказанный механизм. В одной загрузке
было 6 AER-ошибок и ноль сбоев Wi-Fi, то есть объём AER сам по себе сброс не
гарантирует. Доказано другое: после устранения шторма сбои Wi-Fi прекратились
полностью.

### Как это выглядело, когда драйвер Wi-Fi застревал

Пока корневая причина не была ясна, сбой загрузки иногда показывал зависший
`modprobe`, держащий глобальную блокировку модулей:

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

Драйвер пытался остановить сбойное устройство и навсегда застревал в
`synchronize_irq`, ожидая прерывание, которое уже не придёт. Поскольку `modprobe`
держал `module_mutex`, после этого не грузился ни один модуль — включая
`nvidia_drm`, отсюда «Failed to load your GPU driver(s)». GPU-ошибка была
следствием, а не причиной, и снапшоты не могли помочь: дело было не в корневой
файловой системе.

### Что НЕ является причиной

- **Прошивка Wi-Fi.** `disable_11ax=1` стоял полтора месяца в предположении, что
  падает 802.11ax Target Wake Time path. Он снижал число сбоев за счёт снижения
  нагрузки на шину, а не за счёт исправления. После настоящего фикса Wi-Fi 6
  работает с **нулём** сбоев, и `disable_11ax` убран.
- **Драйвер `r8169`.** Его blacklist ошибки не останавливает.
- **Ядро.** Проверено на `7.3.4` и `6.18.60-lts` — поведение одинаковое.
  Регрессия `0eaa1f245ac0` в основном ядре делает зависание *хуже*, когда оно
  случается, но не вызывает его.
- **Версия пакета прошивки.** Пробовал три билда; смена прошивки меняла
  вероятность, но никогда не убирала проблему.
- **btrfs или снапшоты.** Загрузка со снапшота падала точно так же.

---

## Исправление

### Отключить PCIe ASPM

Добавить в командную строку ядра:

```
pcie_aspm=off
```

В Limine (CachyOS, Arch) сгенерированный `/boot/limine.conf` руками править
нельзя — правьте его источник:

```bash
# /etc/default/limine
KERNEL_CMDLINE[default]+="quiet nowatchdog splash pcie_aspm=off rw rootflags=subvol=/@ root=UUID=<ваш-uuid>"
```

```bash
sudo limine-update
```

На системах с GRUB:

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=off"
```

```bash
sudo update-grub
```

### Проверка

**Не судите по `lspci`.** Он продолжает показывать `ASPM L1 Enabled` и после
фикса, потому что параметр велит ядру перестать *управлять* ASPM — он не
переписывает то, что уже настроил BIOS. Судить надо по счётчику ошибок:

```bash
journalctl -b 0 | grep -c 'PCIe Bus Error'
```

Ноль — значит работает.

### Цена

Около +0.9 Вт в простое на порт. Для ноутбука это заметно, но немного. Если
критично — попробуйте сначала `pcie_aspm.policy=performance`: ASPM остаётся
включённым, но не уходит в самые глубокие состояния, иногда этого хватает.

### Что не работает

`pci=noaer` — **прячет** ошибки вместо исправления. Зависание загрузки
прекращается (потому что зависание было из-за печати 34 тыс. строк), но шину
продолжают молотить молча. Только как крайний вариант.

### Опционально: не грузить неиспользуемый драйвер

Если проводной порт не нужен, `blacklist r8169` не даёт интерфейсу подняться.
Он **не** лечит AER-шторм — это стоит повторить, потому что в это верили долго.
Чтобы вернуть кабель:

```bash
sudo modprobe r8169
```

### Опционально: энергосбережение Wi-Fi

`/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf`:

```
[connection]
wifi.powersave = 2
```

Без этого пинг по локальной сети 40–165 мс вместо 1–3. К AER-шторму отношения
не имеет, но вещь полезная.

---

## Результаты

| | До | После |
|---|---|---|
| AER-ошибок за загрузку | 875 | **0** |
| Сбоев прошивки Wi-Fi | 3 за 20 мин | **0** |
| Загрузок, дошедших до графики | 1 из 6 | **все** |
| Стандарт Wi-Fi | 802.11ac (`VHT-MCS 9`) | **802.11ax (`HE-MCS 9`)** |
| Скорость приёма Wi-Fi | 1404 Мбит/с | **1921 Мбит/с** |
| Пинг по LAN | 1.0–2.5 мс | 1.0–2.5 мс |

После фикса `disable_11ax=1` был убран, и Wi-Fi 6 работает без сбоев — это
подтверждает, что прошивка никогда не была проблемой.

---

## Установка

```bash
git clone https://github.com/Matvel007/rtl8125-aer-storm.git
cd rtl8125-aer-storm
sudo ./install.sh
sudo reboot
```

Скрипт:

1. добавляет `pcie_aspm=off` в командную строку ядра (`/etc/default/limine` или
   `/etc/default/grub`) и пересобирает конфиг загрузчика;
2. ставит конфиги энергосбережения Wi-Fi;
3. опционально добавляет `r8169` в blacklist;
4. каждый затронутый файл сохраняет как `.bak-<дата>`.

Оба скрипта сами подстраивают язык под локаль (`$LC_ALL` / `$LC_MESSAGES` /
`$LANG`): на `ru_*` печатают по-русски, иначе по-английски. Флагов запоминать
не надо.

### Проверка после перезагрузки

```bash
./diagnose.sh
```

Только чтение, root не нужен. Показывает: применён ли фикс, счётчик AER за
текущую загрузку, какое устройство их даёт, число сбоев Wi-Fi и таблицу по всем
загрузкам с корреляцией AER и успеха загрузки.

---

## Важно при переустановке системы

- Фикс живёт в **командной строке ядра**, а не в конфиге модуля. Новое ядро его
  сохранит; переустановка загрузчика или пересоздание `/etc/default/limine` —
  потеряет.
- Если после правки машина не грузится, держите `Shift`/`Esc` в меню Limine и
  выберите снапшот.
- После обновления BIOS проверьте заново — некоторые прошивки сбрасывают
  политику ASPM.

---

## Источники

- [AskUbuntu: PCIe Bus Error severity=Corrected, Physical Layer](https://askubuntu.com/questions/863150/pcie-bus-error-severity-corrected-type-physical-layer-id-00e5receiver-id)
  — `pcie_aspm=off` как принятый ответ, с оговоркой, что `pci=noaer` только маскирует
- [Proxmox forum: AER Correctable error message received](https://forum.proxmox.com/threads/aer-correctable-error-message-received.156497/)
  — тот же root port `00:1d.0`, тот же `RxErr`, вылечено `pcie_aspm=off`
- [Gentoo forums: PCI ethernet device issue related to AER](https://forums.gentoo.org/viewtopic-p-8819315.html)
  — ошибки начинаются на 0.8 с, до загрузки драйвера
- [Launchpad #2015670: r8169 kernel loop PCIe Bus Error](https://bugs.launchpad.net/bugs/2015670)
  — отчёт именно по Realtek
- [Ubuntu #2148754](https://www.mail-archive.com/ubuntu-bugs@lists.ubuntu.com/msg6289716.html)
  — сбой платформенной инициализации CNVi, смена прошивки не помогает
- [CachyOS forum: Intel AX211 (CNVi) completely disappears](https://discuss.cachyos.org/t/intel-ax211-cnvi-completely-disappears-on-cachyos-no-wi-fi-no-bluetooth/20544)
  — то же железо, на Windows всё работает

Ранее, когда подозревалась прошивка Wi-Fi:

- [pop-os#4101: SPM / Power Management regression in linux-firmware (AX211)](https://github.com/pop-os/pop/issues/4101)
- [CachyOS#673: Intel iwlwifi instability](https://github.com/CachyOS/linux-cachyos/issues/673)
- [Ubuntu Discourse: AX211 s2idle на Dell 7430](https://discourse.ubuntu.com/t/abnormal-battery-drain-during-suspend-s2idle-on-dell-latitude-7430/89171?page=3)
  — источник рецепта `disable_11ax=1`, который здесь оказался не нужен

---

## Оговорки

- Проверено на одной машине, один BIOS, два ядра. Механизм (задержка
  пробуждения ASPM L1 на Realtek) распространённый, но другие модели могут вести
  себя иначе.
- Связь между объёмом AER и сбросом прошивки Wi-Fi — **корреляция, а не
  доказательство**. В одной загрузке AER были, а сбоев Wi-Fi не было.
- Корректируемые ошибки означают, что целостность данных не страдает. Это
  проблема стабильности и производительности, а не порчи данных.
- `pcie_aspm=off` действует глобально — на все устройства PCIe, не только на
  Realtek. Побочных эффектов не замечено, но настройка общесистемная.
- Если ошибки остаются и с фиксом, следующий шаг — BIOS: отключить *PCIe native
  power management* / ASPM для LAN-контроллера.

---

## Лицензия

MIT — см. [LICENSE](LICENSE).
