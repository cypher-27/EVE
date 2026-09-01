"""
Renders ansible/sdn-gateway/templates/eve-firewall.j2 directly with Jinja2
(no Ansible, no Docker, no real gateway) and asserts the generated iptables
rules match what the contract (`firewall_externo` per entorno) declares.

This is the piece Checkov structurally cannot cover: the real risk isn't in
main.tf, it's in the correlation between lab-state.yaml's `firewall_externo`
and what this template actually renders. Molecule could test this too, but
at 10-20x the setup cost for the same signal.

Run with:
    .venv/bin/pytest tests/test_firewall_template.py -v
"""
import pathlib

import jinja2
import pytest

TEMPLATE_PATH = (
    pathlib.Path(__file__).parent.parent
    / "ansible" / "sdn-gateway" / "templates" / "eve-firewall.j2"
)

BASE_VARS = {
    "wg_iface": "wg0",
    "zt_iface": "ztktivnucr",
    "lan_iface": "eth0",
    "lan_subnet": "192.168.1.0/24",
    "rasp_lan_ip": "192.168.1.30",
}


def render(entornos_activos):
    template = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(
        TEMPLATE_PATH.read_text()
    )
    return template.render(**BASE_VARS, entornos_activos=entornos_activos)


# ==============================================================================
# The real case: eve-monitor with its 3 ports
# ==============================================================================

def test_eve_monitor_ports_generate_accept_on_both_tunnels():
    entornos = [{
        "nombre": "eve-monitor",
        "estado": "presente",
        "red": {"ip": "192.168.1.40/24"},
        "firewall_externo": [
            {"puerto": 22, "protocolo": "tcp", "descripcion": "SSH Admin"},
            {"puerto": 3000, "protocolo": "tcp", "descripcion": "Grafana"},
            {"puerto": 8428, "protocolo": "tcp", "descripcion": "VictoriaMetrics"},
        ],
    }]
    output = render(entornos)
    for port in (22, 3000, 8428):
        assert f"iptables -A FORWARD -i $WG_IFACE -d 192.168.1.40 -p tcp --dport {port} -j ACCEPT" in output
        assert f"iptables -A FORWARD -i $ZT_IFACE -d 192.168.1.40 -p tcp --dport {port} -j ACCEPT" in output


def test_undeclared_port_never_gets_a_rule():
    """The negative case: only declared ports get rules — nothing 'extra'."""
    entornos = [{
        "nombre": "eve-monitor",
        "estado": "presente",
        "red": {"ip": "192.168.1.40/24"},
        "firewall_externo": [{"puerto": 22, "protocolo": "tcp"}],
    }]
    output = render(entornos)
    assert "--dport 22 -j ACCEPT" in output
    assert "--dport 3000" not in output
    assert "--dport 8428" not in output


# ==============================================================================
# The template's fallback: 'firewall_externo | default([])'
# ==============================================================================

def test_resource_without_firewall_externo_gets_no_rule_and_does_not_crash():
    entornos = [{
        "nombre": "doom-gateway",
        "estado": "presente",
        "red": {"ip": "192.168.1.30/24"},
        # no 'firewall_externo' — the template must use the default([]) and not crash
    }]
    output = render(entornos)
    assert "-d 192.168.1.30 -p" not in output


# ==============================================================================
# 'ausente' resources must be skipped entirely
# ==============================================================================

def test_ausente_resource_is_skipped_entirely():
    entornos = [{
        "nombre": "eve-lab-vm",
        "estado": "ausente",
        "red": {"ip": "192.168.1.41/24"},
        "firewall_externo": [{"puerto": 22, "protocolo": "tcp"}],
    }]
    output = render(entornos)
    assert "192.168.1.41" not in output


# ==============================================================================
# Multiple resources: each with its own rules, without leaking into each other
# ==============================================================================

def test_multiple_resources_do_not_leak_rules_into_each_other():
    entornos = [
        {
            "nombre": "eve-monitor",
            "estado": "presente",
            "red": {"ip": "192.168.1.40/24"},
            "firewall_externo": [{"puerto": 8428, "protocolo": "tcp"}],
        },
        {
            "nombre": "eve-lab-vm",
            "estado": "presente",
            "red": {"ip": "192.168.1.41/24"},
            "firewall_externo": [{"puerto": 22, "protocolo": "tcp"}],
        },
    ]
    output = render(entornos)
    assert "-d 192.168.1.40 -p tcp --dport 8428 -j ACCEPT" in output
    assert "-d 192.168.1.41 -p tcp --dport 22 -j ACCEPT" in output
    assert "-d 192.168.1.40 -p tcp --dport 22" not in output
    assert "-d 192.168.1.41 -p tcp --dport 8428" not in output


# ==============================================================================
# The final catch-all: must exist and must come AFTER the dynamic rules
# (if this breaks, the allowlist becomes "decorative", as the template's
# own comment says).
# ==============================================================================

def test_catch_all_drop_exists_after_dynamic_rules():
    entornos = [{
        "nombre": "eve-monitor",
        "estado": "presente",
        "red": {"ip": "192.168.1.40/24"},
        "firewall_externo": [{"puerto": 22, "protocolo": "tcp"}],
    }]
    output = render(entornos)
    accept_idx = output.index("--dport 22 -j ACCEPT")
    dropall_idx = output.rindex("iptables -A FORWARD -j DROP")
    assert dropall_idx > accept_idx, "The catch-all DROP must come after the dynamic rules"


def test_default_policies_are_drop_drop_accept():
    output = render([])
    assert "iptables -P INPUT DROP" in output
    assert "iptables -P FORWARD DROP" in output
    assert "iptables -P OUTPUT ACCEPT" in output


# ==============================================================================
# Direct regression for invalid protocol: if the YAML ever allows unusual
# protocols, the template must not generate an empty or malformed '-p '.
# ==============================================================================

def test_protocol_and_port_are_interpolated_literally():
    entornos = [{
        "nombre": "eve-monitor",
        "estado": "presente",
        "red": {"ip": "192.168.1.40/24"},
        "firewall_externo": [{"puerto": 51820, "protocolo": "udp"}],
    }]
    output = render(entornos)
    assert "-p udp --dport 51820 -j ACCEPT" in output
