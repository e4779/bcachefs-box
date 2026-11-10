> English version: [alpha-run.md](alpha-run.md).
# α-LIVE RUN REPORT — FUSE→VM переключение на живом G8 (2026-11-09)

Статус: IN PROGRESS — пул в глубоком recovery (deep passes), см. финал.

## Прогресс церемонии
1. ✅ Квитирование: p2p (amuled/amutorrent/qbt/stash/navidrome) + poolfuse +
   poolwatchd + fusefs.ko из kld_list — погашены/выключены. BE
   pre-alpha-quiesce-1109-0200. Ребут хоста чистый.
2. ✅ Контрольный NFSv4 roundtrip на скретчах после холодного старта
   (STEP2-RT-OK, named attributes, 0.1ms).
3. ✅ План-Б + G8 бейзлайн: пул rw, 4.4T/2.7T данные, библиотека цела,
   NFS с хоста читается (PLANB-NFS-OK).
4. ⏸ Appliance + G8: ИНЦИДЕНТ (ниже), пул в recovery.

## ИНЦИДЕНТ: двойной rw + unclean shutdown
- 16:03 план-Б поднял пул rw (бейзлайн). Одновременно f3heal — вочдог
  FUSE-линии (v2, 2026-11-07, «first aid = bounce the daemon», while-цикл)
  — не знавший о VM-линии, поднял FUSE-маунт ПОВЕРХ VM-дисков: 4 мин
  двойного rw (DKMS 1.39.7 kernel + Rust FUSE-порт, разные реализации).
- 16:07 план-Б погашен force-poweroff (unclean).
- 16:11 appliance-mount: journal replay OK, но check_alloc_info →
  journal_shutdown — само-восстановление на маунте исчерпано.
- 16:22 план-Б поднят снова: going read-write на 29-й минуте, superblock
  назначил 4 deep-прохода (check_topology, check_allocations,
  check_alloc_info, btree_bitmap_gc), идёт последовательный прогон с
  полными btree-ресканами. ETA 1.5-3ч (vdc 3.6T HDD — узкое место).

## Разбор инцидента
- КОРЕНЬ: f3heal_enable=YES остался в автостарте — мой квитец-инвентарь
  погасил poolfuse/poolwatchd, но f3heal (рядом в sysrc-списке) я прочитал
  глазами и пропустил. F26: квитец = полный 'service -e', не выборочный
  grep; имена вочдогов не говорят о их функции.
- КОЛЛИЗИЯ АРХИТЕКТУР: две линии (FUSE-хостовая и VM) претендуют на
  одни G8-диски; вочдог одной линии не знает о жизни другой. Пока обе
  линии существуют — нужен общий mutex (например: f3heal проверяет
  bcachefsbox_enable/статус VM; или единый pool-orchestrator).
- F27: /tmp очищается при ребуте (clear_tmp_enable) — тестовые диски
  образа только на zvols (/tmp/scratch.img исчез → FATAL супервизора,
  VM «не стартовала», а я читал СТАРЫЙ консоль-лог — F28: перед чтением
  вердикта лог трункировать и проверять свежесть бута).
- F29: утренний «FUSE вернулся» = f3heal всё время переподнимал демона
  (двойняшки-демоны 15:28/15:32 — его цикл). rc-скрипт честно был NO —
  raiser жил в отдельном сервисе.

## Исполнитель после вердикта
- MOUNTED → bcachefs fsck (план-Б tools) → спот-чек данных → продолжение
  α шага 4 (appliance swap) → сервисы по одному.
- FAILED → userspace fsck -y из план-Б (ради него и бутаемся туда).


## ФИНАЛ α (2026-11-10, 00:40): ПОЛНЫЙ УСПЕХ
- Recovery завершён (6 проходов, ~7.5ч суммарно; ущерб от двойного rw =
  2 checksum errors на vdc; write errors 0; библиотека читалась на
  промежуточных стадиях).
- Чистое гашение план-Б сняло recovery-флаги superblock.
- APPLIANCE + G8: пул смонтирован МГНОВЕННО (pool-up [ok], nfsd [ok]).
- Хост: NFSv4+nconnect=4 → библиотека, спот-риф 158 MB/s
  (3MB / 0.0198s). ALPHA-STEP4-HOST-OK.
- Вердикт: VM-appliance жизнеспособен как прод-стек для G8-пула.
  Остаток α: сервисы по одному (postgres → navidrome → qbt → stash →
  amule) + soak — следующее окно.
