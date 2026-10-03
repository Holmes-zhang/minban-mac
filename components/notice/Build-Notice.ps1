# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory = $true)][string]$WindhawkDirectory, [switch]$UpdateManifest)
$ErrorActionPreference = 'Stop'
$component = $PSScriptRoot
$project = Split-Path (Split-Path $component -Parent) -Parent
$windhawkRoot = [IO.Path]::GetFullPath($WindhawkDirectory)
$compilerRoot = Join-Path $windhawkRoot 'Compiler'
$compiler = Join-Path $compilerRoot 'bin\clang++.exe'
$engineLib = Join-Path $windhawkRoot 'Engine\1.7.3\64\windhawk.lib'
if (-not (Test-Path -LiteralPath $compiler) -or -not (Test-Path -LiteralPath $engineLib)) {
    throw '需要完整的 Windhawk 1.7.3 便携目录及其内置编译器。'
}
$sourceRoot = Join-Path $component 'src'
$binaryRoot = Join-Path $component 'bin'
$testRoot = Join-Path $project '.build\notice-tests'
New-Item -ItemType Directory -Path $binaryRoot, $testRoot -Force | Out-Null
$common = @('-target', 'x86_64-w64-mingw32', '-std=c++23', '-O2', '-DUNICODE', '-D_UNICODE',
    '-DWINVER=0x0A00', '-D_WIN32_WINNT=0x0A00', '-D_WIN32_IE=0x0A00',
    '-DNTDDI_VERSION=0x0A000008', '-D__USE_MINGW_ANSI_STDIO=0', ('-I' + $sourceRoot),
    ('-ffile-prefix-map=' + $project + '=minban-mac'),
    ('-ffile-prefix-map=' + $compilerRoot + '=windhawk-compiler'))
Push-Location $compilerRoot
try {
    $binary = Join-Path $binaryRoot 'minban-qq-notice_0.3.0.dll'
    $arguments = $common + @('-shared', '-DWH_MOD', '-DWH_MOD_ID=L\"minban-qq-notice\"',
        '-DWH_MOD_VERSION=L\"0.3.0\"', $engineLib, (Join-Path $sourceRoot 'minban-qq-notice.wh.cpp'),
        '-include', 'windhawk_api.h', '-Wl,--export-all-symbols', '-Wl,--no-insert-timestamp',
        '-o', $binary, '-lshell32', '-lgdi32', '-lole32', '-loleaut32', '-luuid', '-ldwmapi')
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw '独立提醒编译失败。' }
    foreach ($test in @('PolicyTests', 'TaskbarTargetChecks', 'SurfaceChecks')) {
        $testExe = Join-Path $testRoot ($test + '.exe')
        $arguments = $common + @('-static', (Join-Path $component ('tests\' + $test + '.cpp')),
            '-o', $testExe, '-lshell32', '-lgdi32', '-lole32', '-loleaut32', '-luuid')
        if ($test -eq 'SurfaceChecks') { $arguments += '-municode' }
        & $compiler @arguments
        if ($LASTEXITCODE -ne 0) { throw ('验证程序编译失败：' + $test) }
        if ($test -eq 'SurfaceChecks') { & $testExe (Join-Path $testRoot 'surface-preview.bmp') }
        else { & $testExe }
        if ($LASTEXITCODE -ne 0) { throw ('验证失败：' + $test) }
    }
} finally { Pop-Location }
$manifestPath = Join-Path $project 'dependencies.json'
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
$mod = @($manifest.bundledMods | Where-Object id -eq 'minban-qq-notice')[0]
$hash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -File | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ path = ('components/notice/src/' + $_.Name); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
if ($UpdateManifest) {
    $mod.dllSha256 = $hash
    $mod.sourceFiles = $sourceFiles
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
} else {
    if ($mod.dllSha256 -ne $hash) { throw '程序哈希与发布清单不符；维护者确认改动后可使用 -UpdateManifest。' }
    foreach ($source in $sourceFiles) {
        $recorded = @($mod.sourceFiles | Where-Object path -eq $source.path)
        if ($recorded.Count -ne 1 -or $recorded[0].sha256 -ne $source.sha256) { throw '源码哈希与发布清单不符。' }
    }
}
Write-Host ('独立提醒：' + $binary)
Write-Host ('SHA256：' + $hash)
