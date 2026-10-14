# Prepares shaderpack/ for the installed game version:
#   1. extracts Hytale's GLSL from HytaleClient.exe into shaderpack/original (the pack's overrides
#      include parts of it, and it cannot be redistributed, so every install pulls it from the
#      player's own game),
#   2. builds shaderpack/index.txt (unique source lines the hook uses to recognise each shader),
#   3. generates shaderpack/programs/MapChunkFS.glsl from the game's MapChunkFS + tools/mapchunk/*.
#
#   prepare_shaders.ps1 -Exe "<...>\Client\HytaleClient.exe"
#   prepare_shaders.ps1 -MapChunkOnly        (after editing tools/mapchunk/*.glsl)
param(
    [string]$Exe,
    [switch]$MapChunkOnly
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pack = Join-Path $root 'shaderpack'

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

public static class AuroraPrep
{
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

    // NativeAOT "NativeFormat" unsigned integer.
    static int Nu(byte[] d, ref int p)
    {
        int b0 = d[p];
        if ((b0 & 1) == 0) { p += 1; return b0 >> 1; }
        if ((b0 & 2) == 0) { int v = (b0 >> 2) | (d[p + 1] << 6); p += 2; return v; }
        if ((b0 & 4) == 0) { int v = (b0 >> 3) | (d[p + 1] << 5) | (d[p + 2] << 13); p += 3; return v; }
        if ((b0 & 8) == 0) { int v = (b0 >> 4) | (d[p + 1] << 4) | (d[p + 2] << 12) | (d[p + 3] << 20); p += 4; return v; }
        int r = BitConverter.ToInt32(d, p + 1); p += 5; return r;
    }

    static List<int> FindAll(byte[] d, byte[] pat)
    {
        var hits = new List<int>();
        byte first = pat[0];
        for (int i = Array.IndexOf(d, first); i >= 0 && i <= d.Length - pat.Length; i = Array.IndexOf(d, first, i + 1))
        {
            int k = 1;
            while (k < pat.Length && d[i + k] == pat[k]) k++;
            if (k == pat.Length) hits.Add(i);
        }
        return hits;
    }

    static bool StartsWithAt(byte[] d, int at, byte[] pat)
    {
        if (at < 0 || at + pat.Length > d.Length) return false;
        for (int k = 0; k < pat.Length; k++) if (d[at + k] != pat[k]) return false;
        return true;
    }

    // Returns the number of shader files written.
    public static int Extract(string exe, string outDir)
    {
        byte[] d = File.ReadAllBytes(exe);
        byte[] asm = Encoding.ASCII.GetBytes("HytaleClient, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null");
        const string prefix = "HytaleClient.Graphics.Shaders.";
        var res = new List<Tuple<string, int, int>>();
        foreach (int m in FindAll(d, asm))
        {
            int p = m + asm.Length;
            int n = Nu(d, ref p);
            if (n <= 0 || n > 512 || p + n > d.Length) continue;
            string name = Encoding.ASCII.GetString(d, p, n);
            if (!name.StartsWith(prefix)) continue;
            int q = p + n;
            int off = Nu(d, ref q);
            int len = Nu(d, ref q);
            res.Add(Tuple.Create(name.Substring(prefix.Length), off, len));
        }
        if (res.Count == 0) throw new Exception("No shader resources found in " + exe);

        // The resources are stored back to back in one blob; find its start by checking which
        // "#version" occurrence makes the most vertex/fragment shaders start with "#version".
        byte[] ver = Encoding.ASCII.GetBytes("#version 410 core");
        var mains = res.Where(r => r.Item1.EndsWith("FS.glsl") || r.Item1.EndsWith("VS.glsl")).ToList();
        var first = mains.OrderBy(r => r.Item2).First();
        int bestBase = -1, bestScore = 0;
        foreach (int occ in FindAll(d, ver))
        {
            int b = occ - first.Item2;
            int score = mains.Count(r => StartsWithAt(d, b + r.Item2, ver));
            if (score > bestScore) { bestScore = score; bestBase = b; }
        }
        if (bestBase < 0 || bestScore < mains.Count / 2) throw new Exception("Could not locate the shader data in " + exe);

        Directory.CreateDirectory(outDir);
        foreach (var r in res)
        {
            if (bestBase + r.Item2 + r.Item3 > d.Length) continue;
            var data = new byte[r.Item3];
            Array.Copy(d, bestBase + r.Item2, data, 0, r.Item3);
            File.WriteAllBytes(Path.Combine(outDir, r.Item1), data);
        }
        return res.Count;
    }

    // For every main (non-include) shader: up to three source lines found in no other shader.
    // The hook hashes each line of a runtime shader and identifies it by these.
    public static int BuildIndex(string origDir, string outPath)
    {
        var files = Directory.GetFiles(origDir, "*.glsl").OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal).ToList();
        var text = files.ToDictionary(f => Path.GetFileName(f), f => File.ReadAllText(f, Utf8));
        var included = new HashSet<string>();
        foreach (var t in text.Values)
            foreach (Match m in Regex.Matches(t, "#include\\s*\"([^\"]+)\"")) included.Add(m.Groups[1].Value);
        var lines = text.ToDictionary(kv => kv.Key, kv => new HashSet<string>(
            kv.Value.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0)));
        var count = new Dictionary<string, int>();
        foreach (var set in lines.Values)
            foreach (var l in set) { int c; count[l] = count.TryGetValue(l, out c) ? c + 1 : 1; }
        var outLines = new List<string>();
        foreach (var name in text.Keys.Where(n => !included.Contains(n)))
        {
            var sigs = lines[name]
                .Where(l => count[l] == 1 && l.Length >= 20 && !l.Contains('\t')
                            && !l.StartsWith("#include") && !l.StartsWith("#version"))
                .OrderBy(l => l.StartsWith("//") ? 1 : 0).ThenByDescending(l => l.Length).ThenBy(l => l, StringComparer.Ordinal)
                .Take(3).ToList();
            if (sigs.Count == 0) continue;
            outLines.Add(name.Substring(0, name.Length - 5) + "\t" + string.Join("\t", sigs));
        }
        File.WriteAllText(outPath, string.Join("\n", outLines) + "\n", Utf8);
        return outLines.Count;
    }

    static string Read(string path)
    {
        return File.ReadAllText(path, Utf8).TrimStart((char)0xFEFF).Replace("\r\n", "\n");
    }

    static string Rep(string s, string a, string b)
    {
        int i = s.IndexOf(a, StringComparison.Ordinal);
        if (i < 0) throw new Exception("MapChunkFS: game shader changed, anchor not found: " + a.Substring(0, Math.Min(70, a.Length)).Replace("\n", "\\n"));
        return s.Substring(0, i) + b + s.Substring(i + a.Length);
    }

    // The game's MapChunkFS with the pack's G-buffer normals, forward lighting, water and fog
    // spliced in.
    public static void MakeMapChunk(string pack, string snip)
    {
        string s = Read(Path.Combine(pack, "original", "MapChunkFS.glsl"));
        s = Rep(s, "#endif // !DEFERRED\n\n#if USE_OVERLAY",
                "#endif // !DEFERRED\n\n" + Read(Path.Combine(snip, "includes.glsl")) + "\n#if USE_OVERLAY");
        // Hytale sweeps a fake shine over REFLECTIVE blocks in near chunks only, boosting their
        // static light; the pack's lighting reads that as block light and the near chunks glow
        // in a square around the player. The pack has its own highlights.
        s = Rep(s, "    if (shadingMode == SHADING_REFLECTIVE)\n    {\n"
                 + "        vec4 shininess = computeFakeShininess(texColor.rgb, normalWS, CameraDirection.xyz);\n"
                 + "        light = max(light, vec3(shininess.a));\n        albedo.rgb += shininess.rgb;\n    }\n",
                "    // (Hytale fake shininess removed by Aurora Shaders)\n");
        s = Rep(s, "writeToGBuffer(albedo, normalWS, light, fragStaticLight.a, hasSSAO, hasBloom, useCleanShadowBackfaces, outColor0, outColor1, outColor2);\n",
                "writeToGBuffer(albedo, normalWS, light, fragStaticLight.a, hasSSAO, hasBloom, useCleanShadowBackfaces, outColor0, outColor1, outColor2);\n"
                + "    outColor0.a = (round(outColor0.a * 255.0) + 128.0 + 4.0 * (auMatClass > 0.0 ? auMatLevel : round(clamp(auOreGlow, 0.0, 1.0) * 7.0)) + 32.0 * auMatClass) / 255.0;   // Aurora: pure glow (128), ore glow / material level (bits 2-4), material class (bits 5-6)\n");
        s = Rep(s, "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n\n    writeToGBuffer(",
                "    bool useCleanShadowBackfaces = effectID > EFFECT_WIND;\n\n#if DEFERRED\n"
                + Read(Path.Combine(snip, "gennormals.glsl")) + "\n    writeToGBuffer(");
        string lit = "    outColor0.rgb = albedo * light * shadow;\n    outColor0.a = texColor.a;\n";
        // Glass the pack composites itself (lighting.glsl) is written opaque into the OIT pass.
        s = Rep(s, "    color.a = isWater(effectID) ? 1.0 : texColor.a;\n",
                "#if AU_FORWARD\n    color.a = isWater(effectID) || auGlass ? 1.0 : texColor.a;\n#else\n"
                + "    color.a = isWater(effectID) ? 1.0 : texColor.a;\n#endif\n");
        s = Rep(s, lit, lit + "\n" + Read(Path.Combine(snip, "lighting.glsl")));

        int start = s.IndexOf("    if (isWater(effectID) && uWaterQuality >= 1)\n    {\n        vec2 screenUV", StringComparison.Ordinal);
        int end = s.IndexOf("    // Warning : because of precision issue \"with the UVs\",", StringComparison.Ordinal);
        if (start < 0 || end < start) throw new Exception("MapChunkFS: game shader changed, water block not found");
        string origWater = s.Substring(start, end - start);
        int bodyStart = origWater.IndexOf("{\n", StringComparison.Ordinal) + 2;
        string origBody = origWater.Substring(bodyStart, origWater.LastIndexOf('}') - bodyStart);
        s = s.Substring(0, start)
            + "    if (isWater(effectID) && uWaterQuality >= 1)\n    {\n#if AU_FORWARD && AU_WATER\n"
            + Read(Path.Combine(snip, "water.glsl")) + "#else\n" + origBody + "#endif\n    }\n\n"
            + s.Substring(end);

        s = Rep(s, "#if USE_FOG\n    // Apply fog\n    outColor0.rgb = mix(outColor0.rgb, fragFog.rgb, fragFog.w);\n"
                 + "    hasBloom = hasBloom && fragFog.w < 0.9;\n#endif // USE_FOG",
                "#if USE_FOG\n#if AU_FORWARD\n    DoAUFog(outColor0.rgb, fragPositionWS, auDither, fragStaticLight.a);\n"
                + "    outColor0.rgb = AU_AddVL(outColor0.rgb, auForwardVL);\n#else\n"
                + "    // Apply fog\n    outColor0.rgb = mix(outColor0.rgb, fragFog.rgb, fragFog.w);\n#endif\n"
                + "    hasBloom = hasBloom && fragFog.w < 0.9;\n#endif // USE_FOG");
        s = Rep(s, "#version 410 core\n",
                "#version 410 core\n// Aurora Shaders for Hytale - terrain (G-buffer) and forward water / translucents.\n"
                + "// Generated by tools/prepare_shaders.ps1 from the game shader + tools/mapchunk/*.glsl.\n");
        File.WriteAllText(Path.Combine(pack, "programs", "MapChunkFS.glsl"), s, Utf8);
    }

    // The game's MapChunkVS, recording every block it draws in the path tracer's voxel grid.
    public static void MakeMapChunkVS(string pack, string snip)
    {
        string s = Read(Path.Combine(pack, "original", "MapChunkVS.glsl"));
        s = Rep(s, "#version 410 core\n",
                "#version 410 core\n#extension GL_ARB_shader_image_load_store : enable\n"
                + "// Aurora Shaders for Hytale - terrain vertices + voxel grid.\n"
                + "// Generated by tools/prepare_shaders.ps1 from the game shader + tools/mapchunk/voxelize.glsl.\n");
        s = Rep(s, "#include \"Shading_inc.glsl\"\n",
                "#include \"Shading_inc.glsl\"\n#include \"AU_Settings.glsl\"\n"
                + "#if AU_VOXELS && DEFERRED && !ALPHA_BLEND && !ANIMATED && !USE_SCENE_DATA_OVERRIDE\n"
                + "#define AU_VOX_WRITER_ONLY\n#include \"AU_Voxel.glsl\"\n#endif\n");
        s = Rep(s, "    fragPackedData = packData(effectID, shadingMode);\n",
                Read(Path.Combine(snip, "voxelize.glsl")) + "\n    fragPackedData = packData(effectID, shadingMode);\n");
        // DLSS camera jitter (sub-pixel offset per frame, set by the hook; 0 without DLSS).
        s = Rep(s, "uniform mat4 uModelMatrix;\n", "uniform mat4 uModelMatrix;\nuniform vec2 uHookJitter;\n");
        s = Rep(s, "#endif // ALPHA_BLEND\n\n    float lightExposition;\n",
                "#endif // ALPHA_BLEND\n#if !USE_SCENE_DATA_OVERRIDE\n    gl_Position.xy += uHookJitter * gl_Position.w;\n#endif\n\n    float lightExposition;\n");
        // The G-buffer gets the pure block light (glow); DeferredFS adds the sun part from the
        // sky light itself. Hytale's max(sun, glow) here threw torch light away by day wherever
        // the sky reaches. Forward passes keep the game's combined light.
        string mx = "    fragStaticLight.rgb = max(SunLightColor.rgb * SunLightColor.a * staticLight.a, staticLight.rgb * StaticLightMultiplier);\n";
        s = Rep(s, mx, "#if DEFERRED && !USE_SCENE_DATA_OVERRIDE\n"
                + "    fragStaticLight.rgb = staticLight.rgb * StaticLightMultiplier;   // Aurora: pure glow (AU_GBUFFER_PURE_GLOW)\n"
                + "#else\n" + mx + "#endif\n");
        File.WriteAllText(Path.Combine(pack, "programs", "MapChunkVS.glsl"), s, Utf8);
    }

    // The game's other scene vertex shaders with the DLSS camera jitter: their main() is
    // renamed and called from a new main() that offsets gl_Position (early returns included).
    public static void MakeJitteredVS(string pack, string name)
    {
        string s = Read(Path.Combine(pack, "original", name + ".glsl"));
        var m = System.Text.RegularExpressions.Regex.Match(s, @"void\s+main\s*\(\s*(void)?\s*\)");
        if (!m.Success) throw new Exception(name + ": main() not found");
        s = s.Substring(0, m.Index) + "void auGameMain()" + s.Substring(m.Index + m.Length);
        string guardA = s.Contains("USE_SCENE_DATA_OVERRIDE") ? "#if !USE_SCENE_DATA_OVERRIDE\n" : "";
        string guardB = guardA.Length > 0 ? "#endif\n" : "";
        s = Rep(s, "#version 410 core\n", "#version 410 core\n// Aurora Shaders for Hytale - " + name
                + " with the DLSS camera jitter. Generated by tools/prepare_shaders.ps1 from the game shader.\n");
        s += "\n// DLSS camera jitter (sub-pixel offset per frame, set by the hook; 0 without DLSS).\n"
           + "uniform vec2 uHookJitter;\nvoid main()\n{\n    auGameMain();\n" + guardA
           + "    gl_Position.xy += uHookJitter * gl_Position.w;\n" + guardB + "}\n";
        File.WriteAllText(Path.Combine(pack, "programs", name + ".glsl"), s, Utf8);
    }

    // The game's ParticleFS with glowing particles (flames, sparks) mapped through the inverse of
    // the pack's tonemap, so they show Hytale's colour instead of a pale, darker one.
    public static void MakeParticleFS(string pack)
    {
        string s = Read(Path.Combine(pack, "original", "ParticleFS.glsl"));
        string call = "    processOIT(color, fragDepthVS, sceneLinearDepth, screenUV, blendMode, hasBloom, outColor0, outColor1);\n";
        if (s.IndexOf(call, StringComparison.Ordinal) < 0) throw new Exception("ParticleFS: game shader changed, processOIT call not found");
        s = s.Replace(call, "    if (hasBloom) color.rgb = AU_InverseTonemap(pow(clamp(color.rgb, 0.0, 0.88), vec3(2.2)));   // Aurora\n" + call);
        int nl = s.IndexOf('\n');
        s = s.Substring(0, nl + 1) + "#include \"AU_Tonemap.glsl\"\n" + s.Substring(nl + 1);
        File.WriteAllText(Path.Combine(pack, "programs", "ParticleFS.glsl"), s, Utf8);
    }

    // ---- Block materials --------------------------------------------------------------------
    // shaderpack/materials.txt: one line per 32x32 block texture of the game - a fingerprint of
    // its pixels (FNV-1a over RGBA, top row first, transparent texels as 0) and the material its
    // name says it is. The hook fingerprints the tiles of Hytale's block atlas the same way and
    // builds the per-tile material map the terrain shader reads (hook.c, materials_build).
    //   class 0 default, 1 polished (gloss = level), 2 metal (level = polish), 3 porous (soaks
    //   up rain, darker when wet; level = how much); level 0-7.
    static int[] Classify(string name)
    {
        string n = name.ToLowerInvariant();
        Func<string, bool> has = k => n.Contains(k);
        if (n.StartsWith("fluid") || n.StartsWith("dev") || n.StartsWith("editor") || n.StartsWith("t_")
            || n.StartsWith("transition") || has("grass") || has("leaves") || has("moss")) return new[] { 0, 0 };
        if (n.StartsWith("metal_") || n.StartsWith("rock_gold"))
            return new[] { 2, has("smooth") ? 6 : (has("goblin") || has("rust") || has("scrap")) ? 2 : 4 };
        if (has("ice") || n.StartsWith("glass")) return new[] { 1, 7 };
        if (has("smooth") || has("marble") || has("polish") || has("whitetiles") || has("quartzite_brick")) return new[] { 1, 4 };
        if (has("brick") || has("decorative") || has("ornate") || has("tile") || has("rune") || has("planks")) return new[] { 0, 0 };
        if (n.StartsWith("soil_snow")) return new[] { 0, 0 };
        if (has("gravel") || has("cobble")) return new[] { 3, 4 };
        if (n.StartsWith("soil_") || has("sand") || n.StartsWith("clay")) return new[] { 3, 6 };
        if (n.StartsWith("rock_") || n.StartsWith("calcite") || n.StartsWith("peachstone") || n.StartsWith("chalk")) return new[] { 3, 3 };
        return new[] { 0, 0 };
    }

    public static int BuildMaterials(string assetsZip, string outPath)
    {
        var lines = new List<string>();
        using (var zip = System.IO.Compression.ZipFile.OpenRead(assetsZip))
        {
            foreach (var e in zip.Entries)
            {
                if (!e.FullName.StartsWith("Common/BlockTextures/") || !e.FullName.EndsWith(".png")) continue;
                string name = Path.GetFileNameWithoutExtension(e.FullName);
                int[] cl = Classify(name);
                if (cl[0] == 0) continue;
                byte[] png;
                using (var s = e.Open()) using (var ms = new MemoryStream()) { s.CopyTo(ms); png = ms.ToArray(); }
                using (var bmp = new System.Drawing.Bitmap(new MemoryStream(png)))
                {
                    if (bmp.Width != 32 || bmp.Height != 32) continue;
                    var data = bmp.LockBits(new System.Drawing.Rectangle(0, 0, 32, 32),
                        System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                    var bgra = new byte[32 * 32 * 4];
                    for (int y = 0; y < 32; y++)
                        System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, bgra, y * 128, 128);
                    bmp.UnlockBits(data);
                    uint h = 2166136261u;
                    for (int i = 0; i < 1024; i++)
                    {
                        byte b = bgra[i * 4], g = bgra[i * 4 + 1], r = bgra[i * 4 + 2], a = bgra[i * 4 + 3];
                        if (a == 0) { r = g = b = 0; }
                        foreach (byte v in new[] { r, g, b, a }) { h ^= v; h *= 16777619u; }
                    }
                    lines.Add(string.Format("{0:x8} {1} {2} {3}", h, cl[0], cl[1], name));
                }
            }
        }
        lines.Sort(StringComparer.Ordinal);
        File.WriteAllLines(outPath, new[] { "# fingerprint class level texture  (tools/prepare_shaders.ps1 BuildMaterials)" }.Concat(lines), Utf8);
        return lines.Count;
    }
}
'@ -ReferencedAssemblies System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem

if (-not $MapChunkOnly) {
    if (-not $Exe) { throw 'Pass -Exe "<...>\Client\HytaleClient.exe".' }
    $orig = Join-Path $pack 'original'
    $n = [AuroraPrep]::Extract($Exe, $orig)
    Write-Host "Extracted $n game shaders into shaderpack\original"
    $n = [AuroraPrep]::BuildIndex($orig, (Join-Path $pack 'index.txt'))
    Write-Host "Shader index: $n entries"
    # Client\HytaleClient.exe -> Assets.zip next to the Client folder.
    $assets = Join-Path (Split-Path (Split-Path $Exe -Parent) -Parent) 'Assets.zip'
    if (Test-Path $assets) {
        $n = [AuroraPrep]::BuildMaterials($assets, (Join-Path $pack 'materials.txt'))
        Write-Host "Block materials: $n textures"
    } else {
        Write-Host 'Assets.zip not found next to the game: no block materials'
    }
}
[AuroraPrep]::MakeMapChunk($pack, (Join-Path $PSScriptRoot 'mapchunk'))
Write-Host 'Generated shaderpack\programs\MapChunkFS.glsl'
[AuroraPrep]::MakeMapChunkVS($pack, (Join-Path $PSScriptRoot 'mapchunk'))
Write-Host 'Generated shaderpack\programs\MapChunkVS.glsl'
[AuroraPrep]::MakeParticleFS($pack)
Write-Host 'Generated shaderpack\programs\ParticleFS.glsl'
foreach ($vs in 'BlockyModelVS', 'ParticleVS', 'SkyAndCloudsVS', 'BasicVS', 'BasicFogVS', 'BeamVS', 'TextVS') {
    [AuroraPrep]::MakeJitteredVS($pack, $vs)
}
Write-Host 'Generated the jittered scene vertex shaders'
