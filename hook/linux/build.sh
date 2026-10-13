#!/bin/sh
# Builds build/libaurora-hook.so (the Linux shader hook) from hook/linux/hook_linux.c,
# and build/sdltest (the smoke test). The hook is plain C: any C compiler with glibc
# headers is enough - no libraries to install. On Nix, `nix develop` provides the shell.
set -e
root=$(cd -P "$(dirname "$0")/../.." && pwd)
out="$root/build/libaurora-hook.so"
mkdir -p "$root/build"

CC=""
for c in cc gcc clang; do
    if command -v "$c" >/dev/null 2>&1; then CC="$c"; break; fi
done
if [ -z "$CC" ]; then
    echo "No C compiler found. Install one, or use the Nix dev shell:"
    echo "    Debian / Ubuntu / Mint:   sudo apt install build-essential"
    echo "    Fedora:                   sudo dnf install gcc"
    echo "    Arch / Manjaro:           sudo pacman -S base-devel"
    echo "    openSUSE:                 sudo zypper install gcc"
    echo "    Nix / NixOS:              nix develop   (or nix-shell) in the repo root"
    exit 1
fi

echo "Using $CC"
$CC -O2 -fPIC -shared -Wl,--no-undefined -o "$out" "$root/hook/linux/hook_linux.c" -ldl -lpthread -lm
echo "Built $out"

# Smoke test (exercises the dlsym -> SDL_GL_GetProcAddress -> glShaderSource path).
# Runs inside the Flatpak sandbox: use the standard dynamic loader path so it works there
# even when built with a distro/Nix toolchain.
$CC -O2 -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 -o "$root/build/sdltest" "$root/hook/linux/sdltest.c" -ldl
echo "Built $root/build/sdltest"
