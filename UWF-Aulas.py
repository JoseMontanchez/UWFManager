# -*- coding: utf-8 -*-
"""
UWF Aulas v2 - gestion del Unified Write Filter para las aulas de la UV
Port a Python del script original UWF-Aulas.ps1 (copia exacta de comportamiento).

  Modo normal    : interfaz grafica para el tecnico  (sin argumentos)
  Modo Vigilante : sin interfaz, lo lanza una tarea programada en cada arranque
                   (--vigilante)

Cambios v2 (heredados del original):
  - Corregidos los umbrales del overlay (aviso < critico) y validacion
  - Pestana Uso del disco: tipo (RAM/Disco), tamano y umbrales configurables
  - Exclusiones por programa: detecta lo instalado y propone carpetas/claves

Cambios v3:
  - Cola de cambios pendientes (pendientes.json): la GUI encola exclusiones y uso del
    disco, y nada llega a UWF hasta pulsar "Aplicar cambios y reiniciar". La lista se
    ve aunque UWF no este disponible en el equipo.
  - Fase 'aplicando': si un pendiente exige el filtro desactivado (tipo o tamano), la
    herramienta abre la ventana de mantenimiento sola y el vigilante la cierra tras
    aplicar la cola, volviendo a proteger el equipo.
  - En la interfaz, 'overlay' se llama "uso del disco". Internamente (WMI, uwfmgr y
    claves de los perfiles JSON) se conserva el termino de UWF.

Notas del port:
  - Para leer el estado de UWF se usa WMI (root\\standardcimv2\\embedded) via el
    modulo 'wmi'. Para actuar se usa uwfmgr.exe. No se parsea la salida de
    uwfmgr salvo como fallback puntual para el consumo del overlay.
  - La GUI del original (Windows Forms) se reproduce con Tkinter conservando
    pestanas, controles, textos y comportamiento.
  - Requiere Windows con la caracteristica UWF disponible. En otros sistemas
    uwfmgr.exe no existe y la mayoria de funciones fallan por diseno.
"""

import os
import re
import sys
import glob
import json
import socket
import shutil
import hashlib
import subprocess
from datetime import datetime

try:
    import winreg
except ImportError:  # pragma: no cover - solo fuera de Windows
    winreg = None


# =============================================================================
#  Rutas y constantes de modulo (equivalen a las variables $script:*)
# =============================================================================

Congelado  = bool(getattr(sys, 'frozen', False))  # True cuando corre como .exe empaquetado (PyInstaller)

Base       = os.path.join(os.environ.get('ProgramData', r'C:\ProgramData'), 'UWF-Aulas')
CfgPath    = os.path.join(Base, 'config.json')
EstadoPath = os.path.join(Base, 'estado.json')
PerfilPath = os.path.join(Base, 'perfil-exclusiones.json')
PendPath   = os.path.join(Base, 'pendientes.json')
LogPath    = os.path.join(Base, 'uwf-aulas.log')
ScriptDest = os.path.join(Base, 'UWF-Aulas.exe' if Congelado else 'UWF-Aulas.py')
Uwfmgr     = os.path.join(os.environ.get('SystemRoot', r'C:\WINDOWS'), 'System32', 'uwfmgr.exe')
Tarea      = 'UWF-Aulas-Vigilante'
MaxReintentosFiltro = 3   # reinicios que el vigilante intenta para reactivar el filtro

# Rutas que nunca deben excluirse: romperian las actualizaciones de Windows
Prohibidas = [
    r'C:\WINDOWS\SOFTWAREDISTRIBUTION',
    r'C:\WINDOWS\WINSXS',
    r'C:\WINDOWS\SERVICING',
    r'C:\$WINDOWS.~BT',
    r'C:\WINDOWS\SYSTEM32\CATROOT2',
]

# -----------------------------------------------------------------------------
#  Catalogo de programas conocidos para exclusiones
#  Patron   : regex contra el nombre del programa instalado
#  Carpetas : patrones glob; se anaden solo las rutas que existan en el equipo
#  Claves   : claves HKLM; se anaden solo las que existan en el equipo
# -----------------------------------------------------------------------------
Catalogo = [
    {
        'Nombre':   'Kaspersky (antivirus y agente de red)',
        'Patron':   'Kaspersky',
        'Carpetas': [r'C:\ProgramData\Kaspersky*', r'C:\ProgramData\KasperskyLab*', r'C:\ProgramData\KL*Agent*'],
        'Claves':   [r'HKLM\SOFTWARE\KasperskyLab', r'HKLM\SOFTWARE\WOW6432Node\KasperskyLab'],
    },
    {
        'Nombre':   'pGina (autenticacion LDAP)',
        'Patron':   'pGina',
        'Carpetas': [r'C:\Program Files\pGina*', r'C:\Program Files (x86)\pGina*', r'C:\ProgramData\pGina*'],
        'Claves':   [r'HKLM\SOFTWARE\pGina3', r'HKLM\SOFTWARE\WOW6432Node\pGina3'],
    },
    {
        'Nombre':   'Microsoft Defender (definiciones)',
        'Patron':   'Microsoft Defender|Windows Defender',
        'Carpetas': [r'C:\ProgramData\Microsoft\Windows Defender\Definition Updates'],
        'Claves':   [],
    },
    {
        'Nombre':   'ESET (antivirus)',
        'Patron':   'ESET',
        'Carpetas': [r'C:\ProgramData\ESET'],
        'Claves':   [r'HKLM\SOFTWARE\ESET', r'HKLM\SOFTWARE\WOW6432Node\ESET'],
    },
    {
        'Nombre':   'Sophos (antivirus)',
        'Patron':   'Sophos',
        'Carpetas': [r'C:\ProgramData\Sophos'],
        'Claves':   [r'HKLM\SOFTWARE\Sophos', r'HKLM\SOFTWARE\WOW6432Node\Sophos'],
    },
]

# Palabras que la heuristica de "Anadir por programa" no usa como termino de busqueda: son
# tan genericas que casarian con medio sistema (p. ej. el fabricante 'Microsoft' proponia
# excluir HKLM\SOFTWARE\Microsoft entero).
TerminosGenericos = {
    'microsoft', 'windows', 'corporation', 'corp', 'update', 'updates', 'software',
    'program', 'programs', 'system', 'systems', 'service', 'services', 'driver', 'drivers',
    'runtime', 'redistributable', 'tools', 'client', 'edition', 'version', 'package',
    'components', 'framework', 'technologies', 'limited', 'company', 'intel', 'x64-based',
}

# Carpetas y claves raiz que nunca se proponen por heuristica, aunque casen por nombre
RaicesSistema = {
    r'C:\PROGRAMDATA\MICROSOFT',
    r'HKLM\SOFTWARE\MICROSOFT', r'HKLM\SOFTWARE\WOW6432NODE\MICROSOFT',
    r'HKLM\SOFTWARE\CLASSES', r'HKLM\SOFTWARE\WOW6432NODE\CLASSES',
    r'HKLM\SOFTWARE\POLICIES', r'HKLM\SOFTWARE\WOW6432NODE\POLICIES',
    r'HKLM\SOFTWARE\WOW6432NODE', r'HKLM\SOFTWARE\CLIENTS',
}


# =============================================================================
#  Utilidades
# =============================================================================

def _sin_ventana():
    """Argumentos para subprocess que evitan abrir una consola y no heredan stdin.

    El .exe se compila sin consola: cada programa de consola que lance (uwfmgr, schtasks,
    powershell, shutdown) haria parpadear una ventana negra, y sus descriptores estandar no
    son validos, asi que un hijo que los herede puede fallar de forma dificil de reproducir.
    """
    flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000) if os.name == 'nt' else 0
    return {'stdin': subprocess.DEVNULL, 'creationflags': flags}

def inicializar_carpeta():
    """Crea C:\\ProgramData\\UWF-Aulas si todavia no existe."""
    if not os.path.isdir(Base):
        os.makedirs(Base, exist_ok=True)


def _now(fmt):
    """Fecha/hora actual formateada segun fmt (atajo sobre datetime.now())."""
    return datetime.now().strftime(fmt)


def escribir_log(accion, resultado='OK', detalle=''):
    """Anade una linea CSV al log local y, si hay ruta de red configurada, tambien al log central."""
    inicializar_carpeta()
    linea = '%s;%s;%s;%s;%s;%s' % (
        _now('%Y-%m-%d %H:%M:%S'),
        os.environ.get('COMPUTERNAME', socket.gethostname()),
        os.environ.get('USERNAME', ''),
        accion, resultado, detalle,
    )
    try:
        with open(LogPath, 'a', encoding='utf-8') as fh:
            fh.write(linea + '\n')
    except Exception:
        pass
    try:
        cfg = leer_config()
        if cfg.get('rutaLogRed'):
            destino = os.path.join(cfg['rutaLogRed'], 'uwf-aulas-' + _now('%Y-%m') + '.csv')
            with open(destino, 'a', encoding='utf-8') as fh:
                fh.write(linea + '\n')
    except Exception:
        pass


def leer_config():
    """Lee config.json (ruta de log en red, horas maximas de mantenimiento) o devuelve los valores por defecto."""
    if os.path.isfile(CfgPath):
        try:
            with open(CfgPath, 'r', encoding='utf-8-sig') as fh:
                return json.load(fh)
        except Exception:
            pass
    return {'rutaLogRed': '', 'horasMaxMantenimiento': 8}


def guardar_config(cfg):
    """Escribe config.json."""
    inicializar_carpeta()
    with open(CfgPath, 'w', encoding='utf-8') as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=True)


def leer_estado():
    """Lee estado.json (fase de mantenimiento en curso) o None si no hay ninguna fase abierta."""
    if os.path.isfile(EstadoPath):
        try:
            with open(EstadoPath, 'r', encoding='utf-8-sig') as fh:
                return json.load(fh)
        except Exception:
            pass
    return None


def guardar_estado(fase, detalle='', intentos=0):
    """Escribe estado.json con la fase actual, o lo borra si fase es None/vacio.
    'intentos' cuenta los reintentos del vigilante para reactivar el filtro."""
    inicializar_carpeta()
    if not fase:
        try:
            os.remove(EstadoPath)
        except OSError:
            pass
        return
    datos = {
        'fase':    fase,
        'inicio':  _now('%Y-%m-%dT%H:%M:%S'),
        'tecnico': os.environ.get('USERNAME', ''),
        'equipo':  os.environ.get('COMPUTERNAME', socket.gethostname()),
        'detalle': detalle,
        'intentos': int(intentos),
    }
    with open(EstadoPath, 'w', encoding='utf-8') as fh:
        json.dump(datos, fh, indent=2, ensure_ascii=True)


def test_administrador():
    """True si el proceso actual tiene privilegios de administrador."""
    if os.name != 'nt':
        return hasattr(os, 'geteuid') and os.geteuid() == 0
    try:
        import ctypes
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        return False


def test_uwf_instalado():
    """True si la caracteristica UWF esta disponible en este equipo (existe uwfmgr.exe)."""
    return os.path.isfile(Uwfmgr)


def invoke_uwf(argumentos):
    """Wrapper de uwfmgr.exe. Devuelve dict {Codigo, Salida, Ok}."""
    if not test_uwf_instalado():
        raise RuntimeError('uwfmgr.exe no esta disponible. Instala primero la caracteristica UWF.')
    try:
        # errors='replace': uwfmgr escribe en la pagina OEM de la consola y algunos de sus
        # bytes no existen en la ANSI; sin esto, un mensaje con tildes hacia fallar la
        # decodificacion y una orden que habia funcionado se daba por fallida.
        proc = subprocess.run(
            [Uwfmgr] + [str(a) for a in argumentos],
            capture_output=True, text=True, shell=False, errors='replace', **_sin_ventana()
        )
        salida = ((proc.stdout or '') + (proc.stderr or '')).strip()
        return {'Codigo': proc.returncode, 'Salida': salida, 'Ok': proc.returncode == 0}
    except Exception as ex:
        return {'Codigo': -1, 'Salida': str(ex), 'Ok': False}


# =============================================================================
#  Estado del filtro
# =============================================================================

def _wmi_embedded():
    """Conexion WMI al namespace root\\standardcimv2\\embedded (clases UWF_*), o None si no esta disponible."""
    if os.name != 'nt':
        return None
    try:
        import wmi
        return wmi.WMI(namespace=r'root\standardcimv2\embedded')
    except Exception:
        return None


def get_estado_uwf():
    """Foto completa del estado de UWF: filtro, volumenes protegidos, overlay y su consumo.

    Lee por WMI (como el original en PowerShell via Get-CimInstance); si el consumo del
    overlay no llega por WMI, hace fallback puntual parseando 'uwfmgr overlay get-consumption'.
    """
    r = {
        'Instalado':        test_uwf_instalado(),
        'FiltroActual':     False,
        'FiltroSiguiente':  False,
        'VolumenesActual':  [],
        'OverlayTipo':      'desconocido',
        'OverlayMaxMB':     0,
        'OverlayAvisoMB':   0,
        'OverlayCriticoMB': 0,
        'OverlayUsoMB':     -1,
        'Error':            '',
    }
    if not r['Instalado']:
        return r

    conn = _wmi_embedded()
    try:
        if conn is None:
            raise RuntimeError('WMI no disponible')

        f = conn.UWF_Filter()
        if f:
            r['FiltroActual']    = bool(f[0].CurrentEnabled)
            r['FiltroSiguiente'] = bool(f[0].NextEnabled)

        vols = [
            v for v in (conn.UWF_Volume() or [])
            if getattr(v, 'CurrentSession', False)
            and getattr(v, 'BindByDriveLetter', False)
            and getattr(v, 'ProtectionEnabled', False)
        ]
        r['VolumenesActual'] = [v.DriveLetter for v in vols]

        oc = None
        for c in (conn.UWF_OverlayConfig() or []):
            if getattr(c, 'CurrentSession', False):
                oc = c
                break
        if oc is not None:
            r['OverlayTipo']  = 'RAM' if int(oc.Type) == 0 else ('Disco' if int(oc.Type) == 1 else 'desconocido')
            r['OverlayMaxMB'] = int(oc.MaximumSize)

        ovs = conn.UWF_Overlay() or []
        if ovs:
            ov = ovs[0]
            r['OverlayAvisoMB']   = int(ov.WarningOverlayThreshold)
            r['OverlayCriticoMB'] = int(ov.CriticalOverlayThreshold)
            if ov.OverlayConsumption is not None and int(ov.OverlayConsumption) >= 0:
                r['OverlayUsoMB'] = int(ov.OverlayConsumption)
    except Exception as ex:
        r['Error'] = str(ex)

    if r['OverlayUsoMB'] < 0:
        try:
            s = invoke_uwf(['overlay', 'get-consumption'])['Salida']
            m = re.search(r'(\d+)', s)
            if m:
                r['OverlayUsoMB'] = int(m.group(1))
        except Exception:
            pass

    return r


# =============================================================================
#  Overlay
# =============================================================================

def test_umbrales_validos(aviso, critico, tamano):
    """Valida la regla de umbrales del overlay: aviso < critico <= tamano (consumo acumulado, no espacio libre)."""
    aviso, critico, tamano = int(aviso), int(critico), int(tamano)
    return aviso > 0 and critico > aviso and tamano >= critico


def aplicar_tipo_tamano(tipo, tamano_mb):
    """Aplica tipo (RAM/Disco) y tamano del overlay. UWF solo lo admite con el filtro DESACTIVADO:
    comprobarlo es responsabilidad de quien llama. Devuelve la lista de errores."""
    errores = []
    t = 'disk' if tipo == 'Disco' else 'ram'
    r1 = invoke_uwf(['overlay', 'set-type', t])
    if not r1['Ok']:
        errores.append('set-type: %s' % r1['Salida'])
    r2 = invoke_uwf(['overlay', 'set-size', '%d' % int(tamano_mb)])
    if not r2['Ok']:
        errores.append('set-size: %s' % r2['Salida'])
    return errores


def aplicar_umbrales(aviso_mb, critico_mb):
    """Aplica los umbrales de aviso y critico del overlay. Se pueden cambiar en cualquier momento,
    con el filtro activo o no. Devuelve la lista de errores."""
    errores = []
    r1 = invoke_uwf(['overlay', 'set-warningthreshold', '%d' % int(aviso_mb)])
    if not r1['Ok']:
        errores.append('set-warningthreshold: %s' % r1['Salida'])
    r2 = invoke_uwf(['overlay', 'set-criticalthreshold', '%d' % int(critico_mb)])
    if not r2['Ok']:
        errores.append('set-criticalthreshold: %s' % r2['Salida'])
    return errores


def aplicar_overlay(tipo, tamano_mb, aviso_mb, critico_mb, filtro_activo):
    """Aplica tipo/tamano/umbrales del overlay via uwfmgr. Tipo y tamano solo si el filtro esta desactivado;
    los umbrales se aplican siempre. Devuelve la lista de avisos/errores en vez de lanzar excepcion parcial."""
    if not test_umbrales_validos(aviso_mb, critico_mb, tamano_mb):
        raise ValueError(
            "Umbrales no validos: debe cumplirse aviso < critico <= tamano "
            "(has puesto %s / %s / %s MB)." % (aviso_mb, critico_mb, tamano_mb)
        )

    errores = []

    # Tipo y tamano solo se pueden cambiar con el filtro desactivado
    if filtro_activo:
        errores.append(
            'El tamano y el sitio del uso del disco solo se pueden cambiar con la proteccion '
            'desactivada. Hazlo durante una ventana de mantenimiento. Los umbrales si se han aplicado.'
        )
    else:
        errores.extend(aplicar_tipo_tamano(tipo, tamano_mb))

    errores.extend(aplicar_umbrales(aviso_mb, critico_mb))

    escribir_log('AplicarOverlay', 'OK' if not errores else 'PARCIAL',
                 'tipo=%s tamano=%s aviso=%s critico=%s' % (tipo, tamano_mb, aviso_mb, critico_mb))
    return errores


# =============================================================================
#  Exclusiones
# =============================================================================

def normalizar_clave_registro(clave):
    """Convierte HKEY_LOCAL_MACHINE\\... o HKLM:\\... al formato canonico HKLM\\..."""
    # Sin distinguir mayusculas, como el -replace del .ps1
    c = clave.strip().rstrip('\\')
    c = re.sub(r'^HKEY_LOCAL_MACHINE', 'HKLM', c, flags=re.IGNORECASE)
    c = re.sub(r'^HKLM:?(?=\\|$)', 'HKLM', c, flags=re.IGNORECASE)
    return c


def test_exclusion_peligrosa(ruta):
    """True si excluir esta ruta romperia Windows Update (esta dentro de la lista Prohibidas)."""
    r = ruta.upper().rstrip('\\')
    for p in Prohibidas:
        if r == p or r.startswith(p + '\\'):
            return True
    return False


def get_exclusiones_archivo():
    """Lista las rutas de archivo actualmente excluidas de UWF en C: (via uwfmgr file get-exclusions)."""
    lista = []
    try:
        s = invoke_uwf(['file', 'get-exclusions', 'C:'])['Salida']
        for linea in re.split(r'\r?\n', s):
            t = linea.strip()
            if t.startswith('\\'):
                lista.append('C:' + t)
    except Exception:
        pass
    return lista


def get_exclusiones_registro():
    """Lista las claves HKLM actualmente excluidas de UWF (via uwfmgr registry get-exclusions)."""
    lista = []
    try:
        s = invoke_uwf(['registry', 'get-exclusions'])['Salida']
        for linea in re.split(r'\r?\n', s):
            t = linea.strip()
            if re.match(r'^(HKLM|HKEY_LOCAL_MACHINE)\\', t):
                lista.append(normalizar_clave_registro(t))
    except Exception:
        pass
    return lista


def get_exclusiones_detalle():
    """Exclusiones ya permitidas en el equipo, separando la sesion actual de la siguiente.

    Devuelve una lista de dicts {Tipo ('archivo'|'registro'), Valor, Ahora, TrasReinicio}:
    'Ahora' = surte efecto en esta sesion; 'TrasReinicio' = seguira (o empezara) a surtir
    efecto despues de reiniciar. Una exclusion anadida con el filtro activo solo aparece en
    la siguiente sesion, y una quitada sigue en la actual hasta reiniciar: mostrarlo evita
    que el tecnico crea que algo ya funciona cuando aun no.

    Se lee por WMI (UWF_Volume y UWF_RegistryFilter, una instancia por sesion), que no
    depende del idioma. Si WMI falla, se recurre a uwfmgr sin distinguir sesiones.
    """
    def clave_reg(k):
        c = normalizar_clave_registro(k)
        return c if re.match(r'^HKLM\\', c, re.IGNORECASE) else 'HKLM\\' + c.lstrip('\\')

    vistas = {}   # (tipo, valor en minusculas) -> dict

    def anotar(tipo, valor, actual):
        d = vistas.setdefault((tipo, valor.lower()),
                              {'Tipo': tipo, 'Valor': valor, 'Ahora': False, 'TrasReinicio': False})
        d['Ahora' if actual else 'TrasReinicio'] = True

    conn = _wmi_embedded()
    try:
        if conn is None:
            raise RuntimeError('WMI no disponible')
        for v in (conn.UWF_Volume() or []):
            if str(getattr(v, 'DriveLetter', '') or '').upper() != 'C:':
                continue
            actual = bool(getattr(v, 'CurrentSession', False))
            for f in (v.GetExclusions()[0] or []):
                ruta = str(getattr(f, 'FileName', '') or '').strip()
                if ruta:
                    anotar('archivo', 'C:' + ruta if ruta.startswith('\\') else ruta, actual)
        for rf in (conn.UWF_RegistryFilter() or []):
            actual = bool(getattr(rf, 'CurrentSession', False))
            for k in (rf.GetExclusions()[0] or []):
                clave = str(getattr(k, 'RegistryKey', '') or '').strip()
                if clave:
                    anotar('registro', clave_reg(clave), actual)
        return list(vistas.values())
    except Exception:
        vistas.clear()

    for a in get_exclusiones_archivo():
        anotar('archivo', a, True); anotar('archivo', a, False)
    for k in get_exclusiones_registro():
        anotar('registro', k, True); anotar('registro', k, False)
    return list(vistas.values())


def add_exclusion_archivo(ruta):
    """Anade una exclusion de archivo/carpeta, rechazando rutas prohibidas."""
    if test_exclusion_peligrosa(ruta):
        raise ValueError('Ruta prohibida: excluirla rompe Windows Update (%s)' % ruta)
    r = invoke_uwf(['file', 'add-exclusion', ruta])
    escribir_log('AddExclusionArchivo', 'OK' if r['Ok'] else 'ERROR', ruta)
    if not r['Ok']:
        raise RuntimeError(r['Salida'])


def remove_exclusion_archivo(ruta):
    """Quita una exclusion de archivo/carpeta."""
    r = invoke_uwf(['file', 'remove-exclusion', ruta])
    escribir_log('QuitarExclusionArchivo', 'OK' if r['Ok'] else 'ERROR', ruta)
    if not r['Ok']:
        raise RuntimeError(r['Salida'])


def add_exclusion_registro(clave):
    """Anade una exclusion de registro. UWF solo admite exclusiones bajo HKLM."""
    c = normalizar_clave_registro(clave)
    if not re.match(r'^HKLM\\', c):
        raise ValueError('UWF solo admite exclusiones de registro bajo HKLM.')
    r = invoke_uwf(['registry', 'add-exclusion', c])
    escribir_log('AddExclusionRegistro', 'OK' if r['Ok'] else 'ERROR', c)
    if not r['Ok']:
        raise RuntimeError(r['Salida'])


def remove_exclusion_registro(clave):
    """Quita una exclusion de registro."""
    c = normalizar_clave_registro(clave)
    r = invoke_uwf(['registry', 'remove-exclusion', c])
    escribir_log('QuitarExclusionRegistro', 'OK' if r['Ok'] else 'ERROR', c)
    if not r['Ok']:
        raise RuntimeError(r['Salida'])


# =============================================================================
#  Cambios pendientes
#
#  El tecnico encola en pendientes.json todo lo que quiere cambiar (exclusiones y uso
#  del disco) y lo aplica de una vez con "Aplicar cambios y reiniciar". Dos razones:
#  la GUI puede mostrar lo decidido aunque UWF no este disponible todavia en el equipo,
#  y nada queda a medias: lo que no se puede aplicar ahora se conserva en la cola para
#  aplicarse en el arranque siguiente.
# =============================================================================

def pendientes_vacios(p):
    """True si no hay ningun cambio encolado."""
    return not p.get('exclusiones') and not p.get('disco')


def leer_pendientes():
    """Lee pendientes.json descartando entradas corruptas, o devuelve una cola vacia."""
    p = {'exclusiones': [], 'disco': None}
    if os.path.isfile(PendPath):
        try:
            with open(PendPath, 'r', encoding='utf-8-sig') as fh:
                guardado = json.load(fh)
            ex = guardado.get('exclusiones')
            if isinstance(ex, list):
                p['exclusiones'] = [
                    e for e in ex
                    if isinstance(e, dict)
                    and e.get('tipo') in ('archivo', 'registro')
                    and e.get('accion') in ('add', 'remove')
                    and e.get('valor')
                ]
            d = guardado.get('disco')
            if isinstance(d, dict) and d.get('tipo') in ('RAM', 'Disco') \
                    and test_umbrales_validos(d.get('avisoMB', 0), d.get('criticoMB', 0), d.get('tamanoMB', 0)):
                p['disco'] = d
        except Exception:
            pass
    return p


def guardar_pendientes(p):
    """Escribe pendientes.json, o lo borra si ya no queda nada encolado."""
    inicializar_carpeta()
    if pendientes_vacios(p):
        try:
            os.remove(PendPath)
        except OSError:
            pass
        return
    datos = {
        'version':     1,
        'actualizado': _now('%Y-%m-%dT%H:%M:%S'),
        'tecnico':     os.environ.get('USERNAME', ''),
        'equipo':      os.environ.get('COMPUTERNAME', socket.gethostname()),
        'exclusiones': p.get('exclusiones') or [],
        'disco':       p.get('disco'),
    }
    with open(PendPath, 'w', encoding='utf-8') as fh:
        json.dump(datos, fh, indent=2, ensure_ascii=True)


def _valor_pendiente(tipo, valor):
    """Forma canonica con la que se guarda un valor encolado (conserva mayusculas y minusculas,
    porque es la que se le pasa tal cual a uwfmgr)."""
    if tipo == 'registro':
        return normalizar_clave_registro(valor)
    return valor.strip().rstrip('\\')


def _clave_pendiente(tipo, valor):
    """Clave con la que se comparan dos valores encolados. Va en minusculas porque las rutas y
    las claves de registro de Windows no distinguen mayusculas, igual que el '-eq' del .ps1."""
    return _valor_pendiente(tipo, valor).lower()


def anadir_pendiente_exclusion(p, tipo, accion, valor):
    """Encola anadir o quitar una exclusion.

    Valida al encolar, no al aplicar, para que el tecnico vea el error en el momento en que
    lo decide. Si ya habia encolado el pendiente opuesto sobre el mismo valor, se anulan
    entre si: vuelve al estado que tiene el equipo ahora. Devuelve True si la cola cambio.
    """
    v = _valor_pendiente(tipo, valor)
    if not v:
        raise ValueError('Ruta o clave vacia.')
    if accion == 'add':
        if tipo == 'archivo' and test_exclusion_peligrosa(v):
            raise ValueError('Ruta prohibida: excluirla rompe Windows Update (%s)' % v)
        if tipo == 'registro' and not re.match(r'^HKLM\\', v):
            raise ValueError('UWF solo admite exclusiones de registro bajo HKLM.')

    clave = _clave_pendiente(tipo, v)
    for e in list(p['exclusiones']):
        if e['tipo'] == tipo and _clave_pendiente(tipo, e['valor']) == clave:
            if e['accion'] == accion:
                return False
            p['exclusiones'].remove(e)
            return True

    p['exclusiones'].append({'tipo': tipo, 'accion': accion, 'valor': v})
    return True


def quitar_pendiente_exclusion(p, tipo, valor):
    """Saca de la cola un pendiente concreto. Devuelve True si habia algo que sacar."""
    clave = _clave_pendiente(tipo, valor)
    antes = len(p['exclusiones'])
    p['exclusiones'] = [
        e for e in p['exclusiones']
        if not (e['tipo'] == tipo and _clave_pendiente(tipo, e['valor']) == clave)
    ]
    return len(p['exclusiones']) != antes


def fijar_pendiente_disco(p, tipo, tamano_mb, aviso_mb, critico_mb):
    """Encola la configuracion del uso del disco, validando la regla de umbrales al encolar."""
    if tipo not in ('RAM', 'Disco'):
        raise ValueError('Tipo no valido: %s' % tipo)
    if not test_umbrales_validos(aviso_mb, critico_mb, tamano_mb):
        raise ValueError(
            'Umbrales no validos: debe cumplirse aviso < critico <= tamano '
            '(has puesto %s / %s / %s MB).' % (aviso_mb, critico_mb, tamano_mb)
        )
    p['disco'] = {
        'tipo':      tipo,
        'tamanoMB':  int(tamano_mb),
        'avisoMB':   int(aviso_mb),
        'criticoMB': int(critico_mb),
    }


def disco_pendiente_exige_filtro_off(p, uwf):
    """True si el pendiente de disco cambia el tipo o el tamano, que UWF solo admite con el
    filtro desactivado. Si solo cambian los umbrales no hace falta ventana de mantenimiento."""
    d = p.get('disco')
    if not d:
        return False
    if not uwf.get('Instalado'):
        return True
    return (d['tipo'] != uwf.get('OverlayTipo')
            or int(d['tamanoMB']) != int(uwf.get('OverlayMaxMB') or 0))


def resumen_pendientes(p):
    """Lineas legibles con lo que hay encolado, para la GUI y los mensajes de confirmacion."""
    lineas = []
    for e in p.get('exclusiones') or []:
        verbo = 'Anadir' if e['accion'] == 'add' else 'Quitar'
        que = 'carpeta/archivo' if e['tipo'] == 'archivo' else 'clave de registro'
        lineas.append('%s %s: %s' % (verbo, que, e['valor']))
    d = p.get('disco')
    if d:
        lineas.append('Uso del disco: %s, %s MB (aviso %s, critico %s)'
                      % (d['tipo'], d['tamanoMB'], d['avisoMB'], d['criticoMB']))
    return lineas


def aplicar_pendientes(filtro_activo):
    """Aplica todo lo encolado que se pueda aplicar ahora y conserva el resto en la cola.

    Exclusiones y umbrales se pueden registrar con el filtro activo o no (surten efecto tras
    reiniciar). El tipo y el tamano exigen el filtro desactivado: con la proteccion activa se
    quedan encolados para aplicarse en el arranque de mantenimiento.

    Devuelve {Aplicados, Errores, Restantes, EsperandoFiltroOff}.
    """
    p = leer_pendientes()
    res = {'Aplicados': [], 'Errores': [], 'Restantes': 0, 'EsperandoFiltroOff': False}
    if pendientes_vacios(p):
        return res

    quedan = []
    for e in p['exclusiones']:
        etiqueta = '%s %s' % ('anadir' if e['accion'] == 'add' else 'quitar', e['valor'])
        try:
            if e['tipo'] == 'archivo':
                if e['accion'] == 'add':
                    add_exclusion_archivo(e['valor'])
                else:
                    remove_exclusion_archivo(e['valor'])
            else:
                if e['accion'] == 'add':
                    add_exclusion_registro(e['valor'])
                else:
                    remove_exclusion_registro(e['valor'])
            res['Aplicados'].append(etiqueta)
        except Exception as ex:
            res['Errores'].append('%s -> %s' % (etiqueta, ex))
            quedan.append(e)

    disco = p.get('disco')
    disco_queda = None
    if disco:
        try:
            errores = aplicar_umbrales(disco['avisoMB'], disco['criticoMB'])
            if errores:
                res['Errores'].extend(errores)
            else:
                res['Aplicados'].append('umbrales %s / %s MB' % (disco['avisoMB'], disco['criticoMB']))

            if filtro_activo:
                # Tipo y tamano no se pueden tocar con la proteccion activa. Solo se quedan
                # encolados si de verdad cambian algo: si ya coinciden, no hay nada que hacer.
                if disco_pendiente_exige_filtro_off(p, get_estado_uwf()):
                    disco_queda = disco
                    res['EsperandoFiltroOff'] = True
                else:
                    res['Aplicados'].append('uso del disco: ya estaba en %s, %s MB'
                                            % (disco['tipo'], disco['tamanoMB']))
            else:
                errores = aplicar_tipo_tamano(disco['tipo'], disco['tamanoMB'])
                if errores:
                    res['Errores'].extend(errores)
                    disco_queda = disco
                else:
                    res['Aplicados'].append('uso del disco %s, %s MB'
                                            % (disco['tipo'], disco['tamanoMB']))
        except Exception as ex:
            res['Errores'].append('uso del disco -> %s' % ex)
            disco_queda = disco

    guardar_pendientes({'exclusiones': quedan, 'disco': disco_queda})
    res['Restantes'] = len(quedan) + (1 if disco_queda else 0)
    escribir_log('AplicarPendientes',
                 'OK' if (not res['Errores'] and not res['Restantes']) else 'PARCIAL',
                 'aplicados=%d restantes=%d errores=%d'
                 % (len(res['Aplicados']), res['Restantes'], len(res['Errores'])))
    return res


# =============================================================================
#  Deteccion de programas instalados y propuestas de exclusion
# =============================================================================

def _abrir_hklm(subruta):
    """Abre una subclave de HKEY_LOCAL_MACHINE en modo lectura, o None si no existe/falla."""
    if winreg is None:
        return None
    try:
        return winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, subruta, 0, winreg.KEY_READ)
    except OSError:
        return None


def _valor(clave, nombre):
    """Lee un valor de una clave de registro ya abierta, o None si no existe."""
    try:
        valor, _ = winreg.QueryValueEx(clave, nombre)
        return valor
    except OSError:
        return None


def existe_clave_hklm(clave):
    """True si la clave HKLM indicada existe. Equivalente a Test-Path 'HKLM:\\...'."""
    if winreg is None:
        return False
    sub = re.sub(r'^HKLM\\', '', clave)
    k = _abrir_hklm(sub)
    if k is not None:
        winreg.CloseKey(k)
        return True
    return False


def get_programas_instalados():
    """Enumera los programas instalados (64 y 32 bits) leyendo HKLM\\...\\Uninstall, sin componentes de sistema."""
    rutas = [
        r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    ]
    lista = {}
    for ruta in rutas:
        base = _abrir_hklm(ruta)
        if base is None:
            continue
        try:
            i = 0
            while True:
                try:
                    sub = winreg.EnumKey(base, i)
                except OSError:
                    break
                i += 1
                k = None
                try:
                    k = winreg.OpenKey(base, sub, 0, winreg.KEY_READ)
                    display = _valor(k, 'DisplayName')
                    if not display:
                        continue
                    if _valor(k, 'SystemComponent') == 1:
                        continue
                    nombre = str(display).strip()
                    if nombre not in lista:
                        lista[nombre] = {'Nombre': nombre, 'Fabricante': str(_valor(k, 'Publisher') or '')}
                except OSError:
                    continue
                finally:
                    if k is not None:
                        winreg.CloseKey(k)
        finally:
            winreg.CloseKey(base)
    return sorted(lista.values(), key=lambda p: p['Nombre'].lower())


def resolver_glob(patron):
    """Expande un patron tipo 'C:\\ProgramData\\Kaspersky*' a las carpetas que realmente existen en el equipo."""
    res = []
    try:
        if any(c in patron for c in '*?[]'):
            res = [p for p in glob.glob(patron) if os.path.isdir(p)]
        elif os.path.isdir(patron):
            res = [patron]
        if not res and os.path.exists(patron):
            res = [patron]
    except Exception:
        pass
    return res


def get_propuestas_exclusion(nombre_programa, fabricante):
    """Propone carpetas/claves a excluir para un programa: catalogo curado si esta cubierto,
    si no una heuristica que busca por nombre en ProgramData y HKLM\\SOFTWARE(\\WOW6432Node)."""
    carpetas = []
    claves = []
    origen = 'heuristica'

    # 1) Catalogo de programas conocidos
    for entrada in Catalogo:
        if re.search(entrada['Patron'], nombre_programa, re.IGNORECASE):
            origen = 'catalogo'
            for gl in entrada['Carpetas']:
                for ruta in resolver_glob(gl):
                    if ruta not in carpetas:
                        carpetas.append(ruta)
            for clave in entrada['Claves']:
                if existe_clave_hklm(clave) and clave not in claves:
                    claves.append(clave)
            break

    # 2) Heuristica para programas fuera del catalogo
    if origen == 'heuristica':
        terminos = []
        limpio = re.sub(r'[\d\.\(\)]+', ' ', nombre_programa).strip()
        for p in re.split(r'\s+', limpio):
            if len(p) >= 4 and p.lower() not in TerminosGenericos:
                terminos.append(p)
        if fabricante:
            f = re.split(r'[,\s]+', fabricante)[0]
            if len(f) >= 4 and f.lower() not in TerminosGenericos and f not in terminos:
                terminos.append(f)

        for termino in terminos:
            tl = termino.lower()
            try:
                base_pd = r'C:\ProgramData'
                if os.path.isdir(base_pd):
                    for nombre in os.listdir(base_pd):
                        full = os.path.join(base_pd, nombre)
                        if os.path.isdir(full) and tl in nombre.lower() and full not in carpetas:
                            carpetas.append(full)
            except Exception:
                pass
            for raiz in (r'SOFTWARE', r'SOFTWARE\WOW6432Node'):
                base = _abrir_hklm(raiz)
                if base is None:
                    continue
                try:
                    j = 0
                    while True:
                        try:
                            hijo = winreg.EnumKey(base, j)
                        except OSError:
                            break
                        j += 1
                        if tl in hijo.lower():
                            clave = 'HKLM\\%s\\%s' % (raiz, hijo)
                            if clave not in claves:
                                claves.append(clave)
                finally:
                    winreg.CloseKey(base)

        carpetas = [c for c in carpetas if c.upper().rstrip('\\') not in RaicesSistema]
        claves = [k for k in claves if k.upper().rstrip('\\') not in RaicesSistema]

    return {'Origen': origen, 'Carpetas': carpetas, 'Claves': claves}


# =============================================================================
#  Perfiles
# =============================================================================

def get_perfil_predeterminado():
    """Perfil de exclusiones que se usa si no hay ninguno guardado: base Kaspersky, overlay 4 GB en disco."""
    return {
        'nombre':   'Aulas UV - base Kaspersky',
        'version':  _now('%Y-%m-%d'),
        'archivos': [r'C:\ProgramData\KasperskyLab', r'C:\ProgramData\Kaspersky Lab'],
        'registro': [r'HKLM\SOFTWARE\WOW6432Node\KasperskyLab', r'HKLM\SOFTWARE\KasperskyLab'],
        'overlay':  {'tipo': 'Disco', 'tamanoMB': 4096, 'avisoMB': 2560, 'criticoMB': 3584},
    }


def leer_perfil():
    """Lee perfil-exclusiones.json, o el perfil por defecto si no existe/esta corrupto."""
    if os.path.isfile(PerfilPath):
        try:
            with open(PerfilPath, 'r', encoding='utf-8-sig') as fh:
                return json.load(fh)
        except Exception:
            pass
    return get_perfil_predeterminado()


def guardar_perfil(perfil, ruta=None):
    """Guarda un perfil de exclusiones, validando antes los umbrales de overlay si el perfil trae uno."""
    if not ruta:
        ruta = PerfilPath
    o = perfil.get('overlay')
    if o:
        if not test_umbrales_validos(int(o['avisoMB']), int(o['criticoMB']), int(o['tamanoMB'])):
            raise ValueError(
                'El perfil tiene umbrales de overlay no validos (aviso=%s, critico=%s, tamano=%s). '
                'Debe cumplirse aviso < critico <= tamano.' % (o['avisoMB'], o['criticoMB'], o['tamanoMB'])
            )
    inicializar_carpeta()
    with open(ruta, 'w', encoding='utf-8') as fh:
        json.dump(perfil, fh, indent=2, ensure_ascii=True)


def aplicar_perfil(perfil, filtro_activo=False):
    """Aplica al equipo las exclusiones de archivo/registro y el overlay de un perfil, acumulando avisos."""
    errores = []
    for a in (perfil.get('archivos') or []):
        try:
            add_exclusion_archivo(a)
        except Exception as ex:
            errores.append('%s -> %s' % (a, ex))
    for k in (perfil.get('registro') or []):
        try:
            add_exclusion_registro(k)
        except Exception as ex:
            errores.append('%s -> %s' % (k, ex))
    if perfil.get('overlay'):
        try:
            o = perfil['overlay']
            extra = aplicar_overlay(o['tipo'], int(o['tamanoMB']), int(o['avisoMB']),
                                    int(o['criticoMB']), filtro_activo)
            errores.extend(extra)
        except Exception as ex:
            errores.append('overlay -> %s' % ex)
    escribir_log('AplicarPerfil', 'OK' if not errores else 'PARCIAL', perfil.get('nombre', ''))
    return errores


# =============================================================================
#  Tarea vigilante y autoinstalacion
# =============================================================================

def _pythonw():
    """Interprete a usar para relanzar el script en modo dev (no aplica si esta congelado)."""
    exe = sys.executable or 'python.exe'
    cand = os.path.join(os.path.dirname(exe), 'pythonw.exe')
    return cand if os.path.exists(cand) else exe


def _script_origen():
    """Ruta del fichero a copiar a ProgramData: el propio .exe si esta congelado, si no el .py."""
    if Congelado:
        return os.path.abspath(sys.executable)
    try:
        return os.path.abspath(__file__)
    except NameError:
        return os.path.abspath(sys.argv[0])


def _accion_lanzamiento():
    """Devuelve (ejecutable, argumento) para relanzar la copia instalada en modo vigilante.

    Congelado: el propio .exe copiado, sin necesitar Python instalado en el equipo.
    Dev (.py): pythonw.exe apuntando al .py copiado.
    """
    if Congelado:
        return ScriptDest, '--vigilante'
    return _pythonw(), '"%s" --vigilante' % ScriptDest


def _huella(ruta):
    """Hash SHA-256 de un fichero. Sirve para saber si la copia instalada es exactamente la
    misma que se esta ejecutando, sin depender de un numero de version que hay que recordar
    subir a mano en cada compilacion."""
    h = hashlib.sha256()
    with open(ruta, 'rb') as fh:
        for trozo in iter(lambda: fh.read(65536), b''):
            h.update(trozo)
    return h.hexdigest()


def detectar_instalacion(origen=None):
    """Mira que hay instalado ya en ProgramData.

    Devuelve {Existe, Bytes, Huella, EsLaMisma}. 'EsLaMisma' compara con lo que se esta
    ejecutando: si coincide, no hay nada que sustituir.
    """
    r = {'Existe': False, 'Bytes': 0, 'Huella': '', 'EsLaMisma': False}
    if not os.path.isfile(ScriptDest):
        return r
    r['Existe'] = True
    try:
        r['Bytes'] = os.path.getsize(ScriptDest)
        r['Huella'] = _huella(ScriptDest)
        if origen and os.path.isfile(origen):
            r['EsLaMisma'] = (r['Huella'] == _huella(origen))
    except Exception:
        pass
    return r


def _detener_tarea():
    """Termina la instancia en curso de la tarea del vigilante, si la hay.

    Hace falta porque el vigilante arranca con el equipo: si todavia esta corriendo, su .exe
    esta en uso y Windows no deja sobrescribirlo.
    """
    try:
        subprocess.run(['schtasks', '/end', '/tn', Tarea],
                       capture_output=True, text=True, shell=False, **_sin_ventana())
    except Exception:
        pass


def _limpiar_restos():
    """Borra los apartados .old-* de sustituciones anteriores y el .py suelto que pudiera
    haber dejado una instalacion de desarrollo cuando ahora se ejecuta el .exe."""
    borrados = []
    try:
        for nombre in os.listdir(Base):
            ruta = os.path.join(Base, nombre)
            if '.old-' in nombre and os.path.isfile(ruta):
                try:
                    os.remove(ruta)
                    borrados.append(nombre)
                except OSError:
                    pass          # sigue en uso: se intentara en el proximo arranque
        if Congelado:
            viejo_py = os.path.join(Base, 'UWF-Aulas.py')
            if os.path.isfile(viejo_py):
                try:
                    os.remove(viejo_py)
                    borrados.append('UWF-Aulas.py')
                except OSError:
                    pass
    except Exception:
        pass
    return borrados


def reemplazar_instalado(origen):
    """Sustituye la copia de ProgramData por la version que se esta ejecutando ahora.

    Tres intentos, de menos a mas invasivo, porque Windows no permite sobrescribir un
    ejecutable en uso:
      1. Copiar encima.
      2. Terminar la tarea del vigilante (que es quien suele tenerlo abierto) y repetir.
      3. Apartar el instalado a un '.old-<fecha>' y copiar la nueva al lado. Renombrar un
         .exe en uso si esta permitido; el .old se borra en la siguiente ejecucion.

    Devuelve (accion, detalle). Lanza excepcion solo si los tres intentos fallan, para que
    quien llama pueda avisar al tecnico: una copia instalada vieja con una GUI nueva es
    peligrosa, porque el vigilante antiguo no conoce la fase 'aplicando'.
    """
    previo = detectar_instalacion(origen)

    if not previo['Existe']:
        shutil.copy2(origen, ScriptDest)
        return 'instalado', 'primera instalacion en este equipo'

    if previo['EsLaMisma']:
        return 'sin cambios', 'la copia instalada ya es esta misma version'

    detalle = '%d -> %d bytes' % (previo['Bytes'], os.path.getsize(origen))

    try:
        shutil.copy2(origen, ScriptDest)
        return 'sustituido', detalle
    except (OSError, PermissionError):
        pass

    _detener_tarea()
    try:
        shutil.copy2(origen, ScriptDest)
        return 'sustituido', '%s (tras detener la tarea)' % detalle
    except (OSError, PermissionError):
        pass

    apartado = '%s.old-%s' % (ScriptDest, _now('%Y%m%d%H%M%S'))
    os.replace(ScriptDest, apartado)      # si esto falla, propaga: no hay mas que intentar
    shutil.copy2(origen, ScriptDest)
    return 'sustituido', '%s (la anterior estaba en uso, apartada como %s)' % (
        detalle, os.path.basename(apartado))


def instalar_vigilante():
    """Sustituye la copia instalada por esta version y registra la tarea programada que lanza
    el modo vigilante en cada arranque. Se ejecuta en cada arranque de la GUI, no solo la
    primera vez, para que actualizar el equipo sea solo abrir el .exe nuevo."""
    inicializar_carpeta()
    origen = _script_origen()
    if origen and os.path.normcase(origen) != os.path.normcase(ScriptDest):
        accion, detalle = reemplazar_instalado(origen)
        if accion != 'sin cambios':
            escribir_log('ActualizarInstalacion', 'OK', '%s: %s' % (accion, detalle))
        restos = _limpiar_restos()
        if restos:
            escribir_log('LimpiarRestos', 'OK', ', '.join(restos))

    ejecutable, argumento = _accion_lanzamiento()
    ps = (
        "$a = New-ScheduledTaskAction -Execute '%s' -Argument '%s';"
        "$t = New-ScheduledTaskTrigger -AtStartup;"
        "$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest;"
        "$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable;"
        "Register-ScheduledTask -TaskName '%s' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null"
    ) % (ejecutable, argumento, Tarea)
    subprocess.run(['powershell', '-NoProfile', '-Command', ps],
                   capture_output=True, text=True, shell=False, check=True, **_sin_ventana())
    escribir_log('InstalarVigilante', 'OK', ScriptDest)


def crear_acceso_directo():
    """Crea el acceso directo 'UWF Aulas.lnk' en el escritorio publico, apuntando a la copia instalada."""
    try:
        destino = os.path.join(os.environ.get('PUBLIC', r'C:\Users\Public'), 'Desktop', 'UWF Aulas.lnk')
        if Congelado:
            objetivo, argumentos, icono = ScriptDest, '', '%s,0' % ScriptDest
        else:
            objetivo, argumentos = _pythonw(), '"%s"' % ScriptDest
            icono = '%s\\System32\\shell32.dll,48' % os.environ.get('SystemRoot', r'C:\WINDOWS')
        ps = (
            "$ws = New-Object -ComObject WScript.Shell;"
            "$lnk = $ws.CreateShortcut('%s');"
            "$lnk.TargetPath = '%s';"
            "$lnk.Arguments = '%s';"
            "$lnk.WorkingDirectory = '%s';"
            "$lnk.IconLocation = '%s';"
            "$lnk.Description = 'Gestion del Unified Write Filter';"
            "$lnk.Save()"
        ) % (destino, objetivo, argumentos, Base, icono)
        subprocess.run(['powershell', '-NoProfile', '-Command', ps],
                       capture_output=True, text=True, shell=False, **_sin_ventana())
    except Exception:
        pass


# =============================================================================
#  Flujo de mantenimiento
# =============================================================================

def iniciar_mantenimiento():
    """Paso 1 del flujo de mantenimiento: desactiva el filtro y marca la fase 'mantenimiento'."""
    r = invoke_uwf(['filter', 'disable'])
    if not r['Ok']:
        raise RuntimeError('No se ha podido desactivar el filtro: %s' % r['Salida'])
    guardar_estado('mantenimiento')
    escribir_log('IniciarMantenimiento', 'OK', 'filtro desactivado, pendiente de reinicio')


def iniciar_aplicacion_pendientes():
    """Abre una ventana de mantenimiento automatica, solo para aplicar los pendientes que exigen
    el filtro desactivado (tipo y tamano del uso del disco).

    Se distingue de un mantenimiento normal por la fase 'aplicando': el vigilante la reconoce en
    el arranque siguiente, aplica la cola, vuelve a proteger el equipo y reinicia sin que el
    tecnico tenga que hacer nada mas.
    """
    r = invoke_uwf(['filter', 'disable'])
    if not r['Ok']:
        raise RuntimeError('No se ha podido desactivar el filtro: %s' % r['Salida'])
    guardar_estado('aplicando')
    escribir_log('IniciarAplicacionPendientes', 'OK',
                 'filtro desactivado para aplicar la cola, pendiente de reinicio')


def finalizar_mantenimiento():
    """Paso 3 del flujo de mantenimiento: reactiva el filtro y marca la fase 'verificando'."""
    r = invoke_uwf(['filter', 'enable'])
    if not r['Ok']:
        raise RuntimeError('No se ha podido activar el filtro: %s' % r['Salida'])
    guardar_estado('verificando')
    escribir_log('FinalizarMantenimiento', 'OK', 'filtro activado, pendiente de reinicio')


def reiniciar_equipo(motivo):
    """Programa un reinicio en 10 segundos y lo deja anotado en el log."""
    escribir_log('Reinicio', 'OK', motivo)
    try:
        subprocess.Popen(['shutdown.exe', '/r', '/t', '10', '/c', 'UWF Aulas: %s' % motivo],
                         **_sin_ventana())
    except Exception as ex:
        escribir_log('Reinicio', 'ERROR', str(ex))


# =============================================================================
#  MODO VIGILANTE (sin interfaz, en cada arranque)
# =============================================================================

def ejecutar_vigilante():
    """Logica del modo --vigilante, ejecutada en cada arranque por la tarea programada.

    Sin fase abierta: solo avisa si el filtro esta desactivado sin motivo.
    Fase 'verificando': confirma que el filtro volvio a activarse tras el mantenimiento (si no, reintenta).
    Fase 'aplicando': arranque abierto por la herramienta para volcar la cola de pendientes; los
      aplica, vuelve a proteger el equipo y reinicia.
    Fase 'mantenimiento': aplica lo que haya encolado aprovechando que no hay proteccion y, si la
      ventana lleva abierta mas horas que el limite configurado, reactiva la proteccion sola.
    """
    estado = leer_estado()
    cfg = leer_config()
    uwf = get_estado_uwf()

    if not estado:
        if uwf['Instalado'] and not uwf['FiltroActual']:
            escribir_log('Vigilante', 'AVISO',
                         'El equipo ha arrancado con el filtro desactivado y sin mantenimiento en curso')
        return

    fase = estado.get('fase')
    if fase == 'aplicando':
        # El equipo ha arrancado sin proteccion solo para volcar la cola. Pase lo que pase con los
        # pendientes, el filtro tiene que quedar activo otra vez antes de devolver el equipo al aula.
        if uwf['FiltroActual']:
            escribir_log('Vigilante', 'ERROR',
                         'Se esperaba el filtro desactivado para aplicar la cola; se deja para el tecnico')
            guardar_estado('verificando')
            return
        try:
            res = aplicar_pendientes(False)
            escribir_log('Vigilante',
                         'OK' if (not res['Errores'] and not res['Restantes']) else 'PARCIAL',
                         'Cola aplicada: %d cambios, %d restantes, %d errores'
                         % (len(res['Aplicados']), res['Restantes'], len(res['Errores'])))
            for err in res['Errores']:
                escribir_log('Vigilante', 'ERROR', err)
        except Exception as ex:
            escribir_log('Vigilante', 'ERROR', 'Al aplicar la cola: %s' % ex)
        try:
            r = invoke_uwf(['filter', 'enable'])
            if not r['Ok']:
                escribir_log('Vigilante', 'ERROR', 'No se ha podido reactivar el filtro: %s' % r['Salida'])
            guardar_estado('verificando')
            reiniciar_equipo('cierre automatico tras aplicar los cambios pendientes')
        except Exception as ex:
            escribir_log('Vigilante', 'ERROR', str(ex))
    elif fase == 'verificando':
        if uwf['FiltroActual']:
            escribir_log('Vigilante', 'OK', 'Mantenimiento cerrado, filtro activo y verificado')
            guardar_estado(None)
        else:
            # Tope de reintentos: si 'filter enable' no consigue nada, reiniciar sin limite
            # dejaria el equipo en un bucle de reinicios que solo se arregla yendo al aula.
            try:
                intentos = int(estado.get('intentos') or 0)
            except (TypeError, ValueError):
                intentos = 0
            if intentos >= MaxReintentosFiltro:
                escribir_log('Vigilante', 'ERROR',
                             'El filtro sigue sin activarse tras %d intentos. No se reinicia mas: '
                             'hace falta revisar el equipo' % intentos)
                return
            escribir_log('Vigilante', 'ERROR',
                         'El filtro deberia estar activo y no lo esta. Reintento %d de %d'
                         % (intentos + 1, MaxReintentosFiltro))
            try:
                r = invoke_uwf(['filter', 'enable'])
                if not r['Ok']:
                    escribir_log('Vigilante', 'ERROR', 'filter enable: %s'
                                 % ' '.join(r['Salida'].replace(';', ',').split()))
                guardar_estado('verificando', intentos=intentos + 1)
                reiniciar_equipo('reactivando proteccion')
            except Exception as ex:
                escribir_log('Vigilante', 'ERROR', str(ex))
    elif fase == 'mantenimiento':
        # Arranque de mantenimiento: se aprovecha que no hay proteccion para volcar la cola.
        # Aqui no se reinicia, porque el tecnico esta trabajando en el equipo.
        if not uwf['FiltroActual'] and not pendientes_vacios(leer_pendientes()):
            try:
                res = aplicar_pendientes(False)
                escribir_log('Vigilante',
                             'OK' if (not res['Errores'] and not res['Restantes']) else 'PARCIAL',
                             'Cola aplicada en mantenimiento: %d cambios, %d restantes, %d errores'
                             % (len(res['Aplicados']), res['Restantes'], len(res['Errores'])))
                for err in res['Errores']:
                    escribir_log('Vigilante', 'ERROR', err)
            except Exception as ex:
                escribir_log('Vigilante', 'ERROR', 'Al aplicar la cola en mantenimiento: %s' % ex)

        maximo = 8
        try:
            if cfg.get('horasMaxMantenimiento'):
                maximo = float(cfg['horasMaxMantenimiento'])
        except (TypeError, ValueError):
            pass
        try:
            horas = (datetime.now() - datetime.fromisoformat(str(estado['inicio']))).total_seconds() / 3600.0
        except (KeyError, TypeError, ValueError):
            # Sin fecha legible no se puede saber cuanto lleva abierto: ante la duda se
            # protege el equipo, que es el fallo menos grave.
            escribir_log('Vigilante', 'AVISO', 'estado.json sin fecha de inicio valida')
            horas = maximo
        if horas >= maximo:
            escribir_log('Vigilante', 'AVISO',
                         'Mantenimiento abierto %.1f h, se reactiva la proteccion automaticamente' % horas)
            try:
                invoke_uwf(['filter', 'enable'])
                guardar_estado('verificando')
                reiniciar_equipo('cierre automatico de mantenimiento')
            except Exception as ex:
                escribir_log('Vigilante', 'ERROR', str(ex))
        else:
            escribir_log('Vigilante', 'INFO', 'Mantenimiento en curso desde hace %.1f h' % horas)


# =============================================================================
#  Instalar la caracteristica UWF (usado por la GUI)
# =============================================================================

Caracteristica = 'Client-UnifiedWriteFilter'


def _system32():
    """Carpeta de binarios del sistema correcta para este proceso.

    Un proceso de 32 bits en un Windows de 64 ve 'System32' redirigido a SysWOW64, y DISM no
    puede trabajar desde ahi: 'Sysnative' es el alias que lleva a los binarios reales de 64
    bits. Hoy el .exe se compila en 64 bits, pero esto evita un fallo dificil de diagnosticar
    si algun dia se compila en 32.
    """
    raiz = os.environ.get('SystemRoot', r'C:\WINDOWS')
    if sys.maxsize <= 2 ** 32:
        nativo = os.path.join(raiz, 'Sysnative')
        if os.path.isdir(nativo):
            return nativo
    return os.path.join(raiz, 'System32')


def _ejecutar_oculto(argumentos):
    """Lanza un proceso hijo sin ventana y sin heredar la entrada estandar.

    Redirigir stdin es imprescindible al correr como .exe empaquetado en modo --windowed: el
    proceso no tiene consola y sus descriptores estandar no son validos, asi que un hijo que
    los herede puede fallar de formas que no se reproducen ejecutando el .py desde una
    terminal. Devuelve (codigo, salida).
    """
    proc = subprocess.run(argumentos, capture_output=True, text=True, shell=False,
                          errors='replace', **_sin_ventana())
    return proc.returncode, ((proc.stdout or '') + (proc.stderr or '')).strip()


def estado_caracteristica_uwf():
    """Estado de la caracteristica UWF segun DISM, sin depender del idioma del sistema.

    Se fuerza '/English' justo para no parsear texto traducido, igual que el resto del
    proyecto evita leer la salida localizada de uwfmgr. Devuelve 'Enabled', 'EnablePending',
    'Disabled', 'NoDisponible' (la edicion de Windows no la incluye) o 'Desconocido'.
    """
    dism = os.path.join(_system32(), 'dism.exe')
    try:
        codigo, salida = _ejecutar_oculto([dism, '/online', '/get-featureinfo',
                                           '/featurename:' + Caracteristica, '/english'])
    except Exception:
        return 'Desconocido'
    bajo = salida.lower()
    if '0x800f080c' in bajo or 'is unknown' in bajo:
        return 'NoDisponible'
    m = re.search(r'^\s*State\s*:\s*(\S+)', salida, re.MULTILINE)
    if m:
        return m.group(1)
    return 'Desconocido'


def instalar_caracteristica_uwf():
    """Habilita la caracteristica opcional Unified Write Filter. Requiere reiniciar despues.

    Dos motores, porque en un equipo gestionado el primero puede no estar disponible:
      1. dism.exe directamente, que no depende de PowerShell ni de su modo de lenguaje
         (ConstrainedLanguage o AppLocker pueden bloquear cmdlets sin bloquear dism.exe).
      2. Enable-WindowsOptionalFeature, como respaldo.

    El resultado se comprueba releyendo el estado, no fiandose del codigo de salida, y se
    registra SIEMPRE en el log, tambien cuando falla: sin eso, un fallo en un aula no deja
    rastro con el que diagnosticar. Devuelve el estado final.
    """
    previo = estado_caracteristica_uwf()
    if previo == 'NoDisponible':
        escribir_log('InstalarCaracteristica', 'ERROR',
                     'esta edicion de Windows no incluye UWF (%s)' % Caracteristica)
        raise RuntimeError(
            'Esta edicion de Windows no incluye el Unified Write Filter.\n\n'
            'UWF solo esta disponible en Windows 10/11 Enterprise, Education e IoT '
            'Enterprise. Comprueba la edicion con "winver".')
    if previo in ('Enabled', 'EnablePending'):
        escribir_log('InstalarCaracteristica', 'OK', 'ya estaba habilitada: %s' % previo)
        return previo

    intentos = []

    dism = os.path.join(_system32(), 'dism.exe')
    try:
        codigo, salida = _ejecutar_oculto([dism, '/online', '/enable-feature',
                                           '/featurename:' + Caracteristica,
                                           '/norestart', '/quiet', '/english'])
    except Exception as ex:
        codigo, salida = -1, str(ex)
    intentos.append(('dism', codigo, salida))

    # 0 = hecho, 3010 = hecho pero pide reinicio
    if codigo not in (0, 3010):
        ps = os.path.join(_system32(), 'WindowsPowerShell', 'v1.0', 'powershell.exe')
        orden = ("Enable-WindowsOptionalFeature -Online -FeatureName '%s' -NoRestart "
                 "-ErrorAction Stop | Out-Null" % Caracteristica)
        try:
            codigo2, salida2 = _ejecutar_oculto([ps, '-NoProfile', '-NonInteractive',
                                                 '-ExecutionPolicy', 'Bypass', '-Command', orden])
        except Exception as ex:
            codigo2, salida2 = -1, str(ex)
        intentos.append(('powershell', codigo2, salida2))

    # Sin ';' en el detalle: es el separador de columnas del log CSV
    detalle = ' | '.join(
        '%s codigo=%s %s' % (motor, cod, ' '.join((sal or '').replace(';', ',').split())[:300])
        for motor, cod, sal in intentos
    )
    final = estado_caracteristica_uwf()
    # Si algun motor dijo que lo hizo pero no se puede releer el estado, se da por bueno
    if final == 'Desconocido' and any(cod in (0, 3010) for _, cod, _ in intentos):
        final = 'EnablePending'

    if final in ('Enabled', 'EnablePending'):
        escribir_log('InstalarCaracteristica', 'OK', 'estado=%s, %s' % (final, detalle))
        return final

    escribir_log('InstalarCaracteristica', 'ERROR', 'estado=%s, %s' % (final, detalle))
    raise RuntimeError(
        'No se ha podido habilitar UWF.\n\nEstado de la caracteristica: %s\n\n%s'
        % (final, detalle))


# =============================================================================
#  Dialogo: exclusiones por programa
# =============================================================================

def mostrar_dialogo_programa(padre):
    """Dialogo modal 'Exclusiones por programa': elegir un programa instalado y marcar que
    carpetas/claves propuestas anadir. Devuelve {Aceptado, Carpetas, Claves}."""
    import tkinter as tk
    from tkinter import ttk

    dlg = tk.Toplevel(padre)
    dlg.title('Exclusiones por programa')
    dlg.geometry('680x520')
    dlg.transient(padre)
    dlg.resizable(False, False)
    dlg.grab_set()

    tk.Label(dlg, text='Programa instalado en este equipo:').place(x=16, y=16)

    programas = get_programas_instalados()
    var_prog = tk.StringVar()
    combo = ttk.Combobox(dlg, textvariable=var_prog, state='readonly', width=100)
    combo['values'] = [p['Nombre'] for p in programas]
    combo.place(x=16, y=40, width=630)

    tk.Label(dlg, text='Se anadiran las exclusiones marcadas (desmarca las que no quieras):').place(x=16, y=82)

    marco = tk.Frame(dlg, bd=1, relief='sunken')
    marco.place(x=16, y=106, width=630, height=280)
    canvas = tk.Canvas(marco, highlightthickness=0)
    scroll = ttk.Scrollbar(marco, orient='vertical', command=canvas.yview)
    interior = tk.Frame(canvas)
    interior.bind('<Configure>', lambda e: canvas.configure(scrollregion=canvas.bbox('all')))
    canvas.create_window((0, 0), window=interior, anchor='nw')
    canvas.configure(yscrollcommand=scroll.set)
    canvas.pack(side='left', fill='both', expand=True)
    scroll.pack(side='right', fill='y')

    lbl_origen = tk.Label(dlg, text='', wraplength=630, justify='left')
    lbl_origen.place(x=16, y=392, width=630, height=36)

    estado = {'items': []}  # (tipo, valor, IntVar)
    resultado = {'Aceptado': False, 'Carpetas': [], 'Claves': []}

    def al_elegir(_evt=None):
        """Al seleccionar un programa en el combo, recalcula y muestra sus propuestas de exclusion."""
        for hijo in interior.winfo_children():
            hijo.destroy()
        estado['items'] = []
        idx = combo.current()
        if idx < 0:
            return
        sel = programas[idx]
        prop = get_propuestas_exclusion(sel['Nombre'], sel['Fabricante'])
        # Solo se premarca lo del catalogo, que esta verificado; lo de la heuristica es una
        # busqueda por nombre y el tecnico tiene que elegirlo a conciencia.
        marcar = 1 if prop['Origen'] == 'catalogo' else 0
        for c in prop['Carpetas']:
            var = tk.IntVar(value=marcar)
            tk.Checkbutton(interior, text='CARPETA  %s' % c, variable=var, anchor='w').pack(fill='x', anchor='w')
            estado['items'].append(('CARPETA', c, var))
        for k in prop['Claves']:
            var = tk.IntVar(value=marcar)
            tk.Checkbutton(interior, text='REGISTRO %s' % k, variable=var, anchor='w').pack(fill='x', anchor='w')
            estado['items'].append(('REGISTRO', k, var))

        if not estado['items']:
            lbl_origen.config(text='No se ha encontrado ninguna carpeta ni clave asociada a este programa. '
                                   'Anadela a mano desde la pestana Exclusiones.')
            btn_ok.config(state='disabled')
        elif prop['Origen'] == 'catalogo':
            lbl_origen.config(text='Programa reconocido: estas rutas son las recomendadas y estan verificadas '
                                   'en este equipo.')
            btn_ok.config(state='normal')
        else:
            lbl_origen.config(text='Programa fuera del catalogo: las rutas son una busqueda automatica por nombre. '
                                   'Marca solo las que sepas que pertenecen a este programa.')
            btn_ok.config(state='normal')

    combo.bind('<<ComboboxSelected>>', al_elegir)

    def aceptar():
        """Vuelca al resultado las propuestas marcadas y cierra el dialogo."""
        for tipo, valor, var in estado['items']:
            if var.get():
                if tipo == 'CARPETA':
                    resultado['Carpetas'].append(valor)
                else:
                    resultado['Claves'].append(valor)
        resultado['Aceptado'] = True
        dlg.destroy()

    btn_ok = tk.Button(dlg, text='Anadir seleccionadas', command=aceptar, state='disabled')
    btn_ok.place(x=400, y=436, width=170, height=34)
    tk.Button(dlg, text='Cancelar', command=dlg.destroy).place(x=578, y=436, width=80, height=34)

    padre.wait_window(dlg)
    return resultado


# =============================================================================
#  INTERFAZ GRAFICA
# =============================================================================

def mostrar_interfaz():
    """Construye y muestra la ventana principal (cinco pestanas: Estado, Exclusiones, Uso del
    disco, Mantenimiento, Configuracion) y arranca el bucle de eventos de Tkinter.

    Toda la ventana encola cambios; el unico sitio donde se aplican es la barra de pendientes
    de abajo, visible desde cualquier pestana."""
    import tkinter as tk
    from tkinter import ttk, messagebox, filedialog, simpledialog

    ROJO   = '#B22222'
    VERDE  = '#1E783C'
    NARANJA = '#C88200'
    AMBAR  = '#965000'
    GRIS   = '#808080'
    AZUL   = '#1F5FA9'
    ROJO_FILA = '#A03C3C'

    form = tk.Tk()
    form.title('UWF Aulas v2  -  %s' % os.environ.get('COMPUTERNAME', socket.gethostname()))
    form.geometry('940x700')
    form.minsize(820, 620)
    try:
        form.option_add('*Font', '{Segoe UI} 9')
    except Exception:
        pass

    # ---- Banner superior ----
    banner = tk.Frame(form, height=64)
    banner.pack(side='top', fill='x')
    banner.pack_propagate(False)
    lbl_banner = tk.Label(banner, text='', fg='white',
                          font=('Segoe UI', 13, 'bold'))
    lbl_banner.pack(fill='both', expand=True)

    # ---- Barra de estado inferior ----
    barra = tk.Frame(form, bd=1, relief='sunken')
    barra.pack(side='bottom', fill='x')
    lbl_barra = tk.Label(barra, text='Listo', anchor='w')
    lbl_barra.pack(side='left', padx=4)

    # ---- Barra de cambios pendientes (visible desde cualquier pestana) ----
    # Es el unico punto donde se aplica algo: el resto de la ventana solo encola.
    barra_pend = tk.Frame(form, height=56, bd=1, relief='raised')
    barra_pend.pack(side='bottom', fill='x')
    barra_pend.pack_propagate(False)
    lbl_pend = tk.Label(barra_pend, anchor='w', justify='left', font=('Segoe UI', 9, 'bold'))
    lbl_pend.place(x=12, y=8, width=560, height=40)
    btn_aplicar_pend = tk.Button(barra_pend, text='Aplicar cambios y reiniciar',
                                 font=('Segoe UI', 9, 'bold'))
    btn_aplicar_pend.place(x=588, y=11, width=200, height=34)
    btn_descartar_pend = tk.Button(barra_pend, text='Descartar')
    btn_descartar_pend.place(x=798, y=11, width=110, height=34)

    # ---- Cuaderno de pestanas ----
    tabs = ttk.Notebook(form)
    tabs.pack(fill='both', expand=True)

    tab_estado  = ttk.Frame(tabs); tabs.add(tab_estado,  text='Estado')
    tab_excl    = ttk.Frame(tabs); tabs.add(tab_excl,    text='Exclusiones')
    tab_overlay = ttk.Frame(tabs); tabs.add(tab_overlay, text='Uso del disco')
    tab_mant    = ttk.Frame(tabs); tabs.add(tab_mant,    text='Mantenimiento')
    tab_cfg     = ttk.Frame(tabs); tabs.add(tab_cfg,     text='Configuracion')

    # =========================== PESTANA ESTADO ==============================
    txt_estado = tk.Text(tab_estado, height=15, wrap='none', font=('Consolas', 10))
    txt_estado.place(x=16, y=16, width=880, height=300)
    txt_estado.config(state='disabled')

    barra_overlay = ttk.Progressbar(tab_estado, maximum=100, value=0)
    barra_overlay.place(x=16, y=328, width=880, height=22)

    btn_instalar = tk.Button(tab_estado, text='Instalar caracteristica UWF')
    btn_instalar.place(x=16, y=368, width=220, height=34)
    btn_preparar = tk.Button(tab_estado, text='Preparar equipo (protege C: y aplica perfil)')
    btn_preparar.place(x=248, y=368, width=300, height=34)
    btn_refrescar = tk.Button(tab_estado, text='Actualizar estado')
    btn_refrescar.place(x=560, y=368, width=160, height=34)

    # ========================= PESTANA EXCLUSIONES ===========================
    cols = ('estado', 'tipo', 'ruta', 'existe')
    lv = ttk.Treeview(tab_excl, columns=cols, show='headings')
    lbl_resumen_excl = tk.Label(tab_excl, anchor='w', justify='left', font=('Segoe UI', 9, 'bold'))
    lbl_resumen_excl.place(x=16, y=8, width=880, height=22)

    lv.heading('estado', text='Estado'); lv.column('estado', width=190, anchor='w')
    lv.heading('tipo', text='Tipo'); lv.column('tipo', width=80, anchor='w')
    lv.heading('ruta', text='Ruta o clave'); lv.column('ruta', width=470, anchor='w')
    lv.heading('existe', text='Existe'); lv.column('existe', width=130, anchor='w')
    lv.tag_configure('noexiste', foreground=ROJO_FILA)
    lv.tag_configure('permitida', foreground=VERDE)
    lv.tag_configure('transito', foreground=AMBAR)
    lv.tag_configure('vacio', foreground=GRIS)
    lv.tag_configure('pend_add', foreground=AZUL)
    lv.tag_configure('pend_del', foreground=ROJO)
    lv.place(x=16, y=34, width=880, height=362)

    btn_add_programa = tk.Button(tab_excl, text='Anadir por programa...', font=('Segoe UI', 9, 'bold'))
    btn_add_programa.place(x=16, y=408, width=170, height=32)
    btn_add_carpeta = tk.Button(tab_excl, text='Carpeta')
    btn_add_carpeta.place(x=194, y=408, width=90, height=32)
    btn_add_archivo = tk.Button(tab_excl, text='Archivo')
    btn_add_archivo.place(x=292, y=408, width=90, height=32)
    btn_add_reg = tk.Button(tab_excl, text='Clave HKLM')
    btn_add_reg.place(x=390, y=408, width=110, height=32)
    btn_quitar = tk.Button(tab_excl, text='Quitar')
    btn_quitar.place(x=508, y=408, width=80, height=32)
    btn_importar = tk.Button(tab_excl, text='Importar perfil')
    btn_importar.place(x=618, y=408, width=130, height=32)
    btn_exportar = tk.Button(tab_excl, text='Exportar perfil')
    btn_exportar.place(x=756, y=408, width=130, height=32)

    lbl_aviso = tk.Label(
        tab_excl, fg=AMBAR, justify='left', wraplength=880,
        text='Los cambios se quedan en la lista como PENDIENTES hasta que pulses "Aplicar cambios y '
             'reiniciar" abajo. Todo lo excluido se guarda de verdad en el disco: excluye lo minimo.')
    lbl_aviso.place(x=16, y=448, width=880, height=34)

    # ======================== PESTANA USO DEL DISCO ==========================
    # Sin saltos de linea a mano dentro de cada parrafo: el texto se reparte solo en el ancho
    # disponible. Con los saltos fijos ocupaba mas de lo que cabe y las dos ultimas lineas
    # (justo las que explican cuando se puede cambiar el tamano) quedaban tapadas.
    lbl_ov1 = tk.Label(tab_overlay, justify='left', anchor='nw', wraplength=880, text=(
        'Mientras la proteccion esta activa, todo lo que el profesor escribe en el equipo no va al '
        'disco de verdad: se guarda en un espacio aparte que se vacia al reiniciar. Aqui se decide '
        'cuanto espacio se reserva para eso y donde.\n\n'
        '- Disco: reserva el espacio en C:. Recomendado para las aulas: no resta memoria al equipo.\n'
        '- RAM:   mas rapido, pero consume memoria fisica segun se llena. Solo para equipos con mucha RAM.\n\n'
        'Los cambios de aqui tampoco se aplican al momento: se encolan como pendientes. El tamano y '
        'el sitio solo pueden cambiarse con la proteccion desactivada, asi que si hace falta se '
        'abrira la ventana de mantenimiento sola al aplicar.'))
    lbl_ov1.place(x=16, y=16, width=880, height=160)

    gb_tipo = tk.LabelFrame(tab_overlay, text='Donde se guarda')
    gb_tipo.place(x=16, y=176, width=240, height=90)
    var_tipo = tk.StringVar(value='Disco')
    tk.Radiobutton(gb_tipo, text='Disco (C:)  - recomendado', variable=var_tipo, value='Disco', anchor='w').place(x=16, y=6, width=210, height=24)
    tk.Radiobutton(gb_tipo, text='RAM (memoria)', variable=var_tipo, value='RAM', anchor='w').place(x=16, y=34, width=210, height=24)

    gb_tam = tk.LabelFrame(tab_overlay, text='Espacio (MB)')
    gb_tam.place(x=272, y=176, width=600, height=90)
    tk.Label(gb_tam, text='Tamano:').place(x=16, y=12)
    num_tam = tk.Spinbox(gb_tam, from_=512, to=65536, increment=512, width=8)
    num_tam.place(x=78, y=10, width=90, height=24)
    tk.Label(gb_tam, text='Aviso:').place(x=196, y=12)
    num_av = tk.Spinbox(gb_tam, from_=128, to=65536, increment=128, width=8)
    num_av.place(x=246, y=10, width=90, height=24)
    tk.Label(gb_tam, text='Critico:').place(x=364, y=12)
    num_cr = tk.Spinbox(gb_tam, from_=256, to=65536, increment=128, width=8)
    num_cr.place(x=418, y=10, width=90, height=24)
    tk.Label(gb_tam, fg=GRIS,
             text='Regla: aviso < critico <= tamano. Ambos miden el consumo acumulado.').place(x=16, y=40)

    def _set_spin(spin, valor):
        """Fija el valor mostrado en un Spinbox."""
        spin.delete(0, 'end')
        spin.insert(0, str(valor))

    _set_spin(num_tam, 4096)
    _set_spin(num_av, 2560)
    _set_spin(num_cr, 3584)

    btn_aplicar_ov = tk.Button(tab_overlay, text='Anadir a los cambios pendientes',
                               font=('Segoe UI', 9, 'bold'))
    btn_aplicar_ov.place(x=16, y=284, width=280, height=40)
    lbl_ov_estado = tk.Label(tab_overlay, justify='left', anchor='nw', wraplength=880)
    lbl_ov_estado.place(x=16, y=340, width=880, height=60)

    # ======================== PESTANA MANTENIMIENTO ==========================
    lbl_mant = tk.Label(tab_mant, justify='left', anchor='nw', wraplength=880, font=('Segoe UI', 10), text=(
        'Flujo de mantenimiento (sustituye al servicing mode de UWF):\n\n'
        '  1. Iniciar mantenimiento    ->  desactiva el filtro y reinicia\n'
        '  2. El equipo arranca sin proteccion: instala parches, actualiza Kaspersky, cambia lo que necesites\n'
        '  3. Finalizar y proteger     ->  reactiva el filtro y reinicia\n'
        '  4. Al arrancar, el vigilante comprueba que la proteccion ha vuelto y lo anota en el registro\n\n'
        'Si el mantenimiento se queda abierto mas horas de las configuradas, el vigilante reactiva\n'
        'la proteccion por su cuenta en el siguiente arranque.'))
    lbl_mant.place(x=16, y=16, width=880, height=210)

    lbl_fase = tk.Label(tab_mant, anchor='w', font=('Segoe UI', 10, 'bold'))
    lbl_fase.place(x=16, y=236, width=880, height=30)

    btn_iniciar_m = tk.Button(tab_mant, text='1 - Iniciar mantenimiento y reiniciar')
    btn_iniciar_m.place(x=16, y=280, width=330, height=52)
    btn_finalizar_m = tk.Button(tab_mant, text='3 - Finalizar, proteger y reiniciar')
    btn_finalizar_m.place(x=360, y=280, width=330, height=52)

    txt_log = tk.Text(tab_mant, wrap='none', font=('Consolas', 9))
    txt_log.place(x=16, y=348, width=880, height=150)
    txt_log.config(state='disabled')

    # ======================== PESTANA CONFIGURACION ==========================
    tk.Label(tab_cfg, text='Ruta de red para el registro centralizado (opcional):').place(x=16, y=20)
    txt_red = tk.Entry(tab_cfg)
    txt_red.place(x=16, y=46, width=600, height=24)
    tk.Label(tab_cfg, text='Horas maximas con el mantenimiento abierto antes de reactivar la proteccion:').place(x=16, y=86)
    num_horas = tk.Spinbox(tab_cfg, from_=1, to=72, width=6)
    num_horas.place(x=16, y=112, width=80, height=24)
    btn_guardar_cfg = tk.Button(tab_cfg, text='Guardar configuracion')
    btn_guardar_cfg.place(x=16, y=156, width=200, height=34)
    btn_abrir_carpeta = tk.Button(tab_cfg, text='Abrir carpeta de la herramienta')
    btn_abrir_carpeta.place(x=228, y=156, width=240, height=34)

    # ============================ LOGICA GUI =================================
    def refrescar():
        """Vuelve a leer el estado de UWF y la cola de pendientes, y redibuja toda la ventana:
        banner, pestana Estado, campos de Uso del disco, lista de Exclusiones (pendientes
        incluidos), barra de pendientes y las ultimas lineas del log."""
        try:
            u = get_estado_uwf()
            es = leer_estado()
            pend = leer_pendientes()
            lineas_pend = resumen_pendientes(pend)

            lineas = []
            lineas.append('Equipo              : %s' % os.environ.get('COMPUTERNAME', ''))
            lineas.append('Caracteristica UWF  : %s' % ('instalada' if u['Instalado'] else 'NO instalada'))
            lineas.append('Filtro (sesion act.): %s' % ('ACTIVO' if u['FiltroActual'] else 'DESACTIVADO'))
            lineas.append('Filtro (tras reinic): %s' % ('ACTIVO' if u['FiltroSiguiente'] else 'DESACTIVADO'))
            lineas.append('Volumenes protegidos: %s' % (', '.join(u['VolumenesActual']) if u['VolumenesActual'] else 'ninguno'))
            lineas.append('Uso del disco       : %s, maximo %s MB' % (u['OverlayTipo'], u['OverlayMaxMB']))
            lineas.append('Umbrales            : aviso %s MB, critico %s MB' % (u['OverlayAvisoMB'], u['OverlayCriticoMB']))
            if u['OverlayUsoMB'] >= 0:
                lineas.append('Espacio consumido   : %s MB' % u['OverlayUsoMB'])
            lineas.append('')
            if es:
                lineas.append("Mantenimiento       : fase '%s' iniciada el %s por %s" % (es['fase'], es['inicio'], es['tecnico']))
            else:
                lineas.append('Mantenimiento       : ninguno en curso')
            lineas.append('Cambios pendientes  : %s' % (
                '%d sin aplicar' % len(lineas_pend) if lineas_pend else 'ninguno'))
            if u['Error']:
                lineas.append('')
                lineas.append('Aviso: %s' % u['Error'])

            txt_estado.config(state='normal')
            txt_estado.delete('1.0', 'end')
            txt_estado.insert('end', '\n'.join(lineas))
            txt_estado.config(state='disabled')

            if u['OverlayMaxMB'] > 0 and u['OverlayUsoMB'] >= 0:
                barra_overlay['maximum'] = int(u['OverlayMaxMB'])
                barra_overlay['value'] = min(int(u['OverlayUsoMB']), int(u['OverlayMaxMB']))

            # Banner
            fase_abierta = es.get('fase') if es else None
            if fase_abierta in ('mantenimiento', 'aplicando') and not u['FiltroActual']:
                banner.config(bg=ROJO); lbl_banner.config(bg=ROJO,
                    text=('APLICANDO CAMBIOS PENDIENTES  -  EL EQUIPO NO ESTA PROTEGIDO'
                          if fase_abierta == 'aplicando'
                          else 'MANTENIMIENTO EN CURSO  -  EL EQUIPO NO ESTA PROTEGIDO'))
            elif u['FiltroActual']:
                banner.config(bg=VERDE); lbl_banner.config(bg=VERDE,
                    text='PROTECCION ACTIVA  -  los cambios se descartan al reiniciar')
            else:
                banner.config(bg=NARANJA); lbl_banner.config(bg=NARANJA,
                    text='PROTECCION DESACTIVADA  -  los cambios se guardan en disco')

            lbl_fase.config(text=lbl_banner.cget('text'))
            btn_iniciar_m.config(state='normal' if (u['Instalado'] and u['FiltroActual']) else 'disabled')
            btn_finalizar_m.config(state='normal' if (u['Instalado'] and not u['FiltroActual']) else 'disabled')
            btn_instalar.config(state='normal' if not u['Instalado'] else 'disabled')

            # Pestana Uso del disco: si hay algo encolado se muestran los valores pendientes
            # (son los que el tecnico acaba de decidir); si no, el estado real del equipo.
            if pend.get('disco'):
                d = pend['disco']
                var_tipo.set(d['tipo'])
                _set_spin(num_tam, d['tamanoMB'])
                _set_spin(num_av, d['avisoMB'])
                _set_spin(num_cr, d['criticoMB'])
                lbl_ov_estado.config(fg=AZUL,
                    text='Estos valores estan PENDIENTES: todavia no son los del equipo. Pulsa '
                         '"Aplicar cambios y reiniciar" abajo para que surtan efecto, o "Descartar" '
                         'para volver a la configuracion real.')
            elif u['Instalado']:
                var_tipo.set('RAM' if u['OverlayTipo'] == 'RAM' else 'Disco')
                if u['OverlayMaxMB'] >= 512:
                    _set_spin(num_tam, min(u['OverlayMaxMB'], 65536))
                if u['OverlayAvisoMB'] >= 128:
                    _set_spin(num_av, min(u['OverlayAvisoMB'], 65536))
                if u['OverlayCriticoMB'] >= 256:
                    _set_spin(num_cr, min(u['OverlayCriticoMB'], 65536))
                if u['FiltroActual']:
                    lbl_ov_estado.config(fg=AMBAR,
                        text='La proteccion esta ACTIVA: el tamano y el sitio no se pueden cambiar ahora. '
                             'Si los cambias, al aplicar se abrira la ventana de mantenimiento sola y el '
                             'equipo se reiniciara dos veces.')
                else:
                    lbl_ov_estado.config(fg=VERDE,
                        text='La proteccion esta desactivada: se puede cambiar todo. '
                             'Los cambios se aplican tras reiniciar.')
            else:
                lbl_ov_estado.config(fg=GRIS,
                    text='UWF no esta instalado en este equipo: puedes dejar la configuracion preparada '
                         'como pendiente, pero no se aplicara hasta instalar la caracteristica.')

            # Exclusiones: primero la cola de pendientes, que se ve siempre aunque UWF no este
            # disponible en este equipo; despues lo que ya esta permitido en UWF, distinguiendo
            # si vale ya o solo tras reiniciar.
            for fila in lv.get_children():
                lv.delete(fila)
            encolados = set()
            for e in pend['exclusiones']:
                existe = (os.path.exists(e['valor']) if e['tipo'] == 'archivo'
                          else existe_clave_hklm(e['valor']))
                encolados.add((e['tipo'], _clave_pendiente(e['tipo'], e['valor'])))
                lv.insert('', 'end', values=(
                    'PENDIENTE: anadir' if e['accion'] == 'add' else 'PENDIENTE: quitar',
                    'Archivo' if e['tipo'] == 'archivo' else 'Registro',
                    e['valor'],
                    'si' if existe else 'NO EXISTE - revisar',
                ), tags=('pend_add' if e['accion'] == 'add' else 'pend_del',))

            n_arch = n_reg = 0
            if u['Instalado']:
                detalle = sorted(get_exclusiones_detalle(),
                                 key=lambda d: (d['Tipo'] != 'archivo', d['Valor'].lower()))
                for d in detalle:
                    if (d['Tipo'], _clave_pendiente(d['Tipo'], d['Valor'])) in encolados:
                        continue
                    if d['Ahora'] and d['TrasReinicio']:
                        texto, tag = 'Permitida', 'permitida'
                    elif d['TrasReinicio']:
                        texto, tag = 'Permitida tras reiniciar', 'transito'
                    else:
                        texto, tag = 'Se quita al reiniciar', 'transito'
                    if d['TrasReinicio']:
                        if d['Tipo'] == 'archivo':
                            n_arch += 1
                        else:
                            n_reg += 1
                    existe = (os.path.exists(d['Valor']) if d['Tipo'] == 'archivo'
                              else existe_clave_hklm(d['Valor']))
                    lv.insert('', 'end', values=(
                        texto,
                        'Archivo' if d['Tipo'] == 'archivo' else 'Registro',
                        d['Valor'],
                        'si' if existe else 'NO EXISTE - revisar',
                    ), tags=(tag,) if existe else ('noexiste',))

            if not u['Instalado']:
                lbl_resumen_excl.config(fg=GRIS,
                    text='UWF no esta instalado: este equipo no tiene exclusiones permitidas.')
            elif n_arch or n_reg:
                lbl_resumen_excl.config(fg=VERDE, text=(
                    'Permitidas en este equipo: %d carpeta(s)/archivo(s) y %d clave(s) de registro. '
                    'Todo lo que no aparece aqui se borra al reiniciar.' % (n_arch, n_reg)))
            else:
                lbl_resumen_excl.config(fg=AMBAR,
                    text='Este equipo no tiene ninguna exclusion permitida: todo se borra al reiniciar.')
            if not lv.get_children():
                lv.insert('', 'end', values=('', '', '(sin exclusiones ni cambios pendientes)', ''),
                          tags=('vacio',))

            # Barra de cambios pendientes
            if lineas_pend:
                resumen = '  |  '.join(lineas_pend[:2])
                if len(lineas_pend) > 2:
                    resumen += '  |  y %d mas' % (len(lineas_pend) - 2)
                plural = '' if len(lineas_pend) == 1 else 's'
                lbl_pend.config(fg=AZUL, text='%d cambio%s pendiente%s de aplicar:\n%s'
                                             % (len(lineas_pend), plural, plural, resumen))
                btn_aplicar_pend.config(state='normal')
                btn_descartar_pend.config(state='normal')
            else:
                lbl_pend.config(fg=GRIS,
                    text='Sin cambios pendientes.\nLo que configures en Exclusiones o en Uso del disco '
                         'aparecera aqui antes de aplicarse.')
                btn_aplicar_pend.config(state='disabled')
                btn_descartar_pend.config(state='disabled')

            # Log
            if os.path.isfile(LogPath):
                try:
                    with open(LogPath, 'r', encoding='utf-8', errors='replace') as fh:
                        cola = fh.read().splitlines()[-40:]
                    txt_log.config(state='normal')
                    txt_log.delete('1.0', 'end')
                    txt_log.insert('end', '\n'.join(cola))
                    txt_log.see('end')
                    txt_log.config(state='disabled')
                except Exception:
                    pass

            lbl_barra.config(text='Actualizado ' + _now('%H:%M:%S'))
        except Exception as ex:
            lbl_barra.config(text='Error: ' + str(ex))

    def preguntar_reinicio(motivo):
        """Pregunta si reiniciar ahora y, si se confirma, lanza el reinicio con el motivo indicado."""
        if messagebox.askyesno('UWF Aulas',
                               'Hay que reiniciar para que el cambio surta efecto.\n\nReiniciar ahora?'):
            reiniciar_equipo(motivo)

    def on_instalar():
        """Boton 'Instalar caracteristica UWF'. Puede tardar: DISM trabaja sobre la imagen."""
        try:
            lbl_barra.config(text='Instalando la caracteristica UWF (puede tardar un minuto)...')
            form.config(cursor='watch'); form.update_idletasks()
            estado = instalar_caracteristica_uwf()
            form.config(cursor='')
            refrescar()
            if estado == 'Enabled':
                # Ya activa: no hace falta reiniciar
                messagebox.showinfo('UWF Aulas', 'La caracteristica UWF ya esta habilitada.')
            else:
                preguntar_reinicio('instalacion de la caracteristica UWF')
        except Exception as ex:
            form.config(cursor='')
            lbl_barra.config(text='No se ha podido instalar la caracteristica UWF')
            messagebox.showerror('Error', str(ex))

    def on_preparar():
        """Boton 'Preparar equipo': protege C: con UWF y aplica el perfil de exclusiones guardado."""
        try:
            form.config(cursor='watch'); form.update_idletasks()
            r = invoke_uwf(['volume', 'protect', 'C:'])
            if not r['Ok']:
                raise RuntimeError('No se ha podido proteger C: con UWF:\n\n%s' % r['Salida'])
            u = get_estado_uwf()
            errores = aplicar_perfil(leer_perfil(), u['FiltroActual'])
            r = invoke_uwf(['filter', 'enable'])
            if not r['Ok']:
                raise RuntimeError('No se ha podido activar el filtro:\n\n%s' % r['Salida'])
            # Como cualquier activacion del filtro, el vigilante lo confirma en el arranque
            guardar_estado('verificando')
            escribir_log('PrepararEquipo', 'OK' if not errores else 'PARCIAL',
                         '%d avisos' % len(errores))
            form.config(cursor='')
            refrescar()
            if errores:
                messagebox.showwarning('UWF Aulas', 'Equipo preparado, pero con avisos:\n\n' + '\n'.join(errores))
            preguntar_reinicio('preparacion del equipo')
        except Exception as ex:
            form.config(cursor='')
            messagebox.showerror('Error', str(ex))

    def _encolar_exclusion(tipo, valor, accion='add'):
        """Encola una exclusion y refresca la ventana. La validacion ocurre al encolar, asi que
        el tecnico ve el error en el momento en que lo decide y no al aplicar."""
        try:
            p = leer_pendientes()
            anadir_pendiente_exclusion(p, tipo, accion, valor)
            guardar_pendientes(p)
            escribir_log('EncolarExclusion', 'OK', '%s %s %s' % (accion, tipo, valor))
            refrescar()
        except Exception as ex:
            messagebox.showerror('Error', str(ex))

    def on_add_programa():
        """Boton 'Anadir por programa...': encola como pendientes las exclusiones aceptadas."""
        try:
            res = mostrar_dialogo_programa(form)
            if not res['Aceptado']:
                return
            p = leer_pendientes()
            nuevos = 0
            errores = []
            for tipo, valores in (('archivo', res['Carpetas']), ('registro', res['Claves'])):
                for v in valores:
                    try:
                        if anadir_pendiente_exclusion(p, tipo, 'add', v):
                            nuevos += 1
                    except Exception as ex:
                        errores.append('%s -> %s' % (v, ex))
            guardar_pendientes(p)
            escribir_log('EncolarExclusiones', 'OK', 'por programa: %d encoladas' % nuevos)
            refrescar()
            if errores:
                messagebox.showwarning('UWF Aulas', 'Encolado con avisos:\n\n' + '\n'.join(errores))
            lbl_barra.config(text='%d exclusiones encoladas como pendientes' % nuevos)
        except Exception as ex:
            messagebox.showerror('Error', str(ex))

    def on_add_carpeta():
        """Boton 'Carpeta': elige una carpeta y la encola como exclusion pendiente."""
        ruta = filedialog.askdirectory()
        if ruta:
            _encolar_exclusion('archivo', os.path.normpath(ruta))

    def on_add_archivo():
        """Boton 'Archivo': elige un archivo suelto y lo encola como exclusion pendiente."""
        ruta = filedialog.askopenfilename()
        if ruta:
            _encolar_exclusion('archivo', os.path.normpath(ruta))

    def on_add_reg():
        """Boton 'Clave HKLM': pide una clave de registro y la encola como exclusion pendiente."""
        clave = simpledialog.askstring('UWF Aulas', 'Clave de registro a excluir (solo HKLM):',
                                       initialvalue='HKLM\\SOFTWARE\\', parent=form)
        if clave:
            _encolar_exclusion('registro', clave)

    def on_quitar():
        """Boton 'Quitar': sobre una fila pendiente la saca de la cola; sobre una exclusion ya
        activa en UWF encola su retirada. En ningun caso toca el equipo todavia."""
        sel = lv.selection()
        if not sel:
            return
        valores = lv.item(sel[0])['values']
        estado_fila, tipo_txt, valor = str(valores[0]), str(valores[1]), str(valores[2])
        if not tipo_txt:
            return   # fila informativa de lista vacia
        if estado_fila == 'Se quita al reiniciar':
            lbl_barra.config(text='Esa exclusion ya se quitara al reiniciar')
            return
        tipo = 'archivo' if tipo_txt == 'Archivo' else 'registro'
        try:
            p = leer_pendientes()
            if estado_fila.startswith('PENDIENTE'):
                quitar_pendiente_exclusion(p, tipo, valor)
                escribir_log('CancelarPendiente', 'OK', '%s %s' % (tipo, valor))
                lbl_barra.config(text='Pendiente cancelado')
            else:
                anadir_pendiente_exclusion(p, tipo, 'remove', valor)
                escribir_log('EncolarExclusion', 'OK', 'remove %s %s' % (tipo, valor))
                lbl_barra.config(text='Retirada encolada como pendiente')
            guardar_pendientes(p)
            refrescar()
        except Exception as ex:
            messagebox.showerror('Error', str(ex))

    def on_aplicar_pendientes():
        """Boton 'Aplicar cambios y reiniciar': el unico punto donde la cola llega a UWF."""
        p = leer_pendientes()
        if pendientes_vacios(p):
            return
        u = get_estado_uwf()
        if not u['Instalado']:
            messagebox.showwarning('UWF Aulas',
                'UWF no esta instalado en este equipo, asi que los cambios no pueden aplicarse '
                'todavia. Instalalo desde la pestana Estado: la cola de pendientes se conserva.')
            return

        requiere_off = u['FiltroActual'] and disco_pendiente_exige_filtro_off(p, u)
        detalle = '\n'.join('  - ' + l for l in resumen_pendientes(p))
        aviso = 'Se van a aplicar estos cambios:\n\n%s\n\n' % detalle
        if requiere_off:
            aviso += ('Cambiar el tamano o el sitio exige desactivar la proteccion, asi que el equipo se\n'
                      'reiniciara DOS veces: la primera para aplicarlo sin proteccion y la segunda para\n'
                      'volver a protegerlo. No hay que hacer nada entre medias.\n\nContinuar?')
        else:
            aviso += 'El equipo se reiniciara una vez para que surtan efecto.\n\nContinuar?'
        if not messagebox.askyesno('UWF Aulas', aviso):
            return

        try:
            form.config(cursor='watch'); form.update_idletasks()
            res = aplicar_pendientes(u['FiltroActual'])
            form.config(cursor='')
            refrescar()
            if res['Errores']:
                messagebox.showwarning('UWF Aulas', 'Aplicado con avisos:\n\n' + '\n'.join(res['Errores']))
            if requiere_off and res['EsperandoFiltroOff']:
                iniciar_aplicacion_pendientes()
                refrescar()
                reiniciar_equipo('aplicar cambios pendientes sin proteccion')
            elif res['Aplicados']:
                preguntar_reinicio('cambios pendientes aplicados')
        except Exception as ex:
            form.config(cursor='')
            messagebox.showerror('Error', str(ex))

    def on_descartar_pendientes():
        """Boton 'Descartar': vacia la cola sin tocar el equipo."""
        p = leer_pendientes()
        if pendientes_vacios(p):
            return
        if not messagebox.askyesno('UWF Aulas',
                'Se descartaran los %d cambios pendientes sin aplicarlos.\n\n'
                'El equipo se queda exactamente como esta. Continuar?' % len(resumen_pendientes(p))):
            return
        guardar_pendientes({'exclusiones': [], 'disco': None})
        escribir_log('DescartarPendientes', 'OK')
        refrescar()
        lbl_barra.config(text='Cambios pendientes descartados')

    def on_importar():
        """Boton 'Importar perfil': carga un perfil JSON, lo guarda como el activo y encola todo
        su contenido como cambios pendientes para que el tecnico lo revise antes de aplicarlo."""
        ruta = filedialog.askopenfilename(filetypes=[('Perfil JSON', '*.json')])
        if not ruta:
            return
        try:
            with open(ruta, 'r', encoding='utf-8-sig') as fh:
                perfil = json.load(fh)
            guardar_perfil(perfil)          # valida los umbrales y rechaza el perfil si no cuadran
            p = leer_pendientes()
            nuevos = 0
            errores = []
            for tipo, clave in (('archivo', 'archivos'), ('registro', 'registro')):
                for v in (perfil.get(clave) or []):
                    try:
                        if anadir_pendiente_exclusion(p, tipo, 'add', v):
                            nuevos += 1
                    except Exception as ex:
                        errores.append('%s -> %s' % (v, ex))
            ov = perfil.get('overlay') or {}
            if ov:
                try:
                    fijar_pendiente_disco(p, 'RAM' if ov.get('tipo') == 'RAM' else 'Disco',
                                          ov.get('tamanoMB'), ov.get('avisoMB'), ov.get('criticoMB'))
                    nuevos += 1
                except Exception as ex:
                    errores.append('uso del disco -> %s' % ex)
            guardar_pendientes(p)
            escribir_log('ImportarPerfil', 'OK',
                         "%s: %d cambios encolados" % (perfil.get('nombre', ''), nuevos))
            refrescar()
            msg = ("Perfil '%s' cargado.\n\n%d cambios encolados como pendientes: revisalos y pulsa "
                   '"Aplicar cambios y reiniciar".' % (perfil.get('nombre', ''), nuevos))
            if errores:
                msg += '\n\nAvisos:\n' + '\n'.join(errores)
            messagebox.showinfo('UWF Aulas', msg)
        except Exception as ex:
            messagebox.showerror('Error', str(ex))

    def on_exportar():
        """Boton 'Exportar perfil': vuelca las exclusiones y el overlay actuales a un JSON."""
        ruta = filedialog.asksaveasfilename(defaultextension='.json',
                                            initialfile='perfil-exclusiones.json',
                                            filetypes=[('Perfil JSON', '*.json')])
        if ruta:
            try:
                u = get_estado_uwf()
                perfil = {
                    'nombre':   'Exportado de %s' % os.environ.get('COMPUTERNAME', ''),
                    'version':  _now('%Y-%m-%d'),
                    'archivos': get_exclusiones_archivo(),
                    'registro': get_exclusiones_registro(),
                }
                # El uso del disco solo se exporta si se ha podido leer entero: con valores a 0
                # la validacion de umbrales rechazaria el perfil y no se exportaria nada.
                if (u['OverlayTipo'] in ('RAM', 'Disco') and test_umbrales_validos(
                        u['OverlayAvisoMB'], u['OverlayCriticoMB'], u['OverlayMaxMB'])):
                    perfil['overlay'] = {
                        'tipo':      u['OverlayTipo'],
                        'tamanoMB':  u['OverlayMaxMB'],
                        'avisoMB':   u['OverlayAvisoMB'],
                        'criticoMB': u['OverlayCriticoMB'],
                    }
                guardar_perfil(perfil, ruta)
                messagebox.showinfo('UWF Aulas', 'Perfil exportado.')
            except Exception as ex:
                messagebox.showerror('Error', str(ex))

    def on_aplicar_ov():
        """Boton 'Anadir a los cambios pendientes' de la pestana Uso del disco."""
        try:
            tipo = 'RAM' if var_tipo.get() == 'RAM' else 'Disco'
            p = leer_pendientes()
            fijar_pendiente_disco(p, tipo, int(num_tam.get()), int(num_av.get()), int(num_cr.get()))
            guardar_pendientes(p)
            escribir_log('EncolarUsoDisco', 'OK', 'tipo=%s tamano=%s aviso=%s critico=%s'
                         % (tipo, num_tam.get(), num_av.get(), num_cr.get()))
            refrescar()
            lbl_barra.config(text='Uso del disco encolado como pendiente')
        except Exception as ex:
            messagebox.showerror('Error', str(ex))

    def on_iniciar_m():
        """Boton '1 - Iniciar mantenimiento y reiniciar', tras confirmar con el tecnico."""
        if not messagebox.askyesno('UWF Aulas',
                'Se va a desactivar la proteccion y reiniciar el equipo.\n\n'
                'Durante el mantenimiento TODO lo que se escriba se guarda de forma permanente. Continuar?'):
            return
        try:
            iniciar_mantenimiento(); refrescar(); reiniciar_equipo('inicio de mantenimiento')
        except Exception as ex:
            messagebox.showerror('Error', str(ex))

    def on_finalizar_m():
        """Boton '3 - Finalizar, proteger y reiniciar'."""
        try:
            finalizar_mantenimiento(); refrescar(); reiniciar_equipo('cierre de mantenimiento')
        except Exception as ex:
            messagebox.showerror('Error', str(ex))

    def on_guardar_cfg():
        """Boton 'Guardar configuracion' de la pestana Configuracion."""
        try:
            guardar_config({'rutaLogRed': txt_red.get().strip(),
                            'horasMaxMantenimiento': int(num_horas.get())})
            lbl_barra.config(text='Configuracion guardada')
        except Exception as ex:
            messagebox.showerror('Error', str(ex))

    def on_abrir_carpeta():
        """Boton 'Abrir carpeta de la herramienta': abre C:\\ProgramData\\UWF-Aulas en el explorador."""
        try:
            subprocess.Popen(['explorer.exe', Base])
        except Exception:
            pass

    btn_refrescar.config(command=refrescar)
    btn_instalar.config(command=on_instalar)
    btn_preparar.config(command=on_preparar)
    btn_add_programa.config(command=on_add_programa)
    btn_add_carpeta.config(command=on_add_carpeta)
    btn_add_archivo.config(command=on_add_archivo)
    btn_add_reg.config(command=on_add_reg)
    btn_quitar.config(command=on_quitar)
    btn_importar.config(command=on_importar)
    btn_exportar.config(command=on_exportar)
    btn_aplicar_ov.config(command=on_aplicar_ov)
    btn_aplicar_pend.config(command=on_aplicar_pendientes)
    btn_descartar_pend.config(command=on_descartar_pendientes)
    btn_iniciar_m.config(command=on_iniciar_m)
    btn_finalizar_m.config(command=on_finalizar_m)
    btn_guardar_cfg.config(command=on_guardar_cfg)
    btn_abrir_carpeta.config(command=on_abrir_carpeta)

    # Carga inicial
    cfg = leer_config()
    txt_red.insert(0, str(cfg.get('rutaLogRed', '')))
    _set_spin(num_horas, int(cfg['horasMaxMantenimiento']) if cfg.get('horasMaxMantenimiento') else 8)

    estado_actual = leer_estado()
    if estado_actual and estado_actual.get('fase') in ('mantenimiento', 'aplicando'):
        tabs.select(tab_mant)

    refrescar()
    form.mainloop()


# =============================================================================
#  Arranque
# =============================================================================

def _es_vigilante(argv):
    """True si los argumentos de linea de comandos piden el modo vigilante (sin interfaz)."""
    return any(a.lower() in ('--vigilante', '-vigilante', '/vigilante') for a in argv)


def _avisar(mensaje):
    """Muestra un aviso en una ventana emergente (o en consola si Tkinter no esta disponible)."""
    try:
        import tkinter as tk
        from tkinter import messagebox
        raiz = tk.Tk()
        raiz.withdraw()
        messagebox.showwarning('UWF Aulas', mensaje)
        raiz.destroy()
    except Exception:
        print(mensaje)


def main(argv=None):
    """Punto de entrada: modo vigilante si se pide por argumento, si no comprueba privilegios,
    hace la autoinstalacion (tarea programada + acceso directo) y muestra la GUI."""
    if argv is None:
        argv = sys.argv[1:]

    inicializar_carpeta()

    if _es_vigilante(argv):
        try:
            ejecutar_vigilante()
        except Exception as ex:
            escribir_log('Vigilante', 'ERROR', str(ex))
        return 0

    if not test_administrador():
        _avisar('Esta herramienta necesita ejecutarse como administrador.')
        return 0

    if not os.path.isfile(PerfilPath):
        guardar_perfil(get_perfil_predeterminado())

    try:
        instalar_vigilante()
        crear_acceso_directo()
    except Exception as ex:
        escribir_log('Autoinstalacion', 'ERROR', str(ex))
        # No basta con dejarlo en el log: si la copia de ProgramData se ha quedado en una
        # version anterior, el vigilante que corre al arrancar no conoce la fase 'aplicando'
        # y un equipo podria quedarse sin proteccion. El tecnico tiene que saberlo.
        _avisar(
            'No se ha podido actualizar la copia instalada en\n%s\n\n%s\n\n'
            'La herramienta se abrira igualmente, pero NO uses "Aplicar cambios y reiniciar" '
            'hasta resolverlo: el vigilante que arranca con el equipo seguiria siendo el '
            'anterior. Cierra la herramienta, espera unos segundos tras el arranque y vuelve '
            'a ejecutarla.' % (ScriptDest, ex)
        )

    mostrar_interfaz()
    return 0


if __name__ == '__main__':
    sys.exit(main())
