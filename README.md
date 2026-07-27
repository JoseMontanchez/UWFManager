# UWFFreezer (UWF Aulas)

Herramienta para gestionar el **Unified Write Filter (UWF)** de Windows. Sustituye el *servicing mode* nativo de UWF (fragil y que no
cubre software de terceros como el antivirus) por una ventana de mantenimiento controlada,
con una GUI pensada para que un tecnico la use en el aula sin margen de error.

## Que hace

- **Estado**: lee en vivo si UWF esta instalado, si el filtro esta activo, que volumenes
  protege y el consumo del overlay, todo via WMI (`root\standardcimv2\embedded`).
- **Overlay**: configura donde se guardan los cambios temporales de cada sesion (RAM o
  Disco), su tamano y los umbrales de aviso/critico (regla: `aviso < critico <= tamano`,
  ambos como consumo acumulado, no espacio libre).
- **Exclusiones**: gestiona que carpetas/archivos y claves de registro (`HKLM`) quedan
  fuera de la proteccion de UWF, con:
  - Bloqueo automatico de rutas que romperian Windows Update
    (`SoftwareDistribution`, `WinSxS`, `servicing`, `$WINDOWS.~BT`, `catroot2`).
  - **Exclusiones por programa**: detecta el software instalado y propone las rutas/claves
    a excluir. Catalogo curado para Kaspersky, pGina, Defender, ESET y Sophos; heuristica
    de busqueda por nombre para cualquier otro programa.
  - Importar/exportar el conjunto de exclusiones como perfil JSON.
- **Mantenimiento**: flujo guiado de 3 pasos para actualizar el equipo sin servicing mode:
  1. Iniciar mantenimiento -> desactiva el filtro y reinicia.
  2. El equipo arranca sin proteccion: se actualiza lo que haga falta.
  3. Finalizar y proteger -> reactiva el filtro y reinicia.
- **Vigilante**: una tarea programada (ejecutada como `SYSTEM` en cada arranque) vigila que
  la proteccion vuelva a activarse tras un mantenimiento y, si alguien se olvida de
  cerrarlo, reactiva la proteccion sola pasadas unas horas configurables.
- **Registro**: cada accion queda en un log CSV local (`C:\ProgramData\UWF-Aulas\uwf-aulas.log`)
  y, si se configura una ruta de red, tambien en un log centralizado por mes.

## Archivos

| Archivo | Que es |
|---|---|
| `UWF-Aulas.ps1` | Version original: script PowerShell + WinForms. |
| `UWF-Aulas.bat` | Lanzador del `.ps1` (pide elevacion si hace falta). |
| `UWF-Aulas.py` | Port a Python + Tkinter, mismo comportamiento. |
| `UWFAulas.bat` | Lanzador del `.py`. |
| `UWF-Aulas.spec` | Configuracion de PyInstaller para compilar `UWF-Aulas.py` a un `.exe` standalone. |
| `UWF-Aulas-contexto.md` | Documento de traspaso con el contexto completo del proyecto, decisiones tomadas y mejoras pendientes. |

## Uso

- **Modo normal** (sin argumentos): abre la GUI. Pide privilegios de administrador y, la
  primera vez que se ejecuta en un equipo, se auto-instala:
  - Se copia a `C:\ProgramData\UWF-Aulas\`.
  - Registra la tarea programada `UWF-Aulas-Vigilante` (arranque, como `SYSTEM`).
  - Crea el acceso directo `UWF Aulas.lnk` en el escritorio publico.
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
pyinstaller --onefile --windowed --uac-admin --name UWF-Aulas UWF-Aulas.py
```

El resultado queda en `dist\UWF-Aulas.exe`: un unico ejecutable, sin necesitar Python
instalado en el equipo destino, que pide elevacion automaticamente al abrirse.
