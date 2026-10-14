#!/usr/bin/env python3
# Linux/macOS port of tools/prepare_shaders.ps1. Prepares shaderpack/ for the installed game:
#   1. extracts Hytale's GLSL from the HytaleClient binary into shaderpack/original (the pack's
#      overrides include parts of it, and it cannot be redistributed, so every install pulls it
#      from the player's own game),
#   2. builds shaderpack/index.txt (unique source lines the hook uses to recognise each shader),
#   3. fingerprints the game's 32x32 block textures from Assets.zip into shaderpack/materials.txt
#      (class + level per texture name; the hook matches the block atlas against it at runtime),
#   4. generates the shader-pack overrides from the game shaders + tools/mapchunk/*:
#      programs/MapChunkFS.glsl, programs/MapChunkVS.glsl, programs/ParticleFS.glsl and the
#      scene vertex shaders with the DLSS camera jitter.
#
#   python3 tools/prepare_shaders.py --exe "<...>/Client/HytaleClient"
#   python3 tools/prepare_shaders.py --mapchunk-only        (after editing tools/mapchunk/*.glsl)
#
# The binary is the .NET NativeAOT client (HytaleClient.exe on Windows, HytaleClient on Linux);
# the resource blob layout is identical. Works on any Python 3.8+, no dependencies.

import argparse
import re
import struct
import sys
import zipfile
import zlib
from pathlib import Path

UTF8 = "utf-8"
ASM = b"HytaleClient, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"
PREFIX = b"HytaleClient.Graphics.Shaders."
VERSION = b"#version 410 core"


def find_all(data: bytes, pat: bytes):
    out = []
    i = data.find(pat)
    while i >= 0:
        out.append(i)
        i = data.find(pat, i + 1)
    return out


def starts_with_at(data: bytes, at: int, pat: bytes) -> bool:
    return 0 <= at and at + len(pat) <= len(data) and data[at:at + len(pat)] == pat


def nu(data: bytes, p: int):
    """NativeAOT 'NativeFormat' unsigned integer. Returns (value, new offset)."""
    b0 = data[p]
    if (b0 & 1) == 0:
        return b0 >> 1, p + 1
    if (b0 & 2) == 0:
        return (b0 >> 2) | (data[p + 1] << 6), p + 2
    if (b0 & 4) == 0:
        return (b0 >> 3) | (data[p + 1] << 5) | (data[p + 2] << 13), p + 3
    if (b0 & 8) == 0:
        return (b0 >> 4) | (data[p + 1] << 4) | (data[p + 2] << 12) | (data[p + 3] << 20), p + 4
    return struct.unpack_from("<i", data, p + 1)[0], p + 5


def extract(exe: Path, out_dir: Path) -> int:
    data = exe.read_bytes()
    res = []  # (name, offset, length)
    for m in find_all(data, ASM):
        p = m + len(ASM)
        try:
            n, p = nu(data, p)
        except IndexError:
            continue
        if n <= 0 or n > 512 or p + n > len(data):
            continue
        name = data[p:p + n]
        if not name.startswith(PREFIX):
            continue
        q = p + n
        off, q = nu(data, q)
        ln, q = nu(data, q)
        res.append((name[len(PREFIX):].decode("ascii"), off, ln))
    if not res:
        raise SystemExit(f"No shader resources found in {exe}")

    # The resources are stored back to back in one blob; find its start by checking which
    # "#version" occurrence makes the most vertex/fragment shaders start with "#version".
    mains = [r for r in res if r[0].endswith(("FS.glsl", "VS.glsl"))]
    first = min(r[1] for r in mains)
    best_base, best_score = -1, 0
    for occ in find_all(data, VERSION):
        base = occ - first
        score = sum(1 for r in mains if starts_with_at(data, base + r[1], VERSION))
        if score > best_score:
            best_score, best_base = score, base
    if best_base < 0 or best_score < len(mains) // 2:
        raise SystemExit(f"Could not locate the shader data in {exe}")

    out_dir.mkdir(parents=True, exist_ok=True)
    written = 0
    for name, off, ln in res:
        if best_base + off + ln > len(data):
            continue
        blob = data[best_base + off:best_base + off + ln]
        if blob.startswith(b"\xef\xbb\xbf"):   # the game trims the BOM before compiling; so do we
            blob = blob[3:]
        (out_dir / name).write_bytes(blob)
        written += 1
    return written


def build_index(orig_dir: Path, out_path: Path) -> int:
    files = sorted(orig_dir.glob("*.glsl"), key=lambda f: f.name)
    text = {f.name: read(f) for f in files}
    included = set()
    for t in text.values():
        included.update(re.findall(r'#include\s*"([^"]+)"', t))
    lines = {k: {l.strip() for l in v.split("\n") if l.strip()} for k, v in text.items()}
    count = {}
    for s in lines.values():
        for l in s:
            count[l] = count.get(l, 0) + 1

    out_lines = []
    for name in sorted(text):
        if name in included:
            continue
        sigs = [l for l in lines[name]
                if count[l] == 1 and len(l) >= 20 and "\t" not in l
                and not l.startswith("#include") and not l.startswith("#version")]
        sigs.sort(key=lambda l: (1 if l.startswith("//") else 0, -len(l), l))
        sigs = sigs[:3]
        if not sigs:
            continue
        out_lines.append(name[:-5] + "\t" + "\t".join(sigs))
    out_path.write_text("\n".join(out_lines) + "\n", UTF8)
    return len(out_lines)


# ---- Block materials -----------------------------------------------------------------------
# shaderpack/materials.txt: one line per 32x32 block texture of the game - a fingerprint of
# its pixels (FNV-1a over RGBA, top row first, transparent texels as 0) and the material its
# name says it is. The hook fingerprints the tiles of Hytale's block atlas the same way and
# builds the per-tile material map the terrain shader reads (hook_linux.c, materials_build).
#   class 0 default, 1 polished (gloss = level), 2 metal (level = polish), 3 porous (soaks
#   up rain, darker when wet; level = how much); level 0-7.

def classify(name: str):
    n = name.lower()
    has = lambda k: k in n
    if (n.startswith(("fluid", "dev", "editor", "t_", "transition"))
            or has("grass") or has("leaves") or has("moss")):
        return 0, 0
    if n.startswith("metal_") or n.startswith("rock_gold"):
        return 2, 6 if has("smooth") else (2 if (has("goblin") or has("rust") or has("scrap")) else 4)
    if has("ice") or n.startswith("glass"):
        return 1, 7
    if has("smooth") or has("marble") or has("polish") or has("whitetiles") or has("quartzite_brick"):
        return 1, 4
    if has("brick") or has("decorative") or has("ornate") or has("tile") or has("rune") or has("planks"):
        return 0, 0
    if n.startswith("soil_snow"):
        return 0, 0
    if has("gravel") or has("cobble"):
        return 3, 4
    if n.startswith("soil_") or has("sand") or n.startswith("clay"):
        return 3, 6
    if n.startswith("rock_") or has("calcite") or has("peachstone") or has("chalk"):
        return 3, 3
    return 0, 0


def decode_png(data: bytes):
    """8-bit PNG decoder (gray/RGB/palette/gray+alpha/RGBA, no interlace) -> (w, h, RGBA)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, plte, trns = 8, b"", b"", b""
    w = h = bd = ct = inter = 0
    while pos + 8 <= len(data):
        ln, typ = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            w, h, bd, ct, _comp, _filt, inter = struct.unpack(">IIBBBBB", chunk)
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"PLTE":
            plte = chunk
        elif typ == b"tRNS":
            trns = chunk
        elif typ == b"IEND":
            break
    if bd != 8 or inter != 0 or w <= 0 or h <= 0:
        raise ValueError(f"unsupported PNG (depth {bd}, interlace {inter})")
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ct)
    if ch is None:
        raise ValueError(f"unsupported PNG colour type {ct}")
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray()
    prev = bytearray(stride)
    i = 0
    for _y in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out += line
        prev = line
    rgba = bytearray(w * h * 4)
    for i2 in range(w * h):
        o, q = i2 * 4, i2 * ch
        if ct == 6:
            rgba[o:o + 4] = out[q:q + 4]
        elif ct == 2:
            rgba[o:o + 3] = out[q:q + 3]
            rgba[o + 3] = 255
        elif ct == 0:
            rgba[o] = rgba[o + 1] = rgba[o + 2] = out[q]
            rgba[o + 3] = 255
        elif ct == 4:
            rgba[o] = rgba[o + 1] = rgba[o + 2] = out[q]
            rgba[o + 3] = out[q + 1]
        else:  # palette
            idx = out[q]
            if idx * 3 + 2 < len(plte):
                rgba[o:o + 3] = plte[idx * 3:idx * 3 + 3]
            rgba[o + 3] = trns[idx] if idx < len(trns) else 255
    return w, h, bytes(rgba)


def build_materials(assets_zip: Path, out_path: Path) -> int:
    lines = []
    with zipfile.ZipFile(assets_zip) as z:
        for entry in z.namelist():
            if not entry.startswith("Common/BlockTextures/") or not entry.endswith(".png"):
                continue
            name = Path(entry).stem
            cls, lvl = classify(name)
            if cls == 0:
                continue
            try:
                w, h, rgba = decode_png(z.read(entry))
            except (ValueError, zlib.error, KeyError):
                continue
            if w != 32 or h != 32:
                continue
            hv = 2166136261
            for i in range(1024):
                r, g, b, a = rgba[i * 4:i * 4 + 4]
                if a == 0:
                    r = g = b = 0
                for v in (r, g, b, a):
                    hv = ((hv ^ v) * 16777619) & 0xFFFFFFFF
            lines.append(f"{hv:08x} {cls} {lvl} {name}")
    lines.sort()
    out_path.write_text("# fingerprint class level texture  (tools/prepare_shaders.py BuildMaterials)\n"
                        + "\n".join(lines) + ("\n" if lines else ""), UTF8)
    return len(lines)


# ---- Shader generation ---------------------------------------------------------------------

def read(p: Path) -> str:
    return p.read_text(UTF8).lstrip("\ufeff").replace("\r\n", "\n")


def rep(s: str, a: str, b: str, what: str) -> str:
    i = s.find(a)
    if i < 0:
        raise SystemExit(f"prepare_shaders: game shader changed, anchor not found in {what}: "
                         + a[:70].replace("\n", "\\n"))
    return s[:i] + b + s[i + len(a):]


def make_map_chunk(pack: Path, snip: Path):
    s = read(pack / "original" / "MapChunkFS.glsl")
    s = rep(s, "#endif // !DEFERRED\n\n#if USE_OVERLAY",
            "#endif // !DEFERRED\n\n" + read(snip / "includes.glsl") + "\n#if USE_OVERLAY", "includes")
    # Hytale sweeps a fake shine over REFLECTIVE blocks in near chunks only; the pack has its own.
    s = rep(s, "    if (shadingMode == SHADING_REFLECTIVE)\n    {\n"
               "        vec4 shininess = computeFakeShininess(texColor.rgb, normalWS, CameraDirection.xyz);\n"
               "        light = max(light, vec3(shininess.a));\n        albedo.rgb += shininess.rgb;\n    }\n",
            "    // (Hytale fake shininess removed by Aurora Shaders)\n", "fake shine")
    s = rep(s, "writeToGBuffer(albedo, normalWS, light, fragStaticLight.a, hasSSAO, hasBloom, useCleanShadowBackfaces, outColor0, outColor1, outColor2);\n",
            "writeToGBuffer(albedo, normalWS, light, fragStaticLight.a, hasSSAO, hasBloom, useCleanShadowBackfaces, outColor0, outColor1, outColor2);\n"
            + "    outColor0.a = (round(outColor0.a * 255.0) + 128.0 + 4.0 * (auMatClass > 0.0 ? auMatLevel : round(clamp(auOreGlow, 0.0, 1.0) * 7.0)) + 32.0 * auMatClass) / 255.0;   // Aurora: pure glow (128), ore glow / material level (bits 2-4), material class (bits 5-6)\n",
            "gbuffer meta bits")
    s = rep(s, "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n\n    writeToGBuffer(",
            "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n"
            + read(snip / "gennormals.glsl") + "\n    writeToGBuffer(", "gennormals")
    # Glass the pack composites itself (lighting.glsl) is written opaque into the OIT pass.
    s = rep(s, "    color.a = isWater(effectID) ? 1.0 : texColor.a;\n",
            "#if AU_FORWARD\n    color.a = isWater(effectID) || auGlass ? 1.0 : texColor.a;\n#else\n"
            + "    color.a = isWater(effectID) ? 1.0 : texColor.a;\n#endif\n", "glass oit")
    lit = "    outColor0.rgb = albedo * light * shadow;\n    outColor0.a = texColor.a;\n"
    s = rep(s, lit, lit + "\n" + read(snip / "lighting.glsl"), "lighting")

    start = s.find("    if (isWater(effectID) && uWaterQuality >= 1)\n    {\n        vec2 screenUV")
    end = s.find("    // Warning : because of precision issue \"with the UVs\",")
    if start < 0 or end < start:
        raise SystemExit("MapChunkFS: game shader changed, water block not found")
    orig_water = s[start:end]
    body_start = orig_water.find("{\n") + 2
    orig_body = orig_water[body_start:orig_water.rfind("}")]
    s = (s[:start]
         + "    if (isWater(effectID) && uWaterQuality >= 1)\n    {\n#if AU_FORWARD && AU_WATER\n"
         + read(snip / "water.glsl") + "#else\n" + orig_body + "#endif\n    }\n\n"
         + s[end:])

    s = rep(s, "#if USE_FOG\n    // Apply fog\n    outColor0.rgb = mix(outColor0.rgb, fragFog.rgb, fragFog.w);\n"
               "    hasBloom = hasBloom && fragFog.w < 0.9;\n#endif // USE_FOG",
            "#if USE_FOG\n#if AU_FORWARD\n    DoAUFog(outColor0.rgb, fragPositionWS, auDither, fragStaticLight.a);\n"
            "    outColor0.rgb = AU_AddVL(outColor0.rgb, auForwardVL);\n#else\n"
            "    // Apply fog\n    outColor0.rgb = mix(outColor0.rgb, fragFog.rgb, fragFog.w);\n#endif\n"
            "    hasBloom = hasBloom && fragFog.w < 0.9;\n#endif // USE_FOG", "fog")
    s = rep(s, "#version 410 core\n",
            "#version 410 core\n// Aurora Shaders for Hytale - terrain (G-buffer) and forward water / translucents.\n"
            "// Generated by tools/prepare_shaders.py from the game shader + tools/mapchunk/*.glsl.\n", "header")
    (pack / "programs" / "MapChunkFS.glsl").write_text(s, UTF8)


def make_map_chunk_vs(pack: Path, snip: Path):
    """The game's MapChunkVS, recording every block it draws in the path tracer's voxel grid."""
    s = read(pack / "original" / "MapChunkVS.glsl")
    s = rep(s, "#version 410 core\n",
            "#version 410 core\n#extension GL_ARB_shader_image_load_store : enable\n"
            + "// Aurora Shaders for Hytale - terrain vertices + voxel grid.\n"
            + "// Generated by tools/prepare_shaders.py from the game shader + tools/mapchunk/voxelize.glsl.\n",
            "MapChunkVS header")
    s = rep(s, "#include \"Shading_inc.glsl\"\n",
            "#include \"Shading_inc.glsl\"\n#include \"AU_Settings.glsl\"\n"
            + "#if AU_VOXELS && DEFERRED && !ALPHA_BLEND && !ANIMATED && !USE_SCENE_DATA_OVERRIDE\n"
            + "#define AU_VOX_WRITER_ONLY\n#include \"AU_Voxel.glsl\"\n#endif\n", "MapChunkVS voxel include")
    s = rep(s, "    fragPackedData = packData(effectID, shadingMode);\n",
            read(snip / "voxelize.glsl") + "\n    fragPackedData = packData(effectID, shadingMode);\n",
            "MapChunkVS voxelize")
    # DLSS camera jitter (sub-pixel offset per frame, set by the hook; 0 without DLSS).
    s = rep(s, "uniform mat4 uModelMatrix;\n", "uniform mat4 uModelMatrix;\nuniform vec2 uHookJitter;\n",
            "MapChunkVS jitter uniform")
    s = rep(s, "#endif // ALPHA_BLEND\n\n    float lightExposition;\n",
            "#endif // ALPHA_BLEND\n#if !USE_SCENE_DATA_OVERRIDE\n    gl_Position.xy += uHookJitter * gl_Position.w;\n#endif\n\n    float lightExposition;\n",
            "MapChunkVS jitter")
    # The G-buffer gets the pure block light (glow); DeferredFS adds the sun part from the
    # sky light itself. Hytale's max(sun, glow) here threw torch light away by day wherever
    # the sky reaches. Forward passes keep the game's combined light.
    mx = "    fragStaticLight.rgb = max(SunLightColor.rgb * SunLightColor.a * staticLight.a, staticLight.rgb * StaticLightMultiplier);\n"
    s = rep(s, mx, "#if DEFERRED && !USE_SCENE_DATA_OVERRIDE\n"
                   + "    fragStaticLight.rgb = staticLight.rgb * StaticLightMultiplier;   // Aurora: pure glow (AU_GBUFFER_PURE_GLOW)\n"
                   + "#else\n" + mx + "#endif\n", "MapChunkVS pure glow")
    (pack / "programs" / "MapChunkVS.glsl").write_text(s, UTF8)


def make_jittered_vs(pack: Path, name: str):
    """The game's scene vertex shaders with the DLSS camera jitter: their main() is renamed and
    called from a new main() that offsets gl_Position (early returns included)."""
    s = read(pack / "original" / (name + ".glsl"))
    m = re.search(r"void\s+main\s*\(\s*(void)?\s*\)", s)
    if not m:
        raise SystemExit(f"{name}: main() not found")
    s = s[:m.start()] + "void auGameMain()" + s[m.end():]
    guard_a = "#if !USE_SCENE_DATA_OVERRIDE\n" if "USE_SCENE_DATA_OVERRIDE" in s else ""
    guard_b = "#endif\n" if guard_a else ""
    s = rep(s, "#version 410 core\n", "#version 410 core\n// Aurora Shaders for Hytale - " + name
            + " with the DLSS camera jitter. Generated by tools/prepare_shaders.py from the game shader.\n",
            name + " header")
    s += ("\n// DLSS camera jitter (sub-pixel offset per frame, set by the hook; 0 without DLSS).\n"
          + "uniform vec2 uHookJitter;\nvoid main()\n{\n    auGameMain();\n" + guard_a
          + "    gl_Position.xy += uHookJitter * gl_Position.w;\n" + guard_b + "}\n")
    (pack / "programs" / (name + ".glsl")).write_text(s, UTF8)


def make_particle_fs(pack: Path):
    """The game's ParticleFS with glowing particles (flames, sparks) mapped through the inverse
    of the pack's tonemap, so they show Hytale's colour instead of a pale, darker one."""
    s = read(pack / "original" / "ParticleFS.glsl")
    call = "    processOIT(color, fragDepthVS, sceneLinearDepth, screenUV, blendMode, hasBloom, outColor0, outColor1);\n"
    if call not in s:
        raise SystemExit("ParticleFS: game shader changed, processOIT call not found")
    s = s.replace(call, "    if (hasBloom) color.rgb = AU_InverseTonemap(pow(clamp(color.rgb, 0.0, 0.88), vec3(2.2)));   // Aurora\n" + call)
    # After the game's OIT prelude, not after #version: OIT_prelude.glsl carries #extension
    # directives, and Mesa (unlike NVIDIA's compiler) rejects them once code has been seen.
    anchor = '#include "OIT_prelude.glsl"\n'
    s = rep(s, anchor, anchor + '#include "AU_Tonemap.glsl"\n', "ParticleFS tonemap include")
    (pack / "programs" / "ParticleFS.glsl").write_text(s, UTF8)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", help='path to the game client binary ("HytaleClient" / "HytaleClient.exe")')
    ap.add_argument("--mapchunk-only", action="store_true",
                    help="only regenerate programs/MapChunk*.glsl, ParticleFS and the jittered VSs")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    pack = root / "shaderpack"
    snip = root / "tools" / "mapchunk"

    if not args.mapchunk_only:
        if not args.exe:
            ap.error('pass --exe "<...>/Client/HytaleClient"')
        exe = Path(args.exe).expanduser()
        if not exe.is_file():
            raise SystemExit(f"not found: {exe}")
        orig = pack / "original"
        n = extract(exe, orig)
        print(f"Extracted {n} game shaders into {orig}")
        n = build_index(orig, pack / "index.txt")
        print(f"Shader index: {n} entries")
        # Client/HytaleClient -> Assets.zip next to the Client folder.
        assets = exe.parent.parent / "Assets.zip"
        if assets.is_file():
            n = build_materials(assets, pack / "materials.txt")
            print(f"Block materials: {n} textures")
        else:
            print("Assets.zip not found next to the game: no block materials")
    make_map_chunk(pack, snip)
    print(f"Generated {pack / 'programs' / 'MapChunkFS.glsl'}")
    make_map_chunk_vs(pack, snip)
    print(f"Generated {pack / 'programs' / 'MapChunkVS.glsl'}")
    make_particle_fs(pack)
    print(f"Generated {pack / 'programs' / 'ParticleFS.glsl'}")
    for vs in ("BlockyModelVS", "ParticleVS", "SkyAndCloudsVS", "BasicVS", "BasicFogVS", "BeamVS", "TextVS"):
        make_jittered_vs(pack, vs)
    print("Generated the jittered scene vertex shaders")


if __name__ == "__main__":
    main()
