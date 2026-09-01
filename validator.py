#!/usr/bin/env python3
"""
EVE Validator — Enforces cluster topology rules against lab-state.yaml.

collect_errors(entornos) is a pure function (no I/O, no module-level state),
so it can be unit-tested directly (see tests/test_validator.py). validate()
is the CLI entrypoint invoked by orchestrator.sh.
"""
import sys
import yaml
import ipaddress
from dataclasses import dataclass, field

# ==============================================================================
# Cluster Governance & Physical Topology
# ==============================================================================

LIMITS = {
    "cpu_total":          11,
    "ram_total_mb":       8192,
    "ram_ephemeral_mb":   2048,   # Cap for resources flagged as ephemeral
    "supported_os":       ["debian", "alpine"],
    "nodes": {
        "makima": { "local-zfs": 100, "hdd_data": 850 },  # local-zfs=SSD, hdd_data=HDD
        "reze":   { "local-zfs": 850, "hdd_data": 0   },  # local-zfs=HDD, hdd_data=DOES NOT EXIST
    },
    "templates": {
        "debian13-template": 11,
    },
    "lxc_templates": {
        "alpine":  { "tarball": "alpine-eve-custom.tar.zst",                    "min_disk": 2 },
        "debian":  { "tarball": "debian-12-standard_12.12-1_amd64.tar.zst",     "min_disk": 4 },
    }
}

IP_MONITOR     = "192.168.1.40"
IP_RANGE_START = ipaddress.IPv4Address("192.168.1.41")
IP_RANGE_END   = ipaddress.IPv4Address("192.168.1.63")

VALID_ESTADOS = ("presente", "ausente")

# ==============================================================================
# Helpers
# ==============================================================================

GREEN  = "\033[0;32m"
RED    = "\033[0;31m"
YELLOW = "\033[0;33m"
NC     = "\033[0m"

def log(color: str, msg: str) -> None:
    print(f"{color}{msg}{NC}")

def fatal(msg: str) -> None:
    """Unrecoverable error — nothing else can run (e.g. contract unreadable)."""
    log(RED, f"[!] FATAL ERROR: {msg}")
    sys.exit(1)

@dataclass
class ValidationResult:
    errors: list = field(default_factory=list)
    total_ram: int = 0
    total_cores: int = 0

# ==============================================================================
# Pure validator — no file I/O, no sys.exit, no module-level state.
# This is what pytest imports and calls directly.
# ==============================================================================

def collect_errors(entornos: list) -> ValidationResult:
    errors: list = []

    def fail(msg: str) -> None:
        log(RED, f"[!] VALIDATION ERROR: {msg}")
        errors.append(msg)

    total_ram      = 0
    total_cores    = 0
    ephemeral_ram  = 0

    disk_usage = {
        "makima": {"local-zfs": 0, "hdd_data": 0},
        "reze":   {"local-zfs": 0, "hdd_data": 0},
    }

    monitor_present    = False
    requesting_monitor = []
    seen_names         = set()
    seen_vmids         = set()
    seen_ips           = set()

    gateway_ips = {
        e["red"]["ip"].split("/")[0]
        for e in entornos
        if e.get("tipo") == "gateway" and e.get("estado") == "presente"
        and "red" in e and "ip" in e["red"]
    }

    for env in entornos:
        name         = env.get("nombre", "unknown")
        state        = env.get("estado",  "ausente")
        is_core      = env.get("core",     False)
        is_ephemeral = env.get("efimero", False)
        kind         = env.get("tipo",     "vm")
        os_distro    = env.get("os",       "debian")
        node         = env.get("nodo_proxmox")
        vmid         = env.get("vmid")

        if name in seen_names:
            fail(f"Duplicate name: '{name}'")
        seen_names.add(name)

        if vmid is not None:
            if vmid in seen_vmids:
                fail(f"Duplicate VMID: {vmid} in '{name}'")
            seen_vmids.add(vmid)

        if name == "eve-monitor" and state == "presente":
            monitor_present = True

        if state not in VALID_ESTADOS:
            fail(f"Invalid estado '{state}' in '{name}'. Must be one of {VALID_ESTADOS}.")
            continue

        if state == "ausente":
            continue

        if env.get("monitor_enabled", False):
            requesting_monitor.append(name)

        # --- VM / LXC validation ---
        if kind in ["vm", "lxc"]:
            if kind == "vm" and not env.get("plantilla"):
                fail(f"VM '{name}' missing required field: plantilla")
                continue

            if kind == "lxc":
                if vmid is None:
                    fail(f"LXC '{name}' missing required field: vmid")
                    continue
                if not env.get("os"):
                    fail(f"LXC '{name}' missing required field: os")
                    continue

            if os_distro not in LIMITS["supported_os"]:
                fail(f"Unsupported OS: '{os_distro}' in '{name}'")
                continue

            if node not in LIMITS["nodes"]:
                fail(f"Unknown Proxmox node: '{node}' in '{name}'")
                continue

            recursos = env.get("recursos")
            if not recursos:
                fail(f"'{name}' missing required block: recursos")
                continue

            missing_fields = [f for f in ["cores", "memoria", "disco"] if recursos.get(f) is None]
            if missing_fields:
                for field_name in missing_fields:
                    fail(f"'{name}' missing recursos.{field_name}")
                continue

            ram        = recursos.get("memoria", 0)
            cores      = recursos.get("cores",   0)
            disk_root  = recursos.get("disco",   8)

            total_ram   += ram
            total_cores += cores
            if is_ephemeral:
                ephemeral_ram += ram

            if kind == "vm":
                plantilla = env.get("plantilla")
                min_disk  = LIMITS["templates"].get(plantilla)
                if min_disk is None:
                    fail(f"VM '{name}' uses unknown template '{plantilla}'. "
                         f"Register it in LIMITS['templates'] in validator.py")
                    continue
                if disk_root < min_disk:
                    fail(f"VM '{name}': disco={disk_root}G is smaller than "
                         f"template '{plantilla}' minimum ({min_disk}G). "
                         f"Proxmox cannot shrink a disk on clone.")

            if kind == "lxc":
                lxc_tpl = LIMITS["lxc_templates"].get(os_distro)
                if lxc_tpl is None:
                    fail(f"LXC '{name}' uses unregistered OS '{os_distro}'. "
                         f"Register it in LIMITS['lxc_templates'] in validator.py")
                    continue
                if disk_root < lxc_tpl["min_disk"]:
                    fail(f"LXC '{name}': disco={disk_root}G is below minimum "
                         f"for '{os_distro}' ({lxc_tpl['min_disk']}G).")

            assigned_pool = "hdd_data" if (is_ephemeral and node == "makima") else "local-zfs"

            extra_disk = recursos.get("disco_datos", {})
            if extra_disk:
                extra_pool = extra_disk.get("storage")
                extra_size_str = extra_disk.get("size", "0")
                try:
                    extra_size = int(extra_size_str.replace("G", "").replace("g", ""))
                except ValueError:
                    fail(f"Invalid size format in disco_datos of '{name}': {extra_size_str}")
                    extra_size = 0

                if extra_pool == "hdd_data" and node == "reze":
                    fail(f"'{name}' requests 'hdd_data' on node 'reze', but that pool does not exist.")

                if extra_pool in disk_usage[node]:
                    disk_usage[node][extra_pool] += extra_size

            disk_usage[node][assigned_pool] += disk_root

            for rule in env.get("firewall_externo", []):
                port     = rule.get("puerto")
                protocol = rule.get("protocolo", "tcp").lower()

                if protocol not in ["tcp", "udp"]:
                    fail(f"Invalid protocol in '{name}': '{protocol}'. Use 'tcp' or 'udp'.")

                if port is not None:
                    if not isinstance(port, int) or not (1 <= port <= 65535):
                        fail(f"Invalid port in '{name}': {port}")

        # --- Network validation ---
        if "red" in env and "ip" in env["red"]:
            ip_str = env["red"]["ip"].split("/")[0]
            try:
                ip_obj = ipaddress.IPv4Address(ip_str)
            except ValueError:
                fail(f"Invalid IP in '{name}': {ip_str}")
                continue

            if ip_str in seen_ips:
                fail(f"Duplicate IP: {ip_str} in '{name}'")
            seen_ips.add(ip_str)

            gateway = env["red"].get("gateway")
            if gateway:
                try:
                    ipaddress.IPv4Address(gateway)
                except ValueError:
                    fail(f"Invalid gateway in '{name}': {gateway}")
                else:
                    if gateway not in gateway_ips:
                        fail(f"Gateway '{gateway}' in '{name}' does not match any "
                             f"declared tipo:gateway node ({sorted(gateway_ips)})")

            if name == "eve-monitor":
                if ip_str != IP_MONITOR:
                    fail(f"eve-monitor must use static IP {IP_MONITOR}")
            elif not is_core:
                if not (IP_RANGE_START <= ip_obj <= IP_RANGE_END):
                    fail(f"IP of '{name}' ({ip_str}) is outside the allowed range (.41–.63)")

    if requesting_monitor and not monitor_present:
        fail(f"Resources {requesting_monitor} request monitoring, but eve-monitor is ABSENT.")

    if total_ram > LIMITS["ram_total_mb"]:
        fail(f"RAM overbooking: {total_ram}MB requested / {LIMITS['ram_total_mb']}MB available")

    if total_cores > LIMITS["cpu_total"]:
        fail(f"CPU overbooking: {total_cores} cores requested / {LIMITS['cpu_total']} available")

    if ephemeral_ram > LIMITS["ram_ephemeral_mb"]:
        fail(f"Ephemeral RAM limit exceeded: {ephemeral_ram}MB / {LIMITS['ram_ephemeral_mb']}MB")

    for node_name, pools in LIMITS["nodes"].items():
        for pool, limit in pools.items():
            used = disk_usage[node_name][pool]
            if used > limit:
                fail(f"Storage exceeded on {node_name}/{pool}: {used}GB requested / {limit}GB available")

    return ValidationResult(errors=errors, total_ram=total_ram, total_cores=total_cores)

# ==============================================================================
# CLI entrypoint — used by orchestrator.sh. Same external behavior as before.
# ==============================================================================

def validate() -> None:
    try:
        with open("lab-state.yaml") as f:
            data = yaml.safe_load(f)
    except Exception as e:
        fatal(f"Cannot read lab-state.yaml: {e}")

    entornos = data.get("entornos", [])
    log(YELLOW, "[*] Starting EVE topology validation...")

    result = collect_errors(entornos)

    if result.errors:
        log(RED, f"\n[✗] Validation FAILED with {len(result.errors)} error(s):")
        for i, err in enumerate(result.errors, 1):
            log(YELLOW, f"  {i}. {err}")
        sys.exit(1)

    log(GREEN, f"[✓] Validation passed — RAM: {result.total_ram}/{LIMITS['ram_total_mb']}MB | "
               f"CPU: {result.total_cores}/{LIMITS['cpu_total']}")
    sys.exit(0)


if __name__ == "__main__":
    validate()
