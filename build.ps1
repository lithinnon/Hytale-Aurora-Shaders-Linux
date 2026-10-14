# Builds build\opengl32.dll (the shader hook) from the C source in hook\.
# The compiler is Zig, downloaded once into tools\zig from ziglang.org and checked against the
# SHA-256 that ziglang.org publishes for that file. No Visual Studio needed.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$zigVersion = '0.15.2'
$zigDir = Join-Path $root 'tools\zig'
$zig = Join-Path $zigDir 'zig.exe'

if (-not (Test-Path $zig)) {
    Write-Host "Downloading the Zig $zigVersion compiler from ziglang.org (about 90 MB, one time)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $entry = (Invoke-RestMethod 'https://ziglang.org/download/index.json').$zigVersion.'x86_64-windows'
    if (-not $entry) { throw "ziglang.org has no Windows build of Zig $zigVersion listed." }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "aurora-zig-$zigVersion"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory $tmp | Out-Null
    $zip = Join-Path $tmp 'zig.zip'
    Invoke-WebRequest $entry.tarball -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $entry.shasum) { throw "Zig download failed its checksum (got $hash, expected $($entry.shasum))." }
    Write-Host 'Checksum OK, unpacking...'
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) { & $tar -xf $zip -C $tmp } else { Expand-Archive $zip $tmp }
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    New-Item -ItemType Directory -Force (Split-Path $zigDir) | Out-Null
    Move-Item $inner.FullName $zigDir
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $root 'build\zig-cache\global'
$env:ZIG_LOCAL_CACHE_DIR = Join-Path $root 'build\zig-cache\local'
New-Item -ItemType Directory -Force (Join-Path $root 'build') | Out-Null

$stubs = Join-Path $root 'hook\gl_stubs.c'
if (-not (Test-Path $stubs)) { & python -I (Join-Path $root 'tools\gen_stubs.py') }

Push-Location (Join-Path $root 'hook')
try {
    # DLSS (aud_dlss.c) needs the NVIDIA DLSS SDK headers and the Vulkan headers in third_party\;
    # without them the DLL is built without DLSS.
    $dlss = @()
    if ((Test-Path (Join-Path $root 'third_party\DLSS\include\nvsdk_ngx_defs.h')) -and
        (Test-Path (Join-Path $root 'third_party\vulkan\include\vulkan\vulkan.h'))) {
        $dlss = @('-DAU_HAS_DLSS=1', '-I..\third_party\DLSS\include', '-I..\third_party\vulkan\include', 'aud_dlss.c', '-ladvapi32')
    }
    & $zig cc -target x86_64-windows-gnu -O2 -shared -o ..\build\opengl32.dll hook.c gl_stubs.c @dlss -lgdi32 -luser32
    if ($LASTEXITCODE -ne 0) { throw "zig cc failed ($LASTEXITCODE)" }
} finally { Pop-Location }
Write-Host "Built $(Join-Path $root 'build\opengl32.dll')"
