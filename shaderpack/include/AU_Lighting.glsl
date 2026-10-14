// Aurora Shaders for Hytale - surface lighting.
// Sun, sky and block light with GGX highlights, on top of Hytale's G-buffer: sky light = per-vertex sun occlusion, block light = coloured static light.

#ifndef AU_LIGHTING
#define AU_LIGHTING

#include "AU_Common.glsl"

float GetNoHSquared(float radiusTan, float NoL, float NoV, float VoL)
{
    float radiusCos = 1.0 / sqrt(1.0 + radiusTan * radiusTan);
    float RoL = 2.0 * NoL * NoV - VoL;
    if (RoL >= radiusCos) return 1.0;

    float rOverLengthT = radiusCos * radiusTan / sqrt(1.0 - RoL * RoL);
    float NoTr = rOverLengthT * (NoV - RoL * NoL);
    float VoTr = rOverLengthT * (2.0 * NoV * NoV - 1.0 - RoL * VoL);
    float triple = sqrt(clamp(1.0 - NoL * NoL - NoV * NoV - VoL * VoL + 2.0 * NoL * NoV * VoL, 0.0, 1.0));
    float NoBr = rOverLengthT * triple, VoBr = rOverLengthT * (2.0 * triple * NoV);
    float NoLVTr = NoL * radiusCos + NoV + NoTr, VoLVTr = VoL * radiusCos + 1.0 + VoTr;
    float p = NoBr * VoLVTr, q = NoLVTr * VoLVTr, s = VoBr * NoLVTr;
    float xNum = q * (-0.5 * p + 0.25 * VoBr * NoLVTr);
    float xDenom = p * p + s * ((s - 2.0 * p)) + NoLVTr * ((NoL * radiusCos + NoV) * VoLVTr * VoLVTr +
                   q * (-0.5 * (VoLVTr + VoL * radiusCos) - 0.5));
    float twoX1 = 2.0 * xNum / (xDenom * xDenom + xNum * xNum);
    float sinTheta = twoX1 * xDenom;
    float cosTheta = 1.0 - twoX1 * xNum;
    NoTr = cosTheta * NoTr + sinTheta * NoBr;
    VoTr = cosTheta * VoTr + sinTheta * VoBr;
    float newNoL = NoL * radiusCos + NoTr;
    float newVoL = VoL * radiusCos + VoTr;
    float NoH = NoV + newNoL;
    float HoH = 2.0 * newVoL + 2.0;
    return clamp(NoH * NoH / HoH, 0.0, 1.0);
}

float GGX(vec3 normalM, vec3 nViewPos, vec3 L, float NdotLmax0, float smoothnessG)
{
    smoothnessG = sqrt1(smoothnessG * 0.9 + 0.1);
    float roughnessP = (1.35 - smoothnessG);
    float roughness = pow2(pow2(roughnessP));

    vec3 halfVec = normalize(L - nViewPos);
    float dotLH = clamp(dot(halfVec, L), 0.0, 1.0);
    float dotNV = dot(normalM, -nViewPos);
    float dotNH = GetNoHSquared(0.01, NdotLmax0, dotNV, dot(-nViewPos, L));

    float denom = dotNH * roughness - dotNH + 1.0;
    float D = roughness / (3.141592653589793 * pow2(denom));
    float f0 = 0.05;
    float F = exp2((-5.55473 * dotLH - 6.98316) * dotLH) * (1.0 - f0) + f0;

    float NdotLmax0M = sqrt3(NdotLmax0 * NdotLmax0);
    float specular = max0(NdotLmax0M * D * F / pow2(dotLH));
    return specular / (0.125 * specular + 1.0);
}

vec3 GetMinimumLighting(float lightmapYM)
{
    vec3 minLighting = vec3(0.005625 + vsBrightness * 0.043) * (AU_CAVE_LIGHTING * 0.01);
    minLighting *= vec3(0.45, 0.475, 0.6);
    minLighting *= 1.0 - lightmapYM;
    return max(minLighting, vec3(0.0));
}

// Hytale's coloured block light -> a Minecraft-style lightmap curve, keeping some of the hue.
vec3 GetBlockLighting(vec3 hytaleLight, out float lightmapXM)
{
    // Hytale's glow peaks around 0.5-0.6 next to a torch; Minecraft's lightmap reaches ~0.93.
    float glow = max(hytaleLight.r, max(hytaleLight.g, hytaleLight.b));
    float x = clamp(glow * AU_BLOCKLIGHT_RANGE, 0.0, 0.93);
    float lightmapXMSteep = pow2(pow2(x * x)) * (2.8 - 0.6 * vsBrightness + 1.0);
    float lightmapXMCalm = x * (2.8 + 0.6 * vsBrightness - 1.0);
    lightmapXM = pow(lightmapXMSteep + lightmapXMCalm, 2.25);

    vec3 hue = glow > 0.0001 ? hytaleLight / glow : vec3(1.0);
    vec3 hytaleCol = DoLuminanceCorrection(hue * hue) * GetLuminance(blocklightCol);
    vec3 col = mix(blocklightCol, hytaleCol, AU_BLOCKLIGHT_HYTALE_HUE);
    return lightmapXM * col * AU_BLOCKLIGHT_STRENGTH;
}

// Hytale's static light is max(SunLightColor * skyLight * exposition, glow * exposition * 2)
// (MapChunkVS). Recover the block-light (glow) part: wherever the sun term wins, block light
// is hidden behind it anyway.
vec3 AU_ExtractBlockLight(vec3 staticLight, float skyLight, vec3 normal, bool flatShading)
{
    float exposition = flatShading ? 1.0 : 0.6 + max(0.4 * clamp(normal.y, 0.0, 1.0), 0.2 * abs(normal.z));
    vec3 sunPart = SunLightColor.rgb * SunLightColor.a * skyLight * exposition;
    float lumL = GetLuminance(staticLight);
    float lumS = GetLuminance(sunPart);
    float isBlock = smoothstep(lumS * 1.03 + 0.004, lumS * 1.3 + 0.03, lumL);
    return staticLight / (2.0 * exposition) * isBlock;
}

// Terrain drawn by the pack's MapChunkVS stores the pure glow instead (G-buffer meta bit 7,
// AU_GBUFFER_PURE_GLOW), so torches keep their light by day.
#define AU_GBUFFER_PURE_GLOW 128u
#define AU_GBUFFER_ORE_GLOW 28u   // 3-bit glow level (bits 2-4)
float AU_OreGlowLevel(float meta) { return float((uint(round(meta * 255.0)) >> 2) & 7u) / 7.0; }
// Block material of a terrain texel (tools/mapchunk/gennormals.glsl): class 0 plain,
// 1 polished, 2 metal, 3 porous (bits 5-6); level 0-1 (bits 2-4, the ore glow bits otherwise).
uint AU_MaterialClass(float meta) { return (uint(round(meta * 255.0)) >> 5) & 3u; }
float AU_MaterialLevel(float meta) { return float((uint(round(meta * 255.0)) >> 2) & 7u) / 7.0; }
vec3 AU_GlowToBlockLight(vec3 glowLight, vec3 normal, bool flatShading)
{
    float exposition = flatShading ? 1.0 : 0.6 + max(0.4 * clamp(normal.y, 0.0, 1.0), 0.2 * abs(normal.z));
    return glowLight / (2.0 * exposition);
}

// subsurfaceMode: 0 = solid, 1 = grass-like, 2 = leaves-like.
// shadowVis: raw sun shadow visibility (1 = lit). ao: screen-space AO (1 = none).
// Sky light scale from the path tracer (DeferredFS sets it before AU_DoLighting): the
// share of the open sky the surface sees, which Hytale's flood-fill sky light can't tell.
float auPTSky = 1.0;

vec3 AU_DoLighting(vec3 albedo, vec3 normalM, vec3 playerPos, float skyLight, vec3 hytaleBlockLight,
                   float shadowVis, float ao, int subsurfaceMode, float emission, float smoothnessG,
                   float highlightMult, bool noDirectionalShading)
{
    const vec3 upVec = vec3(0.0, 1.0, 0.0);
    const vec3 northVec = vec3(0.0, 0.0, -1.0);
    const vec3 eastVec = vec3(1.0, 0.0, 0.0);

    float lViewPos = length(playerPos);
    vec3 nViewPos = playerPos / max(lViewPos, 0.0001);

    float NdotN = dot(normalM, northVec);
    float absNdotN = abs(NdotN);
    float NdotE = dot(normalM, eastVec);
    float absNdotE = abs(NdotE);
    float NdotL = dot(normalM, lightVec);
    float NdotU = dot(normalM, upVec);
    float NdotUmax0 = max(NdotU, 0.0);

    skyLight = clamp(skyLight, 0.0, 1.0);
    float lightmapY2 = pow2(skyLight);
    float lightmapYM = smoothstep1(skyLight);
    float subsurfaceHighlight = 0.0;
    float ambientMult = 1.0;
    vec3 lightColorM = lightColor;
    vec3 ambientColorM = ambientColor;

    // ---- Sun / moon light with shadows ----
    float NdotLmax0 = max0(NdotL);
    float NdotLM = NdotLmax0 * 0.9999;
    if (subsurfaceMode != 0) {
        // Hytale's leaves barely self-shadow in its shadow map, so use a
        // shadowless foliage path: half top-lit, wrapped towards the light.
        float NdotLfol = subsurfaceMode == 2 ? NdotL : mix(NdotL, dot(upVec, lightVec), 0.5);
        // Leaves: half-Lambert wrapped towards full light, since light transmits through them.
        // Leaves take full light (translucent); grass is half top-lit.
        NdotLM = subsurfaceMode == 2 ? 1.0 : max0(mix(NdotLfol, 1.0, 0.5));
        highlightMult *= max0(NdotLfol);
    } else {
#if AU_SIDE_SHADOWING
        NdotLM = max0(NdotL + 0.4) * 0.714;
#endif
    }

    // Hytale's shadow mask is lit beyond the cascades; fall back to the
    // sky lightmap there, and the lightmap also keeps caves from leaking sunlight.
    // Beyond the shadow cascades the light falls back to lightmap^8 (skyLightShadowMult).
    float skyLightShadowMult = pow2(pow2(lightmapY2));
    float shadowFar = max(SunShadowCascadeStats[AU_SHADOW_CASCADES - 1].x, 1.0);
    float beyondShadows = smoothstep(0.8, 1.0, lViewPos / shadowFar);
    // Leaves let some light through even where the shadow map says they are occluded.
    float shadowVisM = subsurfaceMode == 2 ? mix(shadowVis, 1.0, 0.3) : shadowVis;
    // Beyond the cascades the mask holds the distant screen-space shadows, combined with the
    // lightmap; distant leaves also get the shadowless leaf shading.
    float farLeaf = 1.0;
    if (subsurfaceMode == 2) farLeaf = (NdotL * 0.4999 + 0.5) * mix(1.0, NdotU * 0.5 + 0.5, 0.125 + 0.125 * pow2(noonFactor));
    else if (subsurfaceMode == 1) farLeaf = 0.6 + 0.3 * pow2(noonFactor);
    vec3 shadowMult = vec3(mix(shadowVisM * smoothstep(0.0, 0.4, skyLight), skyLightShadowMult * shadowVis * farLeaf, beyondShadows));

    if (subsurfaceMode != 0) {
        float VdotL = dot(nViewPos, lightVec);
        float lightFactor = pow(max(VdotL, 0.0), 10.0) * float(IsCameraUnderwater < 0.5);
        subsurfaceHighlight = lightFactor * (subsurfaceMode == 1 ? 0.8 : 0.6) * AU_SUBSURFACE_GLOW;
    }
    shadowMult *= max(NdotLM * shadowTime, 0.0);

    // ---- Block light ----
    float lightmapXM;
    vec3 blockLighting = GetBlockLighting(hytaleBlockLight, lightmapXM);
    float daylightFactor = lightmapYM * invRainFactor * sunVisibility;
    emission *= 1.0 - 0.25 * daylightFactor;

    vec3 minLighting = GetMinimumLighting(lightmapYM);
    vec3 shadowLightMult = shadowMult;
    float shadowMultFloat = min1(GetLuminance(shadowMult));

    // ---- Overworld tweaks ----
    ambientMult = mix(lightmapYM, pow2(lightmapYM) * lightmapYM, rainFactor);
    if (IsCameraUnderwater < 0.5) {
        float lxFactor = (sunVisibility2 * 0.4 + (0.6 - 0.6 * invNoonFactor2)) * (6.0 - 5.0 * rainFactor);
        lxFactor *= lightmapY2 + lightmapY2 * 2.0 * pow2(shadowMultFloat);
        lxFactor = max0(lxFactor - emission * 1000000.0);
        blockLighting *= pow(lightmapXM / 60.0 + 0.001, 0.09 * lxFactor);

        float rainLF = 0.1 * rainFactor;
        float lightFogTweaks = 1.0 + max0(96.0 - lViewPos) * (0.002 * (1.0 - sunVisibility2) + 0.0104 * rainLF) - rainLF;
        ambientMult *= lightFogTweaks;
        lightColorM *= lightFogTweaks;
    }
    ambientMult *= auPTSky;

    // ---- Directional shading ----
    float directionShade = 1.0;
#if AU_DIRECTIONAL_SHADING
    if (!noDirectionalShading) {
        float absNdotE2 = pow2(absNdotE);
        float NdotUM = 0.75 + NdotU * 0.25;
        if (subsurfaceMode == 2) NdotUM = max(NdotUM, 0.72); // leaf undersides stay soft, not black
        float NdotNM = 1.0 + 0.075 * absNdotN;
        float NdotEM = 1.0 - 0.1 * absNdotE2;
        directionShade = NdotUM * NdotEM * NdotNM;
        lightColorM *= 1.0 + absNdotE2 * 0.75;

        // Fake bounced light + more natural noon lighting (PERPENDICULAR_TWEAKS)
        ambientColorM = mix(ambientColorM, lightColorM, (0.05 + 0.03 * float(subsurfaceMode)) * absNdotN * lightmapY2);
        lightColorM *= 1.0 + max0(1.0 - float(subsurfaceMode)) * pow(noonFactor, 20.0) * (pow2(absNdotN) * 0.8 - absNdotE2 * 0.2);
    }
#endif

    vec3 sceneLighting = lightColorM * shadowLightMult + ambientColorM * ambientMult;
    float dotSceneLighting = dot(sceneLighting, sceneLighting);

    // ---- Ambient occlusion (Hytale's SSAO in place of vanilla AO) ----
    float vanillaAO = pow(clamp(ao, 0.0, 1.0), AU_SSAO_STRENGTH);
    if (subsurfaceMode != 0) {
        vanillaAO = mix(min1(vanillaAO * 1.15), 1.0, shadowMultFloat);
    } else {
        vanillaAO = min1(vanillaAO + 0.08);
        vanillaAO = pow(pow1_5(vanillaAO), 1.0 + dotSceneLighting * 0.02 + NdotUmax0 * (0.15 + 0.25 * pow2(noonFactor * pow2(lightmapY2))));
    }
    vanillaAO = vanillaAO * 0.9 + 0.1;

    // ---- Light highlight ----
    vec3 lightHighlight = vec3(0.0);
#if AU_LIGHT_HIGHLIGHT
    vec3 highlightColor = normalize(pow(lightColor, vec3(0.37))) * (0.3 + 1.5 * sunVisibility2) * (1.0 - 0.85 * rainFactor);
    float specularHighlight = GGX(normalM, nViewPos, lightVec, NdotLmax0, smoothnessG) * highlightMult;
    lightHighlight = IsCameraUnderwater < 0.5 ? shadowMult : pow(shadowMult, vec3(0.25)) * 0.35;
    lightHighlight *= (subsurfaceHighlight + specularHighlight) * highlightColor;
#endif

    vec3 finalDiffuse = pow2(directionShade * vanillaAO) * (blockLighting + pow2(sceneLighting) + minLighting) + pow2(emission);
    finalDiffuse = sqrt(max(finalDiffuse, vec3(0.0)));

    return albedo * finalDiffuse + lightHighlight;
}

#endif // AU_LIGHTING
