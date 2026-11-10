#!/bin/sh
# run-bcachefsbox.sh — bcachefs-box VM supervising orchestrator (POSIX sh).
#
# Repo source of truth : host/run-bcachefsbox.sh (this file)
# Deployed copy        : /vm/bcachefs-box/run-bcachefsbox.sh (see host/README.md)
# VM description       : declarative bhyve_config(5) variables, loaded with
#   "bhyve -k <file>" (bhyve(8) -k: "Set configuration variables from a
#   simple, key-value config file"). Manual assembly of -c/-m/-w/-H/-s/-l is
#   retired; the guest lives in bhyve-vm.conf (repo:
#   host/bhyve-vm.conf.example, seeded to /vm/bcachefs-box/bhyve-vm.conf on
#   first run). This script owns only the LIFECYCLE. Config layering:
#   host/README.md and host/examples/bhyve.conf.sample.
#
# Modes:
#   (no args)       supervise loop — rc.d daemon mode (stdout → /var/log/bcachefsbox-run.log)
#   --stop          stop protocol: SIGTERM bhyve → ACPI grace → --force-poweroff → --destroy
#   --lint          validate BOTH configs + environment, change NOTHING, exit 0
#   --print-config  print the runtime -k file for console=off AND console=log;
#                   change nothing
#
# Loop semantics (v2 heritage):
#   bhyve exit 0   = guest rebooted (bhyve(8) EXIT STATUS: 0 rebooted)
#                    → restart in 2 s;
#   any other exit = 1 powered off / 2 halted / 3 triple fault / 4 error / 5 suspended
#                    → linear backoff 5*tries s, max 120 s.
#   tries reset after an instance that lived ≥ 300 s. The ONLY manual stop is
#   `service bcachefsbox stop` — rc.d kills this supervisor first, then --stop.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

: "${VMTAG:=bcachefsbox}"
: "${CONF:=/vm/bcachefs-box/bhyve.conf}"
# bhyve — ONLY by absolute path. The reference deployment ran a patched
# bhyve (uart console-EOF fix, an upstream FreeBSD PR effort) installed as
# /usr/local/libexec/bhyve-uartfix: a PATH lookup could silently pick the
# stock binary and reintroduce the mevent spin on hosts where it bites
# (see host/README.md, "Undeclared dependencies" — the symptom, and why
# stock bhyve is fine on hosts it does not affect: override
# BHYVE=/usr/sbin/bhyve in the lifecycle conf there). The patched binary is
# -k-capable (its usage line is "[-k config_file]").
: "${BHYVE:=/usr/local/libexec/bhyve-uartfix}"
: "${NMDM:=/dev/nmdm-bcachefsbox}"
: "${CONLOG:=/var/log/bcachefsbox-console.log}"
NETASSERT_LOG=/var/log/netassert.log
: "${CONFIG_SHARE_DIR:=/vm/bcachefs-box/config}"
: "${STATUS_SHARE_DIR:=/var/run/bcachefsbox}"
# --- declarative VM description (bhyve_config(5)) fed to bhyve -k -----------
# Layering (host/README.md): the VM itself is described by bhyve-vm.conf;
# lifecycle knobs (nice, stop grace, console mode) stay in the shell $CONF.
# shellcheck disable=SC1007  # CDPATH= prefix: canonical suppression idiom
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VMSAMPLE=$SCRIPT_DIR/bhyve-vm.conf.example  # repo/deploy seed (first run copies it)
: "${VMCONF:=/vm/bcachefs-box/bhyve-vm.conf}"      # deployed declarative VM description
RUNTIME_VMCONF=$STATUS_SHARE_DIR/vm.conf   # per-launch -k file (inside the rw 9p
                                           # status share — no secrets there, the
                                           # guest may read its own geometry)
# resctrl boot-assert marker (see resctrl_assert below; host/README.md)
: "${RESCTRL_MARKER:=/usr/local/libexec/vmm-resctrl-patched.marker}"
RESCTRL_DELAY=10

LOGGER=""
ECHO_ASSERT=""

# ---------------------------------------------------------------- logging ---
# Principle: alerts do NOT go through syslogd — it froze once during an
# incident while everything else kept dying silently. All logging goes to
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
# Layering (host/README.md): bhyve.conf = LIFECYCLE of the ORCHESTRATOR
# (nice, stop grace, console routing, net asserts, serial pins). The GUEST
# is described declaratively in bhyve-vm.conf (bhyve_config(5)); cpus/memory
# /pool disks moved there — leftovers in an old bhyve.conf are sourced but
# IGNORED. wifibox load_bhyve_conf_values pattern (sbin/wifibox:244-265):
# internal defaults first, then ". $CONF", then assert-style validation.
nice_priority=15
stop_wait_max=60
console=log

# --- net asserts: EMPTY defaults (see net_asserts below) --------------------
# With nothing set here (or in $CONF) net_asserts() touches NOTHING. Setting
# values makes the supervisor reconfigure HOST networking on every loop
# iteration — net_asserts_notice() prints the prominent warning.
BENCH_TAP=""
BENCH_INET=""
BENCH_INET6=""
BENCH_MTU=""
LAN_BRIDGE=""
LAN_MEMBERS=""
LAN_UPLINK=""
LAN_INET=""
LAN_GATEWAY=""
LAN_MAC=""

# --- serial-pin guard pins: EMPTY default — fail closed (see G8 below) ------
G8_SERIALS=""

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
    # serial pins: space-separated device=serial pairs (fail-closed guard).
    for _pair in $G8_SERIALS; do # shellcheck disable=SC2086 # intentional split of pair list
        case "$_pair" in
            *=*) [ -n "${_pair#*=}" ] || die "$CONF: G8_SERIALS: empty serial in '$_pair'" ;;
            *)   die "$CONF: G8_SERIALS: malformed entry '$_pair', expected device=serial pairs" ;;
        esac
    done
}

# ------------------------------------------ declarative VM conf (bhyve -k) ---
# bhyve(8) -k: "Set configuration variables from a simple, key-value config
# file. Each line ... name, an equals sign ('='), and a value. No spaces are
# permitted ... Blank lines and lines starting with '#' are ignored."
# Variables per bhyve_config(5). The supervisor:
#   1. seeds $VMCONF from the adjacent example on the first run;
#   2. validates it (name/cpus/memory.size/bootrom/PCI tree/paths);
#   3. per launch generates $RUNTIME_VMCONF (console=off strips lpc.com1.*;
#      a missing 9p config share strips pci.0.10.0.*, wifibox WARN
#      precedent — bhyve would abort on open(O_DIRECTORY) otherwise);
#   4. starts: nice -n $nice_priority $BHYVE -k $RUNTIME_VMCONF $VMTAG.
ensure_vmconf() {
    if [ ! -f "$VMCONF" ]; then
        [ -f "$VMSAMPLE" ] || die "no $VMCONF and no example $VMSAMPLE to seed from"
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

vmconf_pool_members() { # $1 = src — active /dev/ virtio-blk paths
    # (G8 scope = the production pool disks; see the serial-pin guard below)
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
    # models, sane leaves. Static slots also make the old "at most 2 pool
    # disks (slots 3-4)" clamp structural — geometry is fixed in the file.
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
# The pgrep pattern must match both bhyve process-title shapes: stock bhyve
# titles "bhyve: <vmname>", the patched binary titles
# "bhyve-uartfix: <vmname> (bhyve-uartfix)" (argv[0] differs). The [x]
# bracket keeps the pattern from matching its own command line (scar: a
# pkill -f self-match once killed the caller's ssh session).
vm_pid() { pgrep -f "bhyve.*bcachefsbo[x]" | head -n 1; }

# ---------------------------------------------------------- stop protocol ---
# Stop protocol: SIGTERM bhyve (ACPI poweroff request) → grace
# (stop_wait_max) → bhyvectl --force-poweroff → --destroy.
stop_protocol() {
    # --stop must work even with a broken/absent config: clamp defensively
    # instead of running validate_conf.
    case "$stop_wait_max" in ''|*[!0-9]*) stop_wait_max=30 ;; esac
    _pid=$(vm_pid)
    if [ -n "$_pid" ]; then
        # bhyve(8) SIGNALS: "SIGTERM / Trigger ACPI poweroff for a VM"
        log "stop: SIGTERM bhyve (pid $_pid) — ACPI poweroff requested"
        doas -n /bin/kill -TERM $_pid 2>/dev/null
        _i=0
        while [ "$_i" -lt "$stop_wait_max" ] && [ -n "$(vm_pid)" ]; do
            sleep 1
            _i=$((_i + 1))
        done
        if [ -n "$(vm_pid)" ]; then
            # bhyvectl(8): "--force-poweroff  Force the VM to power off."
            log "stop: grace ${stop_wait_max}s expired — bhyvectl --force-poweroff"
            doas -n /usr/sbin/bhyvectl --vm=$VMTAG --force-poweroff 2>/dev/null
        else
            log "stop: guest powered off via ACPI after ${_i}s"
        fi
    else
        log "stop: no running bhyve process"
    fi
    sleep 1
    # bhyvectl(8): "--destroy  Destroy the specified VM." — v2 scar:
    # on AMD a guest triple-fault can leave a stale vmm object (vm_openf
    # EBUSY); always destroy so the next start cannot collide.
    doas -n /usr/sbin/bhyvectl --vm=$VMTAG --destroy 2>/dev/null || true
}

# --------------------------------------------------------- console logger ---
# mode=log (default): nmdm + file logger. Rule: the logger MUST set
#   stty -f ${NMDM}B raw -echo
# BEFORE every cat (ECHO is a per-terminal flag, termios(4); nmdm(4) is two
# independent ttys — setting B never touches A).
# Incident 2026-11-04: with the default termios ECHO left on the B side, the
# tty echoed guest output back INTO the guest — agetty read its own echo
# (97 getty restarts, ~85 lines/s). Every bhyve (re)start re-creates the nmdm
# pair with DEFAULT termios, hence stty BEFORE EVERY cat — and only cat when
# stty succeeded (a failed stty must not fall through to a default-termios
# cat). Quotes: termios(4) "ECHO /* enable echoing */"; "If ECHO is set,
# input characters are echoed back to the terminal"; nmdm(4): "The nmdm
# driver provides two tty devices connected by a virtual null modem cable".
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

# (scar, 2026-11-08): nmdm pair (re)creation races the logger's stty —
# observed twice with ECHO back ON minutes after boot while cat kept its fd
# on the same minor. The loop above re-runs stty only when cat exits, so a
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
# v2 heritage, scars 2026-10-21/25: taps lose their inet on VM restarts and a
# bridge must be re-completed after boots — so these asserts re-run on EVERY
# loop iteration, failures swallowed (`|| true`) on purpose: the supervise
# loop must not die on a transient ifconfig error.
#
# RELEASE NOTE (sanitization): the pre-release private script burned the
# author's LAN into this block — bridge MAC, LAN address/prefix, uplink NIC,
# default gateway — and re-applied it on every iteration. On any other host
# that silently rewrote the bridge MAC and injected a bogus default route.
# This shipped version has NO defaults: every value is an overridable
# variable that defaults to EMPTY, and an empty variable SKIPS its assert.
# With the shipped defaults net_asserts() touches NOTHING.
#
# WARNING: setting these variables makes the supervisor actively RECONFIGURE
# HOST NETWORKING on every iteration (addresses, bridge membership/MAC,
# default route). net_asserts_notice() prints the prominent warning once per
# run (startup and --lint). Configure LAN pieces once in rc.conf(5) instead
# of here where you can; keep these asserts for state that genuinely needs
# re-asserting after VM restarts. Keys documented in
# host/examples/bhyve.conf.sample.
net_asserts() {
    # bench tap — host end of the VM /30 (guest side is static in the image).
    if [ -n "$BENCH_TAP" ]; then
        [ -n "$BENCH_MTU" ] && \
            doas -n /sbin/ifconfig "$BENCH_TAP" mtu "$BENCH_MTU" 2>/dev/null || true
        [ -n "$BENCH_INET" ] && \
            doas -n /sbin/ifconfig "$BENCH_TAP" inet "$BENCH_INET" up 2>/dev/null || true
        [ -n "$BENCH_INET6" ] && \
            doas -n /sbin/ifconfig "$BENCH_TAP" inet6 "$BENCH_INET6" up 2>/dev/null || true
    fi
    # LAN bridge — EMPTY defaults; any values are the operator's own.
    if [ -n "$LAN_BRIDGE" ]; then
        kldload -n if_bridge 2>/dev/null || true
        { date '+%F %T netassert pre-state:'; /sbin/ifconfig "$LAN_BRIDGE"; } >>"$NETASSERT_LOG" 2>&1
        doas -n /sbin/ifconfig "$LAN_BRIDGE" create 2>/dev/null || true
        [ -n "$LAN_MAC" ] && \
            doas -n /sbin/ifconfig "$LAN_BRIDGE" ether "$LAN_MAC" 2>/dev/null || true
        [ -n "$LAN_INET" ] && \
            doas -n /sbin/ifconfig "$LAN_BRIDGE" inet "$LAN_INET" 2>/dev/null || true
        [ -n "$LAN_UPLINK" ] && \
            doas -n /sbin/ifconfig "$LAN_BRIDGE" addm "$LAN_UPLINK" 2>/dev/null || true
        for _m in $LAN_MEMBERS; do # shellcheck disable=SC2086 # intentional split of member list
            doas -n /sbin/ifconfig "$LAN_BRIDGE" addm "$_m" 2>/dev/null || true
        done
        doas -n /sbin/ifconfig "$LAN_BRIDGE" up 2>/dev/null || true
        [ -n "$LAN_GATEWAY" ] && \
            doas -n /sbin/route add -net default "$LAN_GATEWAY" 2>/dev/null || true
    fi
}

# Prominent one-shot notice: net asserts reconfigure HOST networking when
# enabled; printed at supervise start and by --lint (NOT per iteration — the
# asserts run every loop, the warning must not spam the log).
net_asserts_notice() {
    if [ -z "$BENCH_TAP" ] && [ -z "$LAN_BRIDGE" ]; then
        log "net asserts: DISABLED (BENCH_TAP / LAN_BRIDGE unset) — host networking untouched"
        return 0
    fi
    log "########################################################################"
    log "# WARNING: net asserts are ENABLED — on EVERY supervise-loop iteration"
    log "# this host's networking is RECONFIGURED with ifconfig(8)/route(8):"
    log "#   BENCH_TAP=${BENCH_TAP:-<unset>}  BENCH_INET=${BENCH_INET:-<unset>}  BENCH_MTU=${BENCH_MTU:-<unset>}"
    log "#   LAN_BRIDGE=${LAN_BRIDGE:-<unset>}  LAN_INET=${LAN_INET:-<unset>}  LAN_UPLINK=${LAN_UPLINK:-<unset>}  LAN_GATEWAY=${LAN_GATEWAY:-<unset>}"
    log "# Every assert swallows failures ('|| true') — a wrong value silently"
    log "# mangles this host's networking. Prefer one-time rc.conf(5) setup for"
    log "# the LAN pieces; see host/README.md ('Network setup')."
    log "########################################################################"
}

# -------------------------------------------------------------------- G8 ---
# G8 = the production pool disks (internal codename from the private
# deployment; kept as the guard's name). HARD RULE: pool roles are pinned by
# SERIAL, never by adaN/ndaN name — a re-platform once flipped ada0/ada1
# while the serials stayed, which is the whole reason the guard exists.
# v2 heritage: refuse to attach when the serial does not match.
#
# The pin map lives in the lifecycle conf ($CONF) as G8_SERIALS:
# space-separated device=serial pairs; device = basename WITHOUT partition
# suffix (nda0p3 -> nda0). FAIL CLOSED: every ACTIVE /dev/ virtio-blk path
# in bhyve-vm.conf must have a pin — an unknown or unpinned device ABORTS
# the start instead of silently bypassing the guard (the shipped default map
# is EMPTY on purpose; see host/examples/bhyve.conf.sample):
#   G8_SERIALS='nda0=SERIAL-OF-NVME-MEMBER ada1=SERIAL-OF-HDD-MEMBER'

g8_expected_serial() { # $1 = device base name -> stdout: pinned serial ('' = unpinned)
    for _pair in $G8_SERIALS; do # shellcheck disable=SC2086 # intentional split of pair list
        case "$_pair" in
            "$1="*) printf '%s\n' "${_pair#*=}"; return 0 ;;
        esac
    done
    return 0 # caller MUST treat empty output as fatal (fail closed)
}

g8_assert_disk() { # $1 = /dev/... (whole disk or slice)
    _base=$(basename "$1" | sed 's/p[0-9]*$//')
    _want=$(g8_expected_serial "$_base")
    if [ -z "$_want" ]; then
        die "G8 ABORT: /dev/$_base has NO serial pin (map: ${G8_SERIALS:-<empty>}) — add 'device=serial' to G8_SERIALS in $CONF; refusing to attach an unpinned pool disk (fail closed)"
    fi
    _got=$(doas -n /sbin/camcontrol identify "/dev/$_base" 2>/dev/null \
            | grep -i '^serial number' | awk '{print $3}')
    if [ "$_got" != "$_want" ]; then
        die "G8 ABORT: /dev/$_base serial '$_got' != '$_want' — refusing to attach pool disk"
    fi
    log "G8: /dev/$_base serial $_got OK"
}

# --------------------------------------------------------- resctrl assert ---
# Boot-time assert BEFORE attaching pool disks: the marker file proves the
# running vmm(4) carries the upstream fix for FreeBSD bug 300480 (AMD QoS
# CPUID leaf leaks to guests; Linux 6.12+ guests divide-by-zero in resctrl
# init and boot-loop PID 1). Checking guest dmesg via ssh in the first boot
# seconds is impossible and no sysctl marker exists — so the DEPLOY installs
# a host-side file marker instead (see host/README.md, "resctrl marker").
# After verifying the host vmm handles such guests:
#   doas touch /usr/local/libexec/vmm-resctrl-patched.marker
resctrl_assert() {
    if [ ! -f "$RESCTRL_MARKER" ]; then
        log "WARN: $RESCTRL_MARKER absent — vmm resctrl patch NOT verified (bug 300480 boot-loop risk); waiting ${RESCTRL_DELAY}s and continuing"
        sleep "$RESCTRL_DELAY"
    fi
}

# ----------------------------------------------------------------- lint ---
lint() {
    log "lint: validating configs + environment; touching nothing"
    load_conf
    validate_conf
    log "lint: PASS lifecycle conf ($CONF): nice_priority=$nice_priority stop_wait_max=$stop_wait_max console=$console"
    net_asserts_notice
    if [ -f "$VMCONF" ]; then
        _vmcs=$VMCONF
    else
        _vmcs=$VMSAMPLE
        log "lint: $VMCONF absent — first supervise run would seed it from $_vmcs"
    fi
    validate_vmconf "$_vmcs"
    log "lint: PASS vm conf ($_vmcs): name/cpus/memory.size/bootrom + PCI nodes/paths OK"
    _pool=$(vmconf_pool_members "$_vmcs")
    log "lint: pool members (serial pins + resctrl asserted at every attach): ${_pool:-<none — poolless boot: pool nodes commented out>}"
    for d in $_pool; do # shellcheck disable=SC2086 # intentional split of member list
        _base=$(basename "$d" | sed 's/p[0-9]*$//')
        [ -n "$(g8_expected_serial "$_base")" ] \
            || die "lint: pool member $d (/dev/$_base) has NO serial pin — set G8_SERIALS in $CONF (fail-closed guard)"
    done
    if [ -n "$_pool" ]; then
        log "lint: serial pins present for all pool members"
    fi
    for b in "$BHYVE" /usr/sbin/bhyvectl /usr/bin/nice /bin/stty /bin/cat /sbin/camcontrol; do
        [ -x "$b" ] || die "lint: executable missing: $b"
    done
    log "lint: binaries OK ($BHYVE, bhyvectl, nice, stty, cat, camcontrol)"
    if [ -x /usr/local/libexec/oomprotect ]; then
        log "lint: oomprotect present — OOM shield will be active"
    else
        log "lint: oomprotect ABSENT — OOM shield disabled (optional helper; see host/README.md)"
    fi
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
        log "lint: resctrl marker ABSENT → WARN + ${RESCTRL_DELAY}s delay at every pool-attach boot (after verifying the host vmm, touch $RESCTRL_MARKER)"
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
        log "print-config: $VMCONF absent — showing the example $_vmcs"
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
    net_asserts_notice
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
            # cu(1): "~^D or ~.  Drop the connection and exit."
            log "console=cu: interactive only — doas cu -l ${NMDM}B   (exit: ~.)"
            log "console=cu: no console logger; $CONLOG stays idle"
            ;;
        off)
            log "console=off: com1 is NOT attached — no nmdm, no logger, no cu"
            ;;
    esac
    trap on_term INT TERM

    # rw status share target: the runtime -k file lives here (and any guest
    # status files the operator adds). pci_virtio_9p.c opens the share path
    # O_DIRECTORY — a missing dir aborts the whole bhyve start, so
    # (re)create before every launch; idempotent.
    doas -n /usr/bin/install -d -o root -g wheel -m 755 "$STATUS_SHARE_DIR"

    tries=0
    while :; do
        net_asserts

        # Pool attach gates: pool members = ACTIVE /dev/ virtio-blk paths in
        # the declarative conf (poolless boot = those nodes commented out).
        _pool=$(vmconf_pool_members "$VMCONF")
        if [ -n "$_pool" ]; then
            # Boot-time assert BEFORE attaching pool disks.
            resctrl_assert
            for d in $_pool; do
                g8_assert_disk "$d"
            done
        else
            log "no /dev pool members in $VMCONF — poolless boot (pool nodes commented out)"
        fi

        # Per-launch runtime conf (see the gen_vmconf block comment).
        gen_vmconf "$RUNTIME_VMCONF" "$console" "$VMCONF"

        # v2 scar: on AMD a guest triple-fault may keep a stale vmm object
        # (vm_openf EBUSY) — destroy before every start.
        doas -n /usr/sbin/bhyvectl --vm=$VMTAG --destroy 2>/dev/null || true

        # Launch: native declarative -k instead of hand-built -c/-m/-w/-H/-s/-l.
        # The positional vmname is REQUIRED by the bhyve(8) SYNOPSIS
        # ("bhyve [opts] [-k config_file] [opts] vmname") and it OVERRIDES the
        # conf's name= — we pass it explicitly AND validate name=$VMTAG inside
        # the conf, so both sources always agree (idempotency: whoever edits
        # the conf cannot silently rename the vmm(4) instance). Deliberately
        # NOT exec(1): the supervise loop needs the child's exit status
        # (exit 0 = guest rebooted → restart in 2 s; anything else → backoff;
        # bhyve(8) EXIT STATUS). -H/-w live in bhyve-vm.conf now:
        # x86.vmexit_on_hlt=true ("Force a VM exit when a guest CPU executes
        # the HLT instruction ... yield the host CPU", bhyve_config(5)) and
        # x86.strictmsr=false ("If this is false, writes are ignored and
        # reads return zero" = bhyve(8) -w "Ignore accesses to unimplemented
        # MSRs").
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

        # Optional local glue (host/README.md, "poolmount"): persistent NFS
        # mount, ensure/remount semantics; idempotent. Skipped when the
        # script is not deployed.
        if [ -f /usr/local/etc/rc.d/poolmount ]; then
            ( sh /usr/local/etc/rc.d/poolmount remount >>/var/log/poolmount.log 2>&1 ) &
        fi
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
# Only the supervise loop needs it (--lint/--stop/--print-config exit
# immediately). Optional helper — see host/README.md.
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
