# UWF Aulas — contexto del proyecto para Claude Code

Documento de traspaso. Recoge la conversación que dio origen a la herramienta, el estado actual del código y las mejoras pendientes. Pensado para pegarlo (o adjuntarlo) al abrir el proyecto en Claude Code y seguir desde ahí sin perder contexto.

---

## 1. Contexto operativo

**Quién**: equipo de IT de Pulsia Technology dando servicio a la Universitat de València. IT Team Leader (Jose) coordina 7 técnicos repartidos entre campus.

**Dónde se despliega**: aulas de la Universitat. Windows 10 y 11 **Enterprise**.

**Cómo se autentica hoy**: cada equipo usa **pGina** contra el LDAP de la UV. Tras autenticarse, todos los profesores caen en un mismo usuario local llamado **`Profesor`**.

**Restricciones que no se tocan**:
- pGina debe seguir funcionando tal cual está. No se puede borrar/recrear la cuenta `Profesor` ni cambiar el flujo de login.
- Las actualizaciones se aplican **manualmente, equipo a equipo** (no hay WSUS ni Intune desplegado para estas aulas).
- Antivirus: **Kaspersky**.
- Los técnicos van físicamente al aula. La herramienta tiene que servirles allí, no ser un panel remoto.

**Problema original**: los profesores dejan basura en el perfil `Profesor` (escritorio, descargas, sesiones abiertas, credenciales guardadas en navegadores). Cada mes hay que ir aula por aula a limpiar manualmente. Además hay riesgo de fuga entre profesores: sesiones de Outlook o Teams abiertas, exámenes en `Documentos`.

**Solución elegida**: **UWF (Unified Write Filter)** — ya se usa en algunos equipos. El punto de dolor no es UWF en sí, sino su *servicing mode* nativo, que solo cubre Windows Update y falla con software de terceros. Decisión: **sustituir servicing mode por una ventana de mantenimiento controlada** (desactivar filtro → reiniciar → actualizar → reactivar filtro → reiniciar), envuelta en una GUI que impida errores humanos.

---

## 2. Evolución de la conversación (para entender por qué el código es como es)

Se descartaron por el camino, y conviene saberlo antes de proponer alternativas:

1. **Script `.bat` al apagar** para limpiar escritorio/descargas/temporales y sustituir accesos directos por versiones en modo privado. Descartado como solución completa: solo trata síntomas, no evita que el siguiente profesor herede sesiones abiertas o credenciales.
2. **Perfil dorado con `robocopy /MIR`** al arrancar. Sigue siendo válido para aulas Pro (sin UWF), pero para Enterprise se prefiere UWF por su nivel de garantía.
3. **UWF con servicing mode**: rechazado por el propio equipo — el servicing mode es la parte frágil de UWF y no cubre Kaspersky. De ahí nace la herramienta actual.

---

## 3. Arquitectura del proyecto actual

**Dos archivos**, distribuidos por USB, van juntos en la misma carpeta:

- `UWF-Aulas.bat` — lanzador. Verifica que el `.ps1` está al lado, pide elevación si no la tiene y arranca la GUI.
- `UWF-Aulas.ps1` — todo lo demás. Se autocopia a `C:\ProgramData\UWF-Aulas\` la primera vez que se ejecuta en un equipo.

**Persistencia en el equipo** (en `C:\ProgramData\UWF-Aulas\`):
- `UWF-Aulas.ps1` — copia local.
- `config.json` — ruta de red del log central, horas máx de mantenimiento.
- `estado.json` — fase actual (`mantenimiento` / `verificando` / ausente).
- `perfil-exclusiones.json` — exclusiones + config de overlay del centro.
- `uwf-aulas.log` — CSV local; se replica al recurso de red si está configurado.

**Modos de ejecución**:
- Sin argumentos → GUI Windows Forms (requiere admin).
- `-Vigilante` → sin interfaz. Lo lanza una tarea programada al arranque, bajo SYSTEM.

**Tarea programada `UWF-Aulas-Vigilante`**: registrada la primera vez que se ejecuta la GUI, dispara al inicio del sistema y ejecuta el script en modo vigilante.

**Acceso directo `UWF Aulas.lnk`** en el escritorio público, creado en la autoinstalación.

---

## 4. Piezas del script (funciones clave)

### Estado y comunicación con UWF

- `Get-EstadoUwf` — lee todo el estado por WMI (`root\standardcimv2\embedded`: `UWF_Filter`, `UWF_Volume`, `UWF_OverlayConfig`, `UWF_Overlay`). Fallback a `uwfmgr overlay get-consumption` para el consumo si WMI no lo da.
- `Invoke-Uwf` — wrapper de `uwfmgr.exe`. Devuelve objeto con código, salida y `Ok`.
- **Importante**: no se parsea texto de `uwfmgr` (cambia con el idioma del sistema). Todo el estado va por WMI.

### Overlay

- `Test-UmbralesValidos` — regla `aviso < crítico ≤ tamaño`. Ambos umbrales miden **consumo acumulado**, no espacio libre. Un fallo temprano fue tenerlos invertidos.
- `Aplicar-Overlay` — aplica tipo (RAM/Disco), tamaño y umbrales. **Restricción de UWF**: tipo y tamaño solo se pueden cambiar con el filtro desactivado (durante un mantenimiento). Los umbrales, en cualquier momento. La función devuelve la lista de errores/pendientes en lugar de fallar, para que la GUI pueda mostrar "se aplicó X, quedó pendiente Y".

### Exclusiones

- `Get-ExclusionesArchivo`, `Get-ExclusionesRegistro` — leen las exclusiones actuales.
- `Add-/Remove-ExclusionArchivo`, `Add-/Remove-ExclusionRegistro` — con validación de HKLM y bloqueo de rutas prohibidas.
- `Test-ExclusionPeligrosa` — rechaza rutas que romperían Windows Update: `SoftwareDistribution`, `WinSxS`, `servicing`, `$WINDOWS.~BT`, `catroot2`.
- **Exclusiones por programa** (la característica de v2):
  - `$script:Catalogo` — array al principio del script. Cada entrada tiene `Patron` (regex contra `DisplayName`), `Carpetas` (patrones glob) y `Claves` (HKLM). Programas cubiertos hoy: Kaspersky, pGina, Defender, ESET, Sophos.
  - `Get-ProgramasInstalados` — lee `HKLM\...\Uninstall` en 64 y 32 bits.
  - `Resolver-Glob` — expande patrones tipo `C:\ProgramData\Kaspersky*` a rutas reales que existan en el equipo.
  - `Get-PropuestasExclusion` — dos niveles. Nivel 1: catálogo curado (solo devuelve rutas que existan). Nivel 2 (heurística, para programas fuera del catálogo): busca en `C:\ProgramData` y en `HKLM\SOFTWARE(\WOW6432Node)` por términos del nombre del programa y del fabricante (mínimo 4 caracteres para evitar coincidencias basura).
  - `Mostrar-DialogoPrograma` — combo con programas instalados + `CheckedListBox` con las propuestas etiquetadas (`CARPETA` / `REGISTRO`). El diálogo indica el origen (catálogo verificado vs heurística que hay que revisar).

### Mantenimiento

- `Iniciar-Mantenimiento` — `filter disable` + `Guardar-Estado 'mantenimiento'`.
- `Finalizar-Mantenimiento` — `filter enable` + `Guardar-Estado 'verificando'`.
- `Reiniciar-Equipo` — `shutdown /r /t 10`.

### Vigilante (`Ejecutar-Vigilante`)

Lógica en cada arranque:
- Sin estado guardado → si el filtro no está activo, log de aviso.
- `fase = 'verificando'` → si el filtro está activo, cerrar la fase. Si no, `filter enable` + reinicio.
- `fase = 'mantenimiento'` → si han pasado más horas que `horasMaxMantenimiento` (por defecto 8), reactivar filtro por su cuenta y reiniciar. Si no, solo dejar constancia en el log.

Es la red de seguridad para "el técnico se olvidó de cerrar el mantenimiento".

### Perfiles

- `Get-PerfilPredeterminado` — Kaspersky por defecto, overlay 4096 MB en Disco, aviso 2560, crítico 3584.
- `Guardar-Perfil` — valida umbrales antes de escribir. Los perfiles con umbrales inválidos se rechazan al importar.
- `Aplicar-Perfil` — recibe también `FiltroActivo` para poder decidir si intenta cambiar tipo/tamaño del overlay o solo umbrales.

---

## 5. Decisiones importantes ya tomadas

- **Overlay: por defecto en Disco, 4 GB**. La RAM en aulas suele ser 8 GB — reservar 4 GB en RAM asfixia el equipo. En disco, el impacto de velocidad es irrelevante para el uso de aula.
- **Idioma del código**: español sin acentos (el script se distribuye por USB y hay Windows con juegos de caracteres viejos; los mensajes usan `Segoe UI` y hay algunos acentos, pero los identificadores y logs son ASCII).
- **Codificación al distribuir**: `.ps1` como UTF-8 **con BOM** (PowerShell 5.1 lo requiere para acentos), `.bat` como ASCII. Ambos con CRLF.
- **Nunca se excluyen** `SoftwareDistribution`, `WinSxS`, `servicing`, `$WINDOWS.~BT`, `catroot2` — bloqueado en código.
- **La GUI no oculta la restricción de UWF sobre tipo/tamaño**: la muestra en cada refresco de la pestaña Overlay.
- **Logs**: locales siempre en `C:\ProgramData\UWF-Aulas\uwf-aulas.log` (CSV con `;`), y replicados a la ruta de red si está configurada. Nombre del fichero de red: `uwf-aulas-YYYY-MM.csv`.

---

## 6. Cosas que se validan cuando la herramienta llegue a un aula real

Estas son hipótesis, no verificaciones hechas:

1. **Rutas por defecto de Kaspersky**. El perfil predeterminado usa `C:\ProgramData\KasperskyLab` y `HKLM\SOFTWARE\WOW6432Node\KasperskyLab`. Kaspersky Endpoint Security y el Agente de Red cambian rutas entre versiones. Instalarlo en un equipo real y ajustar el catálogo con las rutas efectivas.
2. **Duplicados de host en Kaspersky Security Center**. Si el ID del Agente de Red se regenera en cada reinicio porque su almacén está bajo el overlay, aparecen cientos de equipos fantasma en la consola. Kaspersky tiene guía para entornos no persistentes (VDI) que aplica aquí. Dejar un equipo con UWF activo dos días y comprobar la consola antes de desplegar.
3. **OneDrive y KFM**. Si el escritorio o descargas están sincronizados por Known Folder Move con una cuenta institucional, hay que ver cómo interactúa con UWF. Descartar equipos con KFM activo hasta entenderlo.
4. **Inicio rápido (`HiberbootEnabled`)**. Ver si hace falta desactivarlo para que el vigilante corra siempre — con UWF el reinicio es explícito y no debería ser problema, pero conviene comprobar.

---

## 7. Mejoras pendientes (por orden de utilidad)

1. **Inventario central en CSV/base de datos**. El vigilante escribiría en el log de red **una línea de estado por equipo en cada arranque**: protegido sí/no, versión del perfil, timestamp del último mantenimiento correcto. Con eso se ve en Excel el estado de las N aulas de un vistazo. Es el paso previo a la 2.
2. **Mantenimiento desatendido**. Modo "mantenimiento programado": tarea nocturna (3-6 AM) que abre mantenimiento, ejecuta un script de parcheo, cierra y verifica. Wake-on-LAN para arrancar equipos apagados. Convierte las visitas mensuales en excepción. Es la mejora con más retorno, y también la que más pruebas necesita.
3. **Firma del script + AllSigned**. Hoy corre con `-ExecutionPolicy Bypass` y la tarea SYSTEM apunta a un `.ps1` en `ProgramData` con ACL laxa. Firmar con certificado interno de la UV y endurecer la ACL cierra la ruta de escalada.
4. **Aviso al llenarse el overlay**. UWF emite eventos en los umbrales; escuchar y avisar al profesor ("guarda tu trabajo, el equipo se reiniciará en 10 min") en lugar de degradarse en silencio.
5. **Verificación del perfil tras cada mantenimiento**. El vigilante compara exclusiones activas con el perfil y marca en el log las que dejaron de existir. Las actualizaciones grandes de Kaspersky cambian rutas y hoy solo se detecta abriendo la GUI.
6. **Catálogo más amplio**. Ahora cubre Kaspersky, pGina, Defender, ESET, Sophos. Añadir al catálogo lo que se use en aulas: Adobe Reader, Java, navegadores, herramientas específicas de facultad. Es un array de cinco líneas por entrada.
7. **Modo "comprobar"**. Un argumento CLI que imprima estado en JSON y salga con código 0/1. Útil para integrarlo con lo que sea que monitorice los equipos.

---

## 8. Cómo retomar en Claude Code

Al abrir el proyecto:

- El script principal es `UWF-Aulas.ps1`. Un solo fichero, ~900 líneas. Está dividido por regiones con comentarios `# =====` — respetar la estructura al añadir cosas.
- Las funciones de UWF hablan por WMI + `uwfmgr`. Preferir WMI para leer, `uwfmgr` para actuar.
- La GUI está toda en `Mostrar-Interfaz`. Cinco pestañas: Estado, Exclusiones, Overlay, Mantenimiento, Configuración. Al añadir controles nuevos, usar el mismo patrón de `Anchor` para que la ventana escale.
- El diálogo de exclusiones por programa es `Mostrar-DialogoPrograma`.
- Para probar en local **hace falta Windows con la característica UWF disponible** (Windows 10/11 Enterprise o Education). En cualquier otro sistema, `uwfmgr.exe` no existe y la mayoría de funciones fallan por diseño.
- Convención de logs: usar `Escribir-Log 'Accion' 'Resultado' 'detalle'`. Nada de `Write-Host` fuera de la GUI.
- Los perfiles se validan al guardar (`Guardar-Perfil`), no al aplicar. Cualquier campo nuevo del perfil debe validarse ahí también.

**Primera tarea sugerida** al retomar: mejora 1 (inventario central), porque desbloquea decisiones de dimensionamiento para la 2 y no requiere firmar nada.
