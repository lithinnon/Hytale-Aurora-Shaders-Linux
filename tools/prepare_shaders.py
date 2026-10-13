#!/usr/bin/env python3
# Linux/macOS port of tools/prepare_shaders.ps1. Prepares shaderpack/ for the installed game:
#   1. extracts Hytale's GLSL from the HytaleClient binary into shaderpack/original (the pack's
#      overrides include parts of it, and it cannot be redistributed, so every install pulls it
#      from the player's own game),
#   2. builds shaderpack/index.txt (unique source lines the hook uses to recognise each shader),
#   3. generates shaderpack/programs/MapChunkFS.glsl from the game's MapChunkFS + tools/mapchunk/*.
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
        (out_dir / name).write_bytes(data[best_base + off:best_base + off + ln])
        written += 1
    return written


def build_index(orig_dir: Path, out_path: Path) -> int:
    files = sorted(orig_dir.glob("*.glsl"), key=lambda f: f.name)
    text = {f.name: f.read_text(UTF8) for f in files}
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


def read(p: Path) -> str:
    return p.read_text(UTF8).lstrip("\ufeff").replace("\r\n", "\n")


def rep(s: str, a: str, b: str, what: str) -> str:
    i = s.find(a)
    if i < 0:
        raise SystemExit(f"MapChunkFS: game shader changed, anchor not found in {what}: "
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
    s = rep(s, "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n\n    writeToGBuffer(",
            "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n"
            + read(snip / "gennormals.glsl") + "\n    writeToGBuffer(", "gennormals")
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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", help='path to the game client binary ("HytaleClient" / "HytaleClient.exe")')
    ap.add_argument("--mapchunk-only", action="store_true",
                    help="only regenerate programs/MapChunkFS.glsl (after editing tools/mapchunk/*)")
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
    make_map_chunk(pack, snip)
    print(f"Generated {pack / 'programs' / 'MapChunkFS.glsl'}")


if __name__ == "__main__":
    main()
