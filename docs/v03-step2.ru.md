> English version: [build-findings.md](build-findings.md).
# V0.3 STEP 2 REPORT — bcachefs-модуль из дерева Кента + pool-up (2026-11-08, вечер)

## Результат: GATE PASSED

Alpine-аплаенс монтирует bcachefs-пул на бут: модуль 1.39.7 собран из дерева
Кента против заголовков 6.18.62-0-lts, запечён в initramfs, грузится и
монтирует scratch-пул rw. Полный интероп: mkfs (edge tools 1.38) → rw-запись
(наш модуль 1.39.7, Alpine) → чтение (DKMS 1.39.7, Debian-билдер).

## Сборка модуля (рецепт, F16)
Среда: Alpine-chroot внутри Debian-билдера (minirootfs + linux-lts-dev
6.18.62-r0 = точное совпадение версий с ядром аплаенса). Компиляция —
НЕ из корня тарболла (то тянет cargo): Kent's staging из его же Makefile:
  mkdir -p D/src/fs/bcachefs; tar -C fs -cf - . | tar -C D/src/fs/bcachefs -xf -
  cp -a dkms/Makefile D/Makefile
  echo '#define bcachefs_version "1.39.7"' > D/src/fs/bcachefs/version.h
  cp -a dkms/module-version.c D/src/fs/bcachefs/
  env BCACHEFS_DKMS=1 make -C /usr/src/linux-headers-6.18.62-0-lts M=D modules
Канонический скрипт: services/bcachefsbox/image/kmod-build.sh.
Источник: evilpiepirate.org/bcachefs-tools/bcachefs-tools-1.39.7.tar.zst.
vermagic: 6.18.62-0-lts SMP preempt mod_unload modversions (точный).
BUILD_EXCLUSIVE_KERNEL_MIN=6.16 (dkms.conf Кента).

## Boot-цепочка (initramfs v7)
busybox-init + модули: virtio(-closure), squashfs, bcachefs.ko.gz (22.7MB) +
6 зависимостей (xor, raid6_pq, libchacha, libpoly1305, lz4_compress,
lz4hc_compress — все =m, листовые). UKI alpine8.EFI = 38MB. /init:
modprobe bcachefs → mount -t bcachefs /dev/vdb → POOL-UP OK в консоль.

## Доказательства
console-alpine-poolup.log: "starting version need_discard_by_journal_seq
(1.38)" → модуль 1.39.7 монтирует формат 1.38 (forward-compat); 
"POOL-UP: OK". BOOT-PROOF.txt записан аплаенсом, прочитан Debian-билдером.

## Находки
- F16: рецепт сборки kmod (выше) — корень тарболла = cargo-ловушка; правильный
  вход = dkms/Makefile + staging fs/.
- F17: squashfs ro-root — точки монтирования пулов надо печь в образ
  (mkdir в ro /newroot падает); воркараунд демо = /pool-tmp в initramfs.
- F18 (env): alpine-chroot в Debian: apk требует IPv4-пин в /etc/hosts
  (musl IPv6-first, v6-маршрута нет); зеркало = mirror.yandex.ru/MIRRORS/alpine
  (не /alpine!); RM='rm -f' экспортировать (в kbuild-контексте пуст); нужны
  musl-dev + linux-headers (UAPI → /usr/include/linux/types.h) + весь pkg-config
  dev-набор Кента (bcachefs.ko линкует юзерспейс-объекты — libbcachefs.a).
- v03.raw = zvol vmv03 (GPT: p1 ESP msdosfs, p2 squashfs) — sqfs обновляется
  dd прямо в /dev/zvol/zroot/vmv03p2 (без гостя).
- Scratch-пул: /tmp/scratch.img 2G (файл как virtio-диск), формат 1.38.

## Осталось в (b)
- Печь /pool-каталог в sqfs + OpenRC pool-up сервис (замена initramfs-хака)
- tools в образ (cargo-сборка из того же дерева — или edge 1.38 для scratch)
- гист-рецепт: вычитка + alignment-сверка с локальными клонами wifibox
