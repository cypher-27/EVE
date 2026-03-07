#!/usr/bin/env python3
import yaml
import ipaddress
import sys

# --- CONSTANTES DE GOBERNANZA Y TOPOLOGÍA FÍSICA ---
LIMITES = {
    "cpu_total": 11,
    "ram_total_mb": 8192,
    "ram_efimera_mb": 2048, # Bozal para la rama dev
    "sistemas_soportados": ["debian", "alpine"],
    "nodos": {
        "makima": {
            "local-zfs": 100, # SSD
            "hdd_data": 850   # HDD
        },
        "reze": {
            "local-zfs": 850, # HDD
            "hdd_data": 0     # NO EXISTE
        }
    }
}

IP_MONITOR = '192.168.1.40'
IP_RANGE_START = ipaddress.IPv4Address('192.168.1.41')
IP_RANGE_END = ipaddress.IPv4Address('192.168.1.63')

# Colores terminal
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
NC = '\033[0m'

def print_error(msg):
    print(f"{RED}[!] ERROR DE VALIDACIÓN: {msg}{NC}")
    sys.exit(1)

def validate():
    try:
        with open('lab-state.yaml', 'r') as f:
            data = yaml.safe_load(f)
    except Exception as e:
        print_error(f"Error al leer el YAML: {e}")

    entornos = data.get('entornos', [])

    total_ram = 0
    total_cores = 0
    ephemeral_ram = 0

    # Contabilidad por nodo y por pool
    uso_disco = {
        "makima": {"local-zfs": 0, "hdd_data": 0},
        "reze":   {"local-zfs": 0, "hdd_data": 0}
    }

    monitor_presente = False
    nodos_piden_monitor = []

    # --- VALIDACIÓN DE DUPLICADOS ---
    nombres_vistos = set()
    vmids_vistos = set()
    ips_vistas = set()

    print(f"{YELLOW}[*] Iniciando validación de Topología EVE...{NC}")

    for env in entornos:
        nombre = env.get('nombre', 'unknown')
        estado = env.get('estado', 'ausente')
        is_core = env.get('core', False)
        is_efimero = env.get('efimero', False)
        tipo = env.get('tipo', 'vm')
        os_distro = env.get('os', 'debian')
        nodo = env.get('nodo_proxmox')
        vmid = env.get('vmid')

        # --- VALIDACIÓN DE NOMBRES DUPLICADOS ---
        if nombre in nombres_vistos:
            print_error(f"Nombre duplicado: '{nombre}'")
        nombres_vistos.add(nombre)

        # --- VALIDACIÓN DE VMID DUPLICADOS ---
        if vmid is not None:
            if vmid in vmids_vistos:
                print_error(f"VMID duplicado: {vmid} en '{nombre}'")
            vmids_vistos.add(vmid)

        if nombre == 'eve-monitor' and estado == 'presente':
            monitor_presente = True

        if estado == 'ausente':
            continue

        if env.get('monitor_enabled', False):
            nodos_piden_monitor.append(nombre)

        if tipo in ['vm', 'lxc']:
            # --- VALIDACIÓN DE CAMPOS OBLIGATORIOS POR TIPO ---
            if tipo == 'vm':
                if not env.get('plantilla'):
                    print_error(f"VM '{nombre}' falta el campo obligatorio: plantilla")

            if tipo == 'lxc':
                if vmid is None:
                    print_error(f"LXC '{nombre}' falta el campo obligatorio: vmid")
                if not env.get('os'):
                    print_error(f"LXC '{nombre}' falta el campo obligatorio: os")

            if os_distro not in LIMITES['sistemas_soportados']:
                print_error(f"OS no soportado: '{os_distro}' en {nombre}")

            if nodo not in LIMITES['nodos']:
                print_error(f"Nodo Proxmox desconocido: '{nodo}' en {nombre}")

            # --- VALIDACIÓN DE RECURSOS OBLIGATORIOS ---
            recursos = env.get('recursos')
            if not recursos:
                print_error(f"'{nombre}' falta el bloque obligatorio: recursos")

            if not recursos.get('cores'):
                print_error(f"'{nombre}' falta recursos.cores")
            if not recursos.get('memoria'):
                print_error(f"'{nombre}' falta recursos.memoria")
            if not recursos.get('disco'):
                print_error(f"'{nombre}' falta recursos.disco")

            ram = recursos.get('memoria', 0)
            cores = recursos.get('cores', 0)
            disco_root = recursos.get('disco', 8)
            
            total_ram += ram
            total_cores += cores
            
            if is_efimero:
                ephemeral_ram += ram

            # Lógica de asignación de storage simulando el comportamiento del Pipeline
            # Si es efímero y está en makima, va a hdd_data. Si no, va a local-zfs.
            pool_asignado = "local-zfs"
            if is_efimero and nodo == "makima":
                pool_asignado = "hdd_data"

            # Verificar si hay discos extra declarados dentro de recursos
            disco_extra = recursos.get('disco_datos', {})
            if disco_extra:
                pool_extra = disco_extra.get('storage')
                size_extra_str = disco_extra.get('size', '0')
                try:
                    size_extra = int(size_extra_str.replace('G', '').replace('g', ''))
                except ValueError:
                    print_error(f"Formato de size inválido en disco_datos de {nombre}: {size_extra_str}")

                if pool_extra == "hdd_data" and nodo == "reze":
                    print_error(f"{nombre} intenta montar 'hdd_data' en el nodo 'reze', pero ese pool no existe ahí.")

                if pool_extra in uso_disco[nodo]:
                    uso_disco[nodo][pool_extra] += size_extra

            uso_disco[nodo][pool_asignado] += disco_root

            # --- VALIDACIÓN DE FIREWALL ---
            firewall_rules = env.get('firewall_externo', [])
            for rule in firewall_rules:
                puerto = rule.get('puerto')
                protocolo = rule.get('protocolo', 'tcp').lower()

                if protocolo not in ['tcp', 'udp']:
                    print_error(f"Protocolo inválido en {nombre}: '{protocolo}'. Use 'tcp' o 'udp'.")

                if puerto is not None:
                    if not isinstance(puerto, int) or puerto < 1 or puerto > 65535:
                        print_error(f"Puerto inválido en {nombre}: {puerto}")

        # Validación de Red (IPs)
        if 'red' in env and 'ip' in env['red']:
            ip_str = env['red']['ip'].split('/')[0]
            try:
                ip_obj = ipaddress.IPv4Address(ip_str)
            except ValueError:
                print_error(f"IP inválida en {nombre}: {ip_str}")

            # --- VALIDACIÓN DE IPs DUPLICADAS ---
            if ip_str in ips_vistas:
                print_error(f"IP duplicada: {ip_str} en '{nombre}'")
            ips_vistas.add(ip_str)

            # --- VALIDACIÓN DE GATEWAY ---
            gateway = env['red'].get('gateway')
            if gateway:
                try:
                    ipaddress.IPv4Address(gateway)
                except ValueError:
                    print_error(f"Gateway inválido en {nombre}: {gateway}")

            if nombre == 'eve-monitor':
                if ip_str != IP_MONITOR:
                    print_error(f"eve-monitor debe tener la IP estática {IP_MONITOR}")
            elif not is_core:
                if not (IP_RANGE_START <= ip_obj <= IP_RANGE_END):
                    print_error(f"La IP de {nombre} ({ip_str}) está fuera del rango (.41 a .63)")

    # --- REGLAS DE NEGOCIO Y CUOTAS ---
    if nodos_piden_monitor and not monitor_presente:
        print_error(f"Nodos {nodos_piden_monitor} piden monitoreo, pero eve-monitor está AUSENTE.")

    if total_ram > LIMITES['ram_total_mb']:
        print_error(f"OVERBOOKING DE RAM: {total_ram}MB / {LIMITES['ram_total_mb']}MB")
        
    if total_cores > LIMITES['cpu_total']:
        print_error(f"OVERBOOKING DE CPU: {total_cores} / {LIMITES['cpu_total']}")

    if ephemeral_ram > LIMITES['ram_efimera_mb']:
        print_error(f"Límite Efímero excedido: {ephemeral_ram}MB / {LIMITES['ram_efimera_mb']}MB")

    # Validación de discos por nodo
    for n in LIMITES['nodos']:
        for pool in LIMITES['nodos'][n]:
            usado = uso_disco[n][pool]
            limite = LIMITES['nodos'][n][pool]
            if usado > limite:
                print_error(f"Almacenamiento excedido en {n} ({pool}). Solicitado: {usado}GB / Límite: {limite}GB")

    print(f"{GREEN}[✓] Validación Exitosa. RAM: {total_ram}/{LIMITES['ram_total_mb']}MB | CPU: {total_cores}/{LIMITES['cpu_total']}{NC}")
    sys.exit(0)

if __name__ == '__main__':
    validate()

