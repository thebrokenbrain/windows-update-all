<#
.SYNOPSIS
    Actualiza programas (winget), Windows Update y Microsoft Store desde un único sitio.

.DESCRIPTION
    - Si falta PowerShell 7 lo ofrece instalar y se relanza en él (y como administrador).
    - Instala bajo demanda los módulos que necesita (PwshSpectreConsole, Microsoft.WinGet.Client).
    - Modo interactivo: menú, listas para elegir qué actualizar y menú de configuración.
    - Modo -Auto: instala todo lo pendiente (respetando exclusiones) sin preguntar.
    - Modo -DryRun: solo comprueba y muestra qué se actualizaría; no instala nada ni pide administrador.

.PARAMETER Auto
    Instala todo sin preguntar. Pensado para tareas programadas.

.PARAMETER DryRun
    Solo comprueba. No instala ni modifica nada.

.PARAMETER Settings
    Abre directamente el menú de configuración.

.EXAMPLE
    .\Update-All.ps1
    .\Update-All.ps1 -Auto
    .\Update-All.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$DryRun,
    [switch]$Settings,
    # Uso interno: indica que el script se ha relanzado a sí mismo en una ventana nueva.
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script:AppName    = 'Update-All'
$script:AppVersion = '1.1.0'
$script:ConfigPath = Join-Path $PSScriptRoot 'Update-All.config.json'
$script:LogDir     = Join-Path $PSScriptRoot 'logs'
$script:LogFile    = $null

# Paquetes que se actualizan al final porque pueden cerrar esta misma ventana.
$script:SelfPackageIds = @('Microsoft.PowerShell', 'Microsoft.PowerShell.Preview', 'Microsoft.AppInstaller')

$script:RequiredModules = @(
    @{ Name = 'PwshSpectreConsole';      MinVersion = '2.0.0' }
    @{ Name = 'Microsoft.WinGet.Client'; MinVersion = '1.9.0' }
)

#region Arranque (compatible con Windows PowerShell 5.1: sin Spectre ni sintaxis de PS7)

function Write-Boot {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "  $Message" -ForegroundColor $Color
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Interactive {
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

function Find-Pwsh {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $true)
    $hint = if ($Default) { '[S/n]' } else { '[s/N]' }
    $answer = Read-Host "  $Question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return ($answer.Trim().ToLower() -in @('s', 'si', 'sí', 'y', 'yes'))
}

function Get-RelaunchArguments {
    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Auto)     { $list += '-Auto' }
    if ($DryRun)   { $list += '-DryRun' }
    if ($Settings) { $list += '-Settings' }
    $list += '-Relaunched'
    return $list
}

# Relanza como administrador. Si existe Windows Terminal se abre dentro de él (pestañas, fuentes con
# emojis y símbolos); si no, en la consola clásica, donde el script usa símbolos sencillos.
function Start-Elevated {
    param([string]$Exe, [string[]]$Arguments)
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    try {
        if ($wt) {
            $wtArgs = @('-w', 'new', '--title', $script:AppName, "`"$Exe`"") + $Arguments
            Start-Process -FilePath $wt.Source -Verb RunAs -ArgumentList $wtArgs
        } else {
            Start-Process -FilePath $Exe -Verb RunAs -ArgumentList $Arguments
        }
    } catch {
        Write-Boot 'Se canceló la elevación.' 'Red'
        exit 1
    }
}

function Install-Pwsh {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Boot 'No se encuentra winget, así que no puedo instalar PowerShell 7 automáticamente.' 'Red'
        Write-Boot 'Instala "Instalador de aplicación" desde Microsoft Store o PowerShell 7 desde https://aka.ms/powershell' 'Yellow'
        return $false
    }
    Write-Boot 'Instalando PowerShell 7 con winget...' 'Cyan'
    & winget install --id Microsoft.PowerShell --exact --source winget --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    return [bool](Find-Pwsh)
}

function Invoke-Bootstrap {
    $needsAdmin = -not $DryRun
    $isAdmin    = Test-IsAdmin

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host ''
        Write-Boot "$script:AppName $script:AppVersion" 'White'
        $pwsh = Find-Pwsh
        if (-not $pwsh) {
            Write-Boot 'Este script necesita PowerShell 7 (gratuito y oficial de Microsoft).' 'Yellow'
            Write-Boot 'Se instala junto a Windows PowerShell 5.1, sin reemplazarlo.' 'Gray'
            $consent = $Auto -or (Read-YesNo '¿Quieres instalarlo ahora?')
            if (-not $consent) { Write-Boot 'Cancelado.' 'Red'; exit 1 }
            if (-not (Install-Pwsh)) { Write-Boot 'No se pudo instalar PowerShell 7.' 'Red'; exit 1 }
            $pwsh = Find-Pwsh
            Write-Boot 'PowerShell 7 instalado.' 'Green'
        }
        $arguments = Get-RelaunchArguments
        if ($needsAdmin -and -not $isAdmin) {
            Write-Boot 'Abriendo PowerShell 7 como administrador (acepta el aviso de Windows)...' 'Cyan'
            Start-Elevated -Exe $pwsh -Arguments $arguments
            exit 0
        }
        & $pwsh @arguments
        exit $LASTEXITCODE
    }

    if ($needsAdmin -and -not $isAdmin) {
        Write-Boot 'Se necesitan permisos de administrador. Acepta el aviso de Windows...' 'Cyan'
        Start-Elevated -Exe (Get-Process -Id $PID).Path -Arguments (Get-RelaunchArguments)
        exit 0
    }
}

function Initialize-Dependencies {
    $missing = @()
    foreach ($m in $script:RequiredModules) {
        $found = Get-Module -ListAvailable -Name $m.Name | Where-Object { $_.Version -ge [version]$m.MinVersion }
        if (-not $found) { $missing += $m.Name }
    }
    if ($missing.Count -gt 0) {
        Write-Boot "Faltan módulos de PowerShell: $($missing -join ', ')" 'Yellow'
        Write-Boot 'Se instalan desde PowerShell Gallery solo para tu usuario.' 'Gray'
        $consent = $Auto -or (-not (Test-Interactive)) -or (Read-YesNo '¿Instalarlos ahora?')
        if (-not $consent) { Write-Boot 'Cancelado.' 'Red'; exit 1 }
        foreach ($name in $missing) {
            Write-Boot "Instalando $name..." 'Cyan'
            if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
                Install-PSResource -Name $name -Scope CurrentUser -TrustRepository -Quiet
            } else {
                Install-Module -Name $name -Scope CurrentUser -Force -AllowClobber
            }
        }
    }
    foreach ($m in $script:RequiredModules) { Import-Module $m.Name -MinimumVersion $m.MinVersion }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Boot 'winget no está disponible. Intentando repararlo...' 'Yellow'
        try { Repair-WinGetPackageManager -Latest } catch { }
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Boot 'No se pudo activar winget. Instala "Instalador de aplicación" desde Microsoft Store.' 'Red'
            exit 1
        }
    }
}

#endregion

#region Configuración

function Get-DefaultConfig {
    return [ordered]@{
        WingetDownloader       = 'wininet'   # wininet | do | default
        IncludeUnknownVersions = $false
        ExcludedIds            = @()
        WindowsUpdate          = $true
        WindowsUpdateDrivers   = $false
        MicrosoftStore         = $true
        RestorePoint           = $true
        AutoRebootInAutoMode   = $false
    }
}

function Get-Config {
    $config = Get-DefaultConfig
    if (Test-Path $script:ConfigPath) {
        try {
            $saved = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($key in @($config.Keys)) {
                if ($saved.PSObject.Properties.Name -contains $key) { $config[$key] = $saved.$key }
            }
            $config.ExcludedIds = @($config.ExcludedIds | Where-Object { $_ })
        } catch {
            Write-Log 'ERROR' "Leyendo $script:ConfigPath : $($_.Exception.Message)"
            Write-Warn 'No se pudo leer el archivo de configuración; se usan los valores por defecto.'
        }
    }
    return $config
}

function Save-Config {
    param($Config)
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigPath -Encoding utf8
}

function Sync-WingetSettings {
    param($Config)
    try {
        $current = Get-WinGetUserSetting
        $value = $null
        if ($current.ContainsKey('network') -and $current.network.ContainsKey('downloader')) { $value = $current.network.downloader }
        if ($value -ne $Config.WingetDownloader) {
            $label = $script:DownloaderLabels[$Config.WingetDownloader]
            if ($script:IsDryRun) {
                Write-Info "Se cambiaría el modo de descarga de winget a: $label."
            } else {
                Set-WinGetUserSetting -UserSettings @{ network = @{ downloader = $Config.WingetDownloader } } -Merge | Out-Null
                Write-Ok "Modo de descarga de winget ajustado a: $label."
            }
        }
    } catch {
        Write-Log 'ERROR' "Ajustando winget: $($_.Exception.Message)"
        Write-Warn 'No se pudo ajustar el modo de descarga de winget; se usa el que ya tenía.'
    }
}

$script:DownloaderLabels = [ordered]@{
    'wininet' = 'WinINet (descarga directa, rápida)'
    'do'      = 'Delivery Optimization (la de Windows Update)'
    'default' = 'Por defecto de winget'
}

# Ajustes booleanos del menú de configuración: clave de config -> nombre y explicación.
$script:ToggleSettings = [ordered]@{
    IncludeUnknownVersions = @{ Name = 'Apps con versión desconocida'; Help = 'winget no sabe qué versión tienen y puede reinstalarlas cada vez.' }
    WindowsUpdate          = @{ Name = 'Windows Update';               Help = 'Buscar e instalar actualizaciones de Windows.' }
    WindowsUpdateDrivers   = @{ Name = 'Drivers de Windows Update';    Help = 'Mostrar también drivers. Aparecen sin marcar: elige solo los que necesites.' }
    MicrosoftStore         = @{ Name = 'Microsoft Store';              Help = 'Pedir a la Store que actualice sus apps.' }
    RestorePoint           = @{ Name = 'Punto de restauración';        Help = 'Crear uno antes de instalar (requiere la Protección del sistema activada).' }
    AutoRebootInAutoMode   = @{ Name = 'Reinicio automático (-Auto)';  Help = 'En modo automático, reiniciar el equipo si alguna actualización lo necesita.' }
}

function Get-ExcludedSummary {
    param($Config)
    if ($Config.ExcludedIds.Count -eq 0) { return 'ninguno' }
    return Format-Count $Config.ExcludedIds.Count 'programa' 'programas'
}

function Show-SettingsMenu {
    param($Config)
    $saved   = (Get-Config | ConvertTo-Json -Depth 5)
    $message = $null
    while ($true) {
        Clear-Screen
        Write-SpectreRule -Title '[bold]Configuración[/]' -Alignment Left -Color 'DeepSkyBlue1' | Out-Host
        $rows = @(
            [pscustomobject]@{ Ajuste = 'Modo de descarga de winget'; Valor = "[aqua]$(Esc $script:DownloaderLabels[$Config.WingetDownloader])[/]"; 'Qué hace' = '[grey]Cómo descarga winget los instaladores. WinINet suele ser más rápido.[/]' }
            [pscustomobject]@{ Ajuste = 'Programas excluidos'; Valor = "[aqua]$(Get-ExcludedSummary $Config)[/]"; 'Qué hace' = '[grey]Programas que no se actualizan nunca.[/]' }
        )
        foreach ($key in $script:ToggleSettings.Keys) {
            $s = $script:ToggleSettings[$key]
            $rows += [pscustomobject]@{ Ajuste = Esc $s.Name; Valor = Format-Bool $Config[$key]; 'Qué hace' = "[grey]$(Esc $s.Help)[/]" }
        }
        Write-Table -Rows $rows -Wrap 'Qué hace'

        $dirty = (($Config | ConvertTo-Json -Depth 5) -ne $saved)
        if ($message) { Write-Ok $message; $message = $null }
        if ($dirty) { Write-Warn 'Hay cambios sin guardar.' }
        Write-Host ''

        $options = [ordered]@{
            'downloader' = 'Modo de descarga de winget'
            'excluded'   = 'Programas excluidos'
        }
        foreach ($key in $script:ToggleSettings.Keys) { $options[$key] = $script:ToggleSettings[$key].Name }
        if ($dirty) {
            $options['save']   = '[green]Guardar cambios y volver[/]'
            $options['cancel'] = '← Volver sin guardar'
        } else {
            $options['cancel'] = '← Volver'
        }

        $choice = Read-Choice -Title 'Elige un ajuste para cambiarlo:' -Options $options
        switch ($choice) {
            'downloader' {
                $choices = [ordered]@{}
                foreach ($k in $script:DownloaderLabels.Keys) {
                    $mark = if ($k -eq $Config.WingetDownloader) { ' [grey](actual)[/]' } else { '' }
                    $choices[$k] = "$(Esc $script:DownloaderLabels[$k])$mark"
                }
                $choices['__back'] = '← Volver sin cambiar'
                $picked = Read-Choice -Title 'Modo de descarga de winget:' -Options $choices
                if ($picked -ne '__back' -and $picked -ne $Config.WingetDownloader) {
                    $Config.WingetDownloader = $picked
                    $message = "Modo de descarga de winget: $($script:DownloaderLabels[$picked])"
                }
            }
            'excluded' {
                $before = @($Config.ExcludedIds)
                $Config.ExcludedIds = @(Edit-Exclusions -Current $Config.ExcludedIds)
                if (($before -join '|') -ne (@($Config.ExcludedIds) -join '|')) { $message = "Programas excluidos: $(Get-ExcludedSummary $Config)" }
            }
            'save' {
                Save-Config $Config
                $script:Notice = 'Configuración guardada.'
                return $Config
            }
            'cancel' {
                if ($dirty -and -not (Confirm-Action 'Hay cambios sin guardar. ¿Salir y descartarlos?' $false)) { continue }
                if ($dirty) { $script:Notice = 'Cambios descartados; la configuración sigue como estaba.' }
                return (Get-Config)
            }
            default {
                if ($script:ToggleSettings.Contains($choice)) {
                    $Config[$choice] = -not [bool]$Config[$choice]
                    $state = if ($Config[$choice]) { 'Sí' } else { 'No' }
                    $message = "$($script:ToggleSettings[$choice].Name): $state"
                }
            }
        }
    }
}

# Editor de la lista de exclusiones: añadir (con búsqueda) o quitar programas de uno en uno,
# siempre con opción de volver. La lista completa de instalados es demasiado larga para casillas.
function Edit-Exclusions {
    param([string[]]$Current)
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($Current)) { if ($id) { $list.Add($id) } }

    $packages = @(Invoke-WithSpinner 'Leyendo programas instalados...' { @(Get-WinGetPackage | Where-Object { $_.Source }) })
    $names = @{}
    foreach ($p in $packages) { $names[$p.Id] = $p.Name }

    $message = $null
    while ($true) {
        Clear-Screen
        Write-SpectreRule -Title '[bold]Configuración › Programas excluidos[/]' -Alignment Left -Color 'DeepSkyBlue1' | Out-Host
        Write-Info 'Los programas de esta lista no se actualizan nunca, ni en modo automático.'
        if ($list.Count -eq 0) {
            Write-Info 'La lista está vacía.'
        } else {
            $rows = foreach ($id in $list) {
                $name = if ($names.ContainsKey($id)) { $names[$id] } else { '(no instalado)' }
                [pscustomobject]@{ Programa = Esc $name; Id = "[grey]$(Esc $id)[/]" }
            }
            Write-Table -Rows $rows -Wrap 'Programa'
        }
        if ($message) { Write-Ok $message; $message = $null }
        Write-Host ''

        $options = [ordered]@{ 'add' = 'Añadir un programa a la lista' }
        if ($list.Count -gt 0) { $options['remove'] = 'Quitar un programa de la lista' }
        $options['back'] = '← Volver a Configuración'

        switch (Read-Choice -Title '¿Qué quieres hacer?' -Options $options) {
            'add' {
                # Primero los que tienen actualización pendiente, que son los que se suelen querer excluir.
                $candidates = $packages | Where-Object { $list -notcontains $_.Id } |
                    Sort-Object @{ Expression = { -not $_.IsUpdateAvailable } }, Name
                $choices = [ordered]@{ '__back' = '← Volver sin añadir' }
                foreach ($p in $candidates) {
                    $tag = if ($p.IsUpdateAvailable) { '  · tiene actualización' } else { '' }
                    $choices[$p.Id] = Esc "$($p.Name) ($($p.Id))$tag"
                }
                $picked = Read-Choice -Title 'Elige el programa que no quieres actualizar [grey](escribe para buscar)[/]:' -Options $choices -Search
                if ($picked -and $picked -ne '__back') {
                    $list.Add($picked)
                    $message = "Añadido: $($names[$picked])"
                }
            }
            'remove' {
                $choices = [ordered]@{ '__back' = '← Volver sin quitar' }
                foreach ($id in $list) {
                    $name = if ($names.ContainsKey($id)) { "$($names[$id]) ($id)" } else { $id }
                    $choices[$id] = Esc $name
                }
                $picked = Read-Choice -Title 'Elige el programa que quieres volver a actualizar:' -Options $choices
                if ($picked -and $picked -ne '__back') {
                    [void]$list.Remove($picked)
                    $label = if ($names.ContainsKey($picked)) { $names[$picked] } else { $picked }
                    $message = "Quitado: $label"
                }
            }
            'back' { return $list.ToArray() }
        }
    }
}

#endregion

#region Interfaz y registro

function Esc { param($Text) return [Spectre.Console.Markup]::Escape([string]$Text) }

# Windows Terminal trae fuentes con emojis, braille y esquinas redondeadas; la consola clásica (Consolas)
# no, así que allí se usan símbolos que esa fuente sí tiene.
function Initialize-Theme {
    $fancy = [bool]$env:WT_SESSION
    $script:Theme = if ($fancy) {
        @{ Ok = '✔'; Err = '✖'; Warn = '⚠'; Info = '›'; Border = 'Rounded'; Spinner = 'Dots'
           Run = '🔄  '; Check = '🔍  '; Gear = '⚙️   '; Quit = '🚪  ' }
    } else {
        @{ Ok = '√'; Err = 'x'; Warn = '!'; Info = '>'; Border = 'Square'; Spinner = 'Line'
           Run = ''; Check = ''; Gear = ''; Quit = '' }
    }
}

function Clear-Screen { try { Clear-Host } catch { } }

function Format-Bool { param([bool]$Value) if ($Value) { return '[green]Sí[/]' } else { return '[grey]No[/]' } }

function Write-Log {
    param([string]$Level, [string]$Message)
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Encoding utf8 -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message)
    }
}

function Write-Ok   { param([string]$m) Write-SpectreHost "  [green]$($script:Theme.Ok)[/] $(Esc $m)";          Write-Log 'OK'    $m }
function Write-Warn { param([string]$m) Write-SpectreHost "  [yellow]$($script:Theme.Warn)[/] $(Esc $m)";       Write-Log 'WARN'  $m }
function Write-Err  { param([string]$m) Write-SpectreHost "  [red]$($script:Theme.Err)[/] $(Esc $m)";          Write-Log 'ERROR' $m }
function Write-Info { param([string]$m) Write-SpectreHost "  [deepskyblue1]$($script:Theme.Info)[/] $(Esc $m)"; Write-Log 'INFO'  $m }

# Muestra (una vez) el aviso pendiente de una pantalla anterior que se borró al salir de ella.
function Write-Notice {
    if ($script:Notice) { Write-Ok $script:Notice; $script:Notice = $null }
}

function Write-Step {
    param([string]$Title)
    Write-Host ''
    # Write-SpectreRule y Write-SpectreFigletText devuelven el texto; Out-Host evita que acabe en el valor de retorno.
    Write-SpectreRule -Title "[bold]$(Esc $Title)[/]" -Alignment Left -Color 'DeepSkyBlue1' | Out-Host
    Write-Log 'STEP' $Title
}

# Vuelve a activar la interpretación de secuencias ANSI en la consola. Cualquier programa de consola
# que se ejecute compartiendo esta ventana (instaladores, winget...) puede haberla desactivado.
function Enable-VirtualTerminal {
    if ([Console]::IsOutputRedirected) { return }
    try {
        if (-not ('UpdateAll.ConsoleMode' -as [type])) {
            Add-Type -Namespace UpdateAll -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $handle = [UpdateAll.ConsoleMode]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = [uint32]0
        if ([UpdateAll.ConsoleMode]::GetConsoleMode($handle, [ref]$mode) -and -not ($mode -band 0x4)) {
            [void][UpdateAll.ConsoleMode]::SetConsoleMode($handle, $mode -bor 0x4)   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        }
    } catch { }
}

function Invoke-WithSpinner {
    param([string]$Title, [scriptblock]$ScriptBlock)
    # Sin una terminal real la animación se vería como códigos de escape: se muestra el texto y se ejecuta sin más.
    if ([Console]::IsOutputRedirected -or -not [Spectre.Console.AnsiConsole]::Console.Profile.Capabilities.Ansi) {
        Write-Info $Title
        return (& $ScriptBlock)
    }
    try {
        $out = Invoke-SpectreCommandWithStatus -Spinner $script:Theme.Spinner -Color 'DeepSkyBlue1' -Title (Esc $Title) -ScriptBlock $ScriptBlock
    } finally {
        Enable-VirtualTerminal
    }
    # Spectre devuelve la salida del bloque envuelta en una colección; se desenvuelve aquí.
    $out | ForEach-Object { $_ }
}

# Tabla con columnas de ancho natural que no se parten; solo las columnas de -Wrap (textos largos)
# usan varias líneas. Format-SpectreTable no permite esto y reparte mal el ancho con títulos largos.
# $Rows: objetos cuyas propiedades (en orden) son las columnas, con valores en markup ya escapado.
function Write-Table {
    param($Rows, [string]$Title, [string[]]$Wrap = @())
    $Rows = @($Rows)
    if ($Rows.Count -eq 0) { return }
    $table = [Spectre.Console.Table]::new()
    $table.Border      = [Spectre.Console.TableBorder]::($script:Theme.Border)
    $table.BorderStyle = [Spectre.Console.Style]::Parse('grey')
    if ($Title) { $table.Title = [Spectre.Console.TableTitle]::new($Title) }
    $names = @($Rows[0].PSObject.Properties.Name)
    $columns = foreach ($name in $names) {
        $col = [Spectre.Console.TableColumn]::new([Spectre.Console.Markup]::new("[deepskyblue1]$(Esc $name)[/]"))
        $col.NoWrap = ($Wrap -notcontains $name)
        $col
    }
    [void][Spectre.Console.TableExtensions]::AddColumns($table, [Spectre.Console.TableColumn[]]$columns)
    foreach ($row in $Rows) {
        $cells = foreach ($name in $names) { [Spectre.Console.Markup]::new([string]$row.$name) }
        [void][Spectre.Console.TableExtensions]::AddRow($table, [Spectre.Console.Rendering.IRenderable[]]$cells)
    }
    # Out-SpectreHost devuelve el texto renderizado a la salida; Out-Host lo manda a pantalla para que
    # no se mezcle con el valor de retorno de la función que llama.
    $table | Out-SpectreHost | Out-Host
}

# Menú de una opción. $Options: diccionario ordenado clave -> etiqueta (markup); devuelve la clave.
# Se construye el SelectionPrompt a mano para tener los textos en español y búsqueda opcional.
function Read-Choice {
    param([string]$Title, [System.Collections.IDictionary]$Options, [switch]$Search)
    $prompt = [Spectre.Console.SelectionPrompt[string]]::new()
    $prompt.Title           = $Title
    $prompt.PageSize        = 12
    $prompt.WrapAround      = $true
    $prompt.HighlightStyle  = [Spectre.Console.Style]::Parse('deepskyblue1')
    $prompt.MoreChoicesText = '[grey](Muévete arriba/abajo para ver más opciones)[/]'
    if ($Search) {
        $prompt.SearchEnabled         = $true
        $prompt.SearchPlaceholderText = '[grey](Escribe para filtrar la lista)[/]'
    }
    [void][Spectre.Console.SelectionPromptExtensions]::AddChoices($prompt, [string[]]@($Options.Values))
    $selected = $prompt.Show([Spectre.Console.AnsiConsole]::Console)
    foreach ($key in $Options.Keys) { if ($Options[$key] -eq $selected) { return $key } }
}

# Lista con casillas que permite dejar elementos marcados de antemano.
# $Items: diccionario ordenado etiqueta(markup) -> valor devuelto.
function Read-Checklist {
    param([string]$Title, [System.Collections.IDictionary]$Items, [string[]]$Preselected = @())
    if ($Items.Count -eq 0) { return @() }
    $prompt = [Spectre.Console.MultiSelectionPrompt[string]]::new([System.Collections.Generic.IEqualityComparer[string]]$null)
    $prompt.Title           = $Title
    $prompt.PageSize        = 15
    $prompt.Required        = $false
    $prompt.WrapAround      = $true
    $prompt.InstructionsText = '[grey](Espacio: marcar/desmarcar · Intro: confirmar y volver. Si no cambias nada, la selección se queda como estaba.)[/]'
    $prompt.MoreChoicesText  = '[grey](Muévete arriba/abajo para ver más)[/]'
    $prompt.HighlightStyle   = [Spectre.Console.Style]::Parse('deepskyblue1')
    [void][Spectre.Console.MultiSelectionPromptExtensions]::AddChoices($prompt, [string[]]@($Items.Keys))
    foreach ($label in $Preselected) {
        if ($Items.Contains($label)) { [void][Spectre.Console.MultiSelectionPromptExtensions]::Select($prompt, $label) }
    }
    $chosen = $prompt.Show([Spectre.Console.AnsiConsole]::Console)
    return @($chosen | ForEach-Object { $Items[$_] })
}

function Confirm-Action {
    param([string]$Message, [bool]$Default = $true)
    if ($Auto) { return $Default }
    # ConfirmationPrompt directo para poder usar s/n en lugar del y/n de Read-SpectreConfirm.
    $prompt = [Spectre.Console.ConfirmationPrompt]::new((Esc $Message))
    $prompt.Yes = 's'
    $prompt.No  = 'n'
    $prompt.DefaultValue = $Default
    $prompt.InvalidChoiceMessage = '[red]Responde s o n[/]'
    return $prompt.Show([Spectre.Console.AnsiConsole]::Console)
}

function Format-Count {
    param([int]$Count, [string]$Singular, [string]$Plural)
    if ($Count -eq 1) { return "1 $Singular" }
    return "$Count $Plural"
}

# La Protección del sistema registra en SPP\Clients cada volumen protegido; si no hay ninguno,
# Windows no puede crear puntos de restauración.
function Test-SystemProtection {
    $clients = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' -ErrorAction SilentlyContinue
    if (-not $clients) { return $false }
    return [bool]@($clients.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }).Count
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds }
    return '{0:0.0}s' -f $Span.TotalSeconds
}

function Show-Header {
    Clear-Screen
    Write-SpectreFigletText -Text 'Update-All' -Color 'DeepSkyBlue1' | Out-Host
    $os = Get-CimInstance Win32_OperatingSystem
    $mode = if ($script:IsDryRun) { '[yellow]Solo comprobar[/]' } elseif ($Auto) { '[magenta]Automático[/]' } else { '[green]Interactivo[/]' }
    $admin = if (Test-IsAdmin) { '[green]Sí[/]' } else { '[yellow]No[/]' }
    $lines = @(
        "[grey]Equipo:[/]        $(Esc $env:COMPUTERNAME)",
        "[grey]Sistema:[/]       $(Esc $os.Caption) [grey](compilación $($os.BuildNumber))[/]",
        "[grey]PowerShell:[/]    $($PSVersionTable.PSVersion)",
        "[grey]Administrador:[/] $admin",
        "[grey]Modo:[/]          $mode",
        "[grey]Registro:[/]      $(Esc $script:LogFile)"
    )
    Format-SpectrePanel -Data ($lines -join "`n") -Header " v$script:AppVersion " -Border $script:Theme.Border -Color 'Grey' | Out-SpectreHost | Out-Host
}

#endregion

#region Comprobación de actualizaciones

$script:WuCategoryNames = @{
    'Security Updates'   = 'Seguridad'
    'Critical Updates'   = 'Crítica'
    'Updates'            = 'Actualización'
    'Definition Updates' = 'Definiciones'
    'Drivers'            = 'Driver'
    'Update Rollups'     = 'Paquete acumulativo'
    'Feature Packs'      = 'Característica'
    'Service Packs'      = 'Service Pack'
    'Upgrades'           = 'Nueva versión'
    'Tools'              = 'Herramienta'
}

# Las actualizaciones acumulativas declaran un tamaño máximo enorme (paquete completo) aunque
# la descarga real sea mucho menor; por encima de este umbral se muestra como "variable".
$script:WuSizeUnreliableMB = 1000

function Format-WuSize {
    param([double]$SizeMB)
    if ($SizeMB -ge $script:WuSizeUnreliableMB) { return 'variable' }
    return '{0:N1} MB' -f $SizeMB
}

function Get-AppUpdates {
    param($Config)
    $result = Invoke-WithSpinner 'Buscando actualizaciones de programas (winget)...' {
        # En un proceso oculto aparte: si winget.exe comparte esta consola, desactiva la interpretación
        # de secuencias ANSI mientras corre y la animación se ve como códigos de escape.
        Start-Process winget -ArgumentList 'source', 'update', '--disable-interactivity' -WindowStyle Hidden -Wait
        @(Get-WinGetPackage | Where-Object { $_.IsUpdateAvailable })
    }
    $apps = @(); $skipped = @()
    foreach ($p in $result) {
        $unknown = ($p.InstalledVersion -eq 'Unknown')
        $item = [pscustomobject]@{
            Name      = $p.Name
            Id        = $p.Id
            Current   = $p.InstalledVersion
            Available = @($p.AvailableVersions)[0]
            Source    = $p.Source
            Unknown   = $unknown
            IsSelf    = ($script:SelfPackageIds -contains $p.Id)
            Reason    = $null
        }
        if ($Config.ExcludedIds -contains $p.Id) { $item.Reason = 'excluded'; $skipped += $item; continue }
        if ($unknown -and -not $Config.IncludeUnknownVersions) { $item.Reason = 'unknown'; $skipped += $item; continue }
        $apps += $item
    }
    return [pscustomobject]@{ Apps = $apps; Skipped = $skipped }
}

function Get-WindowsUpdates {
    param($Config)
    $includeDrivers = [bool]$Config.WindowsUpdateDrivers
    return Invoke-WithSpinner 'Buscando actualizaciones de Windows Update...' {
        $script:WuSession = New-Object -ComObject Microsoft.Update.Session
        $searcher = $script:WuSession.CreateUpdateSearcher()
        $criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"
        if ($includeDrivers) { $criteria += " or IsInstalled=0 and IsHidden=0 and Type='Driver'" }
        $found = $searcher.Search($criteria).Updates
        $list = @()
        foreach ($u in $found) {
            $classification = ($u.Categories | Where-Object { $_.Type -eq 'UpdateClassification' } | Select-Object -First 1).Name
            $isDriver = ($u.Type -eq 2)
            if (-not $classification) { $classification = if ($isDriver) { 'Drivers' } else { 'Updates' } }
            if ($script:WuCategoryNames.ContainsKey($classification)) { $classification = $script:WuCategoryNames[$classification] }
            $list += [pscustomobject]@{
                Title    = $u.Title
                KB       = (@($u.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
                SizeMB   = [math]::Round($u.MaxDownloadSize / 1MB, 1)
                Category = $classification
                IsDriver = $isDriver
                Update   = $u
            }
        }
        $list
    }
}

function Show-AppTable {
    param($Apps, $Skipped)
    if ($Apps.Count -eq 0) { Write-Ok 'Todos los programas están al día.' }
    else {
        $rows = foreach ($a in $Apps) {
            $note = if ($a.IsSelf) { ' [grey](al final)[/]' } elseif ($a.Unknown) { ' [grey](versión desconocida)[/]' } else { '' }
            [pscustomobject]@{
                Programa = "$(Esc $a.Name)$note"
                Id       = "[grey]$(Esc $a.Id)[/]"
                Actual   = Esc $a.Current
                Nueva    = "[green]$(Esc $a.Available)[/]"
                Origen   = Esc $a.Source
            }
        }
        Write-Table -Rows $rows -Title "Programas con actualización ($($Apps.Count))" -Wrap 'Programa'
    }
    $excluded = @($Skipped | Where-Object { $_.Reason -eq 'excluded' })
    $unknown  = @($Skipped | Where-Object { $_.Reason -eq 'unknown' })
    if ($excluded.Count -gt 0) {
        Write-Info "Excluidos por ti (no se actualizan): $(($excluded | ForEach-Object Name) -join ', ')"
    }
    if ($unknown.Count -gt 0) {
        Write-Info "Omitidos porque winget no sabe qué versión tienes: $(($unknown | ForEach-Object Name) -join ', ')"
        Write-Info '  Puedes incluirlos en Configuración → Apps con versión desconocida.'
    }
}

function Show-WuTable {
    param($Updates)
    if ($Updates.Count -eq 0) { Write-Ok 'Windows está al día.'; return }
    $rows = foreach ($u in $Updates) {
        $cat = if ($u.IsDriver) { "[yellow]$(Esc $u.Category)[/]" } else { Esc $u.Category }
        [pscustomobject]@{
            Actualización = Esc $u.Title
            KB            = Esc $u.KB
            Tipo          = $cat
            Tamaño        = Format-WuSize $u.SizeMB
        }
    }
    Write-Table -Rows $rows -Title "Windows Update ($($Updates.Count))" -Wrap 'Actualización'
}

#endregion

#region Instalación

function New-ResultEntry {
    param([string]$Name, [string]$Kind, [bool]$Ok, [string]$Detail, [TimeSpan]$Duration)
    $script:Results += [pscustomobject]@{ Name = $Name; Kind = $Kind; Ok = $Ok; Detail = $Detail; Duration = $Duration }
    if ($Ok) { Write-Ok "$Name ($(Format-Duration $Duration))" } else { Write-Err "${Name}: $Detail" }
}

function New-RestorePoint {
    Write-Step 'Punto de restauración'
    if (-not (Test-SystemProtection)) {
        Write-Warn 'La Protección del sistema está desactivada en este equipo, así que no se puede crear un punto de restauración.'
        Write-Info 'Puedes activarla en Configuración → Sistema → Información → Protección del sistema, o desactivar este paso en la configuración del script.'
        return
    }
    $description = "Update-All $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    try {
        $ret = Invoke-WithSpinner 'Creando punto de restauración (puede tardar un poco)...' {
            Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint `
                -Arguments @{ Description = $description; RestorePointType = [uint32]12; EventType = [uint32]100 }
        }
        if ($ret.ReturnValue -eq 0) { Write-Ok 'Punto de restauración creado (Windows solo crea uno cada 24 h).' }
        else {
            Write-Log 'ERROR' "CreateRestorePoint devolvió $($ret.ReturnValue)"
            Write-Warn 'Windows no creó el punto de restauración; se continúa sin él.'
        }
    } catch {
        Write-Log 'ERROR' "Punto de restauración: $($_.Exception.Message)"
        Write-Warn 'No se pudo crear el punto de restauración; se continúa sin él (detalles en el registro).'
    }
}

# Contador global de progreso de la instalación ("[3/8]"), común a programas, Windows Update y Store.
function Get-ProgressTag {
    $script:StepIndex++
    return "[$($script:StepIndex)/$($script:StepTotal)]"
}

# Traducción de los estados de error de winget a mensajes comprensibles.
$script:WingetStatusText = @{
    'InstallError'                 = 'el instalador terminó con un error'
    'DownloadError'                = 'no se pudo descargar el instalador'
    'BlockedByPolicy'              = 'bloqueado por una directiva del sistema'
    'CatalogError'                 = 'no se pudo consultar el catálogo de winget'
    'NoApplicableInstallers'       = 'no hay un instalador compatible con este equipo'
    'NoApplicableUpgrade'          = 'no hay una actualización aplicable'
    'PackageAgreementsNotAccepted' = 'no se aceptaron las condiciones del paquete'
    'InternalError'                = 'error interno de winget'
    'InvalidOptions'               = 'winget rechazó las opciones de instalación'
}

function Install-AppUpdates {
    param($Apps)
    foreach ($a in $Apps) {
        $label = "$(Get-ProgressTag) $($a.Name)  $($a.Current) → $($a.Available)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $params = @{ Id = $a.Id; MatchOption = 'Equals'; Mode = 'Silent' }
            if ($a.Source)  { $params.Source = $a.Source }
            if ($a.Unknown) { $params.IncludeUnknown = $true }
            $r = Invoke-WithSpinner "$label  descargando e instalando..." { Update-WinGetPackage @params }
            $sw.Stop()
            $status = [string]$r.Status
            if ($status -eq 'Ok') {
                $detail = if ($r.RebootRequired) { 'requiere reinicio' } else { '' }
                if ($r.RebootRequired) { $script:RebootNeeded = $true }
                New-ResultEntry -Name $a.Name -Kind 'Programa' -Ok $true -Detail $detail -Duration $sw.Elapsed
            } else {
                Write-Log 'ERROR' "$($a.Id): Status=$status InstallerErrorCode=$($r.InstallerErrorCode) ExtendedErrorCode=$($r.ExtendedErrorCode)"
                $text = if ($script:WingetStatusText.ContainsKey($status)) { $script:WingetStatusText[$status] } else { "error de winget ($status)" }
                $detail = "No se pudo actualizar: $text."
                if ($r.InstallerErrorCode) { $detail += " Código $($r.InstallerErrorCode)." }
                if ($status -eq 'InstallError') { $detail += ' Si el programa estaba abierto, ciérralo y vuelve a intentarlo.' }
                New-ResultEntry -Name $a.Name -Kind 'Programa' -Ok $false -Detail $detail -Duration $sw.Elapsed
            }
        } catch {
            $sw.Stop()
            Write-Log 'ERROR' "$($a.Id): $($_ | Out-String)"
            New-ResultEntry -Name $a.Name -Kind 'Programa' -Ok $false -Detail 'Error inesperado al actualizar (detalles en el registro).' -Duration $sw.Elapsed
        }
    }
}

function Install-WindowsUpdates {
    param($Updates)
    foreach ($u in $Updates) {
        $tag  = Get-ProgressTag
        $name = $u.Title
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            if (-not $u.Update.EulaAccepted) { $u.Update.AcceptEula() }
            [void]$coll.Add($u.Update)

            if (-not $u.Update.IsDownloaded) {
                $dr = Invoke-WithSpinner "$tag Descargando $($u.Title) ($(Format-WuSize $u.SizeMB))..." {
                    $downloader = $script:WuSession.CreateUpdateDownloader()
                    $downloader.Updates = $coll
                    $downloader.Download()
                }
                if ($dr.ResultCode -notin 2, 3) {
                    Write-Log 'ERROR' "$($u.KB) descarga: ResultCode=$($dr.ResultCode) HResult=0x$('{0:X8}' -f $dr.HResult)"
                    New-ResultEntry -Name $name -Kind 'Windows Update' -Ok $false -Detail 'No se pudo descargar. Comprueba la conexión y vuelve a intentarlo.' -Duration $sw.Elapsed
                    continue
                }
            }

            $ir = Invoke-WithSpinner "$tag Instalando $($u.Title)..." {
                $installer = $script:WuSession.CreateUpdateInstaller()
                $installer.Updates = $coll
                $installer.Install()
            }
            $sw.Stop()
            if ($ir.RebootRequired) { $script:RebootNeeded = $true }
            if ($ir.ResultCode -in 2, 3) {
                $detail = if ($ir.RebootRequired) { 'requiere reinicio' } else { '' }
                New-ResultEntry -Name $name -Kind 'Windows Update' -Ok $true -Detail $detail -Duration $sw.Elapsed
            } else {
                $hr = '0x{0:X8}' -f $ir.HResult
                Write-Log 'ERROR' "$($u.KB) instalación: ResultCode=$($ir.ResultCode) HResult=$hr"
                New-ResultEntry -Name $name -Kind 'Windows Update' -Ok $false -Detail "No se pudo instalar (error $hr). Puedes reintentarlo desde Configuración de Windows → Windows Update." -Duration $sw.Elapsed
            }
        } catch {
            $sw.Stop()
            Write-Log 'ERROR' "$($u.KB): $($_ | Out-String)"
            New-ResultEntry -Name $name -Kind 'Windows Update' -Ok $false -Detail 'Error inesperado (detalles en el registro).' -Duration $sw.Elapsed
        }
    }
}

function Invoke-StoreUpdate {
    $tag = Get-ProgressTag
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ret = Invoke-WithSpinner "$tag Pidiendo a Microsoft Store que busque e instale actualizaciones..." {
            Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' |
                Invoke-CimMethod -MethodName UpdateScanMethod
        }
        $sw.Stop()
        if ($ret.ReturnValue -eq 0) {
            New-ResultEntry -Name 'Microsoft Store' -Kind 'Store' -Ok $true -Detail 'las apps se actualizan en segundo plano' -Duration $sw.Elapsed
            return
        }
        throw "código $($ret.ReturnValue)"
    } catch {
        $sw.Stop()
        Write-Log 'ERROR' "Store: $($_.Exception.Message)"
        Write-Warn 'Windows no aceptó la orden automática para la Store.'
        Write-Info 'Abriendo Microsoft Store en "Descargas y actualizaciones" para que lo hagas con un clic.'
        Start-Process 'ms-windows-store://downloadsandupdates'
        New-ResultEntry -Name 'Microsoft Store' -Kind 'Store' -Ok $true -Detail 'abierta para actualizar manualmente' -Duration $sw.Elapsed
    }
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    return $false
}

function Show-Summary {
    param([TimeSpan]$Total)
    Write-Step 'Resumen'
    if ($script:Results.Count -eq 0) { Write-Info 'No se ha instalado nada.'; return }
    $rows = foreach ($r in $script:Results) {
        $state = if ($r.Ok) { "[green]$($script:Theme.Ok) OK[/]" } else { "[red]$($script:Theme.Err) Error[/]" }
        [pscustomobject]@{
            Elemento = Esc $r.Name
            Tipo     = Esc $r.Kind
            Estado   = $state
            Tiempo   = Format-Duration $r.Duration
            Detalle  = "[grey]$(Esc $r.Detail)[/]"
        }
    }
    Write-Table -Rows $rows -Wrap 'Elemento', 'Detalle'
    $ok   = @($script:Results | Where-Object Ok).Count
    $fail = $script:Results.Count - $ok
    $color = if ($fail -gt 0) { 'yellow' } else { 'green' }
    $text = if ($fail -eq 0) { "$(Format-Count $ok 'completada' 'completadas'), sin errores" }
            else { "$(Format-Count $ok 'completada' 'completadas'), $(Format-Count $fail 'con error' 'con error')" }
    Write-SpectreHost "  [$color]$text[/] [grey]· tiempo total $(Format-Duration $Total)[/]"
    Write-Log 'SUMMARY' "$text, tiempo total $(Format-Duration $Total)"
}

#endregion

#region Flujo principal

function Invoke-UpdateRun {
    param($Config)
    $script:Results      = @()
    $script:RebootNeeded = $false
    $start = Get-Date

    Sync-WingetSettings $Config

    # 1. Comprobación
    Write-Step 'Programas (winget)'
    $appScan = Get-AppUpdates $Config
    Show-AppTable -Apps $appScan.Apps -Skipped $appScan.Skipped

    $wuUpdates = @()
    if ($Config.WindowsUpdate) {
        Write-Step 'Windows Update'
        try {
            $wuUpdates = @(Get-WindowsUpdates $Config)
            Show-WuTable $wuUpdates
        } catch {
            Write-Log 'ERROR' "Consulta de Windows Update: $($_ | Out-String)"
            Write-Err 'No se pudo consultar Windows Update. Comprueba la conexión a Internet e inténtalo más tarde.'
        }
    }

    # 2. Selección: por defecto todo menos los drivers (en -Auto, los drivers solo si están activados).
    $selectedApps = @($appScan.Apps)
    $selectedWu   = @($wuUpdates | Where-Object { -not $_.IsDriver })
    if ($Config.WindowsUpdateDrivers -and $Auto) { $selectedWu = @($wuUpdates) }
    $doStore = [bool]$Config.MicrosoftStore

    if ($appScan.Apps.Count -eq 0 -and $wuUpdates.Count -eq 0 -and -not $doStore) {
        Write-Step 'Resumen'
        Write-Ok 'No hay nada que instalar. ¡Todo al día!'
        return 'done'
    }

    if (-not $Auto -and (Test-Interactive)) {
        $plan = Read-UpdatePlan -Apps $appScan.Apps -WuUpdates $wuUpdates -SelectedApps $selectedApps -SelectedWu $selectedWu -DoStore $doStore -StoreAvailable ([bool]$Config.MicrosoftStore)
        if (-not $plan) { return 'cancelled' }
        $selectedApps = @($plan.Apps)
        $selectedWu   = @($plan.Wu)
        $doStore      = $plan.Store
    }

    $deferred     = @($selectedApps | Where-Object IsSelf)
    $selectedApps = @($selectedApps | Where-Object { -not $_.IsSelf })

    if ($script:IsDryRun) {
        Write-Step 'Simulación'
        Write-Info "Se instalaría: $(Format-Plan @($selectedApps + $deferred) $selectedWu $doStore)."
        foreach ($a in @($selectedApps + $deferred)) { Write-Info "  Programa: $($a.Name) $($a.Current) → $($a.Available)" }
        foreach ($u in $selectedWu) { Write-Info "  Windows Update: $($u.Title)" }
        Write-Ok 'Modo solo comprobar: no se ha instalado nada.'
        return 'done'
    }

    if (($selectedApps.Count + $deferred.Count + $selectedWu.Count) -eq 0 -and -not $doStore) {
        Write-Step 'Resumen'
        Write-Ok 'No hay nada que instalar. ¡Todo al día!'
        return 'done'
    }

    # 3. Instalación
    $script:StepIndex = 0
    $script:StepTotal = $selectedApps.Count + $deferred.Count + $selectedWu.Count
    if ($doStore) { $script:StepTotal++ }
    if ($Config.RestorePoint -and ($selectedWu.Count -gt 0 -or $selectedApps.Count -gt 0)) { New-RestorePoint }

    if ($selectedApps.Count -gt 0) {
        Write-Step "Instalando programas ($($selectedApps.Count))"
        Install-AppUpdates $selectedApps
    }
    if ($selectedWu.Count -gt 0) {
        Write-Step "Instalando Windows Update ($($selectedWu.Count))"
        Install-WindowsUpdates $selectedWu
    }
    if ($doStore) {
        Write-Step 'Microsoft Store'
        Invoke-StoreUpdate
    }

    Show-Summary -Total ((Get-Date) - $start)

    # 4. Paquetes que pueden cerrar esta ventana (PowerShell, winget)
    if ($deferred.Count -gt 0) {
        Write-Step 'Actualizaciones de PowerShell / winget'
        Write-Warn 'Estas actualizaciones pueden cerrar esta ventana. El resumen ya está guardado en el registro.'
        Install-AppUpdates $deferred
    }

    # 5. Reinicio
    if ($script:RebootNeeded -or (Test-PendingReboot)) {
        Write-Host ''
        Write-Warn 'Hay un reinicio pendiente para terminar de aplicar las actualizaciones.'
        if ($Auto) {
            if ($Config.AutoRebootInAutoMode) {
                Write-Info 'Reiniciando en 60 segundos (shutdown /a para cancelar)...'
                & shutdown.exe /r /t 60 /c "Update-All: reinicio para completar actualizaciones"
            }
        } elseif (Confirm-Action '¿Reiniciar ahora? (guarda antes tu trabajo abierto)' $false) {
            Restart-Computer -Force
        } else {
            Write-Info 'Recuerda reiniciar cuando puedas.'
        }
    }
    return 'done'
}

function Format-Plan {
    param($Apps, $Wu, [bool]$Store)
    $parts = @()
    if (@($Apps).Count -gt 0) { $parts += Format-Count @($Apps).Count 'programa' 'programas' }
    if (@($Wu).Count -gt 0)   { $parts += Format-Count @($Wu).Count 'actualización de Windows' 'actualizaciones de Windows' }
    if ($Store) { $parts += 'Microsoft Store' }
    if ($parts.Count -eq 0) { return 'nada marcado' }
    return $parts -join ', '
}

# Menú previo a la instalación: permite revisar y cambiar la selección cuantas veces haga falta,
# y volver al menú principal sin instalar. Devuelve el plan elegido o $null si se vuelve atrás.
function Read-UpdatePlan {
    param($Apps, $WuUpdates, $SelectedApps, $SelectedWu, [bool]$DoStore, [bool]$StoreAvailable)
    $Apps = @($Apps); $WuUpdates = @($WuUpdates)
    $SelectedApps = @($SelectedApps); $SelectedWu = @($SelectedWu)

    # Etiquetas fijas por elemento para poder volver a abrir las listas con la selección actual marcada.
    $appItems = [ordered]@{}
    foreach ($a in $Apps) {
        $note = if ($a.IsSelf) { ' [grey](se actualiza al final)[/]' } else { '' }
        $appItems["$(Esc $a.Name) [grey]$(Esc $a.Current) → $(Esc $a.Available)[/]$note"] = $a
    }
    $wuItems = [ordered]@{}
    foreach ($u in $WuUpdates) {
        $tag = if ($u.IsDriver) { '[yellow](driver)[/] ' } else { '' }
        $wuItems["$tag$(Esc $u.Title) [grey]$(Format-WuSize $u.SizeMB)[/]"] = $u
    }

    Write-Step 'Elige qué instalar'
    while ($true) {
        $planText = Format-Plan $SelectedApps $SelectedWu $DoStore
        $options = [ordered]@{}
        $goLabel = if ($script:IsDryRun) { "Ver qué se instalaría: $planText" } else { "Empezar a instalar: $planText" }
        $options['go'] = "[green]$(Esc $goLabel)[/]"
        if ($Apps.Count -gt 0)      { $options['apps'] = "Elegir programas [grey]($($SelectedApps.Count) de $($Apps.Count) marcados)[/]" }
        if ($WuUpdates.Count -gt 0) { $options['wu']   = "Elegir actualizaciones de Windows [grey]($($SelectedWu.Count) de $($WuUpdates.Count) marcadas)[/]" }
        if ($StoreAvailable) {
            $storeState = if ($DoStore) { 'Sí' } else { 'No' }
            $options['store'] = "Actualizar apps de Microsoft Store: $storeState [grey](pulsa para cambiar)[/]"
        }
        $options['back'] = '← Volver al menú principal sin instalar'

        switch (Read-Choice -Title '¿Qué quieres hacer?' -Options $options) {
            'go' {
                if (($SelectedApps.Count + $SelectedWu.Count) -eq 0 -and -not $DoStore) {
                    Write-Warn 'No has marcado nada para instalar.'
                    continue
                }
                Write-Info "Selección: $planText."
                return [pscustomobject]@{ Apps = $SelectedApps; Wu = $SelectedWu; Store = $DoStore }
            }
            'apps' {
                $pre = @($appItems.Keys | Where-Object { $SelectedApps -contains $appItems[$_] })
                $SelectedApps = @(Read-Checklist -Title 'Programas a actualizar:' -Items $appItems -Preselected $pre)
                Write-Info "Programas: $($SelectedApps.Count) de $($Apps.Count) marcados."
            }
            'wu' {
                $pre = @($wuItems.Keys | Where-Object { $SelectedWu -contains $wuItems[$_] })
                $title = 'Actualizaciones de Windows a instalar:'
                if (@($WuUpdates | Where-Object IsDriver).Count -gt 0) { $title += ' [grey](los drivers vienen sin marcar: elige solo los que necesites)[/]' }
                $SelectedWu = @(Read-Checklist -Title $title -Items $wuItems -Preselected $pre)
                Write-Info "Windows Update: $($SelectedWu.Count) de $($WuUpdates.Count) marcadas."
            }
            'store' {
                $DoStore = -not $DoStore
                $storeState = if ($DoStore) { 'Sí' } else { 'No' }
                Write-Info "Microsoft Store: $storeState."
            }
            'back' {
                Write-Info 'Vuelta al menú principal. No se ha instalado nada.'
                return $null
            }
        }
    }
}

function Start-UpdateAll {
    $script:IsDryRun = [bool]$DryRun
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
    $script:LogFile = Join-Path $script:LogDir ("Update-All_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
    Write-Log 'START' "Auto=$Auto DryRun=$DryRun PS=$($PSVersionTable.PSVersion)"

    Initialize-Theme
    $config = Get-Config
    if (-not (Test-Path $script:ConfigPath) -and -not $script:IsDryRun) { Save-Config $config }

    Show-Header

    if ($Settings) { $config = Show-SettingsMenu $config; Show-Header; Write-Notice }

    if ($Auto -or $script:IsDryRun -or -not (Test-Interactive)) {
        [void](Invoke-UpdateRun $config)
        return
    }

    while ($true) {
        Write-Host ''
        $choice = Read-Choice -Title '¿Qué quieres hacer?' -Options ([ordered]@{
            run      = "$($script:Theme.Run)Buscar e instalar actualizaciones"
            check    = "$($script:Theme.Check)Solo comprobar (no instala nada)"
            settings = "$($script:Theme.Gear)Configuración"
            quit     = "$($script:Theme.Quit)Salir"
        })
        switch ($choice) {
            'run' {
                # Tras una instalación real se termina (el resumen queda en pantalla); si se vuelve atrás, al menú.
                if ((Invoke-UpdateRun $config) -eq 'done') { return }
            }
            'check' {
                $script:IsDryRun = $true
                try { [void](Invoke-UpdateRun $config) } finally { $script:IsDryRun = [bool]$DryRun }
            }
            'settings' { $config = Show-SettingsMenu $config; Show-Header; Write-Notice }
            'quit'     { $script:UserQuit = $true; return }
        }
    }
}

#endregion

Invoke-Bootstrap
# La codificación debe fijarse antes de importar PwshSpectreConsole: la consola de Spectre la captura al cargarse.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Initialize-Dependencies

$exitCode = 0
try {
    Start-UpdateAll
    if (@($script:Results | Where-Object { -not $_.Ok }).Count -gt 0) { $exitCode = 2 }
} catch {
    Write-Log 'ERROR' ($_ | Out-String)
    Write-Err "Algo ha fallado y el script se ha detenido: $($_.Exception.Message)"
    Write-Info 'Los detalles técnicos están en el registro indicado abajo.'
    $exitCode = 1
} finally {
    if ($script:LogFile) { Write-SpectreHost "  [grey]Registro guardado en: $(Esc $script:LogFile)[/]" }
    # Pausa para que no se cierre la ventana nueva sin leer el resultado (salvo si el usuario eligió Salir).
    if ($Relaunched -and -not $Auto -and -not $script:UserQuit -and (Test-Interactive)) {
        Read-SpectrePause -Message '[grey]Pulsa cualquier tecla para cerrar la ventana...[/]'
    }
}
exit $exitCode
