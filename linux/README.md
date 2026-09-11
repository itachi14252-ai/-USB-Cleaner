# Limpiador de USB — versión Linux / Omarchy

El mismo programa que `Limpiador-USB.ps1`, para Linux: limpiar, formatear,
reparar, grabar imágenes, expulsar, diagnosticar y recuperar memorias USB y
tarjetas SD, con el **mismo guardián de tres niveles**. La interfaz es de
terminal, con [gum](https://github.com/charmbracelet/gum), que ya viene en
Omarchy; si no está, usa menús numerados de bash.

---

## Llevarlo a otra computadora en una memoria

1. Copia la carpeta `linux/` entera a la memoria.
2. En la laptop, abre una terminal y ejecuta el instalador **con `bash`
   delante** (desde FAT32 o exFAT los archivos no tienen permiso de
   ejecución):

   ```bash
   bash /run/media/$USER/NOMBRE-DE-LA-MEMORIA/linux/instalar.sh
   ```

3. Queda en el lanzador de Omarchy (`Super + Espacio` → *Limpiador de USB*)
   y como `limpiador-usb` en la terminal.

El instalador copia el programa a `~/.local/bin`, así que después **la
memoria ya no hace falta** y el propio programa puede limpiarla. Corrige
solo los finales de línea si los archivos pasaron por Windows, pregunta
antes de instalar paquetes y termina corriendo la autoprueba.

Para quitarlo: `bash instalar.sh --quitar` (tu configuración se conserva).

También se puede usar sin instalar: `bash limpiador-usb`. En ese caso la
memoria desde la que corre queda **blindada por el núcleo** mientras el
programa esté abierto.

---

## El guardián

Ningún disco se toca si dispara **al menos una** regla. Lo que separa un
nivel de otro es **quién puede quitarlas**.

### Nivel 1 — el núcleo. No se puede quitar

Ni desde el menú, ni desde `config.conf`, ni desde `preferencias`:

| Regla | Cómo se detecta |
|---|---|
| Disco del sistema (`/`) | `findmnt`, subiendo por LUKS → partición → disco |
| Disco de arranque (`/boot`, `/efi`) | igual |
| Aloja `/home`, `/usr`, `/var`, `/opt`, `/srv`… | igual, incluidos subvolúmenes btrfs como `[/@home]` |
| Aloja swap activo | `swapon` |
| El programa se ejecuta desde ese disco | `findmnt --target` sobre el propio script |
| Bus que no es USB / SD / MMC | `TRAN` de `lsblk`; un bus desconocido se trata como interno |
| Tiene un volumen cifrado o LVM abierto encima | los hijos `crypt` / `lvm` en `lsblk` |

Omarchy cifra la raíz con LUKS y usa btrfs: `findmnt` dice
`/dev/mapper/root[/@home]`, no `/dev/nvme0n1p2`. El guardián resuelve esa
cadena hasta el disco físico; la autoprueba lo verifica.

Los discos internos se listan con `VER TODOS LOS DISCOS`, y solo para
diagnosticar: `SOLO DIAGNOSTICO, NINGUNA ESCRITURA PERMITIDA`.

### Nivel 2 — heurísticas de fábrica. Se pueden eximir por disco

| Regla | Valor por defecto |
|---|---|
| Modelos (marca + modelo) | seagate, portable, expansion, backup plus, one touch, my passport, my book, elements, canvio, lacie |
| Tamaño | más de 2048 GB se asume disco de respaldo |
| Etiquetas | ninguna (las agregas tú) |

Un HDD externo típico dispara dos a la vez, y cualquiera bastaría: esos
discos reportan `TRAN=usb`, así que un filtro de "solo USB" los incluiría.

### Nivel 3 — lo que tú decides

`PROTECCION` en cada disco ofrece lo que corresponda a su estado:
`PROTEGER`, `DESPROTEGER`, `EXIMIR` o `REACTIVAR`. Se guarda **por número
de serie** en `~/.config/limpiador-usb/preferencias`: el `/dev/sdX` cambia
al reconectar, la serie no. Un disco sin serie no se puede recordar y el
programa lo dice.

### Precedencias

1. **Eximir nunca levanta el nivel 1.**
2. **La lista negra de series gana sobre las exenciones.**
3. **Proteger gana sobre eximir.**

Y una diferencia deliberada con Windows: **las exenciones comparan la serie
exacta**. Proteger por contenido es seguro (bloquea de más); eximir por
contenido no, porque una exención corta como `A1` liberaría cualquier
disco cuya serie la contenga.

### Se verifica tres veces

1. Al dibujar la tarjeta.
2. Al elegir la operación.
3. **Justo antes de escribir**: se relee todo el sistema, se compara la
   huella del disco (serie + tamaño + modelo + WWN) y se vuelve a pasar el
   guardián con datos frescos. Si algo cambió, aborta.

La serie sola no basta: los puentes USB baratos inventan series de relleno
— un JMicron reporta `123467` — y dos discos distintos pueden decir lo
mismo.

---

## Qué hace cada acción

| Acción | Qué hace | Confirmación |
|---|---|---|
| **LIMPIAR** | Borra todo lo de la raíz de una partición, ocultos incluidos. Sin papelera. Respeta `System Volume Information`. | escribir `sdb1` |
| **FORMATEAR** | Formato rápido de una partición. exFAT si pasa de 32 GB, FAT32 si no. Conserva la etiqueta. | escribir `sdb1` |
| **REPARAR** | Borra la tabla del **disco entero**, crea una partición y la formatea. Eliges MBR/GPT y AUTO/FAT32/exFAT/NTFS/ext4. | escribir `DISCO sdb` |
| **GRABAR** | Escribe una imagen byte a byte, como Etcher. | escribir `DISCO sdb` |
| **EXPULSAR** | Desmonta y apaga el dispositivo (`udisksctl power-off`). | — |
| **DIAGNOSTICO** | Solo lectura. Se ofrece también en discos blindados. | — |
| **RECUPERAR** | PhotoRec, con el destino vigilado. Solo lee el origen. | — |

Después de grabar una imagen de Linux la memoria no está rota: `REPARAR`
la devuelve a FAT32 usable.

Entre crear la partición y formatearla, REPARAR **espera activamente** a que
el sistema registre el dispositivo, y lo desmonta si algo lo automontó en
ese intervalo.

---

## Diagnóstico

- **Pasaporte** — modelo, serie, firmware, WWN, tipo, bus, capacidad,
  sectores lógico/físico, tabla, y si es disco del sistema.
- **Salud S.M.A.R.T.** — `smartctl`; si el adaptador USB no responde,
  reintenta con `-d sat`. Avisa si hay sectores reasignados (5), pendientes
  (197), incorregibles (198) o errores de enlace (199).
- **T. de acceso** — 300 lecturas de 4 KB en posiciones aleatorias. Mediana
  < 3 ms: electrónico; 3–8: no concluyente; ≥ 8: mecánico. Mide el hardware
  real cuando el adaptador miente.
- **Superficie** — mapa de colores estilo Victoria, con los umbrales
  escalados al tamaño de bloque:
  - **MUESTREO**: 1536 lecturas repartidas, un bloque por celda. Rápido;
    ve zonas lentas y daños extensos, pero puede saltarse un sector suelto.
  - **COMPLETO**: lee todo el rango `DESDE %`–`HASTA %`. Cada celda muestra
    el tiempo **medio** por bloque de su tramo; si una celda falla, se baja
    bloque a bloque para contar cuántos son ilegibles (tope de 16 por celda:
    en un disco moribundo cada lectura fallida tarda segundos).
  - Tras 12 fallos seguidos comprueba si el disco sigue existiendo. Si no,
    se colgó el adaptador, y lo dice en vez de pintar errores falsos.

**Todas las lecturas son `O_DIRECT`.** Sin eso, el sistema contesta desde la
RAM y un disco dañado parece sano. Pasó de verdad con un HDD de 1 TB en
carcasa JMicron: 10 GB escritos y "verificados" sin un error — la relectura
salía a 5 GB/s, imposible por USB, porque venía de la caché. Leyendo sin
caché, el mismo disco dio 258 errores CRC.

Se piden permisos una sola vez por prueba: el programa se llama a sí mismo
con `sudo bash limpiador-usb --interno …`, que solo acepta lecturas.

---

## Grabar imágenes

`.iso`, `.img`, `.raw`, `.bin`, y comprimidas `.xz`, `.gz`, `.zst`, `.zip`
(se descomprimen al vuelo).

- **Hash esperado** (opcional): SHA256, SHA1 o MD5, deducido de la longitud.
  Se comprueba **antes** de tocar el disco; si no coincide, no se escribe nada.
- **Firma 0x55AA**: si falta en el primer sector, avisa. Pasa con los ISO de
  instalación de Windows, que grabados en crudo no arrancan (hace falta
  Rufus o WoeUSB). No bloquea, solo avisa.
- **Bloqueo**: se niega si la imagen vive en el mismo disco de destino.
- **Verificación** activada por defecto: relee el disco sin caché y lo
  compara byte a byte con la imagen.

---

## Recuperar

Delegado en **PhotoRec** (`testdisk`), que reconoce unos 480 tipos de
archivo. Lo que aporta el programa es el guardián:

- **Nunca guardes lo recuperado en el mismo disco.** El programa resuelve a
  qué disco pertenece la carpeta de destino y **se niega** si coincide con el
  origen. No es un aviso: es un bloqueo.
- Límite honesto: esa comprobación se hace antes de abrir PhotoRec. Si dentro
  de PhotoRec eliges otra carpeta, el programa ya no puede seguirte. Acepta
  la que viene puesta.

Los archivos salen sin nombre original: esa información vivía en la tabla
que se borró.

---

## Configuración

| Archivo | Quién lo escribe | Qué lleva |
|---|---|---|
| `~/.config/limpiador-usb/config.conf` | tú, a mano | modelos, etiquetas, series bloqueadas, permitidas, límite de tamaño |
| `~/.config/limpiador-usb/preferencias` | el programa | lo que marcaste con PROTEGER / EXIMIR |
| `~/.local/state/limpiador-usb/registro.log` | el programa | cada operación, con la huella del disco |

`config.conf` **se lee, nunca se ejecuta**: una línea como
`seriales = $(rm -rf ~)` queda como una serie rara, no como un comando.
Ninguno de los dos archivos puede quitar el nivel 1, y si los borras o se
corrompen el programa arranca igual de protegido.

---

## Dependencias

Siempre presentes en Omarchy/Arch: `bash`, `util-linux` (`lsblk`, `findmnt`,
`wipefs`, `sfdisk`), `coreutils`. Opcionales, que el programa ofrece
instalar con `pacman` en el momento en que hacen falta:

| Paquete | Para |
|---|---|
| `gum` | la interfaz |
| `dosfstools`, `exfatprogs`, `ntfs-3g` | FAT32, exFAT, NTFS |
| `smartmontools` | S.M.A.R.T. |
| `testdisk` | RECUPERAR |
| `udisks2` | montar y expulsar sin sudo |

---

## Autoprueba

```bash
limpiador-usb --autoprueba
```

61 comprobaciones contra discos simulados, sin tocar hardware: un Omarchy
con raíz LUKS + btrfs, un Seagate de 4 TB, una SanDisk, un HDD de 1 TB en
carcasa JMicron, una memoria sin serie, la memoria desde la que corre el
programa, una con LUKS abierto, una tarjeta SD, un disco de bus desconocido
y una memoria formateada sin tabla de particiones. Cubre las tres
precedencias, la lectura segura de la configuración y, escaneando el propio
código, que cada operación que escribe vuelve a pasar el guardián y que las
órdenes destructivas solo viven en las funciones permitidas.

---

## Diferencias con la versión de Windows

| | Windows | Linux |
|---|---|---|
| Interfaz | ventana WPF | terminal con gum |
| Exenciones | por contenido de la serie | por serie **exacta** |
| Recuperar | tallado propio (5 familias) | PhotoRec (~480 tipos) |
| Superficie COMPLETO | peor tiempo por celda | tiempo medio por celda |
| Detección automática | vigía cada 2 s | opción `ACTUALIZAR` |

---

## Archivos

| Archivo | Qué es |
|---|---|
| `limpiador-usb` | El programa completo. |
| `instalar.sh` | Lo instala en `~/.local/bin` con lanzador e icono. `--quitar` lo desinstala. |
| `config.conf` | Plantilla de la configuración manual. |
| `limpiador-usb.svg` | Icono: negro, marco dorado y las barras `///`. |
