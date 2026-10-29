# Como funciona UWFManager

Este documento explica el funcionamiento interno de la herramienta: que piezas tiene, como
decide lo que hace en cada momento y que garantias da para que un equipo del aula no se
quede sin proteccion. Para una vista rapida de las funciones y de como compilar, ver el
[README](../README.md).

## Indice

1. [Idea general](#1-idea-general)
2. [Piezas](#2-piezas)
3. [Como lee y como actua sobre UWF](#3-como-lee-y-como-actua-sobre-uwf)
4. [Instalacion y actualizacion en cada equipo](#4-instalacion-y-actualizacion-en-cada-equipo)
5. [La cola de cambios pendientes](#5-la-cola-de-cambios-pendientes)
6. [Mantenimiento](#6-mantenimiento)
7. [Exclusiones](#7-exclusiones)
8. [Uso del disco (overlay)](#8-uso-del-disco-overlay)
9. [Perfiles](#9-perfiles)
10. [La interfaz, pestana a pestana](#10-la-interfaz-pestana-a-pestana)
11. [Ficheros que guarda en el equipo](#11-ficheros-que-guarda-en-el-equipo)
12. [Registro (log)](#12-registro-log)
13. [Garantias de seguridad](#13-garantias-de-seguridad)
14. [Diagnostico de problemas](#14-diagnostico-de-problemas)
15. [Limitaciones conocidas](#15-limitaciones-conocidas)

---

## 1. Idea general

El **Unified Write Filter (UWF)** de Windows redirige todas las escrituras en el disco
protegido a una zona temporal (el *overlay*) que se vacia al reiniciar. El equipo vuelve
siempre al mismo estado, pero eso tambien impide instalar actualizaciones o cambiar la
configuracion de forma permanente.

UWF trae un *servicing mode* para eso, pero es fragil y no cubre el software de terceros.
UWFManager lo sustituye por un flujo mas simple y manual:

- Para cambiar algo de forma permanente se **desactiva el filtro**, se reinicia, se trabaja
  y el tecnico lo **vuelve a activar** con un boton. Nada lo reactiva por su cuenta: no hay
  ningun proceso en segundo plano.
- Los cambios de configuracion de UWF (exclusiones y uso del disco) **no se aplican al
  momento**: se encolan y se aplican de una vez con un solo boton.

## 2. Piezas

```
+--------------------------+
|  Interfaz (tecnico)      |
|  UWFManager.exe          |
|  o UWF-Aulas.ps1         |
+------------+-------------+
             |  lee / escribe
             v
      +-------------------------------------------------------+
      |  C:\ProgramData\UWF-Aulas\                            |
      |  config.json  pendientes.json                         |
      |  perfil-exclusiones.json  uwf-aulas.log  copia de app |
      +-------------------------------------------------------+
             |
             v
      +-------------------------------------------------------+
      |  UWF:  WMI (leer)          uwfmgr.exe (actuar)        |
      +-------------------------------------------------------+
```

- **Dos implementaciones con el mismo comportamiento**:
  - `UWF-Aulas.ps1`: PowerShell 5.1 + Windows Forms. No necesita instalar nada.
  - `UWF-Aulas.py`: Python + Tkinter, que se compila a `UWFManager.exe`. No necesita
    Python en el equipo destino.

  Ambas leen y escriben los mismos ficheros con el mismo formato, de modo que una cola de
  pendientes creada con una la entiende la otra. Cualquier cambio de logica tiene que
  hacerse en las dos.
- **Interfaz**: la usa el tecnico. Se abre sin argumentos y exige ser administrador.
- **Carpeta de trabajo** `C:\ProgramData\UWF-Aulas\`: configuracion, cola y log (ver
  [seccion 11](#11-ficheros-que-guarda-en-el-equipo)). Esta carpeta no es una exclusion de
  UWF: lo que la herramienta escribe ahi con el filtro activo se lleva al disco real con
  `uwfmgr file commit` (o `commit-delete` si se borra). Sin eso, la cola y la configuracion
  se perderian en el siguiente reinicio.
- Las versiones anteriores tenian un *vigilante*: una tarea programada de arranque
  (`UWF-Aulas-Vigilante`) que reactivaba la proteccion sola. Se ha quitado porque, al no
  persistir sus ficheros de estado, reactivaba el filtro en cuanto arrancaba un
  mantenimiento. La version actual borra esa tarea si la encuentra (ver
  [seccion 4](#4-instalacion-y-actualizacion-en-cada-equipo)).

## 3. Como lee y como actua sobre UWF

| Para... | Se usa | Por que |
|---|---|---|
| Leer el estado (filtro, volumenes, overlay, exclusiones) | **WMI**, espacio `root\standardcimv2\embedded` (clases `UWF_Filter`, `UWF_Volume`, `UWF_OverlayConfig`, `UWF_Overlay`, `UWF_RegistryFilter`) | Da datos estructurados que no dependen del idioma de Windows. |
| Cambiar cosas (activar el filtro, anadir exclusiones, tamano...) | **`uwfmgr.exe`** | Es la herramienta oficial; se comprueba su codigo de salida. |
| Saber si la caracteristica UWF esta habilitada e instalarla | **`dism.exe`** con `/English` y, como respaldo, `Enable-WindowsOptionalFeature` | DISM no depende de PowerShell (que una politica puede restringir) y `/English` evita leer texto traducido. |

La salida de texto de `uwfmgr` solo se lee en dos casos de respaldo, cuando WMI no
responde: el consumo del overlay y la lista de exclusiones. En ambos se buscan numeros o
rutas, nunca frases, para no depender del idioma.

"UWF instalado" significa que existe `C:\Windows\System32\uwfmgr.exe`. En Windows Pro o
Home no existe, y casi todas las funciones avisan de que no se pueden usar.

## 4. Instalacion y actualizacion en cada equipo

Cada vez que se abre la interfaz (como administrador):

1. Si no existe `perfil-exclusiones.json`, se crea con el **perfil por defecto** definido en
   el codigo.
2. Se compara por **hash SHA-256** la copia instalada en `C:\ProgramData\UWF-Aulas\` con la
   que se esta ejecutando. Si son distintas, se sustituye. Como Windows no deja sobrescribir
   un ejecutable en uso, si copiar encima falla se renombra la copia en uso a
   `.old-<fecha>` y se copia la nueva al lado. Los `.old-*` se borran en la siguiente
   ejecucion. Con el filtro activo, la copia nueva se lleva al disco real con
   `uwfmgr file commit`.
3. Se borra la tarea `UWF-Aulas-Vigilante` de versiones anteriores, si existe, y el
   `estado.json` que usaba.
4. Se crea el acceso directo `UWF Aulas.lnk` en el escritorio publico.

Si no se puede sustituir la copia instalada, la interfaz **lo avisa**: el acceso directo
seguiria abriendo la version anterior.

### Equipos con una version anterior (con vigilante)

Con el filtro activo, borrar la tarea no es definitivo: el registro de tareas tambien esta
protegido y la tarea reaparece al reiniciar. No pasa nada, porque la tarea lanza la copia
instalada, que ya es la version nueva, y esta la vuelve a borrar sin tocar el filtro. En el
primer arranque sin proteccion (al iniciar un mantenimiento) el borrado queda definitivo.

Por eso, **actualizar un equipo es solo ejecutar la version nueva una vez**.

### Primera puesta en marcha de un equipo

1. **Instalar caracteristica UWF** (pestana Estado). Habilita `Client-UnifiedWriteFilter`
   con DISM y pide reiniciar. Si la edicion de Windows no incluye UWF, lo dice claramente.
   El resultado se comprueba releyendo el estado, no fiandose solo del codigo de salida, y
   queda siempre en el log, tambien si falla.
2. **Preparar equipo** (pestana Estado). Protege el volumen `C:`, aplica el perfil de
   exclusiones guardado y activa el filtro. Si `uwfmgr` falla al proteger `C:` o al activar
   el filtro, se muestra el error y no se da el equipo por preparado.

## 5. La cola de cambios pendientes

Todo lo que el tecnico configura en las pestanas **Exclusiones** y **Uso del disco** se
guarda en `pendientes.json` y **no llega a UWF hasta pulsar "Aplicar cambios y reiniciar"**
en la barra inferior, visible desde cualquier pestana.

Motivos:

- Se puede preparar todo, revisarlo y aplicarlo con un solo reinicio.
- La cola se ve aunque UWF todavia no este instalado en el equipo.
- Nada se queda a medias: lo que no se puede aplicar en ese momento sigue en la cola, y la
  cola sobrevive a los reinicios aunque el filtro este activo.

Reglas de la cola:

- **Se valida al encolar**, no al aplicar. Una ruta prohibida, una clave fuera de `HKLM` o
  unos umbrales incoherentes se rechazan en el momento en que el tecnico los elige.
- Las rutas y claves se comparan **sin distinguir mayusculas**, igual que Windows.
- **Encolar lo contrario anula**: si hay un "anadir X" pendiente y se pide "quitar X", los
  dos desaparecen y el equipo se queda como estaba.
- **Descartar** vacia la cola sin tocar el equipo.
- Si `pendientes.json` esta corrupto, se ignora en vez de bloquear la interfaz.

### Que pasa al pulsar "Aplicar cambios y reiniciar"

```
Hay que cambiar el tipo o el tamano del uso del disco con el filtro activo?
 |
 +-- NO --> se aplican exclusiones y umbrales
 |          --> se pregunta si reiniciar
 |
 +-- SI --> se aplican exclusiones y umbrales
            --> el tipo y el tamano se quedan en la cola
            --> se aplican al pulsar "3 - Finalizar, proteger y reiniciar"
                durante un mantenimiento
```

Lo que UWF permite cambiar en cada situacion:

| Cambio | Con el filtro activo | Con el filtro desactivado |
|---|---|---|
| Anadir o quitar exclusiones | Si (surte efecto al reiniciar) | Si |
| Umbrales de aviso y critico | Si | Si |
| Tipo (RAM/Disco) y tamano del uso del disco | **No** | Si |

Si un cambio falla al aplicarse (por ejemplo, `uwfmgr` devuelve error), **se queda en la
cola** y el error se muestra y se registra.

## 6. Mantenimiento

El mantenimiento lo abre y lo cierra el tecnico. No hay fases guardadas ni nada que actue
en el arranque: el estado se deduce del filtro, que se lee por WMI.

1. **1 - Iniciar mantenimiento y reiniciar** (solo con el filtro activo): desactiva el
   filtro para el siguiente arranque y reinicia.
2. El equipo arranca sin proteccion. Todo lo que se haga se guarda de forma permanente.
3. **3 - Finalizar, proteger y reiniciar** (solo con el filtro desactivado): aplica la cola
   de pendientes (con el filtro desactivado se puede todo, tambien el tipo y el tamano del
   uso del disco), reactiva el filtro y reinicia. Si hay cambios en la cola, antes pide
   confirmacion mostrandolos. Si alguno falla, **se reactiva la proteccion igualmente**, se
   muestra el error y el cambio sigue en la cola.

**La proteccion no vuelve sola.** Si el tecnico no pulsa *Finalizar*, el equipo sigue sin
proteger en todos los arranques. Para que no pase desapercibido, la interfaz se abre
directamente en la pestana Mantenimiento y con el banner en rojo mientras el filtro este
desactivado.

## 7. Exclusiones

Una exclusion es una carpeta, archivo o clave de registro que **no se protege**: lo que se
escribe ahi se conserva tras reiniciar. Sirve para lo que debe sobrevivir, como las firmas
del antivirus o la configuracion de un agente de gestion. Todo lo excluido queda expuesto
de una sesion a otra, asi que hay que **excluir lo minimo**.

### Lo que se ve en la pestana

Encima de la lista aparece un resumen con el numero de carpetas/archivos y claves que el
equipo tiene permitidas. La lista combina la cola y lo que ya esta en UWF, con este estado
en cada fila:

| Estado | Significado |
|---|---|
| `PENDIENTE: anadir` / `PENDIENTE: quitar` | En la cola, todavia sin aplicar. |
| `Permitida` | Excluida ahora y tambien despues de reiniciar. |
| `Permitida tras reiniciar` | Se anadio con el filtro activo: **aun no funciona**; funcionara tras reiniciar. |
| `Se quita al reiniciar` | Sigue funcionando en esta sesion, pero ya esta retirada. |

La columna **Existe** avisa si la ruta o la clave no existe en el equipo, que suele indicar
una exclusion obsoleta o mal escrita.

UWF guarda por separado las exclusiones de la sesion actual y las de la siguiente. La
herramienta las lee por WMI y las cruza para obtener esos estados. Si WMI no responde,
recurre a `uwfmgr` y, como entonces no puede distinguir las sesiones, las muestra todas como
`Permitida`.

### Reglas

- **Rutas prohibidas**: nunca se excluyen `C:\Windows\SoftwareDistribution`,
  `C:\Windows\WinSxS`, `C:\Windows\servicing`, `C:\$WINDOWS.~BT` ni
  `C:\Windows\System32\catroot2`, ni nada dentro de ellas. Excluirlas rompe Windows Update.
  La comprobacion se hace al encolar y otra vez al aplicar, venga la ruta de donde venga
  (a mano, por programa o desde un perfil).
- **Registro**: UWF solo admite claves bajo `HKLM`. Se aceptan las formas
  `HKLM\...`, `HKLM:\...` y `HKEY_LOCAL_MACHINE\...`, y se guardan como `HKLM\...`.

### Anadir por programa

El dialogo lista los programas instalados (leidos de las claves `Uninstall` del registro,
de 64 y 32 bits) y propone que excluir para el elegido:

1. **Catalogo**: si el programa casa con una entrada del catalogo (definido al principio de
   cada implementacion, por tipo de software: antivirus y su agente, gestor de login, el
   antivirus de Windows...), se proponen sus carpetas y claves, **solo las que existen** en
   el equipo, y aparecen **ya marcadas**.
2. **Heuristica**: si no esta en el catalogo, se buscan carpetas en `C:\ProgramData` y
   claves en `HKLM\SOFTWARE` (y `WOW6432Node`) cuyo nombre contenga palabras del nombre del
   programa o del fabricante. Para que no proponga medio sistema:
   - solo se usan palabras de 4 letras o mas;
   - se descartan palabras genericas ("Microsoft", "Windows", "Corporation", "Update",
     "Software"...);
   - nunca se proponen raices del sistema como `C:\ProgramData\Microsoft`,
     `HKLM\SOFTWARE\Microsoft`, `HKLM\SOFTWARE\Classes` o `HKLM\SOFTWARE\Policies`;
   - las propuestas aparecen **sin marcar**: el tecnico elige a conciencia.

Lo aceptado se encola como pendiente, igual que lo anadido a mano.

## 8. Uso del disco (overlay)

En la interfaz se llama "uso del disco" para que se entienda sin conocer UWF. Por dentro
(WMI, `uwfmgr` y los perfiles JSON) conserva el nombre de UWF: *overlay*.

- **Tipo**: `Disco` (reserva espacio en `C:`; recomendado, no resta memoria) o `RAM` (mas
  rapido, pero consume memoria segun se llena).
- **Tamano**: el tecnico lo elige en **GB enteros** (de 2 a 512; por defecto 32). El
  programa lo multiplica por 1024 para pasarselo a UWF, que trabaja en MB.
- **Umbrales**: **se calculan solos** a partir del tamano; el tecnico no los escribe. UWF
  avisa al llegar al de **aviso** y entra en estado critico al llegar al **critico**. Los
  dos miden **cuanto se ha llenado** el espacio reservado, no cuanto queda libre, asi que el
  aviso es el menor de los dos: salta primero y da tiempo a reaccionar antes del critico.
  UWF exige:

  ```
  0 < aviso < critico <= tamano
  ```

  Esta regla se valida al encolar, al guardar un perfil y al leer la cola. Tenerlos
  invertidos fue un fallo real en una version anterior.

Criterio de los umbrales automaticos (`umbrales_automaticos` / `Get-UmbralesAutomaticos`):

- **critico** = 90 % del tamano, pero dejando siempre al menos **1 GB** hasta llenarse;
- **aviso** = 75 % del tamano; si con tamanos pequenos quedara igual o por encima del
  critico, se baja en la misma proporcion (75/90 del critico).

| Tamano | Aviso | Critico | Margen hasta llenarse |
|---|---|---|---|
| 4 GB | 2,5 GB (62 %) | 3 GB (75 %) | 1 GB |
| 8 GB | 6 GB (75 %) | 7 GB (88 %) | 1 GB |
| 16 GB | 12 GB (75 %) | 14,4 GB (90 %) | 1,6 GB |
| **32 GB** (habitual) | **24 GB (75 %)** | **28,8 GB (90 %)** | **3,2 GB** |
| 64 GB | 48 GB (75 %) | 57,6 GB (90 %) | 6,4 GB |

En la pestana se muestran como porcentaje de llenado y en GB. Si la cola trae otros
umbrales (por ejemplo, de un perfil importado), se muestran esos y se respetan; al volver a
pulsar *Anadir a los cambios pendientes* se sustituyen por los automaticos.

Antes de encolar se comprueba si el tamano cabe en el equipo, y si no se pide confirmacion
(no se bloquea, porque la cola puede estar preparandose para otro momento):

- con `Disco`, si `C:` tiene menos espacio libre que el tamano elegido;
- con `RAM`, si el tamano supera la mitad de la memoria del equipo.

La configuracion por defecto (y la del perfil por defecto) es Disco, 32 GB, aviso 24 GB y
critico 28,8 GB.

## 9. Perfiles

Un perfil es un JSON con un conjunto de exclusiones y, opcionalmente, la configuracion del
uso del disco:

```json
{
  "nombre": "Aulas - base",
  "version": "2026-10-28",
  "archivos": ["C:\\ProgramData\\Ejemplo"],
  "registro": ["HKLM\\SOFTWARE\\Ejemplo"],
  "overlay": { "tipo": "Disco", "tamanoMB": 32768, "avisoMB": 24576, "criticoMB": 29491 }
}
```

En los perfiles y en `pendientes.json` los tamanos siguen en MB, que es lo que usa UWF.

- **Perfil activo**: `C:\ProgramData\UWF-Aulas\perfil-exclusiones.json`. Lo usa
  "Preparar equipo".
- **Importar perfil**: valida los umbrales (si no cuadran, rechaza el perfil entero), lo
  guarda como perfil activo y **encola** todo su contenido como pendiente para revisarlo
  antes de aplicarlo.
- **Exportar perfil**: guarda en un JSON las exclusiones que el equipo tiene en UWF y la
  configuracion del uso del disco. Si no se ha podido leer esa configuracion completa, el
  perfil se exporta sin el apartado `overlay`.

Los perfiles propios de cada centro (con nombres de programas y rutas reales) no se suben
al repositorio: el `.gitignore` excluye `*.local.json`.

## 10. La interfaz, pestana a pestana

El **banner superior** resume el estado:

- **Verde** "PROTECCION ACTIVA": el filtro esta activo.
- **Naranja** "PROTECCION DESACTIVADA - se reactivara al reiniciar": ya se ha pulsado
  *Finalizar* y falta el reinicio.
- **Rojo** "MANTENIMIENTO EN CURSO": el filtro esta desactivado y seguira asi hasta pulsar
  *Finalizar*.
- **Naranja** "UWF NO ESTA INSTALADO": la caracteristica no esta en el equipo.

La **barra de cambios pendientes**, abajo, muestra lo que hay en la cola y los botones
**Aplicar cambios y reiniciar** y **Descartar**.

| Pestana | Que tiene |
|---|---|
| **Estado** | Resumen: caracteristica UWF, filtro ahora y tras reiniciar, volumenes protegidos, uso del disco y su consumo (con barra), si hay un mantenimiento en curso y numero de pendientes. Botones *Instalar caracteristica UWF* (solo si no esta), *Preparar equipo* y *Actualizar estado*. |
| **Exclusiones** | Resumen de lo permitido, lista de exclusiones y pendientes (ver [seccion 7](#7-exclusiones)). Botones *Anadir por programa*, *Carpeta*, *Archivo*, *Clave HKLM*, *Quitar*, *Importar perfil* y *Exportar perfil*. *Quitar* sobre un pendiente lo saca de la cola y sobre una exclusion permitida encola su retirada. |
| **Uso del disco** | Tipo, tamano en GB y, debajo, los umbrales calculados (en % de llenado y en GB), y el boton *Anadir a los cambios pendientes*. Si hay un cambio encolado se muestran los valores pendientes, marcados como tales. |
| **Mantenimiento** | Explicacion del flujo, botones *1 - Iniciar mantenimiento y reiniciar* (solo con el filtro activo) y *3 - Finalizar, proteger y reiniciar* (solo con el filtro desactivado), y las ultimas 40 lineas del log. Si el filtro esta desactivado, la interfaz se abre directamente en esta pestana. |
| **Configuracion** | Ruta de red para el log centralizado y boton para abrir la carpeta de la herramienta. |

## 11. Ficheros que guarda en el equipo

Todos en `C:\ProgramData\UWF-Aulas\`. Con el filtro activo, la herramienta los lleva al
disco real con `uwfmgr file commit` al escribirlos (salvo el log):

| Fichero | Contenido |
|---|---|
| `config.json` | `rutaLogRed` (carpeta de red del log centralizado, opcional). Las versiones anteriores guardaban tambien `horasMaxMantenimiento`; ahora se ignora. |
| `pendientes.json` | Cola de cambios: `exclusiones` (lista de `{tipo: archivo|registro, accion: add|remove, valor}`) y `disco` (`{tipo, tamanoMB, avisoMB, criticoMB}` o `null`), mas `version`, `actualizado`, `tecnico` y `equipo`. Se borra cuando la cola queda vacia. |
| `perfil-exclusiones.json` | Perfil activo (ver [seccion 9](#9-perfiles)). |
| `uwf-aulas.log` | Registro local (ver [seccion 12](#12-registro-log)). |
| `UWF-Aulas.exe` o `UWF-Aulas.ps1` | Copia instalada, a la que apunta el acceso directo. |

## 12. Registro (log)

Cada accion relevante anade una linea CSV separada por `;` con seis columnas:

```
fecha;equipo;usuario;accion;resultado;detalle
2026-10-28 09:15:02;AULA1-PC07;tecnico;FinalizarMantenimiento;OK;filtro activado, pendiente de reinicio
```

- `resultado` es uno de `OK`, `PARCIAL`, `ERROR`, `AVISO` o `INFO`.
- El `detalle` nunca debe contener `;`: la herramienta los sustituye en los textos que
  vienen de programas externos (DISM, `uwfmgr`) para no descuadrar las columnas.
- Las lineas escritas con el filtro activo se pierden al reiniciar: el log local no se
  lleva al disco real en cada escritura. El log de red si las conserva.
- Si en Configuracion hay una ruta de red, cada linea se anade tambien a
  `<ruta>\uwf-aulas-AAAA-MM.csv`, un fichero por mes con los registros de todos los equipos.
  Si la red no esta disponible, se ignora sin afectar al resto.

Acciones mas habituales: `InstalarCaracteristica`, `PrepararEquipo`, `EncolarExclusion`,
`EncolarUsoDisco`, `AplicarPendientes`, `IniciarMantenimiento`, `FinalizarMantenimiento`,
`Reinicio`, `ActualizarInstalacion`, `EliminarTareaAntigua`, `PersistirFichero` y
`Autoinstalacion`.

## 13. Garantias de seguridad

Lo que el codigo cuida para no dejar un equipo del aula roto o desprotegido:

1. **El equipo no se queda sin proteccion en silencio.** Mientras el filtro esta
   desactivado, el banner es rojo y la interfaz se abre en la pestana Mantenimiento.
   Reactivarlo es decision del tecnico: nada lo hace por su cuenta.
2. **La cola no se pierde al reiniciar.** Lo que la herramienta escribe con el filtro
   activo se lleva al disco real con `uwfmgr file commit`.
3. **Windows Update no se rompe.** Las rutas que necesita no se pueden excluir por ninguna
   via.
4. **Los umbrales siempre son coherentes.** Se valida `aviso < critico <= tamano` en todas
   las entradas.
5. **No se cambia el tipo ni el tamano con el filtro activo.** Esos cambios se quedan en la
   cola y se aplican al finalizar un mantenimiento.
6. **Los fallos de `uwfmgr` no se esconden.** Las acciones comprueban su codigo de salida;
   un cambio que falla sigue en la cola y queda en el log.
7. **La reactivacion no depende de la cola.** Si un pendiente falla al finalizar, la
   proteccion se reactiva igualmente.

## 14. Diagnostico de problemas

| Sintoma | Donde mirar / que hacer |
|---|---|
| "Esta edicion de Windows no incluye el Unified Write Filter" | UWF solo existe en Windows 10/11 Enterprise, Education e IoT Enterprise. Comprobar con `winver`. |
| No se puede instalar la caracteristica | El log (`InstalarCaracteristica;ERROR`) guarda el codigo y la salida de DISM y de PowerShell. Los codigos 0 y 3010 significan exito (3010: pide reinicio). |
| Una exclusion aparece como "Permitida tras reiniciar" | Es normal si se anadio con el filtro activo: funcionara tras el siguiente reinicio. |
| Una fila dice "NO EXISTE - revisar" | La ruta o clave no esta en el equipo: exclusion obsoleta o mal escrita. Se puede retirar con *Quitar*. |
| Un cambio pendiente no desaparece de la cola | `uwfmgr` lo rechazo. El motivo esta en el aviso al aplicar y en el log (`AddExclusion...;ERROR`). |
| El banner esta en rojo sin que nadie haya iniciado un mantenimiento | Alguien desactivo el filtro fuera de la herramienta, o no se cerro un mantenimiento. Pulsar *3 - Finalizar, proteger y reiniciar*. |
| La cola o la configuracion desaparecen tras reiniciar | `uwfmgr file commit` ha fallado. El motivo esta en el log de red (`PersistirFichero;ERROR`). |
| Aviso "No se ha podido actualizar la copia instalada" | Otra ventana de la herramienta tenia la copia en uso. Cerrarlas todas y volver a abrir la version nueva. |
| El estado no muestra el consumo del uso del disco | WMI no lo ha devuelto y tampoco se ha podido leer de `uwfmgr`. No afecta a la proteccion. |

## 15. Limitaciones conocidas

- **Solo `C:`**: la herramienta protege y lista exclusiones solo del volumen `C:`.
- **Permisos de la carpeta de trabajo**: `C:\ProgramData\UWF-Aulas\` hereda los permisos
  por defecto de `ProgramData`, que dejan crear ficheros a cualquier usuario. Un
  `pendientes.json` plantado se aplicaria al pulsar *Aplicar* o *Finalizar* (el tecnico lo
  ve antes en la lista). Endurecer esos permisos esta pendiente.
- **Respaldo por texto**: si WMI no responde, el consumo del overlay y la lista de
  exclusiones se leen de la salida de `uwfmgr`; en ese caso no se distingue entre la sesion
  actual y la siguiente.
- **No probado aqui con UWF real**: el equipo de desarrollo es Windows Pro, donde UWF no
  existe. Lo que no toca UWF (cola, perfiles, umbrales, log, flujo de
  mantenimiento con UWF simulado, interfaz) se prueba en desarrollo; la lectura y escritura real de UWF hay que validarla
  en un equipo Enterprise o Education.
