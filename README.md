# Update-All

Actualiza desde un único sitio los programas (winget), Windows Update y las apps de Microsoft Store, con interfaz interactiva en consola.

## Descarga

1. Descarga **`Update-All.zip`** de la [última versión](https://github.com/thebrokenbrain/windows-update-all/releases/latest).
2. Antes de descomprimir: clic derecho en el .zip → **Propiedades** → marca **Desbloquear** → Aceptar.
3. Descomprime en una carpeta fija (por ejemplo `Documentos\Update-All`); ahí se guardan la configuración y los registros.
4. Si al ejecutarlo aparece "Windows protegió su PC", pulsa **Más información → Ejecutar de todas formas**.

## Uso

Doble clic en **`Update-All.cmd`**, o desde una terminal:

```powershell
.\Update-All.ps1            # menú interactivo
.\Update-All.ps1 -DryRun    # solo comprobar, no instala nada (no pide administrador)
.\Update-All.ps1 -Auto      # instala todo sin preguntar (para tareas programadas)
.\Update-All.ps1 -Settings  # abre la configuración
```

La primera vez, el script:

1. Si no tienes **PowerShell 7**, te pregunta si quieres instalarlo (con winget) y se relanza en él.
2. Pide permisos de **administrador** (un único aviso de Windows).
3. Si faltan los módulos **PwshSpectreConsole** y **Microsoft.WinGet.Client**, te pregunta si quieres instalarlos (solo para tu usuario).

## Navegación

- Muévete con las flechas y elige con **Intro**. Todos los menús tienen una opción **← Volver**.
- Antes de instalar verás el menú *Elige qué instalar*: desde ahí puedes revisar las listas de programas y de Windows Update, activar o desactivar la Store, empezar o volver al menú principal sin instalar nada.
- En las listas con casillas, **Espacio** marca o desmarca e **Intro** confirma. Si no cambias nada, la selección se queda como estaba.

## Configuración

Se guarda en `Update-All.config.json`, junto al script, y se edita desde el menú *Configuración*:

| Ajuste | Por defecto | Qué hace |
|---|---|---|
| Modo de descarga de winget | `wininet` | `wininet` descarga directamente (más rápido); `do` usa Delivery Optimization |
| Incluir apps con versión desconocida | No | winget no sabe qué versión tienen y puede reinstalarlas cada vez |
| Programas excluidos | ninguno | Nunca se actualizan |
| Windows Update | Sí | |
| Drivers de Windows Update | No | Si se activa, aparecen sin marcar para elegirlos a mano |
| Microsoft Store | Sí | |
| Punto de restauración previo | Sí | Windows solo crea uno cada 24 h |
| Reiniciar solo en modo `-Auto` | No | Reinicia a los 60 s si hace falta |

Cada ejecución deja un registro en `logs\`.

## Notas

- PowerShell y winget (App Installer) se actualizan al final, porque su actualización puede cerrar la ventana.
- Si la Store no acepta la orden automática, se abre en *Descargas y actualizaciones*.
