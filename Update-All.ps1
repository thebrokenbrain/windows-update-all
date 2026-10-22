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
$script:AppVersion = '1.0.0'
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
            Write-Warn "No se pudo leer la configuración ($($_.Exception.Message)). Se usan valores por defecto."
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
            if ($script:IsDryRun) {
                Write-Info "Se cambiaría el modo de descarga de winget a '$($Config.WingetDownloader)'."
            } else {
                Set-WinGetUserSetting -UserSettings @{ network = @{ downloader = $Config.WingetDownloader } } -Merge | Out-Null
                Write-Ok "Modo de descarga de winget: $($Config.WingetDownloader)"
            }
        }
    } catch {
        Write-Warn "No se pudo ajustar la configuración de winget: $($_.Exception.Message)"
    }
}

function Show-SettingsMenu {
    param($Config)
    $downloaderLabels = [ordered]@{
        'wininet' = 'WinINet (descarga directa, rápida)'
        'do'      = 'Delivery Optimization (la de Windows Update)'
        'default' = 'Por defecto de winget'
    }
    while ($true) {
        Clear-Screen
        Write-SpectreRule -Title '[bold]Configuración[/]' -Color 'DeepSkyBlue1'
        $excluded = if ($Config.ExcludedIds.Count) { "$($Config.ExcludedIds.Count) programa(s)" } else { 'ninguno' }
        $options = [ordered]@{
            'downloader' = "Modo de descarga de winget:        [aqua]$(Esc $downloaderLabels[$Config.WingetDownloader])[/]"
            'unknown'    = "Incluir apps con versión desconocida: $(Format-Bool $Config.IncludeUnknownVersions)"
            'excluded'   = "Programas excluidos:               [aqua]$excluded[/]"
            'wu'         = "Windows Update:                    $(Format-Bool $Config.WindowsUpdate)"
            'drivers'    = "Drivers de Windows Update:         $(Format-Bool $Config.WindowsUpdateDrivers)"
            'store'      = "Microsoft Store:                   $(Format-Bool $Config.MicrosoftStore)"
            'restore'    = "Punto de restauración previo:      $(Format-Bool $Config.RestorePoint)"
            'reboot'     = "Reiniciar solo en modo -Auto:      $(Format-Bool $Config.AutoRebootInAutoMode)"
            'save'       = '[green]Guardar y volver[/]'
            'cancel'     = '[grey]Volver sin guardar[/]'
        }
        $choice = Read-Choice -Title 'Elige un ajuste para cambiarlo:' -Options $options
        switch ($choice) {
            'downloader' {
                $Config.WingetDownloader = Read-Choice -Title 'Modo de descarga de winget:' -Options $downloaderLabels
            }
            'unknown'  { $Config.IncludeUnknownVersions = -not $Config.IncludeUnknownVersions }
            'wu'       { $Config.WindowsUpdate          = -not $Config.WindowsUpdate }
            'drivers'  { $Config.WindowsUpdateDrivers   = -not $Config.WindowsUpdateDrivers }
            'store'    { $Config.MicrosoftStore         = -not $Config.MicrosoftStore }
            'restore'  { $Config.RestorePoint           = -not $Config.RestorePoint }
            'reboot'   { $Config.AutoRebootInAutoMode   = -not $Config.AutoRebootInAutoMode }
            'excluded' { $Config.ExcludedIds = @(Edit-Exclusions -Current $Config.ExcludedIds) }
            'save'     { Save-Config $Config; Write-Ok 'Configuración guardada.'; return $Config }
            'cancel'   { return (Get-Config) }
        }
    }
}

function Edit-Exclusions {
    param([string[]]$Current)
    $packages = Invoke-WithSpinner 'Leyendo programas instalados...' { @(Get-WinGetPackage | Where-Object { $_.Source }) }
    $items = [ordered]@{}
    foreach ($id in $Current) { $items["$(Esc $id)"] = $id }
    foreach ($p in ($packages | Sort-Object Name)) {
        if ($Current -notcontains $p.Id) { $items["$(Esc $p.Name) [grey]($(Esc $p.Id))[/]"] = $p.Id }
    }
    $preselected = @($Current | ForEach-Object { Esc $_ })
    return Read-Checklist -Title 'Marca los programas que [yellow]NO[/] quieres actualizar nunca:' -Items $items -Preselected $preselected
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

function Write-Step {
    param([string]$Title)
    Write-Host ''
    Write-SpectreRule -Title "[bold]$(Esc $Title)[/]" -Alignment Left -Color 'DeepSkyBlue1'
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
    $table | Out-SpectreHost
}

function Read-Choice {
    param([string]$Title, [System.Collections.IDictionary]$Options)
    $labels = @($Options.Values)
    $selected = Read-SpectreSelection -Message $Title -Choices $labels -PageSize 12 -Color 'DeepSkyBlue1'
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
    $prompt.InstructionsText = '[grey](Espacio: marcar/desmarcar · Intro: confirmar)[/]'
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
    $answer = if ($Default) { 'y' } else { 'n' }
    return Read-SpectreConfirm -Message $Message -DefaultAnswer $answer -Color 'DeepSkyBlue1'
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds }
    return '{0:0.0}s' -f $Span.TotalSeconds
}

function Show-Header {
    Clear-Screen
    Write-SpectreFigletText -Text 'Update-All' -Color 'DeepSkyBlue1'
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
    Format-SpectrePanel -Data ($lines -join "`n") -Header " v$script:AppVersion " -Border $script:Theme.Border -Color 'Grey' | Out-SpectreHost
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
        }
        if ($Config.ExcludedIds -contains $p.Id) { $skipped += $item; continue }
        if ($unknown -and -not $Config.IncludeUnknownVersions) { $skipped += $item; continue }
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
    if ($Skipped.Count -gt 0) {
        $names = ($Skipped | ForEach-Object { $_.Name }) -join ', '
        Write-Info "Omitidos por configuración (excluidos o versión desconocida): $names"
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
    $description = "Update-All $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    try {
        $ret = Invoke-WithSpinner 'Creando punto de restauración (puede tardar un poco)...' {
            Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint `
                -Arguments @{ Description = $description; RestorePointType = [uint32]12; EventType = [uint32]100 }
        }
        if ($ret.ReturnValue -eq 0) { Write-Ok 'Punto de restauración creado (Windows solo crea uno cada 24 h).' }
        else { Write-Warn "No se creó el punto de restauración (código $($ret.ReturnValue)). ¿Está activada la Protección del sistema en C:?" }
    } catch {
        Write-Warn "No se pudo crear el punto de restauración: $($_.Exception.Message)"
    }
}

function Install-AppUpdates {
    param($Apps)
    $i = 0
    foreach ($a in $Apps) {
        $i++
        $label = "[$i/$($Apps.Count)] $($a.Name)  $($a.Current) → $($a.Available)"
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
                $detail = "$status (código $($r.InstallerErrorCode)). Si el programa estaba abierto, ciérralo y reinténtalo."
                New-ResultEntry -Name $a.Name -Kind 'Programa' -Ok $false -Detail $detail -Duration $sw.Elapsed
            }
        } catch {
            $sw.Stop()
            New-ResultEntry -Name $a.Name -Kind 'Programa' -Ok $false -Detail $_.Exception.Message -Duration $sw.Elapsed
        }
    }
}

function Install-WindowsUpdates {
    param($Updates)
    $i = 0
    foreach ($u in $Updates) {
        $i++
        $name = if ($u.KB) { "$($u.KB) $($u.Title)" } else { $u.Title }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            if (-not $u.Update.EulaAccepted) { $u.Update.AcceptEula() }
            [void]$coll.Add($u.Update)

            if (-not $u.Update.IsDownloaded) {
                $dr = Invoke-WithSpinner "[$i/$($Updates.Count)] Descargando $($u.Title) ($(Format-WuSize $u.SizeMB))..." {
                    $downloader = $script:WuSession.CreateUpdateDownloader()
                    $downloader.Updates = $coll
                    $downloader.Download()
                }
                if ($dr.ResultCode -notin 2, 3) { throw "falló la descarga (código $($dr.ResultCode))" }
            }

            $ir = Invoke-WithSpinner "[$i/$($Updates.Count)] Instalando $($u.Title)..." {
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
                New-ResultEntry -Name $name -Kind 'Windows Update' -Ok $false -Detail "falló la instalación (código $($ir.ResultCode), HRESULT 0x$('{0:X8}' -f $ir.HResult))" -Duration $sw.Elapsed
            }
        } catch {
            $sw.Stop()
            New-ResultEntry -Name $name -Kind 'Windows Update' -Ok $false -Detail $_.Exception.Message -Duration $sw.Elapsed
        }
    }
}

function Invoke-StoreUpdate {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ret = Invoke-WithSpinner 'Pidiendo a Microsoft Store que busque e instale actualizaciones...' {
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
        Write-Warn "No se pudo lanzar la actualización automática de la Store ($($_.Exception.Message))."
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
    Write-SpectreHost "  [$color]$ok correctas, $fail con error[/] [grey]· tiempo total $(Format-Duration $Total)[/]"
    Write-Log 'SUMMARY' "$ok correctas, $fail con error, tiempo total $(Format-Duration $Total)"
}

#endregion

#region Flujo principal

function Invoke-UpdateRun {
    param($Config)
    $script:Results      = @()
    $script:RebootNeeded = $false
    $start = Get-Date

    Write-Step 'Preparación'
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
            Write-Err "No se pudo consultar Windows Update: $($_.Exception.Message)"
        }
    }

    # 2. Selección
    $selectedApps = @($appScan.Apps)
    $selectedWu   = @($wuUpdates | Where-Object { -not $_.IsDriver })
    if ($Config.WindowsUpdateDrivers -and $Auto) { $selectedWu = @($wuUpdates) }

    if (-not $Auto -and (Test-Interactive)) {
        if ($appScan.Apps.Count -gt 0) {
            $items = [ordered]@{}
            foreach ($a in $appScan.Apps) { $items["$(Esc $a.Name) [grey]$(Esc $a.Current) → $(Esc $a.Available)[/]"] = $a }
            $selectedApps = @(Read-Checklist -Title 'Programas a actualizar:' -Items $items -Preselected @($items.Keys))
        }
        if ($wuUpdates.Count -gt 0) {
            $items = [ordered]@{}; $pre = @()
            foreach ($u in $wuUpdates) {
                $tag = if ($u.IsDriver) { '[yellow](driver)[/] ' } else { '' }
                $label = "$tag$(Esc $u.Title) [grey]$(Format-WuSize $u.SizeMB)[/]"
                $items[$label] = $u
                if (-not $u.IsDriver) { $pre += $label }
            }
            $selectedWu = @(Read-Checklist -Title 'Actualizaciones de Windows a instalar [grey](los drivers vienen sin marcar)[/]:' -Items $items -Preselected $pre)
        }
    }

    $doStore = $false
    if ($Config.MicrosoftStore -and -not $script:IsDryRun) {
        $doStore = Confirm-Action '¿Actualizar también las apps de Microsoft Store?' $true
    }

    $deferred     = @($selectedApps | Where-Object IsSelf)
    $selectedApps = @($selectedApps | Where-Object { -not $_.IsSelf })
    $totalWork    = $selectedApps.Count + $deferred.Count + $selectedWu.Count

    if ($script:IsDryRun) {
        Write-Step 'Simulación'
        Write-Info "Se actualizarían $($selectedApps.Count + $deferred.Count) programa(s) y $($selectedWu.Count) actualización(es) de Windows."
        foreach ($a in @($selectedApps + $deferred)) { Write-Info "  Programa: $($a.Name) $($a.Current) → $($a.Available)" }
        foreach ($u in $selectedWu) { Write-Info "  Windows Update: $($u.Title)" }
        if ($Config.MicrosoftStore) { Write-Info 'Se pediría a Microsoft Store que actualice sus apps.' }
        Write-Info 'Modo solo comprobar: no se ha instalado nada.'
        return
    }

    if ($totalWork -eq 0 -and -not $doStore) {
        Write-Step 'Resumen'
        Write-Ok 'No hay nada que instalar. ¡Todo al día!'
        return
    }

    if (-not (Confirm-Action "¿Empezar? ($($selectedApps.Count + $deferred.Count) programas, $($selectedWu.Count) de Windows Update$(if ($doStore) { ', Store' }))" $true)) {
        Write-Warn 'Cancelado por el usuario.'
        return
    }

    # 3. Instalación
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
        } elseif (Confirm-Action '¿Reiniciar ahora?' $false) {
            Restart-Computer -Force
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

    if ($Settings) { $config = Show-SettingsMenu $config }

    if ($Auto -or $script:IsDryRun -or -not (Test-Interactive)) {
        Invoke-UpdateRun $config
        return
    }

    while ($true) {
        Write-Host ''
        $choice = Read-Choice -Title '¿Qué quieres hacer?' -Options ([ordered]@{
            run      = "$($script:Theme.Run)Buscar e instalar actualizaciones"
            check    = "$($script:Theme.Check)Solo comprobar (sin instalar)"
            settings = "$($script:Theme.Gear)Configuración"
            quit     = "$($script:Theme.Quit)Salir"
        })
        switch ($choice) {
            'run'      { Invoke-UpdateRun $config; return }
            'check'    { $script:IsDryRun = $true; Invoke-UpdateRun $config; $script:IsDryRun = [bool]$DryRun }
            'settings' { $config = Show-SettingsMenu $config; Show-Header }
            'quit'     { return }
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
    Write-Err "Error inesperado: $($_.Exception.Message)"
    Write-Log 'ERROR' ($_ | Out-String)
    $exitCode = 1
} finally {
    if ($script:LogFile) { Write-SpectreHost "  [grey]Registro guardado en: $(Esc $script:LogFile)[/]" }
    if ($Relaunched -and -not $Auto -and (Test-Interactive)) { Read-SpectrePause -Message '[grey]Pulsa cualquier tecla para cerrar...[/]' }
}
exit $exitCode
