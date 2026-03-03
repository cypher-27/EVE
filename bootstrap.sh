#!/bin/bash
# ==============================================================================
# PROYECTO FÉNIX - EVE Bootstrap Script
# Descripción: Reconstruye la estación de mando desde cero.
# ==============================================================================

set -e # Detener script si hay un error

# Colores para la terminal
VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${AZUL}[*] Iniciando Proyecto Fénix - Bootstrap de EVE...${NC}"

# 1. ACTUALIZACIÓN E INSTALACIÓN BASE
echo -e "${AZUL}[1/6] Actualizando sistema e instalando dependencias base...${NC}"
sudo apt-get update -y
sudo apt-get install -y curl wget gnupg software-properties-common git unzip python3-pip age

# 2. TERRAFORM (HashiCorp Official)
echo -e "${AZUL}[2/6] Verificando Terraform...${NC}"
if ! command -v terraform &> /dev/null; then
    echo "Instalando Terraform..."
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt-get update -y && sudo apt-get install -y terraform
else
    echo -e "${VERDE}✓ Terraform ya está instalado.${NC}"
fi

# 3. ANSIBLE Y COLECCIONES
echo -e "${AZUL}[3/6] Verificando Ansible y Colecciones...${NC}"
if ! command -v ansible &> /dev/null; then
    echo "Instalando Ansible..."
    sudo apt-get install -y ansible
else
    echo -e "${VERDE}✓ Ansible ya está instalado.${NC}"
fi

echo "Instalando dependencias de Ansible (SOPS y General)..."
ansible-galaxy collection install community.general community.sops --force

# 4. SOPS (Mozilla Secret OPerationS)
echo -e "${AZUL}[4/6] Verificando SOPS...${NC}"
if ! command -v sops &> /dev/null; then
    echo "Instalando SOPS..."
    SOPS_VERSION="v3.8.1"
    wget -qO sops https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64
    sudo mv sops /usr/local/bin/sops
    sudo chmod +x /usr/local/bin/sops
else
    echo -e "${VERDE}✓ SOPS ya está instalado.${NC}"
fi

# 5. ZEROTIER (Red de Gestión)
echo -e "${AZUL}[5/6] Verificando puente de red (ZeroTier)...${NC}"
if ! command -v zerotier-cli &> /dev/null; then
    echo "Instalando ZeroTier..."
    curl -s https://install.zerotier.com | sudo bash
else
    echo -e "${VERDE}✓ ZeroTier ya está instalado.${NC}"
fi

read -p "¿Deseas unirte a una red ZeroTier ahora? (y/n): " zt_resp
if [[ "$zt_resp" == "y" || "$zt_resp" == "Y" ]]; then
    read -p "Introduce tu Network ID de ZeroTier: " zt_id
    sudo zerotier-cli join $zt_id
    echo -e "${VERDE}✓ Petición de unión enviada. (Recuerda autorizar el nodo en el portal web).${NC}"
fi

# 6. CONFIGURACIÓN DE IDENTIDAD (AGE KEY)
echo -e "${AZUL}[6/6] Configurando Identidad Criptográfica (Age)...${NC}"
AGE_DIR="$HOME/.config/sops/age"
AGE_FILE="$AGE_DIR/keys.txt"

mkdir -p "$AGE_DIR"

if [ ! -f "$AGE_FILE" ]; then
    echo -e "${ROJO}No se encontró la llave de Age en $AGE_FILE${NC}"
    read -s -p "Pega aquí tu llave PRIVADA de Age (AGE-SECRET-KEY-...) y presiona Enter: " age_key
    echo ""
    if [[ $age_key == AGE-SECRET-KEY-* ]]; then
        echo "$age_key" > "$AGE_FILE"
        chmod 600 "$AGE_FILE"
        echo -e "${VERDE}✓ Llave guardada de forma segura en $AGE_FILE${NC}"
    else
        echo -e "${ROJO}Formato de llave inválido. Deberás configurarla manualmente.${NC}"
    fi
else
    echo -e "${VERDE}✓ Llave de Age detectada.${NC}"
fi

# Exportar variable en el perfil del usuario si no existe
if ! grep -q "SOPS_AGE_KEY_FILE" "$HOME/.bashrc"; then
    echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> "$HOME/.bashrc"
    echo -e "${VERDE}✓ Variable SOPS_AGE_KEY_FILE añadida a .bashrc${NC}"
fi
if [ -f "$HOME/.zshrc" ] && ! grep -q "SOPS_AGE_KEY_FILE" "$HOME/.zshrc"; then
    echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> "$HOME/.zshrc"
    echo -e "${VERDE}✓ Variable SOPS_AGE_KEY_FILE añadida a .zshrc${NC}"
fi

echo -e "\n${VERDE}================================================================${NC}"
echo -e "${VERDE} ¡PROYECTO FÉNIX COMPLETADO! Estación de Mando Lista.${NC}"
echo -e "${VERDE}================================================================${NC}"
echo -e "Por favor, ejecuta: ${AZUL}source ~/.bashrc${NC} (o reinicia tu terminal) para cargar las variables."
echo -e "Para levantar EVE, entra a la carpeta del proyecto y ejecuta: ${AZUL}./orchestrator.sh${NC}"

