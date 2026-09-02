#!/bin/bash
set -euo pipefail

# ==============================================================================
# EVE Orchestrator - Modular CI/CD Pipeline
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

export ANSIBLE_HOST_KEY_CHECKING=False

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- ARGUMENTS ---
ACTION="apply"
FORCE=false
STAGE="all"
TARGET_RESOURCE=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --destroy)        ACTION="destroy" ;;
        --plan)           ACTION="plan"    ;;
	--apply)          ACTION="apply"   ;;
        --force)          FORCE=true       ;;
        --destroy-target)  ACTION="destroy-target"; TARGET_RESOURCE="$2"; shift ;;
        --stage-validate) STAGE="validate" ;;
        --stage-firewall) STAGE="firewall" ;;
        --stage-infra)    STAGE="infra"    ;;
        --stage-config)   STAGE="config"   ;;
        --stage-all)      STAGE="all"      ;;
        *)
            echo -e "${RED}[ERROR] Unknown argument: $1${NC}"
            echo "Usage: $0 [--destroy --force] [--plan] [--apply] [--destroy-target <name>]"
            echo "       $0 [--stage-validate|--stage-firewall|--stage-infra|--stage-config|--stage-all]"
            exit 1
            ;;
    esac
    shift
done

# --- EXECUTION STATE ---
CURRENT_STEP="Initialization"
IN_PROGRESS=true
STATE_FILE="/tmp/eve-orchestrator-state-$(whoami).env"
TERRAFORM_APPLIED=false
SDN_APPLIED=false

if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    echo -e "${CYAN}[*] Previous state loaded: TERRAFORM_APPLIED=$TERRAFORM_APPLIED${NC}"
fi

save_state()  { echo -e "TERRAFORM_APPLIED=$TERRAFORM_APPLIED\nSDN_APPLIED=$SDN_APPLIED" > "$STATE_FILE"; }
clear_state() { rm -f "$STATE_FILE" 2>/dev/null; }

# --- HELPERS ---
load_secrets() {
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
        echo -e "${CYAN}[*] Loading secrets via SOPS...${NC}"
        source <(sops -d secrets.enc.yaml | python3 -c "
import sys, yaml
for k, v in yaml.safe_load(sys.stdin).items():
    print(f\"export {k.upper()}='{v}'\")
") || { echo -e "${RED}[ERROR] Failed to decrypt secrets.enc.yaml${NC}"; exit 1; }
    fi
}

send_telegram() {
    local message="$1"
    # Callers that already own their own notification flow (e.g. the janitor
    # workflow) can set QUIET_NOTIFY=true to suppress orchestrator-level
    # messages and avoid duplicate/conflicting Telegram notifications.
    if [ "${QUIET_NOTIFY:-false}" = "true" ]; then
        return 0
    fi
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="$(printf '%b' "*EVE*: ${message}")" \
            -d parse_mode="Markdown" > /dev/null
    fi
}

handle_error() {
    local step="$1"
    local detail="$2"
    cd "$SCRIPT_DIR"
    echo -e "${RED}[ERROR] Failed at: ${step}${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}${detail}${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local detail_truncated
    detail_truncated="$(printf '%s' "$detail" | tail -c 3000)"

    send_telegram "❌ *CRITICAL ERROR* at stage: \`${step}\`\n\n\`\`\`${detail_truncated}\`\`\`"
    exit 1
}

wait_for_ssh() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${YELLOW}[!] Invalid IP: $ip — skipping${NC}"
        return
    fi

    echo -e "${CYAN}[*] Waiting for SSH on $ip (initial 30s boot delay)...${NC}"
    sleep 30

    local count=0
    until nc -z -w5 "$ip" 22 2>/dev/null; do
        echo -n "."
        sleep 2
        count=$(( count + 1 ))
        if [ "$count" -ge 60 ]; then
            echo -e "\n${RED}[!] Timeout: $ip did not respond after 2 minutes${NC}"
            ping -c 1 "$ip" 2>/dev/null \
                && echo -e "${YELLOW}[!] Host responds to ping but not SSH${NC}" \
                || echo -e "${RED}[!] Host unreachable${NC}"
            handle_error "SSH Wait" "VM $ip did not bring up port 22."
        fi
    done

    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" > /dev/null 2>&1
    echo -e "${GREEN}✓ SSH ready on $ip${NC}"
}

terraform_init() {
    echo -e "${CYAN}[*] Initializing Terraform (env: ${TF_VAR_eve_env})...${NC}"
    cd "$SCRIPT_DIR/terraform" || handle_error "Navigation" "Cannot access terraform/ directory"
    local output
    output=$(terraform init -input=false \
        -backend-config="key=lab/${TF_VAR_eve_env}/terraform.tfstate" 2>&1) \
        || handle_error "Terraform Init" "$output"
    cd "$SCRIPT_DIR"
}

check_dependencies() {
    local missing=()
    for cmd in terraform ansible-playbook sops python3 nc curl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}[ERROR] Missing dependencies: ${missing[*]}${NC}"
        exit 1
    fi
}

check_required_files() {
    [ -f "lab-state.yaml" ]    || { echo -e "${RED}[ERROR] lab-state.yaml not found${NC}";    exit 1; }
    [ -f "secrets.enc.yaml" ]  || { echo -e "${RED}[ERROR] secrets.enc.yaml not found${NC}";  exit 1; }
}

# --- VENV (for pytest/checkov, without touching the system Python /
# avoids the "externally-managed-environment" lock on recent Fedora/Debian) ---
ensure_venv() {
    if [ ! -d ".venv" ]; then
        echo -e "${CYAN}[*] .venv not found — creating it...${NC}"
        python3 -m venv .venv || handle_error "Venv Setup" "Failed to create .venv (is python3-venv installed?)"
    fi
    .venv/bin/pip install -q -r requirements.txt \
        || handle_error "Venv Setup" "Failed to install requirements.txt into .venv"
}

# --- ROLLBACK ---
cleanup() {
    local exit_code=$?
    if [ "$IN_PROGRESS" = true ] && [ "$exit_code" -ne 0 ] \
        && [ "$ACTION" != "plan" ] && [ "$STAGE" != "validate" ]; then

        echo -e "\n${RED}[!] Error detected (exit code: $exit_code) at: $CURRENT_STEP${NC}"
        local rollback_status="➖ Not needed"

        if [ "$TERRAFORM_APPLIED" = true ]; then
            echo -e "${YELLOW}[!] Rolling back Terraform...${NC}"
            send_telegram "🔄 *ROLLBACK*: Destroying infrastructure after failure at \`${CURRENT_STEP}\`..."
            cd "$SCRIPT_DIR/terraform" 2>/dev/null && terraform destroy -auto-approve 2>&1
            cd "$SCRIPT_DIR"
            rollback_status="✅ Infrastructure destroyed"
        elif [ "$SDN_APPLIED" = true ]; then
            echo -e "${YELLOW}[!] Cleaning up firewall rules...${NC}"
            ansible-playbook -i localhost, ansible/sdn-gateway/cleanup-firewall.yml > /dev/null 2>&1 || true
            rollback_status="✅ Firewall cleaned"
        fi

        clear_state
        send_telegram "⚠ *DEPLOYMENT FAILED*\n\n📍 *Stage:* \`$CURRENT_STEP\`\n🚫 *Exit code:* $exit_code\n🔄 *Rollback:* $rollback_status"
    fi

    [ "$exit_code" -eq 0 ] && clear_state
    IN_PROGRESS=false
    exit "$exit_code"
}

trap cleanup EXIT SIGINT SIGTERM

# ==============================================================================
# STAGES
# ==============================================================================

stage_validate() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[STAGE: VALIDATE]${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    CURRENT_STEP="Dependency Check"
    check_dependencies
    echo -e "${GREEN}✓ Dependencies OK${NC}"

    CURRENT_STEP="Required Files"
    check_required_files
    echo -e "${GREEN}✓ Required files present${NC}"

    CURRENT_STEP="Load Secrets"
    load_secrets
    echo -e "${GREEN}✓ Secrets loaded${NC}"

    CURRENT_STEP="Unit Tests"
    echo -e "${CYAN}[*] Running validator + firewall-template unit tests...${NC}"
    ensure_venv
    .venv/bin/pytest tests/ -v || handle_error "Unit Tests" "pytest suite failed — validator.py or eve-firewall.j2 logic may be broken."
    echo -e "${GREEN}✓ Unit tests passed${NC}"

    CURRENT_STEP="Contract Validation"
    python3 validator.py || handle_error "Contract Validation" "lab-state.yaml violates cluster rules."
    echo -e "${GREEN}✓ Contract valid${NC}"

    CURRENT_STEP="Terraform Validate"
    terraform_init
    cd "$SCRIPT_DIR/terraform"
    local tf_out
    tf_out=$(terraform validate 2>&1) || handle_error "Terraform Validate" "$tf_out"
    cd "$SCRIPT_DIR"
    echo -e "${GREEN}✓ Terraform valid${NC}"

    CURRENT_STEP="Policy Scan"
    echo -e "${CYAN}[*] Running Checkov policy scan...${NC}"
    ensure_venv
    local checkov_out
    checkov_out=$(.venv/bin/checkov -d terraform/ --external-checks-dir custom_checks/ \
        --check CKV_EVE_1 --compact --quiet 2>&1)
    if [ $? -ne 0 ]; then
        handle_error "Policy Scan" "$checkov_out"
    fi
    echo -e "${GREEN}✓ Policy scan passed (CKV_EVE_1: no host-level firewall on Proxmox resources)${NC}"

    CURRENT_STEP="Ansible Lint"
    ansible-playbook ansible/sdn-gateway/deploy-firewall.yml  --syntax-check > /dev/null 2>&1 \
        || handle_error "Ansible Lint" "Syntax error in deploy-firewall.yml"
    ansible-playbook ansible/node-config/setup_base.yml       --syntax-check > /dev/null 2>&1 \
        || handle_error "Ansible Lint" "Syntax error in setup_base.yml"
    ansible-playbook ansible/monitor/setup_monitor.yml        --syntax-check > /dev/null 2>&1 \
        || handle_error "Ansible Lint" "Syntax error in setup_monitor.yml"
    echo -e "${GREEN}✓ Ansible syntax OK${NC}"

    echo -e "${GREEN}[STAGE: VALIDATE] ✓ Done${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

stage_firewall() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[STAGE: FIREWALL]${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    load_secrets

    CURRENT_STEP="SDN Firewall"
    echo -e "${CYAN}[*] Applying firewall rules on doom-gateway...${NC}"
    local sdn_out
    sdn_out=$(ANSIBLE_VERBOSITY=3 ansible-playbook -i localhost, ansible/sdn-gateway/deploy-firewall.yml 2>&1) \
        || handle_error "Ansible SDN" "$(echo "$sdn_out" | tail -80)"
    SDN_APPLIED=true
    save_state
    echo -e "${GREEN}✓ Firewall rules applied${NC}"

    echo -e "${GREEN}[STAGE: FIREWALL] ✓ Done${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

stage_infra() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[STAGE: INFRA]${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    load_secrets
    terraform_init

    CURRENT_STEP="Terraform Apply"
    echo -e "${CYAN}[*] Running terraform apply...${NC}"
    send_telegram "🚀 Starting infrastructure deployment (env: \`${TF_VAR_eve_env}\`)..."
    cd "$SCRIPT_DIR/terraform" || handle_error "Navigation" "Cannot access terraform/ directory"
    local tf_out
    tf_out=$(terraform apply -auto-approve -parallelism=2 2>&1) || {
        echo "$tf_out" | grep -q "Error acquiring the state lock" \
            && handle_error "Terraform Lock" "State locked by another process. Release the lock manually." \
            || handle_error "Terraform Apply" "$tf_out"
    }
    TERRAFORM_APPLIED=true
    save_state
    cd "$SCRIPT_DIR"
    echo -e "${GREEN}✓ Infrastructure deployed${NC}"

    CURRENT_STEP="SSH Connectivity"
    echo -e "${CYAN}[*] Checking SSH connectivity...${NC}"
    local vms_ips
    vms_ips=$(python3 -c "
import yaml
with open('lab-state.yaml') as f:
    d = yaml.safe_load(f)
for e in d.get('entornos', []):
    if e.get('tipo') in ['vm', 'lxc'] and e.get('estado') == 'presente':
        ip = e.get('red', {}).get('ip', '')
        if ip: print(ip.split('/')[0])
" 2>/dev/null)

    if [ -n "$vms_ips" ]; then
        for ip in $vms_ips; do wait_for_ssh "$ip"; done
        echo -e "${CYAN}[*] Stabilizing services (30s)...${NC}"
        sleep 30
    fi
    echo -e "${GREEN}✓ SSH connectivity verified${NC}"

    echo -e "${GREEN}[STAGE: INFRA] ✓ Done${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

stage_config() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[STAGE: CONFIG]${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    load_secrets

    CURRENT_STEP="Base Configuration"
    echo -e "${CYAN}[*] Applying base node configuration...${NC}"
    local node_out
    node_out=$(ansible-playbook -i localhost, ansible/node-config/setup_base.yml 2>&1 | tee /dev/stderr)
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        handle_error "Ansible Node Config" "$node_out"
    fi
    echo -e "${GREEN}✓ Base configuration applied${NC}"

    CURRENT_STEP="Monitoring Stack"
    echo -e "${CYAN}[*] Configuring monitoring stack...${NC}"
    local monitor_out
    monitor_out=$(ansible-playbook -i localhost, ansible/monitor/setup_monitor.yml 2>&1 | tee /dev/stderr)
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        handle_error "Ansible Monitor" "$monitor_out"
    fi
    echo -e "${GREEN}✓ Monitoring configured${NC}"

    echo -e "${GREEN}[STAGE: CONFIG] ✓ Done${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

# ==============================================================================
# MAIN
# ==============================================================================

if [ "$ACTION" = "destroy-target" ]; then
    [ -z "$TARGET_RESOURCE" ] && { echo -e "${RED}[ERROR] --destroy-target requires a resource name${NC}"; exit 1; }

    CURRENT_STEP="Destroy Target: $TARGET_RESOURCE"
    load_secrets
    terraform_init

    # Resolve Terraform address from lab-state.yaml
    RESOURCE_TYPE=$(python3 -c "
import yaml, sys
with open('lab-state.yaml') as f:
    data = yaml.safe_load(f)
for e in data.get('entornos', []):
    if e['nombre'] == sys.argv[1]:
        print(e.get('tipo', 'lxc'))
        sys.exit(0)
print('NOT_FOUND'); sys.exit(1)
" "$TARGET_RESOURCE") || handle_error "Resolve Target" "Resource '$TARGET_RESOURCE' not found in lab-state.yaml"

    if [ "$RESOURCE_TYPE" = "vm" ]; then
        ADDRESS="proxmox_vm_qemu.entorno_vm[\"$TARGET_RESOURCE\"]"
    else
        ADDRESS="proxmox_lxc.entorno_lxc[\"$TARGET_RESOURCE\"]"
    fi

    echo -e "${CYAN}[*] Destroying $RESOURCE_TYPE '$TARGET_RESOURCE' → $ADDRESS${NC}"
    send_telegram "🧹 Destroying \`$TARGET_RESOURCE\` (\`$RESOURCE_TYPE\`)..."

    cd "$SCRIPT_DIR/terraform"
    destroy_out=$(terraform destroy -auto-approve -target="$ADDRESS" 2>&1) || \
        handle_error "Terraform Destroy Target" "$destroy_out"
    cd "$SCRIPT_DIR"

    IN_PROGRESS=false
    clear_state
    echo -e "${GREEN}✓ '$TARGET_RESOURCE' destroyed${NC}"
    send_telegram "✅ \`$TARGET_RESOURCE\` destroyed successfully."
    exit 0
fi

if [ "$ACTION" = "destroy" ]; then
    CURRENT_STEP="Destroy"
    [ "$FORCE" = false ] && { echo -e "${RED}⚠ Use --force to confirm destruction.${NC}"; exit 1; }
    load_secrets
    send_telegram "🧹 *EVE*: Starting infrastructure destruction (env: \`${TF_VAR_eve_env}\`)..."
    echo -e "${GREEN}[1/3] Terraform Init...${NC}"
    terraform_init
    echo -e "${GREEN}[2/3] Terraform Destroy...${NC}"
    cd "$SCRIPT_DIR/terraform" || handle_error "Navigation" "Cannot access terraform/ directory"
    destroy_out=$(terraform destroy -auto-approve 2>&1) || {
        echo "$destroy_out" | grep -q "Error acquiring the state lock" \
            && handle_error "Terraform Lock" "State locked. Release the lock manually." \
            || handle_error "Terraform Destroy" "$destroy_out"
    }
    cd "$SCRIPT_DIR"
    echo -e "${GREEN}[3/3] Cleaning firewall rules...${NC}"
    ansible-playbook -i localhost, ansible/sdn-gateway/cleanup-firewall.yml > /dev/null 2>&1 || true
    IN_PROGRESS=false
    clear_state
    echo -e "${GREEN}✓ Lab destroyed successfully${NC}"
    send_telegram "✅ *Lab destroyed* (env: \`${TF_VAR_eve_env}\`)."
    exit 0
fi

if [ "$ACTION" = "plan" ]; then
    echo -e "${CYAN}[PLAN MODE] Read-only, no changes will be applied.${NC}"
    check_dependencies
    check_required_files
    load_secrets
    python3 validator.py || exit 1
    terraform_init
    cd "$SCRIPT_DIR/terraform" && terraform plan
    cd "$SCRIPT_DIR"
    IN_PROGRESS=false
    clear_state
    exit 0
fi

case "$STAGE" in
    validate) stage_validate ;;
    firewall) stage_firewall ;;
    infra)    stage_infra    ;;
    config)   stage_config   ;;
    all)
        stage_validate
        stage_firewall
        stage_infra
        stage_config
        IN_PROGRESS=false
        clear_state
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✅ DEPLOYMENT COMPLETE (env: ${TF_VAR_eve_env})${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        send_telegram "✅ *DEPLOYMENT COMPLETE* (env: \`${TF_VAR_eve_env}\`)"
        ;;
esac

exit 0
