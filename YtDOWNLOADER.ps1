# YtDOWNLOADER.ps1
# YtDOWNLOADER by OsageP - Version 1.0.
# Cambio principal: no usa eventos asincronos de OutputDataReceived.
# La descarga se lanza con Start-Process y la UI lee stdout/stderr desde archivos temporales con un Timer.
# Esto evita cierres de PowerShell/WinForms al recibir progreso de yt-dlp.

$ErrorActionPreference = 'Stop'

$Script:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Script:AppName = 'YtDOWNLOADER by OsageP'
$Script:AppVersion = '1.0'
$Script:YtDlp  = Join-Path $Script:AppDir 'yt-dlp.exe'
$Script:Ffmpeg = Join-Path $Script:AppDir 'ffmpeg.exe'
$Script:Ffprobe = Join-Path $Script:AppDir 'ffprobe.exe'
$Script:Deno = Join-Path $Script:AppDir 'deno.exe'
$Script:IconPath = Join-Path $Script:AppDir 'assets\YtDOWNLOADER.ico'
$Script:ErrorLog = Join-Path $Script:AppDir 'YtDOWNLOADER_error.log'
$Script:DebugLog = Join-Path $Script:AppDir 'YtDOWNLOADER_debug.log'
$Script:ConfigFile = Join-Path $Script:AppDir 'YtDOWNLOADER_config.json'
$Script:HistoryFile = Join-Path $Script:AppDir 'YtDOWNLOADER_history.jsonl'
$Script:Config = $null
$Script:CurrentProcess = $null
$Script:IsDownloading = $false
$Script:LastFolder = $null
$Script:StdoutFile = $null
$Script:StderrFile = $null
$Script:StdoutLineCount = 0
$Script:StderrLineCount = 0
$Script:DownloadTimer = $null
$Script:StartTime = $null
$Script:PlaylistCurrent = $null
$Script:PlaylistTotal = $null
$Script:CurrentOutputName = ''
$Script:CancellationRequested = $false


function Limit-LogFile {
    param([string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $item) { return }

        # Evita que los logs crezcan sin limite. Mantiene solo las ultimas lineas.
        $maxBytes = 5MB
        if ($item.Length -le $maxBytes) { return }

        $lines = Get-Content -LiteralPath $Path -Tail 1500 -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -eq $lines) { $lines = @() }
        Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8 -Force
        Add-Content -LiteralPath $Path -Value ('[{0}] Log recortado automaticamente por superar 5 MB.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
    } catch {}
}

function Format-BytesHuman {
    param([double]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Write-AppLog {
    param([string]$Text)
    try {
        Limit-LogFile -Path $Script:ErrorLog
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
        Add-Content -LiteralPath $Script:ErrorLog -Value $line -Encoding UTF8
    } catch {}
}

function Write-DebugLog {
    param([string]$Text)
    try {
        Limit-LogFile -Path $Script:DebugLog
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
        Add-Content -LiteralPath $Script:DebugLog -Value $line -Encoding UTF8
    } catch {}
}

Write-AppLog ('Aplicacion iniciada. ' + $Script:AppName + ' - Version ' + $Script:AppVersion + '.')

function Show-ErrorMessage {
    param(
        [string]$Title,
        [string]$Message
    )

    Write-AppLog "$Title - $Message"
    try {
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        Write-Host $Message
    }
}

function Invoke-ExternalCheck {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$Arguments
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return @{ Ok = $false; ExitCode = -999; Output = "No existe: $FilePath" }
    }

    $stdout = Join-Path $env:TEMP ('ytdl_check_out_' + [guid]::NewGuid().ToString('N') + '.txt')
    $stderr = Join-Path $env:TEMP ('ytdl_check_err_' + [guid]::NewGuid().ToString('N') + '.txt')

    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $Script:AppDir -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        $out = ''
        if (Test-Path -LiteralPath $stdout) { $out += (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path -LiteralPath $stderr) { $out += (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue) }
        return @{ Ok = ($p.ExitCode -eq 0); ExitCode = $p.ExitCode; Output = $out }
    }
    catch {
        return @{ Ok = $false; ExitCode = -998; Output = $_.Exception.Message }
    }
    finally {
        try { Remove-Item -LiteralPath $stdout -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Test-YtDlpExe {
    if (-not (Test-Path -LiteralPath $Script:YtDlp)) { return $false }
    $r = Invoke-ExternalCheck -FilePath $Script:YtDlp -Arguments '--version'
    if (-not $r.Ok) {
        Write-AppLog "yt-dlp.exe no pasa validacion. ExitCode=$($r.ExitCode). Output=$($r.Output)"
    }
    return [bool]$r.Ok
}

function Test-FfmpegExe {
    if (-not (Test-Path -LiteralPath $Script:Ffmpeg)) { return $false }
    $r = Invoke-ExternalCheck -FilePath $Script:Ffmpeg -Arguments '-version'
    if (-not $r.Ok) {
        Write-AppLog "ffmpeg.exe no pasa validacion. ExitCode=$($r.ExitCode). Output=$($r.Output)"
    }
    return [bool]$r.Ok
}

function Test-DenoExe {
    if (-not (Test-Path -LiteralPath $Script:Deno)) { return $false }
    $r = Invoke-ExternalCheck -FilePath $Script:Deno -Arguments '--version'
    if (-not $r.Ok) {
        Write-AppLog "deno.exe no pasa validacion. ExitCode=$($r.ExitCode). Output=$($r.Output)"
        return $false
    }

    # yt-dlp recomienda Deno 2.3.0 o superior para EJS. Si no se puede leer la version,
    # lo dejamos pasar igualmente porque --version ya ha arrancado correctamente.
    try {
        $firstLine = (($r.Output -split "`r?`n") | Select-Object -First 1)
        if ($firstLine -match 'deno\s+(\d+)\.(\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 3)) {
                Write-AppLog "deno.exe detectado, pero parece antiguo: $firstLine"
                return $false
            }
        }
    } catch {}

    return $true
}

function Download-File {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -ErrorAction Stop
    }
    finally {
        $ProgressPreference = $oldProgress
    }
}

function Install-YtDlp {
    $needInstall = $true
    if (Test-Path -LiteralPath $Script:YtDlp) {
        if (Test-YtDlpExe) {
            Write-Host 'yt-dlp.exe comprobado correctamente.'
            $needInstall = $false
        } else {
            Write-Host 'yt-dlp.exe existe, pero no arranca. Se descargara de nuevo...'
            try { Remove-Item -LiteralPath $Script:YtDlp -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    if (-not $needInstall) { return }

    Write-Host 'Descargando yt-dlp.exe...'
    Write-AppLog 'Descargando yt-dlp.exe.'
    $tmp = Join-Path $env:TEMP ('yt-dlp-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        $url = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
        Download-File -Url $url -Destination $tmp
        Copy-Item -LiteralPath $tmp -Destination $Script:YtDlp -Force -ErrorAction Stop

        if (-not (Test-YtDlpExe)) {
            throw 'yt-dlp.exe se descargo, pero Windows no puede ejecutarlo. Revisa antivirus, SmartScreen o arquitectura del sistema.'
        }

        Write-Host 'yt-dlp.exe instalado correctamente.'
        Write-AppLog 'yt-dlp.exe instalado correctamente.'
    }
    finally {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Install-Ffmpeg {
    $needInstall = $true
    if (Test-Path -LiteralPath $Script:Ffmpeg) {
        if (Test-FfmpegExe) {
            Write-Host 'ffmpeg.exe comprobado correctamente.'
            $needInstall = $false
        } else {
            Write-Host 'ffmpeg.exe existe, pero no arranca. Se descargara de nuevo...'
            foreach ($name in @('ffmpeg.exe','ffprobe.exe','ffplay.exe')) {
                $target = Join-Path $Script:AppDir $name
                try { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue } catch {}
            }
            Get-ChildItem -LiteralPath $Script:AppDir -File -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }

    if (-not $needInstall) { return }

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Esta version automatica de FFmpeg esta preparada para Windows de 64 bits. En Windows 32 bits hay que instalar FFmpeg manualmente.'
    }

    Write-Host 'Descargando FFmpeg. Puede tardar un poco...'
    Write-AppLog 'Descargando FFmpeg desde yt-dlp/FFmpeg-Builds.'

    $zipPath = Join-Path $env:TEMP ('ffmpeg-ytdlp-' + [guid]::NewGuid().ToString('N') + '.zip')
    $extractDir = Join-Path $env:TEMP ('ffmpeg_ytdlp_extract_' + [guid]::NewGuid().ToString('N'))

    try {
        $url = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
        Download-File -Url $url -Destination $zipPath

        if (-not (Test-Path -LiteralPath $zipPath)) {
            throw 'El ZIP de FFmpeg no se descargo correctamente.'
        }

        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop

        $ffmpegFile = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ffmpegFile) {
            throw 'No se encontro ffmpeg.exe dentro del ZIP descargado.'
        }

        $binDir = Split-Path -Parent $ffmpegFile.FullName
        foreach ($name in @('ffmpeg.exe','ffprobe.exe','ffplay.exe')) {
            $src = Join-Path $binDir $name
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $Script:AppDir $name) -Force -ErrorAction Stop
            }
        }

        Get-ChildItem -LiteralPath $binDir -File -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Script:AppDir $_.Name) -Force -ErrorAction Stop
        }

        if (-not (Test-FfmpegExe)) {
            throw "ffmpeg.exe se copio, pero Windows no puede ejecutarlo. Detalle en: $Script:ErrorLog"
        }

        Write-Host 'FFmpeg instalado correctamente.'
        Write-AppLog 'FFmpeg instalado correctamente.'
    }
    finally {
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}


function Install-Deno {
    $needInstall = $true
    if (Test-Path -LiteralPath $Script:Deno) {
        if (Test-DenoExe) {
            Write-Host 'deno.exe comprobado correctamente.'
            $needInstall = $false
        } else {
            Write-Host 'deno.exe existe, pero no arranca o es antiguo. Se descargara de nuevo...'
            try { Remove-Item -LiteralPath $Script:Deno -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    if (-not $needInstall) { return }

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Esta version automatica de Deno esta preparada para Windows de 64 bits. En Windows 32 bits hay que instalar Deno manualmente.'
    }

    Write-Host 'Descargando Deno para compatibilidad actual con YouTube...'
    Write-AppLog 'Descargando deno.exe para yt-dlp EJS.'

    $zipPath = Join-Path $env:TEMP ('deno-' + [guid]::NewGuid().ToString('N') + '.zip')
    $extractDir = Join-Path $env:TEMP ('deno_extract_' + [guid]::NewGuid().ToString('N'))

    try {
        $url = 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip'
        Download-File -Url $url -Destination $zipPath

        if (-not (Test-Path -LiteralPath $zipPath)) {
            throw 'El ZIP de Deno no se descargo correctamente.'
        }

        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop

        $denoFile = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter 'deno.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $denoFile) {
            throw 'No se encontro deno.exe dentro del ZIP descargado.'
        }

        Copy-Item -LiteralPath $denoFile.FullName -Destination $Script:Deno -Force -ErrorAction Stop

        if (-not (Test-DenoExe)) {
            throw 'deno.exe se descargo, pero Windows no puede ejecutarlo o la version no es compatible.'
        }

        Write-Host 'Deno instalado correctamente.'
        Write-AppLog 'Deno instalado correctamente.'
    }
    finally {
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Install-Dependencies {
    try {
        Install-YtDlp
        Install-Ffmpeg
        Install-Deno
    }
    catch {
        $msg = $_.Exception.Message
        Write-AppLog "Error preparando dependencias: $msg"
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show(
                "Error preparando dependencias:`r`n`r`n$msg`r`n`r`nRevisa el archivo:`r`n$Script:ErrorLog",
                'Error de instalacion',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        } catch {}
        Write-Host "Error preparando dependencias: $msg"
        exit 1
    }
}

function Get-DownloadsFolder {
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace('shell:Downloads')
        if ($folder -and $folder.Self -and $folder.Self.Path) {
            return $folder.Self.Path
        }
    } catch {}

    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')
}


function Get-DefaultConfig {
    $cfg = [ordered]@{}
    $cfg['DownloadFolder'] = Get-DownloadsFolder
    $cfg['Mode'] = 'Video'
    $cfg['Quality'] = 'Mejor calidad disponible'
    $cfg['AudioQuality'] = 'Mejor calidad MP3 (0)'
    $cfg['DownloadPlaylist'] = $false
    $cfg['EnableHistory'] = $false
    $cfg['Theme'] = 'Sistema'
    $cfg['OpenFolderWhenFinished'] = $false
    $cfg['FileNameTemplate'] = 'Titulo + ID'
    $cfg['UseSubfolders'] = $false
    $cfg['ShowAdvanced'] = $false
    $cfg['CookiesBrowser'] = 'No usar'
    return $cfg
}

function Load-AppConfig {
    $cfg = Get-DefaultConfig
    $isFirstRun = -not (Test-Path -LiteralPath $Script:ConfigFile)

    if (-not $isFirstRun) {
        try {
            $raw = Get-Content -LiteralPath $Script:ConfigFile -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $json = $raw | ConvertFrom-Json -ErrorAction Stop
                foreach ($key in @($cfg.Keys)) {
                    if ($json.PSObject.Properties.Name -contains $key) {
                        $propValue = $json.PSObject.Properties[$key].Value
                        if ($null -ne $propValue) { $cfg[$key] = $propValue }
                    }
                }
            }
        }
        catch {
            Write-AppLog "No se pudo leer configuracion. Se usaran valores por defecto. Error: $($_.Exception.Message)"
            $isFirstRun = $true
        }
    }

    $cfg['IsFirstRun'] = [bool]$isFirstRun
    $Script:Config = $cfg
    return $cfg
}

function Save-AppConfig {
    try {
        if ($null -eq $Script:Config) { $Script:Config = Get-DefaultConfig }
        $toSave = [ordered]@{}
        foreach ($key in @('DownloadFolder','Mode','Quality','AudioQuality','DownloadPlaylist','EnableHistory','Theme','OpenFolderWhenFinished','FileNameTemplate','UseSubfolders','ShowAdvanced','CookiesBrowser')) {
            if ($Script:Config.Contains($key)) { $toSave[$key] = $Script:Config[$key] }
        }
        ([pscustomobject]$toSave | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Script:ConfigFile -Encoding UTF8
        $Script:Config['IsFirstRun'] = $false
        Write-AppLog "Configuracion guardada en $Script:ConfigFile"
    }
    catch {
        Write-AppLog "No se pudo guardar configuracion: $($_.Exception.Message)"
        throw
    }
}

function Get-ConfigString {
    param([string]$Name, [string]$Default = '')
    try {
        if ($Script:Config -and $Script:Config.Contains($Name) -and $null -ne $Script:Config[$Name] -and ([string]$Script:Config[$Name]).Trim() -ne '') {
            return [string]$Script:Config[$Name]
        }
    } catch {}
    return $Default
}

function Get-ConfigBool {
    param([string]$Name, [bool]$Default = $false)
    try {
        if ($Script:Config -and $Script:Config.Contains($Name) -and $null -ne $Script:Config[$Name]) {
            if ($Script:Config[$Name] -is [bool]) { return [bool]$Script:Config[$Name] }
            return ([string]$Script:Config[$Name]).Trim().ToLowerInvariant() -in @('true','1','yes','si','sí')
        }
    } catch {}
    return $Default
}

function Get-SystemThemeName {
    try {
        $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $value = Get-ItemPropertyValue -Path $path -Name AppsUseLightTheme -ErrorAction Stop
        if ([int]$value -eq 0) { return 'Oscuro' }
    } catch {}
    return 'Claro'
}

function Resolve-AppThemeName {
    param([string]$Theme)
    if ([string]::IsNullOrWhiteSpace($Theme) -or $Theme -eq 'Sistema') {
        return Get-SystemThemeName
    }
    if ($Theme -eq 'Oscuro') { return 'Oscuro' }
    return 'Claro'
}

function Get-AppThemeColors {
    param([string]$Theme)
    $resolved = Resolve-AppThemeName -Theme $Theme
    if ($resolved -eq 'Oscuro') {
        return @{
            Name = 'Oscuro'
            Form = [System.Drawing.Color]::FromArgb(31, 31, 36)
            Surface = [System.Drawing.Color]::FromArgb(42, 42, 48)
            Input = [System.Drawing.Color]::FromArgb(50, 50, 56)
            LogBack = [System.Drawing.Color]::FromArgb(24, 24, 28)
            Text = [System.Drawing.Color]::FromArgb(242, 242, 242)
            Muted = [System.Drawing.Color]::FromArgb(190, 190, 190)
            Button = [System.Drawing.Color]::FromArgb(64, 64, 72)
            Link = [System.Drawing.Color]::FromArgb(88, 166, 255)
        }
    }

    return @{
        Name = 'Claro'
        Form = [System.Drawing.Color]::FromArgb(245, 247, 250)
        Surface = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Input = [System.Drawing.Color]::FromArgb(255, 255, 255)
        LogBack = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Text = [System.Drawing.Color]::FromArgb(32, 32, 32)
        Muted = [System.Drawing.Color]::FromArgb(90, 90, 90)
        Button = [System.Drawing.SystemColors]::Control
        Link = [System.Drawing.Color]::FromArgb(0, 102, 204)
    }
}

function Apply-AppThemeToControl {
    param($Control)
    if ($null -eq $Control) { return }

    $colors = Get-AppThemeColors -Theme (Get-ConfigString 'Theme' 'Sistema')
    try {
        if ($Control -is [System.Windows.Forms.Form]) {
            $Control.BackColor = $colors.Form
            $Control.ForeColor = $colors.Text
        } elseif ($Control -is [System.Windows.Forms.TextBox]) {
            if ($Control.ReadOnly -and $Control.Multiline) {
                $Control.BackColor = $colors.LogBack
            } else {
                $Control.BackColor = $colors.Input
            }
            $Control.ForeColor = $colors.Text
            $Control.BorderStyle = 'FixedSingle'
        } elseif ($Control -is [System.Windows.Forms.ComboBox]) {
            $Control.BackColor = $colors.Input
            $Control.ForeColor = $colors.Text
        } elseif ($Control -is [System.Windows.Forms.Button]) {
            $Control.BackColor = $colors.Button
            $Control.ForeColor = $colors.Text
            $Control.UseVisualStyleBackColor = $false
        } elseif ($Control -is [System.Windows.Forms.LinkLabel]) {
            $Control.BackColor = $Control.Parent.BackColor
            $Control.ForeColor = $colors.Muted
            $Control.LinkColor = $colors.Link
            $Control.ActiveLinkColor = $colors.Link
            $Control.VisitedLinkColor = $colors.Link
        } elseif ($Control -is [System.Windows.Forms.Label] -or $Control -is [System.Windows.Forms.CheckBox]) {
            $Control.BackColor = $Control.Parent.BackColor
            $Control.ForeColor = $colors.Text
        }

        foreach ($child in $Control.Controls) {
            Apply-AppThemeToControl -Control $child
        }
    } catch {
        Write-AppLog "Apply-AppThemeToControl error: $($_.Exception.Message)"
    }
}

function Save-CurrentUiToConfig {
    try {
        if ($null -eq $Script:Config) { $Script:Config = Get-DefaultConfig }
        if ($txtFolder) { $Script:Config['DownloadFolder'] = $txtFolder.Text.Trim() }
        if ($cmbMode -and $cmbMode.SelectedItem) { $Script:Config['Mode'] = [string]$cmbMode.SelectedItem }
        if ($cmbQuality -and $cmbQuality.SelectedItem) {
            if ($cmbMode -and $cmbMode.SelectedItem -eq 'Solo MP3') {
                $Script:Config['AudioQuality'] = [string]$cmbQuality.SelectedItem
            } else {
                $Script:Config['Quality'] = [string]$cmbQuality.SelectedItem
            }
        }
        if ($chkPlaylist) { $Script:Config['DownloadPlaylist'] = [bool]$chkPlaylist.Checked }
        if ($chkOpenAfter) { $Script:Config['OpenFolderWhenFinished'] = [bool]$chkOpenAfter.Checked }
        Save-AppConfig
    } catch {
        Write-AppLog "Save-CurrentUiToConfig error: $($_.Exception.Message)"
    }
}


function Get-VideoQualityItems {
    return @('Mejor calidad disponible','Maximo 2160p / 4K','Maximo 1440p / 2K','Maximo 1080p / Full HD','Maximo 720p / HD','Maximo 480p','Maximo 360p')
}

function Get-AudioQualityItems {
    return @('Mejor calidad MP3 (0)','320 kbps','256 kbps','192 kbps','160 kbps','128 kbps')
}

function Set-ComboBoxItems {
    param($Combo, [string[]]$Items, [string]$Selected)
    if ($null -eq $Combo) { return }
    $Combo.BeginUpdate()
    try {
        $Combo.Items.Clear()
        foreach ($item in $Items) { [void]$Combo.Items.Add($item) }
        if ($Combo.Items.Contains($Selected)) { $Combo.SelectedItem = $Selected }
        elseif ($Combo.Items.Count -gt 0) { $Combo.SelectedIndex = 0 }
    }
    finally { $Combo.EndUpdate() }
}

function Sync-QualityComboForMode {
    try {
        if (-not $cmbQuality -or -not $cmbMode) { return }
        if ($cmbMode.SelectedItem -eq 'Solo MP3') {
            if ($lblQuality) { $lblQuality.Text = 'Calidad MP3:' }
            Set-ComboBoxItems -Combo $cmbQuality -Items (Get-AudioQualityItems) -Selected (Get-ConfigString 'AudioQuality' 'Mejor calidad MP3 (0)')
        } else {
            if ($lblQuality) { $lblQuality.Text = 'Calidad:' }
            Set-ComboBoxItems -Combo $cmbQuality -Items (Get-VideoQualityItems) -Selected (Get-ConfigString 'Quality' 'Mejor calidad disponible')
        }
        $cmbQuality.Enabled = (-not $Script:IsDownloading)
    } catch { Write-AppLog "Sync-QualityComboForMode error: $($_.Exception.Message)" }
}

function Get-AudioQualityArgument {
    param([string]$QualityText)
    switch -Regex ($QualityText) {
        '320' { return '320K' }
        '256' { return '256K' }
        '192' { return '192K' }
        '160' { return '160K' }
        '128' { return '128K' }
        default { return '0' }
    }
}

function Get-FileNameTemplateItems {
    return @('Titulo + ID','Solo titulo','Fecha + titulo')
}

function Get-CookiesBrowserItems {
    return @('No usar','Chrome','Edge','Firefox')
}

function Get-OutputTemplate {
    param(
        [string]$TemplateName,
        [bool]$Playlist
    )

    $base = switch ($TemplateName) {
        'Solo titulo' { '%(title).180s.%(ext)s' }
        'Fecha + titulo' { '%(upload_date)s - %(title).180s [%(id)s].%(ext)s' }
        default { '%(title).180s [%(id)s].%(ext)s' }
    }

    if ($Playlist) {
        return ('%(playlist_title|Lista de YouTube)s/%(playlist_index)03d - ' + $base)
    }

    return $base
}

function Get-EffectiveOutputFolder {
    param(
        [Parameter(Mandatory=$true)][string]$BaseFolder,
        [Parameter(Mandatory=$true)][string]$Mode
    )

    $folder = $BaseFolder
    if (Get-ConfigBool 'UseSubfolders' $false) {
        if ($Mode -eq 'Solo MP3') { $folder = Join-Path $BaseFolder 'MP3' }
        else { $folder = Join-Path $BaseFolder 'Video' }
    }

    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    return $folder
}

function Add-HistoryEntry {
    param(
        [string]$Status,
        [string]$Message = ''
    )

    try {
        if (-not (Get-ConfigBool 'EnableHistory' $false)) { return }
        $entry = [ordered]@{
            Date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Url = if ($txtUrl) { $txtUrl.Text.Trim() } else { '' }
            DestinationFolder = if ($txtFolder) { $txtFolder.Text.Trim() } else { '' }
            Mode = if ($cmbMode -and $cmbMode.SelectedItem) { [string]$cmbMode.SelectedItem } else { '' }
            VideoQuality = Get-ConfigString 'Quality' 'Mejor calidad disponible'
            AudioQuality = Get-ConfigString 'AudioQuality' 'Mejor calidad MP3 (0)'
            DownloadPlaylist = if ($chkPlaylist) { [bool]$chkPlaylist.Checked } else { Get-ConfigBool 'DownloadPlaylist' $false }
            FileNameTemplate = Get-ConfigString 'FileNameTemplate' 'Titulo + ID'
            UseSubfolders = Get-ConfigBool 'UseSubfolders' $false
            CookiesBrowser = Get-ConfigString 'CookiesBrowser' 'No usar'
            Status = $Status
            Message = $Message
        }
        ($entry | ConvertTo-Json -Compress -Depth 5) | Add-Content -LiteralPath $Script:HistoryFile -Encoding UTF8
    } catch { Write-AppLog "Add-HistoryEntry error: $($_.Exception.Message)" }
}

function Show-HistoryDialog {
    try {
        if (-not (Get-ConfigBool 'EnableHistory' $false)) {
            [System.Windows.Forms.MessageBox]::Show('El historial esta desactivado. Puedes activarlo desde Configuracion.', 'Historial desactivado', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'Historial de descargas'
        $dlg.Size = New-Object System.Drawing.Size(850, 520)
        $dlg.MinimumSize = New-Object System.Drawing.Size(850, 520)
        $dlg.StartPosition = 'CenterParent'
        $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $txtHistory = New-Object System.Windows.Forms.TextBox
        $txtHistory.Location = New-Object System.Drawing.Point(15, 15)
        $txtHistory.Size = New-Object System.Drawing.Size(805, 390)
        $txtHistory.Anchor = 'Top,Bottom,Left,Right'
        $txtHistory.Multiline = $true
        $txtHistory.ScrollBars = 'Vertical'
        $txtHistory.ReadOnly = $true
        $dlg.Controls.Add($txtHistory)

        $lines = @()
        if (Test-Path -LiteralPath $Script:HistoryFile) {
            $rawLines = Get-Content -LiteralPath $Script:HistoryFile -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($rawLines) { $lines = @($rawLines | Select-Object -Last 100) }
        }
        if ($lines.Count -eq 0) {
            $txtHistory.Text = 'Todavia no hay historial registrado.'
        } else {
            $view = New-Object System.Collections.Generic.List[string]
            foreach ($line in $lines) {
                try {
                    $o = $line | ConvertFrom-Json -ErrorAction Stop
                    $playlistText = if ($o.DownloadPlaylist) { 'Lista completa' } else { 'Solo video/enlace' }
                    $view.Add(('{0} | {1} | {2} | {3} | {4}' -f $o.Date, $o.Status, $o.Mode, $playlistText, $o.Url))
                    if ($o.Message) { $view.Add(('  Detalle: {0}' -f $o.Message)) }
                    if ($o.DestinationFolder) { $view.Add(('  Carpeta: {0}' -f $o.DestinationFolder)) }
                    $view.Add('')
                } catch {
                    $view.Add($line)
                }
            }
            $txtHistory.Text = ($view -join [Environment]::NewLine)
        }

        $btnOpen = New-Object System.Windows.Forms.Button
        $btnOpen.Text = 'Abrir archivo'
        $btnOpen.Location = New-Object System.Drawing.Point(15, 420)
        $btnOpen.Size = New-Object System.Drawing.Size(110, 32)
        $btnOpen.Anchor = 'Bottom,Left'
        $btnOpen.Add_Click({
            try {
                if (Test-Path -LiteralPath $Script:HistoryFile) { Start-Process notepad.exe -ArgumentList ('"' + $Script:HistoryFile + '"') }
                else { [System.Windows.Forms.MessageBox]::Show('Todavia no existe el archivo de historial.', 'Sin historial', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null }
            } catch { Show-ErrorMessage -Title 'Error abriendo historial' -Message $_.Exception.Message }
        })
        $dlg.Controls.Add($btnOpen)

        $btnClear = New-Object System.Windows.Forms.Button
        $btnClear.Text = 'Borrar historial'
        $btnClear.Location = New-Object System.Drawing.Point(140, 420)
        $btnClear.Size = New-Object System.Drawing.Size(120, 32)
        $btnClear.Anchor = 'Bottom,Left'
        $btnClear.Add_Click({
            try {
                $confirm = [System.Windows.Forms.MessageBox]::Show('Quieres borrar el historial de descargas?', 'Borrar historial', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Remove-Item -LiteralPath $Script:HistoryFile -Force -ErrorAction SilentlyContinue
                    $txtHistory.Text = 'Historial borrado.'
                }
            } catch { Show-ErrorMessage -Title 'Error borrando historial' -Message $_.Exception.Message }
        })
        $dlg.Controls.Add($btnClear)

        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = 'Cerrar'
        $btnClose.Location = New-Object System.Drawing.Point(710, 420)
        $btnClose.Size = New-Object System.Drawing.Size(110, 32)
        $btnClose.Anchor = 'Bottom,Right'
        $btnClose.Add_Click({ $dlg.Close() })
        $dlg.Controls.Add($btnClose)

        Apply-AppThemeToControl -Control $dlg
        [void]$dlg.ShowDialog()
    } catch {
        Write-AppLog "Show-HistoryDialog error: $($_.Exception.ToString())"
        Show-ErrorMessage -Title 'Error abriendo historial' -Message $_.Exception.Message
    }
}

function Clear-HistoryFromUi {
    try {
        if (-not (Test-Path -LiteralPath $Script:HistoryFile)) {
            [System.Windows.Forms.MessageBox]::Show('Todavia no existe historial para borrar.', 'Borrar historial', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show('Quieres borrar todo el historial de descargas?', 'Borrar historial', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Remove-Item -LiteralPath $Script:HistoryFile -Force -ErrorAction SilentlyContinue
            Append-Log 'Historial borrado.'
            [System.Windows.Forms.MessageBox]::Show('Historial borrado correctamente.', 'Borrar historial', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    } catch {
        Show-ErrorMessage -Title 'Error borrando historial' -Message $_.Exception.Message
    }
}

function Update-HistoryButtonState {
    try {
        $enabled = Get-ConfigBool 'EnableHistory' $false
        if ($btnHistory) {
            $btnHistory.Visible = $true
            $btnHistory.Enabled = (-not $Script:IsDownloading)
            if ($enabled) { $btnHistory.Text = 'Historial' } else { $btnHistory.Text = 'Historial (off)' }
        }
        if ($btnClearHistory) {
            $btnClearHistory.Visible = $true
            $btnClearHistory.Enabled = $enabled -and (-not $Script:IsDownloading) -and (Test-Path -LiteralPath $Script:HistoryFile)
        }
    } catch {}
}

function Apply-ConfigToMainControls {
    try {
        if ($txtFolder) { $txtFolder.Text = Get-ConfigString 'DownloadFolder' (Get-DownloadsFolder) }
        if ($cmbMode) {
            $mode = Get-ConfigString 'Mode' 'Video'
            if ($cmbMode.Items.Contains($mode)) { $cmbMode.SelectedItem = $mode } else { $cmbMode.SelectedItem = 'Video' }
        }
        if ($cmbQuality -and $cmbMode) { Sync-QualityComboForMode }
        if ($chkPlaylist) { $chkPlaylist.Checked = Get-ConfigBool 'DownloadPlaylist' $false }
        if ($chkOpenAfter) { $chkOpenAfter.Checked = Get-ConfigBool 'OpenFolderWhenFinished' $false }
        if ($btnOpenFolder -and $txtFolder) { $btnOpenFolder.Enabled = (Test-Path -LiteralPath $txtFolder.Text) }
        Update-HistoryButtonState
    } catch {
        Write-AppLog "Apply-ConfigToMainControls error: $($_.Exception.Message)"
    }
}


function Create-DesktopShortcutFromUi {
    try {
        $batPath = Join-Path $Script:AppDir 'YtDOWNLOADER.bat'
        if (-not (Test-Path -LiteralPath $batPath)) {
            [System.Windows.Forms.MessageBox]::Show('No se encuentra YtDOWNLOADER.bat junto a la aplicacion.', 'Crear acceso directo', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $desktop = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) {
            [System.Windows.Forms.MessageBox]::Show('No se pudo localizar el escritorio de Windows.', 'Crear acceso directo', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $shortcutPath = Join-Path $desktop 'YtDOWNLOADER by OsageP.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $batPath
        $shortcut.WorkingDirectory = $Script:AppDir
        $shortcut.Description = 'YtDOWNLOADER by OsageP - Descargar videos y MP3 con yt-dlp'
        if (Test-Path -LiteralPath $Script:IconPath) {
            $shortcut.IconLocation = ('{0},0' -f $Script:IconPath)
        }
        $shortcut.Save()

        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null

        Append-Log "Acceso directo creado en el escritorio: $shortcutPath"
        [System.Windows.Forms.MessageBox]::Show("Acceso directo creado correctamente en el escritorio.`r`n`r`n$shortcutPath", 'Crear acceso directo', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        Show-ErrorMessage -Title 'Error creando acceso directo' -Message $_.Exception.Message
    }
}

function Show-SettingsDialog {
    param([bool]$FirstRun = $false)

    try {
        if ($null -eq $Script:Config) { Load-AppConfig | Out-Null }

        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = if ($FirstRun) { 'Configuracion inicial' } else { 'Configuracion' }
        $dlg.Size = New-Object System.Drawing.Size(760, 640)
        $dlg.MinimumSize = New-Object System.Drawing.Size(760, 640)
        $dlg.StartPosition = 'CenterParent'
        $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false

        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Text = if ($FirstRun) { 'Primera configuracion' } else { 'Valores predeterminados' }
        $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
        $lblTitle.Location = New-Object System.Drawing.Point(18, 15)
        $lblTitle.Size = New-Object System.Drawing.Size(540, 26)
        $dlg.Controls.Add($lblTitle)

        $lblInfo = New-Object System.Windows.Forms.Label
        $lblInfo.Text = 'Estos valores se guardan en YtDOWNLOADER_config.json, junto al programa.'
        $lblInfo.Location = New-Object System.Drawing.Point(18, 45)
        $lblInfo.Size = New-Object System.Drawing.Size(700, 22)
        $dlg.Controls.Add($lblInfo)

        $lblSetFolder = New-Object System.Windows.Forms.Label
        $lblSetFolder.Text = 'Carpeta predeterminada:'
        $lblSetFolder.Location = New-Object System.Drawing.Point(18, 82)
        $lblSetFolder.Size = New-Object System.Drawing.Size(180, 22)
        $dlg.Controls.Add($lblSetFolder)

        $txtSetFolder = New-Object System.Windows.Forms.TextBox
        $txtSetFolder.Location = New-Object System.Drawing.Point(18, 106)
        $txtSetFolder.Size = New-Object System.Drawing.Size(575, 24)
        $txtSetFolder.Text = Get-ConfigString 'DownloadFolder' (Get-DownloadsFolder)
        $dlg.Controls.Add($txtSetFolder)

        $btnSetFolder = New-Object System.Windows.Forms.Button
        $btnSetFolder.Text = 'Elegir...'
        $btnSetFolder.Location = New-Object System.Drawing.Point(610, 104)
        $btnSetFolder.Size = New-Object System.Drawing.Size(90, 28)
        $btnSetFolder.Add_Click({
            try {
                $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                $dialog.Description = 'Selecciona la carpeta predeterminada de descarga'
                if (Test-Path -LiteralPath $txtSetFolder.Text) { $dialog.SelectedPath = $txtSetFolder.Text }
                if ($dialog.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) {
                    $txtSetFolder.Text = $dialog.SelectedPath
                }
            } catch { Show-ErrorMessage -Title 'Error seleccionando carpeta' -Message $_.Exception.Message }
        })
        $dlg.Controls.Add($btnSetFolder)

        $lblSetMode = New-Object System.Windows.Forms.Label
        $lblSetMode.Text = 'Tipo predeterminado:'
        $lblSetMode.Location = New-Object System.Drawing.Point(18, 150)
        $lblSetMode.Size = New-Object System.Drawing.Size(145, 22)
        $dlg.Controls.Add($lblSetMode)

        $cmbSetMode = New-Object System.Windows.Forms.ComboBox
        $cmbSetMode.Location = New-Object System.Drawing.Point(165, 147)
        $cmbSetMode.Size = New-Object System.Drawing.Size(140, 24)
        $cmbSetMode.DropDownStyle = 'DropDownList'
        [void]$cmbSetMode.Items.Add('Video')
        [void]$cmbSetMode.Items.Add('Solo MP3')
        $setMode = Get-ConfigString 'Mode' 'Video'
        if ($cmbSetMode.Items.Contains($setMode)) { $cmbSetMode.SelectedItem = $setMode } else { $cmbSetMode.SelectedIndex = 0 }
        $dlg.Controls.Add($cmbSetMode)

        $lblSetQuality = New-Object System.Windows.Forms.Label
        $lblSetQuality.Text = 'Calidad video:'
        $lblSetQuality.Location = New-Object System.Drawing.Point(325, 150)
        $lblSetQuality.Size = New-Object System.Drawing.Size(150, 22)
        $dlg.Controls.Add($lblSetQuality)

        $cmbSetQuality = New-Object System.Windows.Forms.ComboBox
        $cmbSetQuality.Location = New-Object System.Drawing.Point(475, 147)
        $cmbSetQuality.Size = New-Object System.Drawing.Size(250, 24)
        $cmbSetQuality.DropDownStyle = 'DropDownList'
        foreach ($q in (Get-VideoQualityItems)) { [void]$cmbSetQuality.Items.Add($q) }
        $setQuality = Get-ConfigString 'Quality' 'Mejor calidad disponible'
        if ($cmbSetQuality.Items.Contains($setQuality)) { $cmbSetQuality.SelectedItem = $setQuality } else { $cmbSetQuality.SelectedIndex = 0 }
        $dlg.Controls.Add($cmbSetQuality)

        $lblSetAudioQuality = New-Object System.Windows.Forms.Label
        $lblSetAudioQuality.Text = 'Calidad MP3:'
        $lblSetAudioQuality.Location = New-Object System.Drawing.Point(325, 185)
        $lblSetAudioQuality.Size = New-Object System.Drawing.Size(150, 22)
        $dlg.Controls.Add($lblSetAudioQuality)

        $cmbSetAudioQuality = New-Object System.Windows.Forms.ComboBox
        $cmbSetAudioQuality.Location = New-Object System.Drawing.Point(475, 182)
        $cmbSetAudioQuality.Size = New-Object System.Drawing.Size(250, 24)
        $cmbSetAudioQuality.DropDownStyle = 'DropDownList'
        foreach ($q in (Get-AudioQualityItems)) { [void]$cmbSetAudioQuality.Items.Add($q) }
        $setAudioQuality = Get-ConfigString 'AudioQuality' 'Mejor calidad MP3 (0)'
        if ($cmbSetAudioQuality.Items.Contains($setAudioQuality)) { $cmbSetAudioQuality.SelectedItem = $setAudioQuality } else { $cmbSetAudioQuality.SelectedIndex = 0 }
        $dlg.Controls.Add($cmbSetAudioQuality)

        $chkPlaylistDefault = New-Object System.Windows.Forms.CheckBox
        $chkPlaylistDefault.Text = 'Descargar lista completa si el enlace pertenece a una playlist'
        $chkPlaylistDefault.Location = New-Object System.Drawing.Point(18, 225)
        $chkPlaylistDefault.Size = New-Object System.Drawing.Size(520, 24)
        $chkPlaylistDefault.Checked = Get-ConfigBool 'DownloadPlaylist' $false
        $dlg.Controls.Add($chkPlaylistDefault)

        $chkHistory = New-Object System.Windows.Forms.CheckBox
        $chkHistory.Text = 'Guardar historial de descargas en YtDOWNLOADER_history.jsonl'
        $chkHistory.Location = New-Object System.Drawing.Point(18, 255)
        $chkHistory.Size = New-Object System.Drawing.Size(520, 24)
        $chkHistory.Checked = Get-ConfigBool 'EnableHistory' $false
        $dlg.Controls.Add($chkHistory)

        $lblSetTheme = New-Object System.Windows.Forms.Label
        $lblSetTheme.Text = 'Tema visual:'
        $lblSetTheme.Location = New-Object System.Drawing.Point(18, 295)
        $lblSetTheme.Size = New-Object System.Drawing.Size(145, 22)
        $dlg.Controls.Add($lblSetTheme)

        $cmbSetTheme = New-Object System.Windows.Forms.ComboBox
        $cmbSetTheme.Location = New-Object System.Drawing.Point(165, 292)
        $cmbSetTheme.Size = New-Object System.Drawing.Size(140, 24)
        $cmbSetTheme.DropDownStyle = 'DropDownList'
        foreach ($t in @('Sistema','Claro','Oscuro')) { [void]$cmbSetTheme.Items.Add($t) }
        $setTheme = Get-ConfigString 'Theme' 'Sistema'
        if ($cmbSetTheme.Items.Contains($setTheme)) { $cmbSetTheme.SelectedItem = $setTheme } else { $cmbSetTheme.SelectedItem = 'Sistema' }
        $dlg.Controls.Add($cmbSetTheme)

        $chkOpen = New-Object System.Windows.Forms.CheckBox
        $chkOpen.Text = 'Abrir carpeta automaticamente al terminar una descarga'
        $chkOpen.Location = New-Object System.Drawing.Point(18, 330)
        $chkOpen.Size = New-Object System.Drawing.Size(420, 24)
        $chkOpen.Checked = Get-ConfigBool 'OpenFolderWhenFinished' $false
        $dlg.Controls.Add($chkOpen)

        $chkAdvanced = New-Object System.Windows.Forms.CheckBox
        $chkAdvanced.Text = 'Mostrar opciones avanzadas'
        $chkAdvanced.Location = New-Object System.Drawing.Point(18, 365)
        $chkAdvanced.Size = New-Object System.Drawing.Size(300, 24)
        $chkAdvanced.Checked = Get-ConfigBool 'ShowAdvanced' $false
        $dlg.Controls.Add($chkAdvanced)

        $lblFileTemplate = New-Object System.Windows.Forms.Label
        $lblFileTemplate.Text = 'Nombre archivo:'
        $lblFileTemplate.Location = New-Object System.Drawing.Point(38, 400)
        $lblFileTemplate.Size = New-Object System.Drawing.Size(120, 22)
        $dlg.Controls.Add($lblFileTemplate)

        $cmbFileTemplate = New-Object System.Windows.Forms.ComboBox
        $cmbFileTemplate.Location = New-Object System.Drawing.Point(165, 397)
        $cmbFileTemplate.Size = New-Object System.Drawing.Size(200, 24)
        $cmbFileTemplate.DropDownStyle = 'DropDownList'
        foreach ($item in (Get-FileNameTemplateItems)) { [void]$cmbFileTemplate.Items.Add($item) }
        $setTemplate = Get-ConfigString 'FileNameTemplate' 'Titulo + ID'
        if ($cmbFileTemplate.Items.Contains($setTemplate)) { $cmbFileTemplate.SelectedItem = $setTemplate } else { $cmbFileTemplate.SelectedItem = 'Titulo + ID' }
        $dlg.Controls.Add($cmbFileTemplate)

        $chkSubfolders = New-Object System.Windows.Forms.CheckBox
        $chkSubfolders.Text = 'Crear subcarpetas Video / MP3 dentro de la carpeta elegida'
        $chkSubfolders.Location = New-Object System.Drawing.Point(390, 397)
        $chkSubfolders.Size = New-Object System.Drawing.Size(340, 24)
        $chkSubfolders.Checked = Get-ConfigBool 'UseSubfolders' $false
        $dlg.Controls.Add($chkSubfolders)

        $lblCookies = New-Object System.Windows.Forms.Label
        $lblCookies.Text = 'Cookies navegador:'
        $lblCookies.Location = New-Object System.Drawing.Point(38, 435)
        $lblCookies.Size = New-Object System.Drawing.Size(120, 22)
        $dlg.Controls.Add($lblCookies)

        $cmbCookies = New-Object System.Windows.Forms.ComboBox
        $cmbCookies.Location = New-Object System.Drawing.Point(165, 432)
        $cmbCookies.Size = New-Object System.Drawing.Size(200, 24)
        $cmbCookies.DropDownStyle = 'DropDownList'
        foreach ($item in (Get-CookiesBrowserItems)) { [void]$cmbCookies.Items.Add($item) }
        $setCookies = Get-ConfigString 'CookiesBrowser' 'No usar'
        if ($cmbCookies.Items.Contains($setCookies)) { $cmbCookies.SelectedItem = $setCookies } else { $cmbCookies.SelectedItem = 'No usar' }
        $dlg.Controls.Add($cmbCookies)

        $lblAdvancedNote = New-Object System.Windows.Forms.Label
        $lblAdvancedNote.Text = 'Usar cookies puede ayudar con videos con restricciones. Mantener en "No usar" si no hace falta.'
        $lblAdvancedNote.Location = New-Object System.Drawing.Point(390, 435)
        $lblAdvancedNote.Size = New-Object System.Drawing.Size(340, 44)
        $dlg.Controls.Add($lblAdvancedNote)

        $updateAdvancedVisibility = {
            $visible = [bool]$chkAdvanced.Checked
            foreach ($ctrl in @($lblFileTemplate,$cmbFileTemplate,$chkSubfolders,$lblCookies,$cmbCookies,$lblAdvancedNote)) {
                if ($ctrl) { $ctrl.Visible = $visible }
            }
        }
        $chkAdvanced.Add_CheckedChanged($updateAdvancedVisibility)
        & $updateAdvancedVisibility

        $btnShortcut = New-Object System.Windows.Forms.Button
        $btnShortcut.Text = 'Crear acceso directo en escritorio'
        $btnShortcut.Location = New-Object System.Drawing.Point(18, 505)
        $btnShortcut.Size = New-Object System.Drawing.Size(240, 30)
        $btnShortcut.Add_Click({ Create-DesktopShortcutFromUi })
        $dlg.Controls.Add($btnShortcut)

        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text = 'Guardar' 
        $btnSave.Location = New-Object System.Drawing.Point(535, 505)
        $btnSave.Size = New-Object System.Drawing.Size(100, 30)
        $btnSave.Add_Click({
            try {
                if ([string]::IsNullOrWhiteSpace($txtSetFolder.Text) -or -not (Test-Path -LiteralPath $txtSetFolder.Text.Trim())) {
                    [System.Windows.Forms.MessageBox]::Show('La carpeta seleccionada no existe.', 'Carpeta no valida', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                    return
                }
                $Script:Config['DownloadFolder'] = $txtSetFolder.Text.Trim()
                $Script:Config['Mode'] = [string]$cmbSetMode.SelectedItem
                $Script:Config['Quality'] = [string]$cmbSetQuality.SelectedItem
                $Script:Config['AudioQuality'] = [string]$cmbSetAudioQuality.SelectedItem
                $Script:Config['DownloadPlaylist'] = [bool]$chkPlaylistDefault.Checked
                $Script:Config['EnableHistory'] = [bool]$chkHistory.Checked
                $Script:Config['Theme'] = [string]$cmbSetTheme.SelectedItem
                $Script:Config['OpenFolderWhenFinished'] = [bool]$chkOpen.Checked
                $Script:Config['ShowAdvanced'] = [bool]$chkAdvanced.Checked
                $Script:Config['FileNameTemplate'] = [string]$cmbFileTemplate.SelectedItem
                $Script:Config['UseSubfolders'] = [bool]$chkSubfolders.Checked
                $Script:Config['CookiesBrowser'] = [string]$cmbCookies.SelectedItem
                Save-AppConfig
                $dlg.Tag = 'saved'
                $dlg.Close()
            } catch {
                Show-ErrorMessage -Title 'Error guardando configuracion' -Message $_.Exception.Message
            }
        })
        $dlg.Controls.Add($btnSave)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = if ($FirstRun) { 'Usar valores por defecto' } else { 'Cancelar' }
        $btnCancel.Location = New-Object System.Drawing.Point(645, 505)
        $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
        $btnCancel.Add_Click({
            try {
                if ($FirstRun -and -not (Test-Path -LiteralPath $Script:ConfigFile)) {
                    Save-AppConfig
                }
            } catch {}
            $dlg.Tag = 'cancel'
            $dlg.Close()
        })
        $dlg.Controls.Add($btnCancel)

        $dlg.AcceptButton = $btnSave
        $dlg.CancelButton = $btnCancel
        Apply-AppThemeToControl -Control $dlg

        [void]$dlg.ShowDialog()
        return ($dlg.Tag -eq 'saved')
    }
    catch {
        Write-AppLog "Show-SettingsDialog error: $($_.Exception.ToString())"
        Show-ErrorMessage -Title 'Error abriendo configuracion' -Message $_.Exception.Message
        return $false
    }
}

function Quote-Argument {
    param([string]$Value)

    if ($null -eq $Value -or $Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    # Escapado compatible con CreateProcess/CommandLineToArgvW para argumentos normales.
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-VideoFormat {
    param([string]$QualityText)

    switch -Regex ($QualityText) {
        '2160p' { return 'bv*[height<=2160]+ba/b[height<=2160]/best' }
        '1440p' { return 'bv*[height<=1440]+ba/b[height<=1440]/best' }
        '1080p' { return 'bv*[height<=1080]+ba/b[height<=1080]/best' }
        '720p'  { return 'bv*[height<=720]+ba/b[height<=720]/best' }
        '480p'  { return 'bv*[height<=480]+ba/b[height<=480]/best' }
        '360p'  { return 'bv*[height<=360]+ba/b[height<=360]/best' }
        default { return 'bv*+ba/best' }
    }
}

function Append-Log {
    param([string]$Text)

    if ($null -eq $Text) { return }
    $line = $Text.TrimEnd()
    if ($line.Length -eq 0) { return }
    Write-DebugLog $line

    try {
        $txtLog.AppendText($line + [Environment]::NewLine)
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    } catch {
        Write-AppLog "Append-Log error: $($_.Exception.Message)"
    }
}

function Update-PlaylistStatusLabel {
    param([string]$FileName = '')

    try {
        if (-not $lblPlaylistProgress) { return }

        $prefix = ''
        if ($Script:PlaylistCurrent -and $Script:PlaylistTotal) {
            $prefix = ('Lista: {0} de {1}' -f $Script:PlaylistCurrent, $Script:PlaylistTotal)
        } elseif ($chkPlaylist -and $chkPlaylist.Checked) {
            $prefix = 'Lista: esperando informacion de yt-dlp...'
        }

        if (-not [string]::IsNullOrWhiteSpace($FileName)) {
            $Script:CurrentOutputName = $FileName
        }

        if (-not [string]::IsNullOrWhiteSpace($Script:CurrentOutputName)) {
            if ([string]::IsNullOrWhiteSpace($prefix)) {
                $lblPlaylistProgress.Text = ('Archivo: {0}' -f $Script:CurrentOutputName)
            } else {
                $lblPlaylistProgress.Text = ('{0} | Archivo: {1}' -f $prefix, $Script:CurrentOutputName)
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($prefix)) {
            $lblPlaylistProgress.Text = $prefix
        } else {
            $lblPlaylistProgress.Text = 'Lista: no activa'
        }
    } catch {
        Write-AppLog "Update-PlaylistStatusLabel error: $($_.Exception.Message)"
    }
}

function Update-ProgressFromLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    # En playlists, yt-dlp suele emitir: [download] Downloading item 2 of 10
    # Tambien contemplamos variantes antiguas con "video".
    if ($Line -match '(?i)\[download\]\s+Downloading\s+(?:item|video)\s+(\d+)\s+of\s+(\d+)') {
        $Script:PlaylistCurrent = [int]$Matches[1]
        $Script:PlaylistTotal = [int]$Matches[2]
        $Script:CurrentOutputName = ''
        Update-PlaylistStatusLabel
    }

    # Mostramos el nombre del archivo que se esta descargando o procesando.
    if ($Line -match '^\[download\]\s+Destination:\s+(.+)$') {
        $fileName = Split-Path -Leaf $Matches[1]
        Update-PlaylistStatusLabel -FileName $fileName
    } elseif ($Line -match '^\[Merger\]\s+Merging formats into\s+"?(.+?)"?$') {
        $fileName = Split-Path -Leaf $Matches[1]
        Update-PlaylistStatusLabel -FileName $fileName
    } elseif ($Line -match '^\[ExtractAudio\]\s+Destination:\s+(.+)$') {
        $fileName = Split-Path -Leaf $Matches[1]
        Update-PlaylistStatusLabel -FileName $fileName
    }

    $match = [regex]::Match($Line, '(\d{1,3}(?:[\.,]\d+)?)%')
    if ($match.Success) {
        $raw = $match.Groups[1].Value.Replace(',', '.')
        [double]$percent = 0
        if ([double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$percent)) {
            if ($percent -lt 0) { $percent = 0 }
            if ($percent -gt 100) { $percent = 100 }
            $value = [int][math]::Round($percent)
            $progressBar.Style = 'Continuous'
            $progressBar.Value = $value
            if ($Script:PlaylistCurrent -and $Script:PlaylistTotal) {
                $lblProgress.Text = "Progreso archivo: $([math]::Round($percent, 1))%"
            } else {
                $lblProgress.Text = "Progreso: $([math]::Round($percent, 1))%"
            }
        }
    }

    if ($Line -match 'ETA\s+([^\s]+)') {
        if ($Script:PlaylistCurrent -and $Script:PlaylistTotal) {
            $lblStatus.Text = "Descargando archivo $Script:PlaylistCurrent de $Script:PlaylistTotal... ETA $($Matches[1])"
        } else {
            $lblStatus.Text = "Descargando... ETA $($Matches[1])"
        }
    } elseif ($Line -match '\[Merger\]|\[ExtractAudio\]|\[VideoConvertor\]|\[ModifyChapters\]|\[Metadata\]') {
        $progressBar.Style = 'Marquee'
        if ($Script:PlaylistCurrent -and $Script:PlaylistTotal) {
            $lblStatus.Text = "Procesando archivo $Script:PlaylistCurrent de $Script:PlaylistTotal..."
        } else {
            $lblStatus.Text = 'Procesando archivo final...'
        }
    } elseif ($Line -match 'has already been downloaded|100%') {
        $progressBar.Style = 'Continuous'
        $progressBar.Value = 100
        if ($Script:PlaylistCurrent -and $Script:PlaylistTotal) {
            $lblProgress.Text = 'Progreso archivo: 100%'
        } else {
            $lblProgress.Text = 'Progreso: 100%'
        }
    }
}

function Set-ControlsForDownload {
    param([bool]$Downloading)

    $Script:IsDownloading = $Downloading
    $txtUrl.Enabled = -not $Downloading
    $txtFolder.Enabled = -not $Downloading
    $btnFolder.Enabled = -not $Downloading
    $cmbMode.Enabled = -not $Downloading
    $cmbQuality.Enabled = -not $Downloading
    if ($chkPlaylist) { $chkPlaylist.Enabled = -not $Downloading }
    if ($chkOpenAfter) { $chkOpenAfter.Enabled = -not $Downloading }
    $btnDownload.Enabled = -not $Downloading
    $btnCancel.Enabled = $Downloading
    $btnCheck.Enabled = -not $Downloading
    if ($btnUpdateComponents) { $btnUpdateComponents.Enabled = -not $Downloading }
    if ($btnCleanTemp) { $btnCleanTemp.Enabled = -not $Downloading }
    if ($btnClearLogs) { $btnClearLogs.Enabled = -not $Downloading }
    if ($btnClearHistory) { $btnClearHistory.Enabled = (Get-ConfigBool 'EnableHistory' $false) -and (-not $Downloading) -and (Test-Path -LiteralPath $Script:HistoryFile) }
    $btnOpenFolder.Enabled = (-not $Downloading) -and (Test-Path -LiteralPath $txtFolder.Text)
    Update-HistoryButtonState
}

function Read-NewLinesFromFile {
    param(
        [string]$Path,
        [int]$PreviousCount
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Lines = @(); Count = $PreviousCount }
    }

    try {
        $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -eq $lines) { $lines = @() }
        if ($lines -is [string]) { $lines = @($lines) }
        $total = $lines.Count
        if ($total -le $PreviousCount) {
            return @{ Lines = @(); Count = $total }
        }
        $newLines = $lines[$PreviousCount..($total - 1)]
        return @{ Lines = $newLines; Count = $total }
    }
    catch {
        Write-AppLog "Read-NewLinesFromFile error: $($_.Exception.Message)"
        return @{ Lines = @(); Count = $PreviousCount }
    }
}

function Poll-DownloadProcess {
    try {
        $out = Read-NewLinesFromFile -Path $Script:StdoutFile -PreviousCount $Script:StdoutLineCount
        $Script:StdoutLineCount = $out.Count
        foreach ($line in $out.Lines) {
            Append-Log $line
            Update-ProgressFromLine $line
        }

        $err = Read-NewLinesFromFile -Path $Script:StderrFile -PreviousCount $Script:StderrLineCount
        $Script:StderrLineCount = $err.Count
        foreach ($line in $err.Lines) {
            Append-Log $line
            Update-ProgressFromLine $line
        }

        if ($Script:CurrentProcess -and $Script:CurrentProcess.HasExited) {
            Finish-DownloadProcess
        }
    }
    catch {
        Write-AppLog "Poll-DownloadProcess error: $($_.Exception.ToString())"
        Append-Log "ERROR UI/TIMER: $($_.Exception.Message)"
    }
}

function Get-RawFileTextSafe {
    param([string]$Path)

    try {
        if (Test-Path -LiteralPath $Path) {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
            if ($null -ne $raw) { return [string]$raw }
        }
    } catch {}

    return ''
}


function Stop-DownloadProcessTree {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) { return $false }

    $processId = $null
    try { $processId = [int]$Process.Id } catch { return $false }
    if ($processId -le 0) { return $false }

    try {
        if ($Process.HasExited) { return $true }
    } catch {}

    try {
        $taskKill = Join-Path $env:WINDIR 'System32\taskkill.exe'
        if (Test-Path -LiteralPath $taskKill) {
            Write-DebugLog "Cancelacion: ejecutando taskkill /PID $processId /T /F"
            $tk = Start-Process -FilePath $taskKill -ArgumentList @('/PID', [string]$processId, '/T', '/F') -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
            Write-DebugLog "Cancelacion: taskkill termino con codigo $($tk.ExitCode)"
        } else {
            Write-DebugLog "Cancelacion: taskkill.exe no encontrado. Usando Process.Kill()."
            $Process.Kill()
        }

        try { [void]$Process.WaitForExit(5000) } catch {}
        return $true
    }
    catch {
        Write-AppLog "Stop-DownloadProcessTree taskkill error: $($_.Exception.Message)"
        try {
            if (-not $Process.HasExited) {
                $Process.Kill()
                try { [void]$Process.WaitForExit(5000) } catch {}
            }
            return $true
        }
        catch {
            Write-AppLog "Stop-DownloadProcessTree fallback kill error: $($_.Exception.Message)"
            return $false
        }
    }
}

function Get-ProcessExitCodeSafe {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) { return $null }

    try {
        # En algunas versiones de PowerShell/Windows Forms, Start-Process puede dejar ExitCode vacío
        # si no se llama explícitamente a WaitForExit() después de HasExited.
        if (-not $Process.HasExited) {
            [void]$Process.WaitForExit(3000)
        } else {
            [void]$Process.WaitForExit()
        }
        $Process.Refresh()
        return $Process.ExitCode
    }
    catch {
        Write-AppLog "No se pudo leer ExitCode del proceso: $($_.Exception.Message)"
        return $null
    }
}

function Finish-DownloadProcess {
    try {
        if ($Script:DownloadTimer) {
            $Script:DownloadTimer.Stop()
        }

        # Ultima lectura para no perder las lineas finales.
        $out = Read-NewLinesFromFile -Path $Script:StdoutFile -PreviousCount $Script:StdoutLineCount
        $Script:StdoutLineCount = $out.Count
        foreach ($line in $out.Lines) { Append-Log $line; Update-ProgressFromLine $line }

        $err = Read-NewLinesFromFile -Path $Script:StderrFile -PreviousCount $Script:StderrLineCount
        $Script:StderrLineCount = $err.Count
        foreach ($line in $err.Lines) { Append-Log $line; Update-ProgressFromLine $line }

        $stdoutRaw = Get-RawFileTextSafe -Path $Script:StdoutFile
        $stderrRaw = Get-RawFileTextSafe -Path $Script:StderrFile
        $combinedRaw = $stdoutRaw + "`n" + $stderrRaw

        if ($Script:CancellationRequested) {
            Set-ControlsForDownload -Downloading $false
            $progressBar.Style = 'Continuous'
            $lblStatus.Text = 'Descarga cancelada por el usuario.'
            $lblProgress.Text = 'Progreso cancelado.'
            if ($lblPlaylistProgress) {
                if ($Script:PlaylistCurrent -and $Script:PlaylistTotal) {
                    $lblPlaylistProgress.Text = ('Lista cancelada en archivo {0} de {1}' -f $Script:PlaylistCurrent, $Script:PlaylistTotal)
                } else {
                    $lblPlaylistProgress.Text = 'Lista/descarga cancelada.'
                }
            }
            Append-Log 'Descarga cancelada por el usuario. Se ha detenido yt-dlp y sus procesos hijos.'
            Write-AppLog 'Descarga cancelada por el usuario.'
            Add-HistoryEntry -Status 'Cancelado' -Message 'Descarga cancelada por el usuario.'
            return
        }

        $exitCode = Get-ProcessExitCodeSafe -Process $Script:CurrentProcess
        if ($null -eq $exitCode) {
            # Fallback defensivo: si yt-dlp ha terminado claramente bien, no marcamos falso error.
            $hasRealError = ($combinedRaw -match '(?m)^ERROR:')
            $looksCompleted = (
                ($combinedRaw -match '(?m)^\[download\]\s+100%') -or
                ($combinedRaw -match '(?m)^\[Merger\]\s+Merging formats into') -or
                ($combinedRaw -match '(?m)^Deleting original file') -or
                ($combinedRaw -match '(?m)has already been downloaded')
            )

            if ($looksCompleted -and -not $hasRealError) {
                $exitCode = 0
                Write-AppLog 'ExitCode nulo, pero la salida de yt-dlp indica finalizacion correcta. Se interpreta como correcto.'
            } else {
                $exitCode = -1
                Write-AppLog 'ExitCode nulo y no se pudo confirmar finalizacion correcta. Se marca como error -1.'
            }
        }

        Set-ControlsForDownload -Downloading $false

        if ([int]$exitCode -eq 0) {
            $progressBar.Style = 'Continuous'
            $progressBar.Value = 100
            if ($Script:PlaylistCurrent -and $Script:PlaylistTotal) {
                $lblProgress.Text = 'Progreso archivo: 100%'
                if ($lblPlaylistProgress) { $lblPlaylistProgress.Text = ('Lista terminada: {0} de {1}' -f $Script:PlaylistCurrent, $Script:PlaylistTotal) }
            } else {
                $lblProgress.Text = 'Progreso: 100%'
            }
            $lblStatus.Text = 'Descarga terminada correctamente.'
            $btnOpenFolder.Enabled = $true
            Append-Log 'Descarga terminada correctamente.'
            Write-AppLog 'Descarga terminada correctamente.'
            Add-HistoryEntry -Status 'Correcto' -Message 'Descarga terminada correctamente.'
            if (Get-ConfigBool 'OpenFolderWhenFinished' $false) {
                try { Start-Process explorer.exe -ArgumentList ('"' + $Script:LastFolder + '"') } catch { Write-AppLog "No se pudo abrir carpeta automaticamente: $($_.Exception.Message)" }
            }
            [System.Windows.Forms.MessageBox]::Show('Descarga terminada correctamente.', 'Finalizado', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            $progressBar.Style = 'Continuous'
            $lblStatus.Text = "Error en la descarga. Codigo: $exitCode"
            Append-Log "ERROR: yt-dlp termino con codigo $exitCode"
            Write-AppLog "yt-dlp termino con codigo $exitCode. Ver debug: $Script:DebugLog"
            Add-HistoryEntry -Status 'Error' -Message ("Codigo: $exitCode")

            $extraHelp = ''
            if ($combinedRaw -match 'HTTP Error 403|Forbidden') {
                $extraHelp = "`r`n`r`nSe ha detectado HTTP 403 de YouTube. Esta version incluye Deno/EJS para solucionarlo en la mayoria de casos. Si sigue pasando, prueba a cerrar y abrir la app para actualizar dependencias, o prueba otro enlace por si YouTube esta bloqueando ese video concreto."
            }

            [System.Windows.Forms.MessageBox]::Show("La descarga termino con error. Codigo: $exitCode$extraHelp`r`n`r`nRevisa el registro inferior y el archivo:`r`n$Script:DebugLog", 'Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
    catch {
        Write-AppLog "Finish-DownloadProcess error: $($_.Exception.ToString())"
        Show-ErrorMessage -Title 'Error cerrando descarga' -Message $_.Exception.Message
    }
    finally {
        try { if ($Script:CurrentProcess) { $Script:CurrentProcess.Dispose() } } catch {}
        $Script:CurrentProcess = $null
        try { if ($Script:DownloadTimer) { $Script:DownloadTimer.Dispose() } } catch {}
        $Script:DownloadTimer = $null
    }
}


function Remove-DownloadedDependencies {
    try {
        foreach ($name in @('yt-dlp.exe','ffmpeg.exe','ffprobe.exe','ffplay.exe','deno.exe')) {
            $target = Join-Path $Script:AppDir $name
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        }
        Get-ChildItem -LiteralPath $Script:AppDir -File -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
        }
    } catch {
        Write-AppLog "Remove-DownloadedDependencies error: $($_.Exception.Message)"
        throw
    }
}

function Update-ComponentsFromUi {
    try {
        if ($Script:IsDownloading) {
            [System.Windows.Forms.MessageBox]::Show('No se pueden actualizar componentes durante una descarga.', 'Descarga en curso', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Esto borrara y descargara de nuevo yt-dlp, FFmpeg y Deno.`r`n`r`nQuieres continuar?",
            'Actualizar componentes',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        Append-Log 'Actualizando componentes...'
        $lblStatus.Text = 'Actualizando componentes...'
        Remove-DownloadedDependencies
        Install-Dependencies
        Append-Log 'Componentes actualizados correctamente.'
        $lblStatus.Text = 'Componentes actualizados correctamente.'
        [System.Windows.Forms.MessageBox]::Show('Componentes actualizados correctamente.', 'Actualizacion terminada', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        Append-Log ('ERROR actualizando componentes: ' + $_.Exception.Message)
        Show-ErrorMessage -Title 'Error actualizando componentes' -Message $_.Exception.Message
    }
}

function Clean-TemporaryFilesFromUi {
    try {
        if ($Script:IsDownloading) {
            [System.Windows.Forms.MessageBox]::Show('No se deben limpiar temporales durante una descarga.', 'Descarga en curso', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $folder = $txtFolder.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder)) {
            [System.Windows.Forms.MessageBox]::Show('Selecciona primero una carpeta de destino valida.', 'Carpeta no valida', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Se borraran archivos temporales/incompletos de yt-dlp en la carpeta seleccionada.`r`n`r`nNo se borraran MP4/MP3 terminados normales.`r`n`r`nQuieres continuar?",
            'Limpiar temporales',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $patterns = @('*.part','*.ytdl','*.ytdl.part','*.temp','*.tmp','*.download','*.frag','*.part-Frag*','ytdl_stdout_*.log','ytdl_stderr_*.log')
        $deleted = 0
        foreach ($pattern in $patterns) {
            Get-ChildItem -LiteralPath $folder -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                    $deleted++
                } catch {
                    Write-AppLog "No se pudo borrar temporal: $($_.FullName) - $($_.Exception.Message)"
                }
            }
        }

        Get-ChildItem -LiteralPath $env:TEMP -File -Filter 'ytdl_*' -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $deleted++ } catch {}
        }

        Append-Log ("Limpieza terminada. Archivos eliminados: $deleted")
        [System.Windows.Forms.MessageBox]::Show("Limpieza terminada.`r`nArchivos eliminados: $deleted", 'Limpiar temporales', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        Show-ErrorMessage -Title 'Error limpiando temporales' -Message $_.Exception.Message
    }
}


function Clear-LogsFromUi {
    try {
        if ($Script:IsDownloading) {
            [System.Windows.Forms.MessageBox]::Show('No se pueden borrar los logs mientras hay una descarga en curso.', 'Borrar logs', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $logFiles = @($Script:ErrorLog, $Script:DebugLog)
        $existing = @($logFiles | Where-Object { Test-Path -LiteralPath $_ })
        if ($existing.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No hay logs para borrar.', 'Borrar logs', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        $totalBytes = 0
        foreach ($file in $existing) {
            try { $totalBytes += (Get-Item -LiteralPath $file -ErrorAction SilentlyContinue).Length } catch {}
        }

        $confirmText = "Se borraran los logs tecnicos de la aplicacion:`r`n`r`n- YtDOWNLOADER_error.log`r`n- YtDOWNLOADER_debug.log`r`n`r`nEspacio aproximado a liberar: $(Format-BytesHuman $totalBytes)`r`n`r`nQuieres continuar?"
        $confirm = [System.Windows.Forms.MessageBox]::Show($confirmText, 'Borrar logs', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $deleted = 0
        foreach ($file in $existing) {
            try {
                Remove-Item -LiteralPath $file -Force -ErrorAction Stop
                $deleted++
            } catch {
                # Si algun log esta bloqueado, lo vaciamos como alternativa.
                try { Clear-Content -LiteralPath $file -ErrorAction SilentlyContinue } catch {}
            }
        }

        Append-Log "Logs borrados. Archivos eliminados/vaciados: $deleted."
        [System.Windows.Forms.MessageBox]::Show("Logs borrados correctamente.`r`nArchivos eliminados/vaciados: $deleted`r`nEspacio liberado aproximado: $(Format-BytesHuman $totalBytes)", 'Borrar logs', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        Show-ErrorMessage -Title 'Error borrando logs' -Message $_.Exception.Message
    }
}

function Get-FriendlyDownloadError {
    param([string]$Raw, [object]$ExitCode)

    if ($Raw -match 'HTTP Error 403|Forbidden') {
        return "YouTube ha bloqueado temporalmente la descarga o faltan datos para resolver el enlace. Prueba a actualizar componentes, usar Deno/cookies del navegador o intentarlo mas tarde."
    }
    if ($Raw -match 'Sign in to confirm|age-restricted|This video may be inappropriate') {
        return "El video parece tener restriccion de edad o requiere sesion. Activa el modo avanzado y prueba cookies desde Chrome, Edge o Firefox."
    }
    if ($Raw -match 'Private video|Video unavailable|This video is unavailable') {
        return "El video no esta disponible publicamente, es privado o el enlace no se puede descargar."
    }
    if ($Raw -match 'ffmpeg|ffprobe') {
        return "Hay un problema con FFmpeg/FFprobe. Pulsa 'Actualizar componentes' y vuelve a probar."
    }
    if ($Raw -match 'No supported JavaScript runtime|js-runtimes|Deno') {
        return "yt-dlp necesita Deno para resolver JavaScript de YouTube. Pulsa 'Actualizar componentes' y vuelve a probar."
    }

    return "Revisa el registro inferior. Si el error se repite, prueba 'Actualizar componentes'. Codigo: $ExitCode"
}

function Test-DependenciesFromUi {
    try {
        $okYt = Test-YtDlpExe
        $okFf = Test-FfmpegExe
        $okDeno = Test-DenoExe
        if ($okYt -and $okFf -and $okDeno) {
            [System.Windows.Forms.MessageBox]::Show(
                "Dependencias correctas:`r`n`r`nyt-dlp.exe arranca bien.`r`nffmpeg.exe arranca bien.`r`ndeno.exe arranca bien.",
                'Comprobacion correcta',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Alguna dependencia no arranca correctamente.`r`n`r`nRevisa:`r`n$Script:ErrorLog`r`n`r`nPuedes borrar yt-dlp.exe, ffmpeg.exe, ffprobe.exe, deno.exe y ejecutar de nuevo el .bat.",
                'Problema detectado',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    } catch {
        Show-ErrorMessage -Title 'Error comprobando dependencias' -Message $_.Exception.Message
    }
}

function Start-Download {
    try {
        if ($Script:IsDownloading) { return }

        $videoUrl = $txtUrl.Text.Trim()
        $outputFolder = $txtFolder.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($videoUrl)) {
            [System.Windows.Forms.MessageBox]::Show('Pega primero el enlace del video.', 'Falta el enlace', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if ([string]::IsNullOrWhiteSpace($outputFolder) -or -not (Test-Path -LiteralPath $outputFolder)) {
            [System.Windows.Forms.MessageBox]::Show('Selecciona una carpeta de destino valida.', 'Carpeta no valida', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if (-not (Test-YtDlpExe)) {
            [System.Windows.Forms.MessageBox]::Show("yt-dlp.exe no se puede ejecutar. Borra yt-dlp.exe y abre de nuevo YtDOWNLOADER.bat.`r`n`r`nDetalle: $Script:ErrorLog", 'Problema con yt-dlp', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }

        if (-not (Test-FfmpegExe)) {
            [System.Windows.Forms.MessageBox]::Show("ffmpeg.exe no se puede ejecutar. Borra ffmpeg.exe y ffprobe.exe y abre de nuevo YtDOWNLOADER.bat.`r`n`r`nDetalle: $Script:ErrorLog", 'Problema con FFmpeg', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }

        if (-not (Test-DenoExe)) {
            [System.Windows.Forms.MessageBox]::Show("deno.exe no se puede ejecutar. Borra deno.exe y abre de nuevo YtDOWNLOADER.bat.`r`n`r`nDetalle: $Script:ErrorLog", 'Problema con Deno', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }

        $Script:LastFolder = $outputFolder
        $Script:CancellationRequested = $false
        $Script:PlaylistCurrent = $null
        $Script:PlaylistTotal = $null
        $Script:CurrentOutputName = ''
        if ($lblPlaylistProgress) {
            if ($chkPlaylist -and $chkPlaylist.Checked) { $lblPlaylistProgress.Text = 'Lista: esperando informacion de yt-dlp...' }
            else { $lblPlaylistProgress.Text = 'Lista: no activa' }
        }
        Save-CurrentUiToConfig
        $outputFolder = Get-EffectiveOutputFolder -BaseFolder $outputFolder -Mode ([string]$cmbMode.SelectedItem)
        $Script:LastFolder = $outputFolder
        $Script:StdoutFile = Join-Path $env:TEMP ('ytdl_stdout_' + [guid]::NewGuid().ToString('N') + '.log')
        $Script:StderrFile = Join-Path $env:TEMP ('ytdl_stderr_' + [guid]::NewGuid().ToString('N') + '.log')
        New-Item -ItemType File -Path $Script:StdoutFile -Force | Out-Null
        New-Item -ItemType File -Path $Script:StderrFile -Force | Out-Null
        $Script:StdoutLineCount = 0
        $Script:StderrLineCount = 0

        $arguments = New-Object System.Collections.Generic.List[string]
        $arguments.Add('--newline')
        $arguments.Add('--progress')
        $arguments.Add('--no-color')
        $arguments.Add('--windows-filenames')
        $arguments.Add('--no-mtime')
        $arguments.Add('--ffmpeg-location')
        $arguments.Add((Quote-Argument $Script:AppDir))
        # YouTube actual requiere resolver retos JavaScript. Usamos Deno local para que yt-dlp no dependa del PATH del sistema.
        $arguments.Add('--js-runtimes')
        $arguments.Add((Quote-Argument ("deno:$Script:Deno")))
        # Fallback oficial para que yt-dlp pueda actualizar los scripts EJS si el ejecutable no los trae o quedan antiguos.
        $arguments.Add('--remote-components')
        $arguments.Add('ejs:github')
        $arguments.Add('-P')
        $arguments.Add((Quote-Argument $outputFolder))

        $downloadPlaylist = $false
        if ($chkPlaylist) { $downloadPlaylist = [bool]$chkPlaylist.Checked }
        if ($downloadPlaylist) {
            $arguments.Add('--yes-playlist')
            $arguments.Add('-o')
            $arguments.Add((Quote-Argument (Get-OutputTemplate -TemplateName (Get-ConfigString 'FileNameTemplate' 'Titulo + ID') -Playlist $true)))
        } else {
            $arguments.Add('--no-playlist')
            $arguments.Add('-o')
            $arguments.Add((Quote-Argument (Get-OutputTemplate -TemplateName (Get-ConfigString 'FileNameTemplate' 'Titulo + ID') -Playlist $false)))
        }

        $cookiesBrowser = Get-ConfigString 'CookiesBrowser' 'No usar'
        if ($cookiesBrowser -ne 'No usar') {
            $arguments.Add('--cookies-from-browser')
            $arguments.Add($cookiesBrowser.ToLowerInvariant())
        }

        if ($cmbMode.SelectedItem -eq 'Solo MP3') {
            $audioQuality = [string]$cmbQuality.SelectedItem
            if ([string]::IsNullOrWhiteSpace($audioQuality)) { $audioQuality = Get-ConfigString 'AudioQuality' 'Mejor calidad MP3 (0)' }
            $Script:Config['AudioQuality'] = $audioQuality
            $arguments.Add('-x')
            $arguments.Add('--audio-format')
            $arguments.Add('mp3')
            $arguments.Add('--audio-quality')
            $arguments.Add((Quote-Argument (Get-AudioQualityArgument -QualityText $audioQuality)))
        } else {
            $videoQuality = [string]$cmbQuality.SelectedItem
            if ([string]::IsNullOrWhiteSpace($videoQuality)) { $videoQuality = Get-ConfigString 'Quality' 'Mejor calidad disponible' }
            $Script:Config['Quality'] = $videoQuality
            $format = Get-VideoFormat -QualityText $videoQuality
            $arguments.Add('-f')
            $arguments.Add((Quote-Argument $format))
            $arguments.Add('--merge-output-format')
            $arguments.Add('mp4')
        }

        $arguments.Add((Quote-Argument $videoUrl))
        $argumentLine = ($arguments -join ' ')

        $txtLog.Clear()
        Append-Log 'Iniciando descarga...'
        Append-Log "Comando: yt-dlp.exe $argumentLine"
        Append-Log "Destino: $outputFolder"
        Append-Log "Modo: $($cmbMode.SelectedItem)"
        if ($cmbMode.SelectedItem -eq 'Video') { Append-Log "Calidad video: $($cmbQuality.SelectedItem)" } else { Append-Log "Calidad MP3: $($cmbQuality.SelectedItem)" }
        Append-Log "Playlist completa: $downloadPlaylist"
        Append-Log "Formato nombre: $(Get-ConfigString 'FileNameTemplate' 'Titulo + ID')"
        Append-Log "Subcarpetas Video/MP3: $(Get-ConfigBool 'UseSubfolders' $false)"
        Append-Log "Cookies navegador: $(Get-ConfigString 'CookiesBrowser' 'No usar')"
        Append-Log "Stdout temporal: $Script:StdoutFile"
        Append-Log "Stderr temporal: $Script:StderrFile"

        $progressBar.Style = 'Continuous'
        $progressBar.Value = 0
        $lblProgress.Text = 'Progreso: 0%'
        $lblStatus.Text = 'Preparando descarga...'
        Set-ControlsForDownload -Downloading $true

        $Script:CurrentProcess = Start-Process -FilePath $Script:YtDlp -ArgumentList $argumentLine -WorkingDirectory $Script:AppDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $Script:StdoutFile -RedirectStandardError $Script:StderrFile -ErrorAction Stop
        $Script:StartTime = Get-Date

        $Script:DownloadTimer = New-Object System.Windows.Forms.Timer
        $Script:DownloadTimer.Interval = 500
        $Script:DownloadTimer.Add_Tick({ Poll-DownloadProcess })
        $Script:DownloadTimer.Start()
        $lblStatus.Text = 'Descargando...'
    }
    catch {
        Set-ControlsForDownload -Downloading $false
        $lblStatus.Text = 'Error al iniciar la descarga.'
        Append-Log "ERROR: $($_.Exception.Message)"
        Write-AppLog "Start-Download error: $($_.Exception.ToString())"
        [System.Windows.Forms.MessageBox]::Show("No se pudo iniciar la descarga:`r`n$($_.Exception.Message)`r`n`r`nRevisa:`r`n$Script:ErrorLog", 'Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Cancel-Download {
    try {
        if (-not $Script:IsDownloading) { return }

        if ($Script:CurrentProcess -and -not $Script:CurrentProcess.HasExited) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Quieres cancelar la descarga actual?`r`n`r`nSi es una playlist, tambien se detendra la lista completa.",
                'Cancelar descarga',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )

            if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                $Script:CancellationRequested = $true
                $lblStatus.Text = 'Cancelando descarga...'
                Append-Log 'Cancelando descarga y procesos hijos...'

                [void](Stop-DownloadProcessTree -Process $Script:CurrentProcess)
                try { [void]$Script:CurrentProcess.WaitForExit(5000) } catch {}

                Finish-DownloadProcess
            }
        }
    } catch {
        Write-AppLog "Cancel-Download error: $($_.Exception.Message)"
        Append-Log "ERROR cancelando: $($_.Exception.Message)"
    }
}


try {
    Install-Dependencies

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    Load-AppConfig | Out-Null
    if (Get-ConfigBool 'IsFirstRun' $false) {
        [void](Show-SettingsDialog -FirstRun $true)
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = ($Script:AppName + ' - Version ' + $Script:AppVersion)
    $form.Size = New-Object System.Drawing.Size(930, 760)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 760)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Topmost = $false
    if (Test-Path -LiteralPath $Script:IconPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($Script:IconPath) } catch { Write-AppLog "No se pudo cargar icono: $($_.Exception.Message)" }
    }

    $lblUrl = New-Object System.Windows.Forms.Label
    $lblUrl.Text = 'Enlace de video o playlist:'
    $lblUrl.Location = New-Object System.Drawing.Point(15, 18)
    $lblUrl.Size = New-Object System.Drawing.Size(160, 22)
    $form.Controls.Add($lblUrl)

    $txtUrl = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location = New-Object System.Drawing.Point(15, 42)
    $txtUrl.Size = New-Object System.Drawing.Size(870, 24)
    $txtUrl.Anchor = 'Top,Left,Right'
    $form.Controls.Add($txtUrl)

    $lblFolder = New-Object System.Windows.Forms.Label
    $lblFolder.Text = 'Carpeta de destino:'
    $lblFolder.Location = New-Object System.Drawing.Point(15, 78)
    $lblFolder.Size = New-Object System.Drawing.Size(160, 22)
    $form.Controls.Add($lblFolder)

    $txtFolder = New-Object System.Windows.Forms.TextBox
    $txtFolder.Location = New-Object System.Drawing.Point(15, 102)
    $txtFolder.Size = New-Object System.Drawing.Size(650, 24)
    $txtFolder.Anchor = 'Top,Left,Right'
    $txtFolder.Text = Get-ConfigString 'DownloadFolder' (Get-DownloadsFolder)
    $form.Controls.Add($txtFolder)

    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = 'Elegir...'
    $btnFolder.Location = New-Object System.Drawing.Point(675, 100)
    $btnFolder.Size = New-Object System.Drawing.Size(90, 28)
    $btnFolder.Anchor = 'Top,Right'
    $btnFolder.Add_Click({
        try {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Selecciona la carpeta donde se guardara la descarga'
            $dialog.SelectedPath = $txtFolder.Text
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtFolder.Text = $dialog.SelectedPath
                $btnOpenFolder.Enabled = (Test-Path -LiteralPath $txtFolder.Text)
            }
        } catch { Show-ErrorMessage -Title 'Error seleccionando carpeta' -Message $_.Exception.Message }
    })
    $form.Controls.Add($btnFolder)

    $btnOpenFolder = New-Object System.Windows.Forms.Button
    $btnOpenFolder.Text = 'Abrir carpeta'
    $btnOpenFolder.Location = New-Object System.Drawing.Point(775, 100)
    $btnOpenFolder.Size = New-Object System.Drawing.Size(110, 28)
    $btnOpenFolder.Anchor = 'Top,Right'
    $btnOpenFolder.Enabled = $true
    $btnOpenFolder.Add_Click({
        try {
            $folderToOpen = $txtFolder.Text.Trim()
            if (Test-Path -LiteralPath $folderToOpen) {
                Start-Process explorer.exe -ArgumentList ('"' + $folderToOpen + '"')
            } else {
                [System.Windows.Forms.MessageBox]::Show('La carpeta seleccionada no existe.', 'Carpeta no encontrada', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        } catch { Show-ErrorMessage -Title 'Error abriendo carpeta' -Message $_.Exception.Message }
    })
    $form.Controls.Add($btnOpenFolder)

    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.Text = 'Tipo de descarga:'
    $lblMode.Location = New-Object System.Drawing.Point(15, 145)
    $lblMode.Size = New-Object System.Drawing.Size(120, 22)
    $form.Controls.Add($lblMode)

    $cmbMode = New-Object System.Windows.Forms.ComboBox
    $cmbMode.Location = New-Object System.Drawing.Point(145, 142)
    $cmbMode.Size = New-Object System.Drawing.Size(160, 24)
    $cmbMode.DropDownStyle = 'DropDownList'
    [void]$cmbMode.Items.Add('Video')
    [void]$cmbMode.Items.Add('Solo MP3')
    $modeDefault = Get-ConfigString 'Mode' 'Video'
    if ($cmbMode.Items.Contains($modeDefault)) { $cmbMode.SelectedItem = $modeDefault } else { $cmbMode.SelectedIndex = 0 }
    $form.Controls.Add($cmbMode)

    $lblQuality = New-Object System.Windows.Forms.Label
    $lblQuality.Text = 'Calidad:'
    $lblQuality.Location = New-Object System.Drawing.Point(330, 145)
    $lblQuality.Size = New-Object System.Drawing.Size(120, 22)
    $form.Controls.Add($lblQuality)

    $cmbQuality = New-Object System.Windows.Forms.ComboBox
    $cmbQuality.Location = New-Object System.Drawing.Point(455, 142)
    $cmbQuality.Size = New-Object System.Drawing.Size(430, 24)
    $cmbQuality.DropDownStyle = 'DropDownList'
    $form.Controls.Add($cmbQuality)

    $cmbMode.Add_SelectedIndexChanged({
        try {
            Sync-QualityComboForMode
            Save-CurrentUiToConfig
        } catch {}
    })
    Sync-QualityComboForMode

    $chkPlaylist = New-Object System.Windows.Forms.CheckBox
    $chkPlaylist.Text = 'Si es una lista de YouTube, descargar la playlist completa'
    $chkPlaylist.Location = New-Object System.Drawing.Point(145, 177)
    $chkPlaylist.Size = New-Object System.Drawing.Size(620, 24)
    $chkPlaylist.Checked = Get-ConfigBool 'DownloadPlaylist' $false
    $chkPlaylist.Add_CheckedChanged({ try { $Script:Config['DownloadPlaylist'] = [bool]$chkPlaylist.Checked; Save-AppConfig } catch {} })
    $form.Controls.Add($chkPlaylist)

    $chkOpenAfter = New-Object System.Windows.Forms.CheckBox
    $chkOpenAfter.Text = 'Abrir carpeta al terminar'
    $chkOpenAfter.Location = New-Object System.Drawing.Point(145, 203)
    $chkOpenAfter.Size = New-Object System.Drawing.Size(260, 24)
    $chkOpenAfter.Checked = Get-ConfigBool 'OpenFolderWhenFinished' $false
    $chkOpenAfter.Add_CheckedChanged({ try { $Script:Config['OpenFolderWhenFinished'] = [bool]$chkOpenAfter.Checked; Save-AppConfig } catch {} })
    $form.Controls.Add($chkOpenAfter)

    $btnDownload = New-Object System.Windows.Forms.Button
    $btnDownload.Text = 'Descargar'
    $btnDownload.Location = New-Object System.Drawing.Point(15, 238)
    $btnDownload.Size = New-Object System.Drawing.Size(110, 34)
    $btnDownload.Add_Click({ Start-Download })
    $form.Controls.Add($btnDownload)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancelar'
    $btnCancel.Location = New-Object System.Drawing.Point(140, 238)
    $btnCancel.Size = New-Object System.Drawing.Size(110, 34)
    $btnCancel.Enabled = $false
    $btnCancel.Add_Click({ Cancel-Download })
    $form.Controls.Add($btnCancel)

    $btnSettings = New-Object System.Windows.Forms.Button
    $btnSettings.Text = 'Configuracion'
    $btnSettings.Location = New-Object System.Drawing.Point(265, 238)
    $btnSettings.Size = New-Object System.Drawing.Size(125, 34)
    $btnSettings.Add_Click({
        try {
            $saved = Show-SettingsDialog -FirstRun $false
            if ($saved) {
                Apply-ConfigToMainControls
                Apply-AppThemeToControl -Control $form
                Set-ControlsForDownload -Downloading $Script:IsDownloading
            }
        } catch { Show-ErrorMessage -Title 'Error abriendo configuracion' -Message $_.Exception.Message }
    })
    $form.Controls.Add($btnSettings)

    $btnHistory = New-Object System.Windows.Forms.Button
    $btnHistory.Text = 'Historial'
    $btnHistory.Location = New-Object System.Drawing.Point(405, 238)
    $btnHistory.Size = New-Object System.Drawing.Size(120, 34)
    $btnHistory.Visible = $true
    $btnHistory.Enabled = $true
    $btnHistory.Add_Click({ Show-HistoryDialog })
    $form.Controls.Add($btnHistory)

    $btnClearHistory = New-Object System.Windows.Forms.Button
    $btnClearHistory.Text = 'Borrar historial'
    $btnClearHistory.Location = New-Object System.Drawing.Point(540, 238)
    $btnClearHistory.Size = New-Object System.Drawing.Size(130, 34)
    $btnClearHistory.Visible = $true
    $btnClearHistory.Enabled = (Get-ConfigBool 'EnableHistory' $false) -and (Test-Path -LiteralPath $Script:HistoryFile)
    $btnClearHistory.Add_Click({ Clear-HistoryFromUi; Update-HistoryButtonState })
    $form.Controls.Add($btnClearHistory)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = 'Preparado.'
    $lblStatus.Location = New-Object System.Drawing.Point(15, 330)
    $lblStatus.Size = New-Object System.Drawing.Size(870, 22)
    $lblStatus.Anchor = 'Top,Left,Right'
    $form.Controls.Add($lblStatus)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15, 355)
    $progressBar.Size = New-Object System.Drawing.Size(870, 24)
    $progressBar.Anchor = 'Top,Left,Right'
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Value = 0
    $form.Controls.Add($progressBar)

    $lblProgress = New-Object System.Windows.Forms.Label
    $lblProgress.Text = 'Progreso: 0%'
    $lblProgress.Location = New-Object System.Drawing.Point(15, 387)
    $lblProgress.Size = New-Object System.Drawing.Size(870, 22)
    $lblProgress.Anchor = 'Top,Left,Right'
    $form.Controls.Add($lblProgress)

    $lblPlaylistProgress = New-Object System.Windows.Forms.Label
    $lblPlaylistProgress.Text = 'Lista: no activa'
    $lblPlaylistProgress.Location = New-Object System.Drawing.Point(15, 409)
    $lblPlaylistProgress.Size = New-Object System.Drawing.Size(870, 22)
    $lblPlaylistProgress.Anchor = 'Top,Left,Right'
    $form.Controls.Add($lblPlaylistProgress)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location = New-Object System.Drawing.Point(15, 434)
    $txtLog.Size = New-Object System.Drawing.Size(870, 190)
    $txtLog.Anchor = 'Top,Bottom,Left,Right'
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.ReadOnly = $true
    $form.Controls.Add($txtLog)


    $btnCheck = New-Object System.Windows.Forms.Button
    $btnCheck.Text = 'Comprobar dependencias'
    $btnCheck.Location = New-Object System.Drawing.Point(15, 632)
    $btnCheck.Size = New-Object System.Drawing.Size(180, 32)
    $btnCheck.Anchor = 'Bottom,Left'
    $btnCheck.Add_Click({ Test-DependenciesFromUi })
    $form.Controls.Add($btnCheck)

    $btnUpdateComponents = New-Object System.Windows.Forms.Button
    $btnUpdateComponents.Text = 'Actualizar componentes'
    $btnUpdateComponents.Location = New-Object System.Drawing.Point(210, 632)
    $btnUpdateComponents.Size = New-Object System.Drawing.Size(180, 32)
    $btnUpdateComponents.Anchor = 'Bottom,Left'
    $btnUpdateComponents.Add_Click({ Update-ComponentsFromUi })
    $form.Controls.Add($btnUpdateComponents)

    $btnCleanTemp = New-Object System.Windows.Forms.Button
    $btnCleanTemp.Text = 'Limpiar temporales'
    $btnCleanTemp.Location = New-Object System.Drawing.Point(405, 632)
    $btnCleanTemp.Size = New-Object System.Drawing.Size(150, 32)
    $btnCleanTemp.Anchor = 'Bottom,Left'
    $btnCleanTemp.Add_Click({ Clean-TemporaryFilesFromUi })
    $form.Controls.Add($btnCleanTemp)

    $btnClearLogs = New-Object System.Windows.Forms.Button
    $btnClearLogs.Text = 'Borrar logs'
    $btnClearLogs.Location = New-Object System.Drawing.Point(570, 632)
    $btnClearLogs.Size = New-Object System.Drawing.Size(130, 32)
    $btnClearLogs.Anchor = 'Bottom,Left'
    $btnClearLogs.Add_Click({ Clear-LogsFromUi })
    $form.Controls.Add($btnClearLogs)

    $lnkYtDlp = New-Object System.Windows.Forms.LinkLabel
    $lnkYtDlp.Text = '2026 | Basado en: https://github.com/yt-dlp/yt-dlp'
    $lnkYtDlp.Location = New-Object System.Drawing.Point(15, 675)
    $lnkYtDlp.Size = New-Object System.Drawing.Size(870, 24)
    $lnkYtDlp.Anchor = 'Bottom,Left,Right'
    $footerUrl = 'https://github.com/yt-dlp/yt-dlp'
    $lnkYtDlp.LinkArea = New-Object System.Windows.Forms.LinkArea($lnkYtDlp.Text.IndexOf($footerUrl), $footerUrl.Length)
    $lnkYtDlp.Add_LinkClicked({
        try { Start-Process 'https://github.com/yt-dlp/yt-dlp' } catch { Show-ErrorMessage -Title 'Error abriendo enlace' -Message $_.Exception.Message }
    })
    $form.Controls.Add($lnkYtDlp)

    Apply-ConfigToMainControls
    Apply-AppThemeToControl -Control $form

    $form.Add_FormClosing({
        try {
            if ($Script:CurrentProcess -and -not $Script:CurrentProcess.HasExited) {
                $confirm = [System.Windows.Forms.MessageBox]::Show('Hay una descarga en curso. Quieres cerrar la aplicacion y cancelarla?', 'Descarga en curso', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($confirm -eq [System.Windows.Forms.DialogResult]::No) {
                    $_.Cancel = $true
                } else {
                    $Script:CancellationRequested = $true
                    try { [void](Stop-DownloadProcessTree -Process $Script:CurrentProcess) } catch {}
                }
            }
        } catch { Write-AppLog "FormClosing error: $($_.Exception.Message)" }
    })

    [void]$form.ShowDialog()
    if (-not $Script:IsDownloading) { Save-CurrentUiToConfig }
    Write-AppLog 'Aplicacion cerrada por el usuario.'
}
catch {
    Write-AppLog "Error general de la aplicacion: $($_.Exception.ToString())"
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show("La aplicacion encontro un error:`r`n$($_.Exception.Message)`r`n`r`nRevisa:`r`n$Script:ErrorLog", 'Error general', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {
        Write-Host "Error general: $($_.Exception.Message)"
    }
    exit 1
}
