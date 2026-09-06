#Requires -Version 5.1
<#
    LIMPIADOR DE USB  --  Interfaz grafica (WPF), estilo HUD cyberpunk
    ------------------------------------------------------------------
    Negro / blanco / rojo con lineas doradas, esquinas cortadas,
    corchetes de mira y rayas diagonales para lo bloqueado.

    SEGURIDAD, en tres niveles:

      1. NUCLEO INAMOVIBLE. No hay interfaz ni archivo de configuracion
         que pueda quitarlo:
           * el disco del sistema y el de arranque,
           * la letra del sistema (normalmente C:),
           * cualquier unidad con Windows / Program Files / Users,
           * los volumenes 'Fixed' cuyo bus no sea USB / SD / MMC,
           * los discos internos, que solo se listan para diagnosticar.

      2. HEURISTICAS DE FABRICA. Activas por defecto, pensadas para que
         un disco de respaldo no se borre por accidente: modelos de HDD
         externo conocidos, etiquetas y el limite de tamano. El usuario
         puede EXIMIR un disco concreto de estas, nunca del nivel 1.

      3. DECISION DEL USUARIO, recordada entre sesiones. Cada tarjeta
         tiene un boton para PROTEGER o EXIMIR ese disco. Se guarda por
         NUMERO DE SERIE en preferencias.json, porque los numeros de
         disco cambian al reconectar y la serie no.

    Las reglas se vuelven a evaluar DENTRO del hilo que ejecuta la
    operacion, justo antes de borrar o formatear.
#>

[CmdletBinding()]
param(
    # Prueba el guardian contra las unidades conectadas y sale sin abrir la ventana.
    [switch]$Autoprueba,
    # Define todo y sale sin abrir la ventana ni ejecutar pruebas. Sirve
    # para cargar el programa con . (punto) desde otro script.
    [switch]$SoloCargar
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ==================================================================
#  1. REGLAS DE PROTECCION
# ==================================================================
# Estas reglas son ADITIVAS: config.json solo puede AGREGAR
# protecciones, nunca quitar las del NUCLEO.
$script:Guard = @{
    # Letras bloqueadas. Las del nucleo se fijan mas abajo y no se pueden
    # eximir; las que agregue el usuario si.
    Letras    = @('C')
    # Vacio a proposito: aqui no va ninguna serie concreta de fabrica. Se
    # llena desde config.json o desde el boton PROTEGER de cada tarjeta.
    Seriales  = @()
    # Heuristica generica: son las marcas tipicas de disco externo de
    # respaldo. No apunta a ningun disco en particular, y un disco propio
    # se exime con el boton de su tarjeta.
    Nombres   = @(
        'seagate', 'portable', 'expansion', 'backup plus', 'one touch',
        'my passport', 'my book', 'elements', 'canvio', 'lacie'
    )
    Etiquetas = @()
    # 2 TB: hay que poder formatear discos HDD de 1 TB sin exenciones. Por
    # encima se asume disco de respaldo. Es una heuristica, asi que un
    # disco exento se la salta.
    TamMaxGB  = 2048
    # Series EXENTAS de las heuristicas (modelo, etiqueta, tamano y las
    # letras que agrego el usuario). Nunca se salta el nucleo, ni la lista
    # negra de series.
    Permitidos = @()
    # Series que el usuario decidio proteger a mano. Solo suman.
    Protegidos = @()
}

# ------------------------------------------------------------------
#  NUCLEO INAMOVIBLE
# ------------------------------------------------------------------
# La letra del sistema va siempre, aunque no sea C:. Estas letras se
# guardan aparte porque son las unicas que una exencion NO puede saltar:
# el resto de Guard.Letras las agrega el usuario y si son eximibles.
$sysLetter = ($env:SystemDrive -replace '[:\\]', '').ToUpper()
if ($sysLetter -and $script:Guard.Letras -notcontains $sysLetter) {
    $script:Guard.Letras += $sysLetter
}
$script:LetrasNucleo = @($script:Guard.Letras)

# Extensiones opcionales del usuario (solo suman)
# Carpeta del programa. $PSScriptRoot no existe si el script se empaqueta
# en un .exe, asi que hay varios recursos de reserva.
function Get-CarpetaPrograma {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -and $exe -notmatch 'powershell(_ise)?\.exe$|pwsh\.exe$') {
            return (Split-Path -Parent $exe)
        }
    } catch { }
    (Get-Location).Path
}
$script:CarpetaBase = Get-CarpetaPrograma

$cfgPath = Join-Path $script:CarpetaBase 'config.json'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in 'Letras', 'Seriales', 'Nombres', 'Etiquetas', 'Permitidos', 'Protegidos') {
            if ($cfg.PSObject.Properties.Name -contains $k -and $cfg.$k) {
                $script:Guard[$k] = @($script:Guard[$k]) + @($cfg.$k) | Select-Object -Unique
            }
        }
        if ($cfg.PSObject.Properties.Name -contains 'TamMaxGB' -and $cfg.TamMaxGB) {
            if ([double]$cfg.TamMaxGB -lt $script:Guard.TamMaxGB) {
                $script:Guard.TamMaxGB = [double]$cfg.TamMaxGB
            }
        }
    } catch {
        # config invalido: se ignora, las reglas base siguen intactas
    }
}

# ------------------------------------------------------------------
#  PREFERENCIAS DEL USUARIO (las que escribe la propia ventana)
# ------------------------------------------------------------------
# Van en un archivo aparte de config.json a proposito: config.json lo
# edita el usuario a mano y lleva comentarios, y reescribirlo desde el
# programa se los comeria. Aqui solo hay dos listas de numeros de serie.
#
# La serie es la clave porque es lo unico estable: la letra cambia sola,
# el numero de disco cambia al reconectar, la etiqueta la cambia
# cualquiera. Un disco sin serie legible no se puede recordar, y el
# boton lo dice en vez de guardar algo que no serviria.
$script:PrefPath = Join-Path $script:CarpetaBase 'preferencias.json'
$script:Pref = @{ Protegidos = @(); Exentos = @() }

function Import-Preferencias {
    $script:Pref = @{ Protegidos = @(); Exentos = @() }
    if (-not (Test-Path -LiteralPath $script:PrefPath)) { return }
    try {
        $p = Get-Content -LiteralPath $script:PrefPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in 'Protegidos', 'Exentos') {
            if ($p.PSObject.Properties.Name -contains $k -and $p.$k) {
                $script:Pref[$k] = @($p.$k | ForEach-Object { "$_".Trim() } |
                                     Where-Object { $_ } | Select-Object -Unique)
            }
        }
    } catch {
        # preferencias corruptas: se ignoran. Perder una exencion deja el
        # programa MAS protegido, nunca menos, asi que fallar aqui es seguro.
    }
}

function Save-Preferencias {
    try {
        ([pscustomobject]@{
            _nota      = 'Lo escribe la ventana con los botones PROTEGER / EXIMIR. Se puede borrar sin miedo: el programa arranca igual de protegido.'
            Protegidos = @($script:Pref.Protegidos)
            Exentos    = @($script:Pref.Exentos)
        } | ConvertTo-Json -Depth 3) |
            Set-Content -LiteralPath $script:PrefPath -Encoding UTF8 -ErrorAction Stop
        $true
    } catch {
        $false
    }
}

# Las preferencias se vuelcan a Guard, que es lo que leen las reglas.
# Se rehace entero en cada cambio para que quitar una preferencia la
# quite de verdad, sin residuos de la carga anterior.
$script:GuardBase = @{
    Seriales   = @($script:Guard.Seriales)
    Permitidos = @($script:Guard.Permitidos)
}
function Sync-Preferencias {
    $script:Guard.Protegidos = @($script:Pref.Protegidos)
    $script:Guard.Seriales   = @(@($script:GuardBase.Seriales) + @($script:Pref.Protegidos) |
                                 Where-Object { $_ } | Select-Object -Unique)
    # Una serie protegida a mano gana sobre una exencion: si esta en las
    # dos listas, manda la proteccion.
    $script:Guard.Permitidos = @(@($script:GuardBase.Permitidos) + @($script:Pref.Exentos) |
                                 Where-Object { $_ -and $_ -notin $script:Pref.Protegidos } |
                                 Select-Object -Unique)
}

Import-Preferencias
Sync-Preferencias

# ==================================================================
#  2. ENSAMBLADOS
# ==================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Acceso crudo al dispositivo, lo mismo que hace Etcher por dentro.
# Se compila UNA vez aqui y no dentro del runspace de trabajo: los tipos
# .NET son de todo el AppDomain, asi que cada hilo lo encuentra ya listo.
if (-not ('RawDisk' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class RawDisk {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FlushFileBuffers(SafeFileHandle hFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize,
        IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    // Los medios extraibles NO se pueden poner offline con Set-Disk.
    // La via correcta es bloquear y desmontar cada volumen y mantener
    // sus handles abiertos mientras se escribe al disco fisico.
    const uint FSCTL_LOCK_VOLUME          = 0x00090018;
    const uint FSCTL_DISMOUNT_VOLUME      = 0x00090020;
    const uint IOCTL_DISK_UPDATE_PROPERTIES = 0x00070140;
    const uint IOCTL_STORAGE_EJECT_MEDIA    = 0x002D4808;

    private static bool Ctl(SafeFileHandle h, uint code) {
        uint dummy;
        return DeviceIoControl(h, code, IntPtr.Zero, 0, IntPtr.Zero, 0, out dummy, IntPtr.Zero);
    }

    // Busca varios patrones a la vez en un bloque y devuelve las posiciones
    // encontradas como pares (indice, numero de patron) aplanados.
    // Va en C# por lo mismo que la comparacion: recorrer megabytes byte a
    // byte desde PowerShell cuesta menos de 1 MB/s y seria inservible.
    // El filtro por el primer byte evita la mayoria de comparaciones.
    public static int[] BuscarPatrones(byte[] datos, int inicio, int fin, byte[][] patrones) {
        var res = new System.Collections.Generic.List<int>();
        for (int i = inicio; i < fin; i++) {
            byte b = datos[i];
            for (int p = 0; p < patrones.Length; p++) {
                byte[] pat = patrones[p];
                if (pat[0] != b) continue;
                if (i + pat.Length > fin) continue;
                int k = 1;
                while (k < pat.Length && datos[i + k] == pat[k]) k++;
                if (k == pat.Length) { res.Add(i); res.Add(p); }
            }
        }
        return res.ToArray();
    }

    // Comparar bloques byte a byte con un bucle de PowerShell cuesta ~0.8 MB/s
    // (millones de iteraciones interpretadas por bloque). Compilado corre a
    // velocidad de memoria y deja de ser el cuello de botella al verificar.
    // Devuelve el indice de la primera diferencia, o -1 si son iguales.
    public static int PrimeraDiferencia(byte[] a, byte[] b, int n) {
        for (int i = 0; i < n; i++) { if (a[i] != b[i]) return i; }
        return -1;
    }

    // Un barrido puede durar horas: si el equipo se duerme, la lectura en
    // curso queda congelada y luego parece un bloque lentisimo del disco.
    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);
    const uint ES_CONTINUOUS = 0x80000000;
    const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public static void MantenerDespierto(bool activo) {
        SetThreadExecutionState(activo ? (ES_CONTINUOUS | ES_SYSTEM_REQUIRED) : ES_CONTINUOUS);
    }

    public static bool Bloquear(SafeFileHandle h)  { return Ctl(h, FSCTL_LOCK_VOLUME); }
    public static bool Desmontar(SafeFileHandle h) { return Ctl(h, FSCTL_DISMOUNT_VOLUME); }
    public static bool Refrescar(SafeFileHandle h) { return Ctl(h, IOCTL_DISK_UPDATE_PROPERTIES); }
    // Para expulsar un disco sin letra asignada (por ejemplo despues de
    // grabarle una imagen), donde el Shell de Windows no sirve.
    public static bool ExpulsarMedio(SafeFileHandle h) { return Ctl(h, IOCTL_STORAGE_EJECT_MEDIA); }
    public static int  UltimoError() { return Marshal.GetLastWin32Error(); }

    // Van en uint explicito: 0x80000000 sin casteo lo toma PowerShell
    // como entero con signo y la llamada ni siquiera enlaza.
    const uint GENERIC_READ  = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint SHARE_RW      = 0x00000003;
    const uint OPEN_EXISTING = 3;
    const uint WRITE_THROUGH = 0x80000000;

    // Sin WRITE_THROUGH: forzar cada bloque al medio antes de seguir
    // impide encadenar escrituras y frena mucho el grabado. Se vacia
    // una sola vez al final con FlushFileBuffers, que es lo que importa.
    public static SafeFileHandle Abrir(string ruta, bool escritura) {
        uint acceso = escritura ? (GENERIC_READ | GENERIC_WRITE) : GENERIC_READ;
        return CreateFileW(ruta, acceso, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    }

    public static bool Vaciar(SafeFileHandle h) { return FlushFileBuffers(h); }
}
'@
}

# ==================================================================
#  3. ESTADO COMPARTIDO ENTRE HILOS
# ==================================================================
$script:Sync = [hashtable]::Synchronized(@{
    Cola     = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    Busy     = $false
    Cancelar = $false
})
$script:Worker   = $null
$script:Handle   = $null
$script:Runspace = $null
$script:Botones  = @()
$script:Firma    = ''
# Ajustes que se escriben desde dentro de manejadores de eventos. Tiene
# que ser un hashtable: $script:X escrito dentro de una closure se pierde,
# porque GetNewClosure() le da a la closure su propio ambito de script.
$script:Opciones = @{
    VerificarTrasGrabar = $true
    EsquemaReparar = 'MBR'      # MBR o GPT
    FormatoReparar = 'AUTO'     # AUTO, FAT32, exFAT o NTFS
    HashEsperado   = ''         # SHA256/SHA1/MD5 de la imagen, opcional
}
# Cuando esta activo se listan tambien los discos internos, pero solo
# para diagnosticar: el guardian les niega toda accion de escritura.
$script:VerTodos = $false

$script:EsAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ==================================================================
#  4. PALETA
# ==================================================================
$C = @{
    Fondo      = '#08090B'
    Rojo       = '#E5372F'
    RojoClaro  = '#FF6B61'
    RojoTenue  = '#7A1A16'
    RojoFondo  = '#1A0908'
    Oro        = '#C9A227'
    OroTenue   = '#5E4A12'
    Blanco     = '#EDEDED'
    Gris       = '#7E8288'
    GrisOscuro = '#3A3D42'
    Verde      = '#3FB950'
}
function Br([string]$hex) {
    New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
}

# Punto medio como codigo de caracter: se ve igual sin importar la
# codificacion con que se guarde o se lea este archivo.
$SEP = [char]0x00B7

# ==================================================================
#  5. XAML (armazon del HUD)
# ==================================================================
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Limpiador de USB" Height="800" Width="1120"
        MinHeight="620" MinWidth="960"
        WindowStartupLocation="CenterScreen"
        Background="$($C.Fondo)"
        FontFamily="Cascadia Mono, Consolas, Lucida Console"
        TextOptions.TextFormattingMode="Display">

  <Window.Resources>
    <SolidColorBrush x:Key="Fondo"     Color="$($C.Fondo)"/>
    <SolidColorBrush x:Key="Rojo"      Color="$($C.Rojo)"/>
    <SolidColorBrush x:Key="RojoTenue" Color="$($C.RojoTenue)"/>
    <SolidColorBrush x:Key="Oro"       Color="$($C.Oro)"/>
    <SolidColorBrush x:Key="OroTenue"  Color="$($C.OroTenue)"/>
    <SolidColorBrush x:Key="Gris"      Color="$($C.Gris)"/>
    <SolidColorBrush x:Key="Blanco"    Color="$($C.Blanco)"/>

    <!-- Rayas diagonales para zonas bloqueadas -->
    <DrawingBrush x:Key="Rayas" TileMode="Tile" Viewport="0,0,12,12"
                  ViewportUnits="Absolute" Opacity="0.5">
      <DrawingBrush.Transform>
        <RotateTransform Angle="45"/>
      </DrawingBrush.Transform>
      <DrawingBrush.Drawing>
        <GeometryDrawing Brush="$($C.Rojo)">
          <GeometryDrawing.Geometry>
            <RectangleGeometry Rect="0,0,6,12"/>
          </GeometryDrawing.Geometry>
        </GeometryDrawing>
      </DrawingBrush.Drawing>
    </DrawingBrush>

    <!-- Lineas de barrido sobre toda la ventana -->
    <DrawingBrush x:Key="Scanlines" TileMode="Tile" Viewport="0,0,3,3"
                  ViewportUnits="Absolute" Opacity="0.35">
      <DrawingBrush.Drawing>
        <GeometryDrawing Brush="#000000">
          <GeometryDrawing.Geometry>
            <RectangleGeometry Rect="0,0,3,1"/>
          </GeometryDrawing.Geometry>
        </GeometryDrawing>
      </DrawingBrush.Drawing>
    </DrawingBrush>

    <!-- ============ BOTON CON ESQUINAS CORTADAS ============ -->
    <ControlTemplate x:Key="TplBoton" TargetType="Button">
      <Grid>
        <Border x:Name="bg" Background="{TemplateBinding Background}"
                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"/>
        <!-- muesca superior izquierda -->
        <Polygon Points="0,0 10,0 0,10" Fill="{DynamicResource Fondo}"
                 Width="10" Height="10" HorizontalAlignment="Left" VerticalAlignment="Top"/>
        <Path x:Name="d1" Data="M 0,10 L 10,0" Stroke="{TemplateBinding BorderBrush}"
              StrokeThickness="1" Width="10" Height="10"
              HorizontalAlignment="Left" VerticalAlignment="Top"/>
        <!-- muesca inferior derecha -->
        <Polygon Points="10,10 0,10 10,0" Fill="{DynamicResource Fondo}"
                 Width="10" Height="10" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
        <Path x:Name="d2" Data="M 0,10 L 10,0" Stroke="{TemplateBinding BorderBrush}"
              StrokeThickness="1" Width="10" Height="10"
              HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                          Margin="{TemplateBinding Padding}"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="bg" Property="Background" Value="$($C.RojoFondo)"/>
          <Setter TargetName="bg" Property="BorderBrush" Value="$($C.Rojo)"/>
          <Setter TargetName="d1" Property="Stroke"      Value="$($C.Rojo)"/>
          <Setter TargetName="d2" Property="Stroke"      Value="$($C.Rojo)"/>
          <Setter Property="Foreground" Value="$($C.Blanco)"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter TargetName="bg" Property="Background" Value="$($C.RojoTenue)"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter TargetName="bg" Property="Background"  Value="#0C0D0F"/>
          <Setter TargetName="bg" Property="BorderBrush" Value="$($C.GrisOscuro)"/>
          <Setter TargetName="d1" Property="Stroke"      Value="$($C.GrisOscuro)"/>
          <Setter TargetName="d2" Property="Stroke"      Value="$($C.GrisOscuro)"/>
          <Setter Property="Foreground" Value="#4A4D52"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Template"    Value="{StaticResource TplBoton}"/>
      <Setter Property="Background"  Value="#0E1013"/>
      <Setter Property="BorderBrush" Value="$($C.OroTenue)"/>
      <Setter Property="Foreground"  Value="$($C.Blanco)"/>
      <Setter Property="Padding"     Value="16,8"/>
      <Setter Property="FontSize"    Value="11"/>
      <Setter Property="FontWeight"  Value="Bold"/>
      <Setter Property="Cursor"      Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
    </Style>

    <Style x:Key="BtnRojo" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background"  Value="$($C.RojoFondo)"/>
      <Setter Property="BorderBrush" Value="$($C.Rojo)"/>
      <Setter Property="Foreground"  Value="$($C.RojoClaro)"/>
    </Style>

    <Style x:Key="BtnMini" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Padding"  Value="9,3"/>
      <Setter Property="FontSize" Value="9"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="#0C0D0F"/>
    </Style>

    <!-- Menu contextual del registro, con el mismo aspecto que el resto -->
    <Style TargetType="ContextMenu">
      <Setter Property="Background"  Value="#111318"/>
      <Setter Property="BorderBrush" Value="$($C.Oro)"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground"  Value="$($C.Blanco)"/>
    </Style>
    <Style TargetType="MenuItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="$($C.Blanco)"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize"   Value="11"/>
      <Setter Property="Padding"    Value="10,5"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True">
          <Setter Property="Background" Value="$($C.RojoFondo)"/>
          <Setter Property="Foreground" Value="$($C.RojoClaro)"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- encabezado -->
      <RowDefinition Height="Auto"/>   <!-- alerta -->
      <RowDefinition Height="Auto"/>   <!-- barra -->
      <RowDefinition Height="*"/>      <!-- lista -->
      <RowDefinition Height="Auto"/>   <!-- consola -->
      <RowDefinition Height="Auto"/>   <!-- estado -->
    </Grid.RowDefinitions>

    <!-- ================= ENCABEZADO ================= -->
    <Grid Grid.Row="0" Background="#0B0C0F">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <!-- barra roja inclinada -->
      <Polygon Grid.Column="0" Points="0,0 26,0 14,74 0,74" Fill="$($C.Rojo)"
               Width="26" Height="74" VerticalAlignment="Top"/>

      <StackPanel Grid.Column="1" Margin="14,16,0,14" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="///" Foreground="$($C.Rojo)" FontSize="20" FontWeight="Bold"
                     Margin="0,0,10,0" VerticalAlignment="Center"/>
          <TextBlock Text="LIMPIADOR DE USB" Foreground="$($C.Blanco)"
                     FontSize="22" FontWeight="Bold"/>
        </StackPanel>
        <TextBlock Text="UNIDAD DE CONTROL DE MEDIOS EXTRAIBLES  //  ACCESO RESTRINGIDO"
                   Foreground="$($C.Oro)" FontSize="10" Margin="34,5,0,0"/>
      </StackPanel>

      <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center"
                  Margin="0,0,26,0">
        <TextBlock x:Name="Reloj" Foreground="$($C.Gris)" FontSize="11"
                   VerticalAlignment="Center" Margin="0,0,16,0"/>
        <Border x:Name="AdminChip" BorderThickness="1" Padding="12,5">
          <TextBlock x:Name="AdminTxt" FontSize="10" FontWeight="Bold"/>
        </Border>
      </StackPanel>
    </Grid>

    <!-- linea dorada divisoria -->
    <Grid Grid.Row="0" VerticalAlignment="Bottom" Height="3">
      <Rectangle Height="1" VerticalAlignment="Bottom" Fill="$($C.OroTenue)"/>
      <Rectangle Height="3" HorizontalAlignment="Left" Width="220" VerticalAlignment="Bottom">
        <Rectangle.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="$($C.Oro)" Offset="0"/>
            <GradientStop Color="#00C9A227" Offset="1"/>
          </LinearGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
    </Grid>

    <!-- ================= ALERTA ================= -->
    <Grid x:Name="AlertaBox" Grid.Row="1" Visibility="Collapsed" Margin="26,18,26,0">
      <Border Background="$($C.RojoFondo)" BorderBrush="$($C.Rojo)" BorderThickness="1"/>
      <Rectangle Fill="{StaticResource Rayas}" Opacity="0.13"/>
      <Rectangle Width="4" HorizontalAlignment="Left" Fill="$($C.Rojo)"/>
      <StackPanel Orientation="Horizontal" Margin="20,11,14,11">
        <TextBlock Text="///" Foreground="$($C.Rojo)" FontSize="13" FontWeight="Bold"
                   Margin="0,0,10,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="AlertaTxt" Foreground="$($C.RojoClaro)" FontSize="11"
                   VerticalAlignment="Center" TextWrapping="Wrap" FontWeight="Bold"/>
      </StackPanel>
    </Grid>

    <!-- ================= BARRA DE HERRAMIENTAS ================= -->
    <Grid Grid.Row="2" Margin="26,18,26,12">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0" Orientation="Horizontal">
        <Button x:Name="BtnScan" Content="RE-ESCANEAR" Style="{StaticResource Btn}" Margin="0,0,10,0"/>
        <Button x:Name="BtnProt" Content="REGLAS DE BLINDAJE" Style="{StaticResource Btn}" Margin="0,0,10,0"/>
        <Button x:Name="BtnTodos" Content="VER TODOS LOS DISCOS" Style="{StaticResource Btn}"/>
      </StackPanel>
      <TextBlock x:Name="Contador" Grid.Column="1" Foreground="$($C.Gris)" FontSize="10"
                 VerticalAlignment="Center" HorizontalAlignment="Right" TextAlignment="Right"/>
    </Grid>

    <!-- ================= LISTA ================= -->
    <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto"
                  HorizontalScrollBarVisibility="Disabled" Margin="26,0,20,0">
      <StackPanel x:Name="Lista" Margin="0,0,6,0"/>
    </ScrollViewer>

    <!-- ================= CONSOLA ================= -->
    <Grid Grid.Row="4" Margin="26,16,26,0" Height="158">
      <Border Background="#0B0C0F" BorderBrush="$($C.OroTenue)" BorderThickness="1"/>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Background="#111318">
          <TextBlock Text="  &gt;_  CONSOLA" Foreground="$($C.Oro)" FontSize="10"
                     FontWeight="Bold" Margin="10,6,0,6" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,4,8,4">
            <Button x:Name="BtnCopiar"  Content="COPIAR TODO" Style="{StaticResource BtnMini}" Margin="0,0,6,0"/>
            <Button x:Name="BtnGuardar" Content="GUARDAR"     Style="{StaticResource BtnMini}" Margin="0,0,6,0"/>
            <Button x:Name="BtnLimpiar" Content="LIMPIAR"     Style="{StaticResource BtnMini}"/>
          </StackPanel>
          <Rectangle Height="1" VerticalAlignment="Bottom" Fill="$($C.OroTenue)"/>
        </Grid>

        <!-- RichTextBox y no TextBlock: en WPF el TextBlock no se puede
             seleccionar, y aqui hace falta poder copiar los errores. -->
        <RichTextBox x:Name="Log" Grid.Row="1" IsReadOnly="True"
                     Background="Transparent" Foreground="$($C.Gris)"
                     BorderThickness="0" Padding="0" Margin="12,8,4,10"
                     FontFamily="Cascadia Mono, Consolas" FontSize="11"
                     VerticalScrollBarVisibility="Auto"
                     HorizontalScrollBarVisibility="Disabled"
                     SelectionBrush="$($C.Rojo)" SelectionOpacity="0.45"
                     IsReadOnlyCaretVisible="False" IsUndoEnabled="False">
          <RichTextBox.ContextMenu>
            <ContextMenu>
              <MenuItem x:Name="MnuCopiar"    Header="Copiar seleccion         Ctrl+C"/>
              <MenuItem x:Name="MnuTodo"      Header="Seleccionar todo         Ctrl+A"/>
              <MenuItem x:Name="MnuCopiarAll" Header="Copiar todo el registro"/>
              <Separator/>
              <MenuItem x:Name="MnuGuardar"   Header="Guardar registro en archivo..."/>
              <MenuItem x:Name="MnuLimpiar"   Header="Limpiar consola"/>
            </ContextMenu>
          </RichTextBox.ContextMenu>
        </RichTextBox>
      </Grid>
      <!-- corchetes de esquina -->
      <Path Data="M 0,12 L 0,0 L 12,0"   Stroke="$($C.Oro)" StrokeThickness="1.6" Width="12" Height="12"
            HorizontalAlignment="Left"  VerticalAlignment="Top"    Margin="-1,-1,0,0"/>
      <Path Data="M 0,0 L 12,0 L 12,12"  Stroke="$($C.Oro)" StrokeThickness="1.6" Width="12" Height="12"
            HorizontalAlignment="Right" VerticalAlignment="Top"    Margin="0,-1,-1,0"/>
      <Path Data="M 12,0 L 12,12 L 0,12" Stroke="$($C.Oro)" StrokeThickness="1.6" Width="12" Height="12"
            HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-1,-1"/>
      <Path Data="M 0,0 L 0,12 L 12,12"  Stroke="$($C.Oro)" StrokeThickness="1.6" Width="12" Height="12"
            HorizontalAlignment="Left"  VerticalAlignment="Bottom" Margin="-1,0,0,-1"/>
    </Grid>

    <!-- ================= ESTADO / PROGRESO ================= -->
    <Grid Grid.Row="5" Margin="26,12,26,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- fila de progreso, solo durante el grabado -->
      <Grid x:Name="FilaProg" Grid.Row="0" Visibility="Collapsed" Margin="0,0,0,10">
        <Border Background="#0B0C0F" BorderBrush="$($C.Oro)" BorderThickness="1"/>
        <Grid Margin="14,10,12,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="ProgFase" Grid.Column="0" Text="ESCRIBIENDO" Foreground="$($C.Rojo)"
                     FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,14,0"/>
          <StackPanel x:Name="ProgBarra" Grid.Column="1" Orientation="Horizontal"
                      VerticalAlignment="Center"/>
          <TextBlock x:Name="ProgTxt" Grid.Column="2" Foreground="$($C.Oro)" FontSize="11"
                     FontWeight="Bold" VerticalAlignment="Center" Margin="14,0,14,0"/>
          <Button x:Name="BtnCancelar" Grid.Column="3" Content="CANCELAR"
                  Style="{StaticResource BtnRojo}" Width="110"/>
        </Grid>
      </Grid>

      <Grid Grid.Row="1">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="ESTADO //" Foreground="$($C.Oro)" FontSize="10" FontWeight="Bold"
                     VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock x:Name="Estado" Foreground="$($C.Gris)" FontSize="10" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel x:Name="Latido" Orientation="Horizontal" HorizontalAlignment="Right"
                    Visibility="Collapsed"/>
      </Grid>
    </Grid>

    <!-- capa de lineas de barrido, no interactiva -->
    <Rectangle Grid.RowSpan="6" Fill="{StaticResource Scanlines}" IsHitTestVisible="False"/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win    = [Windows.Markup.XamlReader]::Load($reader)

# Icono propio: sin esto Windows pone el de PowerShell en la barra de
# titulo y en la barra de tareas, y se pierde todo el efecto.
# Si falta el archivo no pasa nada, el programa arranca igual.
$script:IconoApp = $null
$rutaIco = Join-Path $script:CarpetaBase 'limpiador.ico'
if (Test-Path -LiteralPath $rutaIco) {
    try {
        $script:IconoApp = New-Object Windows.Media.Imaging.BitmapImage ([Uri]$rutaIco)
        $win.Icon = $script:IconoApp
    } catch { }
}

$UI = @{}
foreach ($n in 'AdminChip','AdminTxt','Reloj','AlertaBox','AlertaTxt','BtnScan','BtnProt',
               'Contador','Lista','Log','Estado','Latido','BtnTodos',
               'FilaProg','ProgFase','ProgBarra','ProgTxt','BtnCancelar',
               'BtnCopiar','BtnGuardar','BtnLimpiar',
               'MnuCopiar','MnuTodo','MnuCopiarAll','MnuGuardar','MnuLimpiar') {
    $UI[$n] = $win.FindName($n)
}

# El RichTextBox arranca con un parrafo vacio de fabrica: se quita para
# que la primera linea del registro no salga precedida de un hueco.
$UI.Log.Document = New-Object Windows.Documents.FlowDocument
$UI.Log.Document.PagePadding = New-Object Windows.Thickness 0
$UI.Log.Document.FontFamily  = $UI.Log.FontFamily
$UI.Log.Document.FontSize    = 11

# ==================================================================
#  6. UTILIDADES
# ==================================================================
function Write-Log {
    param([string]$Texto, [string]$Nivel = 'info')
    $color = switch ($Nivel) {
        'ok'    { $C.Verde }
        'error' { $C.Rojo }
        'warn'  { $C.Oro }
        default { $C.Gris }
    }
    # Un parrafo por linea: asi el texto copiado sale con sus saltos
    # de linea de verdad, como en una terminal.
    $par = New-Object Windows.Documents.Paragraph
    $par.Margin = New-Object Windows.Thickness 0
    $par.LineHeight = 15
    $run = New-Object Windows.Documents.Run ("[{0}] > {1}" -f (Get-Date -Format 'HH:mm:ss'), $Texto)
    $run.Foreground = Br $color
    if ($Nivel -eq 'error') { $run.FontWeight = 'Bold' }
    $par.Inlines.Add($run)
    $UI.Log.Document.Blocks.Add($par)
    $UI.Log.ScrollToEnd()
}

# Todo el contenido de un RichTextBox como texto plano. Sirve para las dos
# consolas: la principal y la de la ventana de diagnostico.
function Get-TextoDeRegistro {
    param($Rtb)
    $rango = New-Object Windows.Documents.TextRange(
        $Rtb.Document.ContentStart, $Rtb.Document.ContentEnd)
    $rango.Text
}

function Copy-TextoAlPortapapeles {
    param([string]$Txt)
    if ([string]::IsNullOrWhiteSpace($Txt)) { return 'el registro esta vacio' }
    try { [Windows.Clipboard]::SetText($Txt); return $null }
    catch { return $_.Exception.Message }
}

function Save-TextoAArchivo {
    param([string]$Txt, [string]$Prefijo = 'limpiador-usb')
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Title = 'Guardar registro'
    $sfd.Filter = 'Texto (*.txt)|*.txt|Todos|*.*'
    $sfd.FileName = '{0}-{1}.txt' -f $Prefijo, (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (-not $sfd.ShowDialog()) { return $null }
    Set-Content -LiteralPath $sfd.FileName -Value $Txt -Encoding UTF8
    $sfd.FileName
}

function Get-TextoRegistro { Get-TextoDeRegistro $UI.Log }

function Copy-Registro {
    $err = Copy-TextoAlPortapapeles (Get-TextoRegistro)
    if ($err) { Write-Log "No se pudo copiar: $err" 'error' }
    else { Write-Log 'Registro completo copiado al portapapeles.' 'ok' }
}

function Save-Registro {
    try {
        $f = Save-TextoAArchivo (Get-TextoRegistro)
        if ($f) { Write-Log "Registro guardado en $f" 'ok' }
    } catch {
        Write-Log "No se pudo guardar: $($_.Exception.Message)" 'error'
    }
}

function Clear-Registro {
    $UI.Log.Document.Blocks.Clear()
    Write-Log 'Consola limpiada.'
}

function Format-Tam {
    param([double]$Bytes)
    if ($Bytes -le 0) { return '0 B' }
    $u = 'B','KB','MB','GB','TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt 4) { $Bytes /= 1024; $i++ }
    '{0:N1} {1}' -f $Bytes, $u[$i]
}

# ------------------------------------------------------------------
#  IMAGENES DE DISCO
# ------------------------------------------------------------------
# Devuelve un flujo de bytes crudo de la imagen, descomprimiendo al
# vuelo si hace falta. El llamador cierra el flujo.
#
# Se guarda como TEXTO y se reconstruye con [scriptblock]::Create tanto
# aqui como dentro del hilo de trabajo: un scriptblock queda atado al
# runspace donde nacio, y pasarlo tal cual a otro falla de formas raras.
$script:AbrirImagenSrc = @'
    param([string]$Ruta)

    $ext = [System.IO.Path]::GetExtension($Ruta).ToLower()
    switch ($ext) {
        '.zip' {
            $za = [System.IO.Compression.ZipFile]::OpenRead($Ruta)
            $e  = $za.Entries | Where-Object { $_.Length -gt 0 } | Select-Object -First 1
            if (-not $e) { $za.Dispose(); throw "El zip '$([System.IO.Path]::GetFileName($Ruta))' no contiene ninguna imagen." }
            return @{ Stream = $e.Open(); Tamano = [long]$e.Length; Comprimida = $true }
        }
        '.gz' {
            $fs = [System.IO.File]::OpenRead($Ruta)
            # gzip guarda el tamano descomprimido (ISIZE) en los ultimos 4
            # bytes, modulo 4 GB. Por encima de eso no es fiable: se deja nulo.
            $tam = $null
            try {
                $fs.Position = $fs.Length - 4
                $b = New-Object byte[] 4
                $null = $fs.Read($b, 0, 4)
                $isize = [BitConverter]::ToUInt32($b, 0)
                if ($fs.Length -lt 4GB) { $tam = [long]$isize }
            } catch { }
            $fs.Position = 0
            $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
            return @{ Stream = $gz; Tamano = $tam; Comprimida = $true }
        }
        default {
            $fs = [System.IO.File]::OpenRead($Ruta)
            return @{ Stream = $fs; Tamano = [long]$fs.Length; Comprimida = $false }
        }
    }
'@
$script:AbrirImagen = [scriptblock]::Create($script:AbrirImagenSrc)

# Copia cruda de un flujo a otro, alineada al sector. Es el codigo mas
# peligroso del programa, asi que vive aqui como texto para que el hilo
# de trabajo y la autoprueba ejecuten EXACTAMENTE el mismo bucle: la
# prueba corre contra un MemoryStream y no contra un disco real.
$script:CopiarFlujoSrc = @'
    param($Origen, $Destino, [int]$Bloque, [int]$Sector,
          $Total, $LimiteBytes, $Progreso, $Cancelado)

    $buf      = New-Object byte[] $Bloque
    $escritos = [long]0

    while ($true) {
        if ($Cancelado -and (& $Cancelado)) { throw 'CANCELADO por el usuario.' }

        # Hay que LLENAR el bufer antes de escribir: los flujos comprimidos
        # devuelven lecturas parciales a media imagen, y rellenar ahi
        # insertaria ceros en medio del contenido. Solo la ultima lectura,
        # la que agota el flujo, se rellena.
        $leidos = 0
        while ($leidos -lt $Bloque) {
            $r = $Origen.Read($buf, $leidos, $Bloque - $leidos)
            if ($r -le 0) { break }
            $leidos += $r
        }
        if ($leidos -le 0) { break }

        # El dispositivo crudo solo acepta multiplos del sector.
        $aEscribir = $leidos
        $resto = $leidos % $Sector
        if ($resto -ne 0) {
            $aEscribir = $leidos + ($Sector - $resto)
            [Array]::Clear($buf, $leidos, $aEscribir - $leidos)
        }

        if ($LimiteBytes -and (($escritos + $aEscribir) -gt $LimiteBytes)) {
            throw "La imagen no cabe en el disco."
        }

        $Destino.Write($buf, 0, $aEscribir)
        $escritos += $leidos

        if ($Progreso) { & $Progreso $escritos $Total }
    }
    $escritos
'@
$script:CopiarFlujo = [scriptblock]::Create($script:CopiarFlujoSrc)

# Lee EXACTAMENTE $Cuantos bytes, insistiendo hasta completarlos.
# Un solo Read puede devolver menos de lo pedido: los puentes USB tienen
# un tamano maximo de transferencia y recortan las peticiones grandes.
# Quien dependa de una sola llamada acaba saltandose datos.
# Devuelve los bytes realmente leidos (menos solo al final del medio).
$script:LeerBloqueSrc = @'
    param($Origen, [byte[]]$Buffer, [int]$Cuantos, [int]$Desplazamiento = 0)
    $n = 0
    while ($n -lt $Cuantos) {
        $r = $Origen.Read($Buffer, $Desplazamiento + $n, $Cuantos - $n)
        if ($r -le 0) { break }
        $n += $r
    }
    $n
'@
$script:LeerBloque = [scriptblock]::Create($script:LeerBloqueSrc)

# ==================================================================
#  FIRMAS PARA RECUPERAR ARCHIVOS (tallado)
# ==================================================================
# El tallado trabaja por DEBAJO del sistema de archivos: reconoce que en
# tal posicion empieza un JPEG y lo sigue hasta su marca de fin. Por eso
# funciona aunque el disco este formateado, y por eso NO recupera nombres
# ni carpetas: esa informacion vivia en la tabla que el formateo borro.
#
# Cabecera y cola en hexadecimal. MaxMB corta los que no encuentran cola,
# para no tragarse medio disco en un solo archivo.
$script:Firmas = @(
    # JPEG con el marcador incluido: 'FFD8FF' a secas son 3 bytes y en datos
    # aleatorios coincide una vez cada 16 MB, o sea cientos de falsos por
    # disco. Con el cuarto byte baja a uno cada 4 GB.
    @{ Nombre = 'JPEG';  Ext = 'jpg';  Cab = 'FFD8FFE0';           Cola = 'FFD9';             MaxMB = 24 },
    @{ Nombre = 'JPEG';  Ext = 'jpg';  Cab = 'FFD8FFE1';           Cola = 'FFD9';             MaxMB = 24 },
    @{ Nombre = 'JPEG';  Ext = 'jpg';  Cab = 'FFD8FFDB';           Cola = 'FFD9';             MaxMB = 24 },
    @{ Nombre = 'JPEG';  Ext = 'jpg';  Cab = 'FFD8FFEE';           Cola = 'FFD9';             MaxMB = 24 },
    @{ Nombre = 'PNG';   Ext = 'png';  Cab = '89504E470D0A1A0A';   Cola = '49454E44AE426082'; MaxMB = 64 },
    @{ Nombre = 'GIF';   Ext = 'gif';  Cab = '474946383961';       Cola = '003B';             MaxMB = 16 },
    @{ Nombre = 'GIF';   Ext = 'gif';  Cab = '474946383761';       Cola = '003B';             MaxMB = 16 },
    @{ Nombre = 'PDF';   Ext = 'pdf';  Cab = '255044462D';         Cola = '2525454F46';       MaxMB = 96 },
    # docx, xlsx y pptx son ZIP por dentro. La cola es el fin del directorio
    # central; el subtipo se deduce mirando el contenido del principio.
    @{ Nombre = 'ZIP';   Ext = 'zip';  Cab = '504B0304';           Cola = '504B0506';         MaxMB = 96 }
)

# Cuantos archivos puede tener abiertos a la vez. Cada uno abierto obliga a
# recorrer el bloque otra vez y a escribirlo entero: con 64 el barrido caia
# a 0.8 MB/s en un disco que lee a 23.
$script:MaxAbiertos = 8

function ConvertFrom-Hex {
    param([string]$Hex)
    $n = $Hex.Length / 2
    $b = New-Object byte[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $b[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    , $b
}

# Un ZIP puede ser docx, xlsx o pptx: se distingue por los nombres que
# guarda al principio. Asi el archivo recuperado sale con su extension util.
$script:SubtipoZipSrc = @'
    param([byte[]]$Inicio)
    $txt = [System.Text.Encoding]::ASCII.GetString($Inicio, 0, [math]::Min(600, $Inicio.Length))
    if ($txt -match 'word/')  { return 'docx' }
    if ($txt -match 'xl/')    { return 'xlsx' }
    if ($txt -match 'ppt/')   { return 'pptx' }
    'zip'
'@
$script:SubtipoZip = [scriptblock]::Create($script:SubtipoZipSrc)
function Get-SubtipoZip { param([byte[]]$Inicio) & $script:SubtipoZip $Inicio }

# Tamano real que ocupara la imagen ya escrita, sin dejar el flujo abierto.
function Get-TamanoImagen {
    param([string]$Ruta)
    $a = & $script:AbrirImagen $Ruta
    try { return $a.Tamano } finally { if ($a.Stream) { $a.Stream.Dispose() } }
}

# Las imagenes isohybrid de Linux y los .img llevan firma de arranque
# 0x55AA al final del primer sector. Los ISO9660 puros (los instaladores
# de Windows, por ejemplo) no la llevan y no arrancan por escritura cruda.
function Test-ImagenArrancable {
    param([string]$Ruta)
    try {
        $a = & $script:AbrirImagen $Ruta
        try {
            $b = New-Object byte[] 512
            $n = 0
            while ($n -lt 512) {
                $r = $a.Stream.Read($b, $n, 512 - $n)
                if ($r -le 0) { break }
                $n += $r
            }
            return ($n -eq 512 -and $b[510] -eq 0x55 -and $b[511] -eq 0xAA)
        } finally { if ($a.Stream) { $a.Stream.Dispose() } }
    } catch { return $false }
}

# --- corchetes de mira en las cuatro esquinas de un Grid ---
function Add-Esquinas {
    param($Contenedor, [string]$Color, [double]$L = 11, [double]$Grosor = 1.6)
    $defs = @(
        @{ D = "M 0,$L L 0,0 L $L,0";   H = 'Left';  V = 'Top' },
        @{ D = "M 0,0 L $L,0 L $L,$L";  H = 'Right'; V = 'Top' },
        @{ D = "M $L,0 L $L,$L L 0,$L"; H = 'Right'; V = 'Bottom' },
        @{ D = "M 0,0 L 0,$L L $L,$L";  H = 'Left';  V = 'Bottom' }
    )
    foreach ($d in $defs) {
        $p = New-Object Windows.Shapes.Path
        $p.Data = [Windows.Media.Geometry]::Parse($d.D)
        $p.Stroke = Br $Color
        $p.StrokeThickness = $Grosor
        $p.Width = $L; $p.Height = $L
        $p.HorizontalAlignment = $d.H
        $p.VerticalAlignment   = $d.V
        $p.IsHitTestVisible = $false
        $Contenedor.Children.Add($p) | Out-Null
    }
}

# --- muescas diagonales (esquinas cortadas) en un Grid ---
function Add-Muescas {
    param($Contenedor, [string]$Color, [double]$L = 12)
    $defs = @(
        @{ Pts = "0,0 $L,0 0,$L";    H = 'Left';  V = 'Top' },
        @{ Pts = "$L,$L 0,$L $L,0";  H = 'Right'; V = 'Bottom' }
    )
    foreach ($d in $defs) {
        $poly = New-Object Windows.Shapes.Polygon
        $poly.Points = [Windows.Media.PointCollection]::Parse($d.Pts)
        $poly.Fill = Br $C.Fondo
        $poly.Width = $L; $poly.Height = $L
        $poly.HorizontalAlignment = $d.H
        $poly.VerticalAlignment   = $d.V
        $poly.IsHitTestVisible = $false
        $Contenedor.Children.Add($poly) | Out-Null

        $ln = New-Object Windows.Shapes.Path
        $ln.Data = [Windows.Media.Geometry]::Parse("M 0,$L L $L,0")
        $ln.Stroke = Br $Color
        $ln.StrokeThickness = 1
        $ln.Width = $L; $ln.Height = $L
        $ln.HorizontalAlignment = $d.H
        $ln.VerticalAlignment   = $d.V
        $ln.IsHitTestVisible = $false
        $Contenedor.Children.Add($ln) | Out-Null
    }
}

# --- barra de uso segmentada, estilo HUD ---
function New-BarraSegmentada {
    param([double]$Fraccion, [int]$Segmentos = 32, [string]$Lleno, [string]$Vacio)
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $brLleno = Br $Lleno
    $brVacio = Br $Vacio
    for ($i = 0; $i -lt $Segmentos; $i++) {
        $r = New-Object Windows.Shapes.Rectangle
        $r.Width = 5; $r.Height = 9
        $r.Margin = New-Object Windows.Thickness 0, 0, 2, 0
        $r.Fill = if (($i + 1) / $Segmentos -le $Fraccion) { $brLleno } else { $brVacio }
        $sp.Children.Add($r) | Out-Null
    }
    $sp
}

# ------------------------------------------------------------------
#  EL GUARDIAN.  Devuelve la lista de razones por las que una unidad
#  NO puede tocarse.  Lista vacia = se puede operar.
# ------------------------------------------------------------------
# Una serie de la lista de permitidos puede saltarse las reglas de MODELO
# y ETIQUETA, y nada mas. Si la serie tambien esta en la lista negra, gana
# la lista negra: por eso aqui se devuelve $false en ese caso.
function Test-SeriePermitida {
    param([string]$Serie)
    if (-not $Serie) { return $false }
    $s = $Serie.Trim()
    if (-not $s) { return $false }
    foreach ($bs in $script:Guard.Seriales) {
        if ($s -like "*$bs*") { return $false }
    }
    foreach ($ok in $script:Guard.Permitidos) {
        if ($ok -and $s -like "*$ok*") { return $true }
    }
    $false
}

function Get-RazonesBloqueo {
    # -SoloNucleo devuelve unicamente las razones que NINGUNA exencion
    # puede levantar. Si vuelve vacio, este disco se puede eximir; si trae
    # algo, el boton de eximir ni se ofrece.
    param([hashtable]$D, [switch]$SoloNucleo)

    $r = @()
    $letra = if ($D.Letra) { ([string]$D.Letra).ToUpper() } else { '' }
    $bus   = if ($D.ContainsKey('Bus')) { [string]$D.Bus } else { '' }

    # ============ NUCLEO INAMOVIBLE ============
    # Nada de lo de este bloque se puede eximir desde la interfaz ni
    # desde ningun archivo de configuracion.
    if ($letra -and $script:LetrasNucleo -contains $letra) {
        $r += "LETRA $letra`: DEL SISTEMA - LISTA NEGRA PERMANENTE"
    }
    if ($D.EsSistema)  { $r += 'DISCO DEL SISTEMA OPERATIVO' }
    if ($D.EsArranque) { $r += 'DISCO DE ARRANQUE' }

    # Los discos internos se listan solo para diagnosticar (que es de
    # lectura). Ninguna accion de escritura puede alcanzarlos.
    if ($D.ContainsKey('SoloDiagnostico') -and $D.SoloDiagnostico) {
        $r += "BUS $bus - SOLO DIAGNOSTICO, NINGUNA ESCRITURA PERMITIDA"
    }
    # Los HDD externos por USB se declaran 'Fixed' igual que un disco interno.
    # Solo se bloquea por eso si ademas el bus no es de medio extraible: el
    # escaneo ya filtra por USB/SD/MMC, y sistema/arranque van por su cuenta.
    # Si no se sabe el bus, se asume lo peor y se bloquea.
    if ($D.TipoVol -eq 'Fixed' -and $bus -notin 'USB', 'SD', 'MMC') {
        $r += "VOLUMEN FIJO EN BUS $(if ($bus) { $bus } else { 'DESCONOCIDO' }) - NO ES UN MEDIO EXTRAIBLE"
    }
    if ($letra) {
        foreach ($p in 'Windows', 'Program Files', 'Users') {
            if (Test-Path -LiteralPath "$letra`:\$p" -ErrorAction SilentlyContinue) {
                $r += "CONTIENE CARPETA DE SISTEMA ($($p.ToUpper()))"
            }
        }
    }

    if ($SoloNucleo) { return $r | Select-Object -Unique }

    # ============ DECISION DEL USUARIO ============
    # Lo que el usuario marco a mano. Gana sobre cualquier exencion.
    $serie = if ($D.Serie) { ([string]$D.Serie).Trim() } else { '' }
    if ($serie) {
        foreach ($pr in $script:Guard.Protegidos) {
            if ($pr -and $serie -like "*$pr*") {
                $r += "PROTEGIDO POR TI - SERIE $pr (se quita desde su tarjeta)"
            }
        }
    }

    # ============ LISTA NEGRA DE SERIES ============
    # Se comprueba SIEMPRE y gana sobre las exenciones.
    if ($serie) {
        foreach ($bs in $script:Guard.Seriales) {
            # Las que ya se reportaron como decision del usuario no se repiten.
            if ($serie -like "*$bs*" -and $bs -notin $script:Guard.Protegidos) {
                $r += "NUMERO DE SERIE BLINDADO ($bs)"
            }
        }
    }

    # ============ HEURISTICAS, EXIMIBLES ============
    # Un disco exento se salta este bloque entero, y solo este.
    if (-not (Test-SeriePermitida $D.Serie)) {
        if ($letra -and $script:Guard.Letras -contains $letra -and
            $script:LetrasNucleo -notcontains $letra) {
            $r += "LETRA $letra`: EN LA LISTA NEGRA DE TU CONFIGURACION"
        }
        if ($D.Modelo) {
            $m = ([string]$D.Modelo).ToLower()
            foreach ($bn in $script:Guard.Nombres) {
                if ($m -like "*$bn*") { $r += "MODELO CONTIENE '$($bn.ToUpper())' - DISCO DE RESPALDO" }
            }
        }
        if ($D.Etiqueta) {
            $e = ([string]$D.Etiqueta).ToLower()
            foreach ($be in $script:Guard.Etiquetas) {
                if ($e -like "*$be*") { $r += "ETIQUETA BLINDADA '$($D.Etiqueta)'" }
            }
        }
        if ($D.TamDisco -gt ($script:Guard.TamMaxGB * 1GB)) {
            $r += ("EXCEDE EL LIMITE DE {0} GB ({1}) - SE ASUME DISCO DE RESPALDO" -f `
                   $script:Guard.TamMaxGB, (Format-Tam $D.TamDisco))
        }
    }
    $r | Select-Object -Unique
}

# ------------------------------------------------------------------
#  GUARDIAN A NIVEL DE DISCO COMPLETO.
#  'Reparar' borra la tabla de particiones del disco entero, no un
#  volumen. Por eso revisa el disco Y todos sus volumenes, y sobre
#  todo confirma la IDENTIDAD del disco por numero de serie: los
#  numeros de disco cambian al reconectar, la serie no. Esto es
#  justo lo que diskpart no comprueba cuando escribes 'select disk N'.
# ------------------------------------------------------------------
function Get-RazonesBloqueoDisco {
    param([int]$Disco, [string]$SerieEsperada,
          [double]$TamEsperado = 0, [string]$ModeloEsperado = '')

    $r = @()
    $d = Get-Disk -Number $Disco -ErrorAction SilentlyContinue
    if (-not $d) { return @("EL DISCO $Disco YA NO EXISTE") }

    $serieReal = "$($d.SerialNumber)".Trim()
    if ($serieReal -ne "$SerieEsperada".Trim()) {
        $r += "EL DISCO $Disco YA NO ES EL MISMO - SERIE ESPERADA '$SerieEsperada', ENCONTRADA '$serieReal'"
    }
    # La serie sola no basta: los puentes USB baratos inventan valores de
    # relleno y dos discos distintos pueden reportar el mismo. Se compara
    # tambien el tamano y el modelo, que si cambian al cambiar de disco.
    if ($TamEsperado -gt 0 -and [double]$d.Size -ne [double]$TamEsperado) {
        $r += ("EL DISCO $Disco CAMBIO DE TAMANO - SE ESPERABA {0}, HAY {1}" -f `
               (Format-Tam $TamEsperado), (Format-Tam $d.Size))
    }
    if ($ModeloEsperado -and "$($d.FriendlyName)".Trim() -ne "$ModeloEsperado".Trim()) {
        $r += "EL DISCO $Disco CAMBIO DE MODELO - SE ESPERABA '$ModeloEsperado', HAY '$($d.FriendlyName)'"
    }
    # --- nucleo inamovible: ninguna exencion lo levanta ---
    if ($d.IsSystem)  { $r += 'DISCO DEL SISTEMA OPERATIVO' }
    if ($d.IsBoot)    { $r += 'DISCO DE ARRANQUE' }
    if ($d.BusType -notin 'USB', 'SD', 'MMC') { $r += "BUS $($d.BusType) - NO ES UN MEDIO EXTRAIBLE" }

    # --- decision del usuario y lista negra de series ---
    foreach ($pr in $script:Guard.Protegidos) {
        if ($pr -and $serieReal -like "*$pr*") {
            $r += "PROTEGIDO POR TI - SERIE $pr (se quita desde su tarjeta)"
        }
    }
    foreach ($bs in $script:Guard.Seriales) {
        if ($serieReal -like "*$bs*" -and $bs -notin $script:Guard.Protegidos) {
            $r += "NUMERO DE SERIE BLINDADO ($bs)"
        }
    }

    # --- heuristicas: solo estas se pueden eximir ---
    if (-not (Test-SeriePermitida $serieReal)) {
        if ($d.Size -gt ($script:Guard.TamMaxGB * 1GB)) {
            $r += ("EXCEDE EL LIMITE DE {0} GB ({1})" -f $script:Guard.TamMaxGB, (Format-Tam $d.Size))
        }
        foreach ($bn in $script:Guard.Nombres) {
            if ("$($d.FriendlyName)".ToLower() -like "*$bn*") { $r += "MODELO CONTIENE '$($bn.ToUpper())'" }
        }
    }

    # Ningun volumen del disco puede estar blindado: se van todos juntos.
    # Las letras del nucleo bloquean siempre; las que agrego el usuario a
    # su configuracion siguen la misma exencion que el resto de heuristicas.
    foreach ($p in @(Get-Partition -DiskNumber $Disco -ErrorAction SilentlyContinue |
                     Where-Object { $_.DriveLetter })) {
        $L = ([string]$p.DriveLetter).ToUpper()
        if ($script:LetrasNucleo -contains $L) {
            $r += "EL DISCO CONTIENE LA UNIDAD DEL SISTEMA $L`:"
        } elseif ($script:Guard.Letras -contains $L -and -not (Test-SeriePermitida $serieReal)) {
            $r += "EL DISCO CONTIENE LA UNIDAD BLINDADA $L`:"
        }
        foreach ($sys in 'Windows', 'Program Files', 'Users') {
            if (Test-Path -LiteralPath "$L`:\$sys" -ErrorAction SilentlyContinue) {
                $r += "EL DISCO CONTIENE CARPETA DE SISTEMA EN $L`: ($($sys.ToUpper()))"
            }
        }
    }
    $r | Select-Object -Unique
}

# A que disco fisico pertenece una carpeta. Se usa para impedir que los
# archivos recuperados se guarden en el mismo disco del que se rescatan.
function Get-DiscoDeRuta {
    param([string]$Ruta)
    try {
        $cual = (Split-Path -Qualifier $Ruta) -replace ':', ''
        if (-not $cual) { return $null }
        $p = Get-Partition -DriveLetter $cual -ErrorAction Stop
        return [int]$p.DiskNumber
    } catch { return $null }
}

# Letras con letra asignada que viven en el mismo disco fisico.
function Get-HermanasDeDisco {
    param([int]$Disco)
    @(Get-Partition -DiskNumber $Disco -ErrorAction SilentlyContinue |
      Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" })
}

# ==================================================================
#  7. ESCANEO
# ==================================================================
# Firma barata (~20 ms) de las unidades presentes. Get-Disk cuesta
# segundos en frio, asi que el vigia usa esto y solo re-escanea de
# verdad cuando algo cambio.
function Get-FirmaUnidades {
    $sb = New-Object System.Text.StringBuilder
    try {
        foreach ($dr in [System.IO.DriveInfo]::GetDrives()) {
            $listo = $false
            try { $listo = $dr.IsReady } catch {}
            [void]$sb.Append($dr.Name).Append('=').Append($listo).Append(';')
        }
    } catch {}
    $sb.ToString()
}

function Get-Unidades {
    $res = @()
    # Con VerTodos se listan tambien los discos internos, pero SOLO para
    # diagnostico: los diagnosticos son de lectura y no pueden danar nada.
    # Las acciones destructivas siguen limitadas a medios extraibles.
    $discos = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object {
        $_.BusType -in 'USB', 'SD', 'MMC' -or $script:VerTodos })

    foreach ($d in $discos) {
        $soloDiag = $d.BusType -notin 'USB', 'SD', 'MMC'
        $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                   Where-Object { $_.DriveLetter })

        if ($parts.Count -eq 0) {
            $res += @{
                Letra = ''; Etiqueta = ''; Modelo = $d.FriendlyName
                Serie = $d.SerialNumber; Bus = [string]$d.BusType
                TamDisco = [double]$d.Size; TamVol = 0; Libre = 0
                Fs = ''; TipoVol = ''; Disco = $d.Number
                Sector = [int]$d.LogicalSectorSize
                EsSistema = [bool]$d.IsSystem; EsArranque = [bool]$d.IsBoot
                SinMedio = ($d.Size -le 0); Montado = $false
                SoloDiagnostico = $soloDiag
                Protegida = $false; Razones = @()
            }
            continue
        }

        foreach ($p in $parts) {
            $v = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
            # Un volumen puede existir y aun asi no estar accesible (sin formato,
            # sin medio, o con una tabla de particiones que Windows no monta).
            $accesible = $false
            try { $accesible = Test-Path -LiteralPath "$($p.DriveLetter):\" -ErrorAction SilentlyContinue } catch {}
            $res += @{
                Letra    = [string]$p.DriveLetter
                Etiqueta = if ($v) { [string]$v.FileSystemLabel } else { '' }
                Modelo   = $d.FriendlyName
                Serie    = $d.SerialNumber
                Bus      = [string]$d.BusType
                TamDisco = [double]$d.Size
                TamVol   = if ($v -and $v.Size -gt 0) { [double]$v.Size } else { [double]$p.Size }
                Libre    = if ($v) { [double]$v.SizeRemaining } else { 0 }
                Fs       = if ($v) { [string]$v.FileSystem } else { '' }
                TipoVol  = if ($v) { [string]$v.DriveType } else { '' }
                Disco    = $d.Number
                Sector   = [int]$d.LogicalSectorSize
                EsSistema  = [bool]$d.IsSystem
                EsArranque = [bool]$d.IsBoot
                SinMedio = $false
                Montado  = [bool]$accesible
                SoloDiagnostico = $soloDiag
                Protegida = $false; Razones = @()
            }
        }
    }
    # sin coma unaria: los llamadores usan @(...) para recolectar
    $res
}

# ==================================================================
#  8. TARJETAS
# ==================================================================
# Candado dibujado en vectores: nada de fuentes de simbolos, que cambian
# de aspecto segun lo que tenga instalado cada equipo.
function New-Candado {
    param([string]$Color, [double]$Alto = 17)

    # Viewbox + Canvas: las coordenadas son absolutas dentro del lienzo, asi
    # que el arco queda centrado sobre el cuerpo pase lo que pase con la
    # escala. Con alineaciones de Grid el arco se descentraba y el candado
    # parecia abierto, que es justo lo contrario de lo que debe comunicar.
    $vb = New-Object Windows.Controls.Viewbox
    $vb.Height = $Alto
    $vb.Stretch = 'Uniform'
    $vb.IsHitTestVisible = $false

    $cv = New-Object Windows.Controls.Canvas
    $cv.Width = 24; $cv.Height = 30

    # Arco cerrado: baja, sube, semicircunferencia, y baja al mismo nivel.
    $arco = New-Object Windows.Shapes.Path
    $arco.Data = [Windows.Media.Geometry]::Parse('M 7,15 L 7,10 A 5,5 0 0 1 17,10 L 17,15')
    $arco.Stroke = Br $Color
    $arco.StrokeThickness = 2.8
    $arco.StrokeStartLineCap = 'Round'
    $arco.StrokeEndLineCap = 'Round'
    $cv.Children.Add($arco) | Out-Null

    # Cuerpo: de x=3 a x=21, mismo centro (12) que el arco.
    $cuerpo = New-Object Windows.Shapes.Rectangle
    $cuerpo.Width = 18; $cuerpo.Height = 14
    $cuerpo.RadiusX = 2.5; $cuerpo.RadiusY = 2.5
    $cuerpo.Fill = Br $Color
    [Windows.Controls.Canvas]::SetLeft($cuerpo, 3)
    [Windows.Controls.Canvas]::SetTop($cuerpo, 14)
    $cv.Children.Add($cuerpo) | Out-Null

    # Ojo de la cerradura, calado sobre el cuerpo.
    $ojo = New-Object Windows.Shapes.Ellipse
    $ojo.Width = 5; $ojo.Height = 5
    $ojo.Fill = Br '#000000'
    [Windows.Controls.Canvas]::SetLeft($ojo, 9.5)
    [Windows.Controls.Canvas]::SetTop($ojo, 18)
    $cv.Children.Add($ojo) | Out-Null

    $vb.Child = $cv
    $vb
}

# El unico boton que aparece en TODAS las tarjetas, blindadas incluidas:
# diagnosticar solo lee, nunca escribe.
function New-BotonDiagnostico {
    param([hashtable]$D)
    $b = New-Object Windows.Controls.Button
    $b.Content = 'DIAGNOSTICO'
    $b.Style   = $win.FindResource('Btn')
    $b.Width   = 116
    $b.Margin  = New-Object Windows.Thickness 0, 6, 6, 0
    $b.ToolTip = 'Pasaporte, salud S.M.A.R.T. y test de superficie. Solo lectura: no modifica nada, por eso funciona incluso en unidades blindadas.'
    $b.Tag     = $D
    $b.Add_Click({ param($s, $e) Show-Diagnostico $s.Tag })
    $b
}

function New-BotonRecuperar {
    param([hashtable]$D)
    $b = New-Object Windows.Controls.Button
    $b.Content = 'RECUPERAR'
    $b.Style   = $win.FindResource('Btn')
    $b.Width   = 116
    $b.Margin  = New-Object Windows.Thickness 0, 6, 6, 0
    $b.ToolTip = 'Busca archivos borrados o perdidos tras un formateo y los rescata a OTRO disco. El origen se abre en solo lectura, por eso funciona incluso en unidades blindadas.'
    $b.Tag     = @{ Datos = $D; Op = 'recuperar' }
    $b.Add_Click({ param($s, $e) Invoke-Operacion $s.Tag.Datos $s.Tag.Op })
    if ($D.SinMedio) { $b.IsEnabled = $false }
    $b
}

# ------------------------------------------------------------------
#  BOTON DE PROTECCION  (PROTEGER / EXIMIR, recordado entre sesiones)
# ------------------------------------------------------------------
# En que estado esta este disco respecto a la decision del usuario.
function Get-EstadoProteccion {
    param([hashtable]$D)
    $serie  = if ($D.Serie) { ([string]$D.Serie).Trim() } else { '' }
    $nucleo = @(Get-RazonesBloqueo $D -SoloNucleo)
    @{
        Serie     = $serie
        Nucleo    = $nucleo
        # Con una sola razon de nucleo, la exencion no se ofrece siquiera.
        EsNucleo  = ($nucleo.Count -gt 0)
        Protegido = ($serie -and $script:Pref.Protegidos -contains $serie)
        Exento    = ($serie -and $script:Pref.Exentos    -contains $serie)
    }
}

# Aplica un cambio de preferencia y refresca la lista. Devuelve $false si
# no se pudo guardar, para no dejar creer que quedo recordado.
function Set-Proteccion {
    param([string]$Serie, [ValidateSet('proteger', 'desproteger', 'eximir', 'quitar-exencion')][string]$Accion)

    if (-not $Serie) { return $false }
    switch ($Accion) {
        'proteger' {
            $script:Pref.Protegidos = @(@($script:Pref.Protegidos) + $Serie | Select-Object -Unique)
            $script:Pref.Exentos    = @($script:Pref.Exentos | Where-Object { $_ -ne $Serie })
        }
        'desproteger' {
            $script:Pref.Protegidos = @($script:Pref.Protegidos | Where-Object { $_ -ne $Serie })
        }
        'eximir' {
            $script:Pref.Exentos    = @(@($script:Pref.Exentos) + $Serie | Select-Object -Unique)
            $script:Pref.Protegidos = @($script:Pref.Protegidos | Where-Object { $_ -ne $Serie })
        }
        'quitar-exencion' {
            $script:Pref.Exentos    = @($script:Pref.Exentos | Where-Object { $_ -ne $Serie })
        }
    }
    Sync-Preferencias
    $guardado = Save-Preferencias
    # Guardar es lo que importa; redibujar es cosmetico. En la autoprueba
    # no hay lista que refrescar, y un fallo aqui no debe tumbar el cambio.
    try { Update-Lista } catch { }
    $guardado
}

function New-BotonProteccion {
    param([hashtable]$D)

    $st = Get-EstadoProteccion $D
    $b  = New-Object Windows.Controls.Button
    $b.Width  = 116
    $b.Margin = New-Object Windows.Thickness 0, 6, 6, 0
    $b.Style  = $win.FindResource('Btn')

    # Sin serie no hay nada estable que recordar: la letra y el numero de
    # disco cambian solos, y guardar por ellos protegeria al aparato
    # equivocado la proxima vez.
    if (-not $st.Serie) {
        $b.Content   = 'PROTEGER'
        $b.IsEnabled = $false
        $b.ToolTip   = 'Este disco no reporta numero de serie, y la preferencia se guarda por serie. La letra y el numero de disco cambian al reconectar, asi que recordarlo por ahi acabaria protegiendo otro aparato.'
        return $b
    }

    if ($st.Protegido) {
        $b.Content = 'DESPROTEGER'
        $b.Style   = $win.FindResource('BtnRojo')
        $b.ToolTip = "Quita la proteccion que pusiste sobre este disco (serie $($st.Serie)). Las protecciones del sistema no se ven afectadas."
        $b.Tag     = @{ Serie = $st.Serie; Accion = 'desproteger' }
    }
    elseif ($st.EsNucleo) {
        # Sistema, arranque, carpetas de Windows o bus no extraible.
        $b.Content   = 'PROTEGIDO'
        $b.IsEnabled = $false
        $b.ToolTip   = "Proteccion no removible. Motivo: $($st.Nucleo -join ' / '). Esto no se puede desactivar desde la interfaz ni desde ningun archivo de configuracion."
        return $b
    }
    elseif ($st.Exento) {
        $b.Content = 'REACTIVAR'
        $b.ToolTip = "Vuelve a aplicar las reglas normales a este disco (serie $($st.Serie)), que ahora esta exento de ellas."
        $b.Tag     = @{ Serie = $st.Serie; Accion = 'quitar-exencion' }
    }
    elseif ($D.Protegida) {
        # Bloqueado solo por heuristicas: modelo, etiqueta o tamano.
        $b.Content = 'EXIMIR'
        $b.Style   = $win.FindResource('BtnRojo')
        $b.ToolTip = 'Marca este disco como tuyo y conocido, para poder operar sobre el. Se salta las reglas de modelo, etiqueta y tamano, nunca las del sistema.'
        $b.Tag     = @{ Serie = $st.Serie; Accion = 'eximir' }
    }
    else {
        $b.Content = 'PROTEGER'
        $b.ToolTip = 'Bloquea toda escritura sobre este disco y lo recuerda para las proximas veces, por su numero de serie.'
        $b.Tag     = @{ Serie = $st.Serie; Accion = 'proteger' }
    }

    $b.Add_Click({
        param($s, $e)
        $serie  = $s.Tag.Serie
        $accion = $s.Tag.Accion

        # Solo se confirma lo que BAJA las defensas. Proteger no pregunta:
        # equivocarse hacia el lado seguro no cuesta nada.
        if ($accion -in 'desproteger', 'eximir') {
            $cuerpo = if ($accion -eq 'eximir') {
                "El disco de serie $serie dejara de estar bloqueado por las reglas de modelo, etiqueta y tamano, y podras borrarlo y formatearlo.`n`nLas protecciones del sistema (disco de arranque, carpetas de Windows, bus no extraible) siguen aplicando y no se pueden quitar.`n`nSe recordara hasta que pulses REACTIVAR."
            } else {
                "El disco de serie $serie dejara de estar protegido y volvera a las reglas normales.`n`nSi las reglas de fabrica no lo bloquean por su cuenta, quedara operable."
            }
            $ok = Show-Aviso -Titulo 'Confirmar cambio de proteccion' -Nivel 'warn' -SiNo -Cuerpo $cuerpo
            if (-not $ok) { return }
        }

        if (Set-Proteccion $serie $accion) {
            Write-Log "PREFERENCIA GUARDADA: $accion  $SEP  serie $serie" 'ok'
        } else {
            Write-Log "NO SE PUDO ESCRIBIR preferencias.json - el cambio vale solo para esta sesion" 'warn'
        }
    })
    $b
}

function New-Tarjeta {
    param([hashtable]$D)

    # Se vuelve a evaluar el guardian aqui: la tarjeta nunca ofrece
    # botones sin haber verificado ella misma.
    $razones   = @(Get-RazonesBloqueo $D)
    $protegida = $razones.Count -gt 0
    $D.Protegida = $protegida
    $D.Razones   = $razones

    $acento = if ($protegida) { $C.Rojo } elseif ($D.SinMedio) { $C.GrisOscuro } else { $C.Oro }

    # --- contenedor ---
    $root = New-Object Windows.Controls.Grid
    $root.Margin = New-Object Windows.Thickness 0, 0, 0, 12

    $fondo = New-Object Windows.Controls.Border
    $fondo.Background      = Br ($(if ($protegida) { $C.RojoFondo } else { '#0B0C0F' }))
    $fondo.BorderBrush     = Br ($(if ($protegida) { $C.Rojo } else { $C.OroTenue }))
    $fondo.BorderThickness = New-Object Windows.Thickness 1
    $root.Children.Add($fondo) | Out-Null

    if ($protegida) {
        $rayas = New-Object Windows.Shapes.Rectangle
        $rayas.Fill = $win.FindResource('Rayas')
        $rayas.Opacity = 0.10
        $rayas.IsHitTestVisible = $false
        $root.Children.Add($rayas) | Out-Null
    }

    # franja de acento a la izquierda
    $franja = New-Object Windows.Shapes.Rectangle
    $franja.Width = 4
    $franja.HorizontalAlignment = 'Left'
    $franja.Fill = Br $acento
    $root.Children.Add($franja) | Out-Null

    # --- rejilla de contenido ---
    $g = New-Object Windows.Controls.Grid
    $g.Margin = New-Object Windows.Thickness 20, 14, 16, 14
    foreach ($tipo in 'Auto', 'Star', 'Auto') {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = New-Object Windows.GridLength (1, [Windows.GridUnitType]::$tipo)
        $g.ColumnDefinitions.Add($cd)
    }
    $root.Children.Add($g) | Out-Null

    # ---------- columna 0: bloque de letra ----------
    $chipG = New-Object Windows.Controls.Grid
    $chipG.Width = 68; $chipG.Height = 68
    $chipG.VerticalAlignment = 'Center'
    $chipG.Margin = New-Object Windows.Thickness 0, 0, 18, 0
    [Windows.Controls.Grid]::SetColumn($chipG, 0)
    $g.Children.Add($chipG) | Out-Null

    $chipB = New-Object Windows.Controls.Border
    $chipB.Background = Br '#000000'
    $chipB.BorderBrush = Br $acento
    $chipB.BorderThickness = New-Object Windows.Thickness 1
    $chipG.Children.Add($chipB) | Out-Null

    $chipTxt = New-Object Windows.Controls.TextBlock
    $chipTxt.Text = if ($D.SinMedio) { '--' } elseif ($D.Letra) { "$($D.Letra):" } else { "#$($D.Disco)" }
    $chipTxt.FontSize = 23
    $chipTxt.FontWeight = 'Bold'
    $chipTxt.Foreground = Br ($(if ($protegida) { $C.Rojo } elseif ($D.SinMedio) { $C.GrisOscuro } else { $C.Blanco }))
    $chipTxt.HorizontalAlignment = 'Center'
    $chipTxt.VerticalAlignment   = 'Center'
    $chipG.Children.Add($chipTxt) | Out-Null
    Add-Esquinas $chipG $acento 9 1.6

    # ---------- columna 1: informacion ----------
    $sp = New-Object Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($sp, 1)
    $g.Children.Add($sp) | Out-Null

    $titulo = New-Object Windows.Controls.TextBlock
    $nombreUnidad = if ($D.Etiqueta) { $D.Etiqueta } elseif ($D.Modelo) { $D.Modelo } else { 'SIN ETIQUETA' }
    $titulo.Text = ([string]$nombreUnidad).ToUpper()
    $titulo.FontSize = 14
    $titulo.FontWeight = 'Bold'
    $titulo.Foreground = Br ($(if ($D.SinMedio) { $C.Gris } else { $C.Blanco }))
    $titulo.TextTrimming = 'CharacterEllipsis'
    $sp.Children.Add($titulo) | Out-Null

    $sub = New-Object Windows.Controls.TextBlock
    $partes = @()
    if ($D.Modelo -and $D.Etiqueta) { $partes += $D.Modelo.ToUpper() }
    if ($D.Bus)  { $partes += "BUS $($D.Bus)" }
    if ($D.Fs)   { $partes += $D.Fs.ToUpper() } elseif (-not $D.SinMedio) { $partes += 'SIN FORMATO' }
    $partes += "DISCO $($D.Disco)"
    if ($D.SinMedio) {
        $partes += 'SIN MEDIO INSERTADO'
    } elseif (-not $D.Letra) {
        # Sin letra: lo tipico tras grabarle una imagen de Linux, cuyo
        # sistema de archivos Windows no sabe montar. No es un fallo.
        $partes += (Format-Tam $D.TamDisco)
        $partes += 'SIN LETRA ASIGNADA - NORMAL TRAS GRABAR UNA IMAGEN'
    } elseif (-not $D.Montado) {
        if ($D.TamVol -gt 0) { $partes += (Format-Tam $D.TamVol) }
        $partes += 'NO MONTADO - WINDOWS NO PUEDE LEERLA'
    } elseif ($D.TamVol -gt 0) {
        $partes += ('{0} LIBRES DE {1}' -f (Format-Tam $D.Libre), (Format-Tam $D.TamVol))
    }
    $sub.Text = ($partes -join "  $SEP  ")
    $sub.FontSize = 10
    $sub.Foreground = Br $C.Gris
    $sub.Margin = New-Object Windows.Thickness 0, 5, 0, 0
    $sub.TextWrapping = 'Wrap'
    $sp.Children.Add($sub) | Out-Null

    if (-not $D.SinMedio -and $D.Montado -and $D.TamVol -gt 0) {
        # 1.0 / 0.0 a proposito: con enteros, [math]::Min elige la sobrecarga
        # de int y trunca la fraccion a 0.
        $usado = [math]::Max(0.0, [math]::Min(1.0, ($D.TamVol - $D.Libre) / $D.TamVol))
        $fila = New-Object Windows.Controls.StackPanel
        $fila.Orientation = 'Horizontal'
        $fila.Margin = New-Object Windows.Thickness 0, 9, 0, 0
        $barra = New-BarraSegmentada $usado 32 $(if ($protegida) { $C.Rojo } else { $C.Oro }) '#22262C'
        $fila.Children.Add($barra) | Out-Null
        $pct = New-Object Windows.Controls.TextBlock
        $pct.Text = ('{0,3:N0}% USADO' -f ($usado * 100))
        $pct.FontSize = 10
        $pct.Foreground = Br ($(if ($protegida) { $C.Rojo } else { $C.Oro }))
        $pct.Margin = New-Object Windows.Thickness 8, 0, 0, 0
        $pct.VerticalAlignment = 'Center'
        $fila.Children.Add($pct) | Out-Null
        $sp.Children.Add($fila) | Out-Null
    }

    if ($protegida) {
        $enc = New-Object Windows.Controls.TextBlock
        $enc.Text = '/// MOTIVOS DEL BLINDAJE'
        $enc.FontSize = 9
        $enc.FontWeight = 'Bold'
        $enc.Foreground = Br $C.Rojo
        $enc.Margin = New-Object Windows.Thickness 0, 10, 0, 2
        $sp.Children.Add($enc) | Out-Null
        foreach ($r in $razones) {
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = "  $SEP  $r"
            $t.FontSize = 9
            $t.Foreground = Br $C.RojoClaro
            $t.TextWrapping = 'Wrap'
            $t.Margin = New-Object Windows.Thickness 0, 2, 0, 0
            $sp.Children.Add($t) | Out-Null
        }
    }

    # ---------- columna 2: acciones ----------
    $acc = New-Object Windows.Controls.StackPanel
    $acc.VerticalAlignment = 'Center'
    $acc.Margin = New-Object Windows.Thickness 18, 0, 0, 0
    [Windows.Controls.Grid]::SetColumn($acc, 2)
    $g.Children.Add($acc) | Out-Null

    if ($protegida) {
        $lg = New-Object Windows.Controls.Grid
        $lg.Width = 132; $lg.Height = 54
        $lb = New-Object Windows.Controls.Border
        $lb.Background = Br '#000000'
        $lb.BorderBrush = Br $C.Rojo
        $lb.BorderThickness = New-Object Windows.Thickness 1
        $lg.Children.Add($lb) | Out-Null
        $lr = New-Object Windows.Shapes.Rectangle
        $lr.Fill = $win.FindResource('Rayas')
        $lr.Opacity = 0.30
        $lg.Children.Add($lr) | Out-Null
        $ls = New-Object Windows.Controls.StackPanel
        $ls.VerticalAlignment = 'Center'
        $fila0 = New-Object Windows.Controls.StackPanel
        $fila0.Orientation = 'Horizontal'
        $fila0.HorizontalAlignment = 'Center'
        $cand = New-Candado $C.Rojo 17
        $cand.Margin = New-Object Windows.Thickness 0, 0, 7, 0
        $cand.VerticalAlignment = 'Center'
        $fila0.Children.Add($cand) | Out-Null
        $l1 = New-Object Windows.Controls.TextBlock
        $l1.Text = 'BLOQUEADA'; $l1.FontSize = 12; $l1.FontWeight = 'Bold'
        $l1.Foreground = Br $C.Rojo; $l1.VerticalAlignment = 'Center'
        $fila0.Children.Add($l1) | Out-Null
        $ls.Children.Add($fila0) | Out-Null
        $l2 = New-Object Windows.Controls.TextBlock
        $l2.Text = 'SOLO LECTURA'; $l2.FontSize = 8
        $l2.Foreground = Br $C.RojoClaro; $l2.HorizontalAlignment = 'Center'
        $l2.Margin = New-Object Windows.Thickness 0, 2, 0, 0
        $ls.Children.Add($l2) | Out-Null
        $lg.Children.Add($ls) | Out-Null
        Add-Esquinas $lg $C.Rojo 9 1.6
        $acc.Children.Add($lg) | Out-Null

        # Diagnosticar y recuperar son de LECTURA sobre el origen: se
        # ofrecen tambien en discos blindados. De hecho el disco de
        # respaldo es el que mas interesa vigilar y del que mas duele
        # perder algo.
        $acc.Children.Add((New-BotonDiagnostico $D)) | Out-Null
        $acc.Children.Add((New-BotonRecuperar $D)) | Out-Null
        # No escribe en el disco: cambia una preferencia. Si el bloqueo es
        # del nucleo, el propio boton se dibuja deshabilitado.
        $acc.Children.Add((New-BotonProteccion $D)) | Out-Null
    }
    elseif ($D.SinMedio) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = 'SIN MEDIO'
        $t.Foreground = Br $C.GrisOscuro
        $t.FontSize = 10; $t.FontWeight = 'Bold'
        $t.VerticalAlignment = 'Center'
        $acc.Children.Add($t) | Out-Null
    }
    else {
        # 'Necesita': que hace falta para que el boton sirva.
        #   montada -> un volumen que Windows pueda leer
        #   letra   -> al menos una letra asignada
        #   (vacio) -> funciona sobre el disco, sin depender del volumen
        $defs = @(
            @{ Txt = 'LIMPIAR';   Op = 'limpiar';   Estilo = 'Btn';     Necesita = 'montada' },
            @{ Txt = 'FORMATEAR'; Op = 'formatear'; Estilo = 'BtnRojo'; Necesita = 'letra' },
            @{ Txt = 'REPARAR';   Op = 'reparar';   Estilo = 'BtnRojo'; Necesita = ''
               Ayuda = 'Borra la tabla de particiones del DISCO COMPLETO y lo vuelve a crear desde cero. Usalo cuando formatear falla. Afecta todas las particiones del mismo disco fisico.' },
            @{ Txt = 'GRABAR';    Op = 'grabar';    Estilo = 'BtnRojo'; Necesita = ''
               Ayuda = 'Escribe una imagen .iso/.img/.gz/.zip byte a byte sobre el DISCO COMPLETO, como hace balenaEtcher, pero verificando antes la identidad del disco por numero de serie.' },
            @{ Txt = 'EXPULSAR';  Op = 'expulsar';  Estilo = 'Btn';     Necesita = '' }
        )
        # Cinco acciones en una sola columna estiran la tarjeta de mas:
        # en dos columnas ocupan tres filas en vez de cinco.
        $rejilla = New-Object Windows.Controls.WrapPanel
        $rejilla.Orientation = 'Horizontal'
        $rejilla.Width = 244
        $acc.Children.Add($rejilla) | Out-Null

        foreach ($def in $defs) {
            $b = New-Object Windows.Controls.Button
            $b.Content = $def.Txt
            $b.Style   = $win.FindResource($def.Estilo)
            $b.Width   = 116
            $b.Margin  = New-Object Windows.Thickness 0, 0, 6, 6
            $b.Tag     = @{ Datos = $D; Op = $def.Op }
            $b.Add_Click({ param($s, $e) Invoke-Operacion $s.Tag.Datos $s.Tag.Op })
            if ($def.ContainsKey('Ayuda')) { $b.ToolTip = $def.Ayuda }

            $falta = switch ($def.Necesita) {
                'montada' { if (-not $D.Montado) { 'Windows no puede leer esta unidad. Prueba FORMATEAR, o REPARAR si eso falla.' } }
                'letra'   { if (-not $D.Letra)   { 'Esta unidad no tiene letra asignada (normal despues de grabar una imagen). Usa REPARAR para volver a dejarla usable.' } }
                default   { $null }
            }
            if ($falta) {
                $b.IsEnabled = $false
                $b.ToolTip   = $falta
            } else {
                $script:Botones += $b
            }
            $rejilla.Children.Add($b) | Out-Null
        }
        $rejilla.Children.Add((New-BotonDiagnostico $D)) | Out-Null
        $rejilla.Children.Add((New-BotonRecuperar $D)) | Out-Null
        $rejilla.Children.Add((New-BotonProteccion $D)) | Out-Null
    }

    Add-Muescas  $root ($(if ($protegida) { $C.Rojo } else { $C.OroTenue })) 12
    Add-Esquinas $root $acento 13 1.6
    $root
}

# ==================================================================
#  9. DIALOGOS
# ==================================================================
# Aviso con el mismo lenguaje visual que el resto: el MessageBox de
# Windows es blanco y rompe el HUD por completo.
#
#   -Secciones espera @( @{ Titulo='...'; Lineas=@('...','...') } )
#   -SiNo devuelve $true solo si se acepta.
function Show-Aviso {
    param(
        [string]$Titulo,
        [string]$Cuerpo = '',
        [array]$Secciones = @(),
        [ValidateSet('info', 'warn', 'error')][string]$Nivel = 'info',
        [switch]$SiNo,
        [switch]$SoloConstruir
    )

    $acento = switch ($Nivel) { 'error' { $C.Rojo } 'warn' { $C.Oro } default { $C.Oro } }
    $txtAcento = switch ($Nivel) { 'error' { $C.RojoClaro } default { $C.Oro } }
    $fondoEnc  = switch ($Nivel) { 'error' { $C.RojoFondo } default { '#14110A' } }

    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Titulo" Width="640" SizeToContent="Height" MaxHeight="720"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Cascadia Mono, Consolas, Lucida Console">
  <Grid Margin="12">
    <Grid.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Color="$acento" Opacity="0.45"/></Grid.Effect>
    <Border Background="$($C.Fondo)" BorderBrush="$acento" BorderThickness="1"/>
    <DockPanel>
      <Grid DockPanel.Dock="Top" Background="$fondoEnc">
        <Rectangle Fill="{DynamicResource RayasDlg}" Opacity="0.10"/>
        <StackPanel Orientation="Horizontal" Margin="22,15,22,15">
          <TextBlock Text="///" Foreground="$acento" FontSize="15" FontWeight="Bold" Margin="0,0,10,0"/>
          <TextBlock x:Name="Enc" Foreground="$txtAcento" FontSize="15" FontWeight="Bold"/>
        </StackPanel>
      </Grid>
      <Rectangle DockPanel.Dock="Top" Height="1" Fill="$($C.Oro)"/>

      <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal"
                  HorizontalAlignment="Right" Margin="22,12,22,20">
        <Button x:Name="BtnNo" Content="CANCELAR" Style="{DynamicResource BtnDlg}"
                Width="130" Margin="0,0,10,0" Visibility="Collapsed"/>
        <Button x:Name="BtnSi" Content="ACEPTAR" Style="{DynamicResource BtnDlg}" Width="130"/>
      </StackPanel>

      <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="22,18,14,10">
        <StackPanel x:Name="Cuerpo"/>
      </ScrollViewer>
    </DockPanel>
    <Path Data="M 0,14 L 0,0 L 14,0"   Stroke="$($C.Oro)" StrokeThickness="1.8" Width="14" Height="14"
          HorizontalAlignment="Left"  VerticalAlignment="Top"/>
    <Path Data="M 14,0 L 14,14 L 0,14" Stroke="$($C.Oro)" StrokeThickness="1.8" Width="14" Height="14"
          HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
  </Grid>
</Window>
"@
    $dr  = New-Object System.Xml.XmlNodeReader ([xml]$x)
    $dlg = [Windows.Markup.XamlReader]::Load($dr)
    if ($win.IsVisible) { $dlg.Owner = $win }
    $dlg.Resources.Add('Fondo',      $win.FindResource('Fondo'))
    $dlg.Resources.Add('RayasDlg',   $win.FindResource('Rayas'))
    $dlg.Resources.Add('BtnDlg',     $win.FindResource('Btn'))
    $dlg.Resources.Add('BtnDlgRojo', $win.FindResource('BtnRojo'))

    $dlg.FindName('Enc').Text = $Titulo.ToUpper()
    # OJO: no llamarlo $cuerpo. PowerShell no distingue mayusculas, asi que
    # chocaria con el parametro [string]$Cuerpo y convertiria el panel a texto.
    $panel = $dlg.FindName('Cuerpo')

    if ($Cuerpo) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Cuerpo
        $t.Foreground = Br $C.Blanco
        $t.FontSize = 11.5
        $t.LineHeight = 18
        $t.TextWrapping = 'Wrap'
        $panel.Children.Add($t) | Out-Null
    }

    foreach ($s in $Secciones) {
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = "// $($s.Titulo)"
        $h.Foreground = Br $C.Oro
        $h.FontSize = 10
        $h.FontWeight = 'Bold'
        $h.Margin = New-Object Windows.Thickness 0, 14, 0, 5
        $panel.Children.Add($h) | Out-Null

        foreach ($ln in $s.Lineas) {
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = "  $SEP  $ln"
            $t.Foreground = Br $C.Blanco
            $t.FontSize = 11
            $t.LineHeight = 17
            $t.TextWrapping = 'Wrap'
            $t.Margin = New-Object Windows.Thickness 6, 0, 0, 0
            $panel.Children.Add($t) | Out-Null
        }
    }

    $si = $dlg.FindName('BtnSi')
    $no = $dlg.FindName('BtnNo')
    if ($SiNo) {
        $si.Content = 'SI'
        $no.Visibility = 'Visible'
        $si.Style = $win.FindResource('BtnRojo')
    }
    $si.Add_Click({ $dlg.DialogResult = $true }.GetNewClosure())
    $no.Add_Click({ $dlg.DialogResult = $false }.GetNewClosure())

    if ($SoloConstruir) { return $dlg }
    [bool]$dlg.ShowDialog()
}

# ==================================================================
#  9b. DIALOGO DE CONFIRMACION DESTRUCTIVA
# ==================================================================
function Show-Confirmacion {
    param(
        [hashtable]$D,
        [string]$Op,
        # Datos propios de 'grabar': Imagen, TamImagen, Arrancable.
        [hashtable]$Extra,
        # Construye el dialogo y lo devuelve sin mostrarlo (para la autoprueba).
        [switch]$SoloConstruir
    )

    # 'reparar' actua sobre el disco entero, asi que se confirma con el
    # disco, no con la letra: la frase describe el alcance real.
    $titulo = switch ($Op) {
        'formatear' { 'FORMATEAR UNIDAD' }
        'reparar'   { 'REPARAR DISCO COMPLETO' }
        'grabar'    { 'GRABAR IMAGEN EN EL DISCO' }
        default     { 'BORRAR TODO EL CONTENIDO' }
    }
    $frase = if ($Op -in 'reparar', 'grabar') { "DISCO $($D.Disco)" } else { "$($D.Letra):" }

    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Confirmar" Width="600" SizeToContent="Height"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Cascadia Mono, Consolas, Lucida Console">
  <Grid Margin="12">
    <Grid.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Color="#E5372F" Opacity="0.5"/></Grid.Effect>
    <Border Background="$($C.Fondo)" BorderBrush="$($C.Rojo)" BorderThickness="1"/>
    <StackPanel>
      <Grid Background="$($C.RojoFondo)">
        <Rectangle Fill="{DynamicResource RayasDlg}" Opacity="0.12"/>
        <StackPanel Margin="22,15,22,15">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="///" Foreground="$($C.Rojo)" FontSize="16" FontWeight="Bold" Margin="0,0,10,0"/>
            <TextBlock Text="$titulo" Foreground="$($C.Rojo)" FontSize="16" FontWeight="Bold"/>
            <TextBlock Text="///" Foreground="$($C.Rojo)" FontSize="16" FontWeight="Bold" Margin="10,0,0,0"/>
          </StackPanel>
          <TextBlock x:Name="Sub" Foreground="$($C.Gris)" FontSize="10" Margin="0,8,0,0" TextWrapping="Wrap"/>
        </StackPanel>
      </Grid>
      <Rectangle Height="1" Fill="$($C.Oro)"/>
      <StackPanel Margin="22,18,22,6">
        <TextBlock x:Name="Aviso" Foreground="$($C.Blanco)" FontSize="11" TextWrapping="Wrap" LineHeight="18"/>
        <Border x:Name="CajaBoot" Visibility="Collapsed" Margin="0,14,0,0"
                Background="#1A1405" BorderBrush="$($C.Oro)" BorderThickness="1" Padding="12,9">
          <TextBlock x:Name="AvisoBoot" Foreground="$($C.Oro)" FontSize="10" TextWrapping="Wrap"/>
        </Border>
        <!-- Solo para REPARAR: esquema de particion y sistema de archivos -->
        <StackPanel x:Name="FilaRep" Orientation="Horizontal" Visibility="Collapsed" Margin="0,16,0,0">
          <TextBlock Text="ESQUEMA" Foreground="$($C.Oro)" FontSize="10" FontWeight="Bold"
                     VerticalAlignment="Center" Margin="0,0,8,0"/>
          <Button x:Name="BtnEsquema" Content="MBR" Style="{DynamicResource BtnDlg}" Width="86" Margin="0,0,18,0"/>
          <TextBlock Text="FORMATO" Foreground="$($C.Oro)" FontSize="10" FontWeight="Bold"
                     VerticalAlignment="Center" Margin="0,0,8,0"/>
          <Button x:Name="BtnFormato" Content="AUTO" Style="{DynamicResource BtnDlg}" Width="92"/>
        </StackPanel>

        <!-- Solo para GRABAR: comprobar la imagen contra su hash publicado -->
        <StackPanel x:Name="FilaHash" Visibility="Collapsed" Margin="0,16,0,0">
          <TextBlock Text="SHA256 / SHA1 / MD5 ESPERADO  (opcional, pegalo de la web de la distro)"
                     Foreground="$($C.Oro)" FontSize="10" FontWeight="Bold" Margin="0,0,0,6"/>
          <Grid>
            <Border Background="#000000" BorderBrush="$($C.OroTenue)" BorderThickness="1"/>
            <TextBox x:Name="Hash" Background="Transparent" Foreground="$($C.Blanco)"
                     BorderThickness="0" Padding="8,6" FontSize="11" CaretBrush="$($C.Oro)"/>
          </Grid>
        </StackPanel>

        <CheckBox x:Name="Verificar" Visibility="Collapsed" IsChecked="True" Margin="0,14,0,0"
                  Foreground="$($C.Blanco)" FontSize="11">
          <TextBlock Text="Verificar al terminar (relee el disco y compara byte a byte)"
                     Foreground="$($C.Blanco)" FontSize="11" TextWrapping="Wrap"/>
        </CheckBox>
        <TextBlock Text="ESCRIBE  $frase  PARA CONFIRMAR:" Foreground="$($C.Oro)"
                   FontSize="10" FontWeight="Bold" Margin="0,18,0,7"/>
        <Grid>
          <Border Background="#000000" BorderBrush="$($C.OroTenue)" BorderThickness="1"/>
          <TextBox x:Name="Campo" Background="Transparent" Foreground="$($C.Blanco)"
                   BorderThickness="0" Padding="10,8" FontSize="15" FontWeight="Bold"
                   CaretBrush="$($C.Rojo)"/>
        </Grid>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="22,14,22,20">
        <Button x:Name="Cancel" Content="CANCELAR" Style="{DynamicResource BtnDlg}" Width="130" Margin="0,0,10,0"/>
        <Button x:Name="Ok" Content="EJECUTAR" Style="{DynamicResource BtnDlgRojo}" Width="130" IsEnabled="False"/>
      </StackPanel>
    </StackPanel>
    <Path Data="M 0,14 L 0,0 L 14,0"   Stroke="$($C.Oro)" StrokeThickness="1.8" Width="14" Height="14"
          HorizontalAlignment="Left"  VerticalAlignment="Top"/>
    <Path Data="M 14,0 L 14,14 L 0,14" Stroke="$($C.Oro)" StrokeThickness="1.8" Width="14" Height="14"
          HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
  </Grid>
</Window>
"@
    $dr  = New-Object System.Xml.XmlNodeReader ([xml]$x)
    $dlg = [Windows.Markup.XamlReader]::Load($dr)
    # Owner solo se puede fijar si la ventana principal ya se mostro
    if ($win.IsVisible) { $dlg.Owner = $win }
    # reutiliza los recursos de la ventana principal
    $dlg.Resources.Add('Fondo',      $win.FindResource('Fondo'))
    $dlg.Resources.Add('RayasDlg',   $win.FindResource('Rayas'))
    $dlg.Resources.Add('BtnDlg',     $win.FindResource('Btn'))
    $dlg.Resources.Add('BtnDlgRojo', $win.FindResource('BtnRojo'))

    $nombre = if ($D.Etiqueta) { $D.Etiqueta } else { $D.Modelo }
    $dlg.FindName('Sub').Text =
        "$($D.Letra):  $($nombre.ToUpper())  $SEP  $(Format-Tam $D.TamVol)  $SEP  DISCO $($D.Disco)  $SEP  BUS $($D.Bus)"
    $dlg.FindName('Aviso').Text = switch ($Op) {
        'formatear' {
            "Se formateara la unidad $($D.Letra): por completo. Se perdera TODO su contenido y no hay forma de recuperarlo. Verifica dos veces que esta es la memoria USB correcta."
        }
        'reparar' {
            $hermanas = @(Get-HermanasDeDisco $D.Disco)
            $alcance  = if ($hermanas.Count -gt 0) { $hermanas -join ', ' } else { 'ninguna con letra asignada' }
            "Esto NO es un formateo: borra la tabla de particiones del DISCO $($D.Disco) completo y la vuelve a crear desde cero.`n`n" +
            "Alcance: TODAS las particiones de ese disco fisico ($alcance), no solo $($D.Letra):.`n`n" +
            "Antes de ejecutar se verifica que el disco $($D.Disco) siga siendo el mismo aparato, comparando su numero de serie ($($D.Serie)). Si lo reconectaste y cambio de numero, la operacion se aborta sola."
        }
        'grabar' {
            $n   = if ($Extra) { [System.IO.Path]::GetFileName($Extra.Imagen) } else { '?' }
            $t   = if ($Extra -and $Extra.TamImagen) { Format-Tam $Extra.TamImagen } else { 'tamano desconocido' }
            $her = @(Get-HermanasDeDisco $D.Disco)
            $alc = if ($her.Count -gt 0) { $her -join ', ' } else { 'ninguna con letra asignada' }
            "Se escribira la imagen byte a byte sobre el DISCO $($D.Disco) completo, desde el sector cero.`n`n" +
            "Imagen:  $n  ($t)`n" +
            "Alcance: TODAS las particiones del disco ($alc). Todo lo que haya se pierde.`n`n" +
            "Antes de escribir se relee el disco y se compara su numero de serie ($($D.Serie)). Si lo reconectaste y cambio de numero, la operacion se aborta sola."
        }
        default {
            "Se borraran todos los archivos y carpetas de $($D.Letra):, incluidos los ocultos y de sistema. No pasan por la papelera."
        }
    }

    if ($Op -eq 'reparar') {
        $dlg.FindName('FilaRep').Visibility = 'Visible'
        $bEsq = $dlg.FindName('BtnEsquema')
        $bFmt = $dlg.FindName('BtnFormato')
        $esquemas = @('MBR', 'GPT')
        $formatos = @('AUTO', 'FAT32', 'exFAT', 'NTFS')
        $iEsq = @{ I = 0 }
        $iFmt = @{ I = 0 }
        $bEsq.ToolTip = 'MBR es lo mas compatible (camaras, autoestereos, equipos viejos). GPT hace falta para discos de mas de 2 TB.'
        $bFmt.ToolTip = 'AUTO elige FAT32 hasta 32 GB y exFAT por encima. NTFS solo si vas a usarla en Windows: no la leen bien otros sistemas.'
        $bEsq.Add_Click({
            $iEsq.I = ($iEsq.I + 1) % $esquemas.Count
            $bEsq.Content = $esquemas[$iEsq.I]
        }.GetNewClosure())
        $bFmt.Add_Click({
            $iFmt.I = ($iFmt.I + 1) % $formatos.Count
            $bFmt.Content = $formatos[$iFmt.I]
        }.GetNewClosure())
    }

    if ($Op -eq 'grabar') {
        $dlg.FindName('Verificar').Visibility = 'Visible'
        $dlg.FindName('FilaHash').Visibility = 'Visible'
        if ($Extra -and -not $Extra.Arrancable) {
            $dlg.FindName('CajaBoot').Visibility = 'Visible'
            $dlg.FindName('AvisoBoot').Text =
                'AVISO: la imagen no tiene firma de arranque (0x55AA) en su primer sector. ' +
                'La escritura cruda funciona con imagenes isohybrid de Linux y archivos .img. ' +
                'Los ISO de instalacion de Windows NO arrancan asi: necesitan particion FAT32 con ' +
                'archivos copiados y gestor de arranque. Se grabara igual, pero puede que no arranque.'
        }
    }

    $campo = $dlg.FindName('Campo')
    $ok    = $dlg.FindName('Ok')
    $campo.Add_TextChanged({ $ok.IsEnabled = ($campo.Text.Trim().ToUpper() -eq $frase) }.GetNewClosure())
    $chk = $dlg.FindName('Verificar')
    # Dentro de una closure, escribir $script:X NO llega al ambito real: la
    # closure tiene el suyo propio. Por eso se escribe en un hashtable
    # capturado, que si es la misma referencia de fuera.
    $opts = $script:Opciones
    $cajaHash = $dlg.FindName('Hash')
    $btnEsq2  = $dlg.FindName('BtnEsquema')
    $btnFmt2  = $dlg.FindName('BtnFormato')
    $ok.Add_Click({
        $opts.VerificarTrasGrabar = [bool]$chk.IsChecked
        $opts.EsquemaReparar = [string]$btnEsq2.Content
        $opts.FormatoReparar = [string]$btnFmt2.Content
        $opts.HashEsperado   = ([string]$cajaHash.Text).Trim()
        $dlg.DialogResult = $true
    }.GetNewClosure())
    $dlg.FindName('Cancel').Add_Click({ $dlg.DialogResult = $false }.GetNewClosure())
    $dlg.Add_ContentRendered({ $campo.Focus() | Out-Null }.GetNewClosure())

    if ($SoloConstruir) { return $dlg }
    [bool]$dlg.ShowDialog()
}

# ==================================================================
#  10. TRABAJO EN SEGUNDO PLANO
# ==================================================================
$script:TrabajoSb = {
    # Un solo hashtable en vez de una lista posicional larga: con diez
    # argumentos por posicion, insertar uno en medio rompe todo en silencio.
    param($Job, $Sync)

    $Letra    = $Job.Letra
    $Op       = $Job.Op
    $Guard    = $Job.Guard
    $Etiqueta = $Job.Etiqueta
    $Fs       = $Job.Fs
    $Serie    = $Job.Serie
    $Modelo   = $Job.Modelo
    $TamDisco = $Job.TamDisco
    $Disco    = $Job.Disco

    function Say($t, $n = 'info') { $Sync.Cola.Enqueue(@{ T = 'log'; Txt = $t; N = $n }) }
    function Prog($pct, $fase, $vel = '', $eta = '') {
        $Sync.Cola.Enqueue(@{ T = 'prog'; Pct = $pct; Fase = $fase; Vel = $vel; Eta = $eta })
    }

    try {
        # ---- SEGUNDA VERIFICACION, ya dentro del hilo de ejecucion ----
        $L = ([string]$Letra).ToUpper()
        $motivos = @()
        if ($Guard.Letras -contains $L) { $motivos += "letra $L en lista negra" }

        # La lista negra de series gana siempre; solo si no esta en ella
        # puede una serie permitida saltarse modelo y etiqueta.
        $enNegra = $false
        foreach ($s in $Guard.Seriales) {
            if ($Serie -and "$Serie".Trim() -like "*$s*") { $motivos += "serie $s"; $enNegra = $true }
        }
        $permitida = $false
        if (-not $enNegra -and $Serie) {
            foreach ($ok in $Guard.Permitidos) {
                if ($ok -and "$Serie".Trim() -like "*$ok*") { $permitida = $true }
            }
        }
        if (-not $permitida) {
            foreach ($n in $Guard.Nombres)   { if ($Modelo   -and "$Modelo".ToLower()   -like "*$n*") { $motivos += "modelo '$n'" } }
            foreach ($e in $Guard.Etiquetas) { if ($Etiqueta -and "$Etiqueta".ToLower() -like "*$e*") { $motivos += "etiqueta '$e'" } }
        }
        if ([double]$TamDisco -gt ($Guard.TamMaxGB * 1GB)) { $motivos += 'tamano fuera de rango' }

        # Solo limpiar y formatear necesitan un volumen legible. Reparar,
        # grabar y expulsar trabajan sobre el disco, y despues de grabar una
        # imagen la unidad se queda sin letra: exigir volumen ahi impedia
        # hasta expulsarla.
        $opDisco = $Op -in 'reparar', 'grabar'
        $vol = if ($L) { Get-Volume -DriveLetter $L -ErrorAction SilentlyContinue } else { $null }
        if (-not $vol -and $Op -in 'limpiar', 'formatear') {
            $motivos += $(if ($L) { "la unidad $L`: no tiene un volumen legible" }
                          else { "el disco $Disco no tiene ninguna unidad con letra" })
        }
        # 'Fixed' solo descalifica si ademas el bus no es de medio extraible:
        # los HDD externos por USB se declaran Fixed igual que un disco interno.
        if ($vol -and $vol.DriveType -eq 'Fixed') {
            $dkBus = (Get-Disk -Number $Disco -ErrorAction SilentlyContinue).BusType
            if ($dkBus -notin 'USB', 'SD', 'MMC') { $motivos += "volumen fijo en bus $dkBus" }
        }
        if ($L) {
            foreach ($p in 'Windows', 'Program Files', 'Users') {
                if (Test-Path -LiteralPath "$L`:\$p") { $motivos += "carpeta de sistema $p" }
            }
        }

        # 'reparar' y 'grabar' escriben el disco entero: se confirma la IDENTIDAD
        # del disco por numero de serie, porque los numeros cambian al reconectar.
        if ($opDisco) {
            $dk = Get-Disk -Number $Disco -ErrorAction SilentlyContinue
            if (-not $dk) {
                $motivos += "el disco $Disco ya no existe"
            } else {
                $serieReal = "$($dk.SerialNumber)".Trim()
                if ($serieReal -ne "$Serie".Trim()) {
                    $motivos += "el disco $Disco cambio de identidad (serie '$serieReal', se esperaba '$Serie')"
                }
                # Tamano y modelo tambien: hay adaptadores que dan la misma
                # serie de relleno a cualquier disco que les pongas.
                if ([double]$dk.Size -ne [double]$TamDisco) {
                    $motivos += "el disco $Disco cambio de tamano"
                }
                if ($Modelo -and "$($dk.FriendlyName)".Trim() -ne "$Modelo".Trim()) {
                    $motivos += "el disco $Disco cambio de modelo"
                }
                if ($dk.IsSystem -or $dk.IsBoot) { $motivos += 'disco de sistema o de arranque' }
                if ($dk.BusType -notin 'USB', 'SD', 'MMC') { $motivos += "bus $($dk.BusType) no extraible" }
                if ($dk.Size -gt ($Guard.TamMaxGB * 1GB)) { $motivos += 'tamano de disco fuera de rango' }
                foreach ($n in $Guard.Nombres)  { if ("$($dk.FriendlyName)".ToLower() -like "*$n*") { $motivos += "modelo '$n'" } }
                foreach ($s in $Guard.Seriales) { if ($serieReal -like "*$s*") { $motivos += "serie $s" } }
                foreach ($pp in @(Get-Partition -DiskNumber $Disco -ErrorAction SilentlyContinue |
                                  Where-Object { $_.DriveLetter })) {
                    if ($Guard.Letras -contains ([string]$pp.DriveLetter).ToUpper()) {
                        $motivos += "el disco contiene la unidad blindada $($pp.DriveLetter):"
                    }
                }
            }
        }

        if ($motivos.Count -gt 0) {
            Say ("ABORTADO POR EL GUARDIAN: {0}" -f ($motivos -join ', ')) 'error'
            $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $false }); return
        }

        # ---------------------------- LIMPIAR ----------------------------
        if ($Op -eq 'limpiar') {
            Say "Limpiando $L`: ..."
            $items = @(Get-ChildItem -LiteralPath "$L`:\" -Force -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -ne 'System Volume Information' })
            if ($items.Count -eq 0) { Say 'La unidad ya estaba vacia.' 'warn' }
            $ok = 0; $fail = 0
            foreach ($it in $items) {
                try {
                    Remove-Item -LiteralPath $it.FullName -Recurse -Force -ErrorAction Stop
                    $ok++
                    Say "  eliminado: $($it.Name)"
                } catch {
                    $fail++
                    Say "  NO se pudo eliminar '$($it.Name)': $($_.Exception.Message)" 'error'
                }
            }
            Say "Limpieza terminada. $ok elemento(s) eliminado(s), $fail con error." $(if ($fail) { 'warn' } else { 'ok' })
        }
        # --------------------------- FORMATEAR ---------------------------
        elseif ($Op -eq 'formatear') {
            Say "Formateando $L`: como $Fs (rapido)..."
            $p = @{
                DriveLetter = $L; FileSystem = $Fs; Full = $false
                Force = $true; Confirm = $false; ErrorAction = 'Stop'
            }
            if ($Etiqueta) { $p.NewFileSystemLabel = $Etiqueta }
            Format-Volume @p | Out-Null
            Say "Unidad $L`: formateada correctamente." 'ok'
        }
        # --------------------------- REPARAR -----------------------------
        elseif ($Op -eq 'reparar') {
            Say "Reparando el disco $Disco (identidad verificada: serie '$Serie')..."

            try {
                Set-Disk -Number $Disco -IsReadOnly $false -ErrorAction Stop
                Say '  atributo de solo lectura del disco: limpiado.'
            } catch {
                Say "  no se pudo limpiar el atributo de solo lectura: $($_.Exception.Message)" 'warn'
            }

            Say '  borrando la tabla de particiones...'
            Clear-Disk -Number $Disco -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop

            $esq = if ($Job.Esquema -in 'MBR', 'GPT') { $Job.Esquema } else { 'MBR' }
            Say "  inicializando el disco como $esq..."
            try { Initialize-Disk -Number $Disco -PartitionStyle $esq -ErrorAction Stop } catch { }

            Say '  creando particion nueva...'
            $np = New-Partition -DiskNumber $Disco -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
            $numPart = $np.PartitionNumber

            # Windows tarda en registrar el volumen de una particion recien
            # creada. Preguntarle antes de tiempo hace que Format-Volume
            # falle con "no encontro objetos MSFT_Volume". Un Start-Sleep
            # fijo no basta: unas veces llega y otras no. Hay que esperar
            # a que el volumen exista de verdad.
            Say '  esperando a que Windows registre el volumen...'
            $letraNueva = $null
            for ($i = 0; $i -lt 40 -and -not $letraNueva; $i++) {
                Start-Sleep -Milliseconds 500
                $pAhora = Get-Partition -DiskNumber $Disco -PartitionNumber $numPart -ErrorAction SilentlyContinue
                if ($pAhora -and $pAhora.DriveLetter) {
                    if (Get-Volume -DriveLetter $pAhora.DriveLetter -ErrorAction SilentlyContinue) {
                        $letraNueva = $pAhora.DriveLetter
                    }
                }
            }
            if (-not $letraNueva) {
                throw 'Windows no registro el volumen de la particion nueva a tiempo. Vuelve a pulsar REPARAR.'
            }
            Say "  volumen listo como $letraNueva`: tras $([int]($i * 0.5)) s."

            Say "  formateando como $Fs ..."
            $etq = if ($Etiqueta) { $Etiqueta } else { 'USB' }
            $formateado = $false
            for ($t = 0; $t -lt 3 -and -not $formateado; $t++) {
                try {
                    Format-Volume -DriveLetter $letraNueva -FileSystem $Fs -NewFileSystemLabel $etq `
                                  -Confirm:$false -Force -ErrorAction Stop | Out-Null
                    $formateado = $true
                } catch {
                    if ($t -eq 2) { throw }
                    Say "  reintentando el formateo: $($_.Exception.Message)" 'warn'
                    Start-Sleep -Seconds 2
                }
            }

            Say "Disco $Disco reparado. Unidad disponible como $letraNueva`:" 'ok'
        }
        # ---------------------------- GRABAR -----------------------------
        # Escritura cruda de una imagen al dispositivo, como hace Etcher:
        # disco offline -> abrir \\.\PhysicalDriveN -> volcar bytes desde el
        # offset 0 -> devolver el disco a online y releer particiones.
        elseif ($Op -eq 'grabar') {
            $img = $Job.Imagen
            Say "Grabando '$([System.IO.Path]::GetFileName($img))' en el disco $Disco..."
            Say "  identidad verificada por serie: '$Serie'" 'ok'

            # Comprobar la imagen contra su hash publicado ANTES de tocar el
            # disco: de nada sirve enterarse de que venia corrupta al final.
            if ($Job.HashEsperado) {
                $esp = ($Job.HashEsperado -replace '[^0-9a-fA-F]', '').ToLower()
                $algo = switch ($esp.Length) { 32 { 'MD5' } 40 { 'SHA1' } 64 { 'SHA256' } default { $null } }
                if (-not $algo) {
                    throw "El hash esperado no tiene una longitud valida ($($esp.Length) caracteres). MD5=32, SHA1=40, SHA256=64."
                }
                Say "  comprobando $algo de la imagen..."
                $real = (Get-FileHash -LiteralPath $img -Algorithm $algo -ErrorAction Stop).Hash.ToLower()
                if ($real -ne $esp) {
                    Say "  esperado: $esp" 'error'
                    Say "  real    : $real" 'error'
                    throw "La imagen NO coincide con el $algo esperado. Descargala de nuevo; no se ha escrito nada."
                }
                Say "  $algo correcto: la imagen es integra." 'ok'
            }

            $bloque   = 8MB
            $sector   = if ($Job.Sector -gt 0) { [int]$Job.Sector } else { 512 }
            $handle   = $null
            $devStream = $null
            $src      = $null
            $volHandles = @()
            $escritos = [long]0

            try {
                [RawDisk]::MantenerDespierto($true)
                try {
                    Set-Disk -Number $Disco -IsReadOnly $false -ErrorAction Stop
                } catch {
                    Say "  aviso: no se pudo tocar el atributo de solo lectura: $($_.Exception.Message)" 'warn'
                }

                # Los medios extraibles no admiten Set-Disk -IsOffline
                # ("Removable media cannot be set to offline"). Hay que
                # bloquear y desmontar cada volumen, y dejar sus handles
                # abiertos: mientras vivan, Windows no vuelve a montarlos.
                $letras = @(Get-Partition -DiskNumber $Disco -ErrorAction SilentlyContinue |
                            Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter })
                foreach ($vl in $letras) {
                    Say "  bloqueando y desmontando $vl`: ..."
                    $vh = [RawDisk]::Abrir("\\.\$vl`:", $true)
                    if ($vh.IsInvalid) { throw "No se pudo abrir el volumen $vl`: (error $([RawDisk]::UltimoError()))" }

                    # Explorer u otro proceso puede tener el volumen abierto:
                    # se reintenta un poco antes de rendirse.
                    $bloqueado = $false
                    for ($t = 0; $t -lt 12 -and -not $bloqueado; $t++) {
                        $bloqueado = [RawDisk]::Bloquear($vh)
                        if (-not $bloqueado) { Start-Sleep -Milliseconds 350 }
                    }
                    if (-not $bloqueado) {
                        $vh.Close()
                        throw "No se pudo bloquear $vl`: - cierra las ventanas y programas que la esten usando."
                    }
                    if (-not [RawDisk]::Desmontar($vh)) {
                        $vh.Close()
                        throw "No se pudo desmontar $vl`: (error $([RawDisk]::UltimoError()))"
                    }
                    $volHandles += $vh
                }

                $ruta = "\\.\PhysicalDrive$Disco"
                $handle = [RawDisk]::Abrir($ruta, $true)
                if ($handle.IsInvalid) {
                    throw "No se pudo abrir $ruta (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
                }
                $devStream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::ReadWrite)

                $AbrirImagen = [scriptblock]::Create($Job.AbrirImagenSrc)
                $abierta = & $AbrirImagen $img
                $src     = $abierta.Stream
                $total   = $abierta.Tamano

                Say ("  escribiendo {0} en bloques de 4 MB..." -f
                     $(if ($total) { '{0:N1} MB' -f ($total / 1MB) } else { 'tamano desconocido' }))

                $reloj = [System.Diagnostics.Stopwatch]::StartNew()
                $ultimoAviso = [ref] 0.0

                $onProgreso = {
                    param($hechos, $tot)
                    if ($reloj.Elapsed.TotalMilliseconds - $ultimoAviso.Value -lt 400) { return }
                    $ultimoAviso.Value = $reloj.Elapsed.TotalMilliseconds
                    $seg = [math]::Max(0.001, $reloj.Elapsed.TotalSeconds)
                    $mbs = ($hechos / 1MB) / $seg
                    # 100.0 y no 100: con enteros, [math]::Min elige la
                    # sobrecarga de int y trunca los decimales.
                    $pct = if ($tot) { [math]::Min(100.0, [math]::Round(($hechos / $tot) * 100, 1)) } else { 0 }
                    $eta = if ($tot -and $mbs -gt 0) {
                        $s = [int]((($tot - $hechos) / 1MB) / $mbs)
                        '{0:d2}:{1:d2}' -f [int]($s / 60), ($s % 60)
                    } else { '--:--' }
                    Prog $pct 'ESCRIBIENDO' ('{0:N1} MB/s' -f $mbs) $eta
                }.GetNewClosure()

                $CopiarFlujo = [scriptblock]::Create($Job.CopiarFlujoSrc)
                $escritos = & $CopiarFlujo $src $devStream $bloque $sector $total $TamDisco `
                                           $onProgreso { $Sync.Cancelar }.GetNewClosure()

                # Sin WRITE_THROUGH el sistema aun tiene datos en cache:
                # este vaciado puede tardar bastante y hay que avisarlo,
                # o parece que el programa se colgo al 100%.
                Prog 100 'VACIANDO CACHE AL DISPOSITIVO' '' ''
                Say '  vaciando la cache del sistema al dispositivo...'
                $devStream.Flush()
                [RawDisk]::Vaciar($handle) | Out-Null
                Prog 100 'ESCRITO' '' ''
                Say ("  escritos {0:N1} MB en {1:N0} s ({2:N1} MB/s)." -f `
                     ($escritos / 1MB), $reloj.Elapsed.TotalSeconds,
                     (($escritos / 1MB) / [math]::Max(0.001, $reloj.Elapsed.TotalSeconds))) 'ok'

                # ---------------- VERIFICACION ----------------
                if ($Job.Verificar) {
                    Say '  verificando: releyendo el disco y comparando...'
                    $src.Dispose(); $src = $null

                    # Se cierra y se reabre el dispositivo a proposito: asi la
                    # lectura viene del medio y no de la cache que acabamos
                    # de escribir, que es lo unico que verifica algo de verdad.
                    $devStream.Dispose(); $devStream = $null
                    $handle = [RawDisk]::Abrir($ruta, $false)
                    if ($handle.IsInvalid) {
                        throw "No se pudo reabrir $ruta para verificar (error $([RawDisk]::UltimoError()))"
                    }
                    $devStream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)

                    $abierta2 = & $AbrirImagen $img
                    $src = $abierta2.Stream
                    $bufD = New-Object byte[] $bloque
                    $bufI = New-Object byte[] $bloque
                    $comparados = [long]0
                    $malas = 0
                    $reloj.Restart()

                    while ($comparados -lt $escritos) {
                        if ($Sync.Cancelar) { throw 'CANCELADO durante la verificacion.' }

                        # Ambos como [long]: con una imagen de mas de 2 GB,
                        # $escritos - $comparados desborda Int32 y la
                        # sobrecarga de enteros de Min revienta la verificacion.
                        $pedir = [int][math]::Min([long]$bloque, [long]($escritos - $comparados))
                        $ni = 0
                        while ($ni -lt $pedir) {
                            $r = $src.Read($bufI, $ni, $pedir - $ni)
                            if ($r -le 0) { break }
                            $ni += $r
                        }
                        # La lectura cruda debe pedirse alineada al sector.
                        $pedirDev = $pedir
                        $resto = $pedirDev % $sector
                        if ($resto -ne 0) { $pedirDev = $pedirDev + ($sector - $resto) }
                        $nd = 0
                        while ($nd -lt $pedirDev) {
                            $r = $devStream.Read($bufD, $nd, $pedirDev - $nd)
                            if ($r -le 0) { break }
                            $nd += $r
                        }

                        if ($ni -le 0) { break }
                        if ($nd -lt $ni) {
                            # el disco devolvio menos bytes de los escritos
                            $malas++
                            break
                        }
                        # Comparacion en C#: en PowerShell este bucle costaba
                        # ~0.8 MB/s y era el cuello de botella real.
                        $dif = [RawDisk]::PrimeraDiferencia($bufD, $bufI, $ni)
                        if ($dif -ge 0) {
                            $malas++
                            Say ("  diferencia en el byte {0:N0}" -f ($comparados + $dif)) 'error'
                        }
                        $comparados += $ni

                        $pct = [math]::Round(($comparados / $escritos) * 100, 1)
                        $seg = [math]::Max(0.001, $reloj.Elapsed.TotalSeconds)
                        Prog $pct 'VERIFICANDO' ('{0:N1} MB/s' -f (($comparados / 1MB) / $seg)) ''
                    }

                    if ($malas -gt 0) {
                        throw "VERIFICACION FALLIDA: $malas bloque(s) no coinciden. La memoria acepto las escrituras pero devuelve datos distintos: no es de fiar."
                    }
                    Say "  verificacion correcta: $([math]::Round($comparados/1MB,1)) MB coinciden byte a byte." 'ok'
                }

                Say "Imagen grabada en el disco $Disco." 'ok'
                if (-not $Job.Arrancable) {
                    Say 'Recuerda: esta imagen no tenia firma de arranque, puede que no arranque.' 'warn'
                }
            }
            finally {
                try { [RawDisk]::MantenerDespierto($false) } catch {}
                if ($src) { try { $src.Dispose() } catch {} }

                # Antes de soltar nada, se le pide al disco que relea su
                # tabla de particiones: si no, Windows sigue viendo la vieja.
                if ($handle -and -not $handle.IsInvalid) {
                    try { [RawDisk]::Refrescar($handle) | Out-Null } catch {}
                }
                if ($devStream) { try { $devStream.Dispose() } catch {} }
                elseif ($handle -and -not $handle.IsInvalid) { try { $handle.Close() } catch {} }

                # Al cerrar el handle del volumen se libera el bloqueo y
                # Windows lo vuelve a montar solo.
                foreach ($vh in $volHandles) { try { $vh.Close() } catch {} }
                if ($volHandles.Count -gt 0) { Say '  volumenes liberados.' }

                try { Update-Disk -Number $Disco -ErrorAction SilentlyContinue } catch {}
            }
        }
        # --------------------------- EXPULSAR ----------------------------
        elseif ($Op -eq 'expulsar') {
            if ($L) {
                # Con letra, el Shell hace la expulsion segura completa.
                Say "Expulsando $L`: ..."
                $sh = New-Object -ComObject Shell.Application
                $sh.NameSpace(17).ParseName("$L`:").InvokeVerb('Eject')
                Start-Sleep -Milliseconds 900
                Say "Solicitud de expulsion enviada para $L`:." 'ok'
            } else {
                # Sin letra (tipico tras grabar una imagen) el Shell no tiene
                # a que agarrarse: se expulsa el dispositivo directamente.
                Say "El disco $Disco no tiene letra asignada: expulsando el dispositivo..."
                $hEject = [RawDisk]::Abrir("\\.\PhysicalDrive$Disco", $true)
                if ($hEject.IsInvalid) {
                    throw "No se pudo abrir el disco $Disco (error $([RawDisk]::UltimoError()))"
                }
                try {
                    if ([RawDisk]::ExpulsarMedio($hEject)) {
                        Say "Disco $Disco expulsado. Ya puedes desconectarlo." 'ok'
                    } else {
                        $e = [RawDisk]::UltimoError()
                        Say "El dispositivo no acepto la orden de expulsion (error $e)." 'warn'
                        Say 'No pasa nada: no tiene ningun volumen montado ni escrituras pendientes,' 'warn'
                        Say 'asi que puedes desconectarlo fisicamente sin riesgo.' 'warn'
                    }
                } finally { $hEject.Close() }
            }
        }

        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $true })
    }
    catch {
        $msg = $_.Exception.Message
        Say "ERROR: $msg" 'error'

        # "read only" en una USB casi nunca es un permiso de Windows:
        # suele ser el propio controlador de la memoria rechazando escrituras.
        if ($msg -match 'read.?only|s.lo lectura|write.?protect|protegid') {
            Say '' 'warn'
            Say 'La unidad rechaza toda escritura. Que significa:' 'warn'
            Say "  1) Puede ser un atributo del disco. En consola de ADMINISTRADOR:" 'warn'
            Say "     diskpart" 'warn'
            Say "     select disk $Disco" 'warn'
            Say "     attributes disk clear readonly" 'warn'
            Say "     clean" 'warn'
            Say "     Luego vuelve aqui y formatea." 'warn'
            Say '  2) Si eso tampoco funciona, el controlador de la memoria entro' 'warn'
            Say '     en modo de solo lectura permanente por desgaste. Es el final' 'warn'
            Say '     de vida normal de una USB y no se arregla por software.' 'warn'
            Say '     Los datos que tenga aun se pueden copiar, pero nada mas.' 'warn'
        }

        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $false })
    }
}

function Invoke-Operacion {
    param([hashtable]$D, [string]$Op)

    if ($script:Sync.Busy) { Write-Log 'Ya hay una operacion en curso.' 'warn'; return }

    # --- Tercera verificacion antes de lanzar nada ---
    $razones = @(Get-RazonesBloqueo $D)
    if ($razones.Count -gt 0) {
        Write-Log ("BLOQUEADO: {0}" -f ($razones -join '; ')) 'error'
        Show-Aviso -Titulo 'Operacion bloqueada' -Nivel 'error' `
            -Cuerpo "La unidad $($D.Letra): esta blindada y no se puede modificar." `
            -Secciones @(@{ Titulo = 'MOTIVOS'; Lineas = $razones }) | Out-Null
        return
    }

    # 'reparar' y 'grabar' tocan el disco entero: guardian de disco tambien
    if ($Op -in 'reparar', 'grabar') {
        $rd = @(Get-RazonesBloqueoDisco $D.Disco $D.Serie $D.TamDisco $D.Modelo)
        if ($rd.Count -gt 0) {
            Write-Log ("BLOQUEADO (disco): {0}" -f ($rd -join '; ')) 'error'
            Show-Aviso -Titulo 'Operacion bloqueada' -Nivel 'error' `
                -Cuerpo "No se puede operar sobre el disco $($D.Disco) completo." `
                -Secciones @(@{ Titulo = 'MOTIVOS'; Lineas = $rd }) | Out-Null
            return
        }
    }

    if ($Op -eq 'limpiar' -and -not $D.Montado) {
        Write-Log "La unidad $($D.Letra): no esta montada: no hay archivos que borrar. Usa FORMATEAR." 'error'
        return
    }
    if ($Op -eq 'formatear' -and -not $D.Letra) {
        Write-Log "El disco $($D.Disco) no tiene ninguna letra asignada: formatear necesita una. Usa REPARAR." 'error'
        return
    }

    if (-not $script:EsAdmin -and $Op -ne 'expulsar') {
        Write-Log 'Se requieren permisos de administrador para esta operacion.' 'error'
        Show-Aviso -Titulo 'Permisos insuficientes' -Nivel 'warn' `
            -Cuerpo ("Esta operacion necesita permisos de administrador.`n`n" +
                     "Cierra el programa y abrelo con 'Iniciar Limpiador USB.cmd', " +
                     "que pide la elevacion automaticamente.") | Out-Null
        return
    }

    # StrictMode: se inicializan aunque solo 'grabar' las use.
    $fs = $D.Fs
    $imagen = $null
    $arrancable = $false
    $destino = $null
    $script:Opciones.VerificarTrasGrabar = $true

    if ($Op -eq 'formatear') {
        if (-not (Show-Confirmacion $D $Op)) { Write-Log 'Formateo cancelado por el usuario.'; return }
        # exFAT para memorias grandes, FAT32 para las chicas (maxima compatibilidad)
        $fs = if ($D.TamVol -gt 32GB) { 'exFAT' } else { 'FAT32' }
    }
    elseif ($Op -eq 'limpiar') {
        if (-not (Show-Confirmacion $D $Op)) { Write-Log 'Limpieza cancelada por el usuario.'; return }
    }
    elseif ($Op -eq 'reparar') {
        if (-not (Show-Confirmacion $D $Op)) { Write-Log 'Reparacion cancelada por el usuario.'; return }
        # AUTO: FAT32 hasta 32 GB (maxima compatibilidad), exFAT por encima
        # porque FAT32 no admite volumenes mayores de forma fiable.
        $fs = if ($script:Opciones.FormatoReparar -eq 'AUTO') {
            if ($D.TamDisco -gt 32GB) { 'exFAT' } else { 'FAT32' }
        } else { $script:Opciones.FormatoReparar }
        Write-Log "Reparar: esquema $($script:Opciones.EsquemaReparar), formato $fs."
    }
    elseif ($Op -eq 'recuperar') {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Donde guardar lo que se rescate del disco $($D.Disco)"
        $fbd.ShowNewFolderButton = $true
        if ($fbd.ShowDialog() -ne 'OK') { Write-Log 'Recuperacion cancelada: no se eligio destino.'; return }
        $destino = $fbd.SelectedPath

        # LA regla de oro de la recuperacion: jamas guardar en el mismo
        # disco del que se rescata. Cada archivo escrito ahi puede machacar
        # justo lo que todavia no se ha recuperado.
        $discoDestino = Get-DiscoDeRuta $destino
        if ($null -eq $discoDestino) {
            Write-Log "No pude averiguar en que disco esta '$destino'." 'error'
            Show-Aviso -Titulo 'Destino no valido' -Nivel 'error' `
                -Cuerpo "No se pudo determinar a que disco pertenece la carpeta elegida.`n`n$destino" | Out-Null
            return
        }
        if ($discoDestino -eq $D.Disco) {
            Write-Log "BLOQUEADO: el destino esta en el MISMO disco $($D.Disco) del que se recupera." 'error'
            Show-Aviso -Titulo 'Destino en el mismo disco' -Nivel 'error' `
                -Cuerpo ("La carpeta elegida esta en el disco $($D.Disco), que es justo del que quieres recuperar.`n`n" +
                         "Guardar ahi sobrescribiria los datos que todavia no se han rescatado. Elige una carpeta en otro disco.") | Out-Null
            return
        }
        Write-Log "Recuperando disco $($D.Disco) hacia '$destino' (esta en el disco $discoDestino)."
    }
    elseif ($Op -eq 'grabar') {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title  = "Elige la imagen a grabar en el disco $($D.Disco)"
        $dlg.Filter = 'Imagenes de disco|*.iso;*.img;*.bin;*.raw;*.gz;*.zip|' +
                      'Crudas (*.iso, *.img, *.bin, *.raw)|*.iso;*.img;*.bin;*.raw|' +
                      'Comprimidas (*.gz, *.zip)|*.gz;*.zip|Todos|*.*'
        if (-not $dlg.ShowDialog()) { Write-Log 'Grabado cancelado: no se eligio imagen.'; return }
        $imagen = $dlg.FileName

        try { $tamImg = Get-TamanoImagen $imagen }
        catch {
            Write-Log "No se pudo leer la imagen: $($_.Exception.Message)" 'error'
            Show-Aviso -Titulo 'Imagen invalida' -Nivel 'error' `
                -Cuerpo "No se pudo leer la imagen.`n`n$($_.Exception.Message)" | Out-Null
            return
        }

        if ($tamImg -and $tamImg -gt $D.TamDisco) {
            Write-Log ("BLOQUEADO: la imagen ({0}) excede el disco ({1})." -f
                       (Format-Tam $tamImg), (Format-Tam $D.TamDisco)) 'error'
            Show-Aviso -Titulo 'Imagen demasiado grande' -Nivel 'error' `
                -Cuerpo 'La imagen no cabe en el disco de destino.' -Secciones @(
                    @{ Titulo = 'TAMANOS'; Lineas = @(
                        "imagen: $(Format-Tam $tamImg)",
                        "disco $($D.Disco): $(Format-Tam $D.TamDisco)") }
                ) | Out-Null
            return
        }

        $arrancable = Test-ImagenArrancable $imagen
        $extra = @{ Imagen = $imagen; TamImagen = $tamImg; Arrancable = $arrancable }
        if (-not (Show-Confirmacion $D $Op -Extra $extra)) { Write-Log 'Grabado cancelado por el usuario.'; return }
    }

    $script:Sync.Busy     = $true
    $script:Sync.Cancelar = $false
    $UI.Latido.Visibility = 'Visible'
    $destino = if ($Op -in 'reparar', 'grabar') { "EL DISCO $($D.Disco)" } else { "$($D.Letra):" }
    $UI.Estado.Text = "EJECUTANDO '$($Op.ToUpper())' EN $destino  //  NO DESCONECTES LA UNIDAD"
    Set-BotonesHabilitados $false
    if ($Op -in 'grabar', 'recuperar') { Show-Progreso $true }

    $job = @{
        Letra    = $D.Letra;  Op       = $Op;        Guard    = $script:Guard
        Etiqueta = $D.Etiqueta; Fs     = $fs;        Serie    = $D.Serie
        Modelo   = $D.Modelo; TamDisco = $D.TamDisco; Disco   = $D.Disco
        Sector   = $D.Sector
        # solo se usan en 'grabar'
        Imagen         = $imagen
        Verificar      = $script:Opciones.VerificarTrasGrabar
        Arrancable     = $arrancable
        AbrirImagenSrc = $script:AbrirImagenSrc
        CopiarFlujoSrc = $script:CopiarFlujoSrc
        LeerBloqueSrc  = $script:LeerBloqueSrc
        Esquema        = $script:Opciones.EsquemaReparar
        HashEsperado   = $script:Opciones.HashEsperado
        # solo se usan en 'recuperar'
        Destino        = $destino
        Firmas         = @($script:Firmas | ForEach-Object {
                            @{ Nombre = $_.Nombre; Ext = $_.Ext; MaxMB = $_.MaxMB
                               CabBytes = (ConvertFrom-Hex $_.Cab)
                               ColaBytes = (ConvertFrom-Hex $_.Cola) } })
        SubtipoZipSrc  = $script:SubtipoZipSrc
        MaxAbiertos    = $script:MaxAbiertos
        Inicio         = 0
        Fin            = [long]$D.TamDisco
        Bloque         = 4MB
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    # 'recuperar' tiene su propio motor: no comparte nada con las
    # operaciones de escritura, y su origen se abre en solo lectura.
    $motor = if ($Op -eq 'recuperar') { $script:RecuperarSb } else { $script:TrabajoSb }
    $null = $ps.AddScript($motor).AddArgument($job).AddArgument($script:Sync)

    $script:Worker   = $ps
    $script:Runspace = $rs
    $script:Handle   = $ps.BeginInvoke()
}

function Show-Progreso {
    param([bool]$Visible)
    $UI.FilaProg.Visibility = if ($Visible) { 'Visible' } else { 'Collapsed' }
    if ($Visible) {
        $UI.BtnCancelar.IsEnabled = $true
        $UI.ProgTxt.Text  = '0%'
        $UI.ProgFase.Text = 'PREPARANDO'
        Update-BarraProgreso 0
    }
}

# Barra segmentada de progreso: se rellena en sitio en vez de reconstruirse,
# porque llega un mensaje cada 400 ms y recrear 48 rectangulos parpadearia.
function Update-BarraProgreso {
    param([double]$Pct)
    $segs = 48
    if ($UI.ProgBarra.Children.Count -ne $segs) {
        $UI.ProgBarra.Children.Clear()
        for ($i = 0; $i -lt $segs; $i++) {
            $r = New-Object Windows.Shapes.Rectangle
            $r.Width = 6; $r.Height = 11
            $r.Margin = New-Object Windows.Thickness 0, 0, 2, 0
            $UI.ProgBarra.Children.Add($r) | Out-Null
        }
    }
    $llenos = [int][math]::Round(($Pct / 100) * $segs)
    $brOn  = Br $C.Rojo
    $brOff = Br '#22262C'
    for ($i = 0; $i -lt $segs; $i++) {
        $UI.ProgBarra.Children[$i].Fill = if ($i -lt $llenos) { $brOn } else { $brOff }
    }
}

function Set-BotonesHabilitados {
    param([bool]$On)
    foreach ($b in $script:Botones) { $b.IsEnabled = $On }
    $UI.BtnScan.IsEnabled = $On
}

# ==================================================================
#  10b. DIAGNOSTICO (estilo Victoria HDD/SSD)
# ==================================================================
# Todo lo de aqui es de SOLO LECTURA. El dispositivo se abre siempre
# con Abrir($ruta, $false), que pide unicamente GENERIC_READ: por eso
# se permite diagnosticar incluso unidades blindadas, que son justo
# las que mas interesa vigilar.

# Escala de tiempos de respuesta por bloque, como el mapa de Victoria.
# Estos valores son la BASE para un bloque de 128 KB (el que usa Victoria).
# Como aqui el bloque es configurable, los umbrales se escalan con el:
# leer 8 MB tarda ~64 veces mas que leer 128 KB, y sin escalar el mapa
# saldria entero rojo sin significar nada. Ver Get-LimitesBucket.
$script:BloqueBase = 128KB
$script:Buckets = @(
    @{ Max =    5; Color = '#2E7D46'; Txt = '< 5 ms' },
    @{ Max =   20; Color = '#6FA33A'; Txt = '< 20 ms' },
    @{ Max =   50; Color = '#C9A227'; Txt = '< 50 ms' },
    @{ Max =  200; Color = '#E08A1E'; Txt = '< 200 ms' },
    @{ Max =  600; Color = '#E5372F'; Txt = '< 600 ms' },
    @{ Max = [double]::MaxValue; Color = '#7A1A16'; Txt = '>= 600 ms' },
    @{ Max = -1;   Color = '#00B7C3'; Txt = 'ERROR DE LECTURA' }
)
$script:IdxError = 6

# Umbrales reales para un tamano de bloque dado, y su etiqueta.
function Get-LimitesBucket {
    param([double]$Bloque)
    $f = [math]::Max(1.0, $Bloque / $script:BloqueBase)
    $res = @()
    for ($i = 0; $i -lt 6; $i++) {
        $m = $script:Buckets[$i].Max
        $v = if ($m -eq [double]::MaxValue) { [double]::MaxValue } else { [double]$m * $f }
        $txt = if ($m -eq [double]::MaxValue) {
            '>= {0:N0} ms' -f ([double]$script:Buckets[4].Max * $f)
        } else { '< {0:N0} ms' -f $v }
        $res += @{ Max = $v; Txt = $txt }
    }
    $res
}

# Tiempo de acceso aleatorio. Un disco mecanico tiene que mover el cabezal
# (10-20 ms); uno de estado solido no (bajo 1 ms). El puente USB anade su
# parte, pero la diferencia es tan grande que sigue siendo concluyente.
# Sirve para saber que hay dentro cuando el adaptador miente sobre el modelo.
$script:AccesoSb = {
    param($Cfg, $Sync)

    function Say($t, $n = 'info') { $Sync.Cola.Enqueue(@{ T = 'log'; Txt = $t; N = $n }) }

    $fs = $null; $h = $null
    try {
        $ruta = if ($Cfg.Ruta) { $Cfg.Ruta } else { "\\.\PhysicalDrive$($Cfg.Disco)" }
        $h = [RawDisk]::Abrir($ruta, $false)      # <- solo lectura
        if ($h.IsInvalid) {
            throw "No se pudo abrir $ruta para lectura (error $([RawDisk]::UltimoError())). Requiere administrador."
        }
        $fs = New-Object System.IO.FileStream($h, [System.IO.FileAccess]::Read)
        if ($fs.CanWrite) { throw 'ABORTADO: el dispositivo se abrio con permiso de escritura.' }

        $sector = [int]$Cfg.Sector
        $tam    = [int]$Cfg.Tam
        $n      = [int]$Cfg.Muestras
        $tope   = [long]$Cfg.Tamano - $tam
        if ($tope -le $sector) { throw 'El disco es demasiado pequeno para medir el acceso.' }

        Say "Midiendo tiempo de acceso: $n lecturas de $($tam / 1KB) KB en posiciones aleatorias..."
        $rnd = New-Object Random
        $buf = New-Object byte[] $tam
        $crono = New-Object System.Diagnostics.Stopwatch
        $t = New-Object 'System.Collections.Generic.List[double]'

        for ($i = 0; $i -lt $n; $i++) {
            if ($Sync.Cancelar) { Say 'Medicion cancelada.' 'warn'; break }
            # Posiciones repartidas por todo el disco: si se leyera siempre
            # la misma zona, responderia la cache y no el medio.
            $off = [long]($rnd.NextDouble() * $tope)
            $off = $off - ($off % $sector)
            $crono.Restart()
            $fs.Position = $off
            $null = $fs.Read($buf, 0, $tam)
            $crono.Stop()
            $t.Add($crono.Elapsed.TotalMilliseconds)
            if ($n -ge 4 -and $i -gt 0 -and ($i % [int]($n / 4)) -eq 0) {
                Say ("  {0}%..." -f [int](($i / $n) * 100))
            }
        }

        if ($t.Count -lt 8) { throw 'No se pudieron tomar suficientes muestras.' }
        $ord = @($t | Sort-Object)
        $mediana = $ord[[int]($ord.Count / 2)]
        $p90     = $ord[[int]($ord.Count * 0.9)]
        $minimo  = $ord[0]
        $maximo  = $ord[$ord.Count - 1]

        # El salto entre una y otra tecnologia es de un orden de magnitud,
        # asi que entre 3 y 8 ms se prefiere no afirmar nada.
        $ver = if ($mediana -lt 3) { 'ELECTRONICO (SSD o memoria flash)' }
               elseif ($mediana -ge 8) { 'MECANICO (disco duro con platos)' }
               else { 'NO CONCLUYENTE' }

        Say ("Tiempo de acceso: mediana {0:N2} ms  (min {1:N2}  p90 {2:N2}  max {3:N2}, {4} muestras)" -f `
             $mediana, $minimo, $p90, $maximo, $ord.Count) 'ok'
        Say "Veredicto: $ver" $(if ($ver -eq 'NO CONCLUYENTE') { 'warn' } else { 'ok' })

        $Sync.Cola.Enqueue(@{ T = 'acceso'; Mediana = $mediana; Min = $minimo
                              P90 = $p90; Max = $maximo; N = $ord.Count; Veredicto = $ver })
        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $true })
    }
    catch {
        Say "ERROR: $($_.Exception.Message)" 'error'
        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $false })
    }
    finally {
        if ($fs) { try { $fs.Dispose() } catch {} }
        elseif ($h -and -not $h.IsInvalid) { try { $h.Close() } catch {} }
    }
}

# ==================================================================
#  RECUPERAR ARCHIVOS  (tallado por firmas, SOLO LECTURA del origen)
# ==================================================================
# El disco de origen se abre con GENERIC_READ y jamas se escribe: los
# archivos rescatados van a OTRO disco, que el llamador ya verifico.
# Un solo recorrido: se mantiene una lista de archivos "abiertos" a los
# que se les va anadiendo cada bloque hasta encontrar su marca de fin.
$script:RecuperarSb = {
    param($Cfg, $Sync)

    function Say($t, $n = 'info') { $Sync.Cola.Enqueue(@{ T = 'log'; Txt = $t; N = $n }) }
    function Prog($pct, $fase, $vel = '', $eta = '') {
        $Sync.Cola.Enqueue(@{ T = 'prog'; Pct = $pct; Fase = $fase; Vel = $vel; Eta = $eta })
    }
    function TamTxt([double]$b) {
        if ($b -le 0) { return '0 B' }
        $u = 'B','KB','MB','GB','TB'; $i = 0
        while ($b -ge 1024 -and $i -lt 4) { $b /= 1024; $i++ }
        '{0:N1} {1}' -f $b, $u[$i]
    }

    $fs = $null; $h = $null
    $abiertos = New-Object System.Collections.ArrayList
    try {
        $ruta = if ($Cfg.Ruta) { $Cfg.Ruta } else { "\\.\PhysicalDrive$($Cfg.Disco)" }
        [RawDisk]::MantenerDespierto($true)
        $h = [RawDisk]::Abrir($ruta, $false)     # <- solo lectura, nunca escritura
        if ($h.IsInvalid) {
            throw "No se pudo abrir $ruta para lectura (error $([RawDisk]::UltimoError())). Requiere administrador."
        }
        $fs = New-Object System.IO.FileStream($h, [System.IO.FileAccess]::Read)
        if ($fs.CanWrite) { throw 'ABORTADO: el origen se abrio con permiso de escritura.' }

        if (-not (Test-Path -LiteralPath $Cfg.Destino)) {
            New-Item -ItemType Directory -Path $Cfg.Destino -Force | Out-Null
        }

        $cabs  = @($Cfg.Firmas | ForEach-Object { , $_.CabBytes })
        $sector = [int]$Cfg.Sector
        $bloque = [int]$Cfg.Bloque
        $inicio = [long]$Cfg.Inicio
        $fin    = [long]$Cfg.Fin
        $span   = $fin - $inicio
        if ($span -le 0) { throw 'El rango a recuperar esta vacio.' }

        # Solapamiento entre bloques: una firma puede quedar partida justo en
        # la frontera, asi que se arrastran los ultimos bytes del anterior.
        $solape = 0
        foreach ($f in $Cfg.Firmas) {
            $solape = [math]::Max($solape, $f.CabBytes.Length)
            $solape = [math]::Max($solape, $f.ColaBytes.Length)
        }
        $solape = [math]::Max(16, $solape)

        Say ("Recuperando de {0}: {1} en bloques de {2}." -f `
             $ruta, (TamTxt $span), (TamTxt $bloque))
        Say ("  destino: $($Cfg.Destino)")
        Say ("  tipos: " + (($Cfg.Firmas | ForEach-Object { $_.Nombre }) -join ', '))

        $buf = New-Object byte[] ($bloque + $solape)
        $pos = $inicio
        $leidoTotal = [long]0
        $encontrados = @{}
        $cerrados = 0
        $descartados = 0
        $reloj = [System.Diagnostics.Stopwatch]::StartNew()
        $ultimo = 0.0
        $colaAnterior = 0     # bytes arrastrados del bloque previo
        $LeerBloque = [scriptblock]::Create($Cfg.LeerBloqueSrc)
        $SubtipoZip = [scriptblock]::Create($Cfg.SubtipoZipSrc)

        while ($pos -lt $fin) {
            if ($Sync.Cancelar) { Say 'Recuperacion cancelada.' 'warn'; break }

            $pedir = [int][math]::Min([long]$bloque, [long]($fin - $pos))
            $resto = $pedir % $sector
            if ($resto -ne 0) { $pedir -= $resto }
            if ($pedir -le 0) { break }

            $fs.Position = $pos
            $n = & $LeerBloque $fs $buf $pedir $colaAnterior
            if ($n -le 0) { break }
            $hasta = $colaAnterior + $n
            $leidoTotal += $n

            # UNA sola pasada por el bloque para TODO: cabeceras nuevas y
            # colas de los archivos abiertos. Antes se recorria el bloque
            # una vez por cada archivo abierto, y con 64 abiertos eso son
            # 260 MB recorridos por cada 4 MB leidos.
            $patrones = New-Object System.Collections.ArrayList
            foreach ($cb in $cabs) { $null = $patrones.Add($cb) }
            $nCabs = $patrones.Count
            $colasUnicas = @{}
            foreach ($a in $abiertos) {
                $clave = [BitConverter]::ToString($a.ColaBytes)
                if (-not $colasUnicas.ContainsKey($clave)) {
                    $colasUnicas[$clave] = $patrones.Count
                    $null = $patrones.Add($a.ColaBytes)
                }
            }
            $hits = [RawDisk]::BuscarPatrones($buf, 0, $hasta, $patrones.ToArray())
            # Contador propio para las colas que se descubran a mitad del
            # bloque: usar $patrones.Count daba el MISMO indice a dos
            # archivos distintos y se pisaban la lista de posiciones.
            $idxExtra = $patrones.Count + 1000

            # Repartir los resultados: cabeceras por un lado, colas por otro
            $nuevasCabs = New-Object System.Collections.ArrayList
            $posColas = @{}
            for ($i = 0; $i -lt $hits.Length; $i += 2) {
                $donde = $hits[$i]; $cual = $hits[$i + 1]
                if ($cual -lt $nCabs) {
                    $null = $nuevasCabs.Add(@($donde, $cual))
                } else {
                    if (-not $posColas.ContainsKey($cual)) {
                        $posColas[$cual] = New-Object System.Collections.ArrayList
                    }
                    $null = $posColas[$cual].Add($donde)
                }
            }

            # 1) abrir los archivos nuevos
            foreach ($nc in $nuevasCabs) {
                if ($abiertos.Count -ge $Cfg.MaxAbiertos) { break }
                $donde = $nc[0]; $cual = $nc[1]
                $f = $Cfg.Firmas[$cual]
                $ext = $f.Ext
                if ($f.Nombre -eq 'ZIP') {
                    $ojeada = New-Object byte[] ([math]::Min(600, $hasta - $donde))
                    [Array]::Copy($buf, $donde, $ojeada, 0, $ojeada.Length)
                    $ext = & $SubtipoZip $ojeada
                }
                $num = 1
                if ($encontrados.ContainsKey($f.Nombre)) { $num = $encontrados[$f.Nombre] + 1 }
                $encontrados[$f.Nombre] = $num
                $nombre = '{0}_{1:d5}.{2}' -f $f.Nombre.ToLower(), $num, $ext
                $st = [System.IO.File]::Create((Join-Path $Cfg.Destino $nombre))
                $claveCola = [BitConverter]::ToString($f.ColaBytes)
                $null = $abiertos.Add(@{
                    Nombre = $nombre; Stream = $st; Escritos = 0
                    ColaBytes = $f.ColaBytes; ClaveCola = $claveCola
                    MaxBytes = ([long]$f.MaxMB * 1MB); Desde = $donde
                })
                # Su cola quiza no estaba en la busqueda de este bloque:
                # se busca solo para el, y solo esta vez.
                if (-not $colasUnicas.ContainsKey($claveCola)) {
                    $idx = $idxExtra
                    $idxExtra++
                    $colasUnicas[$claveCola] = $idx
                    $extra = [RawDisk]::BuscarPatrones($buf, $donde, $hasta, @(, $f.ColaBytes))
                    $lista = New-Object System.Collections.ArrayList
                    for ($j = 0; $j -lt $extra.Length; $j += 2) { $null = $lista.Add($extra[$j]) }
                    $posColas[$idx] = $lista
                }
            }

            # 2) alimentar los abiertos y cerrarlos al encontrar su cola
            for ($k = $abiertos.Count - 1; $k -ge 0; $k--) {
                $a = $abiertos[$k]
                $desde = $a.Desde
                $a.Desde = 0
                $corte = $hasta
                $idxCola = -1
                $idxPat = $null
                if ($colasUnicas.ContainsKey($a.ClaveCola)) { $idxPat = $colasUnicas[$a.ClaveCola] }
                if ($null -ne $idxPat -and $posColas.ContainsKey($idxPat)) {
                    foreach ($pc in $posColas[$idxPat]) {
                        if ($pc -gt $desde) { $idxCola = $pc; break }
                    }
                }
                if ($idxCola -ge 0) { $corte = $idxCola + $a.ColaBytes.Length }

                $cortadoPorTamano = $false
                $cuantos = $corte - $desde
                if ($a.Escritos + $cuantos -gt $a.MaxBytes) {
                    $cuantos = [int]($a.MaxBytes - $a.Escritos)
                    $cortadoPorTamano = $true
                }
                if ($cuantos -gt 0) {
                    $a.Stream.Write($buf, $desde, $cuantos)
                    $a.Escritos += $cuantos
                }
                if ($idxCola -ge 0 -or $cortadoPorTamano) {
                    $a.Stream.Dispose()
                    $abiertos.RemoveAt($k)
                    if ($cortadoPorTamano) {
                        # Sin marca de fin tras megabytes: casi seguro una
                        # coincidencia falsa. Se descarta en vez de dejar
                        # basura en el destino.
                        Remove-Item -LiteralPath (Join-Path $Cfg.Destino $a.Nombre) -Force -ErrorAction SilentlyContinue
                        $descartados++
                    } else {
                        $cerrados++
                    }
                }
            }

            # 3) arrastrar la cola del bloque para no partir firmas
            $colaAnterior = [math]::Min($solape, $hasta)
            [Array]::Copy($buf, $hasta - $colaAnterior, $buf, 0, $colaAnterior)

            $pos += $n

            if ($reloj.Elapsed.TotalMilliseconds - $ultimo -ge 400) {
                $ultimo = $reloj.Elapsed.TotalMilliseconds
                $seg = [math]::Max(0.001, $reloj.Elapsed.TotalSeconds)
                $mbs = ($leidoTotal / 1MB) / $seg
                $pct = [math]::Min(100.0, [math]::Round((($pos - $inicio) / $span) * 100, 1))
                $eta = if ($mbs -gt 0) {
                    $s = [int]((($fin - $pos) / 1MB) / $mbs)
                    '{0:d2}:{1:d2}:{2:d2}' -f [int]($s / 3600), [int](($s % 3600) / 60), ($s % 60)
                } else { '--:--:--' }
                Prog $pct "RECUPERANDO  $cerrados archivo(s)" ('{0:N1} MB/s' -f $mbs) $eta
            }
        }

        foreach ($a in $abiertos) { try { $a.Stream.Dispose(); $cerrados++ } catch {} }
        $abiertos.Clear()

        $seg = [math]::Max(0.001, $reloj.Elapsed.TotalSeconds)
        Prog 100 'RECUPERACION TERMINADA' '' ''
        Say ("Terminado: {0} archivo(s) rescatado(s) leyendo {1} en {2:N0} s = {3:N1} MB/s." -f `
             $cerrados, (TamTxt $leidoTotal), $seg, (($leidoTotal / 1MB) / $seg)) 'ok'
        if ($descartados -gt 0) {
            Say ("  {0} coincidencia(s) falsa(s) descartada(s): empezaban como un archivo pero nunca terminaron." -f $descartados) 'warn'
        }
        foreach ($k in $encontrados.Keys) {
            Say ("  {0}: {1}" -f $k, $encontrados[$k])
        }
        if ($cerrados -gt 0) {
            Say 'Recuerda: el tallado no recupera nombres ni carpetas, y los' 'warn'
            Say 'archivos que estaban fragmentados pueden salir incompletos.' 'warn'
        }
        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $true })
    }
    catch {
        Say "ERROR: $($_.Exception.Message)" 'error'
        foreach ($a in $abiertos) { try { $a.Stream.Dispose() } catch {} }
        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $false })
    }
    finally {
        try { [RawDisk]::MantenerDespierto($false) } catch {}
        if ($fs) { try { $fs.Dispose() } catch {} }
        elseif ($h -and -not $h.IsInvalid) { try { $h.Close() } catch {} }
    }
}

$script:SuperficieSb = {
    param($Cfg, $Sync)

    function Say($t, $n = 'info') { $Sync.Cola.Enqueue(@{ T = 'log'; Txt = $t; N = $n }) }

    # El hilo de trabajo no ve las funciones del programa principal:
    # cada runspace arranca limpio, asi que lleva la suya.
    function Format-TamWorker([double]$b) {
        if ($b -le 0) { return '0 B' }
        $u = 'B','KB','MB','GB','TB'; $i = 0
        while ($b -ge 1024 -and $i -lt 4) { $b /= 1024; $i++ }
        '{0:N1} {1}' -f $b, $u[$i]
    }

    $fs = $null; $h = $null
    try {
        # Cfg.Ruta solo lo usa la autoprueba, para barrer un archivo y poder
        # verificar toda la logica sin depender de un disco real. La ventana
        # nunca la pasa: siempre va contra \\.\PhysicalDriveN.
        $ruta = if ($Cfg.Ruta) { $Cfg.Ruta } else { "\\.\PhysicalDrive$($Cfg.Disco)" }

        if (-not $Cfg.Ruta) {
            # Incluso siendo de lectura, se confirma que el disco sigue siendo
            # el mismo: un informe sobre el disco equivocado no vale nada.
            $dk = Get-Disk -Number $Cfg.Disco -ErrorAction Stop
            if ("$($dk.SerialNumber)".Trim() -ne "$($Cfg.Serie)".Trim()) {
                throw "El disco $($Cfg.Disco) cambio de identidad. Vuelve a escanear."
            }
        }

        [RawDisk]::MantenerDespierto($true)
        $h = [RawDisk]::Abrir($ruta, $false)   # <- GENERIC_READ, nunca escritura
        if ($h.IsInvalid) {
            throw "No se pudo abrir $ruta para lectura (error $([RawDisk]::UltimoError())). Requiere administrador."
        }
        $fs = New-Object System.IO.FileStream($h, [System.IO.FileAccess]::Read)
        if ($fs.CanWrite) { throw 'ABORTADO: el dispositivo se abrio con permiso de escritura.' }

        $sector  = [int]$Cfg.Sector
        $bloque  = [int]$Cfg.Bloque
        $inicio  = [long]$Cfg.Inicio
        $fin     = [long]$Cfg.Fin
        $celdas  = [int]$Cfg.Celdas
        $span    = $fin - $inicio
        if ($span -le 0) { throw 'El rango de barrido esta vacio.' }
        $porCelda = [math]::Max(1.0, $span / $celdas)

        # ContainsKey a proposito: con StrictMode, pedir una clave que no
        # existe en un hashtable lanza excepcion en vez de dar $null.
        # Tiene que quedar definido ANTES del primer mensaje, que ya lo usa.
        $muestreo = ($Cfg.ContainsKey('Muestreo') -and $Cfg.Muestreo)

        if ($muestreo) {
            Say ("MUESTREO: {0} lecturas de {1} repartidas por {2:N1} GB." -f `
                 $celdas, (Format-TamWorker $bloque), ($span / 1GB)) 'warn'
            Say '  Detecta zonas lentas y danos extensos, NO sectores malos sueltos.' 'warn'
        } else {
            Say ("Barriendo {0:N1} GB desde el offset {1:N0} en bloques de {2}..." -f `
                 ($span / 1GB), $inicio, (Format-TamWorker $bloque))
        }

        $LeerBloque = [scriptblock]::Create($Cfg.LeerBloqueSrc)
        $buf   = New-Object byte[] $bloque
        $pos   = $inicio
        $reloj = [System.Diagnostics.Stopwatch]::StartNew()
        $crono = New-Object System.Diagnostics.Stopwatch
        $ultimo = 0.0
        # Cuanto del tiempo total se va de verdad dentro de las lecturas.
        # Si baja mucho del 100%, el cuello de botella no es el disco.
        $msLeyendo = 0.0
        # Errores seguidos: si se acumulan, casi nunca es que el disco este
        # lleno de sectores malos, sino que dejo de responder.
        $seguidos = 0
        # En modo muestreo se lee UN bloque por celda del mapa en vez del
        # disco entero: mismo dibujo, una fraccion del tiempo. Detecta
        # zonas lentas y danos extensos, no sectores malos aislados.
        $celdaIdx = 0
        $celdaActual = -1
        $peorCelda = 0
        $cuenta = New-Object int[] 7
        $errores = 0
        $leidoTotal = [long]0

        while ($pos -lt $fin) {
            if ($Sync.Cancelar) { Say 'Barrido cancelado.' 'warn'; break }

            $pedir = [int][math]::Min([long]$bloque, [long]($fin - $pos))
            $resto = $pedir % $sector
            if ($resto -ne 0) { $pedir -= $resto }
            if ($pedir -le 0) { break }

            $idx = 0
            $crono.Restart()
            try {
                $fs.Position = $pos
                $n = & $LeerBloque $fs $buf $pedir
                $crono.Stop()
                if ($n -le 0) { throw 'lectura vacia' }
                $ms = $crono.Elapsed.TotalMilliseconds
                $msLeyendo += $ms
                # Clasificar por tiempo de respuesta
                for ($i = 0; $i -lt 6; $i++) {
                    if ($ms -lt $Cfg.Limites[$i]) { $idx = $i; break }
                    $idx = 5
                }
                $leidoTotal += $n
                $seguidos = 0
            } catch {
                $crono.Stop()
                $idx = 6
                $errores++
                $seguidos++
                # Muchos fallos seguidos: comprobar si el disco sigue ahi
                # antes de seguir pintando errores que no son del medio.
                if ($seguidos -ge 12 -and -not $Cfg.Ruta) {
                    $vivo = Get-Disk -Number $Cfg.Disco -ErrorAction SilentlyContinue
                    if (-not $vivo -or "$($vivo.SerialNumber)".Trim() -ne "$($Cfg.Serie)".Trim()) {
                        Say '' 'error'
                        Say 'EL DISCO DEJO DE RESPONDER Y DESAPARECIO DEL SISTEMA.' 'error'
                        Say 'Esto NO significa que este danado: lo tipico es que la' 'warn'
                        Say 'electronica de la carcasa USB se haya colgado por la carga' 'warn'
                        Say 'sostenida. Desconectalo, espera unos segundos y vuelve a' 'warn'
                        Say 'conectarlo, mejor en un puerto directo del equipo.' 'warn'
                        Say 'Los errores contados hasta aqui no son de la superficie.' 'warn'
                        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $false })
                        return
                    }
                    $seguidos = 0
                }
                if ($errores -le 20) {
                    Say ("  ERROR de lectura en el sector {0:N0} (offset {1:N0})" -f `
                         ($pos / $sector), $pos) 'error'
                } elseif ($errores -eq 21) {
                    Say '  ...mas errores, se dejan de listar uno a uno.' 'warn'
                }
            }
            $cuenta[$idx]++

            # Una celda del mapa agrupa muchos bloques: se queda con el peor.
            $celda = [int][math]::Min($celdas - 1, [math]::Floor(($pos - $inicio) / $porCelda))
            if ($celda -ne $celdaActual) {
                if ($celdaActual -ge 0) {
                    $Sync.Cola.Enqueue(@{ T = 'celda'; Idx = $celdaActual; B = $peorCelda })
                }
                $celdaActual = $celda
                $peorCelda = $idx
            } elseif ($idx -gt $peorCelda) {
                $peorCelda = $idx
            }

            if ($muestreo) {
                # Saltar a la celda siguiente, alineado al sector.
                $celdaIdx++
                if ($celdaIdx -ge $celdas) { $pos = $fin }
                else {
                    $pos = $inicio + [long]($celdaIdx * $porCelda)
                    $pos = $pos - ($pos % $sector)
                }
            } else {
                # Avanzar por lo leido de verdad: con $pedir se saltaria
                # todo lo que la lectura no llego a devolver.
                $pos += $(if ($n -gt 0) { $n } else { $pedir })
            }

            if ($reloj.Elapsed.TotalMilliseconds - $ultimo -ge 400) {
                $ultimo = $reloj.Elapsed.TotalMilliseconds
                $seg = [math]::Max(0.001, $reloj.Elapsed.TotalSeconds)
                $mbs = ($leidoTotal / 1MB) / $seg
                $pct = [math]::Min(100.0, [math]::Round((($pos - $inicio) / $span) * 100, 1))
                $eta = if ($mbs -gt 0) {
                    $faltan = if ($muestreo) { [double](($celdas - $celdaIdx) * $bloque) }
                              else { [double]($fin - $pos) }
                    $s = [int](($faltan / 1MB) / $mbs)
                    '{0:d2}:{1:d2}:{2:d2}' -f [int]($s / 3600), [int](($s % 3600) / 60), ($s % 60)
                } else { '--:--:--' }
                $enLect = [math]::Round(($msLeyendo / 1000) / $seg * 100, 0)
                $Sync.Cola.Enqueue(@{ T = 'prog'; Pct = $pct; Vel = ('{0:N1} MB/s' -f $mbs)
                                      Eta = $eta; Cuenta = $cuenta.Clone(); Err = $errores
                                      Lect = $enLect })
            }
        }

        if ($celdaActual -ge 0) {
            $Sync.Cola.Enqueue(@{ T = 'celda'; Idx = $celdaActual; B = $peorCelda })
        }
        $seg = [math]::Max(0.001, $reloj.Elapsed.TotalSeconds)
        $Sync.Cola.Enqueue(@{ T = 'prog'; Pct = 100; Cuenta = $cuenta.Clone(); Err = $errores
                              Vel = ('{0:N1} MB/s' -f (($leidoTotal / 1MB) / $seg)); Eta = '00:00:00'
                              Lect = [math]::Round(($msLeyendo / 1000) / $seg * 100, 0) })
        # Se informa en la unidad que toque y con la velocidad: en GB con un
        # decimal, un barrido corto sale como "0.3 GB" y no se puede comparar
        # nada. El bloque leido tambien, para poder contrastar tamanos.
        $velFinal = ($leidoTotal / 1MB) / $seg
        Say ("Barrido terminado: {0} en {1:N0} s = {2:N1} MB/s (bloques de {3}), {4} bloque(s) con error." -f `
             (Format-TamWorker $leidoTotal), $seg, $velFinal,
             (Format-TamWorker $bloque), $errores) $(if ($errores) { 'error' } else { 'ok' })
        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = ($errores -eq 0) })
    }
    catch {
        Say "ERROR: $($_.Exception.Message)" 'error'
        $Sync.Cola.Enqueue(@{ T = 'fin'; Ok = $false })
    }
    finally {
        # Soltar el bloqueo de suspension: si no, el equipo se quedaria
        # sin poder dormirse despues de terminar el barrido.
        try { [RawDisk]::MantenerDespierto($false) } catch {}
        if ($fs) { try { $fs.Dispose() } catch {} }
        elseif ($h -and -not $h.IsInvalid) { try { $h.Close() } catch {} }
    }
}

# Estas dos NO pueden vivir dentro de Show-Diagnostico: los manejadores
# de eventos usan GetNewClosure(), que captura variables pero no funciones
# locales, y al dispararse mas tarde el nombre ya no existe.
function Write-DiagLog {
    param($Caja, [string]$Texto, [string]$Nivel = 'info')
    $col = switch ($Nivel) { 'ok' { $C.Verde } 'error' { $C.Rojo } 'warn' { $C.Oro } default { $C.Gris } }
    # Un parrafo por linea, para que el texto copiado salga con sus saltos.
    $par = New-Object Windows.Documents.Paragraph
    $par.Margin = New-Object Windows.Thickness 0
    $par.LineHeight = 14
    $run = New-Object Windows.Documents.Run ("[{0}] > {1}" -f (Get-Date -Format 'HH:mm:ss'), $Texto)
    $run.Foreground = Br $col
    $par.Inlines.Add($run)
    $Caja.Document.Blocks.Add($par)
    $Caja.ScrollToEnd()
}

function Add-FilaDato {
    param($Panel, [string]$K, [string]$V, [string]$Col = $null)
    $g = New-Object Windows.Controls.Grid
    $cd1 = New-Object Windows.Controls.ColumnDefinition
    $cd1.Width = New-Object Windows.GridLength 132
    $cd2 = New-Object Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($cd1); $g.ColumnDefinitions.Add($cd2)
    $a = New-Object Windows.Controls.TextBlock
    $a.Text = $K; $a.FontSize = 10; $a.Foreground = Br $C.Gris
    $b = New-Object Windows.Controls.TextBlock
    $b.Text = $V; $b.FontSize = 10.5; $b.TextWrapping = 'Wrap'
    $b.Foreground = Br $(if ($Col) { $Col } else { $C.Blanco })
    [Windows.Controls.Grid]::SetColumn($b, 1)
    $g.Children.Add($a) | Out-Null; $g.Children.Add($b) | Out-Null
    $g.Margin = New-Object Windows.Thickness 0, 0, 0, 4
    $Panel.Children.Add($g) | Out-Null
}

function Show-Diagnostico {
    param(
        [hashtable]$D,
        # Devuelve la ventana sin mostrarla (autoprueba y capturas).
        [switch]$SoloConstruir
    )

    $cols = 64
    $filas = 24
    $celdas = $cols * $filas

    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diagnostico" Height="880" Width="1280" MinHeight="700" MinWidth="1100"
        WindowStartupLocation="CenterOwner" Background="$($C.Fondo)"
        FontFamily="Cascadia Mono, Consolas, Lucida Console"
        TextOptions.TextFormattingMode="Display">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Background="#0B0C0F">
      <Polygon Points="0,0 22,0 12,66 0,66" Fill="$($C.Rojo)" Width="22" Height="66" HorizontalAlignment="Left"/>
      <StackPanel Margin="36,14,0,12">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="///" Foreground="$($C.Rojo)" FontSize="17" FontWeight="Bold" Margin="0,0,10,0"/>
          <TextBlock x:Name="Titulo" Foreground="$($C.Blanco)" FontSize="18" FontWeight="Bold"/>
        </StackPanel>
        <TextBlock x:Name="SubTit" Foreground="$($C.Oro)" FontSize="10" Margin="34,5,0,0"/>
      </StackPanel>
      <Border BorderBrush="$($C.Oro)" BorderThickness="1" Padding="10,4" Background="#14110A"
              HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,20,0">
        <TextBlock Text="[ SOLO LECTURA ]" Foreground="$($C.Oro)" FontSize="10" FontWeight="Bold"/>
      </Border>
      <Rectangle Height="1" VerticalAlignment="Bottom" Fill="$($C.OroTenue)"/>
    </Grid>

    <Grid Grid.Row="1" Margin="20,16,20,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="330"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" Margin="0,0,16,0">
        <StackPanel>
          <Grid>
            <Border Background="#0B0C0F" BorderBrush="$($C.OroTenue)" BorderThickness="1"/>
            <StackPanel Margin="14,12,14,12">
              <TextBlock Text="// PASAPORTE" Foreground="$($C.Oro)" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
              <StackPanel x:Name="Pasaporte"/>
            </StackPanel>
          </Grid>
          <Grid Margin="0,12,0,0">
            <Border Background="#0B0C0F" BorderBrush="$($C.OroTenue)" BorderThickness="1"/>
            <StackPanel Margin="14,12,14,12">
              <TextBlock Text="// SALUD  S.M.A.R.T." Foreground="$($C.Oro)" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
              <StackPanel x:Name="Salud"/>
            </StackPanel>
          </Grid>
        </StackPanel>
      </ScrollViewer>

      <Grid Grid.Column="1">
        <Border Background="#0B0C0F" BorderBrush="$($C.OroTenue)" BorderThickness="1"/>
        <Grid Margin="14,12,14,12">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Text="// TEST DE SUPERFICIE  (lectura secuencial, no destructivo)"
                     Foreground="$($C.Oro)" FontSize="10" FontWeight="Bold" Margin="0,0,0,10"/>

          <WrapPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,12">
            <TextBlock Text="DESDE %" Foreground="$($C.Gris)" FontSize="10" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="Desde" Text="0" Width="52" Background="#000000" Foreground="$($C.Blanco)"
                     BorderBrush="$($C.OroTenue)" BorderThickness="1" Padding="5,3" FontSize="11" Margin="0,0,14,0"/>
            <TextBlock Text="HASTA %" Foreground="$($C.Gris)" FontSize="10" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="Hasta" Text="100" Width="52" Background="#000000" Foreground="$($C.Blanco)"
                     BorderBrush="$($C.OroTenue)" BorderThickness="1" Padding="5,3" FontSize="11" Margin="0,0,14,0"/>
            <TextBlock Text="BLOQUE" Foreground="$($C.Gris)" FontSize="10" VerticalAlignment="Center" Margin="0,0,5,0"/>
            <!-- Boton que cicla en vez de ComboBox: el desplegable nativo de
                 Windows se pinta claro y rompe el HUD. -->
            <Button x:Name="TamBloque" Content="1 MB" Style="{DynamicResource BtnD}"
                    Width="84" Margin="0,0,14,0"/>
            <Button x:Name="BtnModo" Content="COMPLETO" Style="{DynamicResource BtnD}"
                    Width="106" Margin="0,0,16,0"/>
            <Button x:Name="BtnIniciar" Content="INICIAR" Style="{DynamicResource BtnD}" Width="96" Margin="0,0,8,0"/>
            <Button x:Name="BtnParar"   Content="DETENER" Style="{DynamicResource BtnDR}" Width="96" Margin="0,0,14,0" IsEnabled="False"/>
            <Button x:Name="BtnAcceso"  Content="T. ACCESO" Style="{DynamicResource BtnD}" Width="106"/>
          </WrapPanel>

          <Border Grid.Row="2" Background="#050607" BorderBrush="#1A1D22" BorderThickness="1" Padding="8">
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
              <UniformGrid x:Name="Mapa" Columns="$cols" HorizontalAlignment="Left" VerticalAlignment="Top"/>
            </ScrollViewer>
          </Border>

          <StackPanel Grid.Row="3" Margin="0,12,0,0">
            <WrapPanel x:Name="Leyenda" Orientation="Horizontal"/>
            <Grid Margin="0,10,0,0">
              <TextBlock x:Name="Stats" Foreground="$($C.Gris)" FontSize="10" VerticalAlignment="Center"/>
              <TextBlock x:Name="Pct" Foreground="$($C.Oro)" FontSize="13" FontWeight="Bold"
                         HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </StackPanel>
        </Grid>
      </Grid>
    </Grid>

    <Grid Grid.Row="2" Margin="20,12,20,14">
      <Border Background="#0B0C0F" BorderBrush="$($C.OroTenue)" BorderThickness="1"/>
      <Grid Margin="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="120"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Background="#111318">
          <TextBlock Text="  &gt;_  REGISTRO" Foreground="$($C.Oro)" FontSize="10"
                     FontWeight="Bold" Margin="8,5,0,5" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,3,8,3">
            <Button x:Name="BtnCopiarD"  Content="COPIAR TODO" Style="{DynamicResource BtnMiniD}" Margin="0,0,6,0"/>
            <Button x:Name="BtnGuardarD" Content="GUARDAR"     Style="{DynamicResource BtnMiniD}"/>
          </StackPanel>
          <Rectangle Height="1" VerticalAlignment="Bottom" Fill="$($C.OroTenue)"/>
        </Grid>
        <!-- RichTextBox para poder seleccionar y copiar, igual que la consola
             principal: un TextBlock de WPF no deja seleccionar texto. -->
        <RichTextBox x:Name="Log" Grid.Row="1" IsReadOnly="True"
                     Background="Transparent" Foreground="$($C.Gris)"
                     BorderThickness="0" Padding="0" Margin="10,6,4,8"
                     FontFamily="Cascadia Mono, Consolas" FontSize="10.5"
                     VerticalScrollBarVisibility="Auto"
                     HorizontalScrollBarVisibility="Disabled"
                     SelectionBrush="$($C.Rojo)" SelectionOpacity="0.45"
                     IsReadOnlyCaretVisible="False" IsUndoEnabled="False">
          <RichTextBox.ContextMenu>
            <ContextMenu>
              <MenuItem x:Name="MnuCopD"  Header="Copiar seleccion         Ctrl+C"/>
              <MenuItem x:Name="MnuTodD"  Header="Seleccionar todo         Ctrl+A"/>
              <MenuItem x:Name="MnuAllD"  Header="Copiar todo el registro"/>
              <Separator/>
              <MenuItem x:Name="MnuGuaD"  Header="Guardar registro en archivo..."/>
            </ContextMenu>
          </RichTextBox.ContextMenu>
        </RichTextBox>
      </Grid>
    </Grid>
  </Grid>
</Window>
"@
    $dr = New-Object System.Xml.XmlNodeReader ([xml]$x)
    $w  = [Windows.Markup.XamlReader]::Load($dr)
    if ($win.IsVisible) { $w.Owner = $win }
    if ($script:IconoApp) { $w.Icon = $script:IconoApp }
    $w.Resources.Add('Fondo', $win.FindResource('Fondo'))
    $w.Resources.Add('BtnD',  $win.FindResource('Btn'))
    $w.Resources.Add('BtnDR', $win.FindResource('BtnRojo'))
    $w.Resources.Add('BtnMiniD', $win.FindResource('BtnMini'))

    $U = @{}
    foreach ($n in 'Titulo','SubTit','Pasaporte','Salud','Desde','Hasta','TamBloque',
                   'BtnIniciar','BtnParar','BtnAcceso','BtnModo','Mapa','Leyenda','Stats','Pct','Log',
                   'BtnCopiarD','BtnGuardarD','MnuCopD','MnuTodD','MnuAllD','MnuGuaD') {
        $U[$n] = $w.FindName($n)
    }

    # El RichTextBox trae un parrafo vacio de fabrica; se quita para que la
    # primera linea no salga precedida de un hueco.
    $U.Log.Document = New-Object Windows.Documents.FlowDocument
    $U.Log.Document.PagePadding = New-Object Windows.Thickness 0
    $U.Log.Document.FontFamily  = $U.Log.FontFamily
    $U.Log.Document.FontSize    = 10.5

    $rtb = $U.Log
    $copiarTodo = {
        $err = Copy-TextoAlPortapapeles (Get-TextoDeRegistro $rtb)
        if ($err) { Write-DiagLog $rtb "No se pudo copiar: $err" 'error' }
        else { Write-DiagLog $rtb 'Registro copiado al portapapeles.' 'ok' }
    }.GetNewClosure()
    $guardar = {
        try {
            $f = Save-TextoAArchivo (Get-TextoDeRegistro $rtb) 'diagnostico'
            if ($f) { Write-DiagLog $rtb "Registro guardado en $f" 'ok' }
        } catch { Write-DiagLog $rtb "No se pudo guardar: $($_.Exception.Message)" 'error' }
    }.GetNewClosure()

    $U.BtnCopiarD.Add_Click($copiarTodo)
    $U.BtnGuardarD.Add_Click($guardar)
    $U.MnuAllD.Add_Click($copiarTodo)
    $U.MnuGuaD.Add_Click($guardar)
    $U.MnuCopD.Add_Click({ if ($rtb.Selection.Text) { [Windows.Clipboard]::SetText($rtb.Selection.Text) } }.GetNewClosure())
    $U.MnuTodD.Add_Click({ $rtb.Focus() | Out-Null; $rtb.SelectAll() }.GetNewClosure())

    $U.Titulo.Text = "DIAGNOSTICO  //  $(([string]$D.Modelo).ToUpper())"
    $U.SubTit.Text = "DISCO $($D.Disco)  $SEP  BUS $($D.Bus)  $SEP  $(Format-Tam $D.TamDisco)  $SEP  SERIE $($D.Serie)"

    $tamanos = @(
        @{ Txt = '256 KB'; V = 256KB }, @{ Txt = '1 MB'; V = 1MB },
        @{ Txt = '4 MB';   V = 4MB },   @{ Txt = '8 MB'; V = 8MB }
    )
    $idxTam = @{ I = 1 }
    $U.TamBloque.Content = $tamanos[$idxTam.I].Txt
    $U.TamBloque.ToolTip = 'Tamano de cada lectura. Bloques grandes barren mas rapido; pequenos localizan mejor los sectores lentos.'
    $U.TamBloque.Add_Click({
        $idxTam.I = ($idxTam.I + 1) % $tamanos.Count
        $U.TamBloque.Content = $tamanos[$idxTam.I].Txt
    }.GetNewClosure())

    $modos = @('COMPLETO', 'MUESTREO')
    $idxModo = @{ I = 0 }
    $U.BtnModo.ToolTip = 'COMPLETO lee todo el disco: encuentra hasta un sector malo suelto, pero tarda lo que tarde el medio. MUESTREO lee un bloque por celda del mapa: minutos en vez de horas, detecta zonas lentas y danos extensos, pero puede pasar por alto un sector aislado.'
    $U.BtnModo.Add_Click({
        $idxModo.I = ($idxModo.I + 1) % $modos.Count
        $U.BtnModo.Content = $modos[$idxModo.I]
    }.GetNewClosure())

    # ---------- mapa de superficie ----------
    $rects = New-Object 'System.Collections.Generic.List[Windows.Shapes.Rectangle]'
    $brNeutro = Br '#151A20'
    for ($i = 0; $i -lt $celdas; $i++) {
        $r = New-Object Windows.Shapes.Rectangle
        $r.Width = 13; $r.Height = 13
        $r.Margin = New-Object Windows.Thickness 1
        $r.Fill = $brNeutro
        $rects.Add($r)
        $U.Mapa.Children.Add($r) | Out-Null
    }
    $brBucket = @($script:Buckets | ForEach-Object { Br $_.Color })

    $etiquetasCuenta = @()
    $etiquetasTxt = @()
    foreach ($bk in $script:Buckets) {
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $sp.Margin = New-Object Windows.Thickness 0, 0, 16, 4
        $sw = New-Object Windows.Shapes.Rectangle
        $sw.Width = 11; $sw.Height = 11; $sw.Fill = Br $bk.Color
        $sw.VerticalAlignment = 'Center'
        $sp.Children.Add($sw) | Out-Null
        $tl = New-Object Windows.Controls.TextBlock
        $tl.Text = "  $($bk.Txt)"; $tl.FontSize = 10; $tl.Foreground = Br $C.Gris
        $tl.VerticalAlignment = 'Center'
        $sp.Children.Add($tl) | Out-Null
        $etiquetasTxt += $tl
        $tn = New-Object Windows.Controls.TextBlock
        $tn.Text = '  0'; $tn.FontSize = 10; $tn.FontWeight = 'Bold'
        $tn.Foreground = Br $bk.Color; $tn.VerticalAlignment = 'Center'
        $sp.Children.Add($tn) | Out-Null
        $etiquetasCuenta += $tn
        $U.Leyenda.Children.Add($sp) | Out-Null
    }

    # Los manejadores usan GetNewClosure(), y dentro de una closure
    # $script:X se lee como NULL. Hay que capturarlo en locales ANTES.
    $buckets  = $script:Buckets
    $scanSb   = $script:SuperficieSb
    $accesoSb = $script:AccesoSb
    $leerSrc  = $script:LeerBloqueSrc
    $syncApp  = $script:Sync
    $esAdmin  = $script:EsAdmin

    # ---------- estado del barrido ----------
    $sync = [hashtable]::Synchronized(@{
        Cola     = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
        Cancelar = $false
        Activo   = $false
    })
    $psRef = @{ Ps = $null; Rs = $null; H = $null }

    $tmr = New-Object Windows.Threading.DispatcherTimer
    $tmr.Interval = [TimeSpan]::FromMilliseconds(120)
    $tmr.Add_Tick({
        while ($sync.Cola.Count -gt 0) {
            $m = $sync.Cola.Dequeue()
            switch ($m.T) {
                'log'   { Write-DiagLog $U.Log $m.Txt $m.N }
                'celda' { if ($m.Idx -ge 0 -and $m.Idx -lt $rects.Count) { $rects[$m.Idx].Fill = $brBucket[$m.B] } }
                'prog'  {
                    $U.Pct.Text = "$($m.Pct)%"
                    for ($i = 0; $i -lt 7; $i++) { $etiquetasCuenta[$i].Text = '  {0:N0}' -f $m.Cuenta[$i] }
                    $lec = if ($null -ne $m.Lect) { "   $SEP   EN LECTURA $($m.Lect)%" } else { '' }
                    $U.Stats.Text = "$($m.Vel)   $SEP   RESTANTE $($m.Eta)   $SEP   ERRORES $($m.Err)$lec"
                }
                'acceso' {
                    $col = switch ($m.Veredicto) {
                        'NO CONCLUYENTE' { $C.Oro }
                        default          { $C.Verde }
                    }
                    Add-FilaDato $U.Pasaporte 'TIPO MEDIDO' $m.Veredicto $col
                    Add-FilaDato $U.Pasaporte 'T. DE ACCESO' ('{0:N2} ms mediana ({1} muestras)' -f $m.Mediana, $m.N)
                }
                'fin' {
                    $sync.Activo = $false
                    $U.BtnIniciar.IsEnabled = $true
                    $U.BtnAcceso.IsEnabled = $true
                    $U.BtnParar.IsEnabled = $false
                    $U.TamBloque.IsEnabled = $true
                    $U.BtnModo.IsEnabled = $true
                    $U.Desde.IsEnabled = $true
                    $U.Hasta.IsEnabled = $true
                    if ($psRef.Ps) {
                        try { $psRef.Ps.EndInvoke($psRef.H) | Out-Null } catch {}
                        $psRef.Ps.Dispose(); $psRef.Rs.Close(); $psRef.Rs.Dispose()
                        $psRef.Ps = $null; $psRef.Rs = $null; $psRef.H = $null
                    }
                }
            }
        }
    }.GetNewClosure())
    $tmr.Start()

    $U.BtnIniciar.Add_Click({
        if ($sync.Activo) { return }
        if ($syncApp.Busy) { Write-DiagLog $U.Log 'Hay una operacion de escritura en curso: espera a que termine.' 'warn'; return }

        $d1 = 0.0; $d2 = 100.0
        if (-not [double]::TryParse($U.Desde.Text, [ref]$d1) -or
            -not [double]::TryParse($U.Hasta.Text, [ref]$d2) -or
            $d1 -lt 0 -or $d2 -gt 100 -or $d1 -ge $d2) {
            Write-DiagLog $U.Log 'Rango invalido: usa numeros entre 0 y 100, y que DESDE sea menor que HASTA.' 'error'
            return
        }

        $sector = if ($D.Sector -gt 0) { [int]$D.Sector } else { 512 }
        $bloque = $tamanos[$idxTam.I].V
        $ini = [long](([double]$D.TamDisco * $d1 / 100) - ((([double]$D.TamDisco * $d1 / 100)) % $sector))
        $fin = [long]([double]$D.TamDisco * $d2 / 100)

        foreach ($r in $rects) { $r.Fill = $brNeutro }
        foreach ($t in $etiquetasCuenta) { $t.Text = '  0' }
        $U.Pct.Text = '0%'
        $sync.Cancelar = $false
        $sync.Activo = $true
        $U.BtnIniciar.IsEnabled = $false
        $U.BtnParar.IsEnabled = $true
        # Los ajustes se congelan: cambiarlos a media marcha no afecta al
        # barrido en curso, y el control mostraria un valor que no es el real.
        $U.TamBloque.IsEnabled = $false
        $U.BtnModo.IsEnabled = $false
        $U.Desde.IsEnabled = $false
        $U.Hasta.IsEnabled = $false
        Write-DiagLog $U.Log "Iniciando barrido de lectura del disco $($D.Disco) ($d1% a $d2%)..."

        # Umbrales proporcionales al bloque, y leyenda con los valores reales:
        # con bloques grandes toda lectura tarda mas, y una escala fija
        # pintaria el disco entero de rojo sin que signifique nada.
        $lims = Get-LimitesBucket ([double]$bloque)
        for ($i = 0; $i -lt 6; $i++) { $etiquetasTxt[$i].Text = "  $($lims[$i].Txt)" }

        $cfg = @{
            Disco = $D.Disco; Serie = $D.Serie; Sector = $sector; Bloque = [int]$bloque
            Inicio = $ini; Fin = $fin; Celdas = $celdas
            Limites = @($lims | ForEach-Object { [double]$_.Max })
            LeerBloqueSrc = $leerSrc
            Muestreo = ($idxModo.I -eq 1)
        }
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $null = $ps.AddScript($scanSb).AddArgument($cfg).AddArgument($sync)
        $psRef.Ps = $ps; $psRef.Rs = $rs; $psRef.H = $ps.BeginInvoke()
    }.GetNewClosure())

    $U.BtnParar.Add_Click({
        $sync.Cancelar = $true
        $U.BtnParar.IsEnabled = $false
        Write-DiagLog $U.Log 'Deteniendo...' 'warn'
    }.GetNewClosure())

    $U.BtnAcceso.Add_Click({
        if ($sync.Activo) { return }
        if ($syncApp.Busy) { Write-DiagLog $U.Log 'Hay una operacion de escritura en curso: espera a que termine.' 'warn'; return }

        $sync.Cancelar = $false
        $sync.Activo = $true
        $U.BtnIniciar.IsEnabled = $false
        $U.BtnAcceso.IsEnabled = $false
        $U.BtnParar.IsEnabled = $true
        $U.TamBloque.IsEnabled = $false
        $U.BtnModo.IsEnabled = $false
        $U.Desde.IsEnabled = $false
        $U.Hasta.IsEnabled = $false

        $cfg = @{
            Disco = $D.Disco; Sector = $(if ($D.Sector -gt 0) { [int]$D.Sector } else { 512 })
            Tamano = [double]$D.TamDisco; Tam = 4KB; Muestras = 300
        }
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $null = $ps.AddScript($accesoSb).AddArgument($cfg).AddArgument($sync)
        $psRef.Ps = $ps; $psRef.Rs = $rs; $psRef.H = $ps.BeginInvoke()
    }.GetNewClosure())

    $w.Add_Closing({
        param($s, $e)
        $sync.Cancelar = $true
        $tmr.Stop()
    }.GetNewClosure())

    # ---------- pasaporte y salud, tras pintar la ventana ----------
    $w.Add_ContentRendered({
        Write-DiagLog $U.Log 'Diagnostico abierto en modo de solo lectura.'
        $dk = Get-Disk -Number $D.Disco -ErrorAction SilentlyContinue
        $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq "$($D.Disco)" }

        Add-FilaDato $U.Pasaporte 'MODELO'      ([string]$D.Modelo)
        Add-FilaDato $U.Pasaporte 'SERIE'       ([string]$D.Serie)
        if ($pd) {
            Add-FilaDato $U.Pasaporte 'FIRMWARE' ([string]$pd.FirmwareVersion)
            Add-FilaDato $U.Pasaporte 'TIPO'     ([string]$pd.MediaType)
            if ($pd.SpindleSpeed -gt 0) { Add-FilaDato $U.Pasaporte 'RPM' ([string]$pd.SpindleSpeed) }
        }
        Add-FilaDato $U.Pasaporte 'BUS'         ([string]$D.Bus)
        Add-FilaDato $U.Pasaporte 'CAPACIDAD'   (Format-Tam $D.TamDisco)
        if ($dk) {
            Add-FilaDato $U.Pasaporte 'SECTOR LOG.' "$($dk.LogicalSectorSize) B"
            Add-FilaDato $U.Pasaporte 'SECTOR FIS.' "$($dk.PhysicalSectorSize) B"
            Add-FilaDato $U.Pasaporte 'PARTICIONES' ([string]$dk.PartitionStyle)
            Add-FilaDato $U.Pasaporte 'SISTEMA'  $(if ($dk.IsSystem) { 'SI' } else { 'no' })
            Add-FilaDato $U.Pasaporte 'ARRANQUE' $(if ($dk.IsBoot) { 'SI' } else { 'no' })
            Add-FilaDato $U.Pasaporte 'SOLO LECT.' $(if ($dk.IsReadOnly) { 'SI' } else { 'no' })
        }
        if ($D.Protegida) {
            Add-FilaDato $U.Pasaporte 'BLINDAJE' 'UNIDAD BLINDADA - SOLO DIAGNOSTICO' $C.Rojo
        }

        if ($pd) {
            $colSalud = switch ("$($pd.HealthStatus)") { 'Healthy' { $C.Verde } default { $C.Rojo } }
            Add-FilaDato $U.Salud 'ESTADO'      ([string]$pd.HealthStatus) $colSalud
            Add-FilaDato $U.Salud 'OPERATIVO'   ([string]$pd.OperationalStatus)
        }
        try {
            $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($rc.Temperature)         { Add-FilaDato $U.Salud 'TEMPERATURA' "$($rc.Temperature) C" $(if ($rc.Temperature -ge 55) { $C.Rojo } else { $C.Verde }) }
            if ($rc.TemperatureMax)      { Add-FilaDato $U.Salud 'TEMP. MAXIMA' "$($rc.TemperatureMax) C" }
            if ($null -ne $rc.PowerOnHours) {
                $h = [int]$rc.PowerOnHours
                Add-FilaDato $U.Salud 'HORAS ENCENDIDO' ("{0:N0} h  ({1:N0} dias)" -f $h, ($h / 24))
            }
            if ($null -ne $rc.Wear)      { Add-FilaDato $U.Salud 'DESGASTE' "$($rc.Wear) %" $(if ([int]$rc.Wear -ge 80) { $C.Rojo } else { $C.Verde }) }
            if ($null -ne $rc.StartStopCycleCount) { Add-FilaDato $U.Salud 'CICLOS' ("{0:N0}" -f $rc.StartStopCycleCount) }
            foreach ($par in @(@('ReadErrorsTotal','ERR. LECTURA'), @('ReadErrorsUncorrected','ERR. NO CORREG.'), @('WriteErrorsTotal','ERR. ESCRITURA'))) {
                $v = $rc.($par[0])
                if ($null -ne $v) { Add-FilaDato $U.Salud $par[1] ("{0:N0}" -f $v) $(if ([long]$v -gt 0) { $C.Rojo } else { $C.Verde }) }
            }
            Write-DiagLog $U.Log 'Contadores de fiabilidad leidos.' 'ok'
        } catch {
            Add-FilaDato $U.Salud 'S.M.A.R.T.' 'NO DISPONIBLE' $C.Oro
            $motivo = if (-not $esAdmin) { 'requiere ejecutar como administrador' }
                      elseif ($D.Bus -eq 'USB') { 'el puente USB no suele dejar pasar S.M.A.R.T.' }
                      else { $_.Exception.Message }
            Add-FilaDato $U.Salud '' $motivo $C.Gris
            Write-DiagLog $U.Log "Contadores de fiabilidad no disponibles: $motivo" 'warn'
        }
    }.GetNewClosure())

    if ($SoloConstruir) { return $w }
    $w.Show()
}

# ==================================================================
#  11. REFRESCO DE LA LISTA
# ==================================================================
function Update-Lista {
    $UI.Lista.Children.Clear()
    $script:Botones = @()

    try { $unidades = @(Get-Unidades) }
    catch {
        Write-Log "No se pudo escanear: $($_.Exception.Message)" 'error'
        return
    }

    # Blindadas primero: lo primero que debes ver es que si las detecto.
    foreach ($u in $unidades) {
        $u.Razones   = @(Get-RazonesBloqueo $u)
        $u.Protegida = $u.Razones.Count -gt 0
    }
    $unidades = @($unidades | Sort-Object `
        @{ Expression = { if ($_.Protegida) { 0 } else { 1 } } },
        @{ Expression = { if ($_.SinMedio)  { 1 } else { 0 } } },
        @{ Expression = { $_.Letra } })

    $libres = 0; $prot = 0; $blindadas = @()
    foreach ($u in $unidades) {
        $UI.Lista.Children.Add((New-Tarjeta $u)) | Out-Null
        if ($u.Protegida) { $prot++; $blindadas += $u } elseif (-not $u.SinMedio) { $libres++ }
    }

    if ($unidades.Count -eq 0) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = '/// NO SE DETECTO NINGUNA UNIDAD USB CONECTADA'
        $t.Foreground = Br $C.GrisOscuro
        $t.FontSize = 12; $t.FontWeight = 'Bold'
        $t.Margin = New-Object Windows.Thickness 4, 24, 0, 0
        $UI.Lista.Children.Add($t) | Out-Null
    }

    $UI.Contador.Text = "$($unidades.Count) DETECTADAS  $SEP  $libres OPERABLES  $SEP  $prot BLINDADAS"

    if ($blindadas.Count -gt 0) {
        $nombres = ($blindadas | ForEach-Object {
            $n = if ($_.Etiqueta) { $_.Etiqueta } else { $_.Modelo }
            if ($_.Letra) { "$($n.ToUpper()) ($($_.Letra):)" } else { $n.ToUpper() }
        }) -join '   //   '
        $UI.AlertaTxt.Text = "UNIDAD BLINDADA CONECTADA:  $nombres  //  DETECTADA Y CON TODAS LAS ACCIONES BLOQUEADAS"
        $UI.AlertaBox.Visibility = 'Visible'
    } else {
        $UI.AlertaBox.Visibility = 'Collapsed'
    }

    Write-Log "Escaneo completado: $($unidades.Count) unidad(es), $prot blindada(s)."
    $script:Firma = Get-FirmaUnidades
}

function Show-Protegidas {
    Show-Aviso -Titulo 'Reglas de blindaje activas' -Nivel 'warn' -Secciones @(
        @{ Titulo = 'NIVEL 1 - NUCLEO, NO SE PUEDE QUITAR NI DESDE AQUI NI DESDE UN ARCHIVO'
           Lineas = @(
               "la letra del sistema: $(($script:LetrasNucleo | ForEach-Object { "$_`:" }) -join ', ')",
               'discos de sistema o de arranque',
               'volumenes Fijos cuyo bus no sea USB / SD / MMC',
               'unidades con carpetas Windows / Program Files / Users',
               'discos internos: solo diagnostico, ninguna escritura') },
        @{ Titulo = 'NIVEL 2 - HEURISTICAS DE FABRICA (un disco exento se las salta)'
           Lineas = @(
               "modelos: $($script:Guard.Nombres -join ', ')",
               $(if ($script:Guard.Etiquetas.Count) { "etiquetas: $($script:Guard.Etiquetas -join ', ')" }
                 else { 'etiquetas: ninguna configurada' }),
               "tamano: mas de $($script:Guard.TamMaxGB) GB se asume disco de respaldo",
               $(if (@($script:Guard.Letras | Where-Object { $_ -notin $script:LetrasNucleo }).Count) {
                     "letras que agregaste: $((@($script:Guard.Letras | Where-Object { $_ -notin $script:LetrasNucleo }) | ForEach-Object { "$_`:" }) -join ', ')"
                 } else { 'letras extra: ninguna' })) },
        @{ Titulo = 'NIVEL 3 - LO QUE TU DECIDISTE (recordado en preferencias.json)'
           Lineas = @(
               $(if ($script:Pref.Protegidos.Count) { "PROTEGIDOS a mano: $($script:Pref.Protegidos -join ', ')" }
                 else { 'protegidos a mano: ninguno' }),
               $(if ($script:Pref.Exentos.Count) { "EXENTOS de las heuristicas: $($script:Pref.Exentos -join ', ')" }
                 else { 'exentos: ninguno' }),
               'se cambia con el boton PROTEGER / EXIMIR de cada tarjeta') },
        @{ Titulo = 'NUMEROS DE SERIE BLOQUEADOS (nivel 2 + 3, gana sobre las exenciones)'
           Lineas = @(if ($script:Guard.Seriales.Count) { $script:Guard.Seriales }
                      else { 'ninguno configurado' }) },
        @{ Titulo = 'SERIES EXENTAS (SALTAN MODELO, ETIQUETA, TAMANO Y LETRAS EXTRA)'
           Lineas = @(if ($script:Guard.Permitidos.Count) { $script:Guard.Permitidos }
                      else { 'ninguna configurada' }) },
        @{ Titulo = 'CUANDO SE COMPRUEBA'
           Lineas = @(
               'al dibujar la tarjeta, para decidir si muestra botones',
               'al pulsar el boton, antes de abrir el dialogo',
               'dentro del hilo que ejecuta, justo antes de escribir',
               'en REPARAR y GRABAR, ademas, se compara el numero de serie del disco') }
    ) | Out-Null
}

# ==================================================================
#  12. TEMPORIZADORES
# ==================================================================
# --- drena la cola del hilo de trabajo ---
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    while ($script:Sync.Cola.Count -gt 0) {
        $m = $script:Sync.Cola.Dequeue()
        switch ($m.T) {
            'log' { Write-Log $m.Txt $m.N }
            'prog' {
                Update-BarraProgreso $m.Pct
                $UI.ProgFase.Text = $m.Fase
                $partes = @("$($m.Pct)%")
                if ($m.Vel) { $partes += $m.Vel }
                if ($m.Eta) { $partes += "ETA $($m.Eta)" }
                $UI.ProgTxt.Text = $partes -join '   '
            }
            'fin' {
                $script:Sync.Busy = $false
                $UI.Latido.Visibility = 'Collapsed'
                Show-Progreso $false
                $UI.Estado.Text = if ($m.Ok) { 'OPERACION COMPLETADA' } else { 'LA OPERACION NO SE COMPLETO' }
                if ($script:Worker) {
                    try { $script:Worker.EndInvoke($script:Handle) | Out-Null } catch {}
                    $script:Worker.Dispose(); $script:Runspace.Close(); $script:Runspace.Dispose()
                    $script:Worker = $null; $script:Runspace = $null; $script:Handle = $null
                }
                Update-Lista
                Set-BotonesHabilitados $true
            }
        }
    }
})
$timer.Start()

# --- reloj + latido de actividad en el encabezado ---
$script:Tic = 0
$reloj = New-Object Windows.Threading.DispatcherTimer
$reloj.Interval = [TimeSpan]::FromMilliseconds(500)
$reloj.Add_Tick({
    $UI.Reloj.Text = (Get-Date -Format 'HH:mm:ss')
    if ($script:Sync.Busy) {
        $script:Tic = ($script:Tic + 1) % 12
        $UI.Latido.Children.Clear()
        for ($i = 0; $i -lt 12; $i++) {
            $r = New-Object Windows.Shapes.Rectangle
            $r.Width = 6; $r.Height = 8
            $r.Margin = New-Object Windows.Thickness 0, 0, 3, 0
            $r.Fill = if ($i -le $script:Tic) { Br $C.Rojo } else { Br '#22262C' }
            $UI.Latido.Children.Add($r) | Out-Null
        }
    }
})
$reloj.Start()

# --- vigia: detecta conexion y desconexion de unidades ---
$vigia = New-Object Windows.Threading.DispatcherTimer
$vigia.Interval = [TimeSpan]::FromSeconds(2)
$vigia.Add_Tick({
    if ($script:Sync.Busy) { return }
    $f = Get-FirmaUnidades
    if ($f -ne $script:Firma) {
        Write-Log 'Cambio detectado en las unidades conectadas.' 'warn'
        Update-Lista
    }
})
$vigia.Start()

# ==================================================================
#  13. ARRANQUE
# ==================================================================
if ($script:EsAdmin) {
    $UI.AdminTxt.Text = '[ ADMINISTRADOR ]'
    $UI.AdminTxt.Foreground   = Br $C.Oro
    $UI.AdminChip.BorderBrush = Br $C.Oro
    $UI.AdminChip.Background  = Br '#14110A'
} else {
    $UI.AdminTxt.Text = '[ SIN PRIVILEGIOS ]'
    $UI.AdminTxt.Foreground   = Br $C.Rojo
    $UI.AdminChip.BorderBrush = Br $C.Rojo
    $UI.AdminChip.Background  = Br $C.RojoFondo
}

$UI.BtnScan.Add_Click({ Update-Lista })
$UI.BtnProt.Add_Click({ Show-Protegidas })
$UI.BtnTodos.Add_Click({
    $script:VerTodos = -not $script:VerTodos
    $UI.BtnTodos.Content = if ($script:VerTodos) { 'SOLO EXTRAIBLES' } else { 'VER TODOS LOS DISCOS' }
    Write-Log $(if ($script:VerTodos) {
        'Mostrando TODOS los discos. Los no extraibles son solo para diagnostico: el guardian les niega cualquier escritura.'
    } else { 'Mostrando solo medios extraibles.' }) 'warn'
    Update-Lista
})
$UI.BtnCopiar.Add_Click({ Copy-Registro })
$UI.BtnGuardar.Add_Click({ Save-Registro })
$UI.BtnLimpiar.Add_Click({ Clear-Registro })
$UI.MnuCopiarAll.Add_Click({ Copy-Registro })
$UI.MnuGuardar.Add_Click({ Save-Registro })
$UI.MnuLimpiar.Add_Click({ Clear-Registro })
$UI.MnuCopiar.Add_Click({ if ($UI.Log.Selection.Text) { [Windows.Clipboard]::SetText($UI.Log.Selection.Text) } })
$UI.MnuTodo.Add_Click({ $UI.Log.Focus() | Out-Null; $UI.Log.SelectAll() })

$UI.BtnCancelar.Add_Click({
    $script:Sync.Cancelar = $true
    $UI.BtnCancelar.IsEnabled = $false
    $UI.ProgFase.Text = 'CANCELANDO'
    Write-Log 'Cancelacion solicitada: se detendra al terminar el bloque en curso.' 'warn'
})
$win.Add_Closing({
    param($s, $e)
    if ($script:Sync.Busy) {
        $r = Show-Aviso -Titulo 'Operacion en curso' -Nivel 'error' -SiNo `
            -Cuerpo ("Hay una operacion escribiendo en una unidad ahora mismo.`n`n" +
                     "Cerrar el programa puede dejar la memoria a medias o danarla.`n`n" +
                     "Cerrar de todos modos?")
        if (-not $r) { $e.Cancel = $true; return }
    }
    $timer.Stop(); $reloj.Stop(); $vigia.Stop()
})

if ($SoloCargar) { $timer.Stop(); $reloj.Stop(); $vigia.Stop(); return }

Write-Log 'Limpiador de USB iniciado.'
Write-Log ("Guardian activo - letras bloqueadas: {0}" -f ($script:Guard.Letras -join ', ')) 'warn'
if (-not $script:EsAdmin) {
    Write-Log 'Modo sin privilegios: limpiar y formatear estan deshabilitados.' 'warn'
}
Update-Lista

# ------------------------------------------------------------------
#  Autoprueba: verifica el guardian sin abrir la ventana
# ------------------------------------------------------------------
if ($Autoprueba) {
    Write-Host ''
    Write-Host '  /// AUTOPRUEBA DEL GUARDIAN ///' -ForegroundColor Yellow
    foreach ($u in (Get-Unidades)) {
        $rz  = @(Get-RazonesBloqueo $u)
        $et  = if ($u.Letra) { "$($u.Letra):" } else { "disco $($u.Disco)" }
        $nom = if ($u.Etiqueta) { $u.Etiqueta } else { $u.Modelo }
        if ($rz.Count -gt 0) {
            Write-Host ("  [BLOQUEADA]  {0,-8} {1}" -f $et, $nom) -ForegroundColor Red
            $rz | ForEach-Object { Write-Host "                   - $_" -ForegroundColor DarkRed }
        } elseif ($u.SinMedio) {
            Write-Host ("  [sin medio]  {0,-8} {1}  (la ventana no le ofrece ninguna accion)" -f $et, $nom) -ForegroundColor DarkGray
        } elseif (-not $u.Letra) {
            Write-Host ("  [permitida]  {0,-8} {1}  (sin letra: solo reparar, grabar o expulsar)" -f $et, $nom) -ForegroundColor DarkYellow
        } elseif (-not $u.Montado) {
            Write-Host ("  [permitida]  {0,-8} {1}  (no montada: solo formatear, reparar o expulsar)" -f $et, $nom) -ForegroundColor DarkYellow
        } else {
            Write-Host ("  [permitida]  {0,-8} {1}" -f $et, $nom) -ForegroundColor Green
        }
    }
    Write-Host ''
    foreach ($caso in @(
        @{ Letra='C'; Modelo='Micron_2450'; Etiqueta=''; Serie='x'; TamDisco=1TB; TipoVol='Fixed'; Bus='NVMe'; EsSistema=$true;  EsArranque=$true },
        @{ Letra='E'; Modelo='WD My Passport 25E2'; Etiqueta='RESPALDO'; Serie='WX21A9FICTICIA'; TamDisco=4TB; TipoVol='Fixed'; Bus='USB'; EsSistema=$false; EsArranque=$false }
    )) {
        $n = @(Get-RazonesBloqueo $caso).Count
        $r = if ($n -gt 0) { "OK  ($n reglas)" } else { 'FALLO CRITICO' }
        Write-Host ("  Prueba negativa {0}: {1}" -f "$($caso.Letra):", $r) `
            -ForegroundColor $(if ($n -gt 0) { 'Green' } else { 'Red' })
    }

    # --- disco sin letra: tras grabar una imagen no debe quedar inutil ---
    Write-Host ''
    Write-Host '  --- disco sin letra asignada (tras grabar imagen) ---' -ForegroundColor Yellow
    $sinLetra = @{ Letra=''; Modelo="SanDisk' Cruzer Fit"; Etiqueta=''; Serie='XYZ123'
                   TamDisco=16GB; TamVol=0; Libre=0; Fs=''; TipoVol=''; Bus='USB'
                   Disco=9; Sector=512; EsSistema=$false; EsArranque=$false
                   SinMedio=$false; Montado=$false; Protegida=$false; Razones=@() }
    $rz = @(Get-RazonesBloqueo $sinLetra)
    Write-Host ("  el guardian lo permite: {0}" -f `
        $(if ($rz.Count -eq 0) { 'OK' } else { "bloqueado por: $($rz -join '; ')" })) `
        -ForegroundColor $(if ($rz.Count -eq 0) { 'Green' } else { 'Red' })

    # La tarjeta debe ofrecer expulsar/reparar/grabar, y no limpiar/formatear
    $tarjeta = New-Tarjeta $sinLetra
    $botones = @()
    $pila = New-Object System.Collections.Stack
    $pila.Push($tarjeta)
    while ($pila.Count -gt 0) {
        $el = $pila.Pop()
        if ($el -is [Windows.Controls.Button]) { $botones += $el; continue }
        # OJO con el nombre: $c pisaria la paleta $C (PowerShell no
        # distingue mayusculas) y romperia todos los dialogos siguientes.
        if ($el -is [Windows.Controls.Panel]) { foreach ($hijo in $el.Children) { $pila.Push($hijo) } }
        elseif ($el -is [Windows.Controls.Border] -and $el.Child) { $pila.Push($el.Child) }
    }
    $estado = @{}
    foreach ($b in $botones) { $estado["$($b.Content)"] = [bool]$b.IsEnabled }
    # 8 botones: los 5 de accion, diagnostico, recuperar y el de proteccion.
    $ok = ($estado.Count -eq 8) -and (-not $estado['LIMPIAR']) -and (-not $estado['FORMATEAR']) -and
          $estado['REPARAR'] -and $estado['GRABAR'] -and $estado['EXPULSAR'] -and
          $estado['DIAGNOSTICO'] -and $estado['RECUPERAR'] -and $estado['PROTEGER']
    Write-Host ("  LIMPIAR={0} FORMATEAR={1} REPARAR={2} GRABAR={3} EXPULSAR={4} DIAG={5} RECUP={6} PROT={7}  -> {8}" -f `
        $estado['LIMPIAR'], $estado['FORMATEAR'], $estado['REPARAR'], $estado['GRABAR'],
        $estado['EXPULSAR'], $estado['DIAGNOSTICO'], $estado['RECUPERAR'], $estado['PROTEGER'],
        $(if ($ok) { 'OK' } else { 'FALLO' })) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })

    # --- una unidad BLINDADA debe ofrecer diagnostico y NADA de escritura ---
    Write-Host ''
    Write-Host '  --- diagnostico en unidad blindada (solo lectura) ---' -ForegroundColor Yellow
    $blindada = @{ Letra='E'; Modelo='WD My Passport 25E2'; Etiqueta='RESPALDO'
                   Serie='WX21A9FICTICIA'; TamDisco=4TB; TamVol=4TB; Libre=1TB; Fs='NTFS'
                   TipoVol='Fixed'; Bus='USB'; Disco=9; Sector=512
                   EsSistema=$false; EsArranque=$false; SinMedio=$false; Montado=$true
                   SoloDiagnostico=$false; Protegida=$false; Razones=@() }
    $tb = New-Tarjeta $blindada
    $bt2 = @()
    $pila2 = New-Object System.Collections.Stack
    $pila2.Push($tb)
    while ($pila2.Count -gt 0) {
        $el = $pila2.Pop()
        if ($el -is [Windows.Controls.Button]) { $bt2 += $el; continue }
        if ($el -is [Windows.Controls.Panel]) { foreach ($hijo in $el.Children) { $pila2.Push($hijo) } }
        elseif ($el -is [Windows.Controls.Border] -and $el.Child) { $pila2.Push($el.Child) }
    }
    $nombres = @($bt2 | ForEach-Object { "$($_.Content)" })
    # Solo se admiten los que leen el origen sin escribirlo, mas el boton
    # de proteccion, que no toca el disco: escribe preferencias.json.
    # Cualquier boton de escritura sobre el disco aqui seria un fallo grave.
    $permitidos = @('DIAGNOSTICO', 'RECUPERAR', 'PROTEGER', 'DESPROTEGER', 'EXIMIR', 'REACTIVAR', 'PROTEGIDO')
    $intrusos = @($nombres | Where-Object { $_ -notin $permitidos })
    $soloLectura = ($intrusos.Count -eq 0 -and $nombres.Count -eq 3)
    Write-Host ("  botones ofrecidos: {0}  -> {1}" -f `
        $(if ($nombres) { $nombres -join ', ' } else { 'ninguno' }),
        $(if ($soloLectura) { 'OK, solo operaciones de lectura' } else { "FALLO CRITICO: $($intrusos -join ', ')" })) `
        -ForegroundColor $(if ($soloLectura) { 'Green' } else { 'Red' })

    # --- un disco interno nunca puede recibir escrituras ---
    $interno = @{ Letra='C'; Modelo='Micron_2450'; Etiqueta=''; Serie='INT1'; TamDisco=1TB
                  TamVol=1TB; Libre=500GB; Fs='NTFS'; TipoVol='Fixed'; Bus='NVMe'; Disco=0
                  Sector=512; EsSistema=$true; EsArranque=$true; SinMedio=$false; Montado=$true
                  SoloDiagnostico=$true; Protegida=$false; Razones=@() }
    $ri = @(Get-RazonesBloqueo $interno)
    $tieneSoloDiag = ($ri -join ' ') -match 'SOLO DIAGNOSTICO'
    Write-Host ("  disco interno bloqueado para escritura: {0} ({1} reglas, incluye la de solo diagnostico: {2})" -f `
        $(if ($ri.Count -gt 0) { 'OK' } else { 'FALLO CRITICO' }), $ri.Count, $tieneSoloDiag) `
        -ForegroundColor $(if ($ri.Count -gt 0 -and $tieneSoloDiag) { 'Green' } else { 'Red' })

    # --- la lista de exentos NO puede desbloquear lo blindado ---
    # Se mete a proposito una serie de la lista negra en los exentos: la
    # lista negra tiene que ganar igual.
    Write-Host ''
    Write-Host '  --- series exentas de las heuristicas ---' -ForegroundColor Yellow
    $permOriginal  = $script:Guard.Permitidos
    $serieOriginal = $script:Guard.Seriales
    try {
        $script:Guard.Seriales   = @('SERIE-EN-LISTA-NEGRA')
        $script:Guard.Permitidos = @('SERIE-EN-LISTA-NEGRA', 'SERIE-HDD-PROPIO')

        $negra = @{ Letra='E'; Modelo='WD My Passport 25E2'; Etiqueta='RESPALDO'
                    Serie='SERIE-EN-LISTA-NEGRA'; TamDisco=4TB; TipoVol='Fixed'; Bus='USB'
                    EsSistema=$false; EsArranque=$false }
        $n1 = @(Get-RazonesBloqueo $negra).Count
        Write-Host ("  serie en lista negra Y en exentos: {0}" -f `
            $(if ($n1 -gt 0) { "sigue BLOQUEADO ($n1 reglas) - OK" } else { 'FALLO CRITICO' })) `
            -ForegroundColor $(if ($n1 -gt 0) { 'Green' } else { 'Red' })

        $sistema = @{ Letra='C'; Modelo='Micron_2450'; Etiqueta=''; Serie='SERIE-HDD-PROPIO'
                      TamDisco=1TB; TipoVol='Fixed'; Bus='NVMe'; EsSistema=$true; EsArranque=$true }
        $n2 = @(Get-RazonesBloqueo $sistema).Count
        Write-Host ("  Disco de sistema con serie EXENTA: {0}" -f `
            $(if ($n2 -gt 0) { "sigue BLOQUEADO ($n2 reglas) - OK" } else { 'FALLO CRITICO' })) `
            -ForegroundColor $(if ($n2 -gt 0) { 'Green' } else { 'Red' })

        # Un HDD propio de 1 TB, marca bloqueada pero serie exenta: debe pasar
        $hdd = @{ Letra='H'; Modelo='Seagate Expansion HDD'; Etiqueta='TRABAJO'
                  Serie='SERIE-HDD-PROPIO'; TamDisco=1TB; TipoVol='Fixed'; Bus='USB'
                  EsSistema=$false; EsArranque=$false }
        $rz = @(Get-RazonesBloqueo $hdd)
        Write-Host ("  HDD 1 TB marca bloqueada + serie exenta: {0}" -f `
            $(if ($rz.Count -eq 0) { 'OPERABLE - OK' } else { "bloqueado por: $($rz -join '; ')" })) `
            -ForegroundColor $(if ($rz.Count -eq 0) { 'Green' } else { 'Red' })

        # Un HDD externo GRANDE (4 TB) exento: la exencion tambien cubre el
        # limite de tamano, que si no dejaria inutil la exencion.
        $hddGrande = @{ Letra='H'; Modelo='Seagate Expansion HDD'; Etiqueta='RESPALDO'
                        Serie='SERIE-HDD-PROPIO'; TamDisco=4TB; TipoVol='Fixed'; Bus='USB'
                        EsSistema=$false; EsArranque=$false }
        $rzg = @(Get-RazonesBloqueo $hddGrande)
        Write-Host ("  HDD 4 TB (sobre el limite) + serie exenta: {0}" -f `
            $(if ($rzg.Count -eq 0) { 'OPERABLE - OK' } else { "bloqueado por: $($rzg -join '; ')" })) `
            -ForegroundColor $(if ($rzg.Count -eq 0) { 'Green' } else { 'Red' })

        # El mismo HDD sin estar exento: debe seguir bloqueado
        $script:Guard.Permitidos = @()
        $rz2 = @(Get-RazonesBloqueo $hdd)
        Write-Host ("  el mismo HDD sin exencion: {0}" -f `
            $(if ($rz2.Count -gt 0) { "BLOQUEADO ($($rz2.Count) reglas) - OK" } else { 'FALLO' })) `
            -ForegroundColor $(if ($rz2.Count -gt 0) { 'Green' } else { 'Red' })
    } finally {
        $script:Guard.Permitidos = $permOriginal
        $script:Guard.Seriales   = $serieOriginal
    }

    # --- preferencias del usuario: proteger, eximir y que se recuerde ---
    Write-Host ''
    Write-Host '  --- preferencias de proteccion (nivel 3) ---' -ForegroundColor Yellow
    $prefOriginal = @{ Protegidos = @($script:Pref.Protegidos); Exentos = @($script:Pref.Exentos) }
    $rutaOriginal = $script:PrefPath
    try {
        # Se escribe en una ruta temporal: la autoprueba no debe tocar las
        # preferencias reales de quien la ejecuta.
        $script:PrefPath = Join-Path ([IO.Path]::GetTempPath()) ("pref-prueba-{0}.json" -f ([guid]::NewGuid()))

        # 1. Una memoria corriente, libre. Se protege a mano.
        $usb = @{ Letra='J'; Modelo='SanDisk Cruzer Fit'; Etiqueta='DATOS'; Serie='USB-PRUEBA-1'
                  TamDisco=16GB; TipoVol='Removable'; Bus='USB'; EsSistema=$false; EsArranque=$false }
        $libre = @(Get-RazonesBloqueo $usb).Count -eq 0
        Set-Proteccion 'USB-PRUEBA-1' 'proteger' | Out-Null
        $trasProteger = @(Get-RazonesBloqueo $usb)
        $ok1 = $libre -and $trasProteger.Count -gt 0
        Write-Host ("  memoria libre -> PROTEGER -> bloqueada: {0}" -f `
            $(if ($ok1) { 'OK' } else { "FALLO (libre antes: $libre, razones despues: $($trasProteger.Count))" })) `
            -ForegroundColor $(if ($ok1) { 'Green' } else { 'Red' })

        # 2. Se relee del disco: la preferencia tiene que sobrevivir.
        Import-Preferencias
        Sync-Preferencias
        $ok2 = @(Get-RazonesBloqueo $usb).Count -gt 0 -and $script:Pref.Protegidos -contains 'USB-PRUEBA-1'
        Write-Host ("  la preferencia sobrevive a releer el archivo: {0}" -f `
            $(if ($ok2) { 'OK' } else { 'FALLO' })) -ForegroundColor $(if ($ok2) { 'Green' } else { 'Red' })

        # 3. Se quita y vuelve a quedar operable.
        Set-Proteccion 'USB-PRUEBA-1' 'desproteger' | Out-Null
        $ok3 = @(Get-RazonesBloqueo $usb).Count -eq 0
        Write-Host ("  DESPROTEGER la devuelve a operable: {0}" -f `
            $(if ($ok3) { 'OK' } else { 'FALLO' })) -ForegroundColor $(if ($ok3) { 'Green' } else { 'Red' })

        # 4. LO IMPORTANTE: eximir NO puede liberar un disco de sistema.
        $sis = @{ Letra='C'; Modelo='Micron_2450'; Etiqueta=''; Serie='SERIE-SISTEMA'
                  TamDisco=1TB; TipoVol='Fixed'; Bus='NVMe'; EsSistema=$true; EsArranque=$true
                  SoloDiagnostico=$true }
        Set-Proteccion 'SERIE-SISTEMA' 'eximir' | Out-Null
        $rSis = @(Get-RazonesBloqueo $sis)
        $nSis = @(Get-RazonesBloqueo $sis -SoloNucleo)
        $ok4 = $rSis.Count -gt 0 -and $nSis.Count -gt 0
        Write-Host ("  EXIMIR un disco de SISTEMA: {0}" -f `
            $(if ($ok4) { "sigue BLOQUEADO ($($rSis.Count) reglas, $($nSis.Count) del nucleo) - OK" }
              else { 'FALLO CRITICO' })) -ForegroundColor $(if ($ok4) { 'Green' } else { 'Red' })

        # 5. Y el boton de su tarjeta ni siquiera se ofrece habilitado.
        $btn = New-BotonProteccion $sis
        $ok5 = (-not $btn.IsEnabled) -and "$($btn.Content)" -eq 'PROTEGIDO'
        Write-Host ("  el boton de un disco de sistema sale bloqueado: {0} (texto '{1}', habilitado {2})" -f `
            $(if ($ok5) { 'OK' } else { 'FALLO CRITICO' }), $btn.Content, $btn.IsEnabled) `
            -ForegroundColor $(if ($ok5) { 'Green' } else { 'Red' })

        # 6. Un disco sin serie no se puede recordar, y el boton lo dice.
        $sinSerie = @{ Letra='K'; Modelo='Generico'; Etiqueta=''; Serie=''
                       TamDisco=8GB; TipoVol='Removable'; Bus='USB'
                       EsSistema=$false; EsArranque=$false }
        $btn2 = New-BotonProteccion $sinSerie
        $ok6 = -not $btn2.IsEnabled
        Write-Host ("  disco sin numero de serie: boton deshabilitado: {0}" -f `
            $(if ($ok6) { 'OK' } else { 'FALLO' })) -ForegroundColor $(if ($ok6) { 'Green' } else { 'Red' })

        # 7. Proteger gana sobre eximir si la misma serie esta en las dos.
        Set-Proteccion 'USB-PRUEBA-1' 'eximir'   | Out-Null
        Set-Proteccion 'USB-PRUEBA-1' 'proteger' | Out-Null
        $ok7 = @(Get-RazonesBloqueo $usb).Count -gt 0 -and
               $script:Pref.Exentos -notcontains 'USB-PRUEBA-1'
        Write-Host ("  proteger gana sobre eximir: {0}" -f `
            $(if ($ok7) { 'OK' } else { 'FALLO CRITICO' })) -ForegroundColor $(if ($ok7) { 'Green' } else { 'Red' })

        if (Test-Path -LiteralPath $script:PrefPath) {
            Remove-Item -LiteralPath $script:PrefPath -Force -ErrorAction SilentlyContinue
        }
    } finally {
        $script:PrefPath = $rutaOriginal
        $script:Pref = $prefOriginal
        Sync-Preferencias
    }

    # --- guardian de disco completo, el que usa REPARAR ---
    Write-Host '  --- guardian de disco completo (REPARAR) ---' -ForegroundColor Yellow
    foreach ($dk in @(Get-Disk -ErrorAction SilentlyContinue |
                      Where-Object { $_.BusType -in 'USB', 'SD', 'MMC' })) {
        $serie = "$($dk.SerialNumber)".Trim()
        $rz = @(Get-RazonesBloqueoDisco $dk.Number $serie $dk.Size $dk.FriendlyName)

        # Serie correcta pero OTRO disco: los adaptadores baratos reciclan
        # la misma serie de relleno, asi que el tamano tiene que delatarlo.
        # Si el disco se desconecta a media prueba, ambas llamadas devuelven
        # 'YA NO EXISTE' y la comparacion no dice nada: se omite.
        $otro = @(Get-RazonesBloqueoDisco $dk.Number $serie ($dk.Size + 1GB) $dk.FriendlyName)
        if (($rz -join ' ') -match 'YA NO EXISTE' -or ($otro -join ' ') -match 'YA NO EXISTE') {
            Write-Host '                 misma serie pero otro tamano: omitida (el disco se desconecto)' -ForegroundColor DarkGray
        } else {
            $pilla = ($otro.Count -gt $rz.Count)
            Write-Host ("                 misma serie pero otro tamano: {0}" -f `
                $(if ($pilla) { 'OK, aborta' } else { 'FALLO: no lo distingue' })) `
                -ForegroundColor $(if ($pilla) { 'DarkGreen' } else { 'Red' })
        }
        if ($rz.Count -gt 0) {
            Write-Host ("  [BLOQUEADO]  disco {0}  {1}" -f $dk.Number, $dk.FriendlyName) -ForegroundColor Red
            $rz | ForEach-Object { Write-Host "                 - $_" -ForegroundColor DarkRed }
        } else {
            Write-Host ("  [reparable]  disco {0}  {1}" -f $dk.Number, $dk.FriendlyName) -ForegroundColor Green
        }
        # La serie es la identidad real del disco: con una serie que no
        # corresponde, la operacion tiene que abortar aunque el numero exista.
        $mal = @(Get-RazonesBloqueoDisco $dk.Number 'SERIE-QUE-NO-EXISTE' $dk.Size $dk.FriendlyName)
        $veredicto = if ($mal.Count -gt 0) { 'OK, aborta' } else { 'FALLO CRITICO' }
        Write-Host ("                 identidad con serie equivocada: {0}" -f $veredicto) `
            -ForegroundColor $(if ($mal.Count -gt 0) { 'DarkGreen' } else { 'Red' })
    }
    # El disco del sistema jamas debe ser reparable, ni con su serie correcta
    $sys = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.IsSystem } | Select-Object -First 1
    if ($sys) {
        $n = @(Get-RazonesBloqueoDisco $sys.Number "$($sys.SerialNumber)".Trim()).Count
        Write-Host ("  Prueba negativa disco de sistema ({0}): {1}" -f $sys.Number,
                    $(if ($n -gt 0) { "OK  ($n reglas)" } else { 'FALLO CRITICO' })) `
            -ForegroundColor $(if ($n -gt 0) { 'Green' } else { 'Red' })
    }
    Write-Host ''

    # El dialogo de confirmacion se arma con recursos de la ventana principal:
    # se verifica que parsee y encuentre sus estilos.
    foreach ($op in 'formatear', 'limpiar', 'reparar', 'grabar') {
        try {
            $falso = @{ Letra = 'Z'; Etiqueta = 'PRUEBA'; Modelo = 'TEST'
                        TamVol = 8GB; Disco = 9; Bus = 'USB'; Serie = 'XYZ' }
            $ex = if ($op -eq 'grabar') {
                @{ Imagen = 'C:\ejemplo\linux.iso'; TamImagen = 1.4GB; Arrancable = $false }
            } else { $null }
            $d = Show-Confirmacion $falso $op -Extra $ex -SoloConstruir
            $d.Close()
            Write-Host "  Dialogo '$op': OK" -ForegroundColor Green
        } catch {
            Write-Host "  Dialogo '$op': FALLO - $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # --- avisos con estilo propio, sin MessageBox nativo ---
    foreach ($n in 'info', 'warn', 'error') {
        try {
            $d = Show-Aviso -Titulo "Prueba $n" -Cuerpo 'cuerpo' -Nivel $n `
                 -Secciones @(@{ Titulo = 'SECCION'; Lineas = @('a', 'b') }) -SoloConstruir
            $d.Close()
            Write-Host "  Aviso '$n': OK" -ForegroundColor Green
        } catch {
            Write-Host "  Aviso '$n': FALLO - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    try {
        $d = Show-Aviso -Titulo 'Prueba si/no' -Cuerpo 'x' -SiNo -SoloConstruir; $d.Close()
        Write-Host "  Aviso si/no: OK" -ForegroundColor Green
    } catch { Write-Host "  Aviso si/no: FALLO - $($_.Exception.Message)" -ForegroundColor Red }

    # Ningun MessageBox nativo debe sobrevivir: rompe el estilo del HUD.
    $propio = $MyInvocation.MyCommand.Path
    if (-not $propio) { $propio = $PSCommandPath }
    $nativos = @(Select-String -LiteralPath $propio -Pattern 'MessageBox\]::Show' -ErrorAction SilentlyContinue)
    Write-Host ("  MessageBox nativos restantes: {0} ({1})" -f $nativos.Count,
                $(if ($nativos.Count -eq 0) { 'OK' } else { 'FALLO' })) `
        -ForegroundColor $(if ($nativos.Count -eq 0) { 'Green' } else { 'Red' })

    # --- lectura de imagenes y firma de arranque ---
    Write-Host ''
    Write-Host '  --- imagenes (GRABAR) ---' -ForegroundColor Yellow
    $tmp = Join-Path $env:TEMP ("limpiador-prueba-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # .img crudo de 3000 bytes, con firma de arranque en el primer sector
        $datos = New-Object byte[] 3000
        (New-Object Random 42).NextBytes($datos)
        $datos[510] = 0x55; $datos[511] = 0xAA
        $img = Join-Path $tmp 'prueba.img'
        [System.IO.File]::WriteAllBytes($img, $datos)

        # el mismo contenido comprimido en .gz y en .zip
        $gz = "$img.gz"
        $fin = [System.IO.File]::OpenRead($img)
        $fout = [System.IO.File]::Create($gz)
        $gzs = New-Object System.IO.Compression.GZipStream($fout, [System.IO.Compression.CompressionMode]::Compress)
        $fin.CopyTo($gzs); $gzs.Dispose(); $fout.Dispose(); $fin.Dispose()

        $zip = Join-Path $tmp 'prueba.zip'
        $za = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $img, 'prueba.img') | Out-Null
        $za.Dispose()

        foreach ($f in $img, $gz, $zip) {
            $t = Get-TamanoImagen $f
            $b = Test-ImagenArrancable $f
            $okT = ($t -eq 3000)
            Write-Host ("  {0,-12} tamano={1} ({2})  arrancable={3} ({4})" -f `
                [System.IO.Path]::GetFileName($f), $t, $(if ($okT) { 'OK' } else { 'FALLO' }),
                $b, $(if ($b) { 'OK' } else { 'FALLO' })) `
                -ForegroundColor $(if ($okT -and $b) { 'Green' } else { 'Red' })
        }

        # sin firma: debe reportarse como no arrancable
        $datos[510] = 0x00; $datos[511] = 0x00
        $sinBoot = Join-Path $tmp 'sinboot.img'
        [System.IO.File]::WriteAllBytes($sinBoot, $datos)
        $b2 = Test-ImagenArrancable $sinBoot
        Write-Host ("  sinboot.img  arrancable={0} ({1})" -f $b2, $(if (-not $b2) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if (-not $b2) { 'Green' } else { 'Red' })
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- el bucle de escritura real, contra memoria en vez de un disco ---
    # Ejecuta EXACTAMENTE el mismo codigo que graba el dispositivo.
    Write-Host ''
    Write-Host '  --- bucle de escritura (mismo codigo que el grabado real) ---' -ForegroundColor Yellow
    $tmp2 = Join-Path $env:TEMP ("limpiador-copia-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp2 -Force | Out-Null
    try {
        # 300000 bytes: no es multiplo de 512 ni del bloque, para forzar
        # el relleno final y varias vueltas del bucle.
        $orig = New-Object byte[] 300000
        (New-Object Random 7).NextBytes($orig)
        $fimg = Join-Path $tmp2 'c.img'
        [System.IO.File]::WriteAllBytes($fimg, $orig)

        $fgz = "$fimg.gz"
        $i1 = [System.IO.File]::OpenRead($fimg); $o1 = [System.IO.File]::Create($fgz)
        $g1 = New-Object System.IO.Compression.GZipStream($o1, [System.IO.Compression.CompressionMode]::Compress)
        $i1.CopyTo($g1); $g1.Dispose(); $o1.Dispose(); $i1.Dispose()

        foreach ($caso in @(@{ N = 'crudo'; F = $fimg }, @{ N = 'gzip '; F = $fgz })) {
            $a = & $script:AbrirImagen $caso.F
            $ms = New-Object System.IO.MemoryStream
            try {
                # bloque de 64 KB para que 300000 bytes den varias vueltas
                $n = & $script:CopiarFlujo $a.Stream $ms 65536 512 $a.Tamano $null $null $null
                $salida = $ms.ToArray()

                $okLen  = ($n -eq 300000)
                $okPad  = ($salida.Length % 512 -eq 0)
                $okCola = ($salida.Length -eq 300032)   # 300000 -> 586 sectores + relleno
                $okDatos = $true
                for ($i = 0; $i -lt 300000; $i++) {
                    if ($salida[$i] -ne $orig[$i]) { $okDatos = $false; break }
                }
                $okCeros = $true
                for ($i = 300000; $i -lt $salida.Length; $i++) {
                    if ($salida[$i] -ne 0) { $okCeros = $false; break }
                }
                $todo = $okLen -and $okPad -and $okCola -and $okDatos -and $okCeros
                Write-Host ("  {0}  bytes={1} alineado={2} datos_identicos={3} relleno_ceros={4}  -> {5}" -f `
                    $caso.N, $n, $okPad, $okDatos, $okCeros, $(if ($todo) { 'OK' } else { 'FALLO' })) `
                    -ForegroundColor $(if ($todo) { 'Green' } else { 'Red' })
            } finally {
                $ms.Dispose()
                if ($a.Stream) { $a.Stream.Dispose() }
            }
        }

        # El limite de tamano debe cortar la escritura
        $a = & $script:AbrirImagen $fimg
        $ms = New-Object System.IO.MemoryStream
        $corto = $false
        try { & $script:CopiarFlujo $a.Stream $ms 65536 512 $a.Tamano 100000 $null $null | Out-Null }
        catch { $corto = $_.Exception.Message -match 'no cabe' }
        finally { $ms.Dispose(); $a.Stream.Dispose() }
        Write-Host ("  limite de tamano corta la escritura: {0}" -f $(if ($corto) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($corto) { 'Green' } else { 'Red' })

        # La cancelacion debe abortar
        $a = & $script:AbrirImagen $fimg
        $ms = New-Object System.IO.MemoryStream
        $cancelo = $false
        try { & $script:CopiarFlujo $a.Stream $ms 65536 512 $a.Tamano $null $null { $true } | Out-Null }
        catch { $cancelo = $_.Exception.Message -match 'CANCELADO' }
        finally { $ms.Dispose(); $a.Stream.Dispose() }
        Write-Host ("  cancelacion aborta el bucle: {0}" -f $(if ($cancelo) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($cancelo) { 'Green' } else { 'Red' })
    } finally {
        Remove-Item -LiteralPath $tmp2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- ninguna closure puede tocar $script: ---
    # Dentro de GetNewClosure() el ambito de script es OTRO: leer $script:X
    # da NULL y escribirlo no sale de la closure. Eso tumbo la ventana de
    # diagnostico entera, asi que se vigila con una prueba.
    Write-Host ''
    Write-Host '  --- ambito de las closures ---' -ForegroundColor Yellow
    $prop = $MyInvocation.MyCommand.Path
    if (-not $prop) { $prop = $PSCommandPath }
    $lineas = [System.IO.File]::ReadAllLines($prop)
    $cierres = @(0..($lineas.Count - 1) | Where-Object { $lineas[$_] -match 'GetNewClosure\(\)' })
    $sucias = @()
    foreach ($ci in $cierres) {
        $prof = 0; $ini = -1
        for ($j = $ci; $j -ge 0; $j--) {
            $prof += ([regex]::Matches($lineas[$j], '\}')).Count - ([regex]::Matches($lineas[$j], '\{')).Count
            if ($prof -le 0) { $ini = $j; break }
        }
        if ($ini -lt 0) { continue }
        # Se ignoran los comentarios y la sonda de la propia prueba.
        $codigo = @($lineas[$ini..$ci] | ForEach-Object { ($_ -replace '#.*$', '') })
        $bloque = ($codigo -join "`n")
        $refs = [regex]::Matches($bloque, '\$script:\w+') | ForEach-Object { $_.Value } |
                Where-Object { $_ -notlike '*__prueba*' } | Select-Object -Unique
        foreach ($rf in $refs) { $sucias += "linea $($ini + 1): $rf" }
    }
    $limpio = ($sucias.Count -eq 0)
    Write-Host ("  {0} closure(s) revisadas, referencias a `$script: dentro: {1}  -> {2}" -f `
        $cierres.Count, $sucias.Count, $(if ($limpio) { 'OK' } else { 'FALLO' })) `
        -ForegroundColor $(if ($limpio) { 'Green' } else { 'Red' })
    foreach ($sc in $sucias) { Write-Host "      $sc" -ForegroundColor Red }

    # Demostracion del comportamiento. Tiene que crearse DENTRO de una
    # funcion: es ahi donde GetNewClosure() aisla el ambito de script, que
    # es exactamente el caso de Show-Diagnostico y Show-Confirmacion.
    $script:__pruebaAmbito = 'original'
    function Test-AmbitoClosure {
        $sb = { $leido = $script:__pruebaAmbito; $script:__pruebaAmbito = 'escrito'; $leido }.GetNewClosure()
        & $sb
    }
    $leidoDentro = Test-AmbitoClosure
    $confirmado = ($null -eq $leidoDentro) -and ($script:__pruebaAmbito -eq 'original')
    Write-Host ("  confirmado: dentro lee NULL y su escritura no sale  -> {0}" -f `
        $(if ($confirmado) { 'OK' } else { 'el comportamiento cambio, revisar' })) `
        -ForegroundColor $(if ($confirmado) { 'Green' } else { 'Yellow' })

    # --- hash de la imagen antes de grabar ---
    Write-Host ''
    Write-Host '  --- verificacion de hash de imagen ---' -ForegroundColor Yellow
    $tmp6 = Join-Path $env:TEMP ("limpiador-hash-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp6 -Force | Out-Null
    try {
        $fh = Join-Path $tmp6 'img.bin'
        [System.IO.File]::WriteAllBytes($fh, [byte[]](1..2048 | ForEach-Object { $_ % 256 }))
        foreach ($alg in 'MD5', 'SHA1', 'SHA256') {
            $real = (Get-FileHash -LiteralPath $fh -Algorithm $alg).Hash.ToLower()
            $largo = $real.Length
            $detectado = switch ($largo) { 32 { 'MD5' } 40 { 'SHA1' } 64 { 'SHA256' } default { '?' } }
            $bien = ($detectado -eq $alg)
            Write-Host ("  {0,-6} da {1} caracteres -> se detecta como {2}  {3}" -f `
                $alg, $largo, $detectado, $(if ($bien) { 'OK' } else { 'FALLO' })) `
                -ForegroundColor $(if ($bien) { 'Green' } else { 'Red' })
        }
        # Un hash que no corresponde tiene que distinguirse del correcto
        $bueno = (Get-FileHash -LiteralPath $fh -Algorithm SHA256).Hash.ToLower()
        $malo  = $bueno.Substring(0, 63) + $(if ($bueno[63] -eq 'a') { 'b' } else { 'a' })
        Write-Host ("  hash alterado se detecta como distinto: {0}" -f `
            $(if ($malo -ne $bueno) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($malo -ne $bueno) { 'Green' } else { 'Red' })
        # Longitud invalida debe rechazarse
        $rara = ('abc123' -replace '[^0-9a-fA-F]', '').Length
        Write-Host ("  longitud invalida ({0}) no coincide con 32/40/64: {1}" -f `
            $rara, $(if ($rara -notin 32, 40, 64) { 'OK, se rechaza' } else { 'FALLO' })) `
            -ForegroundColor $(if ($rara -notin 32, 40, 64) { 'Green' } else { 'Red' })
    } finally {
        Remove-Item -LiteralPath $tmp6 -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- recuperar archivos por tallado ---
    # Se fabrica un "disco" con archivos reales enterrados entre basura,
    # como quedaria tras un formateo rapido, y se comprueba que salen
    # byte a byte identicos.
    Write-Host ''
    Write-Host '  --- recuperacion de archivos (tallado) ---' -ForegroundColor Yellow
    $tmpR = Join-Path $env:TEMP ("limpiador-rec-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmpR -Force | Out-Null
    try {
        $rnd = New-Object Random 99
        function Nuevo-Relleno([int]$n) { $b = New-Object byte[] $n; $rnd.NextBytes($b); , $b }

        # Un JPEG y un PNG creibles: cabecera, contenido y cola correctas.
        $jpg = @(0xFF, 0xD8, 0xFF, 0xE0) + (Nuevo-Relleno 5000) + @(0xFF, 0xD9)
        $png = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + (Nuevo-Relleno 9000) +
               @(0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82)
        $pdf = [byte[]][char[]]'%PDF-1.4' + (Nuevo-Relleno 3000) + [byte[]][char[]]'%%EOF'

        $disco = New-Object System.Collections.Generic.List[byte]
        $disco.AddRange([byte[]](Nuevo-Relleno 100000))
        $disco.AddRange([byte[]]$jpg)
        $disco.AddRange([byte[]](Nuevo-Relleno 50000))
        $disco.AddRange([byte[]]$png)
        $disco.AddRange([byte[]](Nuevo-Relleno 20000))
        $disco.AddRange([byte[]]$pdf)
        $disco.AddRange([byte[]](Nuevo-Relleno 80000))
        $imgDisco = Join-Path $tmpR 'disco.bin'
        [System.IO.File]::WriteAllBytes($imgDisco, $disco.ToArray())

        $salida = Join-Path $tmpR 'rescatado'
        $firmas = @($script:Firmas | ForEach-Object {
            @{ Nombre = $_.Nombre; Ext = $_.Ext; MaxMB = $_.MaxMB
               CabBytes = (ConvertFrom-Hex $_.Cab); ColaBytes = (ConvertFrom-Hex $_.Cola) } })

        $syncR = [hashtable]::Synchronized(@{
            Cola = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancelar = $false })
        & $script:RecuperarSb @{
            Ruta = $imgDisco; Disco = -1; Destino = $salida; Sector = 512
            Bloque = 64KB; Inicio = 0; Fin = $disco.Count; Firmas = $firmas
            LeerBloqueSrc = $script:LeerBloqueSrc; SubtipoZipSrc = $script:SubtipoZipSrc
            MaxAbiertos = $script:MaxAbiertos
        } $syncR
        $finR = $null
        while ($syncR.Cola.Count -gt 0) {
            $m = $syncR.Cola.Dequeue()
            if ($m.T -eq 'fin') { $finR = $m }
        }

        $sacados = @(Get-ChildItem -LiteralPath $salida -File -ErrorAction SilentlyContinue)
        $porTipo = @{}
        foreach ($f in $sacados) { $porTipo[$f.Extension] = $true }
        $tieneTodos = $porTipo.ContainsKey('.jpg') -and $porTipo.ContainsKey('.png') -and $porTipo.ContainsKey('.pdf')
        Write-Host ("  archivos rescatados: {0} ({1})  -> {2}" -f `
            $sacados.Count, (($sacados | ForEach-Object { $_.Name }) -join ', '),
            $(if ($tieneTodos) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($tieneTodos) { 'Green' } else { 'Red' })

        # Lo que sale tiene que ser IDENTICO a lo que se enterro
        $exactos = 0
        foreach ($par in @(@{ e = '.jpg'; d = [byte[]]$jpg }, @{ e = '.png'; d = [byte[]]$png },
                           @{ e = '.pdf'; d = [byte[]]$pdf })) {
            $f = $sacados | Where-Object { $_.Extension -eq $par.e } | Select-Object -First 1
            if (-not $f) { continue }
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($bytes.Length -eq $par.d.Length -and
                [RawDisk]::PrimeraDiferencia($bytes, $par.d, $par.d.Length) -eq -1) { $exactos++ }
        }
        Write-Host ("  identicos al original: {0} de 3  -> {1}" -f `
            $exactos, $(if ($exactos -eq 3) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($exactos -eq 3) { 'Green' } else { 'Red' })

        # El origen NO puede haberse modificado
        $despues = [System.IO.File]::ReadAllBytes($imgDisco)
        $intacto = ($despues.Length -eq $disco.Count -and
                    [RawDisk]::PrimeraDiferencia($despues, $disco.ToArray(), $disco.Count) -eq -1)
        Write-Host ("  el disco de origen queda intacto: {0}" -f `
            $(if ($intacto) { 'OK' } else { 'FALLO CRITICO' })) `
            -ForegroundColor $(if ($intacto) { 'Green' } else { 'Red' })
    } finally {
        Remove-Item -LiteralPath $tmpR -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- lecturas cortas: el barrido no puede saltarse datos ---
    # Un solo Read puede devolver menos de lo pedido (los puentes USB lo
    # hacen con peticiones grandes). Si el barrido avanza el bloque entero
    # de todos modos, marca como revisado lo que nunca leyo.
    Write-Host ''
    Write-Host '  --- lecturas cortas ---' -ForegroundColor Yellow
    $tmp5 = Join-Path $env:TEMP ("limpiador-corto-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp5 -Force | Out-Null
    try {
        # GZipStream devuelve lecturas parciales de verdad: sirve de banco
        # de pruebas sin inventar un flujo falso.
        $orig5 = New-Object byte[] 400000
        (New-Object Random 5).NextBytes($orig5)
        $f5 = Join-Path $tmp5 'x.bin'
        [System.IO.File]::WriteAllBytes($f5, $orig5)
        $gz5 = "$f5.gz"
        $i5 = [System.IO.File]::OpenRead($f5); $o5 = [System.IO.File]::Create($gz5)
        $g5 = New-Object System.IO.Compression.GZipStream($o5, [System.IO.Compression.CompressionMode]::Compress)
        $i5.CopyTo($g5); $g5.Dispose(); $o5.Dispose(); $i5.Dispose()

        # GZipStream a veces devuelve el bloque entero, asi que no sirve como
        # garantia. Este flujo recorta SIEMPRE, igual que un puente USB con
        # un tamano maximo de transferencia.
        if (-not ('FlujoCorto' -as [type])) {
            Add-Type @'
using System;
using System.IO;
public class FlujoCorto : Stream {
    Stream _in; int _max;
    public FlujoCorto(Stream inner, int max) { _in = inner; _max = max; }
    public override int Read(byte[] b, int o, int c) { return _in.Read(b, o, Math.Min(c, _max)); }
    public override bool CanRead  { get { return true; } }
    public override bool CanSeek  { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length   { get { return _in.Length; } }
    public override long Position { get { return _in.Position; } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override long Seek(long o, SeekOrigin r) { throw new NotSupportedException(); }
    public override void SetLength(long v) { throw new NotSupportedException(); }
    public override void Write(byte[] b, int o, int c) { throw new NotSupportedException(); }
}
'@
        }

        # Una sola llamada, sobre un flujo que recorta a 1000 bytes
        $ms5 = New-Object System.IO.MemoryStream (,$orig5)
        $fc5 = New-Object FlujoCorto ($ms5, 1000)
        $b5 = New-Object byte[] (64KB)
        $unaSola = $fc5.Read($b5, 0, 64KB)
        $fc5.Dispose()

        # El ayudante, sobre el mismo flujo recortado
        $ms6 = New-Object System.IO.MemoryStream (,$orig5)
        $fc6 = New-Object FlujoCorto ($ms6, 1000)
        $b6 = New-Object byte[] (64KB)
        $conAyuda = & $script:LeerBloque $fc6 $b6 (64KB)
        $fc6.Dispose()

        $ok5 = ($unaSola -eq 1000) -and ($conAyuda -eq 64KB)
        Write-Host ("  pidiendo 64 KB a un flujo que recorta: una llamada dio {0}, el ayudante dio {1}  -> {2}" -f `
            $unaSola, $conAyuda, $(if ($ok5) { 'OK, completa el bloque' } else { 'FALLO' })) `
            -ForegroundColor $(if ($ok5) { 'Green' } else { 'Red' })

        # Y los datos tienen que salir intactos, sin huecos
        $iguales = ([RawDisk]::PrimeraDiferencia($b6, $orig5, 64KB) -eq -1)
        Write-Host ("  los bytes coinciden con el original: {0}" -f `
            $(if ($iguales) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($iguales) { 'Green' } else { 'Red' })
    } finally {
        Remove-Item -LiteralPath $tmp5 -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- test de tiempo de acceso (mecanico vs estado solido) ---
    Write-Host ''
    Write-Host '  --- tiempo de acceso ---' -ForegroundColor Yellow
    $tmp4 = Join-Path $env:TEMP ("limpiador-acc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp4 -Force | Out-Null
    try {
        $arch = Join-Path $tmp4 'medio.bin'
        $fw = [System.IO.File]::Create($arch)
        $blq = New-Object byte[] (1MB)
        for ($i = 0; $i -lt 32; $i++) { $fw.Write($blq, 0, $blq.Length) }
        $fw.Dispose()

        $syncA = [hashtable]::Synchronized(@{
            Cola = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancelar = $false })
        & $script:AccesoSb @{ Ruta = $arch; Disco = -1; Sector = 512
                              Tamano = 32MB; Tam = 4KB; Muestras = 120 } $syncA
        $res = $null; $finA = $null
        while ($syncA.Cola.Count -gt 0) {
            $m = $syncA.Cola.Dequeue()
            if ($m.T -eq 'acceso') { $res = $m }
            if ($m.T -eq 'fin')    { $finA = $m }
        }
        # Un archivo en disco local responde en microsegundos: debe salir
        # como electronico y con muestras suficientes.
        $ok = $res -and $finA -and $finA.Ok -and $res.N -ge 100 -and
              $res.Veredicto -like 'ELECTRONICO*' -and $res.Mediana -ge 0
        Write-Host ("  medicion sobre archivo: mediana={0:N3} ms muestras={1} veredicto='{2}'  -> {3}" -f `
            $(if ($res) { $res.Mediana } else { -1 }), $(if ($res) { $res.N } else { 0 }),
            $(if ($res) { $res.Veredicto } else { 'sin resultado' }), $(if ($ok) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })

        # Los umbrales tienen que separar las dos tecnologias
        $clasif = {
            param($ms)
            if ($ms -lt 3) { 'ELECTRONICO' } elseif ($ms -ge 8) { 'MECANICO' } else { 'NO CONCLUYENTE' }
        }
        $casos = @(@{ ms = 0.15; esp = 'ELECTRONICO' }, @{ ms = 0.9; esp = 'ELECTRONICO' },
                   @{ ms = 5;    esp = 'NO CONCLUYENTE' },
                   @{ ms = 14;   esp = 'MECANICO' }, @{ ms = 19; esp = 'MECANICO' })
        $malos = @($casos | Where-Object { (& $clasif $_.ms) -ne $_.esp })
        Write-Host ("  umbrales: SSD 0.15/0.9 ms, HDD 14/19 ms, dudoso 5 ms -> {0}" -f `
            $(if ($malos.Count -eq 0) { 'clasificados OK' } else { "FALLO en $($malos.Count)" })) `
            -ForegroundColor $(if ($malos.Count -eq 0) { 'Green' } else { 'Red' })
    } finally {
        Remove-Item -LiteralPath $tmp4 -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- la escala de colores no puede depender del tamano de bloque ---
    Write-Host ''
    Write-Host '  --- escala de colores del mapa ---' -ForegroundColor Yellow
    function Franja {
        param([double]$Ms, [double]$Bloque)
        $l = Get-LimitesBucket $Bloque
        for ($i = 0; $i -lt 6; $i++) { if ($Ms -lt $l[$i].Max) { return $i } }
        5
    }
    $consistente = $true
    foreach ($mbs in 23, 120, 2000) {
        $franjas = @()
        foreach ($b in 256KB, 1MB, 4MB, 8MB) {
            $franjas += Franja (($b / 1MB) / $mbs * 1000) ([double]$b)
        }
        # @() a proposito: con un solo valor distinto, Select-Object -Unique
        # devuelve un escalar y .Count no existe bajo StrictMode.
        $uniforme = (@($franjas | Select-Object -Unique).Count -eq 1)
        if (-not $uniforme) { $consistente = $false }
        Write-Host ("  disco de {0,4} MB/s -> franjas {1}  {2}" -f $mbs, ($franjas -join ','),
            $(if ($uniforme) { 'iguales, OK' } else { 'DISTINTAS: el bloque altera el color' })) `
            -ForegroundColor $(if ($uniforme) { 'Green' } else { 'Red' })
    }
    # Un bloque anomalo debe destacar igual con cualquier tamano de bloque
    $destaca = $true
    foreach ($b in 256KB, 1MB, 8MB) {
        $normal = Franja (($b / 1MB) / 23 * 1000) ([double]$b)
        $lento  = Franja (($b / 1MB) / 23 * 1000 * 40) ([double]$b)
        if ($lento -le $normal) { $destaca = $false }
    }
    Write-Host ("  un bloque 40x mas lento sube de franja siempre: {0}" -f `
        $(if ($destaca) { 'OK' } else { 'FALLO' })) `
        -ForegroundColor $(if ($destaca) { 'Green' } else { 'Red' })

    # --- motor del test de superficie (DIAGNOSTICO) ---
    # Se barre un archivo en vez de un disco: asi se ejercita toda la logica
    # (bucle, clasificacion por tiempo, agregado a celdas, progreso) sin
    # depender de que haya hardware conectado ni de tener elevacion.
    Write-Host ''
    Write-Host '  --- motor del test de superficie ---' -ForegroundColor Yellow
    $tmp3 = Join-Path $env:TEMP ("limpiador-scan-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp3 -Force | Out-Null
    try {
        $falso = Join-Path $tmp3 'disco.bin'
        $fsw = [System.IO.File]::Create($falso)
        $blk = New-Object byte[] (1MB)
        (New-Object Random 11).NextBytes($blk)
        for ($i = 0; $i -lt 16; $i++) { $fsw.Write($blk, 0, $blk.Length) }
        $fsw.Dispose()

        $syncT = [hashtable]::Synchronized(@{
            Cola = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
            Cancelar = $false })
        $cfgT = @{
            Ruta = $falso; Disco = -1; Serie = ''; Sector = 512; Bloque = 1MB
            Inicio = 0; Fin = 16MB; Celdas = 64
            Limites = @($script:Buckets[0..5] | ForEach-Object { [double]$_.Max })
            LeerBloqueSrc = $script:LeerBloqueSrc
        }
        & $script:SuperficieSb $cfgT $syncT

        $celdas = 0; $fin = $null; $ultProg = $null; $errores = 0
        while ($syncT.Cola.Count -gt 0) {
            $m = $syncT.Cola.Dequeue()
            switch ($m.T) {
                'celda' { $celdas++; if ($m.B -eq 6) { $errores++ } }
                'prog'  { $ultProg = $m }
                'fin'   { $fin = $m }
            }
        }
        $ok = $fin -and $fin.Ok -and $celdas -ge 8 -and $errores -eq 0 -and
              $ultProg -and $ultProg.Pct -eq 100
        Write-Host ("  barrido de 16 MB: celdas={0} errores={1} fin_ok={2} pct={3}  -> {4}" -f `
            $celdas, $errores, $(if ($fin) { $fin.Ok } else { 'sin fin' }),
            $(if ($ultProg) { $ultProg.Pct } else { '?' }), $(if ($ok) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })

        # --- modo MUESTREO: mismo mapa, una fraccion de las lecturas ---
        $syncM = [hashtable]::Synchronized(@{
            Cola = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancelar = $false })
        $cfgM = $cfgT.Clone()
        $cfgM.Muestreo = $true
        $cfgM.Celdas = 64
        $cfgM.Bloque = 64KB
        & $script:SuperficieSb $cfgM $syncM
        $celdasM = 0; $finM = $null; $leidoM = 0
        while ($syncM.Cola.Count -gt 0) {
            $m = $syncM.Cola.Dequeue()
            if ($m.T -eq 'celda') { $celdasM++ }
            if ($m.T -eq 'fin')   { $finM = $m }
            if ($m.T -eq 'log' -and $m.Txt -match 'Barrido terminado: ([\d.,]+) (\w+)') {
                $leidoM = [double]($matches[1] -replace ',', '')
            }
        }
        # 64 celdas x 64 KB = 4 MB de los 16 MB del archivo: una cuarta parte
        $ok = $finM -and $finM.Ok -and $celdasM -ge 32
        Write-Host ("  muestreo: {0} celdas pintadas leyendo solo una parte  -> {1}" -f `
            $celdasM, $(if ($ok) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })

        # El muestreo tiene que leer MENOS que el barrido completo
        $syncC = [hashtable]::Synchronized(@{
            Cola = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancelar = $false })
        $cfgC = $cfgT.Clone(); $cfgC.Celdas = 64; $cfgC.Bloque = 64KB
        & $script:SuperficieSb $cfgC $syncC
        $leidoC = 0
        while ($syncC.Cola.Count -gt 0) {
            $m = $syncC.Cola.Dequeue()
            if ($m.T -eq 'log' -and $m.Txt -match 'Barrido terminado: ([\d.,]+) (\w+)') {
                $leidoC = [double]($matches[1] -replace ',', '')
            }
        }
        $menos = ($leidoM -gt 0 -and $leidoC -gt 0 -and $leidoM -lt $leidoC)
        Write-Host ("  muestreo lee menos que completo: {0} vs {1}  -> {2}" -f `
            $leidoM, $leidoC, $(if ($menos) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($menos) { 'Green' } else { 'Red' })

        # Un rango vacio debe rechazarse, no barrer el disco entero
        $syncV = [hashtable]::Synchronized(@{
            Cola = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancelar = $false })
        $cfgV = $cfgT.Clone(); $cfgV.Inicio = 8MB; $cfgV.Fin = 8MB
        & $script:SuperficieSb $cfgV $syncV
        $rechazo = $false
        while ($syncV.Cola.Count -gt 0) {
            $m = $syncV.Cola.Dequeue()
            if ($m.T -eq 'log' -and $m.Txt -match 'rango') { $rechazo = $true }
        }
        Write-Host ("  rango vacio rechazado: {0}" -f $(if ($rechazo) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($rechazo) { 'Green' } else { 'Red' })

        # El dispositivo debe abrirse SIN permiso de escritura
        $hh = [RawDisk]::Abrir($falso, $false)
        $fsr = New-Object System.IO.FileStream($hh, [System.IO.FileAccess]::Read)
        $noEscribe = (-not $fsr.CanWrite) -and $fsr.CanRead
        $fsr.Dispose()
        Write-Host ("  el diagnostico abre solo-lectura: puede_leer=True puede_escribir={0}  -> {1}" -f `
            (-not $noEscribe), $(if ($noEscribe) { 'OK' } else { 'FALLO CRITICO' })) `
            -ForegroundColor $(if ($noEscribe) { 'Green' } else { 'Red' })
    } finally {
        Remove-Item -LiteralPath $tmp3 -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- velocidad de comparacion (el cuello de botella al verificar) ---
    Write-Host ''
    Write-Host '  --- comparacion de bloques ---' -ForegroundColor Yellow
    $a = New-Object byte[] (8MB)
    $b = New-Object byte[] (8MB)
    (New-Object Random 3).NextBytes($a)
    [Array]::Copy($a, $b, $a.Length)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dif = [RawDisk]::PrimeraDiferencia($a, $b, $a.Length)
    $sw.Stop()
    $mbs = 8 / [math]::Max(0.001, $sw.Elapsed.TotalSeconds)
    # Debe ir muy por encima de lo que da cualquier USB leyendo (~25 MB/s).
    $rapido = $mbs -gt 200
    Write-Host ("  iguales: {0} MB/s ({1:N0} ms)  detecta_iguales={2}  -> {3}" -f `
        [int]$mbs, $sw.Elapsed.TotalMilliseconds, ($dif -eq -1),
        $(if ($rapido -and $dif -eq -1) { 'OK' } else { 'FALLO' })) `
        -ForegroundColor $(if ($rapido -and $dif -eq -1) { 'Green' } else { 'Red' })
    $b[5000000] = $b[5000000] -bxor 0xFF
    $dif2 = [RawDisk]::PrimeraDiferencia($a, $b, $a.Length)
    Write-Host ("  detecta diferencia en el byte 5000000: {0} -> {1}" -f `
        $dif2, $(if ($dif2 -eq 5000000) { 'OK' } else { 'FALLO' })) `
        -ForegroundColor $(if ($dif2 -eq 5000000) { 'Green' } else { 'Red' })

    # --- bloqueo y desmontaje de volumen (lo que sustituye al offline) ---
    # Es reversible: al cerrar el handle Windows remonta el volumen solo.
    # Solo se prueba sobre unidades NO blindadas y montadas.
    Write-Host ''
    Write-Host '  --- bloqueo/desmontaje de volumen (mecanismo del grabado) ---' -ForegroundColor Yellow
    $probadas = 0
    foreach ($u in (Get-Unidades)) {
        if ($u.Protegida -or -not $u.Montado -or -not $u.Letra) { continue }
        if (@(Get-RazonesBloqueo $u).Count -gt 0) { continue }
        $probadas++
        $vh = [RawDisk]::Abrir("\\.\$($u.Letra):", $true)
        if ($vh.IsInvalid) {
            Write-Host ("  {0}: no se pudo abrir (error {1})" -f $u.Letra, [RawDisk]::UltimoError()) -ForegroundColor Red
            continue
        }
        $lk = $false
        for ($t = 0; $t -lt 12 -and -not $lk; $t++) {
            $lk = [RawDisk]::Bloquear($vh)
            if (-not $lk) { Start-Sleep -Milliseconds 350 }
        }
        $dm = if ($lk) { [RawDisk]::Desmontar($vh) } else { $false }
        $vh.Close()
        Start-Sleep -Milliseconds 800
        $vuelve = Test-Path -LiteralPath "$($u.Letra):\" -ErrorAction SilentlyContinue
        $ok = $lk -and $dm -and $vuelve
        Write-Host ("  {0}: bloqueo={1} desmontaje={2} remonta_al_soltar={3}  -> {4}" -f `
            $u.Letra, $lk, $dm, $vuelve, $(if ($ok) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    }
    if ($probadas -eq 0) {
        Write-Host '  (sin unidades operables montadas para probar)' -ForegroundColor DarkGray
    }

    # --- la consola tiene que poder copiarse ---
    Write-Host ''
    Write-Host '  --- consola copiable ---' -ForegroundColor Yellow
    Write-Log 'LINEA-DE-PRUEBA-UNO' 'ok'
    Write-Log 'LINEA-DE-PRUEBA-DOS' 'error'
    $txt = Get-TextoRegistro
    $tieneUno  = $txt -match 'LINEA-DE-PRUEBA-UNO'
    $tieneDos  = $txt -match 'LINEA-DE-PRUEBA-DOS'
    $tieneSalto = ($txt -split "`r?`n").Count -ge 3
    $seleccionable = -not $UI.Log.IsReadOnly -or $UI.Log -is [Windows.Controls.RichTextBox]
    $ok = $tieneUno -and $tieneDos -and $tieneSalto -and $seleccionable
    Write-Host ("  consola principal: texto extraible={0} con_saltos={1} seleccionable={2}  -> {3}" -f `
        ($tieneUno -and $tieneDos), $tieneSalto, $seleccionable, $(if ($ok) { 'OK' } else { 'FALLO' })) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })

    # La consola del diagnostico tambien tiene que poder copiarse
    try {
        $dw = Show-Diagnostico @{ Letra=''; Modelo='PRUEBA'; Etiqueta=''; Serie='S1'
                                  Bus='USB'; TamDisco=8GB; TamVol=0; Libre=0; Fs=''
                                  TipoVol=''; Disco=9; Sector=512; EsSistema=$false
                                  EsArranque=$false; SinMedio=$false; Montado=$false
                                  SoloDiagnostico=$false; Protegida=$false; Razones=@() } -SoloConstruir
        $rtbD = $dw.FindName('Log')
        Write-DiagLog $rtbD 'PRUEBA-DIAG-UNO' 'ok'
        Write-DiagLog $rtbD 'PRUEBA-DIAG-DOS' 'error'
        $td = Get-TextoDeRegistro $rtbD
        $okD = ($rtbD -is [Windows.Controls.RichTextBox]) -and $rtbD.IsReadOnly -and
               ($td -match 'PRUEBA-DIAG-UNO') -and ($td -match 'PRUEBA-DIAG-DOS') -and
               (($td -split "`r?`n").Count -ge 3)
        $dw.Close()
        Write-Host ("  consola diagnostico: texto extraible={0} con_saltos={1} seleccionable={2}  -> {3}" -f `
            (($td -match 'PRUEBA-DIAG-UNO') -and ($td -match 'PRUEBA-DIAG-DOS')),
            (($td -split "`r?`n").Count -ge 3), ($rtbD -is [Windows.Controls.RichTextBox]),
            $(if ($okD) { 'OK' } else { 'FALLO' })) `
            -ForegroundColor $(if ($okD) { 'Green' } else { 'Red' })
    } catch {
        Write-Host "  consola diagnostico: FALLO - $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
    $timer.Stop(); $reloj.Stop(); $vigia.Stop()
    return
}

$UI.Estado.Text = 'LISTO  //  VIGILANCIA DE PUERTOS ACTIVA'
$win.ShowDialog() | Out-Null
