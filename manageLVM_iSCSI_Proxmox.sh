#!/bin/bash

# Script para gestión de LVM compartido en cluster Proxmox
# Autor: Script de gestión automática
# Fecha: $(date +%Y-%m-%d)

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

# Configuración del cluster
HOSTS=("IP1" "IP2" "IP3" "IP4")
SSH_USER="root"
CURRENT_HOST=$(hostname -I | awk '{print $1}')

# Función para logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Función para ejecutar comando en todos los hosts
execute_on_all_hosts() {
    local cmd="$1"
    local description="$2"

    log_info "$description"
    for host in "${HOSTS[@]}"; do
        echo "  → Ejecutando en $host..."
        ssh -o StrictHostKeyChecking=no ${SSH_USER}@${host} "$cmd" 2>&1 | sed 's/^/    /'
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo -e "    ${GREEN}✓${NC} Completado en $host"
        else
            log_error "Falló en $host"
        fi
    done
    echo ""
}

# Función para ejecutar comando en host específico
execute_on_host() {
    local host="$1"
    local cmd="$2"

    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${host} "$cmd"
}

# Función para rescanear dispositivos multipath
rescan_multipath() {
    log_info "Rescaneando dispositivos multipath en todos los hosts..."
    echo ""

    for host in "${HOSTS[@]}"; do
        echo "  → Rescaneando en $host..."
        ssh -o StrictHostKeyChecking=no ${SSH_USER}@${host} "
            # Rescan de buses SCSI usando rescan-scsi-bus.sh
            if command -v rescan-scsi-bus.sh &> /dev/null; then
                rescan-scsi-bus.sh 2>&1 | tail -5
            else
                echo 'ADVERTENCIA: rescan-scsi-bus.sh no encontrado'
                # Fallback al método manual
                for host_dir in /sys/class/scsi_host/host*; do
                    echo '- - -' > \${host_dir}/scan 2>/dev/null
                done
            fi
        " 2>&1 | sed 's/^/    /'
        echo -e "    ${GREEN}✓${NC} Rescan completado en $host"
    done

    echo ""
    sleep 2
}

# Función para ampliar disco multipath
expand_multipath_disk() {
    log_info "Ampliando disco multipath en todos los hosts..."
    echo ""
    log_warn "Esta operación detectará cambios de tamaño en los discos multipath existentes"
    echo ""

    # Mostrar dispositivos multipath disponibles en el host local con WWID
    log_info "Dispositivos multipath disponibles en HOST LOCAL ($CURRENT_HOST):"
    echo ""
    
    declare -A mpath_wwids
    
    multipath -ll | grep -E '^mpath' | awk '{print $1}' | while read mpath_name; do
        mpath_device="/dev/mapper/${mpath_name}"
        size=$(lsblk -ndo SIZE "$mpath_device" 2>/dev/null || echo 'N/A')
        wwid=$(multipath -ll "$mpath_name" | grep -oP '(?<=\()[^)]+(?=\))' | head -1)
        
        if pvs "$mpath_device" &>/dev/null; then
            vg_name=$(pvs --noheadings -o vg_name "$mpath_device" 2>/dev/null | tr -d ' ')
            echo "  → $mpath_name - Tamaño: $size - VG: $vg_name"
            echo "     WWID: $wwid"
        else
            echo "  → $mpath_name - Tamaño: $size - Sin VG"
            echo "     WWID: $wwid"
        fi
        echo ""
    done

    read -p "Ingrese el WWID del dispositivo a ampliar (copie y pegue desde arriba): " target_wwid
    
    if [ -z "$target_wwid" ]; then
        log_error "Debe especificar un WWID"
        return 1
    fi

    # Validar que existe localmente
    local_mpath=$(multipath -ll | grep -B1 "$target_wwid" | grep '^mpath' | awk '{print $1}')
    
    if [ -z "$local_mpath" ]; then
        log_error "No se encontró ningún dispositivo multipath con WWID: $target_wwid"
        return 1
    fi

    log_info "WWID $target_wwid corresponde a $local_mpath en este host"
    echo ""

    log_info "Ampliando dispositivo con WWID $target_wwid en todos los hosts del cluster..."
    echo ""

    for host in "${HOSTS[@]}"; do
        echo "  → Procesando en $host..."
        ssh -o StrictHostKeyChecking=no ${SSH_USER}@${host} "
            # Encontrar el nombre del mpath basado en WWID
            mpath_name=\$(multipath -ll | grep -B1 '${target_wwid}' | grep '^mpath' | awk '{print \$1}')
            
            if [ -z \"\$mpath_name\" ]; then
                echo '    ERROR: No se encontró dispositivo con WWID ${target_wwid} en este host'
                exit 1
            fi
            
            echo \"    Dispositivo identificado: \$mpath_name\"
            
            # Rescan de buses SCSI con detección de tamaño
            if command -v rescan-scsi-bus.sh &> /dev/null; then
                echo '    Ejecutando rescan-scsi-bus.sh -s...'
                rescan-scsi-bus.sh -s 2>&1 | tail -10
            else
                echo '    ADVERTENCIA: rescan-scsi-bus.sh no encontrado'
                echo '    Intentando método alternativo...'
                # Fallback: rescan manual y resize de dispositivos
                for host_dir in /sys/class/scsi_host/host*; do
                    echo '- - -' > \${host_dir}/scan 2>/dev/null
                done
                # Resize de dispositivos de bloques
                for dev in /sys/class/block/sd*/device/rescan; do
                    echo 1 > \$dev 2>/dev/null
                done
            fi
            
            echo ''
            echo \"    Redimensionando mapa multipath \$mpath_name...\"
            multipathd resize map \$mpath_name 2>&1
            
            echo ''
            echo \"    Estado del dispositivo \$mpath_name:\"
            multipath -ll \$mpath_name | grep -E 'size=|\$mpath_name' | head -3
        " 2>&1 | sed 's/^/    /'
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo -e "    ${GREEN}✓${NC} Rescan y ampliación completado en $host"
        else
            log_error "Falló en $host"
        fi
        echo ""
    done

    echo ""
    log_info "Actualizando información de PVs en todos los hosts..."
    echo ""

    for host in "${HOSTS[@]}"; do
        echo "  → Redimensionando PV en $host..."
        ssh -o StrictHostKeyChecking=no ${SSH_USER}@${host} "
            # Encontrar el dispositivo basado en WWID
            mpath_name=\$(multipath -ll | grep -B1 '${target_wwid}' | grep '^mpath' | awk '{print \$1}')
            mpath_device=\"/dev/mapper/\$mpath_name\"
            
            # Actualizar cache de LVM
            pvscan --cache 2>&1 | grep -v 'event' || true
            
            # Redimensionar el PV específico
            echo ''
            if pvs \$mpath_device &>/dev/null; then
                echo \"    Redimensionando Physical Volume \$mpath_device...\"
                pvresize \$mpath_device 2>&1
                
                echo ''
                echo '    Estado del PV:'
                pvs \$mpath_device 2>&1
            else
                echo \"    ADVERTENCIA: \$mpath_device no tiene un PV creado\"
            fi
        " 2>&1 | sed 's/^/    /'
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo -e "    ${GREEN}✓${NC} PV actualizado en $host"
        else
            log_error "Falló actualización de PV en $host"
        fi
        echo ""
    done

    echo ""
    echo "=============================================="
    log_info "Ampliación de disco completada"
    echo "=============================================="
    echo ""
    echo "Dispositivo ampliado: WWID $target_wwid"
    echo ""
    echo "Comandos útiles para verificar:"
    echo "  - Ver tamaño de PVs: pvs"
    echo "  - Ver tamaño de VGs: vgs"
    echo "  - Ver dispositivo multipath por WWID: multipath -ll | grep -A10 '$target_wwid'"
    echo "  - Extender LV: lvextend -l +100%FREE /dev/vg_name/lv_name"
    echo "  - Redimensionar filesystem (ext4): resize2fs /dev/vg_name/lv_name"
    echo "  - Redimensionar filesystem (xfs): xfs_growfs /mount/point"
    echo ""
}

# Función para mostrar dispositivos multipath disponibles
show_multipath_devices() {
    log_info "Mostrando dispositivos multipath disponibles en HOST LOCAL ($CURRENT_HOST)..."
    echo ""

    echo 'Analizando dispositivos multipath locales...'
    echo ''

    # Obtener todos los dispositivos mpath
    multipath -ll | grep -E '^mpath' | awk '{print $1}' | while read mpath_name; do
        mpath_device="/dev/mapper/${mpath_name}"

        # Verificar si tiene PV asignado
        if pvs "$mpath_device" &>/dev/null; then
            vg_name=$(pvs --noheadings -o vg_name "$mpath_device" 2>/dev/null | tr -d ' ')
            echo "  ❌ $mpath_device (EN USO - VG: $vg_name)"
        else
            # Obtener tamaño del dispositivo
            size=$(lsblk -ndo SIZE "$mpath_device" 2>/dev/null || echo 'N/A')
            # Obtener información adicional de multipath
            wwid=$(multipath -ll "$mpath_name" | grep -oP '(?<=\()[^)]+(?=\))' | head -1)
            echo "  ✓ $mpath_device (DISPONIBLE - Tamaño: $size - WWID: $wwid)"
        fi
    done

    echo ''
    echo 'Leyenda:'
    echo '  ✓ = Dispositivo disponible para crear PV'
    echo '  ❌ = Dispositivo ya tiene PV asignado'
    echo ""
}

# Función para crear LVM compartido
create_shared_lvm() {
    log_info "Configuración del LVM compartido"
    echo ""

    read -p "Ingrese la ruta del dispositivo multipath (ej: /dev/mapper/mpathX): " mpath_device

    # Validar que el dispositivo existe LOCALMENTE
    if [ ! -b "$mpath_device" ]; then
        log_error "El dispositivo $mpath_device no existe o no es un dispositivo de bloques en este host."
        return 1
    fi

    # Validar si el dispositivo ya tiene PV creado LOCALMENTE
    echo "  → Verificando si el dispositivo ya tiene PV..."
    if pvs "$mpath_device" &>/dev/null; then
        existing_vg=$(pvs --noheadings -o vg_name "$mpath_device" 2>/dev/null | tr -d ' ')
        log_error "El dispositivo $mpath_device ya tiene un Physical Volume creado."
        if [ -n "$existing_vg" ]; then
            echo "        Pertenece al Volume Group: $existing_vg"
        fi
        return 1
    fi

    # Validar si el dispositivo tiene datos
    echo "  → Verificando si el dispositivo tiene datos..."
    if blkid "$mpath_device" &>/dev/null; then
        log_error "El dispositivo $mpath_device contiene un sistema de archivos o datos:"
        blkid "$mpath_device" | sed 's/^/        /'
        echo ""
        read -p "¿Está seguro de que desea continuar? Esto destruirá los datos (s/n): " force_continue
        if [[ ! "$force_continue" =~ ^[sS]$ ]]; then
            log_warn "Operación cancelada por seguridad."
            return 1
        fi
    fi

    read -p "Ingrese el nombre del Volume Group (ej: vg_shared): " vg_name

    # Validar si el VG ya existe LOCALMENTE
    echo "  → Verificando si el Volume Group ya existe..."
    if vgs "$vg_name" &>/dev/null; then
        log_error "El Volume Group '$vg_name' ya existe en el sistema."
        vgs "$vg_name" | sed 's/^/        /'
        return 1
    fi

    read -p "Ingrese el nombre del Physical Volume (por defecto: $mpath_device): " pv_name
    pv_name=${pv_name:-$mpath_device}

    echo ""
    log_info "Resumen de configuración:"
    echo "  - Dispositivo: $mpath_device"
    echo "  - Physical Volume: $pv_name"
    echo "  - Volume Group: $vg_name"
    echo ""

    read -p "¿Confirma la creación del LVM compartido? (s/n): " confirmar
    if [[ ! "$confirmar" =~ ^[sS]$ ]]; then
        log_warn "Operación cancelada por el usuario."
        return 1
    fi

    # Crear PV y VG en el host local
    echo ""
    log_info "Creando Physical Volume y Volume Group en HOST LOCAL ($CURRENT_HOST)..."
    echo ""

    set -e

    # Crear Physical Volume con parámetros específicos
    echo 'Creando Physical Volume...'
    pvcreate --metadatasize 250k -y $pv_name

    # Crear Volume Group compartido
    echo 'Creando Volume Group compartido...'
    vgcreate $vg_name $pv_name

    echo 'LVM creado exitosamente.'

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} LVM creado exitosamente en host local"
    else
        log_error "Falló la creación del LVM"
        return 1
    fi

    echo ""
    sleep 2

    # Actualizar cache en todos los demás hosts
    log_info "Actualizando cache de LVM en los demás hosts del cluster..."
    echo ""

    for host in "${HOSTS[@]}"; do
        # Saltar el host actual
        if [[ "$host" == "$CURRENT_HOST" ]]; then
            log_info "  → Saltando host local ($host)..."
            continue
        fi

        echo "  → Actualizando cache en $host..."
        ssh -o StrictHostKeyChecking=no ${SSH_USER}@${host} "
            pvscan --cache
            vgscan --cache
            vgchange --refresh
        " 2>&1 | sed 's/^/    /'

        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo -e "    ${GREEN}✓${NC} Cache actualizado en $host"
        else
            log_error "Falló la actualización en $host"
        fi
    done

    echo ""
    sleep 1

    # Verificar que el VG es visible en todos los hosts
    log_info "Verificando visibilidad del Volume Group en todos los hosts..."
    echo ""

    for host in "${HOSTS[@]}"; do
        echo "  → Verificando en $host..."
        vg_visible=$(ssh -o StrictHostKeyChecking=no ${SSH_USER}@${host} "vgs --noheadings -o vg_name 2>/dev/null | grep -w '$vg_name' | wc -l")

        if [ "$vg_visible" -eq 1 ]; then
            echo -e "    ${GREEN}✓${NC} Volume Group '$vg_name' visible en $host"
        else
            log_warn "Volume Group '$vg_name' NO visible en $host"
        fi
    done

    echo ""
    echo "=============================================="
    log_info "Proceso completado exitosamente"
    echo "=============================================="
    echo ""
    echo "Comandos útiles:"
    echo "  - Ver PVs: pvs"
    echo "  - Ver VGs: vgs"
    echo "  - Ver LVs: lvs"
    echo "  - Crear LV: lvcreate -L <tamaño> -n <nombre> $vg_name"
    echo ""
}

# Banner
clear
echo "=============================================="
echo "  Gestión de LVM Compartido - Proxmox Cluster"
echo "=============================================="
echo ""
log_info "Host actual: $CURRENT_HOST"
echo ""

# Menú principal
echo -e "${BLUE}Seleccione una opción:${NC}"
echo ""
echo "  1) Rescanear dispositivos multipath"
echo "  2) Crear disco LVM compartido"
echo "  3) Rescanear y crear disco LVM"
echo "  4) Ampliar disco multipath existente"
echo "  5) Salir"
echo ""

read -p "Ingrese su opción [1-5]: " opcion

case $opcion in
    1)
        echo ""
        rescan_multipath
        show_multipath_devices
        ;;
    2)
        echo ""
        show_multipath_devices
        echo ""
        create_shared_lvm
        ;;
    3)
        echo ""
        rescan_multipath
        show_multipath_devices
        echo ""
        read -p "¿Desea crear un LVM compartido? (s/n): " crear_lvm
        if [[ "$crear_lvm" =~ ^[sS]$ ]]; then
            create_shared_lvm
        else
            log_warn "Operación cancelada por el usuario."
        fi
        ;;
    4)
        echo ""
        expand_multipath_disk
        ;;
    5)
        log_info "Saliendo..."
        exit 0
        ;;
    *)
        log_error "Opción inválida. Por favor seleccione una opción entre 1 y 5."
        exit 1
        ;;
esac
