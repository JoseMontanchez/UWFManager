param(
    [switch]$Vigilante
)

# =============================================================================
#  UWF Aulas v2 - gestion del Unified Write Filter para las aulas de la UV
#  Modo normal    : interfaz grafica para el tecnico
#  Modo Vigilante : sin interfaz, lo lanza una tarea programada en cada arranque
#
#  Cambios v2:
#   - Corregidos los umbrales del overlay (aviso < critico) y validacion
#   - Pestana Overlay: tipo (RAM/Disco), tamano y umbrales configurables
#   - Exclusiones por programa: detecta lo instalado y propone carpetas/claves
# =============================================================================

$ErrorActionPreference = 'Stop'

$script:Base       = Join-Path $env:ProgramData 'UWF-Aulas'
$script:CfgPath    = Join-Path $script:Base 'config.json'
$script:EstadoPath = Join-Path $script:Base 'estado.json'
$script:PerfilPath = Join-Path $script:Base 'perfil-exclusiones.json'
$script:LogPath    = Join-Path $script:Base 'uwf-aulas.log'
$script:ScriptDest = Join-Path $script:Base 'UWF-Aulas.ps1'
$script:Uwfmgr     = Join-Path $env:SystemRoot 'System32\uwfmgr.exe'
$script:Tarea      = 'UWF-Aulas-Vigilante'

# Rutas que nunca deben excluirse: romperian las actualizaciones de Windows
$script:Prohibidas = @(
    'C:\WINDOWS\SOFTWAREDISTRIBUTION',
    'C:\WINDOWS\WINSXS',
    'C:\WINDOWS\SERVICING',
    'C:\$WINDOWS.~BT',
    'C:\WINDOWS\SYSTEM32\CATROOT2'
)

# -----------------------------------------------------------------------------
#  Catalogo de programas conocidos para exclusiones
#  Patron   : regex contra el nombre del programa instalado
#  Carpetas : patrones glob; se anaden solo las rutas que existan en el equipo
#  Claves   : claves HKLM; se anaden solo las que existan en el equipo
# -----------------------------------------------------------------------------
$script:Catalogo = @(
    @{
        Nombre   = 'Kaspersky (antivirus y agente de red)'
        Patron   = 'Kaspersky'
        Carpetas = @('C:\ProgramData\Kaspersky*', 'C:\ProgramData\KasperskyLab*', 'C:\ProgramData\KL*Agent*')
        Claves   = @('HKLM\SOFTWARE\KasperskyLab', 'HKLM\SOFTWARE\WOW6432Node\KasperskyLab')
    },
    @{
        Nombre   = 'pGina (autenticacion LDAP)'
        Patron   = 'pGina'
        Carpetas = @('C:\Program Files\pGina*', 'C:\Program Files (x86)\pGina*', 'C:\ProgramData\pGina*')
        Claves   = @('HKLM\SOFTWARE\pGina3', 'HKLM\SOFTWARE\WOW6432Node\pGina3')
    },
    @{
        Nombre   = 'Microsoft Defender (definiciones)'
        Patron   = 'Microsoft Defender|Windows Defender'
        Carpetas = @('C:\ProgramData\Microsoft\Windows Defender\Definition Updates')
        Claves   = @()
    },
    @{
        Nombre   = 'ESET (antivirus)'
        Patron   = 'ESET'
        Carpetas = @('C:\ProgramData\ESET')
        Claves   = @('HKLM\SOFTWARE\ESET', 'HKLM\SOFTWARE\WOW6432Node\ESET')
    },
    @{
        Nombre   = 'Sophos (antivirus)'
        Patron   = 'Sophos'
        Carpetas = @('C:\ProgramData\Sophos')
        Claves   = @('HKLM\SOFTWARE\Sophos', 'HKLM\SOFTWARE\WOW6432Node\Sophos')
    }
)

# -----------------------------------------------------------------------------
#  Utilidades
# -----------------------------------------------------------------------------
function Inicializar-Carpeta {
    if (-not (Test-Path -LiteralPath $script:Base)) {
        New-Item -ItemType Directory -Path $script:Base -Force | Out-Null
    }
}

function Escribir-Log {
    param([string]$Accion, [string]$Resultado = 'OK', [string]$Detalle = '')
    Inicializar-Carpeta
    $linea = '{0};{1};{2};{3};{4};{5}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $env:USERNAME, $Accion, $Resultado, $Detalle
    try { Add-Content -LiteralPath $script:LogPath -Value $linea -Encoding UTF8 } catch { }
    try {
        $cfg = Leer-Config
        if ($cfg.rutaLogRed) {
            $destino = Join-Path $cfg.rutaLogRed ('uwf-aulas-' + (Get-Date -Format 'yyyy-MM') + '.csv')
            Add-Content -LiteralPath $destino -Value $linea -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Leer-Config {
    if (Test-Path -LiteralPath $script:CfgPath) {
        try { return (Get-Content -LiteralPath $script:CfgPath -Raw | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ rutaLogRed = ''; horasMaxMantenimiento = 8 }
}

function Guardar-Config($cfg) {
    Inicializar-Carpeta
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8
}

function Leer-Estado {
    if (Test-Path -LiteralPath $script:EstadoPath) {
        try { return (Get-Content -LiteralPath $script:EstadoPath -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Guardar-Estado($fase, $detalle = '') {
    Inicializar-Carpeta
    if (-not $fase) {
        Remove-Item -LiteralPath $script:EstadoPath -Force -ErrorAction SilentlyContinue
        return
    }
    [pscustomobject]@{
        fase    = $fase
        inicio  = (Get-Date).ToString('s')
        tecnico = $env:USERNAME
        equipo  = $env:COMPUTERNAME
        detalle = $detalle
    } | ConvertTo-Json | Set-Content -LiteralPath $script:EstadoPath -Encoding UTF8
}

function Test-Administrador {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-UwfInstalado { Test-Path -LiteralPath $script:Uwfmgr }

function Invoke-Uwf {
    param([string[]]$Argumentos)
    if (-not (Test-UwfInstalado)) { throw 'uwfmgr.exe no esta disponible. Instala primero la caracteristica UWF.' }
    $salida = & $script:Uwfmgr @Argumentos 2>&1
    $codigo = $LASTEXITCODE
    [pscustomobject]@{
        Codigo = $codigo
        Salida = ($salida | Out-String).Trim()
        Ok     = ($codigo -eq 0)
    }
}

# -----------------------------------------------------------------------------
#  Estado del filtro
# -----------------------------------------------------------------------------
function Get-EstadoUwf {
    $r = [pscustomobject]@{
        Instalado        = (Test-UwfInstalado)
        FiltroActual     = $false
        FiltroSiguiente  = $false
        VolumenesActual  = @()
        OverlayTipo      = 'desconocido'
        OverlayMaxMB     = 0
        OverlayAvisoMB   = 0
        OverlayCriticoMB = 0
        OverlayUsoMB     = -1
        Error            = ''
    }
    if (-not $r.Instalado) { return $r }

    try {
        $ns = 'root\standardcimv2\embedded'
        $f  = Get-CimInstance -Namespace $ns -ClassName UWF_Filter -ErrorAction Stop
        $r.FiltroActual    = [bool]$f.CurrentEnabled
        $r.FiltroSiguiente = [bool]$f.NextEnabled

        $vols = Get-CimInstance -Namespace $ns -ClassName UWF_Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.CurrentSession -eq $true -and $_.BindByDriveLetter -eq $true -and $_.ProtectionEnabled -eq $true }
        $r.VolumenesActual = @($vols | ForEach-Object { $_.DriveLetter })

        $oc = Get-CimInstance -Namespace $ns -ClassName UWF_OverlayConfig -ErrorAction SilentlyContinue |
              Where-Object { $_.CurrentSession -eq $true } | Select-Object -First 1
        if ($oc) {
            $r.OverlayTipo  = if ($oc.Type -eq 0) { 'RAM' } elseif ($oc.Type -eq 1) { 'Disco' } else { 'desconocido' }
            $r.OverlayMaxMB = [int]$oc.MaximumSize
        }

        $ov = Get-CimInstance -Namespace $ns -ClassName UWF_Overlay -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ov) {
            $r.OverlayAvisoMB   = [int]$ov.WarningOverlayThreshold
            $r.OverlayCriticoMB = [int]$ov.CriticalOverlayThreshold
            if ($null -ne $ov.OverlayConsumption -and [int]$ov.OverlayConsumption -ge 0) {
                $r.OverlayUsoMB = [int]$ov.OverlayConsumption
            }
        }
    } catch {
        $r.Error = $_.Exception.Message
    }

    if ($r.OverlayUsoMB -lt 0) {
        try {
            $s = (Invoke-Uwf @('overlay','get-consumption')).Salida
            $m = [regex]::Match($s, '(\d+)')
            if ($m.Success) { $r.OverlayUsoMB = [int]$m.Groups[1].Value }
        } catch { }
    }

    return $r
}

# -----------------------------------------------------------------------------
#  Overlay
# -----------------------------------------------------------------------------
function Test-UmbralesValidos([int]$aviso, [int]$critico, [int]$tamano) {
    # Ambos miden consumo acumulado: el aviso debe saltar antes que el critico
    return ($aviso -gt 0 -and $critico -gt $aviso -and $tamano -ge $critico)
}

function Aplicar-Overlay {
    param([string]$Tipo, [int]$TamanoMB, [int]$AvisoMB, [int]$CriticoMB, [bool]$FiltroActivo)

    if (-not (Test-UmbralesValidos $AvisoMB $CriticoMB $TamanoMB)) {
        throw "Umbrales no validos: debe cumplirse aviso < critico <= tamano (has puesto $AvisoMB / $CriticoMB / $TamanoMB MB)."
    }

    $errores = New-Object System.Collections.ArrayList

    # Tipo y tamano solo se pueden cambiar con el filtro desactivado
    if ($FiltroActivo) {
        [void]$errores.Add('El tipo y el tamano del overlay solo se pueden cambiar con la proteccion desactivada. Hazlo durante una ventana de mantenimiento. Los umbrales si se han aplicado.')
    } else {
        $t = if ($Tipo -eq 'Disco') { 'disk' } else { 'ram' }
        $r1 = Invoke-Uwf @('overlay','set-type',$t)
        if (-not $r1.Ok) { [void]$errores.Add("set-type: $($r1.Salida)") }
        $r2 = Invoke-Uwf @('overlay','set-size',"$TamanoMB")
        if (-not $r2.Ok) { [void]$errores.Add("set-size: $($r2.Salida)") }
    }

    $r3 = Invoke-Uwf @('overlay','set-warningthreshold',"$AvisoMB")
    if (-not $r3.Ok) { [void]$errores.Add("set-warningthreshold: $($r3.Salida)") }
    $r4 = Invoke-Uwf @('overlay','set-criticalthreshold',"$CriticoMB")
    if (-not $r4.Ok) { [void]$errores.Add("set-criticalthreshold: $($r4.Salida)") }

    Escribir-Log 'AplicarOverlay' $(if ($errores.Count -eq 0) {'OK'} else {'PARCIAL'}) `
        ("tipo=$Tipo tamano=$TamanoMB aviso=$AvisoMB critico=$CriticoMB")
    return $errores
}

# -----------------------------------------------------------------------------
#  Exclusiones
# -----------------------------------------------------------------------------
function Normalizar-ClaveRegistro([string]$clave) {
    $c = $clave.Trim().TrimEnd('\')
    $c = $c -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    $c = $c -replace '^HKLM:', 'HKLM'
    return $c
}

function Test-ExclusionPeligrosa([string]$ruta) {
    $r = $ruta.ToUpper().TrimEnd('\')
    foreach ($p in $script:Prohibidas) {
        if ($r -eq $p -or $r.StartsWith($p + '\')) { return $true }
    }
    return $false
}

function Get-ExclusionesArchivo {
    $lista = New-Object System.Collections.ArrayList
    try {
        $s = (Invoke-Uwf @('file','get-exclusions','C:')).Salida
        foreach ($linea in ($s -split "`r?`n")) {
            $t = $linea.Trim()
            if ($t -match '^\\' ) { [void]$lista.Add('C:' + $t) }
        }
    } catch { }
    return $lista
}

function Get-ExclusionesRegistro {
    $lista = New-Object System.Collections.ArrayList
    try {
        $s = (Invoke-Uwf @('registry','get-exclusions')).Salida
        foreach ($linea in ($s -split "`r?`n")) {
            $t = $linea.Trim()
            if ($t -match '^(HKLM|HKEY_LOCAL_MACHINE)\\') { [void]$lista.Add((Normalizar-ClaveRegistro $t)) }
        }
    } catch { }
    return $lista
}

function Add-ExclusionArchivo([string]$ruta) {
    if (Test-ExclusionPeligrosa $ruta) { throw "Ruta prohibida: excluirla rompe Windows Update ($ruta)" }
    $r = Invoke-Uwf @('file','add-exclusion',$ruta)
    Escribir-Log 'AddExclusionArchivo' $(if ($r.Ok) {'OK'} else {'ERROR'}) $ruta
    if (-not $r.Ok) { throw $r.Salida }
}

function Remove-ExclusionArchivo([string]$ruta) {
    $r = Invoke-Uwf @('file','remove-exclusion',$ruta)
    Escribir-Log 'QuitarExclusionArchivo' $(if ($r.Ok) {'OK'} else {'ERROR'}) $ruta
    if (-not $r.Ok) { throw $r.Salida }
}

function Add-ExclusionRegistro([string]$clave) {
    $c = Normalizar-ClaveRegistro $clave
    if ($c -notmatch '^HKLM\\') { throw 'UWF solo admite exclusiones de registro bajo HKLM.' }
    $r = Invoke-Uwf @('registry','add-exclusion',$c)
    Escribir-Log 'AddExclusionRegistro' $(if ($r.Ok) {'OK'} else {'ERROR'}) $c
    if (-not $r.Ok) { throw $r.Salida }
}

function Remove-ExclusionRegistro([string]$clave) {
    $c = Normalizar-ClaveRegistro $clave
    $r = Invoke-Uwf @('registry','remove-exclusion',$c)
    Escribir-Log 'QuitarExclusionRegistro' $(if ($r.Ok) {'OK'} else {'ERROR'}) $c
    if (-not $r.Ok) { throw $r.Salida }
}

# -----------------------------------------------------------------------------
#  Deteccion de programas instalados y propuestas de exclusion
# -----------------------------------------------------------------------------
function Get-ProgramasInstalados {
    $rutas = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $lista = @{}
    foreach ($ruta in $rutas) {
        foreach ($item in (Get-ItemProperty -Path $ruta -ErrorAction SilentlyContinue)) {
            if (-not $item.DisplayName) { continue }
            if ($item.SystemComponent -eq 1) { continue }
            $nombre = $item.DisplayName.Trim()
            if (-not $lista.ContainsKey($nombre)) {
                $lista[$nombre] = [pscustomobject]@{
                    Nombre    = $nombre
                    Fabricante = [string]$item.Publisher
                }
            }
        }
    }
    return ($lista.Values | Sort-Object Nombre)
}

function Resolver-Glob([string]$patron) {
    # Devuelve las rutas reales que existen y encajan con el patron
    $res = @()
    try {
        $res = @(Get-Item -Path $patron -ErrorAction SilentlyContinue |
                 Where-Object { $_.PSIsContainer } |
                 ForEach-Object { $_.FullName })
        if (-not $res -and (Test-Path -LiteralPath $patron)) { $res = @($patron) }
    } catch { }
    return $res
}

function Get-PropuestasExclusion {
    param([string]$NombrePrograma, [string]$Fabricante)

    $carpetas = New-Object System.Collections.ArrayList
    $claves   = New-Object System.Collections.ArrayList
    $origen   = 'heuristica'

    # 1) Catalogo de programas conocidos
    foreach ($entrada in $script:Catalogo) {
        if ($NombrePrograma -match $entrada.Patron) {
            $origen = 'catalogo'
            foreach ($glob in $entrada.Carpetas) {
                foreach ($ruta in (Resolver-Glob $glob)) {
                    if ($carpetas -notcontains $ruta) { [void]$carpetas.Add($ruta) }
                }
            }
            foreach ($clave in $entrada.Claves) {
                $ps = $clave -replace '^HKLM\\', 'HKLM:\'
                if ((Test-Path -LiteralPath $ps) -and ($claves -notcontains $clave)) { [void]$claves.Add($clave) }
            }
            break
        }
    }

    # 2) Heuristica para programas fuera del catalogo:
    #    buscar carpetas en ProgramData y claves en HKLM\SOFTWARE que
    #    contengan el nombre del programa o del fabricante
    if ($origen -eq 'heuristica') {
        $terminos = New-Object System.Collections.ArrayList
        $limpio = ($NombrePrograma -replace '[\d\.\(\)]+', ' ').Trim()
        foreach ($p in ($limpio -split '\s+')) {
            if ($p.Length -ge 4) { [void]$terminos.Add($p) }
        }
        if ($Fabricante) {
            $f = ($Fabricante -split '[,\s]+')[0]
            if ($f.Length -ge 4 -and $terminos -notcontains $f) { [void]$terminos.Add($f) }
        }

        foreach ($termino in $terminos) {
            foreach ($dir in (Get-ChildItem -LiteralPath 'C:\ProgramData' -Directory -ErrorAction SilentlyContinue)) {
                if ($dir.Name -like "*$termino*" -and $carpetas -notcontains $dir.FullName) {
                    [void]$carpetas.Add($dir.FullName)
                }
            }
            foreach ($raiz in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
                foreach ($k in (Get-ChildItem -Path $raiz -ErrorAction SilentlyContinue)) {
                    if ($k.PSChildName -like "*$termino*") {
                        $clave = $k.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
                        if ($claves -notcontains $clave) { [void]$claves.Add($clave) }
                    }
                }
            }
        }
    }

    [pscustomobject]@{
        Origen   = $origen
        Carpetas = @($carpetas)
        Claves   = @($claves)
    }
}

# -----------------------------------------------------------------------------
#  Perfiles
# -----------------------------------------------------------------------------
function Get-PerfilPredeterminado {
    [pscustomobject]@{
        nombre    = 'Aulas UV - base Kaspersky'
        version   = (Get-Date -Format 'yyyy-MM-dd')
        archivos  = @(
            'C:\ProgramData\KasperskyLab',
            'C:\ProgramData\Kaspersky Lab'
        )
        registro  = @(
            'HKLM\SOFTWARE\WOW6432Node\KasperskyLab',
            'HKLM\SOFTWARE\KasperskyLab'
        )
        overlay   = [pscustomobject]@{ tipo = 'Disco'; tamanoMB = 4096; avisoMB = 2560; criticoMB = 3584 }
    }
}

function Leer-Perfil {
    if (Test-Path -LiteralPath $script:PerfilPath) {
        try { return (Get-Content -LiteralPath $script:PerfilPath -Raw | ConvertFrom-Json) } catch { }
    }
    return (Get-PerfilPredeterminado)
}

function Guardar-Perfil($perfil, [string]$ruta = $null) {
    if (-not $ruta) { $ruta = $script:PerfilPath }
    if ($perfil.overlay) {
        $o = $perfil.overlay
        if (-not (Test-UmbralesValidos ([int]$o.avisoMB) ([int]$o.criticoMB) ([int]$o.tamanoMB))) {
            throw "El perfil tiene umbrales de overlay no validos (aviso=$($o.avisoMB), critico=$($o.criticoMB), tamano=$($o.tamanoMB)). Debe cumplirse aviso < critico <= tamano."
        }
    }
    Inicializar-Carpeta
    $perfil | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ruta -Encoding UTF8
}

function Aplicar-Perfil($perfil, [bool]$FiltroActivo = $false) {
    $errores = New-Object System.Collections.ArrayList
    foreach ($a in @($perfil.archivos)) {
        try { Add-ExclusionArchivo $a } catch { [void]$errores.Add("$a -> $($_.Exception.Message)") }
    }
    foreach ($k in @($perfil.registro)) {
        try { Add-ExclusionRegistro $k } catch { [void]$errores.Add("$k -> $($_.Exception.Message)") }
    }
    if ($perfil.overlay) {
        try {
            $extra = Aplicar-Overlay -Tipo $perfil.overlay.tipo -TamanoMB ([int]$perfil.overlay.tamanoMB) `
                     -AvisoMB ([int]$perfil.overlay.avisoMB) -CriticoMB ([int]$perfil.overlay.criticoMB) `
                     -FiltroActivo $FiltroActivo
            foreach ($e in $extra) { [void]$errores.Add($e) }
        } catch { [void]$errores.Add("overlay -> $($_.Exception.Message)") }
    }
    Escribir-Log 'AplicarPerfil' $(if ($errores.Count -eq 0) {'OK'} else {'PARCIAL'}) ($perfil.nombre)
    return $errores
}

# -----------------------------------------------------------------------------
#  Tarea vigilante y autoinstalacion
# -----------------------------------------------------------------------------
function Instalar-Vigilante {
    Inicializar-Carpeta
    $origen = $PSCommandPath
    if ($origen -and ($origen -ne $script:ScriptDest)) {
        Copy-Item -LiteralPath $origen -Destination $script:ScriptDest -Force
    }
    $accion   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Vigilante' -f $script:ScriptDest)
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $ppal     = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $opciones = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $script:Tarea -Action $accion -Trigger $trigger `
        -Principal $ppal -Settings $opciones -Force | Out-Null
    Escribir-Log 'InstalarVigilante' 'OK' $script:ScriptDest
}

function Crear-AccesoDirecto {
    try {
        $ws  = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path (Join-Path $env:PUBLIC 'Desktop') 'UWF Aulas.lnk'))
        $lnk.TargetPath       = 'powershell.exe'
        $lnk.Arguments        = ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $script:ScriptDest)
        $lnk.WorkingDirectory = $script:Base
        $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,48"
        $lnk.Description      = 'Gestion del Unified Write Filter'
        $lnk.Save()
    } catch { }
}

# -----------------------------------------------------------------------------
#  Flujo de mantenimiento
# -----------------------------------------------------------------------------
function Iniciar-Mantenimiento {
    $r = Invoke-Uwf @('filter','disable')
    if (-not $r.Ok) { throw "No se ha podido desactivar el filtro: $($r.Salida)" }
    Guardar-Estado 'mantenimiento'
    Escribir-Log 'IniciarMantenimiento' 'OK' 'filtro desactivado, pendiente de reinicio'
}

function Finalizar-Mantenimiento {
    $r = Invoke-Uwf @('filter','enable')
    if (-not $r.Ok) { throw "No se ha podido activar el filtro: $($r.Salida)" }
    Guardar-Estado 'verificando'
    Escribir-Log 'FinalizarMantenimiento' 'OK' 'filtro activado, pendiente de reinicio'
}

function Reiniciar-Equipo([string]$motivo) {
    Escribir-Log 'Reinicio' 'OK' $motivo
    Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r','/t','10','/c',"UWF Aulas: $motivo" -WindowStyle Hidden
}

# -----------------------------------------------------------------------------
#  MODO VIGILANTE (sin interfaz, en cada arranque)
# -----------------------------------------------------------------------------
function Ejecutar-Vigilante {
    $estado = Leer-Estado
    $cfg    = Leer-Config
    $uwf    = Get-EstadoUwf

    if (-not $estado) {
        if ($uwf.Instalado -and -not $uwf.FiltroActual) {
            Escribir-Log 'Vigilante' 'AVISO' 'El equipo ha arrancado con el filtro desactivado y sin mantenimiento en curso'
        }
        return
    }

    switch ($estado.fase) {
        'verificando' {
            if ($uwf.FiltroActual) {
                Escribir-Log 'Vigilante' 'OK' 'Mantenimiento cerrado, filtro activo y verificado'
                Guardar-Estado $null
            } else {
                Escribir-Log 'Vigilante' 'ERROR' 'El filtro deberia estar activo y no lo esta. Reintentando'
                try { Invoke-Uwf @('filter','enable') | Out-Null; Reiniciar-Equipo 'reactivando proteccion' } catch { }
            }
        }
        'mantenimiento' {
            $horas = ((Get-Date) - [datetime]$estado.inicio).TotalHours
            $max   = 8
            if ($cfg.horasMaxMantenimiento) { $max = [double]$cfg.horasMaxMantenimiento }
            if ($horas -ge $max) {
                Escribir-Log 'Vigilante' 'AVISO' ("Mantenimiento abierto {0:N1} h, se reactiva la proteccion automaticamente" -f $horas)
                try {
                    Invoke-Uwf @('filter','enable') | Out-Null
                    Guardar-Estado 'verificando'
                    Reiniciar-Equipo 'cierre automatico de mantenimiento'
                } catch {
                    Escribir-Log 'Vigilante' 'ERROR' $_.Exception.Message
                }
            } else {
                Escribir-Log 'Vigilante' 'INFO' ("Mantenimiento en curso desde hace {0:N1} h" -f $horas)
            }
        }
    }
}

# -----------------------------------------------------------------------------
#  Dialogo: exclusiones por programa
# -----------------------------------------------------------------------------
function Mostrar-DialogoPrograma {
    param($FormPadre)

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = 'Exclusiones por programa'
    $dlg.Size          = New-Object System.Drawing.Size(680, 520)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox   = $false
    $dlg.MinimizeBox   = $false

    $lbl1          = New-Object System.Windows.Forms.Label
    $lbl1.Text     = 'Programa instalado en este equipo:'
    $lbl1.Location = New-Object System.Drawing.Point(16, 16)
    $lbl1.Size     = New-Object System.Drawing.Size(400, 20)

    $combo               = New-Object System.Windows.Forms.ComboBox
    $combo.Location      = New-Object System.Drawing.Point(16, 40)
    $combo.Size          = New-Object System.Drawing.Size(630, 26)
    $combo.DropDownStyle = 'DropDownList'

    $lbl2          = New-Object System.Windows.Forms.Label
    $lbl2.Text     = 'Se anadiran las exclusiones marcadas (desmarca las que no quieras):'
    $lbl2.Location = New-Object System.Drawing.Point(16, 82)
    $lbl2.Size     = New-Object System.Drawing.Size(600, 20)

    $lista              = New-Object System.Windows.Forms.CheckedListBox
    $lista.Location     = New-Object System.Drawing.Point(16, 106)
    $lista.Size         = New-Object System.Drawing.Size(630, 280)
    $lista.CheckOnClick = $true
    $lista.HorizontalScrollbar = $true

    $lblOrigen          = New-Object System.Windows.Forms.Label
    $lblOrigen.Location = New-Object System.Drawing.Point(16, 392)
    $lblOrigen.Size     = New-Object System.Drawing.Size(630, 36)

    $btnOk          = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Anadir seleccionadas'
    $btnOk.Location = New-Object System.Drawing.Point(400, 436)
    $btnOk.Size     = New-Object System.Drawing.Size(170, 34)
    $btnOk.Enabled  = $false

    $btnCancelar          = New-Object System.Windows.Forms.Button
    $btnCancelar.Text     = 'Cancelar'
    $btnCancelar.Location = New-Object System.Drawing.Point(578, 436)
    $btnCancelar.Size     = New-Object System.Drawing.Size(80, 34)
    $btnCancelar.DialogResult = 'Cancel'

    $dlg.Controls.AddRange(@($lbl1, $combo, $lbl2, $lista, $lblOrigen, $btnOk, $btnCancelar))
    $dlg.CancelButton = $btnCancelar

    # Cargar programas instalados
    $programas = @(Get-ProgramasInstalados)
    foreach ($p in $programas) { [void]$combo.Items.Add($p.Nombre) }

    $combo.Add_SelectedIndexChanged({
        $lista.Items.Clear()
        $btnOk.Enabled = $false
        $sel = $programas[$combo.SelectedIndex]
        $prop = Get-PropuestasExclusion -NombrePrograma $sel.Nombre -Fabricante $sel.Fabricante

        foreach ($c in $prop.Carpetas) { [void]$lista.Items.Add("CARPETA  $c", $true) }
        foreach ($k in $prop.Claves)   { [void]$lista.Items.Add("REGISTRO $k", $true) }

        if ($lista.Items.Count -eq 0) {
            $lblOrigen.Text = 'No se ha encontrado ninguna carpeta ni clave asociada a este programa. Anadela a mano desde la pestana Exclusiones.'
        } elseif ($prop.Origen -eq 'catalogo') {
            $lblOrigen.Text = 'Programa reconocido: estas rutas son las recomendadas y estan verificadas en este equipo.'
            $btnOk.Enabled = $true
        } else {
            $lblOrigen.Text = 'Programa fuera del catalogo: las rutas son una busqueda automatica por nombre. Revisalas antes de aceptar.'
            $btnOk.Enabled = $true
        }
    })

    $resultado = @{ Aceptado = $false; Carpetas = @(); Claves = @() }

    $btnOk.Add_Click({
        $carpetas = New-Object System.Collections.ArrayList
        $claves   = New-Object System.Collections.ArrayList
        foreach ($item in $lista.CheckedItems) {
            $txt = [string]$item
            if ($txt.StartsWith('CARPETA  '))  { [void]$carpetas.Add($txt.Substring(9)) }
            if ($txt.StartsWith('REGISTRO ')) { [void]$claves.Add($txt.Substring(9)) }
        }
        $resultado.Aceptado = $true
        $resultado.Carpetas = @($carpetas)
        $resultado.Claves   = @($claves)
        $dlg.Close()
    })

    [void]$dlg.ShowDialog($FormPadre)
    return [pscustomobject]$resultado
}

# -----------------------------------------------------------------------------
#  INTERFAZ GRAFICA
# -----------------------------------------------------------------------------
function Mostrar-Interfaz {

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "UWF Aulas v2  -  $env:COMPUTERNAME"
    $form.Size            = New-Object System.Drawing.Size(940, 700)
    $form.StartPosition   = 'CenterScreen'
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.MinimumSize     = New-Object System.Drawing.Size(820, 620)

    # ---- Banner superior ----
    $banner            = New-Object System.Windows.Forms.Panel
    $banner.Dock       = 'Top'
    $banner.Height     = 64
    $lblBanner         = New-Object System.Windows.Forms.Label
    $lblBanner.Dock    = 'Fill'
    $lblBanner.TextAlign = 'MiddleCenter'
    $lblBanner.Font    = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $lblBanner.ForeColor = [System.Drawing.Color]::White
    $banner.Controls.Add($lblBanner)
    $form.Controls.Add($banner)

    $tabs        = New-Object System.Windows.Forms.TabControl
    $tabs.Dock   = 'Fill'
    $tabs.Padding = New-Object System.Drawing.Point(12, 6)

    $tabEstado  = New-Object System.Windows.Forms.TabPage; $tabEstado.Text  = 'Estado'
    $tabExcl    = New-Object System.Windows.Forms.TabPage; $tabExcl.Text    = 'Exclusiones'
    $tabOverlay = New-Object System.Windows.Forms.TabPage; $tabOverlay.Text = 'Overlay'
    $tabMant    = New-Object System.Windows.Forms.TabPage; $tabMant.Text    = 'Mantenimiento'
    $tabCfg     = New-Object System.Windows.Forms.TabPage; $tabCfg.Text     = 'Configuracion'
    $tabs.TabPages.AddRange(@($tabEstado, $tabExcl, $tabOverlay, $tabMant, $tabCfg))
    $form.Controls.Add($tabs)
    $tabs.BringToFront()

    $barra              = New-Object System.Windows.Forms.StatusStrip
    $lblBarra           = New-Object System.Windows.Forms.ToolStripStatusLabel
    $lblBarra.Text      = 'Listo'
    [void]$barra.Items.Add($lblBarra)
    $form.Controls.Add($barra)

    # =========================== PESTANA ESTADO ==============================
    $txtEstado                = New-Object System.Windows.Forms.TextBox
    $txtEstado.Multiline      = $true
    $txtEstado.ReadOnly       = $true
    $txtEstado.ScrollBars     = 'Vertical'
    $txtEstado.Font           = New-Object System.Drawing.Font('Consolas', 10)
    $txtEstado.Location       = New-Object System.Drawing.Point(16, 16)
    $txtEstado.Size           = New-Object System.Drawing.Size(880, 300)
    $txtEstado.Anchor         = 'Top,Left,Right'
    $tabEstado.Controls.Add($txtEstado)

    $barraOverlay             = New-Object System.Windows.Forms.ProgressBar
    $barraOverlay.Location    = New-Object System.Drawing.Point(16, 328)
    $barraOverlay.Size        = New-Object System.Drawing.Size(880, 22)
    $barraOverlay.Anchor      = 'Top,Left,Right'
    $tabEstado.Controls.Add($barraOverlay)

    $y = 368
    $btnInstalar   = New-Object System.Windows.Forms.Button
    $btnInstalar.Text = 'Instalar caracteristica UWF'
    $btnInstalar.Location = New-Object System.Drawing.Point(16, $y)
    $btnInstalar.Size = New-Object System.Drawing.Size(220, 34)

    $btnPreparar   = New-Object System.Windows.Forms.Button
    $btnPreparar.Text = 'Preparar equipo (protege C: y aplica perfil)'
    $btnPreparar.Location = New-Object System.Drawing.Point(248, $y)
    $btnPreparar.Size = New-Object System.Drawing.Size(300, 34)

    $btnRefrescar  = New-Object System.Windows.Forms.Button
    $btnRefrescar.Text = 'Actualizar estado'
    $btnRefrescar.Location = New-Object System.Drawing.Point(560, $y)
    $btnRefrescar.Size = New-Object System.Drawing.Size(160, 34)

    $tabEstado.Controls.AddRange(@($btnInstalar, $btnPreparar, $btnRefrescar))

    # ========================= PESTANA EXCLUSIONES ===========================
    $lv              = New-Object System.Windows.Forms.ListView
    $lv.View         = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines    = $true
    $lv.Location     = New-Object System.Drawing.Point(16, 16)
    $lv.Size         = New-Object System.Drawing.Size(880, 380)
    $lv.Anchor       = 'Top,Left,Right,Bottom'
    [void]$lv.Columns.Add('Tipo', 90)
    [void]$lv.Columns.Add('Ruta o clave', 610)
    [void]$lv.Columns.Add('Existe', 160)
    $tabExcl.Controls.Add($lv)

    $y2 = 408
    $btnAddPrograma = New-Object System.Windows.Forms.Button
    $btnAddPrograma.Text = 'Anadir por programa...'
    $btnAddPrograma.Location = New-Object System.Drawing.Point(16, $y2)
    $btnAddPrograma.Size = New-Object System.Drawing.Size(170, 32)
    $btnAddPrograma.Anchor = 'Bottom,Left'
    $btnAddPrograma.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $btnAddCarpeta = New-Object System.Windows.Forms.Button
    $btnAddCarpeta.Text = 'Carpeta'
    $btnAddCarpeta.Location = New-Object System.Drawing.Point(194, $y2)
    $btnAddCarpeta.Size = New-Object System.Drawing.Size(90, 32)
    $btnAddCarpeta.Anchor = 'Bottom,Left'

    $btnAddArchivo = New-Object System.Windows.Forms.Button
    $btnAddArchivo.Text = 'Archivo'
    $btnAddArchivo.Location = New-Object System.Drawing.Point(292, $y2)
    $btnAddArchivo.Size = New-Object System.Drawing.Size(90, 32)
    $btnAddArchivo.Anchor = 'Bottom,Left'

    $btnAddReg = New-Object System.Windows.Forms.Button
    $btnAddReg.Text = 'Clave HKLM'
    $btnAddReg.Location = New-Object System.Drawing.Point(390, $y2)
    $btnAddReg.Size = New-Object System.Drawing.Size(110, 32)
    $btnAddReg.Anchor = 'Bottom,Left'

    $btnQuitar = New-Object System.Windows.Forms.Button
    $btnQuitar.Text = 'Quitar'
    $btnQuitar.Location = New-Object System.Drawing.Point(508, $y2)
    $btnQuitar.Size = New-Object System.Drawing.Size(80, 32)
    $btnQuitar.Anchor = 'Bottom,Left'

    $btnImportar = New-Object System.Windows.Forms.Button
    $btnImportar.Text = 'Importar perfil'
    $btnImportar.Location = New-Object System.Drawing.Point(618, $y2)
    $btnImportar.Size = New-Object System.Drawing.Size(130, 32)
    $btnImportar.Anchor = 'Bottom,Left'

    $btnExportar = New-Object System.Windows.Forms.Button
    $btnExportar.Text = 'Exportar perfil'
    $btnExportar.Location = New-Object System.Drawing.Point(756, $y2)
    $btnExportar.Size = New-Object System.Drawing.Size(130, 32)
    $btnExportar.Anchor = 'Bottom,Left'

    $lblAviso = New-Object System.Windows.Forms.Label
    $lblAviso.Text = 'Las exclusiones solo surten efecto tras reiniciar. Todo lo excluido se guarda de verdad en el disco: excluye lo minimo.'
    $lblAviso.Location = New-Object System.Drawing.Point(16, 448)
    $lblAviso.Size = New-Object System.Drawing.Size(880, 34)
    $lblAviso.Anchor = 'Bottom,Left,Right'
    $lblAviso.ForeColor = [System.Drawing.Color]::FromArgb(150, 80, 0)

    $tabExcl.Controls.AddRange(@($btnAddPrograma, $btnAddCarpeta, $btnAddArchivo, $btnAddReg, $btnQuitar, $btnImportar, $btnExportar, $lblAviso))

    # =========================== PESTANA OVERLAY =============================
    $lblOv1          = New-Object System.Windows.Forms.Label
    $lblOv1.Text     = @"
El overlay es el espacio donde se guardan los cambios temporales de cada sesion. Se vacia al reiniciar.

- Disco: reserva el espacio en C:. Recomendado para las aulas: no resta memoria al equipo.
- RAM:   mas rapido, pero consume memoria fisica segun se llena. Solo para equipos con mucha RAM.

El tipo y el tamano solo se pueden cambiar con la proteccion DESACTIVADA (durante un mantenimiento).
Los umbrales de aviso y critico se pueden cambiar en cualquier momento.
"@
    $lblOv1.Location = New-Object System.Drawing.Point(16, 16)
    $lblOv1.Size     = New-Object System.Drawing.Size(880, 150)
    $lblOv1.Anchor   = 'Top,Left,Right'

    $gbTipo          = New-Object System.Windows.Forms.GroupBox
    $gbTipo.Text     = 'Donde se guarda'
    $gbTipo.Location = New-Object System.Drawing.Point(16, 176)
    $gbTipo.Size     = New-Object System.Drawing.Size(240, 90)

    $radDisco          = New-Object System.Windows.Forms.RadioButton
    $radDisco.Text     = 'Disco (C:)  - recomendado'
    $radDisco.Location = New-Object System.Drawing.Point(16, 24)
    $radDisco.Size     = New-Object System.Drawing.Size(210, 24)
    $radDisco.Checked  = $true

    $radRam          = New-Object System.Windows.Forms.RadioButton
    $radRam.Text     = 'RAM (memoria)'
    $radRam.Location = New-Object System.Drawing.Point(16, 52)
    $radRam.Size     = New-Object System.Drawing.Size(210, 24)

    $gbTipo.Controls.AddRange(@($radDisco, $radRam))

    $gbTam           = New-Object System.Windows.Forms.GroupBox
    $gbTam.Text      = 'Espacio (MB)'
    $gbTam.Location  = New-Object System.Drawing.Point(272, 176)
    $gbTam.Size      = New-Object System.Drawing.Size(600, 90)

    $lblTam          = New-Object System.Windows.Forms.Label
    $lblTam.Text     = 'Tamano:'
    $lblTam.Location = New-Object System.Drawing.Point(16, 30)
    $lblTam.Size     = New-Object System.Drawing.Size(60, 22)
    $numTam          = New-Object System.Windows.Forms.NumericUpDown
    $numTam.Location = New-Object System.Drawing.Point(78, 28)
    $numTam.Size     = New-Object System.Drawing.Size(90, 24)
    $numTam.Minimum  = 512
    $numTam.Maximum  = 65536
    $numTam.Increment = 512
    $numTam.Value    = 4096

    $lblAv           = New-Object System.Windows.Forms.Label
    $lblAv.Text      = 'Aviso:'
    $lblAv.Location  = New-Object System.Drawing.Point(196, 30)
    $lblAv.Size      = New-Object System.Drawing.Size(48, 22)
    $numAv           = New-Object System.Windows.Forms.NumericUpDown
    $numAv.Location  = New-Object System.Drawing.Point(246, 28)
    $numAv.Size      = New-Object System.Drawing.Size(90, 24)
    $numAv.Minimum   = 128
    $numAv.Maximum   = 65536
    $numAv.Increment = 128
    $numAv.Value     = 2560

    $lblCr           = New-Object System.Windows.Forms.Label
    $lblCr.Text      = 'Critico:'
    $lblCr.Location  = New-Object System.Drawing.Point(364, 30)
    $lblCr.Size      = New-Object System.Drawing.Size(52, 22)
    $numCr           = New-Object System.Windows.Forms.NumericUpDown
    $numCr.Location  = New-Object System.Drawing.Point(418, 28)
    $numCr.Size      = New-Object System.Drawing.Size(90, 24)
    $numCr.Minimum   = 256
    $numCr.Maximum   = 65536
    $numCr.Increment = 128
    $numCr.Value     = 3584

    $lblRegla          = New-Object System.Windows.Forms.Label
    $lblRegla.Text     = 'Regla: aviso < critico <= tamano. Ambos miden el consumo acumulado.'
    $lblRegla.Location = New-Object System.Drawing.Point(16, 58)
    $lblRegla.Size     = New-Object System.Drawing.Size(560, 22)
    $lblRegla.ForeColor = [System.Drawing.Color]::Gray

    $gbTam.Controls.AddRange(@($lblTam, $numTam, $lblAv, $numAv, $lblCr, $numCr, $lblRegla))

    $btnAplicarOv          = New-Object System.Windows.Forms.Button
    $btnAplicarOv.Text     = 'Aplicar configuracion del overlay'
    $btnAplicarOv.Location = New-Object System.Drawing.Point(16, 284)
    $btnAplicarOv.Size     = New-Object System.Drawing.Size(280, 40)

    $lblOvEstado          = New-Object System.Windows.Forms.Label
    $lblOvEstado.Location = New-Object System.Drawing.Point(16, 340)
    $lblOvEstado.Size     = New-Object System.Drawing.Size(880, 60)
    $lblOvEstado.Anchor   = 'Top,Left,Right'

    $tabOverlay.Controls.AddRange(@($lblOv1, $gbTipo, $gbTam, $btnAplicarOv, $lblOvEstado))

    # ======================== PESTANA MANTENIMIENTO ==========================
    $lblMant           = New-Object System.Windows.Forms.Label
    $lblMant.Location  = New-Object System.Drawing.Point(16, 16)
    $lblMant.Size      = New-Object System.Drawing.Size(880, 210)
    $lblMant.Anchor    = 'Top,Left,Right'
    $lblMant.Font      = New-Object System.Drawing.Font('Segoe UI', 10)
    $lblMant.Text      = @"
Flujo de mantenimiento (sustituye al servicing mode de UWF):

  1. Iniciar mantenimiento    ->  desactiva el filtro y reinicia
  2. El equipo arranca sin proteccion: instala parches, actualiza Kaspersky, cambia lo que necesites
  3. Finalizar y proteger     ->  reactiva el filtro y reinicia
  4. Al arrancar, el vigilante comprueba que la proteccion ha vuelto y lo anota en el registro

Si el mantenimiento se queda abierto mas horas de las configuradas, el vigilante reactiva
la proteccion por su cuenta en el siguiente arranque.
"@

    $lblFase           = New-Object System.Windows.Forms.Label
    $lblFase.Location  = New-Object System.Drawing.Point(16, 236)
    $lblFase.Size      = New-Object System.Drawing.Size(880, 30)
    $lblFase.Anchor    = 'Top,Left,Right'
    $lblFase.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

    $btnIniciarM       = New-Object System.Windows.Forms.Button
    $btnIniciarM.Text  = '1 - Iniciar mantenimiento y reiniciar'
    $btnIniciarM.Location = New-Object System.Drawing.Point(16, 280)
    $btnIniciarM.Size  = New-Object System.Drawing.Size(330, 52)

    $btnFinalizarM     = New-Object System.Windows.Forms.Button
    $btnFinalizarM.Text = '3 - Finalizar, proteger y reiniciar'
    $btnFinalizarM.Location = New-Object System.Drawing.Point(360, 280)
    $btnFinalizarM.Size = New-Object System.Drawing.Size(330, 52)

    $txtLog            = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline  = $true
    $txtLog.ReadOnly   = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.Font       = New-Object System.Drawing.Font('Consolas', 8.5)
    $txtLog.Location   = New-Object System.Drawing.Point(16, 348)
    $txtLog.Size       = New-Object System.Drawing.Size(880, 150)
    $txtLog.Anchor     = 'Top,Left,Right,Bottom'

    $tabMant.Controls.AddRange(@($lblMant, $lblFase, $btnIniciarM, $btnFinalizarM, $txtLog))

    # ======================== PESTANA CONFIGURACION ==========================
    $lblRed          = New-Object System.Windows.Forms.Label
    $lblRed.Text     = 'Ruta de red para el registro centralizado (opcional):'
    $lblRed.Location = New-Object System.Drawing.Point(16, 20)
    $lblRed.Size     = New-Object System.Drawing.Size(400, 22)

    $txtRed          = New-Object System.Windows.Forms.TextBox
    $txtRed.Location = New-Object System.Drawing.Point(16, 46)
    $txtRed.Size     = New-Object System.Drawing.Size(600, 24)

    $lblHoras        = New-Object System.Windows.Forms.Label
    $lblHoras.Text   = 'Horas maximas con el mantenimiento abierto antes de reactivar la proteccion:'
    $lblHoras.Location = New-Object System.Drawing.Point(16, 86)
    $lblHoras.Size   = New-Object System.Drawing.Size(500, 22)

    $numHoras        = New-Object System.Windows.Forms.NumericUpDown
    $numHoras.Location = New-Object System.Drawing.Point(16, 112)
    $numHoras.Size   = New-Object System.Drawing.Size(80, 24)
    $numHoras.Minimum = 1
    $numHoras.Maximum = 72

    $btnGuardarCfg   = New-Object System.Windows.Forms.Button
    $btnGuardarCfg.Text = 'Guardar configuracion'
    $btnGuardarCfg.Location = New-Object System.Drawing.Point(16, 156)
    $btnGuardarCfg.Size = New-Object System.Drawing.Size(200, 34)

    $btnAbrirCarpeta = New-Object System.Windows.Forms.Button
    $btnAbrirCarpeta.Text = 'Abrir carpeta de la herramienta'
    $btnAbrirCarpeta.Location = New-Object System.Drawing.Point(228, 156)
    $btnAbrirCarpeta.Size = New-Object System.Drawing.Size(240, 34)

    $tabCfg.Controls.AddRange(@($lblRed, $txtRed, $lblHoras, $numHoras, $btnGuardarCfg, $btnAbrirCarpeta))

    # ============================ LOGICA GUI =================================
    $refrescar = {
        try {
            $u  = Get-EstadoUwf
            $es = Leer-Estado

            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("Equipo              : $env:COMPUTERNAME")
            [void]$sb.AppendLine("Caracteristica UWF  : " + $(if ($u.Instalado) {'instalada'} else {'NO instalada'}))
            [void]$sb.AppendLine("Filtro (sesion act.): " + $(if ($u.FiltroActual) {'ACTIVO'} else {'DESACTIVADO'}))
            [void]$sb.AppendLine("Filtro (tras reinic): " + $(if ($u.FiltroSiguiente) {'ACTIVO'} else {'DESACTIVADO'}))
            [void]$sb.AppendLine("Volumenes protegidos: " + $(if ($u.VolumenesActual.Count) { $u.VolumenesActual -join ', ' } else {'ninguno'}))
            [void]$sb.AppendLine("Overlay             : $($u.OverlayTipo), maximo $($u.OverlayMaxMB) MB")
            [void]$sb.AppendLine("Umbrales            : aviso $($u.OverlayAvisoMB) MB, critico $($u.OverlayCriticoMB) MB")
            if ($u.OverlayUsoMB -ge 0) {
                [void]$sb.AppendLine("Consumo del overlay : $($u.OverlayUsoMB) MB")
            }
            [void]$sb.AppendLine('')
            if ($es) {
                [void]$sb.AppendLine("Mantenimiento       : fase '$($es.fase)' iniciada el $($es.inicio) por $($es.tecnico)")
            } else {
                [void]$sb.AppendLine('Mantenimiento       : ninguno en curso')
            }
            if ($u.Error) { [void]$sb.AppendLine(''); [void]$sb.AppendLine("Aviso: $($u.Error)") }
            $txtEstado.Text = $sb.ToString()

            if ($u.OverlayMaxMB -gt 0 -and $u.OverlayUsoMB -ge 0) {
                $barraOverlay.Maximum = [int]$u.OverlayMaxMB
                $barraOverlay.Value   = [Math]::Min([int]$u.OverlayUsoMB, [int]$u.OverlayMaxMB)
            }

            # Banner
            if ($es -and $es.fase -eq 'mantenimiento' -and -not $u.FiltroActual) {
                $banner.BackColor  = [System.Drawing.Color]::FromArgb(178, 34, 34)
                $lblBanner.Text    = 'MANTENIMIENTO EN CURSO  -  EL EQUIPO NO ESTA PROTEGIDO'
            } elseif ($u.FiltroActual) {
                $banner.BackColor  = [System.Drawing.Color]::FromArgb(30, 120, 60)
                $lblBanner.Text    = 'PROTECCION ACTIVA  -  los cambios se descartan al reiniciar'
            } else {
                $banner.BackColor  = [System.Drawing.Color]::FromArgb(200, 130, 0)
                $lblBanner.Text    = 'PROTECCION DESACTIVADA  -  los cambios se guardan en disco'
            }

            $lblFase.Text = $lblBanner.Text
            $btnIniciarM.Enabled   = ($u.Instalado -and $u.FiltroActual)
            $btnFinalizarM.Enabled = ($u.Instalado -and -not $u.FiltroActual)
            $btnInstalar.Enabled   = (-not $u.Instalado)

            # Pestana Overlay: reflejar estado actual y avisar si esta bloqueado
            if ($u.Instalado) {
                if ($u.OverlayTipo -eq 'RAM') { $radRam.Checked = $true } else { $radDisco.Checked = $true }
                if ($u.OverlayMaxMB   -ge $numTam.Minimum) { $numTam.Value = [Math]::Min($u.OverlayMaxMB,   $numTam.Maximum) }
                if ($u.OverlayAvisoMB -ge $numAv.Minimum)  { $numAv.Value  = [Math]::Min($u.OverlayAvisoMB, $numAv.Maximum) }
                if ($u.OverlayCriticoMB -ge $numCr.Minimum){ $numCr.Value  = [Math]::Min($u.OverlayCriticoMB,$numCr.Maximum) }
                if ($u.FiltroActual) {
                    $lblOvEstado.Text = 'La proteccion esta ACTIVA: ahora mismo solo se pueden cambiar los umbrales. Para cambiar tipo o tamano, inicia antes un mantenimiento.'
                    $lblOvEstado.ForeColor = [System.Drawing.Color]::FromArgb(150, 80, 0)
                } else {
                    $lblOvEstado.Text = 'La proteccion esta desactivada: se puede cambiar todo. Los cambios se aplican tras reiniciar.'
                    $lblOvEstado.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 60)
                }
            }

            # Exclusiones
            $lv.Items.Clear()
            if ($u.Instalado) {
                foreach ($a in (Get-ExclusionesArchivo)) {
                    $it = New-Object System.Windows.Forms.ListViewItem('Archivo')
                    [void]$it.SubItems.Add($a)
                    if (Test-Path -LiteralPath $a) {
                        [void]$it.SubItems.Add('si')
                    } else {
                        [void]$it.SubItems.Add('NO EXISTE - revisar')
                        $it.ForeColor = [System.Drawing.Color]::FromArgb(160, 60, 60)
                    }
                    [void]$lv.Items.Add($it)
                }
                foreach ($k in (Get-ExclusionesRegistro)) {
                    $it = New-Object System.Windows.Forms.ListViewItem('Registro')
                    [void]$it.SubItems.Add($k)
                    $ruta = $k -replace '^HKLM\\', 'HKLM:\'
                    if (Test-Path -LiteralPath $ruta) {
                        [void]$it.SubItems.Add('si')
                    } else {
                        [void]$it.SubItems.Add('NO EXISTE - revisar')
                        $it.ForeColor = [System.Drawing.Color]::FromArgb(160, 60, 60)
                    }
                    [void]$lv.Items.Add($it)
                }
            }

            # Log
            if (Test-Path -LiteralPath $script:LogPath) {
                $txtLog.Lines = @(Get-Content -LiteralPath $script:LogPath -Tail 40)
                $txtLog.SelectionStart = $txtLog.Text.Length
                $txtLog.ScrollToCaret()
            }

            $lblBarra.Text = 'Actualizado ' + (Get-Date -Format 'HH:mm:ss')
        } catch {
            $lblBarra.Text = 'Error: ' + $_.Exception.Message
        }
    }

    $preguntarReinicio = {
        param($motivo)
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Hay que reiniciar para que el cambio surta efecto.`n`nReiniciar ahora?",
            'UWF Aulas', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Reiniciar-Equipo $motivo }
    }

    $btnRefrescar.Add_Click($refrescar)

    $btnInstalar.Add_Click({
        try {
            $lblBarra.Text = 'Instalando la caracteristica UWF...'
            $form.Cursor = 'WaitCursor'
            Enable-WindowsOptionalFeature -Online -FeatureName 'Client-UnifiedWriteFilter' -NoRestart -ErrorAction Stop | Out-Null
            Escribir-Log 'InstalarCaracteristica' 'OK'
            $form.Cursor = 'Default'
            & $preguntarReinicio 'instalacion de la caracteristica UWF'
        } catch {
            $form.Cursor = 'Default'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    })

    $btnPreparar.Add_Click({
        try {
            $form.Cursor = 'WaitCursor'
            Invoke-Uwf @('volume','protect','C:') | Out-Null
            $u = Get-EstadoUwf
            $errores = Aplicar-Perfil (Leer-Perfil) $u.FiltroActual
            Invoke-Uwf @('filter','enable') | Out-Null
            $form.Cursor = 'Default'
            & $refrescar
            if ($errores.Count) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Equipo preparado, pero con avisos:`n`n" + ($errores -join "`n"), 'UWF Aulas', 'OK', 'Warning') | Out-Null
            }
            & $preguntarReinicio 'preparacion del equipo'
        } catch {
            $form.Cursor = 'Default'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    })

    $btnAddPrograma.Add_Click({
        try {
            $res = Mostrar-DialogoPrograma $form
            if (-not $res.Aceptado) { return }
            $errores = New-Object System.Collections.ArrayList
            foreach ($c in $res.Carpetas) {
                try { Add-ExclusionArchivo $c } catch { [void]$errores.Add("$c -> $($_.Exception.Message)") }
            }
            foreach ($k in $res.Claves) {
                try { Add-ExclusionRegistro $k } catch { [void]$errores.Add("$k -> $($_.Exception.Message)") }
            }
            & $refrescar
            if ($errores.Count) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Anadido con avisos:`n`n" + ($errores -join "`n"), 'UWF Aulas', 'OK', 'Warning') | Out-Null
            }
            if (($res.Carpetas.Count + $res.Claves.Count) -gt $errores.Count) {
                & $preguntarReinicio 'exclusiones por programa'
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    })

    $btnAddCarpeta.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq 'OK') {
            try { Add-ExclusionArchivo $d.SelectedPath; & $refrescar; & $preguntarReinicio 'nueva exclusion' }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
        }
    })

    $btnAddArchivo.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        if ($d.ShowDialog() -eq 'OK') {
            try { Add-ExclusionArchivo $d.FileName; & $refrescar; & $preguntarReinicio 'nueva exclusion' }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
        }
    })

    $btnAddReg.Add_Click({
        $clave = [Microsoft.VisualBasic.Interaction]::InputBox(
            'Clave de registro a excluir (solo HKLM):', 'UWF Aulas', 'HKLM\SOFTWARE\')
        if ($clave) {
            try { Add-ExclusionRegistro $clave; & $refrescar; & $preguntarReinicio 'nueva exclusion' }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
        }
    })

    $btnQuitar.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $it   = $lv.SelectedItems[0]
        $tipo = $it.SubItems[0].Text
        $val  = $it.SubItems[1].Text
        try {
            if ($tipo -eq 'Archivo') { Remove-ExclusionArchivo $val } else { Remove-ExclusionRegistro $val }
            & $refrescar
            & $preguntarReinicio 'exclusion eliminada'
        } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
    })

    $btnImportar.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'Perfil JSON|*.json'
        if ($d.ShowDialog() -eq 'OK') {
            try {
                $p = Get-Content -LiteralPath $d.FileName -Raw | ConvertFrom-Json
                Guardar-Perfil $p
                $form.Cursor = 'WaitCursor'
                $u = Get-EstadoUwf
                $errores = Aplicar-Perfil $p $u.FiltroActual
                $form.Cursor = 'Default'
                & $refrescar
                $msg = "Perfil '$($p.nombre)' aplicado."
                if ($errores.Count) { $msg += "`n`nAvisos:`n" + ($errores -join "`n") }
                [System.Windows.Forms.MessageBox]::Show($msg, 'UWF Aulas', 'OK', 'Information') | Out-Null
                & $preguntarReinicio 'perfil de exclusiones aplicado'
            } catch {
                $form.Cursor = 'Default'
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
            }
        }
    })

    $btnExportar.Add_Click({
        $d = New-Object System.Windows.Forms.SaveFileDialog
        $d.Filter   = 'Perfil JSON|*.json'
        $d.FileName = 'perfil-exclusiones.json'
        if ($d.ShowDialog() -eq 'OK') {
            try {
                $u = Get-EstadoUwf
                $perfil = [pscustomobject]@{
                    nombre   = "Exportado de $env:COMPUTERNAME"
                    version  = (Get-Date -Format 'yyyy-MM-dd')
                    archivos = @(Get-ExclusionesArchivo)
                    registro = @(Get-ExclusionesRegistro)
                    overlay  = [pscustomobject]@{
                        tipo      = $u.OverlayTipo
                        tamanoMB  = $u.OverlayMaxMB
                        avisoMB   = $u.OverlayAvisoMB
                        criticoMB = $u.OverlayCriticoMB
                    }
                }
                Guardar-Perfil $perfil $d.FileName
                [System.Windows.Forms.MessageBox]::Show('Perfil exportado.', 'UWF Aulas', 'OK', 'Information') | Out-Null
            } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
        }
    })

    $btnAplicarOv.Add_Click({
        try {
            $u = Get-EstadoUwf
            $tipo = if ($radRam.Checked) { 'RAM' } else { 'Disco' }
            $errores = Aplicar-Overlay -Tipo $tipo -TamanoMB ([int]$numTam.Value) `
                       -AvisoMB ([int]$numAv.Value) -CriticoMB ([int]$numCr.Value) -FiltroActivo $u.FiltroActual
            & $refrescar
            if ($errores.Count) {
                [System.Windows.Forms.MessageBox]::Show(($errores -join "`n`n"), 'UWF Aulas', 'OK', 'Warning') | Out-Null
            } else {
                & $preguntarReinicio 'configuracion del overlay'
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    })

    $btnIniciarM.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Se va a desactivar la proteccion y reiniciar el equipo.`n`nDurante el mantenimiento TODO lo que se escriba se guarda de forma permanente. Continuar?",
            'UWF Aulas', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        try {
            Iniciar-Mantenimiento
            & $refrescar
            Reiniciar-Equipo 'inicio de mantenimiento'
        } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
    })

    $btnFinalizarM.Add_Click({
        try {
            Finalizar-Mantenimiento
            & $refrescar
            Reiniciar-Equipo 'cierre de mantenimiento'
        } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
    })

    $btnGuardarCfg.Add_Click({
        try {
            Guardar-Config ([pscustomobject]@{
                rutaLogRed            = $txtRed.Text.Trim()
                horasMaxMantenimiento = [int]$numHoras.Value
            })
            $lblBarra.Text = 'Configuracion guardada'
        } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
    })

    $btnAbrirCarpeta.Add_Click({ Start-Process explorer.exe $script:Base })

    # Carga inicial
    $cfg = Leer-Config
    $txtRed.Text   = [string]$cfg.rutaLogRed
    $numHoras.Value = [int]$(if ($cfg.horasMaxMantenimiento) { $cfg.horasMaxMantenimiento } else { 8 })

    $estadoActual = Leer-Estado
    if ($estadoActual -and $estadoActual.fase -eq 'mantenimiento') { $tabs.SelectedTab = $tabMant }

    & $refrescar
    [void]$form.ShowDialog()
}

# -----------------------------------------------------------------------------
#  Arranque
# -----------------------------------------------------------------------------
Inicializar-Carpeta

if ($Vigilante) {
    try { Ejecutar-Vigilante } catch { Escribir-Log 'Vigilante' 'ERROR' $_.Exception.Message }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

if (-not (Test-Administrador)) {
    [System.Windows.Forms.MessageBox]::Show(
        'Esta herramienta necesita ejecutarse como administrador.', 'UWF Aulas', 'OK', 'Warning') | Out-Null
    return
}

if (-not (Test-Path -LiteralPath $script:PerfilPath)) { Guardar-Perfil (Get-PerfilPredeterminado) }

try {
    Instalar-Vigilante
    Crear-AccesoDirecto
} catch {
    Escribir-Log 'Autoinstalacion' 'ERROR' $_.Exception.Message
}

Mostrar-Interfaz
