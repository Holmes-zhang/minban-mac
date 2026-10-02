# SPDX-License-Identifier: GPL-3.0-only
# 隔离验证：不启动 Windhawk，不修改真实任务栏或登录任务。
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$project = Split-Path $PSScriptRoot -Parent
$checks = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('检查失败：' + $Message) }
    $script:checks++
}
foreach ($file in @(Get-ChildItem -LiteralPath $project -Recurse -Filter '*.ps1')) {
    if ($file.FullName -like '*\dist\*') { continue }
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) ('语法：' + $file.Name)
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    Assert-True ($bytes.Length -gt 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF-8 BOM：' + $file.Name)
}
. (Join-Path $project 'scripts\Core.ps1')
$manifest = Get-Manifest
Assert-True ($manifest.name -eq '民办mac' -and $manifest.mods.Count -eq 4) '项目与模组数量'
Assert-True ($manifest.windhawk.sha256 -match '^[A-F0-9]{64}$') '安装包哈希格式'
foreach ($mod in $manifest.mods) {
    Assert-True ($mod.dllSha256 -match '^[A-F0-9]{64}$' -and $mod.sourceSha256 -match '^[A-F0-9]{64}$') ('哈希格式：' + $mod.id)
    Assert-True ($mod.dllUrl.StartsWith('https://mods.windhawk.net/mods/') -and $mod.sourceUrl.StartsWith('https://mods.windhawk.net/mods/')) '官方模组来源'
    $preset = [IO.File]::ReadAllText((Join-Path $project ('presets\' + $mod.id + '.settings.ini')))
    $config = New-ModConfiguration $mod $preset 123
    Assert-True ($config.Contains('LibraryFileName=' + (Get-ModLibraryName $mod)) -and $config.Contains('SettingsChangeTime=123')) '配置指向正确库'
    Assert-True ($config -notmatch '(?im)Content:=|SearchBox|C:\\Users\\|D:\\|trial\.dll') '预设不裁切搜索、不含个人路径'
}

# 所有文件、模拟启动项和测试注册表值均放在独立位置。
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('MinbanMac-Validation-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$script:DataRoot = Join-Path $sandbox 'Data'
$script:RuntimeRoot = Join-Path $script:DataRoot 'Runtime'
$script:StatePath = Join-Path $script:DataRoot 'state.json'
Initialize-DataDirectory
$owner = Read-Json (Join-Path $script:DataRoot 'owner.json')
Assert-True ($owner.owner -eq 'minban-mac') '独立目录归属'
$escaped = $false
try { [void](Assert-OwnedPath (Join-Path $sandbox 'outside.bin') $script:DataRoot) }
catch { $escaped = $true }
Assert-True $escaped '路径越界拒绝'

# 回归：混合的系统任务包含 COM 动作，首版会在这里直接读取缺失的 Execute。
$taskIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$taskPrincipal = [pscustomobject]@{
    UserId = $taskIdentity.Name; LogonType = 'Interactive'; RunLevel = 'Limited'
}
$comAction = [pscustomobject]@{ ClassId = '{00000000-0000-0000-0000-000000000001}'; Data = 'fixture' }
$execPath = Join-Path $sandbox 'previous\windhawk.exe'
$execAction = [pscustomobject]@{ Execute = $execPath; Arguments = '-tray-only'; WorkingDirectory = $sandbox }
$otherAction = [pscustomobject]@{ Execute = 'notepad.exe'; Arguments = ''; WorkingDirectory = '' }
$comTask = [pscustomobject]@{
    TaskName = 'ComFixture'; TaskPath = '\'; Principal = $taskPrincipal
    Settings = [pscustomobject]@{ Enabled = $true }; Actions = @($comAction)
}
$execTask = [pscustomobject]@{
    TaskName = 'WindhawkFixture'; TaskPath = '\'; Principal = $taskPrincipal
    Settings = [pscustomobject]@{ Enabled = $true }; Actions = @($execAction)
}
$emptyTask = [pscustomobject]@{
    TaskName = 'EmptyFixture'; TaskPath = '\'; Principal = $taskPrincipal
    Settings = [pscustomobject]@{ Enabled = $true }; Actions = @()
}
$multipleTask = [pscustomobject]@{
    TaskName = 'MultipleFixture'; TaskPath = '\'; Principal = $taskPrincipal
    Settings = [pscustomobject]@{ Enabled = $true }; Actions = @($execAction, $comAction)
}
$otherTask = [pscustomobject]@{
    TaskName = 'OtherProgramFixture'; TaskPath = '\'; Principal = $taskPrincipal
    Settings = [pscustomobject]@{ Enabled = $true }; Actions = @($otherAction)
}
$oldFailure = $false
try { [void]$comTask.Actions[0].Execute.Trim('"') } catch { $oldFailure = $true }
Assert-True $oldFailure '夹具能复现首版缺失 Execute 的故障'
Assert-True ($null -eq (Get-SingleExecAction $comTask)) '跳过 COM 动作'
Assert-True ($null -eq (Get-SingleExecAction $emptyTask)) '跳过空动作'
Assert-True ($null -eq (Get-SingleExecAction $multipleTask)) '不修改多个动作的任务'
Assert-True ($null -eq (Get-SingleExecAction ([pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = ''; Arguments = ''; WorkingDirectory = '' }) }))) '跳过空程序路径'
Assert-True ($null -eq (Get-SingleExecAction ([pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = 'windhawk.exe' }) }))) '跳过不完整动作'
Assert-True ((Get-SingleExecAction $execTask).Execute -eq $execPath) '保留正常程序动作'
Assert-True (-not (Test-OwnStartupTask $comTask $execPath)) '同名 COM 任务不被当成自有启动项'
Assert-True (Test-OwnStartupTask $execTask $execPath) '当前用户及正确动作匹配自有启动项'
Assert-True (-not (Test-OwnStartupTask $execTask (Join-Path $sandbox 'different.exe'))) '不同程序路径不匹配'
Assert-True (-not (Test-CurrentUserTask ([pscustomobject]@{ Principal = [pscustomobject]@{ GroupId = 'fixture-group' } }))) '仅有组身份的任务不被当作当前用户'
$emptyStartup = Join-Path $sandbox 'EmptyStartup'
New-Item -ItemType Directory -Path $emptyStartup | Out-Null
& {
    function Get-SessionProcesses { param($Name) return @() }
    function Get-Service { param($Name, $ErrorAction) return @() }
    function Get-ScheduledTask { param($ErrorAction) return @($comTask, $emptyTask, $multipleTask, $otherTask, $execTask) }
    function Get-RegistrySnapshot { param($SubKey, $Name)
        return [pscustomobject]@{ key = $SubKey; name = $Name; exists = $false; value = $null; kind = 'DWord'; desired = 0; changed = $false }
    }
    $captured = Capture-PreviousState (Join-Path $sandbox 'own\windhawk.exe') $emptyStartup
    Assert-True ($captured.previousTasks.Count -eq 1 -and $captured.previousTasks[0].name -eq 'WindhawkFixture') '完整混合任务扫描只记录单个 Windhawk 程序动作'
    Assert-True (-not $captured.active -and $captured.previousLinks.Count -eq 0) '扫描阶段不启用方案或记录无关快捷方式'
}

# 模拟网络响应；验证错误内容不能进入缓存或执行。
function Invoke-WebRequest { param($Uri, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction, $Proxy)
    [IO.File]::WriteAllText($OutFile, 'validated fixture')
}
$digestFile = Join-Path $sandbox 'digest.txt'
[IO.File]::WriteAllText($digestFile, 'validated fixture')
$hash = Get-FileDigest $digestFile
$cache = Join-Path $script:DataRoot 'Cache\fixture.bin'
[void](Get-PinnedFile 'https://example.invalid/fixture' $hash $cache)
Assert-True ((Get-FileDigest $cache) -eq $hash) '正确下载校验'
function Invoke-WebRequest { throw '不应重复下载' }
[void](Get-PinnedFile 'https://example.invalid/fixture' $hash $cache)
Assert-True ((Get-FileDigest $cache) -eq $hash) '缓存复用'
[IO.File]::WriteAllText($cache, 'tampered')
$rejected = $false
try { [void](Get-PinnedFile 'https://example.invalid/fixture' $hash $cache) } catch { $rejected = $true }
Assert-True $rejected '损坏缓存拒绝'
function Invoke-WebRequest { param($Uri, $OutFile, $UseBasicParsing, $TimeoutSec, $ErrorAction, $Proxy)
    [IO.File]::WriteAllText($OutFile, 'unexpected response')
}
$badDestination = Join-Path $script:DataRoot 'Cache\bad.bin'
$rejected = $false
try { [void](Get-PinnedFile 'https://example.invalid/fixture' $hash $badDestination) } catch { $rejected = $true }
Assert-True ($rejected -and -not (Test-Path -LiteralPath $badDestination)) '错误下载不成为正式缓存'

# 配置输出与编码：使用占位文件，不运行任何程序。
$shim = Join-Path $script:RuntimeRoot 'Compiler\x86_64-w64-mingw32\bin'
New-Item -ItemType Directory -Path $shim -Force | Out-Null
foreach ($name in @('libc++.dll', 'libunwind.dll', 'windhawk-mod-shim.dll')) {
    [IO.File]::WriteAllText((Join-Path $shim $name), 'placeholder')
}
foreach ($mod in $manifest.mods) {
    [IO.File]::WriteAllText((Join-Path $script:DataRoot ('Cache\' + (Get-ModLibraryName $mod))), 'placeholder')
    [IO.File]::WriteAllText((Join-Path $script:DataRoot ('Cache\' + $mod.id + '.wh.cpp')), 'placeholder source')
}
Write-RuntimeConfiguration
foreach ($mod in $manifest.mods) {
    $path = Join-Path $script:RuntimeRoot ('AppData\Engine\Mods\' + $mod.id + '.ini')
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert-True ($bytes[0] -eq 255 -and $bytes[1] -eq 254) 'Windhawk INI 编码'
}
Assert-True (Test-Path -LiteralPath (Join-Path $script:RuntimeRoot 'AppData\Engine\Mods\64\libc++.whl')) '运行库目标名称'

$testSubkey = 'Software\MinbanMacValidation-' + [Guid]::NewGuid().ToString('N')
$testKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testSubkey)
try {
    $testKey.SetValue('Search', 2, [Microsoft.Win32.RegistryValueKind]::DWord)
    $testKey.SetValue('Align', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
    $testKey.SetValue('TTB', 2, [Microsoft.Win32.RegistryValueKind]::DWord)
    $snapshot = Get-RegistrySnapshot $testSubkey 'Search'
    Assert-True (Set-SingleRegistryValue $snapshot 1) '单值修改'
    Restore-RegistrySnapshot $snapshot
    Assert-True ($testKey.GetValue('Search') -eq 2) '单值恢复'
    [void](Set-SingleRegistryValue $snapshot 1)
    $testKey.SetValue('Search', 7, [Microsoft.Win32.RegistryValueKind]::DWord)
    Restore-RegistrySnapshot $snapshot
    Assert-True ($testKey.GetValue('Search') -eq 7) '保留后续外部修改'
    $testKey.SetValue('Search', 2, [Microsoft.Win32.RegistryValueKind]::DWord)
    $absent = Get-RegistrySnapshot $testSubkey 'NewValue'
    [void](Set-SingleRegistryValue $absent 1)
    Restore-RegistrySnapshot $absent
    Assert-True (@($testKey.GetValueNames()) -notcontains 'NewValue') '原本不存在的值恢复为不存在'
    $already = Get-RegistrySnapshot $testSubkey 'Search'
    [void](Set-SingleRegistryValue $already 2)
    Assert-True (-not $already.changed) '无需修改时不标记变更'
    $testKey.SetValue('Search', 3, [Microsoft.Win32.RegistryValueKind]::DWord)
    [void](Set-SingleRegistryValue $already 2)
    Assert-True ($testKey.GetValue('Search') -eq 2) '重复应用读取当前值'
    $testKey.SetValue('Search', 2, [Microsoft.Win32.RegistryValueKind]::DWord)

    # 用模拟函数替代系统进程、真实任务与软件安装。
    $script:captures = 0
    $script:loaded = $true
    $script:taskEnabled = $true
    $script:stopCalls = 0
    $script:ownRegistered = $false
    $ownExe = Join-Path $script:RuntimeRoot 'windhawk.exe'
    [IO.File]::WriteAllText($ownExe, 'not executable')
    $oldExe = Join-Path $sandbox 'old-windhawk.exe'
    [IO.File]::WriteAllText($oldExe, 'not executable')
    $linkPath = Join-Path $sandbox 'startup-fixture.lnk'
    $linkBackup = Join-Path $script:DataRoot 'Backups\fixture.lnk'
    [IO.File]::WriteAllText($linkPath, 'fixture shortcut')
    Copy-Item -LiteralPath $linkPath -Destination $linkBackup
    $fakeTask = [pscustomobject]@{
        Actions = @([pscustomobject]@{ Execute = $oldExe; Arguments = '-tray-only'; WorkingDirectory = $sandbox })
        Principal = [pscustomobject]@{ UserId = 'fixture'; LogonType = 'Interactive'; RunLevel = 'Limited' }
    }
    $script:Fixture = [pscustomobject]@{
        owner = 'minban-mac'; schema = 1; runtimeExe = $ownExe; active = $false; created = 'fixture'
        previousTasks = @([pscustomobject]@{ name = 'Fixture'; path = '\'; signature = Get-ActionSignature $fakeTask })
        previousLinks = @([pscustomobject]@{ path = $linkPath; backup = $linkBackup; sha256 = Get-FileDigest $linkPath })
        previousWindhawk = @([pscustomobject]@{ path = $oldExe; wasRunning = $true })
        ttbWasRunning = $false; ttbStartup = Get-RegistrySnapshot $testSubkey 'TTB'
        nativeSearch = Get-RegistrySnapshot $testSubkey 'Search'
        nativeAlignment = Get-RegistrySnapshot $testSubkey 'Align'
        autostartType = ''; manualSearchRequired = $false
    }
    function Assert-Platform {}
    function Ensure-Runtime { return $ownExe }
    function Get-SessionProcesses { return @() }
    function Get-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction)
        if ($TaskName -eq 'Fixture') { return $fakeTask }
        return $null
    }
    function Capture-PreviousState { param($OwnExe)
        $script:captures++
        return ($script:Fixture | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    }
    function Disable-ScheduledTask { param($TaskName, $TaskPath)
        $saved = Read-Json $script:StatePath
        Assert-True $saved.active '暂停原启动项前已有撤回记录'
        $script:taskEnabled = $false
    }
    function Enable-ScheduledTask { param($TaskName, $TaskPath) $script:taskEnabled = $true }
    function Stop-Windhawk { param($Exe) $script:stopCalls++ }
    function Register-OwnStartup { param($State)
        $script:ownRegistered = $true
        $State.autostartType = 'task'
        Write-Json $script:StatePath $State
    }
    function Remove-OwnStartup { param($State) $script:ownRegistered = $false }
    function Start-Process { param($FilePath, $ArgumentList, $WindowStyle) }
    function Wait-RuntimeLoaded { param($Exe) return $script:loaded }

    Invoke-Apply
    $saved = Read-Json $script:StatePath
    Assert-True ($saved.active -and $script:ownRegistered -and -not $script:taskEnabled) '应用进入已启用状态'
    Assert-True ($testKey.GetValue('Search') -eq 1 -and $testKey.GetValue('Align') -eq 1) '应用设置目标值'
    Assert-True (-not (Test-Path -LiteralPath $linkPath)) '原快捷方式已备份并暂停'
    Invoke-Apply
    Assert-True ($script:captures -eq 1) '重复应用保留首次原始备份'
    Invoke-Restore
    Assert-True (-not (Read-Json $script:StatePath).active -and $script:taskEnabled -and -not $script:ownRegistered) '恢复原登录行为'
    Assert-True ($testKey.GetValue('Search') -eq 2 -and $testKey.GetValue('Align') -eq 0 -and $testKey.GetValue('TTB') -eq 2) '恢复全部原设置'
    Assert-True ((Get-FileDigest $linkPath) -eq (Get-FileDigest $linkBackup)) '恢复原快捷方式'

    $script:loaded = $false
    $failed = $false
    try { Invoke-Apply } catch { $failed = $true }
    Assert-True $failed '加载失败返回错误'
    Assert-True (-not (Read-Json $script:StatePath).active -and $script:taskEnabled -and -not $script:ownRegistered) '失败自动撤回启动状态'
    Assert-True ($testKey.GetValue('Search') -eq 2 -and (Test-Path -LiteralPath $linkPath)) '失败自动撤回设置与文件'
    Invoke-Restore
    Assert-True (-not (Read-Json $script:StatePath).active) '重复恢复安全退出'

    $script:loaded = $true
    Invoke-Apply
    $testKey.SetValue('Search', 7, [Microsoft.Win32.RegistryValueKind]::DWord)
    [IO.File]::WriteAllText($linkPath, 'new user shortcut')
    $fakeTask.Actions[0].Arguments = '-new-user-choice'
    Invoke-Restore
    Assert-True ($testKey.GetValue('Search') -eq 7) '整套恢复保留后改设置'
    Assert-True ([IO.File]::ReadAllText($linkPath) -eq 'new user shortcut') '整套恢复保留后改快捷方式'
    Assert-True (-not $script:taskEnabled) '整套恢复不启用已被修改的任务'
    $beforeSignature = Get-ActionSignature $fakeTask
    $fakeTask.Principal.RunLevel = 'Highest'
    Assert-True ((Get-ActionSignature $fakeTask) -ne $beforeSignature) '任务运行身份参与一致性校验'
} finally {
    $testKey.Dispose()
    # 只删除本次创建的单一、随机测试键；没有递归删除。
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($testSubkey, $false)
}
Write-Host ('通过 ' + $checks + ' 项隔离检查。未切换真实任务栏。')
Write-Host ('测试文件保留在：' + $sandbox)
