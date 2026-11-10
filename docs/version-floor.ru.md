> English version: [version-floor.md](version-floor.md).
# Археология: сборка bcachefs DKMS + баг «отсутствие дрейна»

Дата отчёта: 2026-11-08. Метод: read-only раскопки (memory.recall global, rg по private-tooling, git -S/--grep по ~/projects/homelab, kn bundles, memos MCP). Ничего не изменено (отчёт в /tmp — единственная запись).

## VERDICT

**Баг «отсутствие дрейна»** = writeback/reconcile-очередь bcachefs перестаёт сливаться на диск (queue never drains). Операторская лексика подтверждается метриками hlmon: «очередь reconcile / дренаж n-тира» (`copygc_waiting_for_bytes`, `reconcile_blocked`, `reconcile_target_pending_bytes`, writeback `Leaving`).

**Первичный инцидент — август 2026**, НЕ ноябрь: пул 1.38.8 (tiered NVMe fast + HDD cold), конкурентность reconcile↔copygc → полный deadlock reconcile (застревание в `blk_mq_get_tag` при забитом NVMe), **~1 TB writeback-очередь стояла неделю** — очередь не дренировалась. Вторая хроника того же пула: stale generations → блокировка discard-воркера (`bad_data_type` 100% seen, `discarded: 0`; 2026-08-09 — 600 GB неудалённого, 2026-09-06 — 18.6M застрявших buckets).

**Фикс дрейна (версия/коммит): bcachefs 1.39.0** — архитектурное исправление «fragmentation LRU used by copygc is now per device instead of filesystem wide. This solves long standing contention issues between reconcile and copygc, particularly with tiered setups» (цитата 1.39.0 release notes через runbook 25). Подтверждено практикой: апгрейд пула 1.38.8→1.39.4 (DKMS с apt.bcachefs.org, ядро 7.1.3) 2026-09-06: writeback 190 GB → 537 MB за 15 ч, bad_data_type = 0.

**Модуль 1.39.7 (план-Б rootfs2.raw, Debian guest, host the lab host)** собран/поставлен 2026-11-03..04 (DKMS bcachefs-kernel-dkms 1:1.39.7 + tools 1:1.39.7, dkms 3.2.2; источник — репозиторий Кента apt.bcachefs.org; далее директива: собирать из исходников Кента одним деревом для обеих линий Debian+Alpine). 1.39.7 > 1.39.0 — фикс дрейна в нём есть; «пол: выше фикса дрейна» в директиве — именно про это. Символический коммит фикс-семейства — тег/релиз 1.39.0 (per_dev_fragmentation_lru, формат 1.39).

**Как разрулили**: (а) апгрейд на 1.39.x (архитектурный фикс); (б) Emergency kit для рецидивов: rw→ro→rw сброс аллокатора (`device set-state`), `trigger_gc` + `trigger_discards`; (в) директива 2026-11-08: модуль обеих линий — только своя сборка из дерева Кента, версия = осознанный пин выше фикса дрейна.

**Важная оговорка**: проза коммита 6c56fb4 «на ней [1.39.7] словили баг» — вероятно, сжатая транскрипция устной истории; письменные следы инцидента указывают на deadlock августа на 1.38.8 с фиксом в 1.39.0. Второго эпизода «нет дрейна» именно на 1.39.7 в ноябре НЕ найдено (проверены drain/дрейн/Leaving/backlog/stuck/stall/umount/hang по сессиям 11-03..11-07 и docs).

## EVIDENCE (каждое утверждение → источник)

1. **Устная история оператора, дословно** — сессия `01a1b6af` (2026-11-07T15:45, lineage root текущей ветки): «мы 1.39 собирали актуальный тогда, забирали из репозитория - столкнулись с багом отсутствием дрейна. Поэтому - собирать и для дебиана модуль надо и для alpine».
2. **Письменная дистилляция** — коммит `6c56fb4` (2026-11-08) `docs(bcachefs): module provenance`: «DKMS 1.39.7 в план-Б — НАША сборка из репозитория Кента... на ней словили баг отсутствия дрейна (устная история оператора, письменного трейса нет — rg/memory пусты)»; там же: «Версия = осознанный пин (пол: выше фикса дрейна; для G8: >= 1.39)». Дубли: `docs/freebsd/proposals/2026-11-06-bcachefsbox-appliance.md:27-32`, `docs/org-tasks.org:55`.
3. **Первичный инцидент (deadlock, очередь не уходит)** — runbook `docs/debian/25-bcachefs-upgrade-1.39.md` (коммит `caf269a` от 2026-09-06; файл удалён из рабочего дерева `faf5959`, жив в git): «В августе это привело к полному deadlock'у reconcile (застревание в `blk_mq_get_tag` при заполненном NVMe, очередь 1 TB стояла неделю)»; «Наблюдалось дважды: 2026-08-09 (600 GB...) и 2026-09-06 (18.6M застрявших buckets)»; «С подробным разбором в истории сессий the assistant от 2026-08-08..09 и 2026-09-06».
4. **Фикс-версия 1.39.0** — тот же runbook, цитата release notes (см. VERDICT); формат 1.39 = `per_dev_fragmentation_lru`.
5. **Верификация фикса на 1.39.4** — коммиты `9d324bf` (2026-09-06, «DKMS built clean for 7.1.3»), `a061ea8` (2026-09-06, «queue draining... writeback Leaving 203→166 GB in ~4 min»), `776d41d` (2026-09-07, «backlog drained in 15h: 190GB→537MB, zero bad_data_type»).
6. **Сборка 1.39.7 в план-Б** — сессия `01a1a45c` (2026-11-04T02:21): dpkg-факт «bcachefs-kernel-dkms 1:1.39.7 / bcachefs-tools 1:1.39.7» на guest 7.2.9+deb13; коммиты `89b4849` (ca-certificates перед apt.bcachefs.org), `7785a9d` (dkms headers Deps), `746301e` (v3 orchestrator, in-guest build) — все 2026-11-04; манифест совместимости `0b9bf62` (2026-11-06): «DKMS 1.39.7 — собран и под 7.2.9, и под 7.2.11».
7. **Лексика «дренаж» в доме** — сессия bcachefs-freebsd `01a1af46` (2026-11-06T05:12): «собирал `copygc_waiting_for_bytes`, `reconcile_blocked`... (та самая очередь reconcile / дренаж n-тира) из /sys/fs».
8. **Приватная цитата августа в октябрьских сессиях** — `01a17120` (2026-10-25) и `01a19233` (2026-10-31): «дедлок reconcile↔copygc — в августе застряло на неделю ~1TB writeback-очереди (`blk_mq_get_tag`, забитый NVMe); архитектурно починено только в 1.39.0».

## Первичные Aug/Sep-сессии: где они

На the lab host диска нет: `ls private-tooling = 0. Memory-провайдер держит cross-machine источники (`memory-source:the laptop stand/...`, `memory-source:the lab host-debian/...`) — но только октябрьские; Aug/Sep the assistant-сессии в локальном индексе отсутствуют (memory.sessions: не найдены). Их содержимое пережило в: runbook 25 (полный разбор), цитатах в сессиях 2026-10-19/25/31, коммитах caf269a/9d324bf/a061ea8/776d41d.

## Похожие, но ДРУГИЕ «no drain» (near-misses, чтобы не спутать)

- **bhyve UART TX drain** — IRQ-storm/THRE-livelock (сессия 2026-11-03T02:25, 40×drain; коммиты `49af450`, `a50cfde`, `uart_rxfifo_drain`) — консоль, не ФС.
- **NFSv4 «дрейн потребителей»** при cutover (сессия 2026-11-04T02:21) — про стоп сервисов перед umount /mnt/pool.
- **FUSE-порт «no drain»** (bcachefs-freebsd 2026-11-06/07, fusemount.rs/fs.rs): «Frozen accounting + no drain = scan never ran»; вердикт Ф0 ошибочно прочёл «no drain» как «поток не работает», реально — 9+ ч крауля скана по HDD-cold btree. Это Rust-порт tools (fusemount.rs), не DKMS-модуль VM.
- **python socket drain()** (2026-10-24, telnet Keenetic) — код-хелпер.
- **kn**: `~/kn/bundles/common/bcachefs-subvolume-list-entty.md` — другой баг (ENOTTY subvolume list на in-tree 6.12).
- **Memos**: `content.contains("bcachefs")` → 0 записей.

## Exhausted surfaces

1. memory.recall scope:global ×9 формулировок (RU+EN: dkms build, дрейн/drain, shutdown, koverstreet, 1.39, зависание, rust tools, trigger_gc, the assistant) — все top-hits ведут к найденному выше, первичных Aug/Sep нет.
2. rg по private-tooling 'дрейн|dkms|koverstreet' (30 файлов), '\bdrain' counts (top-15), 'blk_mq_get_tag' (3 файла), 'rootfs2', '1\.39\.7', 'apt\.bcachefs\.org', 'mount -t bcachefs' — покрыто.
3. git: --grep bcachefs/1.39, -S dkms, -S дрейн, -i -S drain, -- docs/debian — покрыто; docs/debian удалены (faf5959), читал из истории.
4. kn bundles: rg 'bcachefs|дрейн' — 5 файлов, релевантен только ENOTTY (другой баг).
5. Memos MCP: 0.

## Итоговая цепочка версий

1.38.8 (авг 2026: deadlock, нет дрейна, 1TB/неделю) → **1.39.0 = ФИКС дрейна** (per_dev_fragmentation_lru) → 1.39.4 (06-09-2026, верификация: 190GB→537MB/15ч) → **1.39.7** (03-04.11.2026, план-Б VM, apt.bcachefs.org/сборка Кента) → директива 08.11.2026: свои сборки из дерева Кента для Debian+Alpine, пин выше фикса дрейна.
