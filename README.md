# EVE - Entorno Virtual de Infraestructura

EVE es un orquestador de infraestructura automatizado que gestiona el despliegue de VMs y contenedores LXC en Proxmox, con configuración mediante Ansible y monitoreo integrado.

## Arquitectura General

```
┌─────────────────────────────────────────────────────────────────┐
│                        lab-state.yaml                           │
│                   (Single Source of Truth)                      │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      orchestrator.sh                            │
│                    (Orquestador Principal)                      │
└─────────────────────────────────────────────────────────────────┘
         │              │              │              │
         ▼              ▼              ▼              ▼
   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐
   │validator │  │ Terraform│  │  Ansible │  │   Telegram   │
   │   .py    │  │          │  │          │  │  Notificaciones│
   └──────────┘  └──────────┘  └──────────┘  └──────────────┘
         │              │              │
         │              ▼              ▼
         │      ┌──────────────┐ ┌─────────────────┐
         │      │  Proxmox     │ │ node-config     │
         │      │  makima/reze │ │ monitor         │
         │      └──────────────┘ │ sdn-gateway     │
         │                       └─────────────────┘
         ▼
   Validacion de
     recursos
```

## Componentes Principales

### 1. Orquestador (`orchestrator.sh`)

El cerebro del sistema que coordina todo el flujo de despliegue:

- Ejecuta validaciones previas con `validator.py`
- Despliega reglas de firewall dinámicas
- Crea infraestructura con Terraform
- Aplica configuración con Ansible
- Envía notificaciones a Telegram

### 2. Validador (`validator.py`)

Garantiza que los recursos solicitados cumplan las políticas del cluster:

| Recurso | Límite |
|---------|--------|
| Cores totales | 11 |
| Memoria máxima | 8 GB |
| Sistemas soportados | Debian, Alpine |

### 3. Terraform (`terraform/`)

Gestión de infraestructura como código:

- Backend S3 con DynamoDB para estado remoto
- Soporte para VMs KVM y contenedores LXC
- Integración con cloud-init para configuración inicial
- Multi-nodo: makima y reze

### 4. Ansible (`ansible/`)

Automatización de configuración post-despliegue:

| Rol | Descripción |
|-----|-------------|
| `node-config` | Configuración base del sistema |
| `monitor` | Stack VictoriaMetrics + Grafana |
| `sdn-gateway` | Reglas de firewall dinámicas |

### 5. Stack de Monitoreo

- **VictoriaMetrics**: Base de datos de series temporales
- **Grafana**: Visualización y dashboards
- **Node Exporter**: Métricas de sistema

## Flujo de Despliegue de una Nueva Máquina

### Paso 1: Definir el entorno en `lab-state.yaml`

```yaml
entornos:
  - nombre: "mi-nueva-vm"
    estado: "presente"
    tipo: "vm"                    # "vm" o "lxc"
    nodo_proxmox: "makima"        # "makima" o "reze"
    vmid: 150
    plantilla: "debian13-template"
    red:
      ip: "192.168.1.60/24"
      gateway: "192.168.1.30"
    recursos:
      cores: 2
      memoria: 2048
      disco: 20
    firewall_externo:
      - puerto: 22
        protocolo: "tcp"
        descripcion: "SSH"
```

### Paso 2: Ejecutar el orquestador

```bash
./orchestrator.sh
```

### Paso 3: El orquestador ejecuta automáticamente

1. **Validación**: `validator.py` verifica recursos disponibles
2. **Firewall**: Genera y aplica reglas iptables en doom-gateway
3. **Infraestructura**: Terraform crea la VM/LXC en Proxmox
4. **Espera SSH**: Verifica conectividad de la nueva máquina
5. **Configuración**: Ansible aplica:
   - Actualización de sistema
   - Paquetes base (curl, git, vim, htop)
   - QEMU Guest Agent (solo VMs)
   - Node Exporter para monitoreo
6. **Notificación**: Telegram confirma el despliegue exitoso

## Estructura del Repositorio

```
EVE/
├── orchestrator.sh           # Orquestador principal
├── validator.py              # Validador de recursos
├── lab-state.yaml            # Single Source of Truth
├── bootstrap.sh              # Inicialización del entorno
│
├── terraform/                # Infraestructura como Código
│   ├── main.tf              # Definición de recursos
│   ├── provider.tf          # Proveedor Proxmox
│   └── backend.tf           # Backend S3/DynamoDB
│
├── ansible/                  # Automatización de configuración
│   ├── node-config/         # Configuración base
│   │   └── setup_base.yml
│   ├── monitor/             # Stack de monitoreo
│   │   ├── setup_monitor.yml
│   │   ├── templates/
│   │   └── files/
│   └── sdn-gateway/         # Firewall SDN
│       ├── deploy-firewall.yml
│       └── templates/
│
└── .github/workflows/        # CI/CD
    └── eve-sanity-check.yml
```

## Requisitos

### En el runner/local

- Terraform >= 1.0
- Ansible >= 2.9
- SOPS (para descifrar secretos)
- Age (clave de cifrado)
- Python 3.x

### En Proxmox

- Plantillas cloud-init configuradas
- Token de API con permisos adecuados
- Storage configurado (local-lvm, hdd_data)

## Configuración de Secretos

Los secretos se gestionan con SOPS y Age:

```bash
# Descifrar secretos
sops -d secrets.enc.yaml > secrets.yaml

# Editar secretos cifrados
sops secrets.enc.yaml
```

## Variables de Entorno Requeridas

| Variable | Descripción |
|----------|-------------|
| `PROXMOX_VE_URL` | URL de la API de Proxmox |
| `PROXMOX_VE_API_TOKEN` | Token de autenticación |
| `PROXMOX_VE_USERNAME` | Usuario (alternativo al token) |
| `PROXMOX_VE_PASSWORD` | Contraseña (alternativo al token) |
| `TF_VAR_sops_age_key` | Clave Age para SOPS |
| `TELEGRAM_BOT_TOKEN` | Token del bot de Telegram |
| `TELEGRAM_CHAT_ID` | ID del chat de notificaciones |

## Tipos de Recursos Soportados

### VM (Máquina Virtual)

```yaml
- nombre: "mi-vm"
  tipo: "vm"
  nodo_proxmox: "makima"
  vmid: 100
  plantilla: "debian13-template"
  recursos:
    cores: 2
    memoria: 2048
    disco: 20
```

### LXC (Contenedor)

```yaml
- nombre: "mi-lxc"
  tipo: "lxc"
  os: "alpine"              # "alpine" o "debian"
  nodo_proxmox: "reze"
  vmid: 200
  recursos:
    cores: 1
    memoria: 512
    disco: 8
    disco_datos:            # Opcional
      storage: "hdd_data"
      size: "50G"
```

### Gateway (Firewall)

```yaml
- nombre: "doom-gateway"
  tipo: "gateway"
  red:
    ip: "192.168.1.30/24"
```

## Monitoreo

Una vez desplegado, el stack de monitoreo está disponible en:

- **Grafana**: `http://192.168.1.40:3000`
- **VictoriaMetrics**: `http://192.168.1.40:8428`

Todos los nodos tienen Node Exporter instalado y son scrapeados automáticamente.

## CI/CD

El workflow de GitHub Actions ejecuta validaciones en cada push:

- Verifica herramientas (Terraform, Ansible, SOPS)
- Valida clave de Age
- Verifica conectividad ZeroTier

## Troubleshooting

### El validador rechaza el despliegue

Verifica que los recursos solicitados no excedan los límites del cluster (11 cores, 8GB RAM).

### Terraform falla al conectar con Proxmox

Revisa que las variables `PROXMOX_VE_*` estén configuradas correctamente.

### Ansible no puede conectar por SSH

- Verifica que la VM/LXC haya terminado de arrancar
- Comprueba que cloud-init haya inyectado las SSH keys

### Los secretos no se descifran

Asegúrate de que `SOPS_AGE_KEY_FILE` apunta a la clave correcta.
