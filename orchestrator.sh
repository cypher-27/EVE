#!/bin/bash

# ==============================================================================
# EVE Orchestrator - The Grand Director (Modular CI/CD Version)
# ==============================================================================

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Seguridad SSH
export ANSIBLE_HOST_KEY_CHECKING=False

# --- DETECCIÓN DE ENTORNO (CI/CD) ---
if [[ "$GITHUB_REF" == *"refs/heads/main"* ]]; then
    export TF_VAR_eve_env="main"
    echo -e "${CYAN}[*] Entorno detectado: MAIN (Producción - SSD ZFS)${NC}"
else
    export TF_VAR_eve_env="dev"
    echo -e "${YELLOW}[*] Entorno detectado: DEV (Efímero - HDD)${NC}"
fi

# --- DIRECTORIO BASE (para volver siempre aquí) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- VERIFICACIÓN DE DEPENDENCIAS ---
check_dependencies() {
    local missing=()
    for cmd in terraform ansible-playbook sops python3 nc curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}[ERROR] Faltan dependencias: ${missing[*]}${NC}"
        exit 1
    fi
}

# --- VALIDACIÓN DE ARCHIVOS REQUERIDOS ---
check_required_files() {
    if [ ! -f "lab-state.yaml" ]; then
        echo -e "${RED}[ERROR] No se encuentra lab-state.yaml${NC}"
        exit 1
    fi
    if [ ! -f "secrets.enc.env" ]; then
        echo -e "${RED}[ERROR] No se encuentra secrets.enc.env${NC}"
        exit 1
    fi
}

# --- PROCESAMIENTO DE ARGUMENTOS ---
ACTION="apply"
FORCE=false
STAGE="all"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --destroy) ACTION="destroy" ;;
        --plan) ACTION="plan" ;;
        --force) FORCE=true ;;
        --stage-validate) STAGE="validate" ;;
        --stage-firewall) STAGE="firewall" ;;
        --stage-infra) STAGE="infra" ;;
        --stage-config) STAGE="config" ;;
        --stage-all) STAGE="all" ;;
        *)
            echo -e "${RED}[ERROR] Argumento desconocido: $1${NC}"
            echo "Uso: $0 [--destroy] [--plan] [--force]"
            echo "     $0 --stage-validate|--stage-firewall|--stage-infra|--stage-config"
            exit 1
            ;;
    esac
    shift
done

# Variables de seguimiento
CURRENT_STEP="Inicialización"
IN_PROGRESS=true
STATE_FILE="/tmp/eve-orchestrator-state-$(whoami).env"

# Cargar estado previo si existe (para etapas separadas)
if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    echo -e "${CYAN}[*] Estado previo cargado: TERRAFORM_APPLIED=$TERRAFORM_APPLIED${NC}"
fi

# Valores por defecto si no hay estado previo
TERRAFORM_APPLIED=${TERRAFORM_APPLIED:-false}
SDN_APPLIED=${SDN_APPLIED:-false}

# Función para guardar estado
save_state() {
    echo "TERRAFORM_APPLIED=$TERRAFORM_APPLIED" > "$STATE_FILE"
    echo "SDN_APPLIED=$SDN_APPLIED" >> "$STATE_FILE"
}

# Función para limpiar estado
clear_state() {
    rm -f "$STATE_FILE" 2>/dev/null
}

# --- FUNCIONES DE SOPORTE ---
send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        # Usar printf para interpretar \n correctamente
        local formatted_msg
        formatted_msg=$(printf '%b' "*EVE Report*: ${message}")
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${formatted_msg}" -d parse_mode="Markdown" > /dev/null
    fi
}

handle_error() {
    local step="$1"
    local error_log="$2"
    cd "$SCRIPT_DIR"
    echo -e "${RED}[ERROR] Fallo en: ${step}${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}${error_log}${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    send_telegram "❌ *ERROR CRÍTICO* en etapa: \`${step}\`\n\n⚠ *Detalle:*\n\`\`\`${error_log}\`\`\`"
    exit 1
}

wait_for_ssh() {
    local ip=$1

    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${YELLOW}[!] IP inválida detectada: $ip (saltando)${NC}"
        return
    fi

    echo -e "${GREEN}Esperando SSH en $ip...${NC}"
    echo -e "${CYAN}[*] Esperando 10s iniciales para boot...${NC}"
    sleep 10

    local max_retries=90
    local count=0

    until nc -z -w5 "$ip" 22 2>/dev/null; do
        echo -n "."
        sleep 2
        ((count++))
        if [ $count -ge $max_retries ]; then
            echo -e "\n${RED}[!] Timeout: La IP $ip no respondió en 3 minutos.${NC}"
            echo -e "${YELLOW}[!] Verificando si la IP es alcanzable...${NC}"
            ping -c 1 "$ip" 2>/dev/null && echo -e "${YELLOW}[!] La IP responde a ping pero no a SSH${NC}" || echo -e "${RED}[!] La IP no responde ni a ping${NC}"
            handle_error "Espera de SSH" "La VM $ip no levantó el puerto 22."
        fi
    done

    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" > /dev/null 2>&1
    echo -e "${GREEN}✓ SSH disponible en $ip${NC}"
}

# --- FUNCIONES DE TERRAFORM ---
terraform_init() {
    echo -e "${CYAN}[*] Inicializando Terraform...${NC}"
    cd "$SCRIPT_DIR/terraform" || handle_error "Navegación" "No se puede acceder al directorio terraform/"

    # State separado por entorno: dev o main
    TF_INIT_OUTPUT=$(terraform init -input=false \
        -backend-config="key=lab/${TF_VAR_eve_env}/terraform.tfstate" 2>&1)

    if [ $? -ne 0 ]; then
        handle_error "Terraform Init" "$TF_INIT_OUTPUT"
    fi
    cd "$SCRIPT_DIR"
}

# --- CLEANUP CON ROLLBACK GRANULAR ---
cleanup() {
    local exit_code=$?

    # Solo ejecutar rollback si hay error real (exit_code != 0)
    if [ "$IN_PROGRESS" = true ] && [ "$exit_code" -ne 0 ] && [ "$ACTION" != "plan" ] && [ "$STAGE" != "validate" ]; then
        echo -e "\n${RED}[!] ERROR DETECTADO (Código: $exit_code)${NC}"
        echo -e "${YELLOW}[!] Etapa fallida: $CURRENT_STEP${NC}"

        # --- ROLLBACK AUTOMÁTICO ---
        if [ "$TERRAFORM_APPLIED" = true ]; then
            echo -e "${YELLOW}[!] Terraform ya había aplicado cambios. Ejecutando rollback automático...${NC}"
            send_telegram "🔄 *ROLLBACK*: Destruyendo infraestructura por error en \`${CURRENT_STEP}\`..."
            cd "$SCRIPT_DIR/terraform" 2>/dev/null
            terraform destroy -auto-approve 2>&1
            cd "$SCRIPT_DIR"
            echo -e "${YELLOW}[!] Rollback completado. Infraestructura destruida.${NC}"
        elif [ "$SDN_APPLIED" = true ]; then
            echo -e "${YELLOW}[!] SDN había sido configurado. Limpiando reglas de firewall...${NC}"
            ansible-playbook -i localhost, ansible/sdn-gateway/cleanup-firewall.yml > /dev/null 2>&1 || true
            echo -e "${YELLOW}[!] Reglas de firewall limpiadas.${NC}"
        fi

        # Limpiar archivo de estado
        clear_state

        local rollback_status="➖ No necesario"
        [ "$TERRAFORM_APPLIED" = true ] && rollback_status="✅ Infraestructura destruida"
        [ "$SDN_APPLIED" = true ] && [ "$TERRAFORM_APPLIED" = false ] && rollback_status="✅ Firewall limpiado"

        local msg="⚠ *EJECUCIÓN FALLIDA*\n\n📍 *Etapa:* \`$CURRENT_STEP\`\n🚫 *Exit code:* $exit_code\n🔄 *Rollback:* $rollback_status"
        send_telegram "$msg"
    fi

    # Siempre limpiar estado al salir exitosamente
    if [ "$exit_code" -eq 0 ]; then
        clear_state
    fi

    IN_PROGRESS=false
    exit $exit_code
}

trap cleanup EXIT SIGINT SIGTERM

# ==============================================================================
# ETAPAS MODULARES
# ==============================================================================

stage_validate() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[ETAPA: VALIDATE] Validando estado del sistema${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    CURRENT_STEP="Verificación de Dependencias"
    check_dependencies
    echo -e "${GREEN}✓ Dependencias verificadas${NC}"

    CURRENT_STEP="Verificación de Archivos"
    check_required_files
    echo -e "${GREEN}✓ Archivos requeridos presentes${NC}"

    CURRENT_STEP="Carga de Secretos"
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "${CYAN}[*] Secretos no detectados. Cargando vía SOPS...${NC}"
        source <(sops -d secrets.enc.env) || handle_error "Carga de Secretos" "No se pudo desencriptar secrets.enc.env"
    fi
    echo -e "${GREEN}✓ Secretos cargados${NC}"

    CURRENT_STEP="Validación de Contrato (validator.py)"
    python3 validator.py || handle_error "Validación de Contrato" "El lab-state.yaml viola las leyes del cluster."
    echo -e "${GREEN}✓ Contrato validado${NC}"

    CURRENT_STEP="Terraform Init + Validate"
    terraform_init
    cd "$SCRIPT_DIR/terraform"
    TF_VALIDATE_OUTPUT=$(terraform validate 2>&1)
    if [ $? -ne 0 ]; then
        handle_error "Linting Terraform" "$TF_VALIDATE_OUTPUT"
    fi
    cd "$SCRIPT_DIR"
    echo -e "${GREEN}✓ Terraform validado${NC}"

    CURRENT_STEP="Linting Ansible"
    ansible-playbook ansible/sdn-gateway/deploy-firewall.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible SDN" "Error en playbook de firewall"
    ansible-playbook ansible/node-config/setup_base.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible Node" "Error en playbook de configuración"
    ansible-playbook ansible/monitor/setup_monitor.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible Monitor" "Error en playbook de monitoreo"
    echo -e "${GREEN}✓ Ansible validado${NC}"

    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[ETAPA: VALIDATE] ✓ Completada exitosamente${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

stage_firewall() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[ETAPA: FIREWALL] Configurando SDN Gateway${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    # Cargar secretos si no están presentes (para notificaciones de error)
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "${CYAN}[*] Cargando secretos para notificaciones...${NC}"
        source <(sops -d secrets.enc.env) || handle_error "Carga de Secretos" "No se pudo desencriptar secrets.enc.env"
    fi

    CURRENT_STEP="Configuración de Firewall SDN"
    echo -e "${CYAN}[*] Aplicando reglas de firewall en doom-gateway...${NC}"
    ansible-playbook -i localhost, ansible/sdn-gateway/deploy-firewall.yml > /dev/null 2>&1 || handle_error "Ansible SDN" "Fallo en aplicación de reglas de firewall."
    SDN_APPLIED=true
    save_state
    echo -e "${GREEN}✓ Reglas de firewall aplicadas${NC}"

    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[ETAPA: FIREWALL] ✓ Completada exitosamente${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

stage_infra() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[ETAPA: INFRA] Desplegando infraestructura en Proxmox${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    # Cargar secretos si no están presentes (necesarios para backend S3 de Terraform)
    if [ -z "$AWS_ACCESS_KEY_ID" ]; then
        echo -e "${CYAN}[*] Cargando secretos para backend Terraform...${NC}"
        source <(sops -d secrets.enc.env) || handle_error "Carga de Secretos" "No se pudo desencriptar secrets.enc.env"
    fi

    # Terraform Init (siempre necesario)
    terraform_init

    CURRENT_STEP="Despliegue Terraform"
    echo -e "${CYAN}[*] Ejecutando terraform apply...${NC}"
    send_telegram "🚀 Iniciando despliegue de infraestructura..."
    cd "$SCRIPT_DIR/terraform" || handle_error "Navegación" "No se puede acceder al directorio terraform/"
    TF_OUTPUT=$(terraform apply -auto-approve 2>&1)
    if [ $? -ne 0 ]; then
        if echo "$TF_OUTPUT" | grep -q "Error acquiring the state lock"; then
            handle_error "Terraform Lock" "State bloqueado por otro proceso. Espera o libera el lock manualmente."
        fi
        handle_error "Terraform Apply" "$TF_OUTPUT"
    fi
    TERRAFORM_APPLIED=true
    save_state
    cd "$SCRIPT_DIR"
    echo -e "${GREEN}✓ Infraestructura desplegada${NC}"

    CURRENT_STEP="Espera de Conectividad SSH"
    echo -e "${CYAN}[*] Comprobando conectividad de las VMs/LXCs...${NC}"
    VMS_IPS=$(python3 -c "
import yaml
try:
    with open('lab-state.yaml') as f:
        d = yaml.safe_load(f)
        for env in d.get('entornos', []):
            if env.get('tipo') in ['vm', 'lxc'] and env.get('estado') == 'presente':
                if 'red' in env and 'ip' in env['red']:
                    print(env['red']['ip'].split('/')[0])
except Exception:
    pass
" 2>/dev/null)

    if [ ! -z "$VMS_IPS" ]; then
        for ip in $VMS_IPS; do wait_for_ssh "$ip"; done
        echo -e "${CYAN}[*] Estabilizando servicios (30s)...${NC}"
        sleep 30
    fi
    echo -e "${GREEN}✓ Conectividad SSH verificada${NC}"

    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[ETAPA: INFRA] ✓ Completada exitosamente${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

stage_config() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[ETAPA: CONFIG] Configurando software${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

    # Cargar secretos si no están presentes (para notificaciones de error)
    # Nota: Los playbooks usan lookup directo a secrets.enc.yaml
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "${CYAN}[*] Cargando secretos para notificaciones...${NC}"
        source <(sops -d secrets.enc.env) || handle_error "Carga de Secretos" "No se pudo desencriptar secrets.enc.env"
    fi

    CURRENT_STEP="Configuración Base (setup_base.yml)"
    echo -e "${CYAN}[*] Aplicando configuración base a los nodos...${NC}"
    NODE_OUTPUT=$(ansible-playbook -i localhost, ansible/node-config/setup_base.yml 2>&1)
    if [ $? -ne 0 ]; then
        handle_error "Ansible Node Config" "$NODE_OUTPUT"
    fi
    echo -e "${GREEN}✓ Configuración base aplicada${NC}"

    CURRENT_STEP="Configuración de Monitoreo (setup_monitor.yml)"
    echo -e "${CYAN}[*] Configurando stack de monitoreo...${NC}"
    MONITOR_OUTPUT=$(ansible-playbook -i localhost, ansible/monitor/setup_monitor.yml 2>&1)
    if [ $? -ne 0 ]; then
        handle_error "Ansible Monitor Config" "$MONITOR_OUTPUT"
    fi
    echo -e "${GREEN}✓ Monitoreo configurado${NC}"

    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[ETAPA: CONFIG] ✓ Completada exitosamente${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

# ==============================================================================
# LÓGICA DE EJECUCIÓN PRINCIPAL
# ==============================================================================

# --- MODO DESTROY ---
if [ "$ACTION" == "destroy" ]; then
    CURRENT_STEP="Destrucción"
    if [ "$FORCE" = false ]; then
        echo -e "${RED}⚠ PELIGRO: Para destruir sin confirmación debes usar --force.${NC}"
        exit 1
    fi

    send_telegram "🧹 *AVISO*: Iniciando destrucción de infraestructura..."

    echo -e "${GREEN}[1/3] Inicializando Terraform...${NC}"
    terraform_init

    echo -e "${GREEN}[2/3] Ejecutando Terraform Destroy...${NC}"
    cd "$SCRIPT_DIR/terraform" || handle_error "Navegación" "No se puede acceder al directorio terraform/"
    TF_DESTROY=$(terraform destroy -auto-approve 2>&1)
    if [ $? -ne 0 ]; then
        if echo "$TF_DESTROY" | grep -q "Error acquiring the state lock"; then
            handle_error "Terraform Lock" "State bloqueado. Espera o libera el lock manualmente."
        fi
        handle_error "Terraform Destroy" "$TF_DESTROY"
    fi
    cd "$SCRIPT_DIR"

    echo -e "${GREEN}[3/3] Limpiando reglas de firewall...${NC}"
    ansible-playbook -i localhost, ansible/sdn-gateway/cleanup-firewall.yml > /dev/null 2>&1 || true

    IN_PROGRESS=false
    clear_state
    echo -e "${GREEN}¡Laboratorio destruido con éxito!${NC}"
    send_telegram "✅ *LABORATORIO DESTRUIDO*."
    exit 0
fi

# --- MODO PLAN ---
if [ "$ACTION" == "plan" ]; then
    CURRENT_STEP="Terraform Plan"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}[MODO PLAN] Solo lectura, no se aplicarán cambios.${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

    check_dependencies
    check_required_files
    python3 validator.py || exit 1
    terraform_init
    cd "$SCRIPT_DIR/terraform"
    terraform plan
    cd "$SCRIPT_DIR"

    IN_PROGRESS=false
    clear_state
    exit 0
fi

# --- MODO STAGE (Ejecución Modular) ---
case "$STAGE" in
    validate)
        stage_validate
        ;;
    firewall)
        stage_firewall
        ;;
    infra)
        stage_infra
        ;;
    config)
        stage_config
        ;;
    all)
        # Ejecutar todas las etapas en orden
        stage_validate
        stage_firewall
        stage_infra
        stage_config

        # Finalización
        IN_PROGRESS=false
        clear_state
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✅ DESPLIEGUE COMPLETO${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        send_telegram "✅ *DESPLIEGUE COMPLETO Y APLICADO*"
        ;;
esac

exit 0
