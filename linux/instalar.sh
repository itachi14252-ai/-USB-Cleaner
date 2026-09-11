#!/usr/bin/env bash
#
#  Instala el Limpiador de USB en Omarchy / Arch (sirve en cualquier Linux).
#
#    bash instalar.sh            instala o actualiza
#    bash instalar.sh --quitar   lo quita (tu configuracion se conserva)
#
#  Se llama con "bash" delante a proposito: desde una memoria FAT32 o
#  exFAT los archivos no tienen permiso de ejecucion.

set -euo pipefail

ORIGEN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN="$HOME/.local/bin"
DATOS="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS="$DATOS/applications"
ICONOS="$DATOS/icons/hicolor/scalable/apps"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/limpiador-usb"

if [[ ${1:-} == --quitar ]]; then
    rm -f -- "$BIN/limpiador-usb" "$APPS/limpiador-usb.desktop" "$ICONOS/limpiador-usb.svg"
    update-desktop-database "$APPS" 2>/dev/null || true
    echo "Quitado. Tu configuracion sigue en $CONF (borrala a mano si quieres)."
    exit 0
fi

[[ $(uname -s) == Linux ]] || { echo "Este instalador es para Linux."; exit 1; }
[[ -f $ORIGEN/limpiador-usb ]] || { echo "No encuentro 'limpiador-usb' junto a este instalador."; exit 1; }

install -d -- "$BIN" "$APPS" "$ICONOS" "$CONF"

# tr -d '\r': si los archivos pasaron por Windows y ganaron CRLF, bash
# fallaria con "$'\r': command not found". Se corrige al copiar.
tr -d '\r' < "$ORIGEN/limpiador-usb" > "$BIN/limpiador-usb"
chmod 755 -- "$BIN/limpiador-usb"
echo "programa:  $BIN/limpiador-usb"

if [[ -f $ORIGEN/limpiador-usb.svg ]]; then
    tr -d '\r' < "$ORIGEN/limpiador-usb.svg" > "$ICONOS/limpiador-usb.svg"
fi

if [[ -f $CONF/config.conf ]]; then
    echo "config:    se conserva la tuya ($CONF/config.conf)"
else
    tr -d '\r' < "$ORIGEN/config.conf" > "$CONF/config.conf"
    echo "config:    $CONF/config.conf"
fi

cat > "$APPS/limpiador-usb.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Limpiador de USB
GenericName=Memorias USB
Comment=Limpiar, formatear, reparar, grabar imagenes, diagnosticar y recuperar memorias USB
Exec=$BIN/limpiador-usb --ventana
Icon=limpiador-usb
Terminal=false
Categories=System;Utility;
Keywords=usb;memoria;formatear;iso;etcher;diagnostico;recuperar;
EOF
update-desktop-database "$APPS" 2>/dev/null || true
echo "lanzador:  $APPS/limpiador-usb.desktop"

# Dependencias opcionales: se pregunta, no se instala nada a escondidas.
declare -A PAQ=(
    [gum]=gum [mkfs.vfat]=dosfstools [mkfs.exfat]=exfatprogs [mkfs.ntfs]=ntfs-3g
    [smartctl]=smartmontools [photorec]=testdisk [udisksctl]=udisks2
)
faltan=()
for c in "${!PAQ[@]}"; do command -v "$c" >/dev/null 2>&1 || faltan+=("${PAQ[$c]}"); done
if (( ${#faltan[@]} )); then
    echo
    echo "Faltan paquetes opcionales: ${faltan[*]}"
    echo "  gum            la interfaz (sin el, menus numerados)"
    echo "  dosfstools     FAT32 · exfatprogs exFAT · ntfs-3g NTFS"
    echo "  smartmontools  salud S.M.A.R.T. · testdisk  RECUPERAR (PhotoRec)"
    echo "  udisks2        montar y expulsar sin sudo"
    echo "  (el programa tambien los ofrece en el momento en que hacen falta)"
    if command -v pacman >/dev/null 2>&1 && [[ -t 0 ]]; then
        read -r -p "¿Instalarlos ahora con pacman? [s/N] " r || r=
        if [[ ${r,,} == s* ]]; then sudo pacman -S --needed -- "${faltan[@]}"; fi
    fi
fi

echo
echo "Autoprueba del guardian:"
if salida=$(NO_COLOR=1 bash "$BIN/limpiador-usb" --autoprueba 2>&1); then
    echo "  $(tail -n 1 <<< "$salida" | sed 's/^ *//')"
else
    printf '%s\n' "$salida"
    echo
    echo "LA AUTOPRUEBA FALLO. No uses el programa hasta revisar por que."
    exit 1
fi

echo
echo "Listo. Abrelo desde el lanzador de Omarchy (Super + Espacio -> 'Limpiador de USB')"
echo "o escribiendo 'limpiador-usb' en una terminal."
case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Nota: $BIN no esta en tu PATH; en terminal usa la ruta completa." ;;
esac
