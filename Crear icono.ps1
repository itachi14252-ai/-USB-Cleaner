#Requires -Version 5.1
<#
    Genera limpiador.ico con el lenguaje visual del programa:
    fondo negro, marco dorado con esquinas cortadas, corchetes de mira
    y las tres barras rojas '///' que son la firma de la interfaz.

    Se dibuja a varios tamanos porque Windows usa uno u otro segun el
    sitio (16 px en la barra de titulo, 256 px en vista de iconos
    grandes). A 16 px los corchetes desaparecen: solo sobreviven el
    marco y las barras.
#>
[CmdletBinding()]
param([string]$Salida)

Add-Type -AssemblyName System.Drawing

if (-not $Salida) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $Salida = Join-Path $base 'limpiador.ico'
}

$NEGRO = [System.Drawing.Color]::FromArgb(255, 10, 10, 12)
$ORO   = [System.Drawing.Color]::FromArgb(255, 201, 162, 39)
$ROJO  = [System.Drawing.Color]::FromArgb(255, 229, 55, 47)

function New-Lienzo {
    param([int]$S)

    $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $m = [math]::Max(1.0, $S * 0.045)        # margen exterior
    $c = [math]::Max(2.0, $S * 0.20)         # corte de las esquinas
    $x0 = $m; $x1 = $S - $m
    $y0 = $m; $y1 = $S - $m

    # Cuerpo con las esquinas superior-izquierda e inferior-derecha cortadas
    $cuerpo = New-Object System.Drawing.Drawing2D.GraphicsPath
    $pts = @(
        (New-Object System.Drawing.PointF(($x0 + $c), $y0)),
        (New-Object System.Drawing.PointF($x1, $y0)),
        (New-Object System.Drawing.PointF($x1, ($y1 - $c))),
        (New-Object System.Drawing.PointF(($x1 - $c), $y1)),
        (New-Object System.Drawing.PointF($x0, $y1)),
        (New-Object System.Drawing.PointF($x0, ($y0 + $c)))
    )
    $cuerpo.AddPolygon($pts)

    $brNegro = New-Object System.Drawing.SolidBrush($NEGRO)
    $g.FillPath($brNegro, $cuerpo)

    $grosor = [math]::Max(1.0, $S * 0.035)
    $lapizOro = New-Object System.Drawing.Pen($ORO, $grosor)
    $lapizOro.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Miter
    $g.DrawPath($lapizOro, $cuerpo)

    # Las tres barras rojas: la firma de la interfaz
    $w  = $S * 0.115          # ancho de cada barra
    $gp = $S * 0.075          # hueco entre barras
    $dx = $S * 0.18           # inclinacion
    $yA = $S * 0.74
    $yB = $S * 0.26
    $xIni = $S * 0.155
    $brRojo = New-Object System.Drawing.SolidBrush($ROJO)
    for ($i = 0; $i -lt 3; $i++) {
        $x = $xIni + $i * ($w + $gp)
        $barra = @(
            (New-Object System.Drawing.PointF($x, $yA)),
            (New-Object System.Drawing.PointF(($x + $w), $yA)),
            (New-Object System.Drawing.PointF(($x + $w + $dx), $yB)),
            (New-Object System.Drawing.PointF(($x + $dx), $yB))
        )
        $g.FillPolygon($brRojo, $barra)
    }

    # Corchetes de mira: solo caben a partir de 32 px
    if ($S -ge 32) {
        $L = $S * 0.17
        $gr2 = [math]::Max(1.0, $S * 0.045)
        $lapizB = New-Object System.Drawing.Pen($ORO, $gr2)
        $ix = $m + $S * 0.10
        $iy = $m + $S * 0.10
        # superior derecha
        $g.DrawLine($lapizB, ($x1 - $L), $iy, ($x1 - $S * 0.03), $iy)
        $g.DrawLine($lapizB, ($x1 - $S * 0.03), $iy, ($x1 - $S * 0.03), ($iy + $L))
        # inferior izquierda
        $g.DrawLine($lapizB, ($x0 + $S * 0.03), ($y1 - $L), ($x0 + $S * 0.03), ($y1 - $S * 0.03))
        $g.DrawLine($lapizB, ($x0 + $S * 0.03), ($y1 - $S * 0.03), ($x0 + $L), ($y1 - $S * 0.03))
        $lapizB.Dispose()
    }

    $brNegro.Dispose(); $brRojo.Dispose(); $lapizOro.Dispose()
    $cuerpo.Dispose(); $g.Dispose()
    $bmp
}

# --- ensamblar el .ico ---
# Formato ICO: cabecera de 6 bytes, una entrada de 16 bytes por tamano,
# y despues los datos. Se guardan como PNG, que Windows admite desde Vista.
$tamanos = 16, 24, 32, 48, 64, 128, 256
$pngs = @()
foreach ($s in $tamanos) {
    $bmp = New-Lienzo $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , @{ S = $s; Bytes = $ms.ToArray() }
    $ms.Dispose(); $bmp.Dispose()
}

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0)                    # reservado
$bw.Write([uint16]1)                    # tipo: 1 = icono
$bw.Write([uint16]$pngs.Count)

$offset = 6 + 16 * $pngs.Count
foreach ($p in $pngs) {
    # 256 se escribe como 0 en el campo de tamano
    $bw.Write([byte]$(if ($p.S -ge 256) { 0 } else { $p.S }))
    $bw.Write([byte]$(if ($p.S -ge 256) { 0 } else { $p.S }))
    $bw.Write([byte]0)                   # colores de la paleta
    $bw.Write([byte]0)                   # reservado
    $bw.Write([uint16]1)                 # planos
    $bw.Write([uint16]32)                # bits por pixel
    $bw.Write([uint32]$p.Bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $p.Bytes.Length
}
foreach ($p in $pngs) { $bw.Write($p.Bytes) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($Salida, $out.ToArray())
$bw.Dispose(); $out.Dispose()

"Icono creado: $Salida ({0:N1} KB, tamanos: {1})" -f ((Get-Item $Salida).Length / 1KB), ($tamanos -join ', ')
