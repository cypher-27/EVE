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

# --- AUTO-LOAD SECRETS ---
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    echo -e "${GREEN}[*] Secretos no detectados. Cargando vía SOPS...${NC}"
    source <(sops -d secrets.enc.env) || handle_error "Carga de Secretos" "No se pudo desencriptar secrets.enc.env"
fi

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
    
    # Limpiamos la IP de known_hosts para evitar el error de cambio de llaves
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" > /dev/null 2>&1
    echo -e "${GREEN} ¡Listo y purgado!${NC}"
}

# ==============================================================================
# LÓGICA DE EJECUCIÓN PRINCIPAL
# ==============================================================================

case "$1" in
    --destroy)
        echo -e "${RED}⚠️  PELIGRO: Vas a destruir TODA la infraestructura de EVE Edge.${NC}"
        read -p "¿Estás totalmente seguro? (y/n): " confirm
        if [[ $confirm != [yY] ]]; then 
            echo "Operación cancelada."
            exit 0
        fi

        send_telegram "💀 *AVISO*: Iniciando destrucción total del laboratorio..."

        # 1. DESTRUCCIÓN DE INFRAESTRUCTURA (TERRAFORM) PRIMERO
        echo -e "${GREEN}[1/2] Ejecutando Terraform Destroy...${NC}"
        cd terraform
        TF_DESTROY=$(terraform destroy -auto-approve 2>&1)
        if [ $? -ne 0 ]; then
            if echo "$TF_DESTROY" | grep -q "Error acquiring the state lock"; then
                echo -e "${RED}[!] BLOQUEO DE ESTADO DETECTADO.${NC}"
                handle_error "Terraform Lock" "DynamoDB ha bloqueado la ejecución (Apply o Destroy en curso). Libera el lock manualmente si es un error."
            else
                echo -e "${RED}--- LOG DE ERROR DE TERRAFORM ---${NC}"
                echo "$TF_DESTROY"
                echo -e "${RED}---------------------------------${NC}"
                handle_error "Terraform Destroy" "Error al destruir la infraestructura. Revisa el log en la terminal."
            fi
        fi
        cd ..

        # 2. LIMPIEZA DE RED (SDN) AL FINAL
        echo -e "${GREEN}[2/2] Limpiando reglas de firewall (Conservando acceso a físicos)...${NC}"
        ansible-playbook -i localhost, ansible/sdn-gateway/cleanup-firewall.yml > /dev/null
        if [ $? -ne 0 ]; then
            handle_error "Limpieza SDN" "Terraform terminó, pero falló la limpieza de iptables en el Gateway."
        fi
        
        echo -e "${GREEN}¡Laboratorio destruido con éxito!${NC}"
        send_telegram "💀 *LABORATORIO DESTRUIDO*
La infraestructura de VMs ha sido eliminada y el firewall purgado."
        exit 0
        ;;
    *)

        # --- FLUJO NORMAL DE DESPLIEGUE ---
        
        # --- 1. PRE-FLIGHT CHECKS ---
        echo -e "${GREEN}[1/5] Ejecutando Linting y Sintaxis...${NC}"
        (cd terraform && terraform validate) > /dev/null || handle_error "Linting Terraform" "Error en .tf"
        ansible-playbook ansible/sdn-gateway/deploy-firewall.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible SDN" "Error en red"
        ansible-playbook ansible/node-config/setup_base.yml --syntax-check > /dev/null 2>&1 || handle_error "Linting Ansible Node" "Error en config"

        # --- 2. RED (ANSIBLE SDN) PRIMERO ---
        echo -e "${GREEN}[2/5] Configurando Firewall en SDN Gateway...${NC}"
        SDN_OUTPUT=$(ansible-playbook -i localhost, ansible/sdn-gateway/deploy-firewall.yml 2>&1)
        if [ $? -ne 0 ]; then
            echo "$SDN_OUTPUT"
            handle_error "Ansible SDN" "Fallo en la aplicación de red. Revisa los logs arriba."
        fi

        # --- 3. INFRAESTRUCTURA (TERRAFORM) DESPUÉS ---
        echo -e "${GREEN}[3/5] Desplegando en Proxmox con Terraform...${NC}"
        send_telegram "🚀 Iniciando despliegue de infraestructura..."
        cd terraform
        TF_OUTPUT=$(terraform apply -auto-approve 2>&1)
        if [ $? -ne 0 ]; then
            if echo "$TF_OUTPUT" | grep -q "Error acquiring the state lock"; then
                echo -e "${RED}[!] BLOQUEO DE ESTADO DETECTADO.${NC}"
                handle_error "Terraform Lock" "DynamoDB ha bloqueado la ejecución. Hay otro proceso corriendo o un candado huérfano. Usa 'terraform force-unlock' si es necesario."
            else
                echo -e "${RED}--- LOG DE ERROR DE TERRAFORM ---${NC}"
                echo "$TF_OUTPUT"
                echo -e "${RED}---------------------------------${NC}"
                handle_error "Terraform Apply" "Error en el despliegue. Revisa el log en la terminal."
            fi
        fi
        cd ..

        # --- 4. ESPERA INTELIGENTE (WAIT FOR SSH) ---
        echo -e "${GREEN}[4/5] Comprobando conectividad de las VMs...${NC}"
        VMS_IPS=$(python3 -c "
import yaml
with open('lab-state.yaml') as f:
    d = yaml.safe_load(f)
    for env in d.get('entornos', []):
        if env.get('tipo', 'vm') in ['vm', 'lxc'] and env.get('estado') == 'presente':
            print(env['red']['ip'].split('/')[0])
" 2>/dev/null)

        if [ -z "$VMS_IPS" ]; then
            echo "No hay VMs o LXCs nuevas para esperar."
        else
            for ip in $VMS_IPS; do
                wait_for_ssh "$ip"
            done
            echo -e "${GREEN}[*] Estabilizando servicios internos (30s)...${NC}"
            sleep 30
        fi

        # --- 5. CONFIGURACIÓN (ANSIBLE NODES) ---
        echo -e "${GREEN}[5/5] Configurando Software y Roles...${NC}"
        NODE_OUTPUT=$(ansible-playbook -i localhost, ansible/node-config/setup_base.yml 2>&1)
        if [ $? -ne 0 ]; then
            echo -e "${RED}--- LOG DE ERROR DE ANSIBLE (INVESTIGACIÓN) ---${NC}"
            echo "$NODE_OUTPUT"
            echo -e "${RED}-----------------------------------------------${NC}"
            handle_error "Ansible Node Config" "Fallo en la configuración base. Revisa el log arriba."
        fi

        # --- FINALIZACIÓN ---
        echo -e "${GREEN}¡Despliegue Completo!${NC}"
        send_telegram "✅ *DESPLIEGUE EXITOSO*
La infraestructura está arriba, la red configurada y el software instalado de acuerdo al estado maestro."
        ;;
esac

