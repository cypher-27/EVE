"""
Unit + integration tests for validator.collect_errors().

Requires the refactored validator.py (v3) where collect_errors(entornos)
is a pure function returning a ValidationResult(errors, total_ram, total_cores).

Run with:
    pip install pytest pyyaml
    pytest tests/ -v
"""
import pathlib
import yaml
import pytest

from validator import collect_errors

FIXTURES_DIR = pathlib.Path(__file__).parent / "fixtures"

CORE_NODES = [
    {"nombre": "doom-gateway", "estado": "presente", "tipo": "gateway", "core": True,
     "red": {"ip": "192.168.1.30/24"}},
    {"nombre": "makima-core", "estado": "presente", "tipo": "fisico", "core": True,
     "red": {"ip": "192.168.1.20/24"}},
    {"nombre": "reze-core", "estado": "presente", "tipo": "fisico", "core": True,
     "red": {"ip": "192.168.1.10/24"}},
]


def make_entorno(**overrides):
    """A 100% valid lxc resource by default. Pass only the field(s) you
    want to break — everything else stays valid, so each test isolates
    exactly one rule."""
    base = {
        "nombre": "test-resource",
        "estado": "presente",
        "tipo": "lxc",
        "os": "alpine",
        "nodo_proxmox": "reze",
        "vmid": 900,
        "red": {"ip": "192.168.1.60/24", "gateway": "192.168.1.30"},
        "recursos": {"cores": 1, "memoria": 256, "disco": 4},
    }
    base.update(overrides)
    return base


# ==============================================================================
# Sanity check: the default fixture itself must be clean
# ==============================================================================

def test_valid_resource_produces_no_errors():
    result = collect_errors(CORE_NODES + [make_entorno()])
    assert result.errors == []


# ==============================================================================
# One rule per case — single resource, single violation
# ==============================================================================

SINGLE_VIOLATION_CASES = [
    pytest.param(
        make_entorno(red={"ip": "192.168.1.101/24", "gateway": "192.168.1.30"}),
        "outside the allowed range",
        id="ip_out_of_range",
    ),
    pytest.param(
        make_entorno(nodo_proxmox="reze",
                      recursos={"cores": 1, "memoria": 256, "disco": 4,
                                "disco_datos": {"storage": "hdd_data", "size": "5G", "mp": "/data"}}),
        "hdd_data' on node 'reze', but that pool does not exist",
        id="storage_pool_missing_on_node",
    ),
    pytest.param(
        make_entorno(recursos={"cores": 1, "memoria": 256, "disco": 4,
                                "disco_datos": {"storage": "local-zfs", "size": "2T", "mp": "/data"}}),
        "Invalid size format",
        id="invalid_disk_size_format",
    ),
    pytest.param(
        make_entorno(os=None),
        "missing required field: os",
        id="lxc_missing_os",
    ),
    pytest.param(
        make_entorno(os="debian", recursos={"cores": 1, "memoria": 256, "disco": 2}),
        "is below minimum for 'debian'",
        id="disk_too_small_for_os",
    ),
    pytest.param(
        make_entorno(tipo="vm", plantilla="debian13-template",
                     recursos={"cores": 1, "memoria": 512, "disco": 10}),
        "smaller than template 'debian13-template' minimum",
        id="disk_too_small_for_template",
    ),
    pytest.param(
        make_entorno(recursos={"cores": 1, "memoria": 20000, "disco": 4}),
        "RAM overbooking",
        id="ram_overbooking",
    ),
    pytest.param(
        make_entorno(recursos={"cores": 50, "memoria": 256, "disco": 4}),
        "CPU overbooking",
        id="cpu_overbooking",
    ),
    pytest.param(
        make_entorno(efimero=True, recursos={"cores": 1, "memoria": 3000, "disco": 4}),
        "Ephemeral RAM limit exceeded",
        id="ephemeral_ram_exceeded",
    ),
    pytest.param(
        make_entorno(estado="reiniciando"),
        "Must be one of",
        id="invalid_estado_enum",
    ),
    pytest.param(
        make_entorno(red={"ip": "192.168.1.60/24", "gateway": "192.168.1.99"}),
        "does not match any declared tipo:gateway node",
        id="gateway_not_declared",
    ),
    pytest.param(
        make_entorno(red={"ip": "999.999.999.999/24"}),
        "Invalid IP",
        id="invalid_ip_format",
    ),
    pytest.param(
        make_entorno(nodo_proxmox="reze2"),
        "Unknown Proxmox node",
        id="unknown_proxmox_node",
    ),
    pytest.param(
        make_entorno(recursos=None),
        "missing required block: recursos",
        id="missing_recursos_block",
    ),
    pytest.param(
        make_entorno(tipo="vm"),  # no 'plantilla' key at all
        "missing required field: plantilla",
        id="vm_missing_plantilla",
    ),
    pytest.param(
        make_entorno(vmid=None),
        "missing required field: vmid",
        id="lxc_missing_vmid",
    ),
    pytest.param(
        make_entorno(tipo="vm", plantilla="windows11-template",
                     recursos={"cores": 1, "memoria": 512, "disco": 20}),
        "uses unknown template",
        id="unknown_template",
    ),
    pytest.param(
        make_entorno(firewall_externo=[{"puerto": 22, "protocolo": "icmp"}]),
        "Invalid protocol",
        id="invalid_firewall_protocol",
    ),
    pytest.param(
        make_entorno(firewall_externo=[{"puerto": 99999, "protocolo": "tcp"}]),
        "Invalid port",
        id="invalid_firewall_port",
    ),
    pytest.param(
        make_entorno(monitor_enabled=True),
        "eve-monitor is ABSENT",
        id="monitor_requested_without_eve_monitor",
    ),
    pytest.param(
        make_entorno(nodo_proxmox="makima",
                      recursos={"cores": 1, "memoria": 256, "disco": 4,
                                "disco_datos": {"storage": "hdd_data", "size": "900G", "mp": "/data"}}),
        "Storage exceeded on makima/hdd_data",
        id="storage_aggregate_exceeded",
    ),
]


@pytest.mark.parametrize("entorno,expected_error", SINGLE_VIOLATION_CASES)
def test_single_violation(entorno, expected_error):
    result = collect_errors(CORE_NODES + [entorno])
    assert any(expected_error in e for e in result.errors), (
        f"Expected an error containing '{expected_error}', got: {result.errors}"
    )


# ==============================================================================
# Violations that need two resources to manifest (duplicates)
# ==============================================================================

def test_duplicate_ip():
    a = make_entorno(nombre="dup-a", vmid=910, red={"ip": "192.168.1.50/24"})
    b = make_entorno(nombre="dup-b", vmid=911, red={"ip": "192.168.1.50/24"})
    result = collect_errors(CORE_NODES + [a, b])
    assert any("Duplicate IP" in e for e in result.errors)


def test_duplicate_vmid():
    a = make_entorno(nombre="dup-vmid-a", vmid=920, red={"ip": "192.168.1.44/24"})
    b = make_entorno(nombre="dup-vmid-b", vmid=920, red={"ip": "192.168.1.45/24"})
    result = collect_errors(CORE_NODES + [a, b])
    assert any("Duplicate VMID" in e for e in result.errors)


def test_duplicate_name():
    a = make_entorno(nombre="same-name", vmid=930, red={"ip": "192.168.1.46/24"})
    b = make_entorno(nombre="same-name", vmid=931, red={"ip": "192.168.1.47/24"})
    result = collect_errors(CORE_NODES + [a, b])
    assert any("Duplicate name" in e for e in result.errors)


# ==============================================================================
# Regression guard: no state leaks between calls (the original ERRORS-global bug)
# ==============================================================================

def test_no_state_leaks_between_calls():
    broken = collect_errors(CORE_NODES + [make_entorno(red={"ip": "192.168.1.101/24"})])
    assert len(broken.errors) > 0

    clean = collect_errors(CORE_NODES + [make_entorno()])
    assert clean.errors == [], f"State leaked from a previous call: {clean.errors}"


# ==============================================================================
# Integration smoke test — the full stress-test fixture, end to end
# ==============================================================================

def _load_stress_fixture_entornos():
    fixture_path = FIXTURES_DIR / "lab-state-stress-test.yaml"
    with open(fixture_path) as f:
        data = yaml.safe_load(f)
    return data["entornos"]


def test_full_stress_fixture_matches_expected_error_count():
    result = collect_errors(_load_stress_fixture_entornos())
    assert len(result.errors) == 24, (
        f"Expected 24 errors, got {len(result.errors)}:\n" + "\n".join(result.errors)
    )


def test_full_stress_fixture_valid_control_is_clean():
    result = collect_errors(_load_stress_fixture_entornos())
    assert not any("stress-valid-control" in e for e in result.errors), (
        "stress-valid-control should never appear in the error list"
    )
