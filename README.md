# Limpiador de USB

Interfaz gráfica (WPF sobre PowerShell) para limpiar, formatear y expulsar
memorias USB, con un guardián que impide tocar unidades protegidas. Tú
eliges qué discos proteger, y el programa lo recuerda por número de serie;
lo que nunca se puede desproteger es el sistema.

Estilo HUD: negro y rojo, líneas doradas, esquinas cortadas, corchetes de
mira, rayas diagonales sobre lo bloqueado y tipografía monoespaciada.

---

## Cómo se abre

Doble clic en **`Iniciar Limpiador USB.cmd`**. Pide permisos de
administrador (los necesita para formatear) y abre la ventana.

También se puede abrir sin permisos: se ve todo y se puede expulsar, pero
`LIMPIAR` y `FORMATEAR` quedan deshabilitados.

Para revisar el guardián sin abrir la ventana:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "Limpiador-USB.ps1" -Autoprueba
```

---

## El guardián

Ninguna unidad se toca si dispara **al menos una** regla. Las reglas
están en tres niveles, y lo que separa un nivel de otro es **quién puede
quitarlas**.

### Nivel 1 — el núcleo. No se puede quitar

Ni desde la ventana, ni desde `config.json`, ni desde `preferencias.json`.
No hay ninguna ruta en el programa que las levante:

| Regla | Cuándo aplica |
|---|---|
| Letra del sistema (normalmente `C:`) | siempre |
| Disco de sistema o de arranque | siempre |
| Contiene `Windows`, `Program Files` o `Users` | siempre |
| Volumen declarado `Fixed` | si además el bus no es USB/SD/MMC |
| Disco interno | solo diagnóstico, ninguna escritura |

### Nivel 2 — heurísticas de fábrica. Se pueden eximir por disco

Sirven para que un disco de respaldo no se borre por descuido. No apuntan
a ningún disco concreto:

| Regla | Valor por defecto |
|---|---|
| Modelos | seagate, portable, expansion, backup plus, one touch, my passport, my book, elements, canvio, lacie |
| Tamaño | más de 2 TB se asume disco de respaldo |
| Etiquetas | ninguna (las agregas tú) |
| Letras extra | ninguna (las agregas tú) |

Un HDD externo típico dispara **dos a la vez** —modelo y tamaño— y
cualquiera bastaría por sí sola. Un detalle que importa: esos discos
reportan `BusType = USB`, así que un filtro ingenuo de "solo unidades USB"
**sí los incluiría**. Por eso el blindaje no depende de un solo criterio.

### Nivel 3 — lo que tú decides, y el programa recuerda

Cada tarjeta trae un botón que cambia según en qué estado esté ese disco:

| Botón | Qué hace |
|---|---|
| `PROTEGER` | bloquea toda escritura sobre ese disco, para siempre |
| `DESPROTEGER` | quita esa protección tuya |
| `EXIMIR` | libera el disco de las heurísticas del nivel 2 |
| `REACTIVAR` | le vuelve a aplicar las heurísticas |
| `PROTEGIDO` (gris) | bloqueado por el nivel 1: no hay nada que quitar |

**Se guarda por número de serie**, en `preferencias.json`. La serie es lo
único estable: la letra cambia sola, el número de disco cambia al
reconectar, y la etiqueta la cambia cualquiera. Un disco que no reporte
serie no se puede recordar, y el botón sale deshabilitado diciéndolo, en
vez de guardar algo que la próxima vez protegería al aparato equivocado.

### Las reglas de precedencia

Estas tres importan, y las tres están cubiertas por la autoprueba:

1. **Eximir nunca levanta el nivel 1.** Marcar como exento el disco del
   sistema no hace nada: sigue bloqueado por sus 8 reglas de núcleo. Si el
   bloqueo viene del núcleo, el botón ni se ofrece habilitado.
2. **La lista negra de series gana sobre las exenciones.** Una serie que
   esté en `Seriales` sigue bloqueada aunque también esté en `Permitidos`.
3. **Proteger gana sobre eximir.** Si una serie acaba en las dos listas,
   manda la protección.

### Se verifica tres veces

1. Al dibujar la tarjeta, para decidir si muestra botones o el candado.
2. Al pulsar el botón, antes de abrir el diálogo.
3. **Dentro del hilo que ejecuta la operación**, justo antes de borrar o
   formatear, releyendo el volumen desde el sistema.

Si algo cambió entre el paso 1 y el 3, el tercero aborta.

---

## Qué hace cada botón

- **LIMPIAR** — borra todos los archivos y carpetas de la raíz, incluidos
  ocultos y de sistema. No pasan por la papelera. Respeta
  `System Volume Information`. Se deshabilita si Windows no puede leer la
  unidad.
- **FORMATEAR** — formato rápido. `exFAT` si la unidad supera 32 GB,
  `FAT32` si no. Conserva la etiqueta actual.
- **REPARAR** — para cuando formatear falla. Limpia el atributo de solo
  lectura, borra la tabla de particiones del **disco completo**, lo
  inicializa, crea una partición nueva y la formatea. En su diálogo puedes
  elegir **esquema** (MBR o GPT) y **formato** (AUTO, FAT32, exFAT, NTFS).
  MBR es lo más compatible; GPT hace falta por encima de 2 TB. AUTO usa
  FAT32 hasta 32 GB y exFAT por encima. Entre crear
  la partición y formatearla espera activamente a que Windows registre el
  volumen: con un retardo fijo, `Format-Volume` fallaba unas veces sí y
  otras no con *"no encontró objetos MSFT_Volume"*.
- **GRABAR** — escribe una imagen de disco (`.iso`, `.img`, `.bin`, `.raw`,
  `.gz`, `.zip`) byte a byte sobre el disco, igual que balenaEtcher.
- **EXPULSAR** — expulsión segura. Funciona también en discos **sin letra
  asignada** (lo normal después de grabar una imagen de Linux): en ese caso
  no puede usar el Shell de Windows y expulsa el dispositivo directamente
  con `IOCTL_STORAGE_EJECT_MEDIA`.
- **PROTEGER / EXIMIR** — no toca el disco: guarda tu decisión sobre él en
  `preferencias.json`, por número de serie. Ver [el guardián](#el-guardián).
  Aparece también en las unidades blindadas, porque es justo ahí donde
  hace falta para liberarlas — salvo cuando el bloqueo es del nivel 1, y
  entonces sale en gris.

Qué necesita cada botón:

| Botón | Requiere |
|---|---|
| LIMPIAR | volumen que Windows pueda leer |
| FORMATEAR | al menos una letra asignada |
| REPARAR, GRABAR, EXPULSAR | nada: trabajan sobre el disco |
| PROTEGER / EXIMIR | que el disco reporte número de serie |

Después de grabar una imagen de Linux, la memoria se queda sin letra porque
Windows no sabe montar ISO9660. **No está rota**: `REPARAR` la devuelve a
FAT32 usable, y `EXPULSAR` sigue funcionando.

`LIMPIAR` y `FORMATEAR` piden que escribas la letra de la unidad (`D:`)
para habilitar el botón de ejecutar. `REPARAR` pide `DISCO N`, porque su
alcance es el disco físico entero y no una sola letra.

### Por qué REPARAR es más seguro que diskpart

En diskpart escribes `select disk 1` y el programa te cree. Pero los
números de disco cambian al reconectar o reiniciar: el disco 1 de hoy puede
ser otro aparato mañana, y `clean` no pregunta.

`REPARAR` guarda el **número de serie** del disco cuando dibuja la tarjeta,
y antes de borrar nada vuelve a leer el disco y compara la serie. Si no
coincide, aborta. Además verifica que el disco entero — no solo la
partición que elegiste — no contenga ninguna unidad blindada, que no sea de
sistema ni de arranque, que su bus sea extraíble y que no exceda el límite
de tamaño.

---

## DIAGNOSTICO (estilo Victoria HDD/SSD)

Botón `DIAGNOSTICO` en cada tarjeta. Abre una ventana propia con tres
bloques:

- **Pasaporte** — modelo, serie, firmware, HDD o SSD, RPM, bus, capacidad,
  tamaño de sector lógico y físico, estilo de particiones, si es disco de
  sistema o de arranque.
- **Salud S.M.A.R.T.** — estado, temperatura y máxima, horas de encendido,
  desgaste, ciclos y contadores de errores de lectura y escritura, vía
  `Get-StorageReliabilityCounter`.
- **Test de superficie** — lectura secuencial del disco midiendo el tiempo
  de respuesta de cada bloque y pintándolo en el mapa de colores, igual que
  Victoria. Rango configurable en %, tamaño de bloque de 256 KB a 8 MB,
  contador por franja de latencia y botón de detener.

### `T. DE ACCESO`: saber si el disco es mecánico

Botón aparte. Hace 300 lecturas de 4 KB en posiciones aleatorias repartidas
por todo el disco y mide la latencia de cada una:

| Mediana | Veredicto |
|---|---|
| < 3 ms | electrónico (SSD o memoria flash) |
| 3 – 8 ms | no concluyente |
| ≥ 8 ms | mecánico (disco duro con platos) |

Un disco mecánico tiene que **mover el cabezal** en cada salto, y eso cuesta
10-20 ms. Uno de estado sólido no tiene partes móviles y responde por debajo
del milisegundo. El puente USB añade su parte, pero la diferencia es de un
orden de magnitud, así que sigue siendo concluyente.

Las posiciones se reparten por todo el disco a propósito: leyendo siempre la
misma zona respondería la caché y no el medio.

Sirve para cuando el adaptador miente. Un puente **JMicron**, por ejemplo,
reporta su propio nombre como modelo, series de relleno tipo `123467`, y un
`MediaType` que puede no corresponder al disco que lleva dentro. Esta prueba
mide el hardware real en vez de creerse lo que dice.

### Es de solo lectura, y eso importa

El dispositivo se abre siempre con `RawDisk::Abrir($ruta, $false)`, que
pide únicamente `GENERIC_READ`. **Por eso el diagnóstico funciona incluso
en unidades blindadas** — y de hecho el disco de respaldo es el que más
interesa vigilar. La autoprueba comprueba que el flujo abierto tenga
`CanWrite = False`.

Con `VER TODOS LOS DISCOS` se listan también los discos internos. Esos
quedan marcados y el guardián les añade la regla
`SOLO DIAGNOSTICO, NINGUNA ESCRITURA PERMITIDA`: aparecen con el botón de
diagnóstico y con ningún botón de escritura.

### Cuánto tarda

Un barrido completo lee todo el disco, así que va a la velocidad de lectura
del medio:

| Disco | Velocidad | Barrido completo |
|---|---|---|
| SanDisk 15 GB USB 2.0 | ~24 MB/s | ~11 min |
| Seagate 3.6 TB USB HDD | ~120 MB/s | ~9 h |
| NVMe 954 GB | ~2 GB/s | ~8 min |

Para discos grandes conviene barrer por tramos con los campos `DESDE %` y
`HASTA %`, o usar el modo `MUESTREO`.

### `COMPLETO` contra `MUESTREO`

El botón `MODO` cambia entre los dos:

- **COMPLETO** lee todo el disco. Encuentra hasta un sector malo aislado,
  pero tarda lo que tarde el medio.
- **MUESTREO** lee **un bloque por celda del mapa** (1536 lecturas
  repartidas por toda la superficie). Dibuja el mismo mapa en una fracción
  del tiempo. Detecta zonas lentas y daños extensos, pero **puede pasar por
  alto un sector malo suelto**.

| Disco | COMPLETO | MUESTREO |
|---|---|---|
| SanDisk 14.9 GB USB 2.0 | ~10 min | ~1 min |
| SSD 238 GB USB 2.0 | ~3 h | ~1 min |
| HDD 465 GB USB | ~1 h 20 | ~15 s |
| Seagate 3.7 TB | ~9 h | ~12 s |

La lógica: en COMPLETO el tiempo crece con el tamaño del disco; en MUESTREO
es constante, porque siempre son 1536 lecturas. Por eso el ahorro crece con
el disco — de 10x en una memoria pequeña a más de 2000x en el Seagate.

Uso razonable: **MUESTREO primero**. Si sale limpio y uniforme, el disco
está bien. Si aparece una zona sospechosa, un COMPLETO de ese tramo con
`DESDE %` / `HASTA %` lo confirma.

### El tamaño de bloque no es una palanca de velocidad

Medido sobre la SanDisk Cruzer Fit (USB 2.0):

| Bloque | Velocidad |
|---|---|
| 256 KB | ~17 MB/s |
| 1 MB | ~24 MB/s |
| 8 MB | ~24 MB/s |

Sube hasta 1 MB y ahí se acaba: a partir de ese punto el cuello de botella
es el bus, no el coste de pedir cada lectura. Lo que sí cambia el bloque es
la **resolución**: bloques pequeños localizan mejor un sector lento
concreto, bloques grandes lo diluyen en un promedio. 1 MB es el equilibrio.

**Bloques grandes con puentes USB:** un solo `Read` puede devolver menos
bytes de los pedidos — los puentes USB tienen un tamaño máximo de
transferencia y recortan las peticiones grandes. Un adaptador JMicron
devolvía ~570 KB por cada petición de 8 MB. El barrido insiste hasta
completar el bloque (`$script:LeerBloque`) y avanza por lo realmente leído;
sin eso, marcaría como revisado lo que nunca llegó a leer, y la velocidad
saldría 14 veces más baja de lo real. La autoprueba lo verifica con un
flujo que recorta a propósito.

Si aun así ves velocidades mucho menores con 8 MB que con 1 MB, baja el
tamaño de bloque: ese adaptador no lleva bien las peticiones grandes.

### Si el disco desaparece a media revisión

Las carcasas USB baratas se cuelgan bajo carga sostenida. Cuando pasa, el
disco deja de responder y Windows lo quita de `Get-Disk`, aunque
`Get-PnpDevice` lo siga mostrando como `OK`.

Sin protección, cada lectura fallaría y el mapa se llenaría de errores: el
programa te diría que el disco está destrozado cuando solo se colgó el
adaptador. Por eso, tras **12 fallos seguidos** el barrido comprueba si el
disco sigue existiendo, y si no, aborta explicando qué pasó en vez de
seguir contando errores falsos.

La solución es desconectar, esperar unos segundos y volver a conectar,
mejor en un puerto directo del equipo. Y no barrer 238 GB de una sentada en
una carcasa así: mejor por tramos.

### Escala de colores

Los umbrales base son los de Victoria para un bloque de 128 KB — verde
< 5 ms, verde lima < 20 ms, oro < 50 ms, naranja < 200 ms, rojo < 600 ms,
rojo oscuro por encima, y cian para errores de lectura.

**Se escalan con el tamaño de bloque**, y la leyenda muestra siempre los
valores reales. Victoria puede usar umbrales fijos porque su bloque es
fijo; aquí es configurable, y sin escalar la escala mentiría: un SSD USB a
23 MB/s tarda 43 ms por bloque de 1 MB (todo dorado) y 348 ms con bloques
de 8 MB (todo rojo), siendo exactamente el mismo disco.

Con el escalado, ese disco cae en la misma franja con cualquier bloque, y
un sector lento sigue destacando. La autoprueba lo verifica con discos
simulados de 23, 120 y 2000 MB/s.

Un disco sano es casi todo del mismo color; lo que importa son las celdas
que se salen. El mapa agrupa muchos bloques por celda y cada celda muestra
**el peor** tiempo encontrado dentro de ella.

Mientras el barrido corre, los ajustes de rango y tamaño de bloque quedan
deshabilitados: cambiarlos no afecta al barrido en curso y el control
mostraría un valor que no es el que se está usando.

---

## El icono

`limpiador.ico` se genera con `Crear icono.ps1`, dibujado con el mismo
lenguaje que la interfaz: cuadro negro con las esquinas cortadas, marco y
corchetes dorados, y las tres barras rojas `///`.

Lleva siete tamaños (16 a 256 px) porque Windows elige uno u otro según
dónde lo muestre. Los corchetes solo se dibujan a partir de 32 px: a 16 px
no caben y ensucian, así que ahí sobreviven solo el marco y las barras.

Se aplica en tres sitios: la ventana principal, la de diagnóstico y el
acceso directo. Sin él, Windows pone el icono de PowerShell y se pierde
todo el efecto.

Para cambiarlo, edita los colores o la forma en `Crear icono.ps1` y
vuélvelo a ejecutar.

### Los símbolos van dibujados, no en fuente

El candado de las unidades blindadas es geometría vectorial
(`New-Candado`), no un carácter de una fuente de símbolos. Las fuentes
cambian de un equipo a otro y un glifo que no exista sale como un cuadro
vacío. Dibujado, se ve igual en todas partes y escala sin perder nitidez.

---

## RECUPERAR archivos borrados o formateados

Botón `RECUPERAR` en cada tarjeta. Busca archivos por sus **firmas** —
tallado, lo mismo que hace PhotoRec— y los rescata a otro disco.

Funciona **aunque el disco esté formateado**, porque no depende de la tabla
de archivos: reconoce que en tal posición empieza un JPEG y lo sigue hasta
su marca de fin.

Tipos que reconoce: **JPEG, PNG, GIF, PDF** y la familia **ZIP**, con el
subtipo deducido del contenido (`.docx`, `.xlsx`, `.pptx`).

### Es de solo lectura sobre el origen

El disco del que se recupera se abre con `GENERIC_READ` y jamás se escribe.
Por eso `RECUPERAR` aparece **también en unidades blindadas** — y ahí es
justamente donde más falta hace, porque el disco de respaldo es del que más
duele perder algo.

### La regla de oro, y el programa la hace cumplir

**Nunca guardes lo recuperado en el mismo disco del que estás
recuperando.** Cada archivo que escribas ahí puede machacar justo lo que
todavía no has rescatado.

El programa resuelve a qué disco físico pertenece la carpeta que elijas
(`Get-DiscoDeRuta`) y **se niega** si coincide con el origen. No es un
aviso: es un bloqueo.

### Lo que NO hace, dicho claramente

- **No recupera nombres ni carpetas.** Salen como `jpeg_00001.jpg`,
  `pdf_00002.pdf`. Esa información vivía en la tabla que el formateo borró.
- **Solo recupera archivos contiguos.** Los que estaban fragmentados salen
  incompletos o corruptos.
- **No hace nada si se sobrescribió.** Un formateo rápido no borra los
  datos, solo la tabla — ahí sí hay rescate. Un formateo completo, o un
  `GRABAR`, los machaca de verdad y no hay nada que hacer.
- **PhotoRec cubre 480 tipos de archivo** y esto cubre cinco familias. Si
  buscas algo raro, usa PhotoRec. Lo que aquí tienes de más es el guardián.

### Cómo está probado

La autoprueba fabrica un "disco" con un JPEG, un PNG y un PDF reales
enterrados entre datos aleatorios —como quedaría tras un formateo rápido— y
comprueba tres cosas:

```
archivos rescatados: 3 (jpeg_00001.jpg, pdf_00001.pdf, png_00001.png)  -> OK
identicos al original: 3 de 3                                          -> OK
el disco de origen queda intacto                                       -> OK
```

La búsqueda de firmas está en **C# compilado** (`RawDisk.BuscarPatrones`),
por lo mismo que la comparación del verificado: recorrer megabytes byte a
byte desde PowerShell da menos de 1 MB/s y sería inservible.

### Por qué una firma corta no sirve

La primera versión usaba `FF D8 FF` para JPEG — tres bytes. En datos
aleatorios eso coincide **una vez cada 16 MB**: unos 950 JPEG falsos en una
memoria de 15 GB. Cada falso abre un archivo que nunca encuentra su marca
de fin y se queda abierto consumiendo recursos.

Ahora se exige también el marcador (`FF D8 FF E0/E1/DB/EE`), cuatro bytes:
un falso cada 4 GB. Y los archivos que superan su tamaño máximo sin
encontrar la cola **se descartan**, porque casi siempre son eso: una
coincidencia falsa.

### Una sola pasada por bloque

La primera versión recorría cada bloque **una vez por archivo abierto**
buscando su marca de fin. Con 64 abiertos eso son 260 MB recorridos y 256 MB
escritos por cada 4 MB leídos — el barrido caía a 0.8 MB/s en un disco que
lee a 23.

Ahora las cabeceras y todas las colas se buscan en **una sola llamada**, y
el máximo de archivos abiertos a la vez es 8 (`$script:MaxAbiertos`).

---

## La consola

Las **dos** consolas —la principal y la de la ventana de diagnóstico— son
`RichTextBox` de solo lectura, así que se comportan como una terminal
normal:

- **Seleccionar con el mouse** y `Ctrl+C`, o `Ctrl+A` para todo.
- **Clic derecho** → copiar selección, seleccionar todo, copiar todo el
  registro, guardarlo en un archivo, o limpiar la consola.
- Botones `COPIAR TODO`, `GUARDAR` y `LIMPIAR` en la cabecera.

Se usa `RichTextBox` y no `TextBlock` porque en WPF el `TextBlock` no
permite seleccionar texto, y lo que más falta hace es poder copiar un error
para pegarlo en otro lado.

---

## Detección automática

Un vigía revisa cada 2 segundos si cambiaron las unidades conectadas y
re-escanea solo cuando algo cambió. Al conectar el Seagate aparece de
inmediato la franja roja `/// UNIDAD BLINDADA CONECTADA` arriba, y su
tarjeta se ordena siempre primero en la lista.

---

## Los dos archivos de configuración

Están separados a propósito: `config.json` lo editas tú a mano y lleva
comentarios, `preferencias.json` lo escribe el programa. Si el programa
reescribiera `config.json`, se comería esos comentarios.

| Archivo | Quién lo escribe | Qué lleva |
|---|---|---|
| `config.json` | tú, a mano | reglas fijas: letras, series, modelos, etiquetas, límite de tamaño |
| `preferencias.json` | la ventana | lo que marcaste con `PROTEGER` / `EXIMIR`, por número de serie |

Ninguno de los dos puede quitar el nivel 1. Si los borras o los dejas
inválidos, el programa arranca igual de protegido — perder una exención
deja el programa **más** protegido, nunca menos.

### config.json

```json
{
  "Letras":     ["H"],
  "Seriales":   ["ABC12345"],
  "Nombres":    ["kingston"],
  "Etiquetas":  ["fotos boda"],
  "Protegidos": ["NA0XYZ12"],
  "Permitidos": ["WX21A9B3"],
  "TamMaxGB":   1024
}
```

`TamMaxGB` solo se acepta si es **menor** que 2048.

### `Permitidos`: discos externos de marca bloqueada

Para trabajar con un HDD externo propio hay un problema: la lista de
modelos bloquea `seagate`, `my passport`, `elements`, `canvio`, `lacie`…
que son justo las marcas de discos externos. Y si el disco pasa de 2 TB,
el límite de tamaño lo bloquea también.

`Permitidos` lleva números de serie que quedan **exentos de las
heurísticas del nivel 2** —modelo, etiqueta, tamaño y las letras que
agregaste— y de nada más. Nunca puede saltarse:

- el nivel 1 completo (sistema, arranque, carpetas de Windows, bus fijo),
- la lista negra de series: una serie en `Seriales` sigue bloqueada aunque
  también esté en `Permitidos` — está probado en la autoprueba,
- una protección que hayas puesto tú con el botón.

Es lo mismo que hace el botón `EXIMIR` de cada tarjeta, pero fijado a mano.
Lo normal es usar el botón; esto es para cuando quieres que la regla viaje
con el archivo de configuración.

La serie de un disco se ve en su tarjeta, o con:

```bash
powershell -Command "Get-Disk | Select-Object Number,FriendlyName,SerialNumber"
```

### preferencias.json

No hace falta tocarlo: lo escribe la ventana. Se puede borrar sin miedo.

```json
{
  "Protegidos": ["USB-A1B2C3"],
  "Exentos":    ["WX21A9B3"]
}
```

---

## Grabar imágenes (en vez de balenaEtcher)

`GRABAR` hace lo mismo que Etcher, sin salir del programa: bloquea y
desmonta los volúmenes del disco, abre `\\.\PhysicalDriveN`, vuelca los
bytes de la imagen desde el sector cero en bloques de 4 MB, y al soltar los
handles Windows remonta el disco con su contenido nuevo.

**Nota sobre el desmontaje:** `Set-Disk -IsOffline` *no* sirve aquí —
Windows responde `Removable media cannot be set to offline`. Hay que abrir
cada volumen (`\\.\D:`), aplicarle `FSCTL_LOCK_VOLUME` y
`FSCTL_DISMOUNT_VOLUME`, y mantener el handle abierto durante toda la
escritura: mientras viva, Windows no lo vuelve a montar. Al cerrarlo se
libera solo. Es lo que hacen Rufus y Etcher por dentro.

**Por qué no se integró Etcher directamente:** su CLI está descontinuada y
no acepta un destino por línea de comandos — el destino siempre se elige
dentro de su interfaz. Es decir, el blindaje no puede seguirlo hasta ahí, y
el Seagate aparecería en su lista. Haciéndolo aquí, el guardián sí aplica:
mismo `Get-RazonesBloqueoDisco` que usa `REPARAR`, con verificación de
identidad por número de serie antes de escribir un solo byte.

- La confirmación pide `DISCO N`, porque el alcance es el disco entero.
- **Hash esperado** (opcional): pega el SHA256, SHA1 o MD5 que publica la
  distro y el programa comprueba la imagen **antes** de tocar el disco. El
  algoritmo se deduce de la longitud (32, 40 o 64 caracteres). Si no
  coincide, aborta sin escribir nada. La imagen está en el disco local, así
  que comprobarla cuesta segundos.
- Barra de progreso con MB/s, tiempo restante y botón de cancelar.
- **Verificación** activada por defecto: al terminar relee el disco y lo
  compara byte a byte con la imagen. Detecta memorias que aceptan
  escrituras y devuelven datos distintos. Se puede desmarcar, pero suele
  costar poco: las memorias leen bastante más rápido de lo que escriben
  (la Cruzer Fit de pruebas: 24 MB/s leyendo contra 5.3 escribiendo,
  así que verificar añade ~20% al tiempo, no el doble).

### Por qué tarda lo que tarda

El límite es casi siempre la memoria, no el programa. Un grabado de 6.2 GB
sobre esa Cruzer Fit tomó 1178 s = 5.3 MB/s, que es su velocidad real de
escritura. Para ir en serio más rápido hace falta una memoria USB 3.0; ahí
el mismo grabado baja a un par de minutos.

El dispositivo se abre **sin** `FILE_FLAG_WRITE_THROUGH`, que forzaría cada
bloque al medio antes de continuar e impediría encadenar escrituras; se
vacía una sola vez al final con `FlushFileBuffers`. Ese vaciado final puede
tardar y aparece como fase propia en la barra, para que no parezca colgado
al 100%.

La comparación de bloques al verificar está en **C# compilado**
(`RawDisk.PrimeraDiferencia`), no en PowerShell. Hecha con un bucle de
PowerShell corría a 0.8 MB/s — millones de iteraciones interpretadas por
bloque — y verificar 3 GB tardaba una hora. Compilada va a ~1,300 MB/s, así
que el límite vuelve a ser la velocidad de lectura de la memoria. La
autoprueba mide esto y falla si baja de 200 MB/s.

### Limitación importante

La escritura cruda sirve para imágenes *isohybrid* de Linux y archivos
`.img`. **Los ISO de instalación de Windows no arrancan así** — necesitan
partición FAT32 con archivos copiados y gestor de arranque, que es lo que
hace Rufus. Etcher tiene exactamente la misma limitación.

El programa lo detecta leyendo el primer sector: si falta la firma de
arranque `0x55AA` en los bytes 510–511, avisa antes de grabar. No lo
bloquea, solo te lo dice.

---

## Si el formateo falla con "the drive is read only"

**Prueba primero `REPARAR`.** Ese error suele venir de una tabla de
particiones rota, no de una memoria muerta: si el volumen no monta,
`Format-Volume` falla con "read only" aunque el disco acepte escrituras
perfectamente.

Pasó exactamente eso con la SanDisk Cruzer Fit de pruebas. Todo apuntaba
a un controlador en modo solo-lectura permanente — Windows reportaba el
disco sano y `IsReadOnly = False`, `diskpart` decía `Solo lectura: No`, los
volúmenes salían como `No usable`, y las particiones solo cubrían 7.4 de
16 GB. El diagnóstico de "memoria al final de su vida" era equivocado:
`REPARAR` borró la tabla de particiones, la recreó, y la memoria volvió
sana y con sus 16 GB completos.

Si `REPARAR` tampoco funciona, queda intentarlo a mano por si hay un
atributo de solo lectura que solo diskpart ve. En consola de
**administrador**:

```bash
diskpart
```

Dentro de diskpart, **primero `list disk`** y confirma el número por el
tamaño. Los números de disco cambian entre reinicios y reconexiones: nunca
uses uno recordado.

```
list disk
select disk N
attributes disk clear readonly
clean
exit
```

`clean` borra la tabla de particiones de ese disco. Por eso el paso de
verificar el número no es opcional.

Si después de eso sigue rechazando escrituras, entonces sí es probable que
el controlador haya entrado en modo de solo lectura permanente por
desgaste. Eso no se repara por software.

Nota: `REPARAR` desde el programa hace lo mismo que esta secuencia, pero
verifica el número de serie del disco antes de borrar. `select disk N`
confía en un número que cambia al reconectar; el programa no.

---

## Llevarlo a otra computadora

No hace falta compilar nada. Windows 10 y 11 ya traen todo lo que usa.

¿La otra computadora es Linux (Omarchy, Arch…)? Esta versión no corre ahí:
lleva la carpeta [`linux/`](linux/README.md) y ejecuta su `instalar.sh`.

1. Copia **la carpeta entera** a la otra máquina (por USB, red, donde sea).
2. Ahí, doble clic en **`Crear acceso directo.cmd`**.
3. Aparece *Limpiador de USB* en el Escritorio, con icono y marcado para
   abrirse **siempre como administrador**.

### ¿Y hacerlo un `.exe`?

Se puede, con el módulo `ps2exe`:

```bash
powershell -Command "Install-Module ps2exe -Scope CurrentUser; Invoke-PS2EXE '.\Limpiador-USB.ps1' '.\Limpiador-USB.exe' -requireAdmin -noConsole -STA"
```

Pero **no lo recomiendo**, por tres razones concretas:

- **Los antivirus lo marcan.** Un ejecutable que lleva PowerShell dentro es
  un patrón clásico de malware. Windows Defender y otros lo bloquean muy a
  menudo, y acabarías peleando con excepciones en cada máquina.
- **No gana nada.** Sigue siendo PowerShell por dentro; no va más rápido ni
  se vuelve independiente.
- **Se pierde lo bueno.** Ahora mismo puedes abrir el `.ps1` y leer o
  cambiar las reglas de blindaje. Compilado, es una caja negra.

El acceso directo te da lo mismo que buscas —icono, doble clic, elevación
automática— sin ninguno de esos problemas. El programa ya resuelve su
propia carpeta con `Get-CarpetaPrograma`, así que funcionaría igual si algún
día decides empaquetarlo.

---

## Archivos

| Archivo | Qué es |
|---|---|
| `Iniciar Limpiador USB.cmd` | Lanzador con elevación. Este es el que se abre. |
| `Crear acceso directo.cmd` | Crea el acceso directo en el Escritorio. Se ejecuta una vez. |
| `Crear acceso directo.ps1` | El trabajo real del anterior. Admite `-Destino` y `-Nombre`. |
| `Limpiador-USB.ps1` | El programa completo. |
| `config.json` | Protecciones adicionales opcionales, editadas a mano. |
| `preferencias.json` | Lo que marcaste con PROTEGER / EXIMIR. Lo crea el programa. |
| `limpiador.ico` | Icono de las ventanas y del acceso directo: negro, marco dorado y las barras `///`. |
| `Crear icono.ps1` | Regenera `limpiador.ico`. Solo si quieres retocar el diseño. |
| `linux/` | Versión para Linux / Omarchy, con el mismo guardián. Programa aparte: ver [su README](linux/README.md). |

---

## Notas técnicas

- Corre sobre Windows PowerShell 5.1 (`powershell.exe -STA`), que trae WPF
  completo. También funciona en PowerShell 7.
- Las operaciones corren en un runspace aparte para no congelar la ventana;
  se comunican con la interfaz por una cola sincronizada que un
  `DispatcherTimer` vacía cada 200 ms.
- **`GetNewClosure()` aísla el ámbito de script.** Dentro de una closure
  creada en una función, leer `$script:X` devuelve **NULL** y escribirlo no
  sale de la closure. Eso tumbaba la ventana de diagnóstico entera al pulsar
  INICIAR (`$script:Buckets[0..5]` → "no se puede indizar en una matriz
  nula" → excepción no controlada en WPF → el proceso muere). La regla:
  capturar en variables locales **antes** de crear la closure, y para
  escribir, usar un hashtable compartido (`$script:Opciones`) cuya
  referencia sí sobrevive. La autoprueba escanea el archivo y falla si
  alguna closure vuelve a tocar `$script:`.
- **El `^` de continuación de línea en `.cmd` no funciona dentro de comillas.**
  Fuera de ellas sí (por eso `Iniciar Limpiador USB.cmd` funciona con una
  sola continuación), pero en cuanto la línea que continúa está dentro de
  una cadena entrecomillada, el caret pierde su valor, la orden se parte y
  CMD intenta ejecutar el fragmento suelto como si fuera un programa. Por
  eso el creador de accesos directos es un `.ps1` y el `.cmd` solo lo llama.
- El separador `·` se genera con `[char]0x00B7` en vez de escribirse
  literal, porque PowerShell 5.1 lee los `.ps1` sin BOM como ANSI y el
  carácter saldría partido.
- El porcentaje de uso usa `[math]::Min(1.0, ...)` con decimal explícito:
  con `1` entero, PowerShell elige la sobrecarga de enteros y trunca la
  fracción a cero.
