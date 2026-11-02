# UWFManager

Herramienta para gestionar el **Unified Write Filter (UWF)** de Windows. Sustituye el *servicing mode* nativo de UWF (fragil y que no
cubre software de terceros como el antivirus) por una ventana de mantenimiento controlada,
con una GUI pensada para que un tecnico la use en el aula sin margen de error.

El funcionamiento interno (mantenimiento, cola de cambios, formatos de los ficheros,
garantias de seguridad y diagnostico de problemas) esta explicado en
[docs/FUNCIONAMIENTO.md](docs/FUNCIONAMIENTO.md).

## Que hace

- **Estado**: lee en vivo si UWF esta instalado, si el filtro esta activo, que volumenes
  protege y el consumo del overlay, todo via WMI (`root\standardcimv2\embedded`).
- **Uso del disco** (el *overlay* de UWF): configura donde se guardan los cambios
  temporales de cada sesion (RAM o Disco) y su tamano, que se elige en GB (32 GB por
  defecto). Los umbrales de aviso y critico se calculan solos: aviso al 75 % de llenado y
  critico al 90 %, con al menos 1 GB de margen (regla de UWF: `aviso < critico <= tamano`,
  ambos como consumo acumulado, no espacio libre).
  En la interfaz se llama "uso del disco" para que se entienda sin conocer UWF;
  internamente (WMI, `uwfmgr` y las claves de los perfiles JSON) se conserva el termino
  original.
- **Exclusiones**: gestiona que carpetas/archivos y claves de registro (`HKLM`) quedan
  fuera de la proteccion de UWF. La pestana muestra las exclusiones que el equipo ya tiene
  permitidas, distinguiendo las que valen ahora de las que solo valdran tras reiniciar, con:
  - Bloqueo automatico de rutas que romperian Windows Update
    (`SoftwareDistribution`, `WinSxS`, `servicing`, `$WINDOWS.~BT`, `catroot2`).
  - **Exclusiones por programa**: detecta el software instalado y propone las rutas/claves
    a excluir. Trae un catalogo curado para el tipo de software que suele haber en un aula
    (antivirus de endpoint y su agente de gestion, gestor de login de terceros, el
    antivirus de Windows) y, para cualquier otro programa, una heuristica que busca por
    nombre del programa y del fabricante en `C:\ProgramData` y `HKLM\SOFTWARE`. El
    catalogo esta al principio de cada implementacion, por si hay que ampliarlo. Las
    propuestas de la heuristica aparecen sin marcar y nunca incluyen raices del sistema.
  - Importar/exportar el conjunto de exclusiones como perfil JSON.
- **Cambios pendientes**: todo lo que configura el tecnico (exclusiones y uso del disco)
  se encola y **no llega a UWF hasta pulsar "Aplicar cambios y reiniciar"**. Asi puede
  prepararlo todo de una vez, revisarlo y aplicarlo en un solo reinicio:
  - La cola se guarda en `pendientes.json` y se ve en la interfaz **aunque UWF no este
    disponible todavia en el equipo**, con cada fila marcada como pendiente de anadir o
    de quitar.
  - Se valida al encolar, no al aplicar: las rutas prohibidas y los umbrales invalidos se
    rechazan en el momento en que el tecnico los elige.
  - Encolar lo contrario de lo que ya habia encolado anula ambos cambios, y la cola se
    puede descartar entera sin tocar el equipo.
  - Si algun cambio exige la proteccion desactivada (el tamano o el sitio del uso del
    disco), se queda en la cola y se aplica al finalizar un mantenimiento.
  - La cola sobrevive a los reinicios aunque el filtro este activo: la herramienta lleva sus
    ficheros al disco real con `uwfmgr file commit`.
- **Mantenimiento**: flujo guiado de 3 pasos para actualizar el equipo sin servicing mode:
  1. Iniciar mantenimiento -> desactiva el filtro y reinicia.
  2. El equipo arranca sin proteccion: se actualiza lo que haga falta.
  3. Finalizar y proteger -> aplica los cambios pendientes, reactiva el filtro y reinicia.

  La proteccion **no vuelve sola**: hasta pulsar *Finalizar*, el equipo sigue sin proteger y
  la interfaz lo avisa en rojo. No hay ningun proceso en segundo plano.
- **Actualizacion automatica**: cada vez que se abre la herramienta, mira en segundo plano la
  [ultima release](https://github.com/JoseMontanchez/UWFManager/releases) y, si es mas nueva,
  la descarga, comprueba su SHA-256 y sustituye la copia instalada sin molestar al tecnico. La
  version nueva se usa la proxima vez que se abra. Solo funciona con la ventana abierta: no hay
  tarea programada ni servicio.
- **Registro**: cada accion queda en un log CSV local (`C:\ProgramData\UWF-Aulas\uwf-aulas.log`)
  y, si se configura una ruta de red, tambien en un log centralizado por mes.

## Archivos

| Archivo | Que es |
|---|---|
| `UWF-Aulas.ps1` | Version original: script PowerShell + WinForms. |
| `UWF-Aulas.bat` | Lanzador del `.ps1` (pide elevacion si hace falta). |
| `UWF-Aulas.py` | Port a Python + Tkinter, mismo comportamiento. |
| `UWFAulas.bat` | Lanzador del `.py`. |
| `docs/FUNCIONAMIENTO.md` | Documentacion del funcionamiento interno. |
| `UWF-Aulas.spec` | Configuracion de PyInstaller para compilar `UWF-Aulas.py` a un `.exe` standalone. |
| `version_info.txt` | Datos de version del `.exe` (Propiedades > Detalles). |
| `Comprobar-Release.ps1` | Escanea el `.exe` con Defender antes de publicarlo y muestra su SHA-256. |
| `.claude/agents/` | Agentes de Claude Code del proyecto: paridad entre las dos implementaciones, revision de los invariantes de UWF, catalogo de exclusiones y empaquetado. |

Estado que la herramienta guarda en el equipo, en `C:\ProgramData\UWF-Aulas\`:
`config.json` (ruta del log de red), `perfil-exclusiones.json` (perfil del centro), `pendientes.json` (cola de
cambios sin aplicar) y `uwf-aulas.log`.

## Uso

- **Modo normal** (sin argumentos): abre la GUI. Pide privilegios de administrador y, cada vez
  que se ejecuta, se asegura de que el equipo tiene esta version instalada:
  - Se copia a `C:\ProgramData\UWF-Aulas\`.
  - Borra la tarea programada `UWF-Aulas-Vigilante` que registraban las versiones
    anteriores, si existe.
  - Crea el acceso directo `UWF Aulas.lnk` en el escritorio publico.
- **Actualizar un equipo** es automatico desde la v6 (ver *Que hace* y
  [Publicar una version](#publicar-una-version)). Tambien se puede actualizar a mano, ejecutando
  la version nueva: compara por hash la
  copia instalada con la que se esta ejecutando y la sustituye si difieren. Como Windows no
  deja sobrescribir un ejecutable en uso, si esta abierto aparta el anterior a un
  `.old-<fecha>` que borra en la siguiente ejecucion. Si aun asi no pudiera sustituirlo,
  **avisa al tecnico**.
- `-Vigilante` / `--vigilante` ya no hace nada salvo borrar la tarea antigua: solo existe
  para que la tarea de una version anterior, si reaparece, se elimine sin tocar el filtro.

## Requisitos

- Windows 10/11 **Enterprise o Education** (UWF no esta disponible en Pro/Home).
- Version PowerShell: PowerShell 5.1 (incluido en Windows).
- Version Python: Python 3.x + los paquetes `wmi` y `pywin32` (para leer el estado de UWF
  por WMI, igual que hace `Get-CimInstance` en la version PowerShell).

## Compilar el `.exe` (version Python)

```powershell
pip install wmi pywin32 pyinstaller
pyinstaller --noconfirm --clean UWF-Aulas.spec
```

El `.spec` es la configuracion autoritativa (`--onefile`, `--windowed`, `--uac-admin`, sin UPX,
nombre `UWFManager` e informacion de version tomada de `version_info.txt`). Compilar con el `.spec` en lugar de repetir los argumentos a mano
evita que la linea de compilacion y lo versionado se separen.

El resultado queda en `dist\UWFManager.exe`: un unico ejecutable, sin necesitar Python
instalado en el equipo destino, que pide elevacion automaticamente al abrirse. El `.exe`
no se versiona en el repositorio.

## Publicar una version

Los equipos se actualizan solos a partir de la release marcada como *Latest*, asi que lo que se
publique llega a todas las aulas. Para sacar la version `N`:

1. Sube el numero en `Version` (`UWF-Aulas.py`), `$script:Version` (`UWF-Aulas.ps1`) y
   `version_info.txt`.
2. Compila el `.exe` y ejecuta `.\Comprobar-Release.ps1` en un equipo con Defender activo.
3. Crea en GitHub la release con la etiqueta `vN` (`v7` o `v7.1`), marcada como *pre-release*,
   y adjunta **`UWFManager.exe`** y **`UWF-Aulas.ps1`** con esos nombres exactos. Si falta uno,
   los equipos que usen esa version siguen como estan y lo anotan en el log
   (`BuscarActualizacion;ERROR`).
4. Envia el `.exe` a Microsoft (ver abajo) y pruebalo en un equipo a mano.
5. Cuando este limpio, marca la release como *Latest*: en ese momento empieza a llegar a las
   aulas. Una *pre-release* queda fuera de la actualizacion automatica.

### Falso positivo de Defender (`Program:Win32/Contebrew.A!ml`)

El sufijo `!ml` indica que lo clasifica un modelo de aprendizaje automatico, no una firma de
malware conocido. Microsoft no publica que lo activa, asi que ningun cambio en la compilacion
garantiza evitarlo. El `.spec` ya evita UPX e incluye datos de version.

Lo que hay que hacer con cada version, porque cada compilacion tiene un hash nuevo:

1. Entra en [Submit a file for malware analysis](https://www.microsoft.com/en-us/wdsi/filesubmission)
   con la misma cuenta en cada envio.
2. Envia `UWFManager.exe` como desarrollador de software, indicando que esta mal clasificado
   ("should not be detected"), con el nombre de la deteccion y una descripcion de la herramienta.
3. Sigue el resultado en el historial de envios de esa cuenta y comprueba con
   `Comprobar-Release.ps1` cuando se hayan actualizado las definiciones.

Firmar el `.exe` con un certificado de firma de codigo ayuda a ganar reputacion, y ademas
permitiria comprobar la firma al actualizar, aunque no garantiza que desaparezca la deteccion.

La herramienta **no** anade exclusiones de Defender ni oculta su contenido: dejaria sin
proteccion los equipos del aula y es justo lo que hace el malware. Si el centro necesita
permitirla, debe hacerlo su administrador por politica.
