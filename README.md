
<a href="https://buymeacoffee.com/kristijan1001" target="_blank"> <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" width="160" alt="Buy Me a Coffee"> </a>


https://github.com/user-attachments/assets/9c0842a6-0442-40e9-8760-67f695989e0c

<img width="3840" height="2160" alt="HytaleClient_ARPBNL3it1" src="https://github.com/user-attachments/assets/b79537e3-1a60-4631-a084-619f9bd18946" />

<img width="3840" height="2160" alt="HytaleClient_XLE7vjtrBp" src="https://github.com/user-attachments/assets/1cf4d1f9-71e0-4597-a119-d9321ea4f554" />

<img width="3840" height="2160" alt="HytaleClient_yiDS4pwOJz" src="https://github.com/user-attachments/assets/3d899ec1-089d-4af7-8fac-14bec9981215" />

<img width="3840" height="2160" alt="HytaleClient_9uBVvnw0u2" src="https://github.com/user-attachments/assets/fa8cc289-cdb0-4e77-b53e-8d5332a578e1" />

<img width="3840" height="2160" alt="image" src="https://github.com/user-attachments/assets/e35d3088-7386-4fbb-8ac3-0dd1624d1a57" />

<img width="3840" height="2160" alt="HytaleClient_nKmVvN2vCb" src="https://github.com/user-attachments/assets/287daae9-44d0-4441-810f-5fac7b174c9a" />

<img width="3840" height="2160" alt="image" src="https://github.com/user-attachments/assets/6c50f4f3-098d-4eac-86d0-67ac4d0e60f9" />

<img width="3840" height="2160" alt="image" src="https://github.com/user-attachments/assets/e63f95ea-0f36-4845-ae8d-54bf9d7eab6c" />


# Aurora Shaders for Hytale (Linux)

> ## ⚠️ This Linux port is purely vibe-coded
>
> Everything that makes this pack run on Linux — the shader hook, the installer, the tools,
> this documentation — was **written by AI** in one sitting, prompted and tested by a human.
> It works, but expect rough edges. The shader pack itself is human work.
> See [Credits](#credits-and-license).

A shader pack for Hytale: soft sun shadows, volumetric clouds, light shafts through trees and
caves, reflective water, ray-traced bounce light and ambient occlusion, rain puddles, rainbows,
a rotating star sky, lens flare and a filmic tonemap - with an in-game options menu.

> **This is the Linux fork** of
> [Aurora Shaders by Kristijan1001](https://github.com/Kristijan1001/Hytale-Aurora-Shaders):
> the same shaders and the same in-game options, ported to the native Linux client.
> **Windows users: install from the
> [original repository](https://github.com/Kristijan1001/Hytale-Aurora-Shaders).**

> **Not tested online, use at your own discretion.**

## Install

> **Windows users:** this fork is Linux-only — install Aurora Shaders from the
> [original repository](https://github.com/Kristijan1001/Hytale-Aurora-Shaders) instead;
> its README covers the Windows installation.

On Linux the pack works with the native Linux client — including the official launcher
installed as a Flatpak (`com.hypixel.HytaleLauncher`). No Wine or Proton involved.

### Before you start

1. **Install Hytale and launch it once** so the game files exist on your machine.
2. **Close Hytale completely** before installing or uninstalling (check for running game
   processes).
3. **Keep the Aurora folder somewhere permanent** — the game loads the shaders from this
   folder every time it runs. Moving or deleting it breaks the pack.
4. **Install the build tools** — a C compiler and Python 3. The hook is plain C with no
   external libraries, so any mainstream distro works out of the box:

   | Distro | Command |
   |---|---|
   | Debian / Ubuntu / Mint | `sudo apt install build-essential python3` |
   | Fedora | `sudo dnf install gcc python3` |
   | Arch / Manjaro | `sudo pacman -S base-devel python` |
   | openSUSE | `sudo zypper install gcc python3` |
   | Nix / NixOS | `nix develop` (or `nix-shell`) in the repo root — toolchain included |

   Any glibc-based distro is fine (the game itself needs glibc — musl/Alpine is not
   supported).

5. Any GPU that runs Hytale is enough — the pack is heavier than vanilla, especially the RTX
   preset; see [Performance](#performance).

### Step by step

1. Get the source (the zip works too — then just extract it and `cd` into it):

   ```sh
   git clone https://github.com/lithinnon/Hytale-Aurora-Shaders-Linux.git
   cd Hytale-Aurora-Shaders-Linux
   ```

2. Close Hytale.
3. Install:

   ```sh
   ./install-linux.sh
   ```

4. Start Hytale from the launcher — press **Home** for the options menu, **Pause** toggles
   the shaders on and off.

- **Hytale installed somewhere else?** `./install-linux.sh --client "<...>/Client"` (the
  folder containing `HytaleClient`). The choice is remembered for next time.
- **After a Hytale update:** run `./install-linux.sh` again.
- **To remove it:** `./install-linux.sh --uninstall`.

What the installer does: finds the game, extracts its shaders, builds the hook, puts it
where the Flatpak sandbox can see it, links `Client/shaderpack` to this folder, and sets
`LD_PRELOAD` for the launcher (the hook stays inert outside the game). Nothing in the game
is modified. More detail: [docs/LINUX.md](docs/LINUX.md).

### Check that it worked

- The world looks different right away: softer shadows, a new sky and clouds, coloured light.
- **Home** opens the **AURORA SHADERS** options menu; changes apply instantly.
- Still looks like vanilla Hytale? See [Troubleshooting](#troubleshooting).

## In game

| Key | |
|---|---|
| **Home** | Opens / closes the options menu. |
| **Up / Down** | Select an option. |
| **Left / Right** | Change it (hold to slide numbers). |
| **PgUp / PgDn** | Jump to the previous / next section. |
| **Backspace** | Put the selected option back to its default. |
| **Pause** | Shaders off / on, for quick comparisons. |

Changes apply instantly; values you changed from the default show in orange. They are saved in
`shaderpack/include/AU_Settings.glsl`, which you can also edit by hand while the game runs (saving
the file reloads the shaders).

## Menu options

### General

| Option | What it does |
|---|---|
| **Shaders** | Turns the whole pack on or off (same as the Pause key). |
| **Preset** | **Standard**, or **RTX**: adds bounce light and ray-traced ambient occlusion (see the RTX section), shadows that get softer the further they fall from what casts them, wet-looking reflective surfaces in rain, and more samples for shadows, light shafts and clouds. Costs noticeably more GPU time. |
| **Brightness** | Overall brightness of shaded areas and nights, like Minecraft's brightness slider: low is moody, high is bright. |
| **Cave lighting %** | The minimum light in places the sun and sky can't reach - caves, deep interiors. Lower makes caves darker. |

### Lighting

| Option | What it does |
|---|---|
| **Ambient occlusion** | How dark corners, crevices and the spots under objects get. |
| **Torch light** | Brightness of light from torches, lanterns, lava and other light blocks. |
| **Torch colour (warm to Hytale)** | 0 gives every light a classic warm orange glow; 1 uses Hytale's own colour for each light (blue crystals, green lights...). |
| **Emissive glow** | How strongly glowing blocks themselves shine - lava, flames, crystals. |
| **Block relief** | Gives block textures a slight 3D surface, so stone, bricks and wood catch the light per pixel. |
| **Relief strength** | How deep that relief looks. |
| **Foliage translucency** | Sunlight shining through leaves and grass when the sun is behind them. |
| **Sun highlights** | Soft sun reflections on surfaces and a sheen on leaves. |

### Shadows

| Option | What it does |
|---|---|
| **Shadow softness** | How blurry shadow edges are. |
| **Contact shadows** | Small shadows for grass, plants and props, which Hytale leaves out of its shadow map. |
| **Distant shadows** | Shadows for trees and hills beyond the range of the normal shadows, so the landscape doesn't go flat in the distance. |

### RTX

These only apply with the **RTX** preset.

| Option | What it does |
|---|---|
| **Bounce light** | Sunlight bouncing off surfaces: shade under a tree picks up green from the sunlit grass, a room fills with warm light from a sunlit floor, torch flames light the walls around them. |
| **Bounce rays** | How many rays per pixel the bounce light uses. More is smoother but slower; this is the biggest performance setting in the pack. |
| **Bounce reach** | How far (in blocks) bounced light travels. |
| **Ray-traced AO** | How much those rays also darken enclosed corners and the shade under overhangs. |

### Sky

| Option | What it does |
|---|---|
| **Stars** | **Off**, **Procedural** (sparse generated stars), or **Hytale** (Hytale's own star texture with the milky way, turning across the sky through the night). |
| **Star brightness** | Brightness of the stars. |
| **Star density** | Size of the star field on the sky: lower gives bigger, fewer stars. |
| **Night sky blue** | How deep blue the night sky stays down to the horizon; 1 is a grey-blue. |
| **Rainbows** | A rainbow opposite the sun after rain, in the morning or evening. |
| **Atmospheric fog** | Haze that softens the distance. |
| **Fog density** | How thick that haze is. |

### Clouds

| Option | What it does |
|---|---|
| **Volumetric clouds** | Replaces Hytale's flat cloud layers with 3D clouds that the sun lights from inside. |
| **Cloud amount** | How much of the sky is covered. |
| **Cloud speed** | How fast they drift. |
| **Cloud layers** | One or two cloud layers. |
| **Cloud shadows** | Clouds cast moving shadows on the ground. |

### Light shafts

| Option | What it does |
|---|---|
| **Light shafts** | Volumetric rays of sun and moon light in the air. |
| **Strength** | Overall strength of the rays. |
| **Forest / cave beams** | How much the beams falling through gaps - between leaves, through roofs and cave openings - stand out from the general haze. 0 makes them plain haze. |
| **Beam boost** | Extra brightness for those beams. |
| **Moonlight haze** | Strength of the moonlit haze at night. |

### Water

| Option | What it does |
|---|---|
| **Shader water** | The pack's water: moving waves, reflections of the sky and the world, depth colour, sun glints. Off gives Hytale's own water. |
| **Refraction** | How much the water surface bends the view of the riverbed. |
| **Shore foam** | Foam along shorelines. |
| **Underwater caustics** | Rippling light patterns on surfaces while you are under water. |
| **Rain puddles** | Reflective puddles on open ground while it rains, drying up after. |
| **Puddle strength** | How many puddles form and how reflective they are. |

### Post-processing

| Option | What it does |
|---|---|
| **Exposure** | Overall image brightness. |
| **Contrast** | Difference between dark and bright. |
| **Saturation** | Colour intensity. |
| **Vibrance** | Boosts dull colours more than already strong ones. |
| **Bloom** | Glow around bright light: the sun, lava, torches. |
| **Bloom strength** | How strong that glow is. |
| **Lens flare** | Camera lens flares from the sun and moon. |
| **Lens flare strength** | How strong the flares are. |
| **Sun glare** | A soft glow around the visible sun. |
| **Vignette** | Slightly darker screen edges. |
| **Temporal anti-aliasing** | Smooths edges and cleans up the fine grain in shadows, light shafts and bounce light by combining frames. Turning it off makes those grainy. |
| **Sharpening** | Sharpens the image (0 is off). |

## Performance

The biggest costs, roughly in order: the **RTX** preset (try fewer **Bounce rays** first),
**Volumetric clouds**, **Light shafts**, and **Shader water** reflections. The Standard preset
runs much lighter than RTX.

## Build it yourself

`./install-linux.sh` builds the hook automatically when needed. To build it by hand:

```sh
./hook/linux/build.sh        # -> build/libaurora-hook.so (any standard C compiler)
./install-linux.sh --build   # build from source and install
```

A prebuilt `bin/libaurora-hook.so` is picked up automatically when present in a release.

Nix users: `nix develop` (flake) or `nix-shell` drops you into a shell with the toolchain
already on `PATH` — no packages to install:

```sh
nix develop -c ./hook/linux/build.sh
```

## How it works

Hytale compiles its OpenGL shaders from source embedded in the game binary and has no shader
loader. The game resolves every OpenGL call at runtime, so a small shim
(`hook/linux/hook_linux.c`, loaded with `LD_PRELOAD`) watches shader compilation: when the
game compiles a shader the pack recognises (by `shaderpack/index.txt`) and the pack has a
replacement for in `shaderpack/programs/`, it compiles that instead. Edited shader files are
recompiled live, and the in-game menu is drawn by the same shim. (The Windows original does
the same through an `opengl32.dll` proxy — see the
[original repository](https://github.com/Kristijan1001/Hytale-Aurora-Shaders).)

Hytale's own shader sources are not redistributed: `tools/prepare_shaders.py` extracts them
from the installed game into `shaderpack/original/` during install, because the pack's shaders
include parts of them.

## Troubleshooting

- **Looks like vanilla:** press **Pause** once (the shaders may be toggled off), and check
  `shaderpack/hook.log` — it should say `override applied: ...`. If the file is missing or
  empty, run `./install-linux.sh` again (also after every game update).
- **Something renders wrong after a game update:** a shader that fails to compile falls back
  to the game's own; the compiler log is in `shaderpack/errors/`, and `shaderpack/hook.log`
  records what the hook did. Please open an issue with those files.

## Known Issue

- **When Sunrise hits for few seconds there is flicker on the opposite side from where the sun is.**

## Credits and license

Aurora Shaders is a modified pack based on Complementary Shaders by Complementary Development
(https://www.complementary.dev/). It is distributed under the Complementary License Agreement,
included unchanged in [LICENSE.txt](LICENSE.txt).

Shaders have been assisted by AI/Claude.

This repository is the Linux fork of
[Aurora Shaders by Kristijan1001](https://github.com/Kristijan1001/Hytale-Aurora-Shaders)
(Windows). The shader pack and licence are unchanged; the fork adds the hook and installer
for the native Linux client — and that Linux port is **purely vibe-coded** (written by AI,
steered and tested by a human).
