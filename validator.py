import yaml
import sys

# --- CONFIGURACIÓN DE LÍMITES FÍSICOS ---
LIMITES = {
    "cpu_total": 11, # 11 Hilos (Dejamos 1 libre para el Host)
    "ram_total_mb": 12800, # ~12.5 GiB
    "nodos": {
        "makima": {"disco_gb": 100}, # 112GB Reales
        "reze":   {"disco_gb": 850}  # 900GB Reales
    }
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
    
    # Contadores de disco por nodo
    uso_disco = {"makima": 0, "reze": 0}

    for item in entornos:
        nombre = item.get('nombre', 'Desconocido')
        tipo = item.get('tipo', 'vm')
        estado = item.get('estado', 'presente')

        ip = item.get('red', {}).get('ip', '').split('/')[0]
        if ip:
            if ip in used_ips: return False, f"❌ IP Duplicada: {ip} en {nombre}"
            used_ips.add(ip)

        if estado == 'presente' and tipo in ['vm', 'lxc']:
            recursos = item.get('recursos', {})
            mem = recursos.get('memoria', 0)
            cores = recursos.get('cores', 0)
            disco = recursos.get('disco', 8) # 8GB por defecto si no se pone
            vmid = item.get('vmid')
            nodo = item.get('nodo_proxmox')

            if vmid:
                if vmid in used_vmids: return False, f"❌ VMID Duplicado: {vmid} en {nombre}"
                used_vmids.add(vmid)

            if nodo not in LIMITES['nodos']:
                return False, f"❌ El nodo '{nodo}' no existe en el cluster."

            total_ram += mem
            total_cores += cores
            uso_disco[nodo] += disco

    # Validaciones Globales
    if total_cores > LIMITES['cpu_total']:
        return False, f"❌ OVERBOOKING DE CPU: Solicitado {total_cores}, Límite {LIMITES['cpu_total']}"
    if total_ram > LIMITES['ram_total_mb']:
        return False, f"❌ OVERBOOKING DE RAM: Solicitado {total_ram}MB, Límite {LIMITES['ram_total_mb']}MB"

    # Validaciones de Almacenamiento por Nodo
    for nodo, uso in uso_disco.items():
        limite_nodo = LIMITES['nodos'][nodo]['disco_gb']
        if uso > limite_nodo:
            return False, f"❌ OVERBOOKING DISCO EN {nodo.upper()}: Solicitado {uso}GB, Límite {limite_nodo}GB"

    return True, f"✅ Validación Exitosa. RAM: {total_ram}/{LIMITES['ram_total_mb']}MB | CPU: {total_cores}/{LIMITES['cpu_total']}"

if __name__ == "__main__":
    success, message = validate_lab_state('lab-state.yaml')
    print(message)
    sys.exit(0 if success else 1)

