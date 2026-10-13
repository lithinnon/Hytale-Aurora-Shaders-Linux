#!/bin/sh
# Installs Aurora Shaders into the Hytale Linux client (native build, e.g. the
# com.hypixel.HytaleLauncher Flatpak). The counterpart of install.ps1 on Windows:
#   - finds the game (--client, last install in install.config, or the Flatpak default),
#   - waits for a running game to close,
#   - builds the hook on request or when no prebuilt/local build exists (hook/linux/build.sh),
#   - extracts the game's shaders + generates MapChunkFS (tools/prepare_shaders.py),
#   - puts libaurora-hook.so where the sandbox can see it, links Client/shaderpack to this
#     folder (so settings changed in the game menu are kept here), and configures the Flatpak
#     (LD_PRELOAD; the hook stays inert in the launcher process).
#
#   ./install-linux.sh                    install (prebuilt bin/libaurora-hook.so, else builds)
#   ./install-linux.sh --build            build the hook from source first
#   ./install-linux.sh --uninstall        remove the hook and the link again
#   ./install-linux.sh --client "<...>/Client"
set -e
root=$(cd -P "$(dirname "$0")" && pwd)   # repo root: everything is relative to it
app="com.hypixel.HytaleLauncher"
config="$root/install.config"
default_client="$HOME/.var/app/$app/data/Hytale/install/release/package/game/latest/Client"
client=""
dobuild=0
uninstall=0

while [ $# -gt 0 ]; do
    case "$1" in
        --build) dobuild=1 ;;
        --uninstall) uninstall=1 ;;
        --client) client="$2"; shift ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
    shift
done

# The game: --client, then the last install (install.config), then the Flatpak default.
[ -n "$client" ] || { [ -f "$config" ] && client=$(cat "$config") || true; }
[ -n "$client" ] && [ -x "$client/HytaleClient" ] || client="$default_client"
if [ ! -x "$client/HytaleClient" ]; then
    echo "HytaleClient not found. Pass --client \"<...>/Client\" (the folder containing HytaleClient)."
    exit 1
fi
echo "$client" > "$config"
echo "Hytale: $client"

while pgrep -x HytaleClient >/dev/null 2>&1; do
    echo "Hytale is running. Close the game to continue..."
    sleep 3
done

# Same shape as install.ps1: clear the old link first, uninstall stops here.
if [ -L "$client/shaderpack" ]; then
    rm -f "$client/shaderpack"
elif [ -e "$client/shaderpack" ]; then
    echo "$client/shaderpack exists and is not a symlink; moving it to shaderpack.bak."
    mv "$client/shaderpack" "$client/shaderpack.bak"
fi
if [ "$uninstall" = 1 ]; then
    flatpak override --user --reset "$app" 2>/dev/null || true
    rm -rf "$HOME/.var/app/$app/data/Hytale/aurora"
    echo "Aurora Shaders removed. Hytale is back to its own shaders."
    exit 0
fi

# The hook: built from source on request, else the prebuilt one, else a local build.
prebuilt="$root/bin/libaurora-hook.so"
local_build="$root/build/libaurora-hook.so"
if [ "$dobuild" = 1 ] || { [ ! -f "$prebuilt" ] && [ ! -f "$local_build" ]; }; then
    "$root/hook/linux/build.sh"
    hook_src="$local_build"
elif [ -f "$prebuilt" ]; then
    hook_src="$prebuilt"
else
    hook_src="$local_build"
fi

python3 "$root/tools/prepare_shaders.py" --exe "$client/HytaleClient"

aurora="$HOME/.var/app/$app/data/Hytale/aurora"
mkdir -p "$aurora"
cp "$hook_src" "$aurora/libaurora-hook.so"

# The pack folder next to the client. The repo folder needs rw access from inside the
# sandbox: the hook writes include/AU_Settings.glsl, shaderpack/errors/ and hook.log there.
ln -sfn "$root/shaderpack" "$client/shaderpack"
flatpak override --user --filesystem="$root" "$app"
flatpak override --user --env=LD_PRELOAD="$aurora/libaurora-hook.so" "$app"

echo ""
echo "Aurora Shaders installed. Start Hytale; in game, Home opens the options and Pause"
echo "switches the shaders off and on. Keep this folder: the game loads the pack from here."
echo "After a Hytale update, run this script again. Remove with: ./install-linux.sh --uninstall"
