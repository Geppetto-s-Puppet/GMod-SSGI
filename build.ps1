<#
    Compiles every shadersrc/*_ps30.hlsl and drops the .vcs into shaders/fxc.

    ShaderCompile always writes to <shaderpath>/shaders/fxc, so we point it at
    shadersrc and move the results into place afterwards.

    Usage:  .\build.ps1            compile everything that changed
            .\build.ps1 -Force     ignore the crc cache and rebuild
            .\build.ps1 ssgi_trace_high_ps30.hlsl
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files,
    [switch]$Force
)

$root    = $PSScriptRoot
$srcDir  = Join-Path $root "shadersrc"
$outDir  = Join-Path $root "shaders\fxc"
$tempOut = Join-Path $srcDir "shaders\fxc"
$compiler = Join-Path $root "bin\ShaderCompile.exe"

if (-not $Files -or $Files.Count -eq 0) {
    $Files = Get-ChildItem -Path $srcDir -Filter "*_ps30.hlsl" | ForEach-Object { $_.Name }
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$compilerArgs = @("/O", "3", "-ver", "30", "-shaderpath", $srcDir)
if ($Force) { $compilerArgs += "-force" }

$failed = 0
foreach ($f in $Files) {
    $name = [System.IO.Path]::GetFileName($f)
    Write-Host "==> $name"
    & $compiler @compilerArgs $name
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        $failed++
    }
}

if (Test-Path $tempOut) {
    Get-ChildItem -Path $tempOut -Filter "*.vcs" | ForEach-Object {
        Move-Item -Force -Path $_.FullName -Destination (Join-Path $outDir $_.Name)
    }
    Remove-Item -Recurse -Force (Join-Path $srcDir "shaders")
}

Write-Host ""
Get-ChildItem -Path $outDir -Filter "*.vcs" | Format-Table Name, Length, LastWriteTime -AutoSize

if ($failed -gt 0) { exit 1 }
