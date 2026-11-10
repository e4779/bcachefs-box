#!/bin/sh
# run-bcachefsbox.sh — bcachefsbox v3 supervising orchestrator (POSIX sh).
#
# Repo source of truth : services/bcachefsbox/run-bcachefsbox.sh (NOT deployed)
# Deployed copy        : /vm/bcachefsbox/run-bcachefsbox.sh   (phase 3, see README)
# Spec                 : docs/freebsd/20-bcachefsbox-v3.md §1 (APPROVED 2026-11-04)
# Amendment p1a (operator, 2026-11-04): bhyve starts NATIVELY declarative —
#   "bhyve -k <file>" (bhyve(8) -k: "Set configuration variables from a
#   simple, key-value config file"; variables per bhyve_config(5)). Manual
#   assembly of -c/-m/-w/-H/-s/-l is RETIRED; the VM description lives in
#   bhyve-vm.conf (seed: bhyve-vm.conf.sample next to this script). This
#   script owns only the LIFECYCLE. Config layering: README.md «Конфиги».
# Predecessor (v2)     : /vm/bcachefsbox/run-hlab.sh (repo copy: services/bcachefsbox/run-hlab.sh)
#
# Modes:
#   (no args)       supervise loop — rc.d daemon mode (stdout → /var/log/bcachefsbox-run.log)
#   --stop          stop protocol: SIGTERM bhyve → ACPI grace → --force-poweroff → --destroy
#   --lint          validate BOTH configs + environment, change NOTHING, exit 0
#   --print-config  print the runtime -k file for console=off AND console=log;
#                   change nothing
#
# Loop semantics (v2 heritage):
#   bhyve exit 0   = guest rebooted (bhyve.8:1160-1161 "Exit status ... 0 rebooted")
#                    → restart in 2 s;
#   any other exit = 1 powered off / 2 halted / 3 triple fault / 4 error / 5 suspended
#                    (bhyve.8:1162-1166) → linear backoff 5*tries s, max 120 s.
#   tries reset after an instance that lived ≥ 300 s. The ONLY manual stop is
#   `service bcachefsbox stop` — rc.d kills this supervisor first, then --stop.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

: "${VMTAG:=bcachefsbox}"
: "${CONF:=/vm/bcachefsbox/bhyve.conf}"
# bhyve — ONLY by absolute path, and only the uartfix binary. Plan §1:
#   "bhyve — ТОЛЬКО по абсолютному пути /usr/local/libexec/bhyve-uartfix
#    (PATH молча возьмёт сток без EOF-патча → возврат mevent-спина)" —
# the 2026-11-02/03 softlockup storm was the stock bhyve stdio-console EOF
# spin (docs/freebsd/19-bcachefsbox-zen5-timer-investigation.md).
# The binary is -k-capable: its usage line is "[-k config_file]"
# (verified 2026-11-05 via bhyve-uartfix -h).
BHYVE=/usr/local/libexec/bhyve-uartfix
: "${NMDM:=/dev/nmdm-bcachefsbox}"
: "${CONLOG:=/var/log/bcachefsbox-console.log}"
NETASSERT_LOG=/var/log/netassert.log
: "${CONFIG_SHARE_DIR:=/vm/bcachefsbox/config}"
: "${STATUS_SHARE_DIR:=/var/run/bcachefsbox}"
# --- p1a: declarative VM description (bhyve_config(5)) fed to bhyve -k ---
# Layering (README «Конфиги»): the VM itself is described by bhyve-vm.conf;
# lifecycle knobs (nice, stop grace, console mode) stay in the shell $CONF.
# The ROOTFS/BOOTROM constants of the pre-p1a script moved INTO the conf —
# the supervisor now reads device paths from the file, not from its body.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VMSAMPLE=$SCRIPT_DIR/bhyve-vm.conf.sample  # repo/deploy seed (first run copies it)
: "${VMCONF:=/vm/bcachefsbox/bhyve-vm.conf}"       # deployed declarative VM description
RUNTIME_VMCONF=$STATUS_SHARE_DIR/vm.conf   # per-launch -k file (inside the rw 9p
                                           # status share — no secrets there, the
                                           # guest may read its own geometry)
# resctrl boot-assert marker (see resctrl_assert below)
RESCTRL_MARKER=/usr/local/libexec/vmm-resctrl-patched.marker
RESCTRL_DELAY=10

LOGGER=""
ECHO_ASSERT=""

# ---------------------------------------------------------------- logging ---
# Plan principle 4: alerts do NOT go through syslogd — it froze 03:01:47 on
# 2026-11-04 while everything else kept dying silently. All logging goes to
# stdout (captured by daemon(8) -o into /var/log/bcachefsbox-run.log) and to
# dedicated files (console/netassert logs).
log() { echo "$(date '+%F %T') $*"; }

die() { log "FATAL: $*"; exit 3; }

usage() {
    cat <<EOF
usage: $0 [--lint|--stop|--print-config]
  (no args)       supervise the $VMTAG VM (rc.d daemon mode)
  --stop          stop protocol: SIGTERM bhyve -> ACPI grace (stop_wait_max)
                  -> bhyvectl --force-poweroff -> --destroy
  --lint          validate lifecycle conf + bhyve-vm.conf + environment,
                  show the generated runtime -k file; change nothing, exit 0
  --print-config  print the runtime -k file for console=off and console=log
EOF
}

# --------------------------------------------------- lifecycle config (sh) ---
# Layering (README «Конфиги»): bhyve.conf = LIFECYCLE of the ORCHESTRATOR
# (nice, stop grace, console routing). The GUEST is described declaratively
# in bhyve-vm.conf (bhyve_config(5)); cpus/memory/pool disks moved there in
# p1a — leftovers in an old bhyve.conf are sourced but IGNORED.
# wifibox load_bhyve_conf_values pattern (sbin/wifibox:244-265): internal
# defaults first, then ". $CONF", then assert-style validation below.
nice_priority=15
stop_wait_max=60
console=log

load_conf() {
    if [ -f "$CONF" ]; then
        . "$CONF"
    else
        log "WARN: $CONF not found — running on built-in defaults"
    fi
}

# wifibox assert_value_* helpers (sbin/wifibox:510-555), POSIX-sh form.
assert_wellformed() { # name syntax expected value
    if ! echo "$4" | grep -Eq "$2"; then
        die "$CONF: malformed $1 value '$4', expected: $3"
    fi
}

assert_ranged_int() { # name lower upper value
    assert_wellformed "$1" '^-?[0-9]+$' 'an integer' "$4"
    if [ "$4" -lt "$2" ] || [ "$4" -gt "$3" ]; then
        die "$CONF: $1 must be between $2 and $3, got '$4'"
    fi
}

validate_conf() {
    # nice(1): priorities run -20 (highest) .. 20 (lowest); we want the
    # storage VM LOWER priority than interactive load → positive values.
    assert_ranged_int nice_priority -20 20 "$nice_priority"
    # wifibox:541 validates stop_wait_max in 1..60 — same range here.
    assert_ranged_int stop_wait_max 1 60 "$stop_wait_max"
    case "$console" in
        off|log|cu) ;;
        *) die "$CONF: console must be one of off|log|cu, got '$console'" ;;
    esac
}

# ------------------------------------------ declarative VM conf (bhyve -k) ---
# bhyve(8) -k: "Set configuration variables from a simple, key-value config
# file. Each line ... name, an equals sign ('='), and a value. No spaces are
# permitted ... Blank lines and lines starting with '#' are ignored."
# Variables per bhyve_config(5). The supervisor:
#   1. seeds $VMCONF from the adjacent sample on the first run;
#   2. validates it (name/cpus/memory.size/bootrom/PCI tree/paths);
#   3. per launch generates $RUNTIME_VMCONF (console=off strips lpc.com1.*;
#      a missing 9p config share strips pci.0.10.0.*, wifibox WARN
#      precedent — bhyve would abort on open(O_DIRECTORY) otherwise);
#   4. starts: nice -n $nice_priority $BHYVE -k $RUNTIME_VMCONF $VMTAG.
ensure_vmconf() {
    if [ ! -f "$VMCONF" ]; then
        [ -f "$VMSAMPLE" ] || die "no $VMCONF and no sample $VMSAMPLE to seed from"
        log "vmconf: $VMCONF absent — seeding from $VMSAMPLE (first run)"
        cat "$VMSAMPLE" >"$VMCONF" || die "vmconf: cannot write $VMCONF"
    fi
}

vmc() { # $1 = anchored regexp, $2 = src — first matching value ('^' anchor
    # excludes '#' comments by construction; comments live on own lines only)
    grep -E "^$1" "$2" 2>/dev/null | head -n 1 | cut -d= -f2-
}

vmconf_blk_paths() { # $1 = src — backing paths of ACTIVE virtio-blk nodes
    grep -E '^pci\.[0-9]+\.[0-9]+\.[0-9]+\.device=virtio-blk$' "$1" |
        cut -d. -f1-4 |
        while IFS= read -r _n; do
            _re=$(printf '%s' "$_n" | sed 's/\./\\./g')
            grep -E "^${_re}\.path=" "$1" | cut -d= -f2-
        done
}

vmconf_pool_members() { # $1 = src — active /dev/ virtio-blk paths (G8 scope)
    vmconf_blk_paths "$1" | grep '^/dev/' || true
}

validate_vmconf() { # $1 = conf path
    _src=$1
    [ -f "$_src" ] || die "bhyve-vm.conf: not found: $_src"
    # name: the vmm(4) instance identity; must equal the positional vmname
    # the supervisor passes after -k (see the launch site in supervise()).
    _v=$(vmc 'name=' "$_src")
    [ "$_v" = "$VMTAG" ] || die "bhyve-vm.conf: name must be '$VMTAG', got '$_v'"
    # cpus: same gate as pre-p1a — 1..hw.vmm.maxcpu.
    _maxcpu=$(sysctl -n hw.vmm.maxcpu 2>/dev/null || echo 64)
    _v=$(vmc 'cpus=' "$_src")
    echo "$_v" | grep -Eq '^-?[0-9]+$' \
        || die "bhyve-vm.conf: cpus must be an integer, got '$_v'"
    [ "$_v" -ge 1 ] && [ "$_v" -le "$_maxcpu" ] \
        || die "bhyve-vm.conf: cpus must be between 1 and $_maxcpu, got '$_v'"
    # memory.size: bhyve_config(5) — "formatted as described in expand_number(3)".
    _v=$(vmc 'memory\.size=' "$_src")
    echo "$_v" | grep -Eq '^[0-9]+[KkMmGgTt]$' \
        || die "bhyve-vm.conf: memory.size must be an integer with K/M/G/T unit suffix (e.g. 4096M), got '$_v'"
    # bootrom: bhyve_config(5) "Path to a boot ROM" — must exist.
    _v=$(vmc 'bootrom=' "$_src")
    [ -n "$_v" ] && [ -f "$_v" ] || die "bhyve-vm.conf: bootrom missing: '$_v'"

    # PCI tree (bhyve_config(5) "PCI Device Settings"): unique nodes, bus 0
    # only (lpc: "This device must be configured on bus 0"), known device
    # models, sane leaves. Static slots also REPLACE the pre-p1a runtime
    # clamp "at most 2 pool disks (slots 3-4)" — geometry is fixed in file.
    _nodes=$(grep -E '^pci\.[0-9]+\.[0-9]+\.[0-9]+\.device=' "$_src" | cut -d= -f1 | sed 's/\.device$//')
    [ -n "$_nodes" ] || die "bhyve-vm.conf: no PCI device nodes found"
    _dupes=$(printf '%s\n' $_nodes | sort | uniq -d)
    [ -z "$_dupes" ] || die "bhyve-vm.conf: duplicate PCI node(s): $(echo $_dupes)"
    for _n in $_nodes; do
        echo "$_n" | grep -Eq '^pci\.0\.[0-9]+\.[0-9]+$' \
            || die "bhyve-vm.conf: node $_n: only bus 0 is used in this VM"
        _slot=$(printf '%s' "$_n" | cut -d. -f3)
        [ "$_slot" -le 31 ] || die "bhyve-vm.conf: node $_n: PCI slot must be 0..31"
        _re=$(printf '%s' "$_n" | sed 's/\./\\./g')
        _dev=$(vmc "^${_re}\.device=" "$_src")
        case "$_dev" in
            hostbridge|lpc)
                ;;
            virtio-blk)
                _p=$(vmc "^${_re}\.path=" "$_src")
                [ -n "$_p" ] || die "bhyve-vm.conf: $_n: virtio-blk without path"
                [ -e "$_p" ] || die "bhyve-vm.conf: $_n: path does not exist: $_p"
                ;;
            virtio-net)
                # bhyve_config(5) "Network Backend Settings": "Configuring a
                # backend requires setting the backend variable"; type
                # inferred from the tapN pattern.
                _b=$(vmc "^${_re}\.backend=" "$_src")
                echo "$_b" | grep -Eq '^tap[0-9]+$' \
                    || die "bhyve-vm.conf: $_n: virtio-net backend must be tapN, got '$_b'"
                _m=$(vmc "^${_re}\.mac=" "$_src")
                if [ -n "$_m" ]; then
                    echo "$_m" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' \
                        || die "bhyve-vm.conf: $_n: malformed mac '$_m'"
                fi
                ;;
            virtio-9p)
                _s=$(vmc "^${_re}\.sharename=" "$_src")
                [ -n "$_s" ] || die "bhyve-vm.conf: $_n: virtio-9p without sharename"
                _p=$(vmc "^${_re}\.path=" "$_src")
                [ -n "$_p" ] || die "bhyve-vm.conf: $_n: virtio-9p without path"
                case "$_p" in
                    "$CONFIG_SHARE_DIR")
                        # optional: omitted with a WARN when missing
                        # (gen_vmconf strips pci.0.10.0.*)
                        ;;
                    "$STATUS_SHARE_DIR")
                        # created by the supervisor before every launch —
                        # see install -d in supervise()
                        ;;
                    *)
                        [ -d "$_p" ] || die "bhyve-vm.conf: $_n: 9p path is not a directory: $_p"
                        ;;
                esac
                ;;
            *)
                die "bhyve-vm.conf: $_n: unknown device model '$_dev' (bhyve_config(5) PCI Device Settings)"
                ;;
        esac
    done

    # lpc.com1.path — bhyve_config(5) "LPC Device Settings": "The LPC bridge
    # stores its configuration under a top-level lpc node rather than under
    # the PCI LPC device's node"; "UART Device Settings": path = "Backend
    # device for the serial port. Either the pathname of a character device
    # or 'stdio'." FORMAT check only: nmdm(4) clones the pair on first open,
    # so the device node legitimately does not exist before bhyve opens A.
    _v=$(vmc 'lpc\.com1\.path=' "$_src")
    if [ -n "$_v" ]; then
        case "$_v" in
            stdio|/dev/nmdm-*) ;;
            *) die "bhyve-vm.conf: lpc.com1.path must be /dev/nmdm-* or stdio, got '$_v'" ;;
        esac
    fi
}

# Runtime -k file. Comments/blank lines are preserved on purpose: bhyve(8)
# -k ignores them ("Blank lines and lines starting with '#' are ignored")
# and the runtime copy stays diffable against $VMCONF.
# Strips:
#   - lpc.com1.*    when console=off (com1 not attached at all — as v2);
#   - pci.0.10.0.*  when the 9p config share dir is missing — bhyve would
#     abort (pci_virtio_9p.c opens the share path O_DIRECTORY), so the node
#     is omitted with a WARN instead (wifibox precedent: "No application
#     config found, nothing to mount"). COUPLING: the config share must
#     stay on slot 10 — do not reshuffle slots in bhyve-vm.conf.
gen_vmconf() { # $1 = dest, $2 = console mode, $3 = src (default $VMCONF)
    _dest=$1; _cm=$2; _src=${3:-$VMCONF}
    _pat=""
    [ "$_cm" = off ] && _pat="$_pat -e ^lpc\\.com1\\."
    if [ ! -d "$CONFIG_SHARE_DIR" ]; then
        log "WARN: $CONFIG_SHARE_DIR missing — 9p config share OMITTED from runtime conf (slot 10)"
        _pat="$_pat -e ^pci\\.0\\.10\\.0\\."
    fi
    if [ -n "$_pat" ]; then
        # shellcheck disable=SC2086 # intentional word-split of grep flags
        grep -v $_pat "$_src" >"$_dest"
    else
        cat "$_src" >"$_dest"
    fi
    [ -s "$_dest" ] || die "vmconf: generated runtime conf is empty: $_dest"
}

# ----------------------------------------------------------- vm pid lookup ---
# Live probed 2026-11-05: the process title is "bhyve-uartfix: bcachefsbox
# (bhyve-uartfix)" — NOT wifibox's "bhyve: <name>" (pgrep -fx 'bhyve:
# bcachefsbox' returns nothing here). The [x] bracket keeps the pattern from
# matching its own command line (AGENTS scar: pkill -f self-match killed the
# caller's ssh session).
vm_pid() { pgrep -f "bhyve.*bcachefsbo[x]" | head -n 1; }

# ---------------------------------------------------------- stop protocol ---
# Plan §1 «Стоп»: ACPI-grace (stop_wait_max, default 30 s) → bhyvectl
# --force-poweroff → --destroy.
stop_protocol() {
    # --stop must work even with a broken/absent config: clamp defensively
    # instead of running validate_conf.
    case "$stop_wait_max" in ''|*[!0-9]*) stop_wait_max=30 ;; esac
    _pid=$(vm_pid)
    if [ -n "$_pid" ]; then
        # bhyve.8:1152-1154: ".It SIGTERM / Trigger ACPI poweroff for a VM"
        log "stop: SIGTERM bhyve (pid $_pid) — ACPI poweroff requested"
        doas -n /bin/kill -TERM $_pid 2>/dev/null
        _i=0
        while [ "$_i" -lt "$stop_wait_max" ] && [ -n "$(vm_pid)" ]; do
            sleep 1
            _i=$((_i + 1))
        done
        if [ -n "$(vm_pid)" ]; then
            # bhyvectl.8:67-68: "--force-poweroff  Force the VM to power off."
            log "stop: grace ${stop_wait_max}s expired — bhyvectl --force-poweroff"
            doas -n /usr/sbin/bhyvectl --vm=$VMTAG --force-poweroff 2>/dev/null
        else
            log "stop: guest powered off via ACPI after ${_i}s"
        fi
    else
        log "stop: no running bhyve process"
    fi
    sleep 1
    # bhyvectl.8:59-60: "--destroy  Destroy the specified VM." — v2 scar:
    # on AMD a guest triple-fault can leave a stale vmm object (vm_openf
    # EBUSY); always destroy so the next start cannot collide.
    doas -n /usr/sbin/bhyvectl --vm=$VMTAG --destroy 2>/dev/null || true
}

# --------------------------------------------------------- console logger ---
# mode=log (default): nmdm + file logger. Plan §1:
#   "mode=log: логгер ОБЯЗАН выставить stty -f /dev/nmdm-bcachefsboxB raw
#    -echo ДО cat (ECHO — пер-терминальный флаг, termios.4:1302; nmdm —
#    два независимых tty, nmdm.4)".
# Incident 2026-11-04: with the default termios ECHO set on the B side, the
# tty echoes guest output back into the guest — agetty read its own echo
# (97 getty restarts, ~85 lines/s). Every bhyve (re)start re-creates the nmdm
# pair with DEFAULT termios, hence stty BEFORE EVERY cat — and only cat when
# stty succeeded (a failed stty must not fall through to a default-termios
# cat).  Quotes: termios.4:1302 "ECHO /* enable echoing */", termios.4:1348-
# 1350 "If ECHO is set, input characters are echoed back to the terminal";
# nmdm.4: "The nmdm driver provides two tty devices connected by a virtual
# null modem cable" — two INDEPENDENT ttys, setting B does not touch A.
# v2 heritage: the logger starts BEFORE bhyve — open(B) parks until bhyve's
# open(A) raises the pair + carrier, so the first output byte is caught.
console_logger_start() {
    (
        while :; do
            /bin/stty -f ${NMDM}B raw -echo 2>/dev/null || { sleep 1; continue; }
            /bin/cat ${NMDM}B >> ${CONLOG} 2>/dev/null
            sleep 1
        done
    ) &
    LOGGER=$!
}

# (2026-11-08, phase-0 F2): nmdm pair (re)creation races the logger's stty —
# observed twice with ECHO back ON minutes after boot while cat kept its fd on
# the same minor. The loop above re-runs stty only when cat exits, so a
# recreated pair keeps DEFAULT termios unnoticed. Guard with a periodic
# assert; every correction is logged (one line = one lost race). grep
# pattern: the standalone `echo` token (not -echo/echoe/echok).
echo_assert_loop() {
    (
        while :; do
            sleep 10
            if /bin/stty -f ${NMDM}B -a 2>/dev/null | \
               /usr/bin/grep -qE '(^|[[:space:]])echo([[:space:]]|$)'; then
                if /bin/stty -f ${NMDM}B raw -echo 2>/dev/null; then
                    log "echo-assert: ECHO reappeared on ${NMDM}B — re-applied raw -echo"
                fi
            fi
        done
    ) &
    ECHO_ASSERT=$!
}

# ----------------------------------------------------------- net asserts ---
# v2 heritage, scars 2026-10-21/25: tap1 loses its inet on VM restarts,
# bridge0 must be re-completed on boots (see git history of run-hlab.sh).
# Runs EVERY loop iteration; pre-state logged to $NETASSERT_LOG.
net_asserts() {
    doas -n /sbin/ifconfig tap1 inet 172.31.255.1/30 mtu 9000 up 2>/dev/null || true
    doas -n /sbin/ifconfig tap1 inet6 fe80::1/64 up 2>/dev/null || true
    { date '+%F %T netassert pre-state:'; /sbin/ifconfig bridge0; } >>$NETASSERT_LOG 2>&1
    doas -n /sbin/ifconfig bridge0 create 2>/dev/null || true
    doas -n /sbin/ifconfig bridge0 ether 9c:6b:00:9f:4f:60 2>/dev/null || true
    doas -n /sbin/ifconfig bridge0 192.168.1.3/24 addm re0 2>/dev/null || true
    doas -n /sbin/ifconfig bridge0 addm tap2 2>/dev/null || true
    doas -n /sbin/ifconfig bridge0 up 2>/dev/null || true
    doas -n /sbin/route add -net default 192.168.1.1 2>/dev/null || true
}

# -------------------------------------------------------------------- G8 ---
# G8 (AGENTS, HARD BAN): pool roles are pinned by SERIAL, never by adaN name
# — the 2026-11 re-platform flipped ada0/ada1 while serials stayed. v2
# heritage: refuse to attach when the serial does not match. The scope is
# p1a-derived: every ACTIVE /dev/ virtio-blk path in bhyve-vm.conf (see
# vmconf_pool_members). Map (live probed 2026-11-05 with camcontrol):
#   ada1 = TOSHIBA SERIAL-HDD-REPLACE-ME  (whole disk, bcachefs pool member)
#   nda0 = KINGSTON SERIAL-NVME-P3-REPLACE-ME (NVMe; p3 = bcachefs member passed to VM)
g8_expected_serial() {
    case "$1" in
        ada1) echo SERIAL-HDD-REPLACE-ME ;;
        nda0) echo SERIAL-NVME-P3-REPLACE-ME ;;
        *)    echo '' ;;
    esac
}

g8_assert_disk() { # $1 = /dev/... (whole disk or slice)
    _base=$(basename "$1" | sed 's/p[0-9]*$//')
    _want=$(g8_expected_serial "$_base")
    [ -n "$_want" ] || return 0        # scratch disks (phase A) are not G8-pinned
    _got=$(doas -n /sbin/camcontrol identify "/dev/$_base" 2>/dev/null \
            | grep -i '^serial number' | awk '{print $3}')
    if [ "$_got" != "$_want" ]; then
        die "G8 ABORT: /dev/$_base serial '$_got' != '$_want' — refusing to attach pool disk"
    fi
    log "G8: /dev/$_base serial $_got OK"
}

# --------------------------------------------------------- resctrl assert ---
# Plan §1: "Boot-time assert: маркер resctrl-патча vmm в dmesg ДО аттача
# пула (без CPUID-фикса bug 300480 Linux 6.12+ бут-лупится в resctrl init)".
# Checking the guest dmesg via ssh in the first boot seconds is impossible,
# and no sysctl marker exists — so the DEPLOY installs a host-side file
# marker instead.
# TODO(main, phase-3 deploy): after verifying the patched vmm is running:
#   doas touch /usr/local/libexec/vmm-resctrl-patched.marker
resctrl_assert() {
    if [ ! -f "$RESCTRL_MARKER" ]; then
        log "WARN: $RESCTRL_MARKER absent — vmm resctrl patch NOT verified (bug 300480 boot-loop risk); waiting ${RESCTRL_DELAY}s and continuing"
        sleep "$RESCTRL_DELAY"
    fi
}

# --------------------------------------------------------------- lint mode ---
lint() {
    log "lint: validating configs + environment; touching nothing"
    load_conf
    validate_conf
    log "lint: PASS lifecycle conf ($CONF): nice_priority=$nice_priority stop_wait_max=$stop_wait_max console=$console"
    if [ -f "$VMCONF" ]; then
        _vmcs=$VMCONF
    else
        _vmcs=$VMSAMPLE
        log "lint: $VMCONF absent — first supervise run would seed it from $_vmcs"
    fi
    validate_vmconf "$_vmcs"
    log "lint: PASS vm conf ($_vmcs): name/cpus/memory.size/bootrom + PCI nodes/paths OK"
    _pool=$(vmconf_pool_members "$_vmcs")
    log "lint: pool members (G8+resctrl asserted at every attach): ${_pool:-<none — phase A: boot WITHOUT pool disks>}"
    for b in "$BHYVE" /usr/local/libexec/oomprotect /usr/sbin/bhyvectl \
              /usr/bin/nice /bin/stty /bin/cat /sbin/camcontrol; do
        [ -x "$b" ] || die "lint: executable missing: $b"
    done
    log "lint: binaries OK (bhyve-uartfix -k capable, oomprotect, bhyvectl, nice, stty, cat, camcontrol)"
    kldstat -m nmdm >/dev/null 2>&1 \
        && log "lint: nmdm module loaded" \
        || log "lint: nmdm module NOT loaded (supervisor will kldload -n nmdm)"
    if [ -d "$CONFIG_SHARE_DIR" ]; then
        log "lint: 9p config share $CONFIG_SHARE_DIR present → pci.0.10.0 attached ro"
    else
        log "lint: 9p config share $CONFIG_SHARE_DIR MISSING → pci.0.10.0 omitted with WARN (deploy installs it)"
    fi
    log "lint: 9p status share $STATUS_SHARE_DIR → created at launch (root:wheel 755), pci.0.11.0 rw"
    if [ -f "$RESCTRL_MARKER" ]; then
        log "lint: resctrl marker present"
    else
        log "lint: resctrl marker ABSENT → WARN + ${RESCTRL_DELAY}s delay at every pool-attach boot (TODO deploy: touch $RESCTRL_MARKER)"
    fi
    _tmp=$(mktemp) || die "lint: mktemp failed"
    gen_vmconf "$_tmp" log "$_vmcs"
    log "lint: runtime -k file for console=log (what supervise would write to $RUNTIME_VMCONF):"
    cat "$_tmp"
    rm -f "$_tmp"
    log "lint: OK"
}

# -------------------------------------------------------- print-config mode ---
print_config() {
    if [ -f "$VMCONF" ]; then
        _vmcs=$VMCONF
    else
        _vmcs=$VMSAMPLE
        log "print-config: $VMCONF absent — showing the sample $_vmcs"
    fi
    for _cm in off log; do
        _tmp=$(mktemp) || die "print-config: mktemp failed"
        gen_vmconf "$_tmp" "$_cm" "$_vmcs"
        echo "===== console=$_cm → bhyve -k file ($RUNTIME_VMCONF) ====="
        cat "$_tmp"
        echo "===== end console=$_cm ====="
        rm -f "$_tmp"
    done
}

# --------------------------------------------------------------- supervise ---
on_term() {
    # Graceful manual stop. NOTE: a POSIX sh runs a trapped signal only after
    # the current foreground command completes — during a backoff `sleep`
    # that is up to 120 s. rc.d therefore uses kill -9 + --stop and does NOT
    # rely on this trap.
    log "supervisor: SIGTERM/INT — graceful stop"
    stop_protocol
    [ -n "$LOGGER" ] && kill "$LOGGER" 2>/dev/null
    [ -n "$ECHO_ASSERT" ] && kill "$ECHO_ASSERT" 2>/dev/null
    exit 0
}

supervise() {
    load_conf
    validate_conf
    log "lifecycle: nice=$nice_priority stop_wait_max=$stop_wait_max console=$console"
    ensure_vmconf
    validate_vmconf "$VMCONF"
    log "vm conf: $VMCONF (declarative, bhyve_config(5)); runtime -k: $RUNTIME_VMCONF"

    # nmdm driver (v2 heritage): the pair is cloned on first open; the
    # module must be loaded before the logger parks on open(B). Without it
    # there is no console at all.
    kldload -n nmdm 2>/dev/null || true
    kldstat -m nmdm >/dev/null 2>&1 || die "nmdm module not loaded — no console"

    case "$console" in
        log)
            console_logger_start
            echo_assert_loop
            ;;
        cu)
            # cu.1:98-99: "~^D or ~.  Drop the connection and exit."
            log "console=cu: interactive only — doas cu -l ${NMDM}B   (exit: ~.)"
            log "console=cu: no console logger; $CONLOG stays idle"
            ;;
        off)
            log "console=off: com1 is NOT attached — no nmdm, no logger, no cu"
            ;;
    esac
    trap on_term INT TERM

    # rw status share target (plan §2): the guest heartbeat TSV lands here
    # over 9p. pci_virtio_9p.c:264 opens the share path O_DIRECTORY — a
    # missing dir aborts the whole bhyve start, so (re)create before every
    # launch; idempotent. Also the runtime -k file itself lives in this dir.
    doas -n /usr/bin/install -d -o root -g wheel -m 755 "$STATUS_SHARE_DIR"

    tries=0
    while :; do
        net_asserts

        # Pool attach gates — same semantics as pre-p1a, but the scope is
        # derived from the declarative conf: pool members = ACTIVE /dev/
        # virtio-blk paths (phase A = those nodes commented out in the conf).
        # Static slots in the file also enforce the old "at most 2 disks
        # (slots 3-4)" clamp structurally.
        _pool=$(vmconf_pool_members "$VMCONF")
        if [ -n "$_pool" ]; then
            # Boot-time assert BEFORE attaching pool disks (plan §1).
            resctrl_assert
            for d in $_pool; do
                g8_assert_disk "$d"
            done
        else
            log "no /dev pool members in $VMCONF — phase-A boot WITHOUT pool disks (plan §4.3)"
        fi

        # Per-launch runtime conf (see the gen_vmconf block comment).
        gen_vmconf "$RUNTIME_VMCONF" "$console" "$VMCONF"

        # v2 scar: on AMD a guest triple-fault may keep a stale vmm object
        # (vm_openf EBUSY) — destroy before every start.
        doas -n /usr/sbin/bhyvectl --vm=$VMTAG --destroy 2>/dev/null || true

        # Launch (p1a): native declarative -k instead of hand-built
        # -c/-m/-w/-H/-s/-l. The positional vmname is REQUIRED by the bhyve(8)
        # SYNOPSIS ("bhyve [opts] [-k config_file] [opts] vmname") and it
        # OVERRIDES the conf's name= — we pass it explicitly AND validate
        # name=$VMTAG inside the conf, so both sources always agree
        # (idempotency: whoever edits the conf cannot silently rename the
        # vmm(4) instance). Deliberately NOT exec(1): the supervise loop
        # needs the child's exit status (exit 0 = guest rebooted → restart
        # in 2 s; anything else → backoff; bhyve.8 EXIT STATUS) — exec would
        # replace the supervisor and kill the loop semantics.
        # -H/-w live in bhyve-vm.conf now: x86.vmexit_on_hlt=true ("Force a
        # VM exit when a guest CPU executes the HLT instruction ... yield
        # the host CPU", bhyve_config(5)) and x86.strictmsr=false ("If this
        # is false, writes are ignored and reads return zero" = bhyve(8) -w
        # "Ignore accesses to unimplemented MSRs").
        t0=$(date +%s)
        /usr/bin/nice -n "$nice_priority" \
            "$BHYVE" -k "$RUNTIME_VMCONF" \
            "$VMTAG"
        rc=$?

        if [ "$rc" -eq 0 ]; then
            log "bhyve exit=0 (guest rebooted) — restarting in 2s"
            tries=0
            sleep 2
        else
            # v2 scar 2026-11-03: treating exit!=0 as loop-STOP left the VM
            # dead for ~2 h after the kernel killed bhyve. Restart with
            # linear backoff; a fresh 300 s-lived instance resets the count.
            [ $(( $(date +%s) - t0 )) -ge 300 ] && tries=0
            tries=$((tries + 1))
            backoff=$((5 * tries)); [ "$backoff" -gt 120 ] && backoff=120
            log "bhyve exit=$rc — restarting in ${backoff}s (attempt $tries)"
            sleep "$backoff"
        fi

        # v2 heritage: re-assert the NFS bridge after every VM (re)start;
        # poolmount remount is idempotent.
        ( sh /usr/local/etc/rc.d/poolmount remount >>/var/log/poolmount.log 2>&1 ) &
    done
}

# ------------------------------------------------------------------- main ---
MODE=run
case "${1-}" in
    --lint) MODE=lint ;;
    --stop) MODE=stop ;;
    --print-config) MODE=print_config ;;
    -h|--help) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 64 ;;
esac

# OOM shield (v2 scar 2026-11-03): the kernel pageout killer (vm_pageout_oom)
# skips P_PROTECTED processes when picking a victim. Re-exec self under
# oomprotect: p_flags survive exec, children inherit via P2_INHERIT.
# Only the supervise loop needs it (--lint/--stop/--print-config exit immediately).
if [ "$MODE" = run ] && [ -x /usr/local/libexec/oomprotect ] && [ -z "$BCACHEFSBOX_SHIELDED" ]; then
    export BCACHEFSBOX_SHIELDED=1
    exec /usr/local/libexec/oomprotect /bin/sh "$0" "$@"
fi

case "$MODE" in
    lint) lint ;;
    print_config) print_config ;;
    stop) load_conf; stop_protocol ;;
    run)  supervise ;;
esac
