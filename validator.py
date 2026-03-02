import yaml
import sys

# --- LÍMITES FÍSICOS ACTUALIZADOS (Política de 8GB) ---
LIMITES = {
    "cpu_total": 11,
    "ram_total_mb": 8192,  # Límite estricto de 8GB para carga de trabajo
    "nodos": {
        "makima": {"disco_gb": 100},
        "reze":   {"disco_gb": 850}
    },
    "sistemas_soportados": ["debian", "alpine"]
}

def validate_lab_state(file_path):
    try:
        with open(file_path, 'r') as f:
            data = yaml.safe_load(f)
    except Exception as e:
        return False, f"Error al leer el YAML: {e}"

    entornos = data.get('entornos', [])
    used_ips = set()
    total_ram = 0
    total_cores = 0
    uso_disco = {"makima": 0, "reze": 0}

    for item in entornos:
        nombre = item.get('nombre', 'Desconocido')
        tipo = item.get('tipo', 'vm')
        estado = item.get('estado', 'presente')
        os_distro = item.get('os', 'debian') # Debian por defecto

        if estado == 'presente' and tipo in ['vm', 'lxc']:
            if os_distro not in LIMITES['sistemas_soportados']:
                return False, f"❌ OS no soportado: {os_distro} en {nombre}"

            recursos = item.get('recursos', {})
            mem = recursos.get('memoria', 0)
            cores = recursos.get('cores', 0)
            disco = recursos.get('disco', 8)
            nodo = item.get('nodo_proxmox')

            total_ram += mem
            total_cores += cores
            if nodo in uso_disco:
                uso_disco[nodo] += disco

    # Validaciones Globales
    if total_cores > LIMITES['cpu_total']:
        return False, f"❌ OVERBOOKING DE CPU: Solicitado {total_cores}, Límite {LIMITES['cpu_total']}"
    if total_ram > LIMITES['ram_total_mb']:
        return False, f"❌ OVERBOOKING DE RAM: Solicitado {total_ram}MB, Límite {LIMITES['ram_total_mb']}MB"

    return True, f"✅ Validación Exitosa. RAM: {total_ram}/{LIMITES['ram_total_mb']}MB | CPU: {total_cores}/{LIMITES['cpu_total']}"

if __name__ == "__main__":
    success, message = validate_lab_state('lab-state.yaml')
    print(message)
    sys.exit(0 if success else 1)

