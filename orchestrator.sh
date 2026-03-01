#!/bin/bash

# ==============================================================================
# EVE Orchestrator - The Grand Director
# ==============================================================================

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Seguridad SSH
export ANSIBLE_HOST_KEY_CHECKING=False

# --- FUNCIONES DE SOPORTE ---

send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="🤖 *EVE Edge Report*: ${message}" -d parse_mode="Markdown" > /dev/null
}

handle_error() {
    local step="$1"
    local error_log="$2"
    echo -e "${RED}[ERROR] Fallo en: ${step}${NC}"
    send_telegram "❌ *ERROR CRÍTICO* en etapa: \`${step}\`
    
⚠️ *Detalle:*
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
            echo -e "\n${RED}[!] Timeout: La IP $ip no respondió tras 60 segundos.${NC}"
            handle_error "Espera de SSH" "La VM $ip no levantó el puerto 22 a tiempo."
        fi
    done
    echo -e "${GREEN} ¡Listo!${NC}"
}

# ==============================================================================
# LÓGICA DE EJECUCIÓN PRINCIPAL
# ==============================================================================

case "$1" in
    --destroy)
        echo -e "${RED}[!] INICIANDO MODO DESTRUCCIÓN...${NC}"
        send_telegram "⚠️ *AVISO*: Iniciando destrucción total del laboratorio."
        # TODO: Añadiremos la lógica de Ansible absent y Terraform destroy aquí
        # después de comprobar que el flujo normal (apply) funciona perfectamente.
        echo "Lógica de destrucción en construcción..."
        exit 0
        ;;
    *)
        # --- FLUJO NORMAL DE DESPLIEGUE ---
        
        # --- 1. PRE-FLIGHT CHECKS ---
        echo -e "${GREEN}[1/5] Ejecutando Linting y Sintaxis...${NC}"
        cd terraform && terraform validate > /dev/null || handle_error "Linting Terraform" "Error de sintaxis en .tf"
        cd ..
        ansible-playbook ansible/sdn-gateway/deploy-firewall.yml --syntax-check > /dev/null || handle_error "Linting Ansible SDN" "Sintaxis incorrecta en red"
        ansible-playbook ansible/node-config/setup_base.yml --syntax-check > /dev/null || handle_error "Linting Ansible Node" "Sintaxis incorrecta en config"

        # --- 2. INFRAESTRUCTURA (TERRAFORM) ---
        echo -e "${GREEN}[2/5] Desplegando en Proxmox con Terraform...${NC}"
        send_telegram "🚀 Iniciando despliegue de infraestructura..."
        cd terraform
        TF_OUTPUT=$(terraform apply -auto-approve 2>&1)
        if [ $? -ne 0 ]; then
            handle_error "Terraform Apply" "${TF_OUTPUT}"
        fi
        cd ..

        # --- 3. RED (ANSIBLE SDN) ---
        echo -e "${GREEN}[3/5] Configurando Firewall en SDN Gateway...${NC}"
        SDN_OUTPUT=$(ansible-playbook -i localhost, ansible/sdn-gateway/deploy-firewall.yml 2>&1)
        if [ $? -ne 0 ]; then
            handle_error "Ansible SDN" "${SDN_OUTPUT}"
        fi

        # --- 4. ESPERA INTELIGENTE (WAIT FOR SSH) ---
        echo -e "${GREEN}[4/5] Comprobando conectividad de las VMs...${NC}"
        # Magia negra: Extraemos las IPs de las VMs 'presentes' directo del YAML usando Python
        VMS_IPS=$(python3 -c "
import yaml
with open('lab-state.yaml') as f:
    d = yaml.safe_load(f)
    for env in d.get('entornos', []):
        if env.get('tipo', 'vm') == 'vm' and env.get('estado') == 'presente':
            print(env['red']['ip'].split('/')[0])
" 2>/dev/null)

        if [ -z "$VMS_IPS" ]; then
            echo "No hay VMs nuevas para esperar."
        else
            for ip in $VMS_IPS; do
                wait_for_ssh "$ip"
            done
        fi

        # --- 5. CONFIGURACIÓN (ANSIBLE NODES) ---
        echo -e "${GREEN}[5/5] Configurando Software y Roles...${NC}"
        NODE_OUTPUT=$(ansible-playbook -i localhost, ansible/node-config/setup_base.yml 2>&1)
        if [ $? -ne 0 ]; then
            handle_error "Ansible Node Config" "${NODE_OUTPUT}"
        fi

        # --- FINALIZACIÓN ---
        echo -e "${GREEN}¡Despliegue Completo!${NC}"
        send_telegram "✅ *DESPLIEGUE EXITOSO*
La infraestructura está arriba, la red configurada y el software instalado."
        ;;
esac

