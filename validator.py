import yaml
import sys

# --- CONFIGURACIÓN DE LÍMITES (BASADO EN TUS CAPTURAS) ---
LIMITES = {
    "cpu_total": 12,
    "ram_total_mb": 12800, # ~12.5 GiB para dejar margen al OS
    "nodos": ["makima", "reze"]
}

def validate_lab_state(file_path):
    try:
        with open(file_path, 'r') as f:
            data = yaml.safe_load(f)
    except Exception as e:
        return False, f"Error al leer el YAML: {e}"

    entornos = data.get('entornos', [])
    used_ips = set()
    used_vmids = set()
    total_ram = 0
    total_cores = 0

    for item in entornos:
        nombre = item.get('nombre', 'Desconocido')
        tipo = item.get('tipo', 'vm')
        estado = item.get('estado', 'presente')

        # 1. Validar Unicidad de IP
        ip = item.get('red', {}).get('ip', '').split('/')[0]
        if ip:
            if ip in used_ips:
                return False, f"❌ IP Duplicada detectada: {ip} en {nombre}"
            used_ips.add(ip)

        # 2. Validar Recursos (Solo si el estado es 'presente' y es VM/LXC)
        if estado == 'presente' and tipo in ['vm', 'lxc']:
            recursos = item.get('recursos', {})
            mem = recursos.get('memoria', 0)
            cores = recursos.get('cores', 0)
            vmid = item.get('vmid')
            nodo = item.get('nodo_proxmox')

            # Validar VMID único
            if vmid:
                if vmid in used_vmids:
                    return False, f"❌ VMID Duplicado: {vmid} en {nombre}"
                used_vmids.add(vmid)

            # Validar existencia de nodo
            if nodo not in LIMITES['nodos']:
                return False, f"❌ El nodo '{nodo}' no existe en el cluster actual."

            total_ram += mem
            total_cores += cores

    # 3. Validar Totales contra el Hardware Real
    if total_cores > LIMITES['cpu_total']:
        return False, f"❌ OVERBOOKING DE CPU: Solicitado {total_cores}, Límite {LIMITES['cpu_total']}"
    
    if total_ram > LIMITES['ram_total_mb']:
        return False, f"❌ OVERBOOKING DE RAM: Solicitado {total_ram}MB, Límite {LIMITES['ram_total_mb']}MB"

    return True, f"✅ Validación Exitosa. RAM: {total_ram}/{LIMITES['ram_total_mb']}MB | CPU: {total_cores}/{LIMITES['cpu_total']}"

if __name__ == "__main__":
    success, message = validate_lab_state('lab-state.yaml')
    print(message)
    sys.exit(0 if success else 1)

