# SPDX-License-Identifier: GPL-3.0-only
# 民办mac：仅操作自己的运行目录；外部启动项和显示设置都先备份。
Set-StrictMode -Version 2
$script:ProjectRoot = Split-Path $PSScriptRoot -Parent
$script:DataRoot = Join-Path $env:LOCALAPPDATA 'MinbanMac'
$script:RuntimeRoot = Join-Path $script:DataRoot 'Runtime'
$script:StatePath = Join-Path $script:DataRoot 'state.json'
$script:Warnings = New-Object 'System.Collections.Generic.List[string]'
$script:ProxyUrl = ''

function Read-Json([string]$Path) {
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}
function Write-Json([string]$Path, $Value) {
    $text = $Value | ConvertTo-Json -Depth 12
    $temporary = $Path + '.new'
    [IO.File]::WriteAllText($temporary, $text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Write-Status([string]$Text) {
    Write-Host ('[民办mac] ' + $Text)
}
function Add-Warning([string]$Text) {
    $script:Warnings.Add($Text)
    Write-Warning $Text
}
function Get-FileDigest([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Assert-OwnedPath([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        throw '目标不在民办mac数据目录内，停止操作。'
    }
    return $full
}
function Assert-Platform {
    if ([Environment]::OSVersion.Version.Build -lt 22000) {
        throw '此版本仅支持 Windows 11。'
    }
    if ([IntPtr]::Size -ne 8) { throw '请使用 64 位 Windows PowerShell。' }
    if (@(Get-CimInstance Win32_Processor | Where-Object Architecture -ne 9).Count -gt 0) {
        throw '此版本只适配 x64 Windows；暂不支持 ARM64。'
    }
}
function Initialize-DataDirectory {
    if (-not (Test-Path -LiteralPath $script:DataRoot)) {
        New-Item -ItemType Directory -Path $script:DataRoot | Out-Null
    }
    $ownerPath = Join-Path $script:DataRoot 'owner.json'
    if (Test-Path -LiteralPath $ownerPath) {
        if ((Read-Json $ownerPath).owner -ne 'minban-mac') { throw '数据目录归属不符。' }
    } else {
        if (Test-Path -LiteralPath $script:RuntimeRoot) {
            throw '同名 Runtime 目录已经存在，未覆盖；请改用空的数据目录。'
        }
        Write-Json $ownerPath @{ owner = 'minban-mac'; schema = 1 }
    }
    foreach ($name in @('Cache', 'Backups')) {
        $path = Join-Path $script:DataRoot $name
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
    }
}
function Receive-WebFile([string]$Url, [string]$Destination) {
    $request = @{
        Uri = $Url; OutFile = $Destination; UseBasicParsing = $true
        TimeoutSec = 600; ErrorAction = 'Stop'
    }
    if ($script:ProxyUrl) { $request.Proxy = $script:ProxyUrl }
    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        # Windows 11 自行选择安全协议；不关闭证书校验，也不永久改进程配置。
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::SystemDefault
        Invoke-WebRequest @request
    } finally { [Net.ServicePointManager]::SecurityProtocol = $oldProtocol }
}
function Get-SystemCurlPath {
    $path = Join-Path $env:WINDIR 'System32\curl.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    return ''
}
function Get-CurlArguments([string]$Url, [string]$Destination) {
    $arguments = @(
        '--disable', '--fail', '--location', '--silent', '--show-error',
        '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
        '--connect-timeout', '25', '--max-time', '600',
        '--output', $Destination, '--url', $Url
    )
    $proxy = $script:ProxyUrl
    if (-not $proxy) {
        # curl 不自动读取 Windows Internet 设置，尽量沿用原下载器的默认代理。
        $webProxy = [Net.WebRequest]::DefaultWebProxy
        if ($null -ne $webProxy) {
            $target = [Uri]$Url
            $resolved = $webProxy.GetProxy($target)
            if ($null -ne $resolved -and $resolved.AbsoluteUri -ne $target.AbsoluteUri) {
                $proxy = $resolved.AbsoluteUri
            }
        }
    }
    if ($proxy) { $arguments += @('--proxy', $proxy) }
    return ,$arguments
}
function Receive-CurlFile([string]$Url, [string]$Destination) {
    $curl = Get-SystemCurlPath
    if (-not $curl) { throw '未找到 Windows 自带下载器。' }
    $arguments = Get-CurlArguments $Url $Destination
    $oldPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 把原生程序的标准错误作为记录；统一按退出码判断。
        $ErrorActionPreference = 'Continue'
        $nativeOutput = & $curl @arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($code -ne 0) {
        $reason = '连接未完成'
        if ($code -eq 60) { $reason = '证书信任校验未通过' }
        elseif ($code -eq 35) { $reason = 'TLS 安全连接未建立' }
        elseif ($code -eq 28) { $reason = '连接超时' }
        elseif ($code -eq 22) { $reason = '服务器未提供所需文件' }
        # 不回显原生输出，避免把含凭据的个人代理地址写入错误提示。
        throw ('Windows 下载器错误 ' + $code + '：' + $reason + '。')
    }
}
function Test-TlsTrustFailure($Exception) {
    $current = $Exception
    for ($i = 0; $i -lt 20 -and $null -ne $current; $i++) {
        if ($current -is [Net.WebException] -and $current.Status -eq [Net.WebExceptionStatus]::TrustFailure) {
            return $true
        }
        if ($current.Message -match 'SSL/TLS|证书|信任关系|certificate|trust relationship|TLS 安全') { return $true }
        $current = $current.InnerException
    }
    return $false
}
function Write-DownloadHelp([string]$Url, [string]$Destination, [bool]$TrustFailure) {
    if ($TrustFailure) {
        Write-Host '安全连接校验失败。请先核对系统日期和时间、Windows 更新，以及代理或安全软件的 HTTPS 设置。'
    }
    Write-Host '也可以用浏览器打开以下官方地址，下载后双击“导入下载文件.cmd”，按提示拖入文件：'
    Write-Host $Url
    Write-Host ('需要的文件：' + [IO.Path]::GetFileName($Destination))
    Write-Host '导入成功后重新运行“应用民办mac.cmd”；无需删除缓存或恢复记录。'
}
function Get-PinnedFile([string]$Url, [string]$Sha256, [string]$Destination) {
    [void](Assert-OwnedPath $Destination $script:DataRoot)
    $uri = [Uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') { throw '只允许 HTTPS 官方下载。' }
    if (Test-Path -LiteralPath $Destination) {
        if ((Get-FileDigest $Destination) -eq $Sha256) { return $Destination }
        throw ('缓存校验失败，请检查或移走该文件后重试：' + $Destination)
    }
    $temporary = $Destination + '.download-' + [Guid]::NewGuid().ToString('N')
    $oldProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        try { Receive-WebFile $Url $temporary }
        catch {
            $primaryError = $_.Exception
            Write-Status '常规下载未完成，改用 Windows 自带下载器重试（仍校验证书）……'
            try { Receive-CurlFile $Url $temporary }
            catch {
                $fallbackError = $_.Exception
                Write-DownloadHelp $Url $Destination ((Test-TlsTrustFailure $primaryError) -or (Test-TlsTrustFailure $fallbackError))
                throw ('官方下载未完成。' + $fallbackError.Message)
            }
        }
        if ((Get-FileDigest $temporary) -ne $Sha256) {
            throw '下载文件的 SHA256 与固定版本清单不符，未运行该文件。'
        }
        Move-Item -LiteralPath $temporary -Destination $Destination
    } finally {
        $ProgressPreference = $oldProgress
        # 只清理本次生成的单个临时文件，保留正式缓存与恢复数据。
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $Destination
}
function Get-Manifest {
    return Read-Json (Join-Path $script:ProjectRoot 'dependencies.json')
}
function Get-BundledMods {
    $manifest = Get-Manifest
    if ($manifest.PSObject.Properties['bundledMods']) { return @($manifest.bundledMods) }
    return @()
}
function Get-AllMods { return @((Get-Manifest).mods) + @(Get-BundledMods) }
function Get-NoticeEnabled {
    $path = Join-Path $script:DataRoot 'preferences.local.json'
    if (Test-Path -LiteralPath $path) {
        $preferences = Read-Json $path
        if ($preferences.PSObject.Properties['noticeEnabled']) { return [bool]$preferences.noticeEnabled }
    }
    return $true
}
function Get-EnabledMods {
    return @(Get-AllMods | Where-Object { $_.id -ne 'minban-qq-notice' -or (Get-NoticeEnabled) })
}
function Get-BundledProjectFile([string]$RelativePath) {
    if ($RelativePath -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw '附带组件路径无效。'
    }
    return Assert-OwnedPath (Join-Path $script:ProjectRoot $RelativePath) $script:ProjectRoot
}
function Assert-BundledMods {
    foreach ($mod in @(Get-BundledMods)) {
        $binary = Get-BundledProjectFile $mod.binaryPath
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf) -or
            (Get-FileDigest $binary) -ne $mod.dllSha256) { throw '独立提醒组件缺失或校验失败，请重新完整解压 Beta 包。' }
        if ([IO.Path]::GetFileName($binary) -ne (Get-ModLibraryName $mod)) { throw '独立提醒程序版本与清单不符。' }
        $mainFound = $false
        foreach ($source in $mod.sourceFiles) {
            $path = Get-BundledProjectFile $source.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-FileDigest $path) -ne $source.sha256) { throw '独立提醒对应源码缺失或校验失败。' }
            if ($source.path -eq $mod.sourcePath) { $mainFound = $true }
        }
        if (-not $mainFound) { throw '独立提醒清单缺少主源码。' }
    }
}
function Set-NoticeEnabled([bool]$Enabled) {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { throw '请先运行“应用民办mac.cmd”。' }
    $state = Read-Json $script:StatePath
    $exe = Join-Path $script:RuntimeRoot 'windhawk.exe'
    if ($state.owner -ne 'minban-mac' -or $state.runtimeExe -ne $exe -or -not $state.active) {
        throw '本包尚未启用，请先运行“应用民办mac.cmd”。'
    }
    $mods = @(Get-BundledMods | Where-Object id -eq 'minban-qq-notice')
    if ($mods.Count -ne 1) { throw '独立提醒清单不完整。' }
    $path = Assert-OwnedPath (Join-Path $script:RuntimeRoot 'AppData\Engine\Mods\minban-qq-notice.ini') $script:RuntimeRoot
    $text = [IO.File]::ReadAllText($path)
    $expected = [regex]::Escape((Get-ModLibraryName $mods[0]))
    if ($text -notmatch ('(?m)^LibraryFileName=' + $expected + '\r?$') -or
        [regex]::Matches($text, '(?m)^Disabled=[01]\r?$').Count -ne 1) { throw '独立提醒配置被改变，未覆盖。' }
    $disabled = if ($Enabled) { '0' } else { '1' }
    $text = [regex]::Replace($text, '(?m)^Disabled=[01]', ('Disabled=' + $disabled))
    $text = [regex]::Replace($text, 'SettingsChangeTime=\d+', ('SettingsChangeTime=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
    [IO.File]::WriteAllText($path, $text, [Text.Encoding]::Unicode)
    Write-Json (Join-Path $script:DataRoot 'preferences.local.json') @{ noticeEnabled = $Enabled }
    Write-Status $(if ($Enabled) { '已开启独立图标提醒。' } else { '已关闭独立图标提醒，任务栏美化保留。' })
}
function Get-ModLibraryName($Mod) {
    return ($Mod.id + '_' + $Mod.version + '.dll')
}
function Get-DownloadEntries {
    $manifest = Get-Manifest
    $entries = @([pscustomobject]@{
        name = ('windhawk_setup_offline_' + $manifest.windhawk.version + '.exe')
        sha256 = $manifest.windhawk.sha256; installer = $true
    })
    foreach ($mod in $manifest.mods) {
        $entries += [pscustomobject]@{ name = Get-ModLibraryName $mod; sha256 = $mod.dllSha256; installer = $false }
        $entries += [pscustomobject]@{ name = ($mod.id + '.wh.cpp'); sha256 = $mod.sourceSha256; installer = $false }
    }
    return $entries
}
function Import-PinnedDownload([string]$Source) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw '未找到所选文件，请拖入下载完成的单个文件。' }
    $hash = Get-FileDigest $Source
    $matches = @(Get-DownloadEntries | Where-Object sha256 -eq $hash)
    if ($matches.Count -ne 1) { throw '文件与固定版本的官方组件不符，未导入。请使用下载失败时提示的官方地址。' }
    $entry = $matches[0]
    Initialize-DataDirectory
    $destination = Join-Path $script:DataRoot ('Cache\' + $entry.name)
    [void](Assert-OwnedPath $destination $script:DataRoot)
    if (Test-Path -LiteralPath $destination) {
        if ((Get-FileDigest $destination) -eq $hash) { Write-Status ('已有有效缓存：' + $entry.name); return }
        throw ('已有同名缓存校验失败，未覆盖；请先保留或移走：' + $destination)
    }
    $temporary = $destination + '.import-' + [Guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($entry.name)
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        if ((Get-FileDigest $temporary) -ne $entry.sha256) { throw '复制后的文件校验失败，未导入。' }
        if ($entry.installer -and (Get-AuthenticodeSignature -LiteralPath $temporary).Status -ne 'Valid') {
            throw '安装包数字签名验证未通过，未导入。请核对系统时间与 Windows 证书更新。'
        }
        Move-Item -LiteralPath $temporary -Destination $destination
        Write-Status ('已校验并导入：' + $entry.name)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
function New-ModConfiguration($Mod, [string]$Preset, [long]$Timestamp) {
    if ($Preset -notmatch '(?m)^\[Settings\]\s*$') { throw '预设缺少 Settings 段。' }
    $lines = @(
        '[Mod]', ('LibraryFileName=' + (Get-ModLibraryName $Mod)),
        'Disabled=0', 'LoggingEnabled=0', 'DebugLoggingEnabled=0',
        'Include=explorer.exe', 'Exclude=', 'IncludeCustom=', 'ExcludeCustom=',
        'IncludeExcludeCustomOnly=0', 'PatternsMatchCriticalSystemProcesses=0',
        'Architecture=x86-64', ('Version=' + $Mod.version),
        ('SettingsChangeTime=' + $Timestamp), '', $Preset.Trim(), ''
    )
    return ($lines -join [Environment]::NewLine)
}
function Ensure-Runtime {
    Assert-BundledMods
    $manifest = Get-Manifest
    $exe = Join-Path $script:RuntimeRoot 'windhawk.exe'
    $markerPath = Join-Path $script:RuntimeRoot 'minban-mac-runtime.json'
    if (Test-Path -LiteralPath $exe) {
        if (-not (Test-Path -LiteralPath $markerPath)) { throw '运行目录没有归属标记，停止覆盖。' }
        if ((Read-Json $markerPath).installerSha256 -ne $manifest.windhawk.sha256) {
            throw '已有运行目录版本不同，请先恢复，再手动保留或移走旧 Runtime 目录。'
        }
    } else {
        Write-Status '首次准备 Windhawk，下载约 142 MiB 官方离线安装包……'
        $installer = Get-PinnedFile $manifest.windhawk.url $manifest.windhawk.sha256 (
            Join-Path $script:DataRoot 'Cache\windhawk_setup_offline_1.7.3.exe')
        if ((Get-AuthenticodeSignature -LiteralPath $installer).Status -ne 'Valid') {
            throw '安装包数字签名验证未通过，未运行。'
        }
        Write-Status '安装独立便携运行目录；若 Windows 弹出权限提示，请核对官方签名。'
        $process = Start-Process -FilePath $installer -ArgumentList @(
            '/S', '/PORTABLE', ('/D=' + $script:RuntimeRoot)
        ) -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
            throw '便携运行目录安装失败；原任务栏尚未切换。'
        }
        Write-Json $markerPath @{ owner = 'minban-mac'; installerSha256 = $manifest.windhawk.sha256 }
    }
    $ini = [IO.File]::ReadAllText((Join-Path $script:RuntimeRoot 'windhawk.ini'))
    if ($ini -notmatch '(?m)^Portable=1\s*$') { throw '运行目录不是便携版，停止操作。' }
    foreach ($mod in $manifest.mods) {
        Write-Status ('准备模组：' + $mod.id)
        [void](Get-PinnedFile $mod.dllUrl $mod.dllSha256 (
            Join-Path $script:DataRoot ('Cache\' + (Get-ModLibraryName $mod))))
        [void](Get-PinnedFile $mod.sourceUrl $mod.sourceSha256 (
            Join-Path $script:DataRoot ('Cache\' + $mod.id + '.wh.cpp')))
    }
    return $exe
}
function Write-RuntimeConfiguration {
    Assert-BundledMods
    $manifest = Get-Manifest
    $appData = Join-Path $script:RuntimeRoot 'AppData'
    $modsPath = Join-Path $appData 'Engine\Mods'
    $binaryPath = Join-Path $modsPath '64'
    $sourcePath = Join-Path $appData 'ModsSource'
    foreach ($path in @($modsPath, $binaryPath, $sourcePath)) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
    }
    $shimSource = Join-Path $script:RuntimeRoot 'Compiler\x86_64-w64-mingw32\bin'
    foreach ($pair in @(
        @('libc++.dll', 'libc++.whl'), @('libunwind.dll', 'libunwind.whl'),
        @('windhawk-mod-shim.dll', 'windhawk-mod-shim.dll')
    )) {
        Copy-Item -LiteralPath (Join-Path $shimSource $pair[0]) -Destination (Join-Path $binaryPath $pair[1]) -Force
    }
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($mod in @(Get-AllMods)) {
        if ($mod.PSObject.Properties['binaryPath']) {
            Copy-Item -LiteralPath (Get-BundledProjectFile $mod.binaryPath) -Destination (Join-Path $binaryPath (Get-ModLibraryName $mod)) -Force
            foreach ($source in $mod.sourceFiles) {
                Copy-Item -LiteralPath (Get-BundledProjectFile $source.path) -Destination (Join-Path $sourcePath ([IO.Path]::GetFileName($source.path))) -Force
            }
        } else {
            Copy-Item -LiteralPath (Join-Path $script:DataRoot ('Cache\' + (Get-ModLibraryName $mod))) -Destination (
                Join-Path $binaryPath (Get-ModLibraryName $mod)) -Force
            Copy-Item -LiteralPath (Join-Path $script:DataRoot ('Cache\' + $mod.id + '.wh.cpp')) -Destination (
                Join-Path $sourcePath ($mod.id + '.wh.cpp')) -Force
        }
        $preset = [IO.File]::ReadAllText((Join-Path $script:ProjectRoot ('presets\' + $mod.id + '.settings.ini')))
        $config = New-ModConfiguration $mod $preset $timestamp
        if ($mod.id -eq 'minban-qq-notice' -and -not (Get-NoticeEnabled)) {
            $config = $config.Replace('Disabled=0', 'Disabled=1')
        }
        [IO.File]::WriteAllText((Join-Path $modsPath ($mod.id + '.ini')), $config, [Text.Encoding]::Unicode)
    }
    $engineConfig = @(
        '[Settings]', 'LoggingVerbosity=0', 'Include=explorer.exe', 'Exclude=',
        'ThreadAttachExempt=', 'InjectIntoCriticalProcesses=0',
        'InjectIntoIncompatiblePrograms=0', 'InjectIntoGames=0', ''
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $appData 'Engine\settings.ini'), $engineConfig, [Text.Encoding]::Unicode)
}
function Get-SessionProcesses([string]$Name) {
    $session = (Get-Process -Id $PID).SessionId
    return @(Get-CimInstance Win32_Process -Filter ("name = '" + $Name + "'") |
        Where-Object SessionId -eq $session)
}
function Get-ActionSignature($Task) {
    return ([ordered]@{
        actions = @($Task.Actions | Select-Object Execute, Arguments, WorkingDirectory)
        principal = $Task.Principal | Select-Object UserId, LogonType, RunLevel
    } | ConvertTo-Json -Compress -Depth 4)
}
function Get-SingleExecAction($Task) {
    # 系统任务可能使用 COM 处理程序等动作；不能假定每个动作都有 Execute。
    if ($null -eq $Task -or $null -eq $Task.PSObject.Properties['Actions']) { return $null }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1 -or $null -eq $actions[0]) { return $null }
    $action = $actions[0]
    foreach ($name in @('Execute', 'Arguments', 'WorkingDirectory')) {
        if ($null -eq $action.PSObject.Properties[$name]) { return $null }
    }
    if ($action.Execute -isnot [string] -or [string]::IsNullOrWhiteSpace($action.Execute)) {
        return $null
    }
    return $action
}
function Test-OwnStartupTask($Task, [string]$Exe) {
    $action = Get-SingleExecAction $Task
    if ($null -eq $action) { return $false }
    return (Test-CurrentUserTask $Task) -and $action.Execute -eq $Exe -and $action.Arguments -eq '-tray-only'
}
function Test-CurrentUserTask($Task) {
    if ($null -eq $Task -or $null -eq $Task.PSObject.Properties['Principal'] -or
        $null -eq $Task.Principal -or $null -eq $Task.Principal.PSObject.Properties['UserId']) {
        return $false
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $Task.Principal.UserId -in @($identity.Name, $identity.User.Value, $env:USERNAME)
}
function Get-RegistrySnapshot([string]$SubKey, [string]$Name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
    try {
        $exists = $null -ne $key -and @($key.GetValueNames()) -contains $Name
        $value = $null
        $kind = 'DWord'
        if ($exists) { $value = $key.GetValue($Name); $kind = [string]$key.GetValueKind($Name) }
        return [pscustomobject]@{
            key = $SubKey; name = $Name; exists = $exists; value = $value
            kind = $kind; desired = 0; changed = $false
        }
    } finally { if ($null -ne $key) { $key.Dispose() } }
}
function Set-SingleRegistryValue($Snapshot, [int]$Value, $State = $null) {
    # 不创建或重建已有注册表键，不修改权限，不绕过 Windows 的写入保护。
    $current = Get-RegistrySnapshot $Snapshot.key $Snapshot.name
    if ($current.exists -and $current.value -eq $Value) { return $true }
    $key = $null
    $oldDesired = $Snapshot.desired
    $oldChanged = $Snapshot.changed
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Snapshot.key, $true)
        if ($null -eq $key) { throw '注册表键不存在。' }
        $Snapshot.desired = $Value
        $Snapshot.changed = $true
        # 先持久化撤回信息，再写单个值；意外关闭窗口后仍能恢复。
        if ($null -ne $State) { Write-Json $script:StatePath $State }
        $key.SetValue($Snapshot.name, $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        return $true
    } catch {
        $Snapshot.desired = $oldDesired
        $Snapshot.changed = $oldChanged
        if ($null -ne $State) { Write-Json $script:StatePath $State }
        Add-Warning ('Windows 未接受设置 ' + $Snapshot.name + '；保留系统设置，请按说明手动调整。')
        return $false
    } finally { if ($null -ne $key) { $key.Dispose() } }
}
function Get-OwnTaskName {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return ('MinbanMac-Taskbar-' + $sid)
}
function Capture-PreviousState(
    [string]$OwnExe,
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup')
) {
    $previous = @()
    foreach ($process in (Get-SessionProcesses 'windhawk.exe')) {
        if ($process.ExecutablePath -eq $OwnExe) { continue }
        if (-not $process.ExecutablePath) { throw '无法识别已有 Windhawk 路径，未切换。' }
        $iniPath = Join-Path (Split-Path $process.ExecutablePath -Parent) 'windhawk.ini'
        if (-not (Test-Path -LiteralPath $iniPath) -or
            [IO.File]::ReadAllText($iniPath) -notmatch '(?m)^Portable=1\s*$') {
            throw '已有标准安装版 Windhawk 正在运行。请先通过其设置退出并关闭原启动服务，再使用本包。'
        }
        $previous += [pscustomobject]@{ path = $process.ExecutablePath; wasRunning = $true }
    }
    $services = @(Get-Service -Name '*Windhawk*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Running' -or $_.StartType -ne 'Disabled' })
    if ($services.Count -gt 0) { throw '检测到标准版 Windhawk 服务，未修改该服务；请先处理原安装。' }
    $tasks = @()
    foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
        if (-not (Test-CurrentUserTask $task)) { continue }
        if ($task.TaskName -eq (Get-OwnTaskName) -or -not $task.Settings.Enabled) { continue }
        $action = Get-SingleExecAction $task
        if ($null -eq $action) { continue }
        if ([IO.Path]::GetFileName($action.Execute.Trim('"')) -ieq 'windhawk.exe') {
            $tasks += [pscustomobject]@{
                name = $task.TaskName; path = $task.TaskPath; signature = Get-ActionSignature $task
            }
        }
    }
    $links = @()
    $startup = $StartupDirectory
    $shell = New-Object -ComObject WScript.Shell
    foreach ($file in @(Get-ChildItem -LiteralPath $startup -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
        $link = $shell.CreateShortcut($file.FullName)
        if ([IO.Path]::GetFileName($link.TargetPath) -ieq 'windhawk.exe') {
            $backup = Join-Path $script:DataRoot ('Backups\' + [Guid]::NewGuid().ToString('N') + '.lnk')
            Copy-Item -LiteralPath $file.FullName -Destination $backup
            $links += [pscustomobject]@{ path = $file.FullName; backup = $backup; sha256 = Get-FileDigest $file.FullName }
        }
    }
    $ttbKey = 'Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\28017CharlesMilette.TranslucentTB_v826wp6bftszj\TranslucentTB'
    return [pscustomobject]@{
        schema = 1; owner = 'minban-mac'; active = $false; runtimeExe = $OwnExe
        created = [DateTimeOffset]::Now.ToString('o')
        previousWindhawk = @($previous); previousTasks = @($tasks); previousLinks = @($links)
        ttbWasRunning = (@(Get-SessionProcesses 'TranslucentTB.exe').Count -gt 0)
        ttbStartup = Get-RegistrySnapshot $ttbKey 'State'
        nativeSearch = Get-RegistrySnapshot 'Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode'
        nativeAlignment = Get-RegistrySnapshot 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl'
        autostartType = ''; manualSearchRequired = $false
    }
}
function Stop-Windhawk([string]$Exe) {
    if (-not (Test-Path -LiteralPath $Exe)) { throw ('Windhawk 路径已不存在：' + $Exe) }
    $process = Start-Process -FilePath $Exe -ArgumentList @('-exit', '-wait', '-timeout', '15000') -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'Windhawk 未正常退出，停止切换，避免两套样式同时运行。' }
}
function Suspend-PreviousState($State) {
    foreach ($task in $State.previousTasks) {
        $current = Get-ScheduledTask -TaskName $task.name -TaskPath $task.path -ErrorAction Stop
        if ((Get-ActionSignature $current) -ne $task.signature) { throw '原 Windhawk 启动任务已变化，停止修改。' }
        Disable-ScheduledTask -TaskName $task.name -TaskPath $task.path | Out-Null
    }
    foreach ($link in $State.previousLinks) {
        if (Test-Path -LiteralPath $link.path) {
            if ((Get-FileDigest $link.path) -ne $link.sha256) { throw '原启动快捷方式已变化，停止修改。' }
            Remove-Item -LiteralPath $link.path
        }
    }
    foreach ($app in $State.previousWindhawk) { Stop-Windhawk $app.path }
    if ($State.ttbStartup.exists) {
        if (-not (Set-SingleRegistryValue $State.ttbStartup 1 $State)) { throw '无法暂停 TranslucentTB 自启动，未切换。' }
        Write-Json $script:StatePath $State
    }
    foreach ($process in (Get-SessionProcesses 'TranslucentTB.exe')) {
        Stop-Process -Id $process.ProcessId -ErrorAction Stop
    }
}
function Register-OwnStartup($State) {
    $name = Get-OwnTaskName
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $existing = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if (-not (Test-OwnStartupTask $existing $State.runtimeExe)) {
            throw '民办mac启动任务名称被其他任务占用，未覆盖。'
        }
    }
    $action = New-ScheduledTaskAction -Execute $State.runtimeExe -Argument '-tray-only' -WorkingDirectory $script:RuntimeRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT0S'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
    $definition = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description '民办mac：当前用户登录时加载独立便携任务栏预设。'
    Register-ScheduledTask -TaskName $name -TaskPath '\' -InputObject $definition -Force | Out-Null
    $State.autostartType = 'task'
    Write-Json $script:StatePath $State
}
function Remove-OwnStartup($State) {
    $name = Get-OwnTaskName
    $task = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        if (-not (Test-OwnStartupTask $task $State.runtimeExe)) {
            throw '启动任务被修改，未删除；请检查任务计划程序。'
        }
        Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false
    }
}
function Restore-RegistrySnapshot($Snapshot) {
    if (-not $Snapshot.changed) { return }
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Snapshot.key, $true)
        if ($null -eq $key) { Add-Warning '原设置键不存在，未新建。'; return }
        if ($key.GetValue($Snapshot.name) -ne $Snapshot.desired) {
            Add-Warning ('设置已被其他操作改变，保留当前值：' + $Snapshot.name); return
        }
        if ($Snapshot.exists) {
            $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], $Snapshot.kind)
            $key.SetValue($Snapshot.name, $Snapshot.value, $kind)
        } else { $key.DeleteValue($Snapshot.name, $false) }
    } catch {
        Add-Warning ('无法恢复设置，请手动检查：' + $Snapshot.name)
    } finally { if ($null -ne $key) { $key.Dispose() } }
}
function Restore-PreviousState($State) {
    try { Remove-OwnStartup $State }
    catch { Add-Warning ('未移除被改变的启动任务：' + $_.Exception.Message) }
    if (@(Get-SessionProcesses 'windhawk.exe' | Where-Object ExecutablePath -eq $State.runtimeExe).Count -gt 0) {
        Stop-Windhawk $State.runtimeExe
    }
    Restore-RegistrySnapshot $State.nativeSearch
    Restore-RegistrySnapshot $State.nativeAlignment
    Restore-RegistrySnapshot $State.ttbStartup
    foreach ($task in $State.previousTasks) {
        $current = Get-ScheduledTask -TaskName $task.name -TaskPath $task.path -ErrorAction SilentlyContinue
        if ($null -ne $current -and (Get-ActionSignature $current) -eq $task.signature) {
            Enable-ScheduledTask -TaskName $task.name -TaskPath $task.path | Out-Null
        } else { Add-Warning '原启动任务不存在或已被修改，未覆盖。' }
    }
    foreach ($link in $State.previousLinks) {
        if (-not (Test-Path -LiteralPath $link.path)) {
            if ((Get-FileDigest $link.backup) -ne $link.sha256) { throw '快捷方式备份校验失败。' }
            Copy-Item -LiteralPath $link.backup -Destination $link.path
        } elseif ((Get-FileDigest $link.path) -ne $link.sha256) {
            Add-Warning '原快捷方式位置已有新文件，未覆盖。'
        }
    }
    foreach ($app in $State.previousWindhawk) {
        if ($app.wasRunning -and (Test-Path -LiteralPath $app.path)) {
            Start-Process -FilePath $app.path -ArgumentList '-tray-only' -WindowStyle Hidden
        }
    }
    if ($State.ttbWasRunning) {
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList 'shell:AppsFolder\28017CharlesMilette.TranslucentTB_v826wp6bftszj!TranslucentTB' -WindowStyle Hidden
    }
    $State.active = $false
    Write-Json $script:StatePath $State
}
function Wait-RuntimeLoaded([string]$Exe, [int]$Seconds = 90) {
    $manifest = Get-Manifest
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $running = @(Get-SessionProcesses 'windhawk.exe' | Where-Object ExecutablePath -eq $Exe)
        if ($running.Count -gt 0) {
            foreach ($explorer in @(Get-Process explorer -ErrorAction SilentlyContinue |
                Where-Object SessionId -eq (Get-Process -Id $PID).SessionId)) {
                try {
                    $names = @($explorer.Modules | Select-Object -ExpandProperty ModuleName)
                    if (@(Get-EnabledMods | Where-Object { $names -notcontains (Get-ModLibraryName $_) }).Count -eq 0) {
                        return $true
                    }
                } catch { }
            }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}
function Invoke-Apply {
    Assert-Platform
    Initialize-DataDirectory
    $exe = Ensure-Runtime
    $state = $null
    $fresh = $true
    if (Test-Path -LiteralPath $script:StatePath) {
        $saved = Read-Json $script:StatePath
        if ($saved.owner -ne 'minban-mac' -or $saved.runtimeExe -ne $exe) { throw '恢复记录归属不符。' }
        if ($saved.active) { $state = $saved; $fresh = $false }
    }
    if ($fresh) {
        if (@(Get-SessionProcesses 'windhawk.exe' | Where-Object ExecutablePath -eq $exe).Count -gt 0) {
            throw '本包正在运行但没有有效的启用记录；为避免覆盖原始备份，停止应用。请保留本地数据并检查恢复记录。'
        }
        $collision = Get-ScheduledTask -TaskName (Get-OwnTaskName) -TaskPath '\' -ErrorAction SilentlyContinue
        if ($null -ne $collision) {
            if (-not (Test-OwnStartupTask $collision $exe)) {
                throw '同名登录任务已有其他内容，原方案尚未改变。'
            }
        }
        $state = Capture-PreviousState $exe
        # 在任何可见变更之前记录事务，窗口被关闭后仍能用恢复入口撤回。
        $state.active = $true
        Write-Json $script:StatePath $state
    } elseif (@(Get-SessionProcesses 'windhawk.exe' | Where-Object ExecutablePath -ne $exe).Count -gt 0) {
        throw '检测到另一套 Windhawk 正在运行，请先恢复或退出它，再重新应用。'
    }
    try {
        Write-Status '保存原设置并切换任务栏……'
        if ($fresh) { Suspend-PreviousState $state }
        $state.manualSearchRequired = -not (Set-SingleRegistryValue $state.nativeSearch 1 $state)
        [void](Set-SingleRegistryValue $state.nativeAlignment 1 $state)
        Write-Json $script:StatePath $state
        # 重新应用/升级前退出本包，避免覆盖已加载的 DLL。原始恢复记录继续保留。
        if (@(Get-SessionProcesses 'windhawk.exe' | Where-Object ExecutablePath -eq $exe).Count -gt 0) {
            Stop-Windhawk $exe
        }
        Write-RuntimeConfiguration
        Register-OwnStartup $state
        Start-Process -FilePath $exe -ArgumentList '-tray-only' -WindowStyle Hidden
        Write-Status '等待启用的模组加载；首次使用可能需要下载 Windows 符号……'
        if (-not (Wait-RuntimeLoaded $exe)) { throw '90 秒内未确认启用的模组加载，正在恢复原方案。' }
        $state.active = $true
        Write-Json $script:StatePath $state
        Write-Status '应用完成。原壁纸保留，下次登录自动加载。'
        if ($state.manualSearchRequired) {
            Write-Status '搜索模式需手动设置：Win+I → 个性化 → 任务栏 → 搜索 → 仅搜索图标。'
        }
    } catch {
        $originalError = $_.Exception.Message
        try { Restore-PreviousState $state }
        catch { Add-Warning ('自动恢复未完全完成：' + $_.Exception.Message + '；请保留本地恢复记录。') }
        throw $originalError
    }
}
function Invoke-Restore {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { Write-Status '没有本包的恢复记录，无需恢复。'; return }
    $state = Read-Json $script:StatePath
    if ($state.owner -ne 'minban-mac' -or $state.runtimeExe -ne (Join-Path $script:RuntimeRoot 'windhawk.exe')) {
        throw '恢复记录与本包运行目录不符，未执行。'
    }
    if (-not $state.active) { Write-Status '当前记录为未应用状态；无需重复恢复。'; return }
    Restore-PreviousState $state
    Write-Status '已退出民办mac并恢复原启动项。缓存和备份保留，方便下次切换。'
}
