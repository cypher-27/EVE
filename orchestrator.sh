#!/bin/bash

# ==============================================================================
# EVE Orchestrator - The Grand Director (Armored Version)
# ==============================================================================

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Seguridad SSH
export ANSIBLE_HOST_KEY_CHECKING=False

# Variables de seguimiento
CURRENT_STEP="Inicialización"
IN_PROGRESS=true

# --- FUNCIÓN DE LIMPIEZA Y TRAPS ---
cleanup() {
    local exit_code=$?
    if [ "$IN_PROGRESS" = true ]; then
        echo -e "\n${RED}[!] INTERRUPCIÓN DETECTADA (Código: $exit_code)${NC}"
        echo -e "${YELLOW}[!] Etapa interrumpida: $CURRENT_STEP${NC}"
        
        # Alerta específica por Telegram
        local msg="⚠️ *EJECUCIÓN INTERRUMPIDA*
        
📍 *Etapa:* \`$CURRENT_STEP\`
🚫 *Estado:* El proceso fue cancelado o falló inesperadamente.
🔐 *Aviso:* Es posible que el **State Lock** de Terraform siga activo en DynamoDB."
        
        send_telegram "$msg"
    fi
    exit $exit_code
}

# Capturamos SIGINT (Ctrl+C), SIGTERM (Terminación) y EXIT
trap cleanup EXIT SIGINT SIGTERM

# --- AUTO-LOAD SECRETS ---
CURRENT_STEP="Carga de Secretos"
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    echo -e "${GREEN}[*] Secretos no detectados. Cargando vía SOPS...${NC}"
    source <(sops -d secrets.enc.env) || handle_error "Carga de Secretos" "No se pudo desencriptar secrets.enc.env"
fi

# --- FUNCIONES DE SOPORTE ---

send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="*EVE Report*: ${message}" -d parse_mode="Markdown" > /dev/null
}

handle_error() {
    local step="$1"
    local error_log="$2"
    IN_PROGRESS=false # Evitamos doble notificación del trap
    echo -e "${RED}[ERROR] Fallo en: ${step}${NC}"
    send_telegram "❌ *ERROR CRÍTICO* en etapa: \`${step}\`
    
⚠ *Detalle:*
${error_log}"
    exit 1
}

wait_for_ssh() {
    local ip=$1
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

# ==============================================================================
# LÓGICA DE EJECUCIÓN PRINCIPAL
# ==============================================================================

case "$1" in
    --destroy)
        CURRENT_STEP="Destrucción (Confirmación)"
        echo -e "${RED}⚠️  PELIGRO: Vas a destruir TODA la infraestructura de EVE Edge.${NC}"
        read -p "¿Estás totalmente seguro? (y/n): " confirm
        if [[ $confirm != [yY] ]]; then exit 0; fi

        send_telegram "*AVISO*: Iniciando destrucción total del laboratorio..."

        CURRENT_STEP="Terraform Destroy"
        echo -e "${GREEN}[1/2] Ejecutando Terraform Destroy...${NC}"
        cd terraform
        TF_DESTROY=$(terraform destroy -auto-approve 2>&1)
        if [ $? -ne 0 ]; then
            if echo "$TF_DESTROY" | grep -q "Error acquiring the state lock"; then
                handle_error "Terraform Lock" "DynamoDB bloqueado. Libera el lock manualmente."
            else
                echo "$TF_DESTROY"
                handle_error "Terraform Destroy" "Error al destruir infraestructura."
            fi
        fi
        cd ..

        CURRENT_STEP="SDN Cleanup"
        echo -e "${GREEN}[2/2] Limpiando reglas de firewall (Conservando físicos)...${NC}"
        ansible-playbook -i localhost, ansible/sdn-gateway/cleanup-firewall.yml > /dev/null || handle_error "Limpieza SDN" "Fallo en purga de iptables."
        
        IN_PROGRESS=false # Finalización exitosa
        echo -e "${GREEN}¡Laboratorio destruido con éxito!${NC}"
        send_telegram "*LABORATORIO DESTRUIDO*."
        exit 0
        ;;
    *)
        # --- 1. PRE-FLIGHT CHECKS ---
        CURRENT_STEP="Pre-flight Checks"
        echo -e "${GREEN}[1/5] Ejecutando Linting y Sintaxis...${NC}"
        (cd terraform && terraform validate) > /dev/null || handle_error "Linting Terraform" "Error en .tf"
        ansible-playbook ansible/sdn-gateway/deploy-firewall.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible SDN" "Error en red"
        ansible-playbook ansible/node-config/setup_base.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible Node" "Error en config"

        # --- 2. RED (ANSIBLE SDN) ---
        CURRENT_STEP="Configuración de Red (SDN)"
        echo -e "${GREEN}[2/5] Configurando Firewall en SDN Gateway...${NC}"
        ansible-playbook -i localhost, ansible/sdn-gateway/deploy-firewall.yml > /dev/null 2>&1 || handle_error "Ansible SDN" "Fallo en aplicación de red."

        # --- 3. INFRAESTRUCTURA (TERRAFORM) ---
        CURRENT_STEP="Despliegue Terraform"
        echo -e "${GREEN}[3/5] Desplegando en Proxmox con Terraform...${NC}"
        send_telegram "🚀 Iniciando despliegue de infraestructura..."
        cd terraform
        TF_OUTPUT=$(terraform apply -auto-approve 2>&1)
        if [ $? -ne 0 ]; then
            if echo "$TF_OUTPUT" | grep -q "Error acquiring the state lock"; then
                handle_error "Terraform Lock" "DynamoDB bloqueado. Revisa si hay otro proceso activo."
            else
                echo "$TF_OUTPUT"
                handle_error "Terraform Apply" "Error en el despliegue de Proxmox."
            fi
        fi
        cd ..

        # --- 4. ESPERA SSH ---
        CURRENT_STEP="Espera de Conectividad (Wait for SSH)"
        echo -e "${GREEN}[4/5] Comprobando conectividad de las VMs...${NC}"
        VMS_IPS=$(python3 -c "
import yaml
with open('lab-state.yaml') as f:
    d = yaml.safe_load(f)
    for env in d.get('entornos', []):
        if env.get('tipo', 'vm') in ['vm', 'lxc'] and env.get('estado') == 'presente':
            print(env['red']['ip'].split('/')[0])
" 2>/dev/null)

        if [ ! -z "$VMS_IPS" ]; then
            for ip in $VMS_IPS; do wait_for_ssh "$ip"; done
            echo -e "${GREEN}[*] Estabilizando servicios (30s)...${NC}"
            sleep 30
        fi

        # --- 5. CONFIGURACIÓN (ANSIBLE NODES) ---
        CURRENT_STEP="Configuración de Software (Ansible)"
        echo -e "${GREEN}[5/5] Configurando Software y Roles...${NC}"
        NODE_OUTPUT=$(ansible-playbook -i localhost, ansible/node-config/setup_base.yml 2>&1)
        if [ $? -ne 0 ]; then
            echo "$NODE_OUTPUT"
            handle_error "Ansible Node Config" "Fallo en la configuración base de las VMs."
        fi

        # --- FINALIZACIÓN ---
        IN_PROGRESS=false
        echo -e "${GREEN}¡Despliegue Completo!${NC}"
        send_telegram "✅ *DESPLIEGUE EXITOSO*"
        ;;
esac

