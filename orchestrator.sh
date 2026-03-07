#!/bin/bash

# ==============================================================================
# EVE Orchestrator - The Grand Director (CI/CD Armored Version)
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
check_dependencies

# --- VALIDACIÓN DE ARCHIVOS REQUERIDOS ---
if [ ! -f "lab-state.yaml" ]; then
    echo -e "${RED}[ERROR] No se encuentra lab-state.yaml${NC}"
    exit 1
fi

if [ ! -f "secrets.enc.env" ]; then
    echo -e "${RED}[ERROR] No se encuentra secrets.enc.env${NC}"
    exit 1
fi

# --- PROCESAMIENTO DE ARGUMENTOS ---
ACTION="apply"
FORCE=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --destroy) ACTION="destroy" ;;
        --plan) ACTION="plan" ;;
        --force) FORCE=true ;;
        *)
            echo -e "${RED}[ERROR] Argumento desconocido: $1${NC}"
            echo "Uso: $0 [--destroy] [--plan] [--force]"
            exit 1
            ;;
    esac
    shift
done

# Variables de seguimiento
CURRENT_STEP="Inicialización"
IN_PROGRESS=true

# --- FUNCIONES DE SOPORTE ---
send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="*EVE Report*: ${message}" -d parse_mode="Markdown" > /dev/null
    fi
}

handle_error() {
    local step="$1"
    local error_log="$2"
    IN_PROGRESS=false # Evitamos doble notificación del trap
    cd "$SCRIPT_DIR"  # Siempre volver al directorio base antes de salir
    echo -e "${RED}[ERROR] Fallo en: ${step}${NC}"
    send_telegram "❌ *ERROR CRÍTICO* en etapa: \`${step}\`\n\n⚠ *Detalle:*\n${error_log}"
    exit 1
}

wait_for_ssh() {
    local ip=$1

    # Validación básica de IP
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${YELLOW}[!] IP inválida detectada: $ip (saltando)${NC}"
        return
    fi

    local max_retries=30
    local count=0
    echo -n -e "${GREEN}Esperando SSH en $ip...${NC}"
    until nc -z -v -w5 "$ip" 22 &>/dev/null; do
        echo -n "."
        sleep 2
        ((count++))
        if [ $count -ge $max_retries ]; then
            echo -e "\n${RED}[!] Timeout: La IP $ip no respondió.${NC}"
            handle_error "Espera de SSH" "La VM $ip no levantó el puerto 22."
        fi
    done
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" > /dev/null 2>&1
    echo -e "${GREEN} ¡Listo y purgado!${NC}"
}

cleanup() {
    local exit_code=$?
    if [ "$IN_PROGRESS" = true ] && [ "$ACTION" != "plan" ]; then
        echo -e "\n${RED}[!] INTERRUPCIÓN DETECTADA (Código: $exit_code)${NC}"
        echo -e "${YELLOW}[!] Etapa interrumpida: $CURRENT_STEP${NC}"
        
        local msg="⚠ *EJECUCIÓN INTERRUMPIDA*\n\n📍 *Etapa:* \`$CURRENT_STEP\`\n🚫 *Estado:* El proceso fue cancelado o falló inesperadamente.\n🔐 *Aviso:* Revisa el State Lock de Terraform."
        send_telegram "$msg"
    fi
    exit $exit_code
}

trap cleanup EXIT SIGINT SIGTERM

# --- AUTO-LOAD SECRETS ---
CURRENT_STEP="Carga de Secretos"
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    echo -e "${GREEN}[*] Secretos no detectados. Cargando vía SOPS...${NC}"
    source <(sops -d secrets.enc.env) || handle_error "Carga de Secretos" "No se pudo desencriptar secrets.enc.env"
fi

# ==============================================================================
# LÓGICA DE EJECUCIÓN PRINCIPAL
# ==============================================================================

if [ "$ACTION" == "destroy" ]; then
    CURRENT_STEP="Destrucción"
    if [ "$FORCE" = false ]; then
        echo -e "${RED}⚠ PELIGRO: Para destruir sin confirmación debes usar --force.${NC}"
        exit 1
    fi

    send_telegram "*AVISO*: Iniciando destrucción de infraestructura..."
    echo -e "${GREEN}[1/2] Ejecutando Terraform Destroy...${NC}"
    cd "$SCRIPT_DIR/terraform" || handle_error "Navegación" "No se puede acceder al directorio terraform/"
    TF_DESTROY=$(terraform destroy -auto-approve 2>&1)
    if [ $? -ne 0 ]; then
        handle_error "Terraform Destroy" "$TF_DESTROY"
    fi
    cd "$SCRIPT_DIR"

    CURRENT_STEP="SDN Cleanup"
    echo -e "${GREEN}[2/2] Limpiando reglas de firewall...${NC}"
    ansible-playbook -i localhost, ansible/sdn-gateway/cleanup-firewall.yml > /dev/null || handle_error "Limpieza SDN" "Fallo en purga de iptables."
    
    IN_PROGRESS=false
    echo -e "${GREEN}¡Laboratorio destruido con éxito!${NC}"
    send_telegram "*LABORATORIO DESTRUIDO*."
    exit 0
fi

if [ "$ACTION" == "plan" ]; then
    CURRENT_STEP="Terraform Plan"
    echo -e "${CYAN}[*] Modo PLAN: Solo lectura, no se aplicarán cambios.${NC}"
    python3 validator.py || { cd "$SCRIPT_DIR"; exit 1; }
    cd "$SCRIPT_DIR/terraform" || { cd "$SCRIPT_DIR"; exit 1; }
    terraform init -input=false -backend-config="dynamodb_table=devilhunters-terraform-lock" > /dev/null 2>&1
    terraform plan
    cd "$SCRIPT_DIR"
    IN_PROGRESS=false
    exit 0
fi

# --- MODO APPLY (Despliegue Normal) ---

# 0. VALIDACIÓN
echo -e "${GREEN}[0/5] Validando recursos del cluster...${NC}"
python3 validator.py || handle_error "Validación de Contrato" "El lab-state.yaml viola las leyes del cluster."

# 1. PRE-FLIGHT CHECKS & INIT
CURRENT_STEP="Pre-flight Checks"
echo -e "${GREEN}[1/5] Sincronizando proveedores y validando sintaxis...${NC}"
cd terraform || handle_error "Navegación" "No se puede acceder al directorio terraform/"
TF_INIT_OUTPUT=$(terraform init -input=false -backend-config="dynamodb_table=devilhunters-terraform-lock" 2>&1)
if [ $? -ne 0 ]; then
    handle_error "Terraform Init" "$TF_INIT_OUTPUT"
fi
TF_VALIDATE_OUTPUT=$(terraform validate 2>&1)
if [ $? -ne 0 ]; then
    handle_error "Linting Terraform" "$TF_VALIDATE_OUTPUT"
fi
cd "$SCRIPT_DIR"
ansible-playbook ansible/sdn-gateway/deploy-firewall.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible SDN" "Error en red"
ansible-playbook ansible/node-config/setup_base.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible Node" "Error en config"

# 2. RED (ANSIBLE SDN)
CURRENT_STEP="Configuración de Red (SDN)"
echo -e "${GREEN}[2/5] Configurando Firewall en SDN Gateway...${NC}"
ansible-playbook -i localhost, ansible/sdn-gateway/deploy-firewall.yml > /dev/null 2>&1 || handle_error "Ansible SDN" "Fallo en aplicación de red."

# 3. INFRAESTRUCTURA (TERRAFORM)
CURRENT_STEP="Despliegue Terraform"
echo -e "${GREEN}[3/5] Desplegando en Proxmox con Terraform...${NC}"
send_telegram "🚀 Iniciando despliegue de infraestructura..."
cd "$SCRIPT_DIR/terraform" || handle_error "Navegación" "No se puede acceder al directorio terraform/"
TF_OUTPUT=$(terraform apply -auto-approve 2>&1)
if [ $? -ne 0 ]; then
    handle_error "Terraform Apply" "$TF_OUTPUT"
fi
cd "$SCRIPT_DIR"

# 4. ESPERA SSH
CURRENT_STEP="Espera de Conectividad (Wait for SSH)"
echo -e "${GREEN}[4/5] Comprobando conectividad de las VMs...${NC}"
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
    echo -e "${GREEN}[*] Estabilizando servicios (30s)...${NC}"
    sleep 30
fi

# 5. CONFIGURACIÓN (ANSIBLE NODES)
CURRENT_STEP="Configuración de Software (Ansible)"
echo -e "${GREEN}[5/5] Configurando Software y Roles...${NC}"

echo -e "${CYAN}[5.1] Aplicando Configuración Base...${NC}"
NODE_OUTPUT=$(ansible-playbook -i localhost, ansible/node-config/setup_base.yml 2>&1)
if [ $? -ne 0 ]; then handle_error "Ansible Node Config" "$NODE_OUTPUT"; fi

echo -e "${CYAN}[5.2] Configurando Monitoreo...${NC}"
MONITOR_OUTPUT=$(ansible-playbook -i localhost, ansible/monitor/setup_monitor.yml 2>&1)
if [ $? -ne 0 ]; then handle_error "Ansible Monitor Config" "$MONITOR_OUTPUT"; fi

# --- FINALIZACIÓN ---
IN_PROGRESS=false
echo -e "${GREEN}¡Despliegue Completo!${NC}"
send_telegram "✅ *DESPLIEGUE COMPLETO Y APLICADO*"

