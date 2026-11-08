#!/usr/bin/env bash
set -euo pipefail

CT_ID=100
CT_HOSTNAME="ansible-control"
CT_IP="192.168.1.240/24"      # Ajusta para o IP pretendido na tua rede
CT_GW="192.168.1.254"         # Ajusta para o IP do teu router
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"

# Não guardar a password num repositório público.
if [[ -z "${CT_PASS:-}" ]]; then
    read -r -s -p "Password do container: " CT_PASS
    echo
fi
if [[ -z "$CT_PASS" ]]; then
    echo "Erro: a password não pode estar vazia." >&2
    exit 1
fi

# Nome exato do template oficial Intel/AMD64
TEMPLATE_NAME="debian-12-standard_12.7-1_amd64.tar.zst"

echo "1. A atualizar lista de templates..."
pveam update

# Se a versão exata não existir, procura o template Debian 12 AMD64 disponível.
ACTUAL_TEMPLATE=$(pveam available -section system | awk '$2 ~ /^debian-12-standard.*amd64\.tar\.zst$/ {print $2}' | tail -n 1)
if [[ -n "$ACTUAL_TEMPLATE" ]]; then
    TEMPLATE_NAME="$ACTUAL_TEMPLATE"
fi

echo "2. A descarregar template AMD64: $TEMPLATE_NAME"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"

echo "3. A criar o Container LXC ($CT_HOSTNAME)..."
pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
    --hostname "$CT_HOSTNAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:8" \
    --cores 1 \
    --memory 1024 \
    --swap 512 \
    --net0 "name=eth0,bridge=vmbr0,ip=${CT_IP},gw=${CT_GW}" \
    --password "$CT_PASS" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1

# Limpa a variável para reduzir o tempo em que a password fica na memória.
unset CT_PASS

echo "4. A iniciar o container..."
pct start "$CT_ID"
echo "A aguardar 8 segundos pela rede..."
sleep 8

echo "5. A instalar Ansible e dependências..."
pct exec "$CT_ID" -- bash -c "apt update && apt install -y ansible python3-proxmoxer python3-requests sshpass git curl"

echo "6. A configurar chaves SSH..."
pct exec "$CT_ID" -- bash -c "mkdir -p /root/.ssh && ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N '' -q"
PUB_KEY=$(pct exec "$CT_ID" -- cat /root/.ssh/id_ed25519.pub)
mkdir -p /root/.ssh
touch /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
printf '%s\n' "$PUB_KEY" >> /root/.ssh/authorized_keys

echo "7. A criar estrutura de diretórios do projeto..."
pct exec "$CT_ID" -- bash -c "mkdir -p /root/homelab/{playbooks,inventories,files}"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    read -r -s -p "GitHub Token (repositório privado minipc): " GITHUB_TOKEN
    echo
fi
if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "Erro: o token do GitHub não pode estar vazio." >&2
    exit 1
fi

echo "8. A clonar o repositório privado e preparar o Ansible..."
pct exec "$CT_ID" -- bash -c "  git clone https://${GITHUB_TOKEN}@://github.com /root/homelab && ansible-galaxy collection install community.general "
# Limpa o token da memória do host Proxmox
unset GITHUB_TOKEN

echo "=========================================================="
echo "CONCLUÍDO! O nó Ansible está pronto no IP: ${CT_IP%/*}"
echo "Para entrar nele, usa: pct enter $CT_ID"
echo "=========================================================="
