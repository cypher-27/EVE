"""
Custom Checkov check for EVE.

Context: EVE centralizes all firewalling at the SDN layer (doom-gateway,
see ansible/sdn-gateway/deploy-firewall.yml + templates/eve-firewall.j2).
Per-resource `network.firewall` on proxmox_lxc / proxmox_vm_qemu must
always stay at its default (false / unset). If someone enables it on a
resource, it creates a second, uncoordinated filtering layer on top of
the SDN rules — undefined behavior, not a security improvement.

This does NOT try to validate the SDN rules themselves (that lives in
tests/test_firewall_template.py, closer to the actual source of truth:
lab-state.yaml + the Jinja2 template). This check only guards against a
regression in main.tf.

Place this file in custom_checks/ and run with:
    checkov -d terraform/ --external-checks-dir custom_checks/ --check CKV_EVE_1
"""
from typing import Any, Dict

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck


class NoHostLevelFirewallOnProxmoxResources(BaseResourceCheck):
    def __init__(self) -> None:
        name = (
            "Proxmox LXC/VM must not enable host-level network.firewall "
            "(firewalling is centralized via SDN on doom-gateway)"
        )
        check_id = "CKV_EVE_1"
        supported_resources = ["proxmox_lxc", "proxmox_vm_qemu"]
        categories = [CheckCategories.NETWORKING]
        super().__init__(
            name=name,
            id=check_id,
            categories=categories,
            supported_resources=supported_resources,
        )

    def scan_resource_conf(self, conf: Dict[str, Any]) -> CheckResult:
        network_blocks = conf.get("network", [])
        for block in network_blocks:
            if not isinstance(block, dict):
                continue
            firewall_val = block.get("firewall")
            # Checkov wraps HCL values in a list, e.g. {"firewall": [True]}
            if isinstance(firewall_val, list) and firewall_val and firewall_val[0] is True:
                return CheckResult.FAILED
            if firewall_val is True:
                return CheckResult.FAILED
        return CheckResult.PASSED


check = NoHostLevelFirewallOnProxmoxResources()
