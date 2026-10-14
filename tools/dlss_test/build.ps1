# Builds tools\dlss_test\dlss_test.exe (standalone check of the DLSS bridge) with the
# project's Zig, and puts the DLSS runtime next to it.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$zig = Join-Path $root 'tools\zig\zig.exe'
if (-not (Test-Path $zig)) { & (Join-Path $root 'build.ps1') | Out-Null }
Push-Location $root
try {
    & $zig cc -target x86_64-windows-gnu -O1 -g `
        -Ithird_party/vulkan/include -Ithird_party/DLSS/include `
        -o tools/dlss_test/dlss_test.exe tools/dlss_test/dlss_test.c hook/aud_dlss.c `
        -lopengl32 -lgdi32 -luser32 -ladvapi32
    if ($LASTEXITCODE -ne 0) { throw "zig cc failed ($LASTEXITCODE)" }
    Copy-Item third_party/DLSS/bin/nvngx_dlss.dll tools/dlss_test/ -Force
    Write-Host 'Built tools\dlss_test\dlss_test.exe'
} finally { Pop-Location }
