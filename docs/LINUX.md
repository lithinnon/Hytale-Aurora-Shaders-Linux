# Aurora Shaders on Linux — the Hytale Flatpak client

Investigation results and integration guide for running Aurora Shaders on the **native Linux
Hytale client** installed via the user Flatpak `com.hypixel.HytaleLauncher`, on **any GPU that
runs the game** — the hook is vendor-neutral and needs nothing beyond the game's own
OpenGL 4.1 core requirement.

**Status:**

| Piece | State |
|---|---|
| Shader extraction / index / MapChunk generation (`tools/prepare_shaders.py`) | **Done, verified** against the Linux client binary |
| GLSL shader pack itself | Portable as-is (GLSL 410 core) |
| `hook/linux/hook_linux.c` (the LD_PRELOAD shim) | **Done, verified in the real game** — 52 overrides applied at startup, 0 compile errors |
| In-game options menu (Home key) | **Done, verified** — bitmap-font panel (public-domain font8x8), same layout/keys as Windows; keys are masked from the game via a wrapped `SDL_GetKeyboardState` + `SDL_PollEvent` (cleaner than the Windows best-effort) |
| Installer (`install-linux.sh`) | **Done** |
| Key toggle (Pause) | **Done** |

---

## 1. What the pack does on Windows

`Install.bat` drops `opengl32.dll` (built from `hook/hook.c` + `hook/gl_stubs.c`) next to
`HytaleClient.exe`. Windows loads it instead of the system `opengl32.dll`; it forwards every GL
call to the real DLL and:

1. **Replaces shader sources at compile time.** Hytale compiles GLSL (`#version 410 core`)
   embedded in the client binary at runtime. The hook recognises each shader via unique source
   lines (`shaderpack/index.txt`) and swaps in `shaderpack/programs/<Name>.glsl`, expanding its
   `#include`s (from `shaderpack/include/`, falling back to `shaderpack/original/`).
2. **Virtualises uniform locations** so the game's cached locations survive relinks, caches and
   replays uniform values, auto-binds uniform blocks, shares textures between passes
   (`share.txt`), forwards uniforms (`forward.txt`) and uploads custom textures (`textures.txt`).
3. **Hot reloads** on file changes and falls back to the game's own shader whenever an override
   fails to compile or link (log in `shaderpack/hook.log`, failed sources in `shaderpack/errors/`).
4. **Draws the options menu** (Home key) at swap time using GL, editing
   `include/AU_Settings.glsl`.

`tools/prepare_shaders.ps1` extracts the game's shaders from `HytaleClient.exe` (NativeAOT
resource blob), builds `index.txt`, and generates `programs/MapChunkFS.glsl` (game terrain
shader + `tools/mapchunk/*.glsl` spliced in).

## 2. The Linux client — verified facts

Checked against `~/.var/app/com.hypixel.HytaleLauncher/data/Hytale/install/release/package/game/latest/Client/`:

* **Native Linux build.** `HytaleClient` is a 67 MB .NET NativeAOT ELF, next to bundled
  `libSDL3.so`, `libNoesis.so`, etc. Not Wine/Proton — `opengl32.dll` trick does not apply.
* **Everything is resolved at runtime through `dlopen`/`dlsym`.** `.dynsym` has no SDL/GL
  imports; the binary links only libc/libm. The strings `SDL3`, `SDL_GL_GetProcAddress`,
  `SDL_PollEvent`, `SDL_GetKeyboardState`, `glShaderSource`, … are the names it looks up via
  `dlsym`. **This gives a single, clean interception point: interpose `dlsym` via
  `LD_PRELOAD`.**
* **All GL entry points come from `SDL_GL_GetProcAddress`** (GLX or EGL underneath — irrelevant
  if you wrap at the SDL boundary).
* **The shader resource blob is identical to Windows.** Extraction works unchanged:
  `tools/prepare_shaders.py --exe …/HytaleClient` → 94 shaders, 64 index entries, generated
  `MapChunkFS.glsl` (all splice anchors matched, so the game shader text is identical to the
  Windows build this pack targets).
* **Renderer:** the game creates an OpenGL 4.6 core context through the system's GL driver;
  its shaders (and the pack's) only need GLSL 410 core, so any driver that runs Hytale at all
  runs the pack. The hook is vendor-neutral: it wraps `SDL_GL_GetProcAddress`, never driver
  internals.
* **GPU support is a non-issue:** whatever OpenGL 4.1+ core GPU Hytale supports, this works
  with. If an override misbehaves on a particular driver, `compile_new` and
  `validate_override_link` fall back to the game's own shader per stage and log it in
  `shaderpack/errors/` — a driver quirk can cost an effect, never the game.
* **Game updates replace `game/latest/`** (same as Windows) and the launcher verifies game
  files (`package/sig`), so **don't modify or wrap game binaries** — hook at the library level.
* The sandbox has **no filesystem access outside the app data dir** (`shared=ipc;network`
  only). The repo folder is invisible inside the sandbox unless granted with
  `flatpak override --filesystem` (the installer does this).

## 3. Integration architecture on Linux

> **Status:** implemented in `hook/linux/hook_linux.c` and verified end-to-end in the
> Flatpak client: interception -> shader identification -> override compilation ->
> live game rendering, with custom textures and uniform-block auto-binding active.
> `hook/linux/sdltest.c` is a standalone smoke test for the chain.

The Windows hook replaces the whole `opengl32.dll` (hence `gl_stubs.c` forwarding ~700 entry
points). On Linux none of that is needed: the game never links GL symbols directly. Instead:

```
HytaleClient ──dlsym──▶ [LD_PRELOAD libaurora-hook.so]
                            dlsym("SDL_GL_GetProcAddress")  → wrapper:
                                "glShaderSource" etc.       → hook_* (the ported hook.c logic)
                                anything else               → real SDL_GL_GetProcAddress
                            dlsym("SDL_GL_SwapWindow")      → wrapper (menu frame + reload pump)
                            dlsym("SDL_PollEvent")          → wrapper (menu keys, focus tracking)
                            anything else                   → real dlsym
```

This mirrors `wglGetProcAddress`/`wglSwapBuffers` in `hook.c:2321-2336` almost one-to-one.

Requirements for the shim:

* **Self-scoping.** `flatpak override --env=LD_PRELOAD=…` applies to the launcher (WebKitGTK)
  too. In the constructor, check `/proc/self/exe` and enable interposition only when the
  process is `HytaleClient`; otherwise act as a pure `dlsym` passthrough (or disable
  entirely by `unsetenv`-free lazy behaviour — keep the passthrough, it is what MangoHud etc.
  do safely).
* **Absolute path inside the sandbox.** The same host path works in and out of the sandbox,
  e.g. `LD_PRELOAD=/home/<user>/.var/app/com.hypixel.HytaleLauncher/data/Hytale/aurora/libaurora-hook.so`.
* Optional belt-and-braces: also export `eglGetProcAddress`/`glXGetProcAddress` wrappers in a
  future build, in case a game update switches away from `SDL_GL_GetProcAddress`.

## 4. Porting `hook/hook.c` — checklist

Everything not listed below is portable C and transfers as-is (shader identification,
`build_override` + include expansion, `compile_new` validation with per-stage fallback,
virtual uniform locations `VLOC`, uniform caching/replay, `relink_program` hot reload, texture
shares, custom textures, forwarded uniforms, wetness, profiling/tracing).

| Windows (`hook.c`) | Linux replacement |
|---|---|
| `DllMain` | `__attribute__((constructor))` / `(destructor)` |
| `GetModuleFileNameW` + `\shaderpack` | `/proc/self/exe` dir + `/shaderpack` (or `AURORA_PACK_DIR` env override) |
| `CRITICAL_SECTION` | `pthread_mutex_t` |
| `CreateThread` (watcher, input) | `pthread_create` (or fold input into the SDL event wrapper — no thread needed) |
| `QueryPerformanceCounter/Frequency` | `clock_gettime(CLOCK_MONOTONIC)` |
| `FindFirstChangeNotificationW` | `inotify` on `programs/` + `include/` (or plain `stat()` polling — simpler, plenty) |
| `GetAsyncKeyState(VK_PAUSE)` + `SetWindowLongPtrW` subclass (`menu_wndproc`) | Wrap `SDL_PollEvent` (present in the binary); translate `SDL_EVENT_KEY_DOWN/UP` to the menu key state machine; focus = `SDL_EVENT_WINDOW_FOCUS_GAINED/LOST` (replaces `GetForegroundWindow`) |
| `WindowFromDC`/`GetClientRect` | `SDL_GL_GetDrawableSize` (real, via `dlsym`) or `glGetIntegerv(GL_VIEWPORT)` |
| GDI text for the menu (`CreateFontW`, `CreateDIBSection`, `SetTextColor`, …) | Embedded bitmap font (`hook/linux/font8x8.h`, public-domain font8x8) rendered into the same BGRA panel buffer — done |
| `_wfopen`, `_snwprintf`, `wchar_t` paths | plain `char` UTF-8 paths (POSIX `fopen`) |
| `_strdup`, `strtok_s` | `strdup`, `strtok_r` |
| exported `wglGetProcAddress` returning `hook_*` | the `SDL_GL_GetProcAddress` wrapper (same `HOOK()` macro list) |
| exported `wglSwapBuffers` | `SDL_GL_SwapWindow` wrapper |
| `gl_stubs.c` / `stubs_resolve()` | **delete from the Linux build** — resolve real pointers with the real `SDL_GL_GetProcAddress` + `dlsym` |

Build: `hook/linux/build.sh` -> `build/libaurora-hook.so` (any C compiler; Nix users:
`nix develop` or `nix-shell` provides one).

GLSL / driver notes: the pack targets GLSL 410 core — the same level the game itself uses —
so it runs on any vendor's OpenGL 4.1+ core driver; where a driver is stricter than most,
`compile_new` already falls back to the game's shader and logs to `shaderpack/errors/`.
Texture units go up to 30 (`textures.txt`); the 32 combined units OpenGL guarantees are
enough. For performance on integrated GPUs, the RTX preset's bounce rays are the main cost;
start with `AU_PRESET 1` / `AU_RTX_GI_RAYS 4`.

## 5. Install steps (run from the repo root)

One command: `./install-linux.sh` (it does everything below and works from any checkout —
no paths are baked in). The manual steps, with the repo as the current directory:

```sh
CLIENT="$HOME/.var/app/com.hypixel.HytaleLauncher/data/Hytale/install/release/package/game/latest/Client"

# 1. Extract the game's shaders + generate MapChunkFS (re-run after every game update)
python3 tools/prepare_shaders.py --exe "$CLIENT/HytaleClient"

# 2. Put the hook where the sandbox can see it
mkdir -p "$HOME/.var/app/com.hypixel.HytaleLauncher/data/Hytale/aurora"
cp build/libaurora-hook.so "$HOME/.var/app/com.hypixel.HytaleLauncher/data/Hytale/aurora/"

# 3. The pack folder next to the client (the hook writes AU_Settings.glsl / errors / hook.log
#    into it, so the repo folder needs rw access from inside the sandbox)
flatpak override --user --filesystem="$PWD" com.hypixel.HytaleLauncher
ln -sfn "$PWD/shaderpack" "$CLIENT/shaderpack"

# 4. Load the shim in the game process (and the launcher; the shim self-scopes)
flatpak override --user --env=LD_PRELOAD="$HOME/.var/app/com.hypixel.HytaleLauncher/data/Hytale/aurora/libaurora-hook.so" com.hypixel.HytaleLauncher
```

Test without persisting anything first:
`flatpak run --env=LD_PRELOAD=…/libaurora-hook.so com.hypixel.HytaleLauncher`
and watch `shaderpack/hook.log` (it should say `hytale shader hook loaded`, `index: 64 entries`,
`override applied: …`).

In game: **Home** = options menu, **Pause** = shaders on/off. After a Hytale update re-run
steps 1 and 2 (the update recreates `game/latest`, removing the `shaderpack` symlink).

Uninstall: `flatpak override --user --reset com.hypixel.HytaleLauncher`, remove the symlink and
the `aurora/` folder.

## 6. Open questions / risks

* **Exact SDL symbol set.** The wrapper should special-case the hook list and pass everything
  else through; confirm with the `hook.log` which GL names the game requests (log the first 200
  `SDL_GL_GetProcAddress` names at startup).
* **Input.** If the game uses `SDL_PeepEvents`/relative mouse paths rather than `SDL_PollEvent`,
  fall back to wrapping `SDL_GetKeyboardState` (returning a state array augmented with the menu
  keys) — the name exists in the binary.
* **Anti-cheat / online play.** The README already warns: not tested online, use at your own
  discretion. The Flatpak launcher verifies game files, which the hook does not touch, but a
  shader hook is still third-party code in the game process.
* **Licence.** `LICENSE.txt` (Complementary License Agreement) governs redistribution of the
  pack regardless of platform; a Linux port is a derivative of the same pack.

## 7. Parity with the Windows version

Same shaders, same options, same keys — only the platform glue differs.

| Windows | Linux | Notes |
|---|---|---|
| `Install.bat` → `install.ps1` | `./install-linux.sh` | Same flow: find game (`-ClientDir`/`--client`, `install.config`, default location) → wait for the game to close → extract shaders → deploy hook → link `Client/shaderpack` to the pack |
| `Uninstall.bat` | `./install-linux.sh --uninstall` | Also resets the Flatpak overrides (Linux-only config) |
| `Build From Source.bat` → `build.ps1` (Zig) | `hook/linux/build.sh` (system `cc`/`gcc`/`clang`, Nix/nix-shell fallback) | |
| prebuilt `bin\opengl32.dll` or build | prebuilt `bin/libaurora-hook.so` or build | Identical prebuilt-or-build selection (`-Build`/`--build` forces it) |
| `tools\prepare_shaders.ps1` | `tools/prepare_shaders.py` | Same extraction, `index.txt`, generated `MapChunkFS.glsl` |
| `opengl32.dll` proxy + `gl_stubs.c` | `LD_PRELOAD` shim (`dlsym` + `SDL_GL_GetProcAddress` wrappers) | No forwarding stubs needed: the Linux client imports no GL symbols |
| `wglGetProcAddress` hook | `SDL_GL_GetProcAddress` wrapper | Same hook table (shaders, uniforms, draws, texture state) |
| `wglSwapBuffers` hook | `SDL_GL_SwapWindow` wrapper | Menu drawn at the same point in the frame |
| watcher thread (`FindFirstChangeNotification`) | poll thread (`stat` polling) | Same hot-reload behaviour |
| `GetAsyncKeyState` + WndProc key swallowing | SDL keyboard-state shadow + `SDL_PollEvent` filter | Menu keys fully masked from the game (Windows is best-effort) |
| `is_game_foreground` gating | SDL window focus events | Menu keys / Pause only act while the game has keyboard focus |
| GDI menu text (Segoe UI) | embedded bitmap font (`font8x8.h`) | Identical layout, colours and keys; only the typeface differs |
| `shaderpack\hook.log`, `errors/`, `dump/`, `programs/_disabled`, `_profile`, `_trace` | identical | Same diagnostics and switches |
| `include\AU_Settings.glsl` edit + hot reload | identical | |
| — | `AURORA_PACK_DIR`, `AURORA_OFF`, `AURORA_MENU_TEST`, `AURORA_FORCE` | Linux extras (all optional) |

In-game keys are exactly the README table: **Home** menu, **Up/Down/Left/Right**,
**PgUp/PgDn**, **Backspace**, **Pause**.
