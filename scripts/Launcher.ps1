# SPDX-License-Identifier: GPL-3.0-only
param(
    [ValidateSet('Apply', 'Restore', 'Check', 'Network', 'Settings')]
    [string]$Mode = 'Apply',
    [string]$ProxyUrl = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'Core.ps1')
$mutex = New-Object Threading.Mutex($false, ('Local\MinbanMac-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw '另一个民办mac操作正在进行，请等它完成后再试。' }
    if ($Mode -eq 'Network') {
        Write-Host '网络设置只保存到本机，不写入发布包。'
        Write-Host '留空：使用 Windows 默认网络；代理示例：http://127.0.0.1:7897'
        $inputUrl = Read-Host '请输入代理地址'
        if ($inputUrl) {
            $uri = [Uri]$inputUrl
            if ($uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) {
                throw '这里只接受不带账号密码的 HTTP/HTTPS 代理地址。'
            }
        }
        Initialize-DataDirectory
        Write-Json (Join-Path $script:DataRoot 'network.local.json') @{ proxy = $inputUrl }
        Write-Status '网络设置已保存。'
    } elseif ($Mode -eq 'Settings') {
        Start-Process 'ms-settings:taskbar'
    } elseif ($Mode -eq 'Check') {
        Assert-Platform
        Write-Status '系统为 Windows 11 x64。'
        $manifest = Get-Manifest
        Write-Status ('项目版本：' + $manifest.version + '；依赖模组数：' + $manifest.mods.Count)
        foreach ($mod in $manifest.mods) {
            $path = Join-Path $script:ProjectRoot ('presets\' + $mod.id + '.settings.ini')
            [void](New-ModConfiguration $mod ([IO.File]::ReadAllText($path)) 1)
        }
        Write-Status '预设结构检查通过。本入口未应用配置。'
    } else {
        if (-not $ProxyUrl) {
            $networkPath = Join-Path $script:DataRoot 'network.local.json'
            if (Test-Path -LiteralPath $networkPath) { $ProxyUrl = (Read-Json $networkPath).proxy }
        }
        if (-not $ProxyUrl) { $ProxyUrl = $env:HTTPS_PROXY }
        if (-not $ProxyUrl) { $ProxyUrl = $env:HTTP_PROXY }
        $script:ProxyUrl = $ProxyUrl
        if ($Mode -eq 'Apply') { Invoke-Apply } else { Invoke-Restore }
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host ('操作未完成：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '请查看 README 的故障处理；保留本机 MinbanMac 目录中的恢复记录。'
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
