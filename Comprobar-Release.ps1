# Comprueba un .exe antes de publicarlo: lo escanea con Microsoft Defender y muestra lo que
# hace falta para enviarlo a Microsoft como falso positivo (ver "Publicar una version" en el
# README). No modifica el fichero ni toca la configuracion de Defender.
#
# Salida: 0 = sin deteccion, 1 = Defender lo detecta, 2 = no se ha podido comprobar.
param(
    [string]$Exe = (Join-Path $PSScriptRoot 'dist\UWFManager.exe')
)

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Output "No existe: $Exe"
    exit 2
}

Write-Output "Fichero : $Exe"
Write-Output "SHA-256 : $((Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash)"
Write-Output 'Enviar  : https://www.microsoft.com/en-us/wdsi/filesubmission'

$activo = $false
try { $activo = [bool](Get-MpComputerStatus -ErrorAction Stop).AntivirusEnabled } catch { }
if (-not $activo) {
    Write-Output 'Resultado: SIN COMPROBAR. Defender no esta activo en este equipo.'
    exit 2
}

$mpcmd = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
$salida = & $mpcmd -Scan -ScanType 3 -File (Resolve-Path -LiteralPath $Exe).Path -DisableRemediation
$codigo = $LASTEXITCODE
$salida | Write-Output

switch ($codigo) {
    0       { Write-Output 'Resultado: sin deteccion local. El analisis en la nube puede dar otro resultado.'; exit 0 }
    2       { Write-Output 'Resultado: DETECTADO. No marcar la release como Latest.'; exit 1 }
    default { Write-Output "Resultado: SIN COMPROBAR. MpCmdRun devolvio $codigo."; exit 2 }
}
