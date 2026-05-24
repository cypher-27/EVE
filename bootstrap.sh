#!/bin/bash
set -e

# ==============================================================================
# EVE Bootstrap — Prepares the command station from scratch
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}[*] Starting EVE Bootstrap...${NC}"

# 1. BASE DEPENDENCIES
echo -e "${BLUE}[1/6] Installing base dependencies...${NC}"
sudo apt-get update -y
sudo apt-get install -y curl wget gnupg software-properties-common git unzip python3-pip python3-yaml age

# 2. TERRAFORM
echo -e "${BLUE}[2/6] Checking Terraform...${NC}"
if ! command -v terraform &> /dev/null; then
    echo "Installing Terraform..."
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt-get update -y && sudo apt-get install -y terraform
else
    echo -e "${GREEN}✓ Terraform already installed${NC}"
fi

# 3. ANSIBLE
echo -e "${BLUE}[3/6] Checking Ansible...${NC}"
if ! command -v ansible &> /dev/null; then
    echo "Installing Ansible..."
    sudo apt-get install -y ansible
else
    echo -e "${GREEN}✓ Ansible already installed${NC}"
fi
echo "Installing Ansible collections..."
ansible-galaxy collection install community.general community.sops --force

# 4. SOPS
echo -e "${BLUE}[4/6] Checking SOPS...${NC}"
if ! command -v sops &> /dev/null; then
    echo "Installing SOPS..."
    SOPS_VERSION=$(curl -s https://api.github.com/repos/getsops/sops/releases/latest \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    wget -qO sops https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64
    sudo mv sops /usr/local/bin/sops
    sudo chmod +x /usr/local/bin/sops
else
    echo -e "${GREEN}✓ SOPS already installed${NC}"
fi

# 5. ZEROTIER
echo -e "${BLUE}[5/6] Checking ZeroTier...${NC}"
if ! command -v zerotier-cli &> /dev/null; then
    echo "Installing ZeroTier..."
    curl -s https://install.zerotier.com | sudo bash
else
    echo -e "${GREEN}✓ ZeroTier already installed${NC}"
fi

read -p "Join a ZeroTier network now? (y/n): " zt_resp
if [[ "$zt_resp" == "y" || "$zt_resp" == "Y" ]]; then
    read -p "Enter your ZeroTier Network ID: " zt_id
    sudo zerotier-cli join "$zt_id"
    echo -e "${GREEN}✓ Join request sent. Authorize the node at https://my.zerotier.com${NC}"
fi

# 6. AGE KEY SETUP
echo -e "${BLUE}[6/6] Configuring cryptographic identity (Age)...${NC}"
AGE_DIR="$HOME/.config/sops/age"
AGE_FILE="$AGE_DIR/keys.txt"

mkdir -p "$AGE_DIR"

if [ ! -f "$AGE_FILE" ]; then
    echo -e "${RED}Age key not found at $AGE_FILE${NC}"
    read -s -p "Paste your Age PRIVATE key (AGE-SECRET-KEY-...) and press Enter: " age_key
    echo ""
    if [[ "$age_key" == AGE-SECRET-KEY-* ]]; then
        echo "$age_key" > "$AGE_FILE"
        chmod 600 "$AGE_FILE"
        echo -e "${GREEN}✓ Key saved securely at $AGE_FILE${NC}"
    else
        echo -e "${RED}Invalid key format. Configure it manually.${NC}"
    fi
else
    echo -e "${GREEN}✓ Age key already present${NC}"
fi

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && ! grep -q "SOPS_AGE_KEY_FILE" "$rc"; then
        echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> "$rc"
        echo -e "${GREEN}✓ SOPS_AGE_KEY_FILE added to $(basename $rc)${NC}"
    fi
done

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN} EVE Bootstrap complete. Command station ready.${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "Run: ${BLUE}source ~/.bashrc${NC} to load environment variables."
echo -e "Then: ${BLUE}./orchestrator.sh${NC} to deploy."
