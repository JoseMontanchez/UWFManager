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
#   - Pestana Uso del disco: tipo (RAM/Disco), tamano y umbrales configurables
#   - Exclusiones por programa: detecta lo instalado y propone carpetas/claves
#
#  Cambios v3:
#   - Cola de cambios pendientes (pendientes.json): la GUI encola exclusiones y uso
#     del disco, y nada llega a UWF hasta pulsar "Aplicar cambios y reiniciar". La
#     lista se ve aunque UWF no este disponible en el equipo.
#   - Fase 'aplicando': si un pendiente exige el filtro desactivado (tipo o tamano),
#     la herramienta abre la ventana de mantenimiento sola y el vigilante la cierra
#     tras aplicar la cola, volviendo a proteger el equipo.
#   - En la interfaz, 'overlay' se llama "uso del disco". Internamente (WMI, uwfmgr y
#     claves de los perfiles JSON) se conserva el termino de UWF.
# =============================================================================

$ErrorActionPreference = 'Stop'

$script:Base       = Join-Path $env:ProgramData 'UWF-Aulas'
$script:CfgPath    = Join-Path $script:Base 'config.json'
$script:EstadoPath = Join-Path $script:Base 'estado.json'
$script:PerfilPath = Join-Path $script:Base 'perfil-exclusiones.json'
$script:PendPath   = Join-Path $script:Base 'pendientes.json'
$script:LogPath    = Join-Path $script:Base 'uwf-aulas.log'
$script:ScriptDest = Join-Path $script:Base 'UWF-Aulas.ps1'
$script:Uwfmgr     = Join-Path $env:SystemRoot 'System32\uwfmgr.exe'
$script:Tarea      = 'UWF-Aulas-Vigilante'
$script:Caracteristica = 'Client-UnifiedWriteFilter'

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

# Palabras que la heuristica de "Anadir por programa" no usa como termino de busqueda: son
# tan genericas que casarian con medio sistema (p. ej. el fabricante 'Microsoft' proponia
# excluir HKLM\SOFTWARE\Microsoft entero).
$script:TerminosGenericos = @(
    'microsoft', 'windows', 'corporation', 'corp', 'update', 'updates', 'software',
    'program', 'programs', 'system', 'systems', 'service', 'services', 'driver', 'drivers',
    'runtime', 'redistributable', 'tools', 'client', 'edition', 'version', 'package',
    'components', 'framework', 'technologies', 'limited', 'company', 'intel', 'x64-based'
)

# Carpetas y claves raiz que nunca se proponen por heuristica, aunque casen por nombre
$script:RaicesSistema = @(
    'C:\PROGRAMDATA\MICROSOFT',
    'HKLM\SOFTWARE\MICROSOFT', 'HKLM\SOFTWARE\WOW6432NODE\MICROSOFT',
    'HKLM\SOFTWARE\CLASSES', 'HKLM\SOFTWARE\WOW6432NODE\CLASSES',
    'HKLM\SOFTWARE\POLICIES', 'HKLM\SOFTWARE\WOW6432NODE\POLICIES',
    'HKLM\SOFTWARE\WOW6432NODE', 'HKLM\SOFTWARE\CLIENTS'
)

$script:MaxReintentosFiltro = 3   # reinicios que el vigilante intenta para reactivar el filtro

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

function Guardar-Estado($fase, $detalle = '', [int]$intentos = 0) {
    # 'intentos' cuenta los reintentos del vigilante para reactivar el filtro
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
        intentos = $intentos
    } | ConvertTo-Json | Set-Content -LiteralPath $script:EstadoPath -Encoding UTF8
}

function Test-Administrador {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-UwfInstalado { Test-Path -LiteralPath $script:Uwfmgr }

function Convertir-SalidaNativa($salida) {
    # Con '2>&1', cada linea de stderr de un ejecutable llega envuelta en un ErrorRecord que
    # Out-String pinta con posicion y categoria de PowerShell; aqui se deja solo el texto.
    return (@($salida | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
    }) -join "`r`n").Trim()
}

function Invoke-Uwf {
    param([string[]]$Argumentos)
    if (-not (Test-UwfInstalado)) { throw 'uwfmgr.exe no esta disponible. Instala primero la caracteristica UWF.' }
    # El script corre con 'Stop': sin esto, una linea de uwfmgr en stderr se convertia en una
    # excepcion con un mensaje criptico en vez de devolverse como Ok = $false.
    $ErrorActionPreference = 'Continue'
    $salida = & $script:Uwfmgr @Argumentos 2>&1
    $codigo = $LASTEXITCODE
    [pscustomobject]@{
        Codigo = $codigo
        Salida = (Convertir-SalidaNativa $salida)
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

function Aplicar-TipoTamano([string]$Tipo, [int]$TamanoMB) {
    # UWF solo admite cambiar tipo y tamano con el filtro DESACTIVADO: comprobarlo es
    # responsabilidad de quien llama.
    $errores = New-Object System.Collections.ArrayList
    $t = if ($Tipo -eq 'Disco') { 'disk' } else { 'ram' }
    $r1 = Invoke-Uwf @('overlay','set-type',$t)
    if (-not $r1.Ok) { [void]$errores.Add("set-type: $($r1.Salida)") }
    $r2 = Invoke-Uwf @('overlay','set-size',"$TamanoMB")
    if (-not $r2.Ok) { [void]$errores.Add("set-size: $($r2.Salida)") }
    return $errores
}

function Aplicar-Umbrales([int]$AvisoMB, [int]$CriticoMB) {
    # Los umbrales se pueden cambiar en cualquier momento, con el filtro activo o no.
    $errores = New-Object System.Collections.ArrayList
    $r1 = Invoke-Uwf @('overlay','set-warningthreshold',"$AvisoMB")
    if (-not $r1.Ok) { [void]$errores.Add("set-warningthreshold: $($r1.Salida)") }
    $r2 = Invoke-Uwf @('overlay','set-criticalthreshold',"$CriticoMB")
    if (-not $r2.Ok) { [void]$errores.Add("set-criticalthreshold: $($r2.Salida)") }
    return $errores
}

function Aplicar-Overlay {
    param([string]$Tipo, [int]$TamanoMB, [int]$AvisoMB, [int]$CriticoMB, [bool]$FiltroActivo)

    if (-not (Test-UmbralesValidos $AvisoMB $CriticoMB $TamanoMB)) {
        throw "Umbrales no validos: debe cumplirse aviso < critico <= tamano (has puesto $AvisoMB / $CriticoMB / $TamanoMB MB)."
    }

    $errores = New-Object System.Collections.ArrayList

    # Tipo y tamano solo se pueden cambiar con el filtro desactivado
    if ($FiltroActivo) {
        [void]$errores.Add('El tamano y el sitio del uso del disco solo se pueden cambiar con la proteccion desactivada. Hazlo durante una ventana de mantenimiento. Los umbrales si se han aplicado.')
    } else {
        foreach ($e in @(Aplicar-TipoTamano $Tipo $TamanoMB)) { [void]$errores.Add($e) }
    }

    foreach ($e in @(Aplicar-Umbrales $AvisoMB $CriticoMB)) { [void]$errores.Add($e) }

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
    $c = $c -replace '^HKLM:?(?=\\|$)', 'HKLM'
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

function Get-ExclusionesDetalle {
    # Exclusiones ya permitidas en el equipo, separando la sesion actual de la siguiente.
    # Devuelve objetos {Tipo ('archivo'|'registro'), Valor, Ahora, TrasReinicio}: 'Ahora' =
    # surte efecto en esta sesion; 'TrasReinicio' = seguira (o empezara) a surtir efecto
    # despues de reiniciar. Una exclusion anadida con el filtro activo solo aparece en la
    # siguiente sesion, y una quitada sigue en la actual hasta reiniciar: mostrarlo evita que
    # el tecnico crea que algo ya funciona cuando aun no.
    #
    # Se lee por WMI (UWF_Volume y UWF_RegistryFilter, una instancia por sesion), que no
    # depende del idioma. Si WMI falla, se recurre a uwfmgr sin distinguir sesiones.
    $vistas = [ordered]@{}
    $anotar = {
        param($tipo, $valor, $actual)
        $k = "$tipo|$($valor.ToLower())"
        if (-not $vistas.Contains($k)) {
            $vistas[$k] = [pscustomobject]@{ Tipo = $tipo; Valor = $valor; Ahora = $false; TrasReinicio = $false }
        }
        if ($actual) { $vistas[$k].Ahora = $true } else { $vistas[$k].TrasReinicio = $true }
    }

    try {
        $ns = 'root\standardcimv2\embedded'
        foreach ($v in @(Get-CimInstance -Namespace $ns -ClassName UWF_Volume -ErrorAction Stop)) {
            if ("$($v.DriveLetter)".ToUpper() -ne 'C:') { continue }
            $res = Invoke-CimMethod -InputObject $v -MethodName GetExclusions -ErrorAction Stop
            foreach ($f in @($res.ExcludedFiles)) {
                $ruta = "$($f.FileName)".Trim()
                if (-not $ruta) { continue }
                if ($ruta.StartsWith('\')) { $ruta = 'C:' + $ruta }
                & $anotar 'archivo' $ruta ([bool]$v.CurrentSession)
            }
        }
        foreach ($rf in @(Get-CimInstance -Namespace $ns -ClassName UWF_RegistryFilter -ErrorAction Stop)) {
            $res = Invoke-CimMethod -InputObject $rf -MethodName GetExclusions -ErrorAction Stop
            foreach ($k in @($res.ExcludedKeys)) {
                $clave = "$($k.RegistryKey)".Trim()
                if (-not $clave) { continue }
                $clave = Normalizar-ClaveRegistro $clave
                if ($clave -notmatch '^HKLM\\') { $clave = 'HKLM\' + $clave.TrimStart('\') }
                & $anotar 'registro' $clave ([bool]$rf.CurrentSession)
            }
        }
        return @($vistas.Values)
    } catch {
        $vistas.Clear()
    }

    foreach ($a in (Get-ExclusionesArchivo))  { & $anotar 'archivo'  $a $true; & $anotar 'archivo'  $a $false }
    foreach ($k in (Get-ExclusionesRegistro)) { & $anotar 'registro' $k $true; & $anotar 'registro' $k $false }
    return @($vistas.Values)
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
#  Cambios pendientes
#
#  El tecnico encola en pendientes.json todo lo que quiere cambiar (exclusiones y uso
#  del disco) y lo aplica de una vez con "Aplicar cambios y reiniciar". Dos razones:
#  la GUI puede mostrar lo decidido aunque UWF no este disponible todavia en el equipo,
#  y nada queda a medias: lo que no se puede aplicar ahora se conserva en la cola para
#  aplicarse en el arranque siguiente.
# -----------------------------------------------------------------------------
function Nueva-ColaPendientes {
    return [pscustomobject]@{
        exclusiones = (New-Object System.Collections.ArrayList)
        disco       = $null
    }
}

function Test-PendientesVacios($p) {
    return (($p.exclusiones.Count -eq 0) -and (-not $p.disco))
}

function Leer-Pendientes {
    # Descarta entradas corruptas en vez de fallar: la cola no debe poder dejar la GUI inservible.
    $p = Nueva-ColaPendientes
    if (Test-Path -LiteralPath $script:PendPath) {
        try {
            $guardado = Get-Content -LiteralPath $script:PendPath -Raw | ConvertFrom-Json
            foreach ($e in @($guardado.exclusiones)) {
                if (-not $e) { continue }
                if ((@('archivo','registro') -contains $e.tipo) -and
                    (@('add','remove') -contains $e.accion) -and $e.valor) {
                    [void]$p.exclusiones.Add([pscustomobject]@{
                        tipo   = [string]$e.tipo
                        accion = [string]$e.accion
                        valor  = [string]$e.valor
                    })
                }
            }
            $d = $guardado.disco
            if ($d -and (@('RAM','Disco') -contains $d.tipo) -and
                (Test-UmbralesValidos ([int]$d.avisoMB) ([int]$d.criticoMB) ([int]$d.tamanoMB))) {
                $p.disco = [pscustomobject]@{
                    tipo      = [string]$d.tipo
                    tamanoMB  = [int]$d.tamanoMB
                    avisoMB   = [int]$d.avisoMB
                    criticoMB = [int]$d.criticoMB
                }
            }
        } catch { }
    }
    return $p
}

function Guardar-Pendientes($p) {
    Inicializar-Carpeta
    if (Test-PendientesVacios $p) {
        Remove-Item -LiteralPath $script:PendPath -Force -ErrorAction SilentlyContinue
        return
    }
    [pscustomobject]@{
        version     = 1
        actualizado = (Get-Date).ToString('s')
        tecnico     = $env:USERNAME
        equipo      = $env:COMPUTERNAME
        exclusiones = @($p.exclusiones)
        disco       = $p.disco
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:PendPath -Encoding UTF8
}

function Valor-Pendiente([string]$Tipo, [string]$Valor) {
    # Forma canonica con la que se compara y se guarda un valor encolado
    if ($Tipo -eq 'registro') { return (Normalizar-ClaveRegistro $Valor) }
    return $Valor.Trim().TrimEnd('\')
}

function Add-PendienteExclusion($p, [string]$Tipo, [string]$Accion, [string]$Valor) {
    # Valida al encolar, no al aplicar, para que el tecnico vea el error en el momento en que
    # lo decide. Si ya habia encolado el pendiente opuesto sobre el mismo valor, se anulan
    # entre si: vuelve al estado que tiene el equipo ahora. Devuelve $true si la cola cambio.
    $v = Valor-Pendiente $Tipo $Valor
    if (-not $v) { throw 'Ruta o clave vacia.' }
    if ($Accion -eq 'add') {
        if ($Tipo -eq 'archivo' -and (Test-ExclusionPeligrosa $v)) {
            throw "Ruta prohibida: excluirla rompe Windows Update ($v)"
        }
        if ($Tipo -eq 'registro' -and $v -notmatch '^HKLM\\') {
            throw 'UWF solo admite exclusiones de registro bajo HKLM.'
        }
    }

    foreach ($e in @($p.exclusiones)) {
        if ($e.tipo -eq $Tipo -and (Valor-Pendiente $Tipo $e.valor) -eq $v) {
            if ($e.accion -eq $Accion) { return $false }
            [void]$p.exclusiones.Remove($e)
            return $true
        }
    }

    [void]$p.exclusiones.Add([pscustomobject]@{ tipo = $Tipo; accion = $Accion; valor = $v })
    return $true
}

function Remove-PendienteExclusion($p, [string]$Tipo, [string]$Valor) {
    $v = Valor-Pendiente $Tipo $Valor
    $quitar = @($p.exclusiones | Where-Object { $_.tipo -eq $Tipo -and (Valor-Pendiente $Tipo $_.valor) -eq $v })
    foreach ($e in $quitar) { [void]$p.exclusiones.Remove($e) }
    return ($quitar.Count -gt 0)
}

function Set-PendienteDisco($p, [string]$Tipo, [int]$TamanoMB, [int]$AvisoMB, [int]$CriticoMB) {
    if (@('RAM','Disco') -notcontains $Tipo) { throw "Tipo no valido: $Tipo" }
    if (-not (Test-UmbralesValidos $AvisoMB $CriticoMB $TamanoMB)) {
        throw "Umbrales no validos: debe cumplirse aviso < critico <= tamano (has puesto $AvisoMB / $CriticoMB / $TamanoMB MB)."
    }
    $p.disco = [pscustomobject]@{
        tipo      = $Tipo
        tamanoMB  = $TamanoMB
        avisoMB   = $AvisoMB
        criticoMB = $CriticoMB
    }
}

function Test-DiscoPendienteExigeFiltroOff($p, $uwf) {
    # True si el pendiente de disco cambia tipo o tamano, que UWF solo admite con el filtro
    # desactivado. Si solo cambian los umbrales no hace falta ventana de mantenimiento.
    if (-not $p.disco) { return $false }
    if (-not $uwf.Instalado) { return $true }
    return (($p.disco.tipo -ne $uwf.OverlayTipo) -or ([int]$p.disco.tamanoMB -ne [int]$uwf.OverlayMaxMB))
}

function Get-ResumenPendientes($p) {
    $lineas = New-Object System.Collections.ArrayList
    foreach ($e in @($p.exclusiones)) {
        $verbo = if ($e.accion -eq 'add') { 'Anadir' } else { 'Quitar' }
        $que   = if ($e.tipo -eq 'archivo') { 'carpeta/archivo' } else { 'clave de registro' }
        [void]$lineas.Add("$verbo ${que}: $($e.valor)")
    }
    if ($p.disco) {
        [void]$lineas.Add("Uso del disco: $($p.disco.tipo), $($p.disco.tamanoMB) MB (aviso $($p.disco.avisoMB), critico $($p.disco.criticoMB))")
    }
    return $lineas
}

function Aplicar-Pendientes([bool]$FiltroActivo) {
    # Aplica todo lo encolado que se pueda aplicar ahora y conserva el resto en la cola.
    # Exclusiones y umbrales se pueden registrar con el filtro activo o no (surten efecto tras
    # reiniciar). El tipo y el tamano exigen el filtro desactivado: con la proteccion activa se
    # quedan encolados para aplicarse en el arranque de mantenimiento.
    $p = Leer-Pendientes
    $res = [pscustomobject]@{
        Aplicados          = (New-Object System.Collections.ArrayList)
        Errores            = (New-Object System.Collections.ArrayList)
        Restantes          = 0
        EsperandoFiltroOff = $false
    }
    if (Test-PendientesVacios $p) { return $res }

    $quedan = New-Object System.Collections.ArrayList
    foreach ($e in @($p.exclusiones)) {
        $etiqueta = "$(if ($e.accion -eq 'add') {'anadir'} else {'quitar'}) $($e.valor)"
        try {
            if ($e.tipo -eq 'archivo') {
                if ($e.accion -eq 'add') { Add-ExclusionArchivo $e.valor } else { Remove-ExclusionArchivo $e.valor }
            } else {
                if ($e.accion -eq 'add') { Add-ExclusionRegistro $e.valor } else { Remove-ExclusionRegistro $e.valor }
            }
            [void]$res.Aplicados.Add($etiqueta)
        } catch {
            [void]$res.Errores.Add("$etiqueta -> $($_.Exception.Message)")
            [void]$quedan.Add($e)
        }
    }

    $discoQueda = $null
    if ($p.disco) {
        try {
            $errU = @(Aplicar-Umbrales ([int]$p.disco.avisoMB) ([int]$p.disco.criticoMB))
            if ($errU.Count -gt 0) {
                foreach ($x in $errU) { [void]$res.Errores.Add($x) }
            } else {
                [void]$res.Aplicados.Add("umbrales $($p.disco.avisoMB) / $($p.disco.criticoMB) MB")
            }

            if ($FiltroActivo) {
                # Tipo y tamano no se pueden tocar con la proteccion activa. Solo se quedan
                # encolados si de verdad cambian algo: si ya coinciden, no hay nada que hacer.
                if (Test-DiscoPendienteExigeFiltroOff $p (Get-EstadoUwf)) {
                    $discoQueda = $p.disco
                    $res.EsperandoFiltroOff = $true
                } else {
                    [void]$res.Aplicados.Add("uso del disco: ya estaba en $($p.disco.tipo), $($p.disco.tamanoMB) MB")
                }
            } else {
                $errT = @(Aplicar-TipoTamano ([string]$p.disco.tipo) ([int]$p.disco.tamanoMB))
                if ($errT.Count -gt 0) {
                    foreach ($x in $errT) { [void]$res.Errores.Add($x) }
                    $discoQueda = $p.disco
                } else {
                    [void]$res.Aplicados.Add("uso del disco $($p.disco.tipo), $($p.disco.tamanoMB) MB")
                }
            }
        } catch {
            [void]$res.Errores.Add("uso del disco -> $($_.Exception.Message)")
            $discoQueda = $p.disco
        }
    }

    $cola = Nueva-ColaPendientes
    foreach ($e in $quedan) { [void]$cola.exclusiones.Add($e) }
    $cola.disco = $discoQueda
    Guardar-Pendientes $cola

    $res.Restantes = $quedan.Count + $(if ($discoQueda) { 1 } else { 0 })
    Escribir-Log 'AplicarPendientes' `
        $(if ($res.Errores.Count -eq 0 -and $res.Restantes -eq 0) {'OK'} else {'PARCIAL'}) `
        ("aplicados=$($res.Aplicados.Count) restantes=$($res.Restantes) errores=$($res.Errores.Count)")
    return $res
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
            if ($p.Length -ge 4 -and $script:TerminosGenericos -notcontains $p) { [void]$terminos.Add($p) }
        }
        if ($Fabricante) {
            $f = ($Fabricante -split '[,\s]+')[0]
            if ($f.Length -ge 4 -and $script:TerminosGenericos -notcontains $f -and $terminos -notcontains $f) {
                [void]$terminos.Add($f)
            }
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

        $carpetas = @($carpetas | Where-Object { $script:RaicesSistema -notcontains $_.ToUpper().TrimEnd('\') })
        $claves   = @($claves   | Where-Object { $script:RaicesSistema -notcontains $_.ToUpper().TrimEnd('\') })
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
function Get-Huella([string]$ruta) {
    # Hash SHA-256 de un fichero. Sirve para saber si la copia instalada es exactamente la
    # misma que se esta ejecutando, sin depender de un numero de version que hay que recordar
    # subir a mano en cada compilacion.
    return (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash
}

function Detectar-Instalacion([string]$Origen) {
    # Mira que hay instalado ya en ProgramData. 'EsLaMisma' compara con lo que se esta
    # ejecutando: si coincide, no hay nada que sustituir.
    $r = [pscustomobject]@{ Existe = $false; Bytes = 0; Huella = ''; EsLaMisma = $false }
    if (-not (Test-Path -LiteralPath $script:ScriptDest)) { return $r }
    $r.Existe = $true
    try {
        $r.Bytes  = (Get-Item -LiteralPath $script:ScriptDest).Length
        $r.Huella = Get-Huella $script:ScriptDest
        if ($Origen -and (Test-Path -LiteralPath $Origen)) {
            $r.EsLaMisma = ($r.Huella -eq (Get-Huella $Origen))
        }
    } catch { }
    return $r
}

function Detener-Tarea {
    # Termina la instancia en curso de la tarea del vigilante, si la hay. Hace falta porque el
    # vigilante arranca con el equipo: si todavia corre, su fichero esta en uso.
    try { & schtasks.exe /end /tn $script:Tarea 2>&1 | Out-Null } catch { }
}

function Limpiar-Restos {
    # Borra los apartados .old-* de sustituciones anteriores y el .exe suelto que pudiera
    # haber dejado una instalacion empaquetada cuando ahora se ejecuta el .ps1.
    $borrados = New-Object System.Collections.ArrayList
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $script:Base -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -like '*.old-*') {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    [void]$borrados.Add($f.Name)
                } catch { }   # sigue en uso: se intentara en el proximo arranque
            }
        }
    } catch { }
    return $borrados
}

function Reemplazar-Instalado([string]$Origen) {
    # Sustituye la copia de ProgramData por la version que se esta ejecutando ahora.
    #
    # Tres intentos, de menos a mas invasivo, porque Windows no permite sobrescribir un
    # fichero en uso:
    #   1. Copiar encima.
    #   2. Terminar la tarea del vigilante (que es quien suele tenerlo abierto) y repetir.
    #   3. Apartar el instalado a un '.old-<fecha>' y copiar la nueva al lado. Renombrar un
    #      ejecutable en uso si esta permitido; el .old se borra en la siguiente ejecucion.
    #
    # Devuelve (Accion, Detalle). Lanza excepcion solo si los tres fallan, para que quien
    # llama pueda avisar al tecnico: una copia instalada vieja con una GUI nueva es peligrosa,
    # porque el vigilante antiguo no conoce la fase 'aplicando'.
    $previo = Detectar-Instalacion $Origen

    if (-not $previo.Existe) {
        Copy-Item -LiteralPath $Origen -Destination $script:ScriptDest -Force
        return @('instalado', 'primera instalacion en este equipo')
    }
    if ($previo.EsLaMisma) {
        return @('sin cambios', 'la copia instalada ya es esta misma version')
    }

    $detalle = "$($previo.Bytes) -> $((Get-Item -LiteralPath $Origen).Length) bytes"

    try {
        Copy-Item -LiteralPath $Origen -Destination $script:ScriptDest -Force -ErrorAction Stop
        return @('sustituido', $detalle)
    } catch { }

    Detener-Tarea
    try {
        Copy-Item -LiteralPath $Origen -Destination $script:ScriptDest -Force -ErrorAction Stop
        return @('sustituido', "$detalle (tras detener la tarea)")
    } catch { }

    $apartado = "$($script:ScriptDest).old-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Move-Item -LiteralPath $script:ScriptDest -Destination $apartado -Force -ErrorAction Stop
    Copy-Item -LiteralPath $Origen -Destination $script:ScriptDest -Force
    return @('sustituido', "$detalle (la anterior estaba en uso, apartada como $(Split-Path $apartado -Leaf))")
}

function Instalar-Vigilante {
    # Se ejecuta en cada arranque de la GUI, no solo la primera vez, para que actualizar un
    # equipo sea solo abrir la version nueva.
    Inicializar-Carpeta
    $origen = $PSCommandPath
    if ($origen -and ($origen -ne $script:ScriptDest)) {
        $res = Reemplazar-Instalado $origen
        if ($res[0] -ne 'sin cambios') {
            Escribir-Log 'ActualizarInstalacion' 'OK' "$($res[0]): $($res[1])"
        }
        $restos = @(Limpiar-Restos)
        if ($restos.Count) { Escribir-Log 'LimpiarRestos' 'OK' ($restos -join ', ') }
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

function Iniciar-AplicacionPendientes {
    # Abre una ventana de mantenimiento automatica, solo para aplicar los pendientes que exigen
    # el filtro desactivado (tipo y tamano del uso del disco). Se distingue de un mantenimiento
    # normal por la fase 'aplicando': el vigilante la reconoce en el arranque siguiente, aplica
    # la cola, vuelve a proteger el equipo y reinicia sin que el tecnico haga nada mas.
    $r = Invoke-Uwf @('filter','disable')
    if (-not $r.Ok) { throw "No se ha podido desactivar el filtro: $($r.Salida)" }
    Guardar-Estado 'aplicando'
    Escribir-Log 'IniciarAplicacionPendientes' 'OK' 'filtro desactivado para aplicar la cola, pendiente de reinicio'
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
        'aplicando' {
            # El equipo ha arrancado sin proteccion solo para volcar la cola. Pase lo que pase con
            # los pendientes, el filtro tiene que quedar activo otra vez antes de devolver el
            # equipo al aula.
            if ($uwf.FiltroActual) {
                Escribir-Log 'Vigilante' 'ERROR' 'Se esperaba el filtro desactivado para aplicar la cola; se deja para el tecnico'
                Guardar-Estado 'verificando'
                return
            }
            try {
                $res = Aplicar-Pendientes $false
                Escribir-Log 'Vigilante' `
                    $(if ($res.Errores.Count -eq 0 -and $res.Restantes -eq 0) {'OK'} else {'PARCIAL'}) `
                    ("Cola aplicada: $($res.Aplicados.Count) cambios, $($res.Restantes) restantes, $($res.Errores.Count) errores")
                foreach ($err in $res.Errores) { Escribir-Log 'Vigilante' 'ERROR' $err }
            } catch {
                Escribir-Log 'Vigilante' 'ERROR' ("Al aplicar la cola: " + $_.Exception.Message)
            }
            try {
                $r = Invoke-Uwf @('filter','enable')
                if (-not $r.Ok) { Escribir-Log 'Vigilante' 'ERROR' "No se ha podido reactivar el filtro: $($r.Salida)" }
                Guardar-Estado 'verificando'
                Reiniciar-Equipo 'cierre automatico tras aplicar los cambios pendientes'
            } catch {
                Escribir-Log 'Vigilante' 'ERROR' $_.Exception.Message
            }
        }
        'verificando' {
            if ($uwf.FiltroActual) {
                Escribir-Log 'Vigilante' 'OK' 'Mantenimiento cerrado, filtro activo y verificado'
                Guardar-Estado $null
            } else {
                # Tope de reintentos: si 'filter enable' no consigue nada, reiniciar sin limite
                # dejaria el equipo en un bucle de reinicios que solo se arregla yendo al aula.
                $intentos = 0
                try { $intentos = [int]$estado.intentos } catch { }
                if ($intentos -ge $script:MaxReintentosFiltro) {
                    Escribir-Log 'Vigilante' 'ERROR' "El filtro sigue sin activarse tras $intentos intentos. No se reinicia mas: hace falta revisar el equipo"
                    return
                }
                Escribir-Log 'Vigilante' 'ERROR' "El filtro deberia estar activo y no lo esta. Reintento $($intentos + 1) de $($script:MaxReintentosFiltro)"
                try {
                    $r = Invoke-Uwf @('filter','enable')
                    if (-not $r.Ok) {
                        Escribir-Log 'Vigilante' 'ERROR' ("filter enable: " + (($r.Salida -replace ';', ',') -replace '\s+', ' '))
                    }
                    Guardar-Estado 'verificando' '' ($intentos + 1)
                    Reiniciar-Equipo 'reactivando proteccion'
                } catch {
                    Escribir-Log 'Vigilante' 'ERROR' $_.Exception.Message
                }
            }
        }
        'mantenimiento' {
            # Arranque de mantenimiento: se aprovecha que no hay proteccion para volcar la cola.
            # Aqui no se reinicia, porque el tecnico esta trabajando en el equipo.
            if (-not $uwf.FiltroActual -and -not (Test-PendientesVacios (Leer-Pendientes))) {
                try {
                    $res = Aplicar-Pendientes $false
                    Escribir-Log 'Vigilante' `
                        $(if ($res.Errores.Count -eq 0 -and $res.Restantes -eq 0) {'OK'} else {'PARCIAL'}) `
                        ("Cola aplicada en mantenimiento: $($res.Aplicados.Count) cambios, $($res.Restantes) restantes, $($res.Errores.Count) errores")
                    foreach ($err in $res.Errores) { Escribir-Log 'Vigilante' 'ERROR' $err }
                } catch {
                    Escribir-Log 'Vigilante' 'ERROR' ("Al aplicar la cola en mantenimiento: " + $_.Exception.Message)
                }
            }

            $max = 8
            try { if ($cfg.horasMaxMantenimiento) { $max = [double]$cfg.horasMaxMantenimiento } } catch { }
            try {
                $horas = ((Get-Date) - [datetime]$estado.inicio).TotalHours
            } catch {
                # Sin fecha legible no se puede saber cuanto lleva abierto: ante la duda se
                # protege el equipo, que es el fallo menos grave.
                Escribir-Log 'Vigilante' 'AVISO' 'estado.json sin fecha de inicio valida'
                $horas = $max
            }
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
#  Instalar la caracteristica UWF
# -----------------------------------------------------------------------------
function Get-System32 {
    # Un proceso de 32 bits en un Windows de 64 ve 'System32' redirigido a SysWOW64, y DISM no
    # puede trabajar desde ahi: 'Sysnative' es el alias que lleva a los binarios reales de 64
    # bits. PowerShell de 32 bits es posible en equipos gestionados, asi que conviene cubrirlo.
    $raiz = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\WINDOWS' }
    if (-not [Environment]::Is64BitProcess) {
        $nativo = Join-Path $raiz 'Sysnative'
        if (Test-Path -LiteralPath $nativo) { return $nativo }
    }
    return (Join-Path $raiz 'System32')
}

function Invoke-Oculto([string]$Ejecutable, [string[]]$Argumentos) {
    # Devuelve @{ Codigo; Salida }. Dos precauciones de PowerShell 5.1:
    #  - $ErrorActionPreference local a 'Continue': el script corre con 'Stop' y una simple
    #    linea en stderr de un ejecutable nativo se convertiria en error terminante.
    #  - El codigo se lee de $LASTEXITCODE, porque $? no refleja de forma fiable el codigo de
    #    salida de un ejecutable nativo.
    $ErrorActionPreference = 'Continue'
    $salida = ''
    try {
        $salida = Convertir-SalidaNativa (& $Ejecutable @Argumentos 2>&1)
    } catch {
        return [pscustomobject]@{ Codigo = -1; Salida = $_.Exception.Message }
    }
    return [pscustomobject]@{ Codigo = $LASTEXITCODE; Salida = $salida }
}

function Get-EstadoCaracteristicaUwf {
    # Estado de la caracteristica UWF segun DISM, sin depender del idioma del sistema: se
    # fuerza '/English' justo para no parsear texto traducido, igual que el resto del proyecto
    # evita leer la salida localizada de uwfmgr.
    # Devuelve 'Enabled', 'EnablePending', 'Disabled', 'NoDisponible' o 'Desconocido'.
    $dism = Join-Path (Get-System32) 'dism.exe'
    $r = Invoke-Oculto $dism @('/online','/get-featureinfo',"/featurename:$script:Caracteristica",'/english')
    $bajo = $r.Salida.ToLower()
    if ($bajo -match '0x800f080c' -or $bajo -match 'is unknown') { return 'NoDisponible' }
    $m = [regex]::Match($r.Salida, '(?m)^\s*State\s*:\s*(\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'Desconocido'
}

function Instalar-CaracteristicaUwf {
    # Habilita la caracteristica opcional Unified Write Filter. Requiere reiniciar despues.
    #
    # Dos motores, porque en un equipo gestionado el primero puede no estar disponible:
    #   1. dism.exe directamente, que no depende de los cmdlets de PowerShell (AppLocker o el
    #      modo ConstrainedLanguage pueden bloquearlos sin bloquear dism.exe).
    #   2. Enable-WindowsOptionalFeature, como respaldo.
    #
    # El resultado se comprueba releyendo el estado, no fiandose del codigo de salida, y se
    # registra SIEMPRE en el log, tambien cuando falla: sin eso, un fallo en un aula no deja
    # rastro con el que diagnosticar. Devuelve el estado final.
    $previo = Get-EstadoCaracteristicaUwf
    if ($previo -eq 'NoDisponible') {
        Escribir-Log 'InstalarCaracteristica' 'ERROR' "esta edicion de Windows no incluye UWF ($script:Caracteristica)"
        throw ("Esta edicion de Windows no incluye el Unified Write Filter.`n`n" +
               'UWF solo esta disponible en Windows 10/11 Enterprise, Education e IoT ' +
               'Enterprise. Comprueba la edicion con "winver".')
    }
    if (@('Enabled','EnablePending') -contains $previo) {
        Escribir-Log 'InstalarCaracteristica' 'OK' "ya estaba habilitada: $previo"
        return $previo
    }

    $intentos = New-Object System.Collections.ArrayList

    # Sin ';' en el detalle: es el separador de columnas del log CSV
    $resumir = {
        param($motor, $res)
        $txt = ($res.Salida -replace ';', ',' -replace '\s+', ' ').Trim()
        "$motor codigo=$($res.Codigo) $($txt.Substring(0, [Math]::Min(300, $txt.Length)))"
    }
    $algunoOk = $false

    $dism = Join-Path (Get-System32) 'dism.exe'
    $r = Invoke-Oculto $dism @('/online','/enable-feature',"/featurename:$script:Caracteristica",'/norestart','/quiet','/english')
    [void]$intentos.Add((& $resumir 'dism' $r))

    # 0 = hecho, 3010 = hecho pero pide reinicio
    if (@(0, 3010) -contains $r.Codigo) {
        $algunoOk = $true
    } else {
        $ps = Join-Path (Get-System32) 'WindowsPowerShell\v1.0\powershell.exe'
        $orden = "Enable-WindowsOptionalFeature -Online -FeatureName '$script:Caracteristica' -NoRestart -ErrorAction Stop | Out-Null"
        $r2 = Invoke-Oculto $ps @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',$orden)
        [void]$intentos.Add((& $resumir 'powershell' $r2))
        if (@(0, 3010) -contains $r2.Codigo) { $algunoOk = $true }
    }

    $detalle = $intentos -join ' | '
    $final = Get-EstadoCaracteristicaUwf
    # Si algun motor dijo que lo hizo pero no se puede releer el estado, se da por bueno
    if ($final -eq 'Desconocido' -and $algunoOk) { $final = 'EnablePending' }

    if (@('Enabled','EnablePending') -contains $final) {
        Escribir-Log 'InstalarCaracteristica' 'OK' "estado=$final, $detalle"
        return $final
    }

    Escribir-Log 'InstalarCaracteristica' 'ERROR' "estado=$final, $detalle"
    throw "No se ha podido habilitar UWF.`n`nEstado de la caracteristica: $final`n`n$detalle"
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

        # Solo se premarca lo del catalogo, que esta verificado; lo de la heuristica es una
        # busqueda por nombre y el tecnico tiene que elegirlo a conciencia.
        $marcar = ($prop.Origen -eq 'catalogo')
        foreach ($c in $prop.Carpetas) { [void]$lista.Items.Add("CARPETA  $c", $marcar) }
        foreach ($k in $prop.Claves)   { [void]$lista.Items.Add("REGISTRO $k", $marcar) }

        if ($lista.Items.Count -eq 0) {
            $lblOrigen.Text = 'No se ha encontrado ninguna carpeta ni clave asociada a este programa. Anadela a mano desde la pestana Exclusiones.'
        } elseif ($prop.Origen -eq 'catalogo') {
            $lblOrigen.Text = 'Programa reconocido: estas rutas son las recomendadas y estan verificadas en este equipo.'
            $btnOk.Enabled = $true
        } else {
            $lblOrigen.Text = 'Programa fuera del catalogo: las rutas son una busqueda automatica por nombre. Marca solo las que sepas que pertenecen a este programa.'
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
    $form.Size            = New-Object System.Drawing.Size(940, 730)
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
    $tabOverlay = New-Object System.Windows.Forms.TabPage; $tabOverlay.Text = 'Uso del disco'
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

    # ---- Barra de cambios pendientes (visible desde cualquier pestana) ----
    # Es el unico punto donde se aplica algo: el resto de la ventana solo encola.
    $barraPend          = New-Object System.Windows.Forms.Panel
    $barraPend.Dock     = 'Bottom'
    $barraPend.Height   = 56
    $barraPend.BorderStyle = 'FixedSingle'

    $lblPend            = New-Object System.Windows.Forms.Label
    $lblPend.Location   = New-Object System.Drawing.Point(12, 8)
    $lblPend.Size       = New-Object System.Drawing.Size(560, 40)
    $lblPend.Font       = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblPend.Anchor     = 'Top,Left,Right'

    $btnAplicarPend          = New-Object System.Windows.Forms.Button
    $btnAplicarPend.Text     = 'Aplicar cambios y reiniciar'
    $btnAplicarPend.Location = New-Object System.Drawing.Point(588, 11)
    $btnAplicarPend.Size     = New-Object System.Drawing.Size(200, 34)
    $btnAplicarPend.Anchor   = 'Top,Right'
    $btnAplicarPend.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $btnDescartarPend          = New-Object System.Windows.Forms.Button
    $btnDescartarPend.Text     = 'Descartar'
    $btnDescartarPend.Location = New-Object System.Drawing.Point(798, 11)
    $btnDescartarPend.Size     = New-Object System.Drawing.Size(110, 34)
    $btnDescartarPend.Anchor   = 'Top,Right'

    # Ancho real antes de meter los botones anclados a la derecha (ver nota mas abajo)
    $barraPend.Width = $form.ClientSize.Width
    $barraPend.Controls.AddRange(@($lblPend, $btnAplicarPend, $btnDescartarPend))
    $form.Controls.Add($barraPend)

    # El orden de acoplado va del final de la coleccion al principio: la barra de estado
    # tiene que acoplarse primera para quedar en el borde inferior, y las pestanas ultimas
    # para quedarse con el espacio restante.
    $barra.SendToBack()
    $tabs.BringToFront()

    # Un control anclado abajo o a la derecha calcula su distancia al borde con el tamano que
    # tiene el contenedor en el momento de anadirlo. Un TabPage recien creado mide 200x100
    # hasta que la ventana se muestra, asi que al crecer empujaba fuera de la vista todo lo
    # anclado abajo (los botones de la pestana Exclusiones no se veian). Se fija aqui su
    # tamano real, antes de colocar nada dentro.
    $form.PerformLayout()
    [void]$tabs.Handle
    foreach ($pg in $tabs.TabPages) { $pg.Bounds = $tabs.DisplayRectangle }

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
    $lblResumenExcl = New-Object System.Windows.Forms.Label
    $lblResumenExcl.Location = New-Object System.Drawing.Point(16, 8)
    $lblResumenExcl.Size = New-Object System.Drawing.Size(880, 22)
    $lblResumenExcl.Anchor = 'Top,Left,Right'
    $lblResumenExcl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $tabExcl.Controls.Add($lblResumenExcl)

    $lv              = New-Object System.Windows.Forms.ListView
    $lv.View         = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines    = $true
    $lv.Location     = New-Object System.Drawing.Point(16, 34)
    $lv.Size         = New-Object System.Drawing.Size(880, 362)
    $lv.Anchor       = 'Top,Left,Right,Bottom'
    [void]$lv.Columns.Add('Estado', 190)
    [void]$lv.Columns.Add('Tipo', 80)
    [void]$lv.Columns.Add('Ruta o clave', 470)
    [void]$lv.Columns.Add('Existe', 130)
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
    $lblAviso.Text = 'Los cambios se quedan en la lista como PENDIENTES hasta que pulses "Aplicar cambios y reiniciar" abajo. Todo lo excluido se guarda de verdad en el disco: excluye lo minimo.'
    $lblAviso.Location = New-Object System.Drawing.Point(16, 448)
    $lblAviso.Size = New-Object System.Drawing.Size(880, 34)
    $lblAviso.Anchor = 'Bottom,Left,Right'
    $lblAviso.ForeColor = [System.Drawing.Color]::FromArgb(150, 80, 0)

    $tabExcl.Controls.AddRange(@($btnAddPrograma, $btnAddCarpeta, $btnAddArchivo, $btnAddReg, $btnQuitar, $btnImportar, $btnExportar, $lblAviso))

    # ======================== PESTANA USO DEL DISCO ==========================
    $lblOv1          = New-Object System.Windows.Forms.Label
    # Sin saltos de linea a mano dentro de cada parrafo: el texto se reparte solo en el ancho
    # disponible. Con los saltos fijos ocupaba mas de lo que cabe y las dos ultimas lineas
    # (justo las que explican cuando se puede cambiar el tamano) quedaban tapadas.
    $lblOv1.Text     = ("Mientras la proteccion esta activa, todo lo que el profesor escribe en el equipo no va al disco de verdad: se guarda en un espacio aparte que se vacia al reiniciar. Aqui se decide cuanto espacio se reserva para eso y donde.`n`n" +
        "- Disco: reserva el espacio en C:. Recomendado para las aulas: no resta memoria al equipo.`n" +
        "- RAM:   mas rapido, pero consume memoria fisica segun se llena. Solo para equipos con mucha RAM.`n`n" +
        'Los cambios de aqui tampoco se aplican al momento: se encolan como pendientes. El tamano y el sitio solo pueden cambiarse con la proteccion desactivada, asi que si hace falta se abrira la ventana de mantenimiento sola al aplicar.')
    $lblOv1.Location = New-Object System.Drawing.Point(16, 16)
    $lblOv1.Size     = New-Object System.Drawing.Size(880, 160)
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
    $btnAplicarOv.Text     = 'Anadir a los cambios pendientes'
    $btnAplicarOv.Location = New-Object System.Drawing.Point(16, 284)
    $btnAplicarOv.Size     = New-Object System.Drawing.Size(280, 40)
    $btnAplicarOv.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

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
            $pend = Leer-Pendientes
            $lineasPend = @(Get-ResumenPendientes $pend)

            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("Equipo              : $env:COMPUTERNAME")
            [void]$sb.AppendLine("Caracteristica UWF  : " + $(if ($u.Instalado) {'instalada'} else {'NO instalada'}))
            [void]$sb.AppendLine("Filtro (sesion act.): " + $(if ($u.FiltroActual) {'ACTIVO'} else {'DESACTIVADO'}))
            [void]$sb.AppendLine("Filtro (tras reinic): " + $(if ($u.FiltroSiguiente) {'ACTIVO'} else {'DESACTIVADO'}))
            [void]$sb.AppendLine("Volumenes protegidos: " + $(if ($u.VolumenesActual.Count) { $u.VolumenesActual -join ', ' } else {'ninguno'}))
            [void]$sb.AppendLine("Uso del disco       : $($u.OverlayTipo), maximo $($u.OverlayMaxMB) MB")
            [void]$sb.AppendLine("Umbrales            : aviso $($u.OverlayAvisoMB) MB, critico $($u.OverlayCriticoMB) MB")
            if ($u.OverlayUsoMB -ge 0) {
                [void]$sb.AppendLine("Espacio consumido   : $($u.OverlayUsoMB) MB")
            }
            [void]$sb.AppendLine('')
            if ($es) {
                [void]$sb.AppendLine("Mantenimiento       : fase '$($es.fase)' iniciada el $($es.inicio) por $($es.tecnico)")
            } else {
                [void]$sb.AppendLine('Mantenimiento       : ninguno en curso')
            }
            [void]$sb.AppendLine("Cambios pendientes  : " + $(if ($lineasPend.Count) { "$($lineasPend.Count) sin aplicar" } else {'ninguno'}))
            if ($u.Error) { [void]$sb.AppendLine(''); [void]$sb.AppendLine("Aviso: $($u.Error)") }
            $txtEstado.Text = $sb.ToString()

            if ($u.OverlayMaxMB -gt 0 -and $u.OverlayUsoMB -ge 0) {
                $barraOverlay.Maximum = [int]$u.OverlayMaxMB
                $barraOverlay.Value   = [Math]::Min([int]$u.OverlayUsoMB, [int]$u.OverlayMaxMB)
            }

            # Banner
            $faseAbierta = if ($es) { $es.fase } else { $null }
            if ((@('mantenimiento','aplicando') -contains $faseAbierta) -and -not $u.FiltroActual) {
                $banner.BackColor  = [System.Drawing.Color]::FromArgb(178, 34, 34)
                $lblBanner.Text    = if ($faseAbierta -eq 'aplicando') {
                    'APLICANDO CAMBIOS PENDIENTES  -  EL EQUIPO NO ESTA PROTEGIDO'
                } else {
                    'MANTENIMIENTO EN CURSO  -  EL EQUIPO NO ESTA PROTEGIDO'
                }
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

            # Pestana Uso del disco: si hay algo encolado se muestran los valores pendientes
            # (son los que el tecnico acaba de decidir); si no, el estado real del equipo.
            if ($pend.disco) {
                if ($pend.disco.tipo -eq 'RAM') { $radRam.Checked = $true } else { $radDisco.Checked = $true }
                $numTam.Value = [Math]::Min([Math]::Max([int]$pend.disco.tamanoMB,  $numTam.Minimum), $numTam.Maximum)
                $numAv.Value  = [Math]::Min([Math]::Max([int]$pend.disco.avisoMB,   $numAv.Minimum),  $numAv.Maximum)
                $numCr.Value  = [Math]::Min([Math]::Max([int]$pend.disco.criticoMB, $numCr.Minimum),  $numCr.Maximum)
                $lblOvEstado.Text = 'Estos valores estan PENDIENTES: todavia no son los del equipo. Pulsa "Aplicar cambios y reiniciar" abajo para que surtan efecto, o "Descartar" para volver a la configuracion real.'
                $lblOvEstado.ForeColor = [System.Drawing.Color]::FromArgb(31, 95, 169)
            } elseif ($u.Instalado) {
                if ($u.OverlayTipo -eq 'RAM') { $radRam.Checked = $true } else { $radDisco.Checked = $true }
                if ($u.OverlayMaxMB   -ge $numTam.Minimum) { $numTam.Value = [Math]::Min($u.OverlayMaxMB,   $numTam.Maximum) }
                if ($u.OverlayAvisoMB -ge $numAv.Minimum)  { $numAv.Value  = [Math]::Min($u.OverlayAvisoMB, $numAv.Maximum) }
                if ($u.OverlayCriticoMB -ge $numCr.Minimum){ $numCr.Value  = [Math]::Min($u.OverlayCriticoMB,$numCr.Maximum) }
                if ($u.FiltroActual) {
                    $lblOvEstado.Text = 'La proteccion esta ACTIVA: el tamano y el sitio no se pueden cambiar ahora. Si los cambias, al aplicar se abrira la ventana de mantenimiento sola y el equipo se reiniciara dos veces.'
                    $lblOvEstado.ForeColor = [System.Drawing.Color]::FromArgb(150, 80, 0)
                } else {
                    $lblOvEstado.Text = 'La proteccion esta desactivada: se puede cambiar todo. Los cambios se aplican tras reiniciar.'
                    $lblOvEstado.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 60)
                }
            } else {
                $lblOvEstado.Text = 'UWF no esta instalado en este equipo: puedes dejar la configuracion preparada como pendiente, pero no se aplicara hasta instalar la caracteristica.'
                $lblOvEstado.ForeColor = [System.Drawing.Color]::Gray
            }

            # Exclusiones: primero la cola de pendientes, que se ve siempre aunque UWF no este
            # disponible en este equipo; despues lo que ya esta permitido en UWF, distinguiendo
            # si vale ya o solo tras reiniciar.
            $lv.Items.Clear()
            $encolados = New-Object System.Collections.ArrayList
            foreach ($e in @($pend.exclusiones)) {
                $esArchivo = ($e.tipo -eq 'archivo')
                $it = New-Object System.Windows.Forms.ListViewItem(
                    $(if ($e.accion -eq 'add') {'PENDIENTE: anadir'} else {'PENDIENTE: quitar'}))
                [void]$it.SubItems.Add($(if ($esArchivo) {'Archivo'} else {'Registro'}))
                [void]$it.SubItems.Add($e.valor)
                $ruta = if ($esArchivo) { $e.valor } else { $e.valor -replace '^HKLM\\', 'HKLM:\' }
                [void]$it.SubItems.Add($(if (Test-Path -LiteralPath $ruta) {'si'} else {'NO EXISTE - revisar'}))
                $it.ForeColor = if ($e.accion -eq 'add') {
                    [System.Drawing.Color]::FromArgb(31, 95, 169)
                } else {
                    [System.Drawing.Color]::FromArgb(178, 34, 34)
                }
                [void]$lv.Items.Add($it)
                [void]$encolados.Add("$($e.tipo)|$(Valor-Pendiente $e.tipo $e.valor)")
            }

            $nArch = 0; $nReg = 0
            $colVerde = [System.Drawing.Color]::FromArgb(30, 120, 60)
            $colAmbar = [System.Drawing.Color]::FromArgb(150, 80, 0)
            $colGris  = [System.Drawing.Color]::FromArgb(128, 128, 128)
            if ($u.Instalado) {
                $detalle = @(Get-ExclusionesDetalle) | Sort-Object @{ Expression = { $_.Tipo -ne 'archivo' } }, @{ Expression = { $_.Valor.ToLower() } }
                foreach ($d in $detalle) {
                    if ($encolados -contains "$($d.Tipo)|$(Valor-Pendiente $d.Tipo $d.Valor)") { continue }
                    if ($d.Ahora -and $d.TrasReinicio) { $texto = 'Permitida';                $color = $colVerde }
                    elseif ($d.TrasReinicio)           { $texto = 'Permitida tras reiniciar'; $color = $colAmbar }
                    else                               { $texto = 'Se quita al reiniciar';    $color = $colAmbar }
                    if ($d.TrasReinicio) { if ($d.Tipo -eq 'archivo') { $nArch++ } else { $nReg++ } }
                    $esArchivo = ($d.Tipo -eq 'archivo')
                    $it = New-Object System.Windows.Forms.ListViewItem($texto)
                    [void]$it.SubItems.Add($(if ($esArchivo) {'Archivo'} else {'Registro'}))
                    [void]$it.SubItems.Add($d.Valor)
                    $ruta = if ($esArchivo) { $d.Valor } else { $d.Valor -replace '^HKLM\\', 'HKLM:\' }
                    if (Test-Path -LiteralPath $ruta) {
                        [void]$it.SubItems.Add('si')
                        $it.ForeColor = $color
                    } else {
                        [void]$it.SubItems.Add('NO EXISTE - revisar')
                        $it.ForeColor = [System.Drawing.Color]::FromArgb(160, 60, 60)
                    }
                    [void]$lv.Items.Add($it)
                }
            }

            if (-not $u.Instalado) {
                $lblResumenExcl.ForeColor = $colGris
                $lblResumenExcl.Text = 'UWF no esta instalado: este equipo no tiene exclusiones permitidas.'
            } elseif ($nArch -or $nReg) {
                $lblResumenExcl.ForeColor = $colVerde
                $lblResumenExcl.Text = "Permitidas en este equipo: $nArch carpeta(s)/archivo(s) y $nReg clave(s) de registro. " +
                                       'Todo lo que no aparece aqui se borra al reiniciar.'
            } else {
                $lblResumenExcl.ForeColor = $colAmbar
                $lblResumenExcl.Text = 'Este equipo no tiene ninguna exclusion permitida: todo se borra al reiniciar.'
            }
            if ($lv.Items.Count -eq 0) {
                $it = New-Object System.Windows.Forms.ListViewItem('')
                [void]$it.SubItems.Add('')
                [void]$it.SubItems.Add('(sin exclusiones ni cambios pendientes)')
                [void]$it.SubItems.Add('')
                $it.ForeColor = $colGris
                [void]$lv.Items.Add($it)
            }

            # Barra de cambios pendientes
            if ($lineasPend.Count) {
                $resumen = ($lineasPend | Select-Object -First 2) -join '  |  '
                if ($lineasPend.Count -gt 2) { $resumen += "  |  y $($lineasPend.Count - 2) mas" }
                $plural = if ($lineasPend.Count -eq 1) { '' } else { 's' }
                $lblPend.Text = "$($lineasPend.Count) cambio$plural pendiente$plural de aplicar:`r`n$resumen"
                $lblPend.ForeColor = [System.Drawing.Color]::FromArgb(31, 95, 169)
                $btnAplicarPend.Enabled   = $true
                $btnDescartarPend.Enabled = $true
            } else {
                $lblPend.Text = "Sin cambios pendientes.`r`nLo que configures en Exclusiones o en Uso del disco aparecera aqui antes de aplicarse."
                $lblPend.ForeColor = [System.Drawing.Color]::Gray
                $btnAplicarPend.Enabled   = $false
                $btnDescartarPend.Enabled = $false
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
        # Puede tardar: DISM trabaja sobre la imagen del sistema.
        try {
            $lblBarra.Text = 'Instalando la caracteristica UWF (puede tardar un minuto)...'
            $form.Cursor = 'WaitCursor'
            $estado = Instalar-CaracteristicaUwf
            $form.Cursor = 'Default'
            & $refrescar
            if ($estado -eq 'Enabled') {
                [System.Windows.Forms.MessageBox]::Show(
                    'La caracteristica UWF ya esta habilitada.', 'UWF Aulas', 'OK', 'Information') | Out-Null
            } else {
                # Ya activa no hace falta reiniciar; si queda pendiente, si
                & $preguntarReinicio 'instalacion de la caracteristica UWF'
            }
        } catch {
            $form.Cursor = 'Default'
            $lblBarra.Text = 'No se ha podido instalar la caracteristica UWF'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    })

    $btnPreparar.Add_Click({
        try {
            $form.Cursor = 'WaitCursor'
            $r = Invoke-Uwf @('volume','protect','C:')
            if (-not $r.Ok) { throw "No se ha podido proteger C: con UWF:`n`n$($r.Salida)" }
            $u = Get-EstadoUwf
            $errores = @(Aplicar-Perfil (Leer-Perfil) $u.FiltroActual)
            $r = Invoke-Uwf @('filter','enable')
            if (-not $r.Ok) { throw "No se ha podido activar el filtro:`n`n$($r.Salida)" }
            # Como cualquier activacion del filtro, el vigilante lo confirma en el arranque
            Guardar-Estado 'verificando'
            Escribir-Log 'PrepararEquipo' $(if ($errores.Count -eq 0) {'OK'} else {'PARCIAL'}) "$($errores.Count) avisos"
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

    # Encola una exclusion y refresca la ventana. La validacion ocurre al encolar, asi que el
    # tecnico ve el error en el momento en que lo decide y no al aplicar.
    $encolarExclusion = {
        param($Tipo, $Valor, $Accion = 'add')
        try {
            $p = Leer-Pendientes
            [void](Add-PendienteExclusion $p $Tipo $Accion $Valor)
            Guardar-Pendientes $p
            Escribir-Log 'EncolarExclusion' 'OK' "$Accion $Tipo $Valor"
            & $refrescar
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    }

    $btnAddPrograma.Add_Click({
        try {
            $res = Mostrar-DialogoPrograma $form
            if (-not $res.Aceptado) { return }
            $p = Leer-Pendientes
            $nuevos  = 0
            $errores = New-Object System.Collections.ArrayList
            foreach ($par in @(@{ t = 'archivo'; v = $res.Carpetas }, @{ t = 'registro'; v = $res.Claves })) {
                foreach ($v in @($par.v)) {
                    try {
                        if (Add-PendienteExclusion $p $par.t 'add' $v) { $nuevos++ }
                    } catch { [void]$errores.Add("$v -> $($_.Exception.Message)") }
                }
            }
            Guardar-Pendientes $p
            Escribir-Log 'EncolarExclusiones' 'OK' "por programa: $nuevos encoladas"
            & $refrescar
            if ($errores.Count) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Encolado con avisos:`n`n" + ($errores -join "`n"), 'UWF Aulas', 'OK', 'Warning') | Out-Null
            }
            $lblBarra.Text = "$nuevos exclusiones encoladas como pendientes"
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    })

    $btnAddCarpeta.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq 'OK') { & $encolarExclusion 'archivo' $d.SelectedPath 'add' }
    })

    $btnAddArchivo.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        if ($d.ShowDialog() -eq 'OK') { & $encolarExclusion 'archivo' $d.FileName 'add' }
    })

    $btnAddReg.Add_Click({
        $clave = [Microsoft.VisualBasic.Interaction]::InputBox(
            'Clave de registro a excluir (solo HKLM):', 'UWF Aulas', 'HKLM\SOFTWARE\')
        if ($clave) { & $encolarExclusion 'registro' $clave 'add' }
    })

    $btnQuitar.Add_Click({
        # Sobre una fila pendiente la saca de la cola; sobre una exclusion ya activa en UWF
        # encola su retirada. En ningun caso toca el equipo todavia.
        if ($lv.SelectedItems.Count -eq 0) { return }
        $it         = $lv.SelectedItems[0]
        $estadoFila = $it.SubItems[0].Text
        $tipoTxt    = $it.SubItems[1].Text
        $val        = $it.SubItems[2].Text
        if (-not $tipoTxt) { return }   # fila informativa de lista vacia
        if ($estadoFila -eq 'Se quita al reiniciar') {
            $lblBarra.Text = 'Esa exclusion ya se quitara al reiniciar'
            return
        }
        $tipo       = if ($tipoTxt -eq 'Archivo') { 'archivo' } else { 'registro' }
        try {
            $p = Leer-Pendientes
            if ($estadoFila.StartsWith('PENDIENTE')) {
                [void](Remove-PendienteExclusion $p $tipo $val)
                Escribir-Log 'CancelarPendiente' 'OK' "$tipo $val"
                $lblBarra.Text = 'Pendiente cancelado'
            } else {
                [void](Add-PendienteExclusion $p $tipo 'remove' $val)
                Escribir-Log 'EncolarExclusion' 'OK' "remove $tipo $val"
                $lblBarra.Text = 'Retirada encolada como pendiente'
            }
            Guardar-Pendientes $p
            & $refrescar
        } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
    })

    $btnAplicarPend.Add_Click({
        # Unico punto donde la cola llega a UWF
        $p = Leer-Pendientes
        if (Test-PendientesVacios $p) { return }
        $u = Get-EstadoUwf
        if (-not $u.Instalado) {
            [System.Windows.Forms.MessageBox]::Show(
                'UWF no esta instalado en este equipo, asi que los cambios no pueden aplicarse todavia. Instalalo desde la pestana Estado: la cola de pendientes se conserva.',
                'UWF Aulas', 'OK', 'Warning') | Out-Null
            return
        }

        $requiereOff = ($u.FiltroActual -and (Test-DiscoPendienteExigeFiltroOff $p $u))
        $detalle = (@(Get-ResumenPendientes $p) | ForEach-Object { "  - $_" }) -join "`n"
        $aviso = "Se van a aplicar estos cambios:`n`n$detalle`n`n"
        if ($requiereOff) {
            $aviso += "Cambiar el tamano o el sitio exige desactivar la proteccion, asi que el equipo se`nreiniciara DOS veces: la primera para aplicarlo sin proteccion y la segunda para`nvolver a protegerlo. No hay que hacer nada entre medias.`n`nContinuar?"
        } else {
            $aviso += "El equipo se reiniciara una vez para que surtan efecto.`n`nContinuar?"
        }
        if ([System.Windows.Forms.MessageBox]::Show($aviso, 'UWF Aulas', 'YesNo', 'Warning') -ne 'Yes') { return }

        try {
            $form.Cursor = 'WaitCursor'
            $res = Aplicar-Pendientes $u.FiltroActual
            $form.Cursor = 'Default'
            & $refrescar
            if ($res.Errores.Count) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Aplicado con avisos:`n`n" + ($res.Errores -join "`n"), 'UWF Aulas', 'OK', 'Warning') | Out-Null
            }
            if ($requiereOff -and $res.EsperandoFiltroOff) {
                Iniciar-AplicacionPendientes
                & $refrescar
                Reiniciar-Equipo 'aplicar cambios pendientes sin proteccion'
            } elseif ($res.Aplicados.Count) {
                & $preguntarReinicio 'cambios pendientes aplicados'
            }
        } catch {
            $form.Cursor = 'Default'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
    })

    $btnDescartarPend.Add_Click({
        $p = Leer-Pendientes
        if (Test-PendientesVacios $p) { return }
        $n = @(Get-ResumenPendientes $p).Count
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Se descartaran los $n cambios pendientes sin aplicarlos.`n`nEl equipo se queda exactamente como esta. Continuar?",
            'UWF Aulas', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        Guardar-Pendientes (Nueva-ColaPendientes)
        Escribir-Log 'DescartarPendientes' 'OK'
        & $refrescar
        $lblBarra.Text = 'Cambios pendientes descartados'
    })

    $btnImportar.Add_Click({
        # Carga un perfil JSON, lo guarda como el activo y encola todo su contenido como cambios
        # pendientes para que el tecnico lo revise antes de aplicarlo.
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'Perfil JSON|*.json'
        if ($d.ShowDialog() -ne 'OK') { return }
        try {
            $perfil = Get-Content -LiteralPath $d.FileName -Raw | ConvertFrom-Json
            Guardar-Perfil $perfil          # valida los umbrales y rechaza el perfil si no cuadran
            $p = Leer-Pendientes
            $nuevos  = 0
            $errores = New-Object System.Collections.ArrayList
            foreach ($par in @(@{ t = 'archivo'; v = $perfil.archivos }, @{ t = 'registro'; v = $perfil.registro })) {
                foreach ($v in @($par.v)) {
                    if (-not $v) { continue }
                    try {
                        if (Add-PendienteExclusion $p $par.t 'add' $v) { $nuevos++ }
                    } catch { [void]$errores.Add("$v -> $($_.Exception.Message)") }
                }
            }
            if ($perfil.overlay) {
                try {
                    $o = $perfil.overlay
                    Set-PendienteDisco $p $(if ($o.tipo -eq 'RAM') {'RAM'} else {'Disco'}) `
                        ([int]$o.tamanoMB) ([int]$o.avisoMB) ([int]$o.criticoMB)
                    $nuevos++
                } catch { [void]$errores.Add("uso del disco -> $($_.Exception.Message)") }
            }
            Guardar-Pendientes $p
            Escribir-Log 'ImportarPerfil' 'OK' "$($perfil.nombre): $nuevos cambios encolados"
            & $refrescar
            $msg = "Perfil '$($perfil.nombre)' cargado.`n`n$nuevos cambios encolados como pendientes: revisalos y pulsa ""Aplicar cambios y reiniciar""."
            if ($errores.Count) { $msg += "`n`nAvisos:`n" + ($errores -join "`n") }
            [System.Windows.Forms.MessageBox]::Show($msg, 'UWF Aulas', 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
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
                }
                # El uso del disco solo se exporta si se ha podido leer entero: con valores a 0
                # la validacion de umbrales rechazaria el perfil y no se exportaria nada.
                if ((@('RAM','Disco') -contains $u.OverlayTipo) -and
                    (Test-UmbralesValidos $u.OverlayAvisoMB $u.OverlayCriticoMB $u.OverlayMaxMB)) {
                    $perfil | Add-Member -NotePropertyName overlay -NotePropertyValue ([pscustomobject]@{
                        tipo      = $u.OverlayTipo
                        tamanoMB  = $u.OverlayMaxMB
                        avisoMB   = $u.OverlayAvisoMB
                        criticoMB = $u.OverlayCriticoMB
                    })
                }
                Guardar-Perfil $perfil $d.FileName
                [System.Windows.Forms.MessageBox]::Show('Perfil exportado.', 'UWF Aulas', 'OK', 'Information') | Out-Null
            } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null }
        }
    })

    $btnAplicarOv.Add_Click({
        try {
            $tipo = if ($radRam.Checked) { 'RAM' } else { 'Disco' }
            $p = Leer-Pendientes
            Set-PendienteDisco $p $tipo ([int]$numTam.Value) ([int]$numAv.Value) ([int]$numCr.Value)
            Guardar-Pendientes $p
            Escribir-Log 'EncolarUsoDisco' 'OK' `
                ("tipo=$tipo tamano=$([int]$numTam.Value) aviso=$([int]$numAv.Value) critico=$([int]$numCr.Value)")
            & $refrescar
            $lblBarra.Text = 'Uso del disco encolado como pendiente'
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
    if ($estadoActual -and (@('mantenimiento','aplicando') -contains $estadoActual.fase)) { $tabs.SelectedTab = $tabMant }

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
    # No basta con dejarlo en el log: si la copia de ProgramData se ha quedado en una version
    # anterior, el vigilante que corre al arrancar no conoce la fase 'aplicando' y un equipo
    # podria quedarse sin proteccion. El tecnico tiene que saberlo.
    [System.Windows.Forms.MessageBox]::Show(
        ("No se ha podido actualizar la copia instalada en`n$($script:ScriptDest)`n`n" +
         "$($_.Exception.Message)`n`n" +
         'La herramienta se abrira igualmente, pero NO uses "Aplicar cambios y reiniciar" ' +
         'hasta resolverlo: el vigilante que arranca con el equipo seguiria siendo el ' +
         'anterior. Cierra la herramienta, espera unos segundos tras el arranque y vuelve a ' +
         'ejecutarla.'),
        'UWF Aulas', 'OK', 'Warning') | Out-Null
}

Mostrar-Interfaz
