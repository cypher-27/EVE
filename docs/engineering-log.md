# EVE — Perimeter Access Architecture and Consolidated Technical Log

> **Status note:** this document is retrospective. The Cloudflare Zero Trust-based perimeter access layer described here is **decommissioned**: the `hackedagain.lol` domain expired and is no longer resolvable from the internet. The `cloudflared` tunnel and Cloudflare Access policies are still technically configured and "Healthy" on Cloudflare's side, but with no public hostname pointing to them anymore — it's a complete, functional architecture, frozen rather than destroyed. Everything described here documents **what was built and how it worked**, not an active operational guide.
>
> Sources: the master Obsidian note (raw development log) + 7 standalone technical documents (`EVE_cierre_de_proyecto.md`, `EVE-cierre-hoy.md`, `EVE-incident-log-consolidado.md`, `EVE-janitor-pipeline-fixes.md`, `EVE_stress_test_drift_firewall.md`, `EVE-stress-test-report.md`, `resumen-incidente-forwarding-eve.md`). The Terraform/Ansible/orchestrator pipeline lives in this same repository (see the main [README](../README.md) for that layer); this document focuses specifically on the network/perimeter layer and the incident history worth preserving long-term.

## Contents

1. [Final architecture actually used](#1-final-architecture-actually-used)
2. [Attempted and discarded / changed](#2-attempted-and-discarded--changed)
3. [Backlog / never implemented](#3-backlog--never-implemented)
4. [Log of incidents, bugs, and fixes](#4-log-of-incidents-bugs-and-fixes-stories-worth-keeping)

---

## 1. Final architecture actually used

### 1.1 Physical foundation (SDDC — Proxmox Cluster "eve")

| Node | Hardware | IP | Role |
|---|---|---|---|
| Reze (Dell) | i7 8-core, 8GB RAM, 1TB HDD (ZFS `rpool`) | 192.168.1.10 | Compute node, HAProxy backup |
| Makima (Lenovo) | i3 4-core, 8GB RAM, 128GB NVMe (`rpool`) + 1TB HDD (`hdd_data`) | 192.168.1.20 | Primary compute node, HAProxy primary |
| Raspi (RPi4) | 4-core, 8GB RAM, 32GB microSD | 192.168.1.30 | Perimeter gateway, quorum QDevice, SDN firewall |

Proxmox cluster "eve" with a QDevice on the Raspberry Pi to avoid split-brain in a 2-node cluster (3 total votes, 2 required). Both laptops configured with `HandleLidSwitch=ignore` to prevent suspending on lid close. Proxmox repositories migrated from `enterprise` to `no-subscription` (DEB822 format).

### 1.2 Remote access and management

- **ZeroTier** (network "EVE", `10.1.1.0/24`) as the **primary** management path: Raspberry Pi (`10.1.1.1`, gateway), DigitalOcean VPS (`10.1.1.100`, Edge Gateway), Kali machine (`10.1.1.69`).
- **WireGuard (`wg0`)** demoted to an **SSH-only backup** to the Raspberry Pi — no longer grants access to the Proxmox GUI or the full LAN (`AllowedIPs` trimmed to `10.0.0.0/24`).
- **`notify.sh` / "Devilhunters Lab Monitor v2.0"** on the Raspberry Pi (cron every 15 min): administrative Telegram monitoring of the 3 physical nodes' status, WireGuard/ZeroTier/HAProxy health, public IP, auto-correction of IP forwarding, and **auto-healing** (restarts failed services before alerting). This is an **independent** layer from the observability stack (Grafana/VictoriaMetrics watches ephemeral VMs/LXCs; this script watches the physical infrastructure).

### 1.3 Perimeter access layer (Cloudflare + ZeroTier + HAProxy)

The real request flow (while the domain was alive):

1. **Cloudflare Access** intercepts the request to `eve.hackedagain.lol`, requiring authentication (Google OAuth/OTP) restricted by email ("Solo DVHT" policy).
2. **Cloudflare Tunnel (`cloudflared`)** running on the VPS, with no inbound ports open — outbound-only encrypted tunnel.
3. **Direct connection to the Raspberry Pi via ZeroTier** (`10.1.1.1:8006`) — **key deviation from the original plan**: Nginx Proxy Manager was designed and implemented as an intermediary on the VPS, but ended up completely out of the final path. The tunnel points directly at the Pi.
4. **HAProxy** on the Raspberry Pi, pure TCP mode (L4 passthrough, to avoid breaking Proxmox's native TLS), **Active-Backup**: Makima primary, Reze automatic failover. Verified with real network evidence (4-layer nmap check: contract → iptables → network behavior → L7 response).
5. **Proxmox** receives the HTTPS request and serves the GUI.

Notable bug fixed: Proxmox's VNC client doesn't forward the Cloudflare Access session cookie when opening the console's WebSocket tunnel (Error 1006). Solution: a **Bypass** policy scoped exclusively to the `/api2` path, delegating real security to Proxmox's native authentication (defense in depth, not a security hole).

Context note: an additional route visible in the Cloudflare tunnel config (`192.168.8.100:8006`) belongs to an unrelated project ("Devilhunters", set up for friends) and **is not part of EVE's architecture**.

### 1.4 Centralized SDN firewall (final evolution)

The firewall lives **centralized on the Raspberry Pi**, not per-host (`network.firewall = false` on every VM/LXC is expected behavior, confirmed across multiple `terraform plan` runs). Evolution:

- **v1:** iptables rules embedded in `wg0.conf`'s `PostUp`/`PostDown`.
- **v2:** standalone script (`eve-firewall.sh`) + `eve-firewall.service` (systemd) — the firewall stops depending on WireGuard to exist.
- **v3:** managed by Ansible via a Jinja2 template, with a rule list (`wg_tcp_rules`) manually edited in the playbook for every new VM.
- **v4 (final):** fully driven by the **SSOT (`lab-state.yaml`)** — every environment declares its own `firewall_externo`, and the playbook generates the iptables rules dynamically with no manual intervention per resource. **This is the actual level of "dynamism" achieved**: dynamic in the sense that iptables is never touched by hand, but the underlying variable (the YAML contract) is still edited by a human — there's no closed loop with Terraform automatically updating it.

Verified with thorough real evidence (not just logs): external nmap showed `filtered` on everything undeclared and `open` on declared ports; internal nmap showed `closed` (confirming the filtering is perimeter-level, not on the LXC itself); L7 verification with `nc` confirmed a real HTTP response from Grafana, not just an open port.

### 1.5 Observability

- **`eve-monitor`** (Alpine LXC, fixed IP `192.168.1.40`): VictoriaMetrics + Grafana, with the OS on SSD (`local-zfs`) and time-series data on HDD (`hdd_data` on Makima) — a deliberate performance-vs-capacity trade-off.
- **Auto-discovery**: VictoriaMetrics' scrape configuration is automatically generated from `lab-state.yaml` via a Jinja2 template — no new node requires manual monitor configuration.
- Node Exporter installed conditionally (`monitor_enabled: true`) on each VM/LXC.
- At the time of the drift stress test, `eve-monitor` had `monitor_enabled: false` — full production monitoring never got persistently activated in the lab.

### 1.6 IaC pipeline (context)

- **SOPS + Age** for secrets management (evolved from plaintext `.tfvars`).
- **`lab-state.yaml`** as the Single Source of Truth, driving both Terraform (`for_each`) and Ansible (in-memory dynamic inventory) — **Zero Static Inventory**.
- Multimodal VM/LXC support, Debian + Alpine.
- Remote Terraform backend on S3, with locking **migrated from DynamoDB to native S3 locking** (`use_lockfile`), validated with real concurrency tests; legacy infrastructure decommissioned.
- `validator.py` evolved into a robust guardrail: CPU/RAM/disk quotas per node and pool, IP/VMID uniqueness, valid IP ranges, monitoring dependency checks, reduced RAM quota for ephemeral environments.
- `orchestrator.sh`: staged execution, automatic secrets loading via SOPS, Telegram notifications, interrupt handling (`trap`), `--plan`/`--apply`/`--destroy`/`--force` flags, capped Terraform parallelism to respect the cluster's real capacity.
- Real CI/CD on GitHub Actions with a dedicated self-hosted runner (`runner` user, not root) on the VPS: sanity-check, deploy, and a **Janitor** (scheduled automatic cleanup).
- `pytest` suite (36 cases) — fixed to actually run in CI (the orchestrator previously called the validator directly, bypassing pytest).
- **Policy-as-code**: `CKV_EVE_1` (Checkov, blocks any resource that enables per-host firewalling) + a Jinja2 rendering test for the firewall template (a lightweight substitute for Molecule).

---

## 2. Attempted and discarded / changed

| What was attempted | Why it changed | Replaced by |
|---|---|---|
| Nginx Proxy Manager as an intermediary on the VPS between the Cloudflare tunnel and ZeroTier | Fully implemented but ended up out of the final path | Tunnel pointing directly at the Raspberry Pi via ZeroTier |
| WireGuard as the primary path to the Proxmox GUI (`FORWARD` rules to port 8006) | ZeroTier became the more stable primary path | WireGuard as SSH-only backup to the Raspberry Pi |
| iptables rules embedded in `wg0.conf` (`PostUp`/`PostDown`) | The firewall needed to exist independently of the VPN to avoid breaking the network on WireGuard restarts | Standalone `eve-firewall.service` (systemd) |
| Firewall rule list (`wg_tcp_rules`) manually edited in the Ansible playbook | Wanted to eliminate manual intervention per new VM | Rules generated dynamically from `lab-state.yaml` (SSOT) |
| Secrets management via plaintext `.tfvars` | Risk of exposure in Git | SOPS + Age |
| Terraform locking via a DynamoDB table | Deprecated since Terraform 1.11 | Native S3 locking (`use_lockfile`), validated with concurrency tests |
| Two-branch Git flow (`dev` for ephemeral work + protected `main`, with a Janitor auto-destroying `dev`) | Simplified at some later point | Single `main` branch only |
| Molecule (Docker + Testinfra) for testing the SDN firewall role | High setup cost for the coverage it provided | Pure Jinja2 rendering test, same risk coverage |
| Checkov rule on `network.firewall = false` | Always triggered (correct behavior in 100% of cases), no real value | `CKV_EVE_1`: blocks the actual regression (enabling per-host firewalling) |
| `wait_for_connection` (Ansible) to wait for Alpine hosts to become available | Circular dependency: requires Python, which wasn't installed yet | `raw: echo ready` check with retries |
| `failed_when: false` in the Alpine Python bootstrap | Masked real network/installation failures | Real retries with explicit success verification |
| Terraform's default apply parallelism (10) | Overwhelmed `pveproxy` on a 2-node, 8GB-per-node cluster under a full 10-resource stress test | Capped `-parallelism` in `orchestrator.sh`, tuned empirically against real cluster behavior |

---

## 3. Backlog / never implemented

- **Automatic integration between Terraform and the SDN firewall**: the `firewall_externo` field in the contract did end up connected to the firewall (via Ansible), but there was never a closed loop where Terraform generated that list automatically without human YAML editing.
- **Persisting IPv6 being disabled** on the Raspberry Pi — a TCP/IPv6 blackhole on the ISP side was discovered (ICMPv6 worked, TCP never did); IPv6 was disabled manually as a mitigation but was **never persisted** via `sysctl.d` or in the template itself. It doesn't survive a reboot. **Confirmed as open technical debt through project closure.**
- **Reporting the IPv6 blackhole to the ISP** — optional, outside the repo's control.
- **Persisting static routes** to the LAN via ZeroTier on the Kali machine — never fully resolved; there's recurring intermittency from route conflicts when arriving at the home network (a known, unresolved issue). It was successfully persisted on the VPS.
- **Local package mirror** (apt-cacher-ng / Alpine mirror) on the Raspberry Pi to reduce latency dependency — discarded as non-urgent.
- **Automatic backup of mountpoints** with persistent data (e.g., VictoriaMetrics history) before recreating resources on drift — accepted as a theoretical risk while `monitor_enabled: false`.
- **Functional parity between WireGuard and HAProxy** (HAProxy only binds on the ZeroTier IP, not WireGuard's) — WireGuard remains a backup for Pi access only, with no real failover for the Proxmox panel. Explicit backlog, out of scope.
- **Removing direct access to `makima-core`/`reze-core:8006`** that bypasses the HAProxy VIP — a design inconsistency identified (not a security hole, still firewalled), evaluated but not fixed.
- **Additional semantic validation in the validator**: strict enum for `estado` (avoiding silent typos), `gateway` coherence against the actual declared topology.
- **Aggregate (non fail-fast) validator mode** — proposed to reduce debugging iterations, no confirmation of final implementation.
- **SIEM or event correlation/detection layer** — considered as a natural evolution of the SDN firewall, discarded due to real hardware resource constraints on the cluster.
- **Refactoring the orchestrator into fine-grained subcommands for GitHub Actions** — explicitly discarded due to low return relative to the project's imminent closure.
- **Reducing redundant Terraform "update VM" calls on unchanged resources** — the Telmate provider re-sends a full config update (including deleting unset legacy attributes like `cpuunits`/`cipassword`/`shares`) on every `apply`, even when nothing changed. Adds avoidable API load on an already capacity-constrained cluster; not investigated further given the project's closure.

---

## 4. Log of incidents, bugs, and fixes (stories worth keeping)

This section gathers the most valuable debugging findings of the project — too detailed for a README, but with real technical learning value.

### 4.1 The silent outbound-to-internet timeout (LAN → WAN)

**Symptom:** new VMs/LXCs couldn't complete `apt`/`apk`/`curl` against external mirrors, while `ping` and internal LAN traffic worked fine. Reproduced across multiple IPs and hosts, ruling out IP collision, home router firewall rules, `rp_filter`, MTU/mirror DNS, and conntrack — one by one, with evidence (`arping`, `sysctl`, tests against unrelated destinations).

**Root cause:** the iptables `FORWARD` chain never had a rule accepting **new** connections initiated by the LAN toward the uplink — only established traffic, targeted VPN rules, and ICMP. Every new SYN silently fell into the final `DROP`. That's why ping (explicit ICMP rule) and the Pi's own traffic (the `OUTPUT` chain, not `FORWARD`) worked fine.

**Fix:** a single line (`iptables -A FORWARD -s $LAN_SUBNET -o $LAN_IFACE -j ACCEPT`) fully resolved an issue that took days of systematic diagnosis.

**Unresolved side finding:** a TCP/IPv6 blackhole on the ISP side (typical of immature residential IPv6 deployments) — IPv6 disabled manually, mitigation never persisted in IaC.

### 4.2 The LAN vs. ZeroTier topology mismatch in CI

**Symptom:** the firewall stage (`--stage-firewall`) **always** failed on GitHub Actions with a generic message, but worked fine locally.

**Root cause:** the playbook's inventory task used the Raspberry Pi's physical LAN IP (`192.168.1.30`), ignoring that the CI runner only has connectivity via the ZeroTier overlay (`10.1.1.1`). This wasn't a data or validation bug — it was a network topology mismatch between execution environments never accounted for in the contract's schema.

**Fix:** `lab-state.yaml` gained a dedicated `management_ip` field for `doom-gateway`, separate from its LAN `ip` — the Ansible inventory task now resolves the correct address per execution context (CI runner vs. local admin) instead of assuming the physical LAN IP always applies.

### 4.3 Secrets leaking in GitHub Actions logs

Workflows decrypted `secrets.enc.yaml` with SOPS and wrote raw values to `$GITHUB_ENV` without going through GitHub's native `secrets.*` context. Since those values were never registered with the log redaction engine, manually enabling "Re-run with debug logging" exposed the Proxmox token, AWS keys, Telegram token, and Grafana password in plaintext. Fix: `::add-mask::` immediately after decrypting each secret.

**Remediation:** AWS credentials were rotated after confirming exposure in retained workflow logs; Age, Telegram, and SSH credentials were assessed as not retrievable from any surviving log and were left unrotated.

### 4.4 Cascading failures rebuilding the lab from scratch (3 days of debugging)

A chain of 5 failures, each masking the next:

1. The Janitor never destroyed the last node in the list — a file missing a trailing newline silently broke the last iteration of a `while read` loop.
2. Python bootstrap on Alpine failed silently because `failed_when: false` forced a reported success regardless of the actual outcome.
3. Terraform marked `apply` as complete as soon as the Proxmox API confirmed resource creation, without waiting for the internal OS to actually have network and SSH ready.
4. Ansible's connectivity check (`wait_for_connection`) had a circular dependency with Python on Alpine: it needed Python to confirm the connection, but needed the connection to install Python.
5. Ansible logs went completely silent for 20+ minutes because command substitution (`$(...)`) doesn't stream anything until the command finishes — making "progressing slowly" indistinguishable from "actually hung."

**Cross-cutting lesson, explicitly documented by the project's own author:** all 7 incidents from these days share the same anatomy — an error-handling layer reporting success, silence, or a generic message, while the real cause lived one or two levels below. The design pattern to avoid: optimizing for "the pipeline looking green" instead of "if an error exists, it's immediately visible."

### 4.5 Contract stress-testing methodology (YAML fuzzing)

Incremental iteration (v1.0 → v2.3) deliberately injecting errors one at a time confirmed 12 classes of violations correctly caught by the validator (IP/VMID uniqueness, per-node storage, disk format and minimums, aggregate RAM/CPU budgets, an ephemeral-resource sub-budget). Two semantic validation gaps with no blocking behavior were identified (`estado` enum, `gateway` coherence) and left in the backlog.

### 4.6 A false alarm validated with evidence (good methodology practice)

A Node Exporter package-name bug was suspected in Alpine after observing a hang. A later run proved the command was correct and the hang was a transient event (I/O contention in `apk`'s solver). **No change was applied** — an explicitly documented example of not modifying working code without solid evidence.

### 4.7 Terraform's remote-exec provisioner blocked by the SDN firewall itself

**Symptom:** during a full-cycle stress test with 10 non-core resources, 8 of them failed with `remote-exec provisioner error / dial tcp <ip>:22: i/o timeout`, while 2 succeeded.

**Root cause:** not a bug — the 2 resources that succeeded were the only 2 that had explicitly declared `puerto: 22` in `firewall_externo`. The SDN firewall on `doom-gateway` governs all forwarded traffic into the LAN, including from the command station/CI runner running Terraform itself — there is no implicit allowance for the provisioning tool. Confirmed as the deny-by-default model working exactly as designed, just not accounted for in the manifest.

**Fix:** no code change. Every VM/LXC that needs Terraform's `remote-exec` to confirm SSH readiness must declare `puerto: 22` (`tcp`) in `firewall_externo` — now a documented schema requirement in the README.

### 4.8 `pveproxy`'s own watchdog killing the API mid-deploy under stress-test load

**Symptom:** immediately after a full `janitor` cleanup, re-running a full 10-resource `terraform apply` failed with `Error: error creating LXC container: 595 Connection refused` on 6 of the 10 resources — a transport-level error, distinct from the timeout/EOF errors seen earlier in the same test cycle.

**Investigation:** `journalctl -u pveproxy -u pvedaemon` on both nodes showed `pveproxy-watchdog: pveproxy not responding, restarting...` on **both** `makima` and `reze`, twice within 5 minutes, timestamped exactly inside the failure window. No `apt`/`logrotate`/`pve-daily-update` timer was scheduled anywhere near that time on either node — ruled out as a coincidence with scheduled maintenance.

**Root cause:** Proxmox's own internal watchdog restarted `pveproxy` on both nodes because the sustained concurrent load from the stress test (VM cloning, disk resizing, CT/VM starts, and — separately — the Telmate provider re-sending a full config `update` on every apply, even for unchanged VMs) made `pveproxy` stop responding to its own health checks. Any Terraform API call landing in the brief window while `pveproxy` was being killed and restarted got `Connection refused`. `-parallelism=3` (already reduced from Terraform's default of 10 after an earlier incident in the same test cycle) was still not conservative enough for this specific combination of operations on an 8GB-per-node cluster.

**Fix:** further reduced Terraform's apply parallelism in `orchestrator.sh` (`-parallelism=2`), tuned empirically against the cluster's real observed ceiling rather than a guessed value. Retrying the same apply after the parallelism change succeeded cleanly.

### 4.9 A fourth, undocumented self-healing layer: `pveproxy-watchdog.sh`

**Symptom:** `Connection refused` errors on `terraform apply` persisted even after capping parallelism to 2, with no correlation to actual cluster load — `pveproxy`/`pvedaemon` showed clean `Stopping → Stopped → Starting → Started` cycles (not crashes, not the Proxmox-native watchdog) on both nodes, synchronized to nearly the same second, every 5 minutes.

**Investigation:** `journalctl -u pveproxy` (filtered to the systemd unit) showed nothing explaining the restarts, because the actual trigger logs under a different syslog identifier entirely. `crontab -l -u root` revealed a previously undocumented script on both nodes:

```
*/5 * * * * /usr/local/bin/pveproxy-watchdog.sh
```

```bash
RESPONSE=$(curl -sk --max-time 5 https://127.0.0.1:8006/api2/json/version)
if ! echo "$RESPONSE" | grep -q "version"; then
    systemctl restart pvedaemon
    systemctl restart pveproxy
fi
```

**Root cause:** a fourth self-healing layer, separate from the three already documented in 1.2 and 1.5 (Grafana/VictoriaMetrics for ephemeral resources, `notify.sh` on the Raspberry Pi for physical infra), installed on `makima` and `reze` directly at some undetermined earlier point in the project — likely during one of the cascading-failure debugging sessions in 4.4 — and never carried into this document's architecture inventory. Its 5-second health-check timeout was too aggressive for the sustained API load of a full-cycle `terraform apply`: legitimate slowness under load was misread as `pveproxy` being down, triggering a restart that then caused real `Connection refused` errors for Terraform's in-flight requests — a self-inflicted failure loop.

**Fix:** increased the health-check timeout (`--max-time 5` → `20`) and added a second confirmation check 5 seconds later before restarting, so a single slow response under real load no longer triggers an unnecessary restart, while a genuine outage is still caught and healed within ~30 seconds.


---

*For the current production architecture, CI/CD pipeline, and quick start instructions, see the main [README](../README.md).*
