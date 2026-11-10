# V0.3 STEP 4 REPORT — NFS-плоскость аплаенса: репетиция замкнута (2026-11-08, ночь)

## Итог: appliance несёт полный сервисный стек (boot 24, всё зелёное)

squashfs ro-root теперь: eth0 static MTU9000 + OpenRC (sysinit/boot/default,
набор = wifibox-список) + pool-up (2-member rw) + pool-nfs (self-contained
unit: rpcbind foreground, nfsd-fs, exportfs, mountd v3, nfsd 3/4/4.1/4.2).
Host-side: TCP 2049/111 живые. Хост-маунт NFSv4 блокируют ТОЛЬКО зомби
mount_nfs (клиентский артефакт итераций до MTU-фикса; procstat-стек:
nfsrpc_exchangeid -> clnt_reconnect_call; чистятся ребутом хоста — входит
в α-церемонию). Данных roundtrip через NFSv3+mounkd не снимали — окно α.

## Debug-сага вечера (14 бутов 10-24) — находки в рецепт
- F22: rpcbind НЕ выживает под busybox start-stop-daemon (молча умирает);
  supervise-daemon в minirootfs openrc игнорируется. Решение: self-contained
  pool-nfs сам поднимает rpcbind -f -s &. wifibox этого не знал — у него
  нет NFS (проверено: их гость = сток-юниты wpa_supplicant/hostapd).
- F23: rpc.statd не нужен для NFSv4 (нет NSM/NLM) — выкинут; v3-путь
  закрыт rpc.mountd.
- F24 (root cause хостовских зомби): MTU! tap1=9000, eth0 был 1500 ->
  первый v4-connect умирал -> mount_nfs уходил в бесконечный reconnect
  (unkillable), держал per-server лок: ВСЕ последующие маунты = EBUSY
  без единого пакета. Дисциплина: tcpdump+procstat -k ДО вердиктов.
- F25: ложный positivе "roundtrip OK": запись+cat на НЕсмонтированной
  точке = локальный файл. Тест-гейт: mount | grep ДО записи.
- F21 (инцидент, чист): dd-вайп /dev/vdc затёр v0-state.raw (guard
  grep -q сматчился о закомментированные PHASE0-строки; vdc был 0.9.0
  state-диск, не scratch02). Ущерб = артефакт v0.1-эксперимента,
  заменимо. Урок: идентификация устройства — по слоту+серийнику, не по имени.
- apk --root PATH должен быть CHROOT-относительным; nfs init-скрипты
  живут в *-openrc субпакетах.
- wifibox-audit (по запросу оператора, 2й раз): сервис-набор совпал
  с их SYSINIT/BOOT_SERVICES пофайлово; перенято: /var-оверлей (для G8),
  tar2sqfs-конвейер и vmlinuz-as-bootx64 (вариант A гиста).

## Артефакты
Образ: newroot15.sqfs (vmv03p2), UKI alpine10.EFI (ESP vmv03p1).
Юниты: services/bcachefsbox/image/{pool-up.initd,pool-nfs.initd}.
Скретч: scratch.img + scratch02 zvol (репетиционный 2-member пул).
Консоль: console-appliance-nfs-final.log. VM оставлена РАБОТАЮЩЕЙ (demo).

## α-готовность (наживую)
1. Ребут хоста (чистит зомби; FUSE-стек погасить перед) -> host-mount
   NFSv4 roundtrip на скретче = финальная галочка репетиции.
2. Кват из FUSE + потребителей (окно оператора) -> слоты 0.3.0/0.4.0 ->
   G8 (серийные гарды супервизора) -> план-Б бейзлайн -> appliance swap.
3. Сервисы по одному: postgres -> navidrome -> qbt -> stash -> amule.


## ФИНАЛ (постскриптум, ~01:50): хост-маунт NFSv4 ДОКАЗАН
Зомби-mount_nfs из до-MTU-итерации дожил на reconnect-таймере до
рабочего сервера: 172.31.255.2:/pool смонтировался (nfs, nfsv4acls,
named attributes), roundtrip write→read→ls→umount = RT-V4-OK.
РЕПЕТИЦИЯ 100%: boot → pool(2-member rw) → NFS → host-mount → данные.
Ребут хоста для α остаётся как чистка клиентского состояния (зомби
самоresolved), не как блокер.