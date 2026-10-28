# UWFManager

Herramienta para gestionar el **Unified Write Filter (UWF)** de Windows. Sustituye el *servicing mode* nativo de UWF (fragil y que no
cubre software de terceros como el antivirus) por una ventana de mantenimiento controlada,
con una GUI pensada para que un tecnico la use en el aula sin margen de error.

El funcionamiento interno (fases, vigilante, cola de cambios, formatos de los ficheros,
garantias de seguridad y diagnostico de problemas) esta explicado en
[docs/FUNCIONAMIENTO.md](docs/FUNCIONAMIENTO.md).

## Que hace

- **Estado**: lee en vivo si UWF esta instalado, si el filtro esta activo, que volumenes
  protege y el consumo del overlay, todo via WMI (`root\standardcimv2\embedded`).
- **Uso del disco** (el *overlay* de UWF): configura donde se guardan los cambios
  temporales de cada sesion (RAM o Disco), su tamano y los umbrales de aviso/critico
  (regla: `aviso < critico <= tamano`, ambos como consumo acumulado, no espacio libre).
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
    disco), la herramienta abre la ventana de mantenimiento sola y el vigilante la cierra
    tras aplicarlo: dos reinicios sin que el tecnico tenga que hacer nada entre medias.
- **Mantenimiento**: flujo guiado de 3 pasos para actualizar el equipo sin servicing mode:
  1. Iniciar mantenimiento -> desactiva el filtro y reinicia.
  2. El equipo arranca sin proteccion: se actualiza lo que haga falta.
  3. Finalizar y proteger -> reactiva el filtro y reinicia.
- **Vigilante**: una tarea programada (ejecutada como `SYSTEM` en cada arranque) vigila que
  la proteccion vuelva a activarse tras un mantenimiento y, si alguien se olvida de
  cerrarlo, reactiva la proteccion sola pasadas unas horas configurables (si el filtro no
  vuelve, lo reintenta como mucho tres reinicios para no entrar en bucle). Tambien es quien
  aplica los cambios pendientes en los arranques sin proteccion, y reactiva el filtro
  aunque la aplicacion falle: el equipo no se queda desprotegido.
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
| `.claude/agents/` | Agentes de Claude Code del proyecto: paridad entre las dos implementaciones, revision de los invariantes de UWF, catalogo de exclusiones y empaquetado. |

Estado que la herramienta guarda en el equipo, en `C:\ProgramData\UWF-Aulas\`:
`config.json` (ruta del log de red y horas maximas de mantenimiento), `estado.json` (fase
en curso), `perfil-exclusiones.json` (perfil del centro), `pendientes.json` (cola de
cambios sin aplicar) y `uwf-aulas.log`.

## Uso

- **Modo normal** (sin argumentos): abre la GUI. Pide privilegios de administrador y, cada vez
  que se ejecuta, se asegura de que el equipo tiene esta version instalada:
  - Se copia a `C:\ProgramData\UWF-Aulas\`.
  - Registra la tarea programada `UWF-Aulas-Vigilante` (arranque, como `SYSTEM`).
  - Crea el acceso directo `UWF Aulas.lnk` en el escritorio publico.
- **Actualizar un equipo** es, por tanto, solo ejecutar la version nueva: compara por hash la
  copia instalada con la que se esta ejecutando y la sustituye si difieren. Como Windows no
  deja sobrescribir un ejecutable en uso, si el vigilante lo tiene abierto termina su tarea y
  reintenta, y en ultimo caso aparta el anterior a un `.old-<fecha>` que borra en el arranque
  siguiente. Si aun asi no pudiera sustituirlo, **avisa al tecnico**: una interfaz nueva con
  un vigilante antiguo no sabria cerrar la fase de aplicacion de cambios pendientes.
- **Modo vigilante** (`-Vigilante` / `--vigilante`): sin interfaz, es el que lanza la tarea
  programada en cada arranque.

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

El `.spec` es la configuracion autoritativa (`--onefile`, `--windowed`, `--uac-admin`,
nombre `UWFManager`). Compilar con el `.spec` en lugar de repetir los argumentos a mano
evita que la linea de compilacion y lo versionado se separen.

El resultado queda en `dist\UWFManager.exe`: un unico ejecutable, sin necesitar Python
instalado en el equipo destino, que pide elevacion automaticamente al abrirse. El `.exe`
no se versiona en el repositorio.
