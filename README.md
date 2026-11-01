# ElvisLab

Utilidad gráfica para Windows inspirada en el flujo de trabajo de [WinUtil](https://christitus.com/win):
seleccionar programas, instalarlos, aplicar ajustes del sistema, actualizar y desinstalar con winget,
crear accesos directos y revisar un registro de actividad.

La interfaz imita el estilo de WinUtil: tema oscuro, pestañas, panel lateral de acciones, tarjetas por
categoría, búsqueda y barra de progreso.

---

## Qué hace

- **Instalar** los programas definidos en `config.json`.
  - Motor **Directo**: descarga el instalador oficial, verifica **SHA256** y/o **firma digital** y lo ejecuta en modo silencioso.
  - Motor **Winget**: instala o actualiza desde el catálogo de Windows Package Manager.
- **Aplicar ajustes** del sistema de forma independiente (sin instalar programas), con punto de restauración primero.
- **Deshacer ajustes** reversibles (por ejemplo, eliminar la política de telemetría).
- **Actualizar** los programas gestionados con winget.
- **Desinstalar** programas con winget (solo los que winget reconozca).
- **Crear accesos directos** en el Escritorio o menú Inicio, apuntando al programa realmente instalado.
- **Herramientas**: panel de control clásico, conexiones de red, sonido, impresoras, programas y características,
  reset de red, reparación de winget, limpieza de temporales y escaneo SFC + DISM.
- **Red**: cambia el DNS de todos los adaptadores físicos activos (Google, Cloudflare, Quad9, AdGuard o DHCP).
- **Energía**: activa o elimina el plan **Ultimate Performance**.
- **Registro** en pantalla y en archivo, con progreso por programa.
- **Modo desatendido** (`-Headless`) y **autotest** (`-SelfTest`).

---

## Requisitos

- Windows 10/11.
- PowerShell 5.1 o superior.
- Ejecutar como **Administrador** (el script se auto-eleva si hace falta).
- Conexión a Internet.
- **winget** (App Installer) para las funciones de actualizar/desinstalar/reparar y para el motor Winget.
- Opcional: módulo **ps2exe** para generar `ElvisLab.exe`.

---

## Estructura

```
ElvisLab\
│   ElvisLab.ps1        Script principal
│   ElvisLab.exe        Versión compilada (opcional, sin firmar)
│   config.json         Programas, accesos y ajustes
│   README.md
└─ Resources\           Iconos opcionales
```

Los iconos son opcionales. Si un programa está instalado, la tarjeta usa el icono real del ejecutable.
También puedes indicar un `.ico` o `.png` en el campo `icon` de cada programa.

---

## Uso rápido

1. Abre PowerShell **como Administrador**.
2. Permite la ejecución para esta sesión:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   ```
3. Entra a la carpeta y ejecuta:
   ```powershell
   cd "C:\Users\Docker\Desktop\Archivos\ElvisLab"
   .\ElvisLab.ps1
   ```

La ventana se abre centrada. Si no eres administrador, el script pide elevación y se relanza.

---

## Interfaz

### Barra superior

- **Instalar / Ajustes / Actualizar / Registro / Config**: cambia de pestaña.
- **Directo / Winget**: motor de instalación.
  - *Directo*: versión fijada en `config.json`, con SHA256 y/o firma verificada antes de ejecutar.
  - *Winget*: última versión del catálogo; no aplica el hash local.
- **Buscar programas...**: filtra las tarjetas por nombre o categoría.

### Panel lateral

- **Instalar**: instala los programas seleccionados y aplica los ajustes marcados.
- **Desinstalar**: desinstala con winget los programas seleccionados (pide confirmación).
- **Actualizar instalados**: actualiza con winget los programas gestionados que estén instalados.
- **Crear accesos directos**: crea los `.lnk` definidos en `config.json`.
- **Limpiar descargas**: borra descargas y archivos temporales de ElvisLab. Los accesos ya no dependen de esa carpeta.
- **Abrir registro**: abre el archivo `.log` en Notepad.
- **Seleccionar todo / Quitar selección**.
- **Expandir / Contraer categorías**.
- **Solo instalados**: muestra únicamente los programas detectados como instalados.

### Tarjetas

- Clic en una tarjeta para seleccionarla (círculo verde).
- Muestra estado: `No instalado`, `Instalado`, `Descargando`, `Verificando`, `Instalando`,
  `Actualizando`, `Desinstalando`, `Actualizado`, `Al dia`, `Omitido`, `Error`, `Cancelado`.
- Si el programa está instalado, usa su icono real; si no, un badge con sus iniciales.

### Pestaña Ajustes

- Los ajustes están agrupados en **Esenciales**, **Interfaz** y **Avanzados**.
- Presets rápidos:
  - **Recomendado**: marca todos los de la categoría *Esenciales*.
  - **Minimo**: marca solo punto de restauración y telemetría.
  - **Avanzados**: marca los de la categoría *Avanzados*.
  - **Todo / Limpiar**: marca o desmarca todo.
- Por defecto solo vienen marcados **punto de restauración** y **telemetría**; el resto se activa manualmente.
- Cada ajuste tiene un **interruptor**: azul cuando está activo y gris cuando está apagado. Abajo se muestra
  el contador **Ajustes seleccionados**.
- **Ejecutar ajustes marcados** aplica la selección sin instalar programas.
- El punto de restauración se ejecuta primero.
- **Deshacer seleccionados** revierte los ajustes que lo permitan. Los puntos de restauración no se deshacen desde aquí.

Tweaks incluidos:

| Categoría | Tweaks |
| --- | --- |
| Esenciales | Punto de restauración, telemetría, historial de actividad, ubicación, características de consumidor, optimización de entrega, widgets, apps en segundo plano, búsqueda web en Inicio. |
| Interfaz | Tema oscuro, extensiones de archivo, archivos ocultos, iconos centrados, modo juego, finalizar tarea con clic derecho, desactivar aceleración del ratón, efectos visuales para mejor rendimiento. |
| Avanzados | Rutas largas, inicio de sesión detallado, reloj en UTC, preferir IPv4, desactivar IPv6, hibernación, servicio DiagTrack, informes de errores (WerSvc). |

Notas:

- **Rutas largas**, **UTC**, **IPv6** y **hibernación** requieren reiniciar.
- **Hibernación** desactiva también el inicio rápido.
- **IPv6 - Preferir IPv4** e **IPv6 - Desactivar** son excluyentes; no marques ambas.
- **Reloj en UTC** puede desincronizar el reloj en equipos con arranque dual.
- Los tweaks de servicios detienen el servicio y cambian su tipo de inicio; se pueden restaurar con **Deshacer**.
- Los tweaks de registro se aplican en `HKLM` o `HKCU` según corresponda.

### Pestaña Actualizar

- Lista el estado de los programas gestionados.
- **Actualizar todos los instalados**: ejecuta `winget upgrade` solo para los programas de `config.json`.
- **Abrir Windows Update / Ver historial**: abre las páginas de Configuración.
- No se modifican las políticas de Windows Update (a diferencia de WinUtil). Es intencional para no dejar
  el sistema sin actualizaciones de seguridad.

### Pestaña Config

- Rutas de configuración y registro, contadores y motor actual.
- Herramientas clásicas de Windows y reparaciones.
- **SFC + DISM** abre una consola aparte y puede tardar mucho.
- **Reset de red** requiere reiniciar el equipo.
- **Limpiar temporales** elimina archivos temporales del usuario y del sistema; los que estén en uso se omiten.
- **DNS**: elige Google, Cloudflare, Cloudflare (malware), Quad9, AdGuard o DHCP y pulsa **Aplicar DNS**.
  Se aplica a todos los adaptadores físicos activos y se vacía la caché DNS.
- **Energía**: **Ultimate Performance** activa el plan; **Quitar plan** vuelve a Equilibrado y elimina los planes
  Ultimate Performance. No se recomienda en laptops.

### Cancelar

- Durante una operación el botón principal cambia a **Cancelar operacion**.
- La cancelación se aplica entre programas y durante la descarga.
- No se interrumpe un instalador o un `winget` que ya está ejecutándose; se detiene al terminar ese paso.

---

## Modo desatendido

Todos los comandos requieren Administrador (se solicita elevación automáticamente).

```powershell
# Instalar todos los programas con el motor directo y los ajustes habilitados
.\ElvisLab.ps1 -Headless

# Instalar solo algunos y aplicar tweaks concretos
.\ElvisLab.ps1 -Headless -Install python,git -Tweaks restorepoint,telemetry

# Instalar sin tweaks
.\ElvisLab.ps1 -Headless -Install notepadpp -NoTweaks

# Descargar y verificar sin instalar (útil para probar)
.\ElvisLab.ps1 -Headless -Install 7zip -NoTweaks -DryRun

# Instalar usando winget
.\ElvisLab.ps1 -Headless -Backend winget -Install notepadpp -NoTweaks

# Aplicar solo ajustes (sin instalar programas)
.\ElvisLab.ps1 -Headless -ApplyOnly -Tweaks telemetry

# Deshacer ajustes reversibles
.\ElvisLab.ps1 -Headless -UndoTweaks -Tweaks telemetry

# Actualizar con winget (todos los gestionados o solo algunos)
.\ElvisLab.ps1 -Headless -Upgrade
.\ElvisLab.ps1 -Headless -Upgrade -Install git,vlc

# Desinstalar con winget
.\ElvisLab.ps1 -Headless -Uninstall -Install vlc

# Instalar y crear accesos directos
.\ElvisLab.ps1 -Headless -Install python,git -Shortcuts

# Comprobar configuración, URLs y estado del sistema sin instalar nada
.\ElvisLab.ps1 -SelfTest

# Generar ElvisLab.exe
.\ElvisLab.ps1 -Build
```

### Códigos de salida del modo headless

| Código | Significado |
| --- | --- |
| 0 | Correcto |
| 1 | Error de configuración o de arranque |
| 2 | La operación terminó con errores |
| 3 | Cancelado por el usuario |

---

## `config.json`

```json
{
  "appName": "ElvisLab",
  "version": "1.4.1",
  "logDirectory": "%LOCALAPPDATA%\\ElvisLab\\logs",
  "files": [
    {
      "id": "python",
      "name": "Python 3.12",
      "wingetId": "Python.Python.3.12",
      "category": "Desarrollo",
      "badgeText": "Py",
      "badgeColor": "#3776AB",
      "icon": "",
      "source": "https://.../python-3.12.5-amd64.exe",
      "destination": "python-3.12.5-amd64.exe",
      "sha256": "44810512...",
      "publisher": "Python Software Foundation",
      "allowUnverified": false,
      "installArgs": "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0",
      "installTimeoutSec": 900,
      "downloadTimeoutSec": 600,
      "successExitCodes": [ 0, 3010, 1641 ],
      "installedPath": "%ProgramFiles%\\Python312\\python.exe",
      "alternatePaths": [
        "%LocalAppData%\\Programs\\Python\\Python312\\python.exe"
      ]
    }
  ],
  "shortcuts": [
    {
      "name": "Python 3.12",
      "fileName": "Python 3.12.lnk",
      "location": "Desktop",
      "fileId": "python",
      "arguments": "",
      "description": "Python 3.12",
      "icon": ""
    }
  ],
  "tweaks": [
    {
      "id": "telemetry",
      "name": "Telemetria de Windows - Desactivar",
      "type": "registry",
      "category": "Esenciales",
      "enabled": true,
      "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection",
      "valueName": "AllowTelemetry",
      "value": 0,
      "kind": "DWord",
      "undo": { "action": "remove" },
      "description": "Establece AllowTelemetry=0."
    }
  ]
}
```

### Campos de `files`

| Campo | Descripción |
| --- | --- |
| `id` | Identificador único, usado en la CLI y en los accesos. |
| `name` | Nombre mostrado y usado en el registro. |
| `wingetId` | Id exacto del paquete en winget (obligatorio para Winget/actualizar/desinstalar). |
| `category` | Categoría de la tarjeta (`Desarrollo`, `Utilidades`, `Multimedia`, etc.). |
| `badgeText`, `badgeColor`, `icon` | Personalización visual opcional. |
| `source` | URL **HTTPS** del instalador. |
| `destination` | Nombre del archivo descargado (sin carpetas). |
| `sha256` | Hash SHA256 esperado. Si está vacío, se puede usar la firma. |
| `publisher` | Texto que debe aparecer en el sujeto del certificado Authenticode. |
| `allowUnverified` | Permite instalar sin hash ni firma (no recomendado). |
| `installArgs` | Argumentos silenciosos del instalador. |
| `installTimeoutSec` | Tiempo máximo de espera del instalador. |
| `downloadTimeoutSec` | Tiempo máximo de descarga. |
| `successExitCodes` | Códigos de salida aceptados (por defecto 0, 3010, 1641). |
| `installedPath` | Ruta esperada tras instalar (admite variables de entorno). |
| `alternatePaths` | Rutas alternativas para detectar la instalación. |

### Verificación de integridad

- Si hay `sha256`, se compara el hash del archivo descargado.
- Si hay `publisher`, se exige firma Authenticode válida y que el certificado contenga ese texto.
- Si no hay `sha256` ni `publisher`, el programa **no se instala** salvo que `allowUnverified` sea `true`.
- Los 5 programas actuales están verificados:
  - Python, Notepad++, Git y VLC: SHA256 + firma.
  - 7-Zip: SHA256 (su instalador no está firmado digitalmente).

### Accesos directos

| Campo | Descripción |
| --- | --- |
| `name` | Nombre visible. |
| `fileName` | Nombre del `.lnk` (se añade `.lnk` si falta). |
| `location` | `Desktop`, `StartMenu` o una carpeta (admite variables). |
| `fileId` | Usa la ruta instalada del programa con ese id. |
| `target` | Ruta directa, si no se usa `fileId`. |
| `arguments`, `description`, `icon` | Opcionales. |

Si el programa no está instalado, el acceso se omite con una advertencia.

### Ajustes (`tweaks`)

| Campo | Descripción |
| --- | --- |
| `id`, `name`, `enabled` | Identificador, texto y estado inicial del checkbox. |
| `category` | Agrupación en la interfaz (`Esenciales`, `Interfaz`, `Avanzados`, etc.). |
| `type` | `registry`, `restorepoint`, `service` o `hibernation`. |
| `description` | Texto de ayuda. |

Tipos:

- **`registry`**: usa `path`, `valueName`, `value` y `kind` para un solo valor, o un array `values` para varios:
  ```json
  "values": [
    { "path": "HKCU:\\...", "valueName": "A", "value": 1, "kind": "DWord", "undo": { "action": "remove" } },
    { "path": "HKCU:\\...", "valueName": "B", "value": 0, "kind": "DWord", "undo": { "action": "set", "value": 1, "kind": "DWord" } }
  ]
  ```
- **`restorepoint`**: crea un punto de restauración; no tiene undo.
- **`service`**: `serviceName`, `startupType` (`Automatic`, `Manual`, `Disabled`), `stopService`, `undoStartupType`, `undoStartService`.
- **`hibernation`**: `action` = `disable` o `enable`; el undo aplica lo contrario.

El `undo` de un valor de registro puede ser:

- `{"action":"remove"}`: elimina el valor al deshacer.
- `{"action":"set","value":1,"kind":"DWord"}`: lo restaura a un valor concreto.

Los tweaks `restorepoint` se ejecutan antes que los demás.

---

## Seguridad

- Solo se descargan URLs **HTTPS**.
- Los instaladores del motor Directo se verifican con SHA256 y/o firma antes de ejecutarse.
- El motor Winget delega la verificación en los manifiestos y el instalador de winget.
- El script se ejecuta como Administrador; revisa `config.json` antes de añadir programas nuevos.
- `ElvisLab.exe` no está firmado digitalmente.
- Los tweaks de registro se aplican en `HKLM` y requieren Administrador.
- El punto de restauración depende de que la Protección del sistema esté disponible.

---

## Registro y archivos temporales

- Registro: `%LOCALAPPDATA%\ElvisLab\logs\ElvisLab_AAAAMMDD_HHMMSS.log`
- Descargas: `%TEMP%\ElvisLab\downloads`
- Estado de trabajos: `%TEMP%\ElvisLab\run_*\progress.json`
- El botón **Limpiar temporal** borra `%TEMP%\ElvisLab`; no borra los registros.

---

## Actualizar versiones

1. Cambia `source`, `destination`, `sha256` y, si aplica, `publisher` en `config.json`.
2. Calcula el hash:
   ```powershell
   Get-FileHash -Algorithm SHA256 .\instalador.exe
   ```
3. Comprueba la firma:
   ```powershell
   Get-AuthenticodeSignature .\instalador.exe | Select-Object Status, @{n='Subject';e={$_.SignerCertificate.Subject}}
   ```
4. Ejecuta el autotest:
   ```powershell
   .\ElvisLab.ps1 -SelfTest
   ```
5. Prueba la descarga sin instalar:
   ```powershell
   .\ElvisLab.ps1 -Headless -Install <id> -NoTweaks -DryRun
   ```

Si el fabricante publica una versión nueva, el hash cambia: es normal que la verificación falle hasta
actualizar `config.json`.

---

## Generar el `.exe`

```powershell
Install-Module ps2exe -Scope CurrentUser -Force   # una sola vez
.\ElvisLab.ps1 -Build
```

El `.exe` incluye el manifiesto de Administrador y no muestra consola. Sigue necesitando `config.json`
en la misma carpeta y no está firmado.

---

## Solución de problemas

| Problema | Solución |
| --- | --- |
| No se puede ejecutar el script | `Set-ExecutionPolicy -Scope Process Bypass -Force` o ejecuta el `.exe`. |
| No aparece la ventana de UAC | Ejecuta PowerShell como Administrador. |
| Error de hash | El instalador cambió de versión. Actualiza `sha256` con `Get-FileHash`. |
| Firma no válida | El editor cambió de certificado. Revisa el nuevo `Subject` y actualiza `publisher`. |
| `winget` no disponible | Instala **App Installer** desde Microsoft Store y comprueba `winget --version`. |
| Winget no detecta un programa instalado en modo Directo | Winget solo actualiza/desinstala paquetes que reconoce por ARP o por su propio catálogo. |
| No se crea el punto de restauración | Activa Protección del sistema para la unidad del sistema. |
| Python no está en la ruta esperada | Revisa `installedPath` / `alternatePaths` (instalación por usuario vs. por máquina). |
| SmartScreen bloquea el `.exe` | Es normal: no está firmado. Usa el `.ps1` o firma el binario. |
| SFC + DISM tarda mucho | Es esperado; se ejecuta en una consola separada. |
| Reset de red deja sin conexión | Reinicia el equipo para completar el reset. |

---

## Limitaciones

- No se implementan los modos de Windows Update de WinUtil (retrasar/desactivar actualizaciones) por seguridad.
- No hay creador de ISO (Win11 Creator).
- La desinstalación depende de que winget reconozca el programa.
- El motor Directo usa versiones fijadas; no busca automáticamente la última versión.
- Solo se incluyen 5 programas; añade más en `config.json`.
- Los tweaks son un subconjunto curado de WinUtil: no se incluyen eliminación de Edge/OneDrive, AppX, Windows AI, Storage Sense, servicios masivos ni BitLocker.

---

## Archivos principales

- `ElvisLab.ps1`: interfaz, motor de descarga/verificación/instalación, winget, tweaks, accesos, modo headless.
- `config.json`: catálogo y ajustes.
- `ElvisLab.exe`: compilado opcional con ps2exe.
