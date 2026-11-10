# host/ — FreeBSD host side

The host owns the VM lifecycle; the guest (`../image/`) is a sealed
appliance whose only job is to mount the bcachefs pool and export it over
NFSv4. Nothing here runs the filesystem itself — bcachefs executes inside
the guest; the host hands it the pool disks over PCI passthrough and
consumes the pool over NFS.

## Files

| File | Role | Deploy to |
|---|---|---|
| `run-bcachefsbox.sh` | supervisor: restart loop, stop protocol, serial-pin guard, declarative `bhyve -k` launch | `/vm/bcachefs-box/run-bcachefsbox.sh` |
| `bhyve-vm.conf.example` | the guest as `bhyve_config(5)` variables | `/vm/bcachefs-box/bhyve-vm.conf` — seeded automatically from the adjacent example on first run |
| `rc.d/bcachefsbox` | rc.d wrapper (`service bcachefsbox onestart/onestop`) | `/usr/local/etc/rc.d/bcachefsbox` |
| `examples/bhyve.conf.sample` | lifecycle conf: nice/stop grace/console + net asserts + serial pins | `/vm/bcachefs-box/bhyve.conf` |
| `examples/doas.conf.sample` | privilege rules | merge into `/etc/doas.conf` |
| `pool-stack-up.sh` | cold-start ceremony: dual-writer gate → VM → NFS mount | run from the repo |

## Config layering

Two files, two jobs:

1. **`/vm/bcachefs-box/bhyve.conf`** (shell, sourced by the supervisor) —
   LIFECYCLE of the supervisor: `nice_priority`, `stop_wait_max`, `console`,
   plus the optional net-assert and serial-pin settings. Defaults live in
   the script; `examples/bhyve.conf.sample` documents every key.
2. **`/vm/bcachefs-box/bhyve-vm.conf`** (`bhyve_config(5)` format, fed to
   `bhyve -k`) — the GUEST: cpus, memory, bootrom, PCI tree, console path.
   The supervisor validates it, then generates a per-launch runtime copy in
   `/var/run/bcachefsbox/vm.conf` (console=off strips `lpc.com1.*`; a
   missing config-share dir strips the 9p config node with a WARN).

## Prerequisites

- **FreeBSD** amd64. Developed and proven on 15.1-RELEASE. The `bhyve -k` /
  `bhyve_config(5)` config-file support the supervisor is built on needs
  FreeBSD ≥ 13.1; the `virtio-net mtu=` variable came with the same config
  rewrite (if unsure, check your installed `bhyve_config(5)`).
- **Packages**: `sysutils/edk2-bhyve` (UEFI boot ROM; point `bootrom=` at
  the file your installed version ships, e.g.
  `/usr/local/share/uefi-firmware/BHYVE_UEFI.fd`); `security/doas`
  (rules: `examples/doas.conf.sample`).
- **Kernel modules**: `vmm`, `nmdm` (console pair; the supervisor
  `kldload -n`s it), `if_bridge` (only if you use a LAN bridge), `if_tap`
  (bhyve opens `/dev/tapN` for `backend=tapN`).
- **Base tools**: `daemon(8)`, `bhyvectl(8)`, `camcontrol(8)`, `fstat(1)`,
  `doas(1)`.
- **Not needed on the host**: bcachefs-tools (the filesystem runs in the
  guest), fusefs (that is the alternative FUSE stack this VM is meant to
  replace — see the dual-writer gate in `pool-stack-up.sh`).

## Undeclared dependencies — read before `--lint`

The reference deployment carried host-side helpers that are NOT in this
repo. Two degrade gracefully; one is hard unless you override `BHYVE`.

### `bhyve-uartfix` — patched bhyve, PRIVATE binary, optional

`BHYVE` defaults to `/usr/local/libexec/bhyve-uartfix`: a patched `bhyve(8)`
built from an upstream FreeBSD PR effort. It is not shipped here — it is
the author's private build. **If stock bhyve works for you, use it**: set
`BHYVE=/usr/sbin/bhyve` in the lifecycle conf. The supervisor insists on an
absolute path on purpose (a PATH lookup silently picking a different binary
is how the spin below once came back).

Symptom the patch fixes (facts from the upstream report, sanitized): after
the console writer disappears — EOF on the `stdio`/`tty` uart backend (a
logger restart, a closed pipe, a detached session) — stock bhyve's mevent
thread pins one host core at ~100%: kqueue keeps reporting the EOF'd
descriptor readable and the uart drain re-arms forever. Once a guest opens
the serial port in interrupt-driven mode, every drain pulses IRQ4:
measured ~1.25M IOAPIC pin-4 pulses/s and ~800K "vm exits due to external
interrupt"/s. A single-vCPU Linux guest soft-locks and fails to boot;
4-vCPU guests mask it while the host core still burns. The patch treats
`read() == 0` / `EIO` as read-side hangup (same semantics as the TCP
console backend's disconnect): input off, TX unaffected, one warning line.
If your consoles never EOF — e.g. an always-open `nmdm` logger — stock
bhyve is fine.

### `oomprotect` — tiny local helper, optional

The supervisor re-execs itself under `/usr/local/libexec/oomprotect` when
present (`--lint` warns when not). What it does: a ~50-line C wrapper that
raises the `P_PROTECTED` process flag (procctl(2)) and then `exec`s its
arguments; the kernel pageout OOM killer (`vm_pageout_oom`) skips
`P_PROTECTED` processes when choosing a victim, and the flag survives
`exec` and inherits to children. Why: under host memory pressure the
kernel once killed bhyve and the restart loop treated every non-zero exit
as "retry later" — the VM stayed down for hours. Source: author's private
tree (not shipped here); any helper that sets the protected flag and
re-execs is a drop-in replacement.

### resctrl marker — a note, not a dependency

`RESCTRL_MARKER` (`/usr/local/libexec/vmm-resctrl-patched.marker`) records
"this host's vmm will not boot-loop Linux 6.12+ guests in resctrl init".
Background: upstream FreeBSD bug 300480 — the AMD QoS CPUID leaf
0x80000020 leaks through to guests (the Intel RDT leaves are masked; the
AMD one has no case in vmm's CPUID table), Linux 6.12+ maps it to resctrl
features and divides by Intel-side zeros → divide error in PID 1, boot
loop. Guest-side workaround if you are affected:
`initcall_blacklist=resctrl_arch_late_init` on the guest kernel cmdline.
A missing marker is NOT fatal: the supervisor logs a WARN and pauses 10 s
before attaching pool disks (so the WARN is readable). If your CPU/vmm is
unaffected, record that you checked:
`doas touch /usr/local/libexec/vmm-resctrl-patched.marker`.

### `poolmount` — optional local glue

`/usr/local/etc/rc.d/poolmount` was the reference deployment's persistent
NFS mount of `/mnt/pool` (ensure/remount semantics, serialized under a
lock). The supervisor calls `poolmount remount` in the background after
every VM (re)start but SKIPS the call when the script is not deployed.
Without it you simply mount `/mnt/pool` yourself — `pool-stack-up.sh`
does. **Not required.**

## Network setup (generic placeholders — replace before use)

The shipped net asserts are EMPTY: by default the supervisor touches NO
host networking. Setting `BENCH_*` / `LAN_*` in the lifecycle conf turns
them on, and then they re-apply on EVERY supervise iteration (the
supervisor prints one prominent warning at startup and in `--lint`; see
`examples/bhyve.conf.sample`). Prefer one-time setup in `rc.conf(5)`;
example with generic names/addresses (172.31.255.0/30 is the bench /30
this repo's image and ceremony actually use; TEST-NET-1 stands in for
your LAN):

```sh
sysrc kld_list+="vmm nmdm if_bridge"
sysrc cloned_interfaces="bridge0 tap1 tap2"
sysrc ifconfig_tap1="inet 172.31.255.1/30 mtu 9000 up"     # bench /30, host end
sysrc ifconfig_bridge0="addm <uplink-nic> addm tap2 up"    # LAN bridge
sysrc ifconfig_bridge0_alias0="inet 192.0.2.3/24"          # your LAN address
sysrc defaultrouter="192.0.2.1"                            # your gateway
```

**MTU parity is load-bearing** (README scar F24 — the single biggest
lever): the host bench tap (`ifconfig_tap1` / `BENCH_MTU`), the virtio
device (`pci.0.5.0.mtu` in `bhyve-vm.conf`) and the guest interface
(`../image/overlay/etc/network/interfaces`) must ALL say 9000. A mismatch
does not error — it shows up as unkillable `mount_nfs` reconnect zombies
holding a per-server lock. Diagnose with `tcpdump` + `procstat -k`, never
by retrying the mount.

## Serial pins — the fail-closed guard

Pool roles are pinned by **serial**, never by device name: a re-platform
once flipped `ada0`/`ada1` under unchanged serials, which is the whole
reason the guard exists. Before uncommenting any `/dev/...` pool node in
`bhyve-vm.conf`, list every member in the lifecycle conf:

```sh
# /vm/bcachefs-box/bhyve.conf — device = basename without partition suffix
G8_SERIALS='nda0=SERIAL-OF-NVME-MEMBER ada1=SERIAL-OF-HDD-MEMBER'
```

Before EVERY attach the supervisor runs `camcontrol identify` and
compares; an **unpinned device, unknown device, or mismatched serial
ABORTS the start** — the guard fails closed, it never silently bypasses.
`--lint` refuses too. Poolless boot ("phase A"): leave the pool nodes
commented out; the pin and resctrl asserts are skipped entirely. Get
serials with `doas camcontrol identify /dev/nda0`.

## Running

```sh
sh run-bcachefsbox.sh --lint          # validate both configs + env; touches nothing
doas service bcachefsbox onestart     # via the rc.d wrapper (daemon(8), run log)
doas sh pool-stack-up.sh              # cold start after a host reboot (gated)
doas service bcachefsbox onestop      # stop: SIGTERM → ACPI grace → force-off → destroy
sh run-bcachefsbox.sh --print-config  # show the generated runtime -k files
```

First run seeds `/vm/bcachefs-box/bhyve-vm.conf` from the adjacent
`bhyve-vm.conf.example` — edit it (or install your own) before relying on
it. Logs: `/var/log/bcachefsbox-run.log` (supervisor),
`/var/log/bcachefsbox-console.log` (guest console, mode=log),
`/var/log/netassert.log` (bridge pre-state, only when LAN asserts are on).
