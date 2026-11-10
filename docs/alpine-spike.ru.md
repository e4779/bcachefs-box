> English version: [build-findings.md](build-findings.md).
# V0.3 STEP 2 REPORT — Alpine spike (2026-11-08)

## Результат: Alpine appliance ЗАГРУЖАЕТСЯ (wifibox-verbatim путь)

Бут-матрица (6 итераций, каждая с находкой):
| # | initramfs | вердикт | урок |
|---|---|---|---|
| 1 | FreeBSD-cpio, без лоадера | no-init | — |
| 2 | GNU-cpio, без лоадера | no-init | busybox динамический! |
| 3 | GNU-cpio + musl-лоадер, 3 модуля | **SHELL на консоли** | initramfs жив |
| 4 | FreeBSD-cpio + лоадер + 7 модулей | no-init | **F12: FreeBSD cpio newc ядром не принимается** |
| 5 | GNU-cpio, 7 модулей, БЕЗ лоадера (хост-каталог отстал) | no-init | сам-себе-грабли |
| 6 | GNU-cpio + лоадер + полный virtio-closure | **LOGIN PROMPT** | ✅ |

Финал: Welcome to Alpine Linux 3.23 / kernel 6.18.62-0-lts / ttyS0 login.

## Стек (всё host-native кроме cpio/ukify)
- Alpine minirootfs 3.23 + linux-lts 6.18.62 apk (файловая распаковка на хосте)
- initramfs: busybox + ld-musl-x86_64.so.1 (!) + 7 модулей (virtio, virtio_ring,
  virtio_pci + legacy/modern_dev, virtio_blk, squashfs) с каноническим modules.dep
- ядро Alpine: SQUASHFS=m VIRTIO_BLK=m ⇒ initramfs обязателен (в отличие от
  кастом-конфига wifibox, где =y и initramfs не нужен)
- root = squashfs 141MB (vs Debian 1.09GB — ×7.7 меньше)
- UKI собирает ukify в Debian-госте; cpio — GNU cpio в госте (F12)

## Гейт по версии (решение)
- Alpine edge: bcachefs-tools 1.38.0 < 1.39 ⇒ G8-пул (формат 1.39) Alpine-
  инструментам недоступен. Вердикт: Alpine = референс РЕЦЕПТА (scratch-пулы
  самосогласованы на 1.38), G8-демо остаётся за Debian-линией (DKMS 1.39.7).
- bcachefs-tools в образ ещё не включён (minirootfs-only бут) — следующий шаг:
  apk add bcachefs-tools (+ akms/bcachefs-src модуль) в образ или в-гостевую.

## Находки (F12-F14)
- **F12**: FreeBSD cpio -H newc ≠ принимаемый ядром newc — initramfs собирать
  только GNU cpio (wifibox потому и живёт в Linux-тулчейне).
- **F13**: busybox minirootfs ДИНАМИЧЕСКИЙ — ld-musl обязателен в initramfs,
  иначе «No working init found» (сообщение покрывает и unpack-fail, и exec-fail).
- **F14**: virtio-модули 6.18 — полный closure зависимостей (virtio_ring,
  virtio_pci_{legacy,modern}_dev) — минимальный modules.dep с пустыми deps
  молча не грузит блочное устройство.
- Операционно: фоновые задачи со scp стабильно зависают (5+ раз) — доставка
  файлов только прямыми короткими вызовами.

## Артефакты
/tmp/alpine-initramfs (каталог-рецепт), /tmp/alpine6.EFI (рабочий UKI),
/tmp/alpine-root.sqfs, console-alpine-sqfs-boot.log (evidence).


## Corrigendum (2026-11-08, вечер)
«Самосогласован на 1.38» требовал оговорки: bcachefs удалён из mainline
v6.17→v6.18 — in-tree поддержки в ядре 6.18 НЕТ. Рецепт обязан печь модуль
через akms (bcachefs-tools depends="akms") на этапе сборки образа. Проверено:
fs/bcachefs отсутствует на peeled v6.18 (контроль Makefile OK), v6.16/6.17
содержат по 260 записей. F15.