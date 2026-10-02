# SPDX-License-Identifier: GPL-3.0-only
# 明确允许清单打包，不收集本机缓存、备份或个人资料。
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $project 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$engine = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tests\Validate.ps1')
if ($LASTEXITCODE -ne 0) { throw '隔离检查未通过，停止打包。' }
$manifest = [IO.File]::ReadAllText((Join-Path $project 'dependencies.json')) | ConvertFrom-Json
if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw '版本号格式错误。' }
$folderName = '民办mac-' + $manifest.version
$stage = Join-Path ([IO.Path]::GetTempPath()) ('MinbanMac-Package-' + [Guid]::NewGuid().ToString('N'))
$package = Join-Path $stage $folderName
New-Item -ItemType Directory -Path $package | Out-Null
$allowed = @(
    'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'CHANGELOG.md', 'dependencies.json', '.gitignore', '.gitattributes',
    '应用民办mac.cmd', '恢复原任务栏.cmd', '检查环境.cmd', '网络设置.cmd', '任务栏设置.cmd',
    'scripts\Core.ps1', 'scripts\Launcher.ps1', 'scripts\Build.ps1', 'tests\Validate.ps1',
    'docs\preview.png', 'docs\TROUBLESHOOTING.md', 'docs\ARCHITECTURE.md', 'docs\VALIDATION.md', 'docs\MAINTAINER.md',
    'licenses\MIT.txt'
)
$allowed += @($manifest.mods | ForEach-Object { 'presets\' + $_.id + '.settings.ini' })
foreach ($relative in $allowed) {
    if ($relative -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($relative)) { throw '非法打包路径。' }
    $source = Join-Path $project $relative
    $target = Join-Path $package $relative
    $parent = Split-Path $target -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    Copy-Item -LiteralPath $source -Destination $target
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$zip = Join-Path $OutputDirectory ($folderName + '.zip')
if (Test-Path -LiteralPath $zip) { throw '同名压缩包已存在，未覆盖；请保留它或选择新输出目录。' }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create, [Text.Encoding]::UTF8)
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $package -Recurse -File)) {
        # 明确采用 ZIP 标准的正斜杠路径，兼容其他平台上的解压工具。
        $entryName = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $archive.Dispose() }
$digest = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText(($zip + '.sha256'), ($digest + '  ' + [IO.Path]::GetFileName($zip) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Host ('发布包：' + $zip)
Write-Host ('SHA256：' + $digest)
