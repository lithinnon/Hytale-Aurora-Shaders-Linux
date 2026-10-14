#version 410 core
#extension GL_ARB_shader_image_load_store : enable

// Aurora Shaders for Hytale - deferred lighting.
// Replaces Hytale's albedo * (light + ambient) * shadow with a full lighting model,
// atmospheric/border fog and volumetric light shafts.

#include "SceneData_inc.glsl"
#include "Deferred_inc.glsl"
#include "Reconstruction_inc.glsl"
#include "Fog_inc.glsl"
#include "AU_Lighting.glsl"
#include "AU_Tonemap.glsl"
#include "AU_VL.glsl"
#include "AU_Clouds.glsl"
#include "AU_Caustics.glsl"
#include "AU_Rainbow.glsl"
#if AU_PRESET >= 2 || AU_RAIN_PUDDLES
#include "AU_RTX.glsl"
#endif
#if AU_VOXELS
#include "AU_Voxel.glsl"
#endif

#ifndef INPUT_NORMALS_IN_WS
#define INPUT_NORMALS_IN_WS 1
#endif

uniform sampler2D uColorTexture;
uniform sampler2D uNormalTexture;
uniform sampler2D uDepthTexture;
uniform sampler2D uSSAOTexture;
uniform sampler2D uLightTexture;
uniform sampler2D uTopDownProjectionTexture;
uniform sampler2D uShadowTexture;
#if USE_FOG
uniform sampler2D uFogNoiseTexture;
#endif

in vec3 fragFrustumRay;
in vec2 fragTexCoords;

out vec4 outColor;

float getShadowFactor(vec2 texCoords)
{
#if USE_DEFERRED_SHADOW
#if USE_DEFERRED_SHADOW_BLURRED && USE_SSAO
    return texture(uSSAOTexture, texCoords).a;
#else
    return texture(uShadowTexture, texCoords).r;
#endif
#else
    return 1.0;
#endif
}

#if AU_PRESET >= 2
// One-bounce source for the RTX GI: the sun light a surface receives this frame (albedo x
// shadow-mapped sun x N.L), plus emissive blocks, read straight from the G-buffer.
vec3 AU_GIHitLight(vec2 uv)
{
    vec4 g0 = textureLod(uColorTexture, uv, 0.0);
    bool hitSSAO, hitBloom;
    unpackGBufferMeta(g0.a, hitSSAO, hitBloom);
    vec3 alb = g0.rgb * AU_ALBEDO_MULT;
    if (hitBloom) return alb * AU_RTX_GI_EMISSIVE;
    // Glowing ore crystals light up what is around them in their colour (the same evened-out
    // tint as their glow).
    float hitOre = AU_MaterialClass(g0.a) == 0u ? AU_OreGlowLevel(g0.a) : 0.0;
    vec3 oreLight = hitOre > 0.0 ? alb * pow(max(GetLuminance(alb), 0.002), -0.5) * (hitOre * AU_ORE_LIGHT) : vec3(0.0);
    vec3 n = decodeNormal(textureLod(uNormalTexture, uv, 0.0).rg);
    // Foliage is lit flat (no N.L) by Hytale's shading.
    float NdotL = hitSSAO ? max(dot(n, lightVec), 0.0) : 0.6;
#if AU_VOXELS
    // Path tracing: plus the torch light it gets (Hytale's glow), so that bounces too.
    vec3 hitStatic = textureLod(uLightTexture, uv, 0.0).rgb;
    vec3 hitGlow = (uint(round(g0.a * 255.0)) & AU_GBUFFER_PURE_GLOW) != 0u
                 ? AU_GlowToBlockLight(hitStatic, n, !hitSSAO)
                 : AU_ExtractBlockLight(hitStatic, textureLod(uNormalTexture, uv, 0.0).b, n, !hitSSAO);
    // And the sky light it gets, for the further bounces (what fills a room with light):
    // Hytale's sky light there, through the same curve as the ambient term.
    float hitSky = smoothstep1(clamp(textureLod(uNormalTexture, uv, 0.0).b, 0.0, 1.0));
    return alb * (lightColor * (getShadowFactor(uv) * NdotL) + hitGlow * 0.5 + ambientColor * (hitSky * AU_PT_AMBIENT_BOUNCE)) + oreLight;
#else
    return alb * lightColor * (getShadowFactor(uv) * NdotL) + oreLight;
#endif
}

// For the path tracer's sky light: albedo luminance and Hytale sky light of an on-screen
// surface (the sky light it passes on when a ray hits it).
vec2 AU_GIHitAlbedoSky(vec2 uv)
{
    vec3 alb = textureLod(uColorTexture, uv, 0.0).rgb * AU_ALBEDO_MULT;
    return vec2(GetLuminance(alb), textureLod(uNormalTexture, uv, 0.0).b);
}
#endif

float getSSAOValue(vec2 texCoords, float depth)
{
#if USE_SSAO
#if USE_EDGE_AWARE_UPSAMPLING
    float totalWeight = 0.0;
    float resultValue = 0.0;
    const float depth_epsilon = 0.0001;
    for (int x = 0; x <= 1; x++) {
        for (int y = 0; y <= 1; y++) {
            vec4 value = textureOffset(uSSAOTexture, texCoords, ivec2(x, y));
            float lowResDepth = unpackDepth(value.gb);
            float weight = 1.0 / (depth_epsilon + abs(depth - lowResDepth));
            resultValue += value.r * weight;
            totalWeight += weight;
        }
    }
    return resultValue / totalWeight;
#else
    return texture(uSSAOTexture, texCoords).r;
#endif
#else
    return 1.0;
#endif
}

void main()
{
    AU_InitCommon();

    vec2 texCoords = fragTexCoords;
#if AU_VOXELS && AU_PT_LIGHTS
    // Empty next frame's light list; MapChunkVS fills it before this pass runs again.
    if (gl_FragCoord.x < 1.0 && gl_FragCoord.y < 1.0) imageStore(auLights, ivec2(0, 1 - (uHookFrame & 1)), uvec4(0u));
#endif
    float depth = texture(uDepthTexture, texCoords).r;
    if (depth >= 1.0) discard;

    vec4 gbuffer0 = texture(uColorTexture, texCoords);   // RGBA8: albedo + render flags
    vec3 albedo = gbuffer0.rgb;
    albedo = mix(vec3(GetLuminance(albedo)), albedo, AU_ALBEDO_SATURATION) * AU_ALBEDO_MULT;
    vec4 gbuffer1 = texture(uNormalTexture, texCoords);
    vec3 blockLight = texture(uLightTexture, texCoords).rgb;
    float skyLight = gbuffer1.b;
    float ao = getSSAOValue(texCoords, depth);
    float shadow = getShadowFactor(texCoords);

#if USE_LINEAR_Z
    vec3 playerPos = fragFrustumRay * depth;
#else
    vec3 playerPos = PositionFromDepth(depth, texCoords, InvViewProjectionMatrix);
#endif

    bool hasSSAO, hasBloom, useCleanShadowBackfaces;
    unpackGBufferMeta(gbuffer0.a, hasSSAO, hasBloom);
    useCleanShadowBackfaces = gbuffer1.a > 0.5;

    vec3 normal = decodeNormal(gbuffer1.rg);
#if !INPUT_NORMALS_IN_WS
    normal = mat3(InvViewMatrix) * normal;
#endif

    float dither = GetDither(gl_FragCoord.xy);


    // Material classes from Hytale's G-buffer flags:
    //  bloom      -> emissive (no shadows, glows)
    //  no SSAO    -> foliage / wind-animated blocks: subsurface scattering, no side shading
    int subsurfaceMode = 0;
    bool noDirectionalShading = false;
    float emission = 0.0;
#if AU_SUBSURFACE
    if (!hasSSAO && !hasBloom) {
        // Leaf blocks are cubes (axis-aligned normals): keep directional shading.
        // Grass / cross plants have diagonal normals: soft, direction-less light.
        vec3 an = abs(normal);
        bool axisAligned = max(an.x, max(an.y, an.z)) > 0.96;
        subsurfaceMode = axisAligned ? 2 : 1;
        noDirectionalShading = !axisAligned;
    }
#endif
#if AU_VOXELS
    AU_VoxFeed(playerPos, normal, albedo, subsurfaceMode != 0 || !hasSSAO, hasBloom, fract(dither * 7.31 + float(uHookFrame % 3600) * 0.137));
#endif

    // Emissive (lava, flames, crystals): brighter texels glow more.
    if (hasBloom) { emission = AU_EMISSION_STRENGTH * mix(0.5, 1.6, smoothstep(0.15, 0.9, GetLuminance(albedo))); shadow = 1.0; }
    // Block materials (the terrain pass looks them up per atlas tile) and glowing ores share
    // the meta bits: a material class means the level bits are the material's.
    uint matClass = hasBloom || subsurfaceMode != 0 ? 0u : AU_MaterialClass(gbuffer0.a);
    float matLevel = AU_MaterialLevel(gbuffer0.a);
    float oreGlowAmount = hasBloom || AU_MaterialClass(gbuffer0.a) != 0u ? 0.0 : AU_OreGlowLevel(gbuffer0.a);
    bool oreGlow = oreGlowAmount > 0.0;
    // Gloss of the material: polished stone, bricks and planks a sheen, ice and glass a mirror;
    // metals reflect in their own colour. Rain soaks everything open to the sky (tops most,
    // walls less): it all turns glossy, and porous blocks (soil, sand, gravel, stone) darken.
    float matSmooth = 0.0, metal = 0.0, wet = 0.0;
#if AU_MATERIALS
    // Only what really shines: smooth stone, marble, ice, glass (level 4+). Planks and bricks
    // (level 1) stay matte.
    if (matClass == 1u) matSmooth = matLevel < 0.5 ? 0.0 : mix(0.12, 0.92, matLevel);
    if (matClass == 2u) { matSmooth = mix(0.35, 0.85, matLevel); metal = 1.0; }
    matSmooth = min(matSmooth * AU_MATERIAL_GLOSS, 0.95);
    if (!hasBloom && subsurfaceMode == 0)
        wet = max(rainFactor, uHookWetness) * smoothstep(0.6, 0.9, skyLight) * mix(0.35, 1.0, max0(normal.y)) * AU_RAIN_WETNESS;
    if (matClass == 3u) albedo *= 1.0 - 0.4 * wet * (0.4 + 0.6 * matLevel);
    matSmooth = max(matSmooth, wet * (matClass == 3u ? 0.5 : 0.7));
#endif

    // Shadows of the volumetric clouds drifting over the land.
    shadow *= hasBloom ? 1.0 : GetCloudShadow(playerPos);
    if (IsCameraUnderwater > 0.5) {
        // Under water: sun light reaching surfaces comes through the waves (Unbound caustics)
        // and has lost its reds, like water-tinted translucent shadows.
#if AU_WATER_CAUSTICS
        if (!hasBloom) shadow *= mix(1.0, AU_CausticSunMult(playerPos + CameraPosition), 0.6);
#endif
        lightColor *= vec3(0.45, 0.75, 1.25);
    }

    vec3 rawStaticLight = blockLight;
    // Foliage (wind-animated) and emissive blocks use Hytale's flat shading: exposition 1.
    blockLight = (uint(round(gbuffer0.a * 255.0)) & AU_GBUFFER_PURE_GLOW) != 0u
               ? AU_GlowToBlockLight(blockLight, normal, hasBloom || !hasSSAO)
               : AU_ExtractBlockLight(blockLight, skyLight, normal, hasBloom || !hasSSAO);

    float aoUse = (hasSSAO || subsurfaceMode != 0) ? ao : 1.0;

#if AU_PRESET >= 2
    // RTX: the GI rays double as ray-traced ambient occlusion.
    float giVisibility = 1.0;
    vec3 gi = vec3(0.0);
    vec3 ptLight = vec3(0.0);
    if (!hasBloom) {
#if AU_VOXELS
        float skyVis;
        gi = AU_GetVoxelGI(uDepthTexture, playerPos, normal, skyLight, giVisibility, skyVis);
#if AU_PT_LIGHTS
        ptLight = AU_PTDirectLight(playerPos, normal, noDirectionalShading, GetDither2(gl_FragCoord.xy).y);
#endif
        AU_PTAccumulate(playerPos, gi, giVisibility, skyVis, ptLight);
        // Path-traced sky light: the ambient follows how much open sky the surface sees,
        // relative to an open field (a wall there sees half the sky, a floor all of it).
        // Hytale's flood-fill sky light already darkens rooms and caves, so the traced sky
        // light only adds what it misses where it counts as open (under steps, overhangs,
        // trees); applying both inside a room left it black.
        float ptSkyAmount = AU_PT_SKY_LIGHT * pow2(skyLight) * (subsurfaceMode != 0 ? 0.5 : 1.0);
        auPTSky = mix(1.0, clamp(skyVis / max(0.5 + 0.5 * normal.y, 0.15), 0.0, 1.0), ptSkyAmount);
#else
        gi = AU_GetSSGI(uDepthTexture, playerPos, normal, dither, giVisibility);
#endif
        // AO darkens indirect light; where the sun hits, direct light dominates.
        aoUse *= mix(1.0, giVisibility, AU_RTX_GI_AO * (1.0 - 0.75 * shadow));
    }
#endif
    float smoothnessG = 0.0, highlightMult = 1.0;
    if (subsurfaceMode == 2) {
        // Green leaves get a soft sheen.
        // Keyed on green dominance (Hytale has bright yellow/autumn leaves that would max it out).
        vec3 leafCol = albedo / max(AU_ALBEDO_MULT, 0.01);
        float factor = min1(pow2(max0(leafCol.g - max(leafCol.r, leafCol.b) * 0.9)) * 5.0) * 0.6;
        smoothnessG = factor * 0.4;
        float fresnelL = clamp(1.0 + dot(normal, normalize(playerPos)), 0.0, 1.0);
        highlightMult = (factor * 4.0 + 2.0) * (1.0 - pow2(pow2(fresnelL)));
    }
    // Ore crystals (the glowing texels of Hytale's REFLECTIVE blocks) are glossy like gems:
    // sharp sun glints here, reflections below.
    float crystal = smoothstep(0.0, 0.4, oreGlowAmount) * AU_ORE_GLOSS;
    // Glossy materials and wet surfaces: sun glints (metals' brighter).
    if (matSmooth > 0.0) {
        smoothnessG = max(smoothnessG, 0.85 * matSmooth);
        highlightMult = max(highlightMult, 1.0 + (2.0 + 2.0 * metal) * matSmooth);
    }
    if (crystal > 0.0) {
        smoothnessG = max(smoothnessG, 0.8 * crystal);
        highlightMult = max(highlightMult, 1.0 + 3.0 * crystal);
    }
    // Plain surfaces (grass, dirt, wood, stone): only a faint sun sheen - more read as plastic.
    if (matSmooth <= 0.0 && crystal <= 0.0 && subsurfaceMode == 0) highlightMult *= 0.25;
    vec3 litAlbedo = albedo;
#if AU_PRESET >= 2
    litAlbedo *= 1.0 - 0.45 * metal;
#endif
    vec3 color = AU_DoLighting(litAlbedo, normal, playerPos, skyLight, blockLight, shadow, aoUse,
                               subsurfaceMode, emission, smoothnessG, highlightMult, noDirectionalShading);
    // Cloth and other models Hytale lights from both sides (no "clean backfaces"): the sun behind
    // them comes through, in the pattern of whatever stands in between - at dawn a curtain shows
    // the window's lattice behind it, like in Hytale. The shadow mask keeps the sun for these
    // faces (DeferredShadowFS only darkens the back of solid blocks); a solid model's own body
    // shadows its far side in the shadow map.
    if (!useCleanShadowBackfaces && subsurfaceMode == 0 && !hasBloom && dot(normal, lightVec) < 0.0) {
        float back = -dot(normal, lightVec);
        color += litAlbedo * lightColor * (shadow * shadowTime * sunVisibility * mix(0.4, 1.0, back) * AU_CLOTH_TRANSMIT);
    }
    // Emissive texels (flames, potions, lava) look like Hytale's: texture colour times the
    // light stored with them (models keep their glow tint there), unshadowed - mapped through
    // the inverse of the tonemap so they come out in that colour instead of washing to white.
    // Their glow is the bloom (BloomSelectFS boosts them).
    // (Capped below 1: right at the top of the curve the inverse explodes, and the tonemap's
    // path to white and the bloom would wash the texel out again.)
    if (hasBloom) color = AU_InverseTonemap(pow(clamp(gbuffer0.rgb * rawStaticLight * (AU_EMISSION_STRENGTH / 3.0), 0.0, 0.92), vec3(2.2)));
    // Glowing ores: the glow lights the crystal evenly - the texture's dark/light contrast is
    // compressed (its colour kept) so it doesn't turn grainy - strongest on the facets facing
    // the camera, so the crystal keeps its shape - and keeps its hue: the brightest channel is
    // eased off softly.
    if (oreGlow) {
        float oreLum = max(GetLuminance(albedo), 0.002);
        float facing = clamp(-dot(normal, normalize(playerPos)), 0.0, 1.0);
        color += albedo * pow(oreLum, -0.5) * (AU_ORE_GLOW_STRENGTH * 0.5 * oreGlowAmount * mix(0.35, 1.0, facing * facing));
        float mx = max(color.r, max(color.g, color.b));
        const float knee = 1.0;
        if (mx > knee) {
            float room = AU_EMISSIVE_MAX - knee;
            color *= (knee + room * (1.0 - exp(-(mx - knee) / room))) / mx;
        }
    }

#if AU_PRESET >= 2
    // RTX preset: screen-space GI bounce + glossy reflections on solid surfaces.
    if (!hasBloom) {
#if AU_VOXELS
        color += albedo * gi * AU_PT_GI_STRENGTH;
#else
        color += albedo * gi * AU_RTX_GI_STRENGTH;
#endif
#if AU_VOXELS && AU_PT_LIGHTS
        color += albedo * ptLight * AU_PT_LIGHT_STRENGTH;
#endif

        vec3 nView = normalize(playerPos);
        float fresnel = clamp(1.0 + dot(normal, nView), 0.0, 1.0);
        // Faint grazing sheen on solids, plus wet surfaces facing up when it rains.
        float wetness = rainFactor * smoothstep(0.7, 0.95, normal.y) * smoothstep(0.6, 0.9, skyLight);
        float smoothness = subsurfaceMode != 0 ? 0.0 : mix(AU_RTX_SMOOTHNESS, 0.85, wetness);
        smoothness = max(smoothness, max(0.85 * crystal, matSmooth));
        // Dielectrics reflect a little head-on (gems a bit more); metals mostly reflect, in
        // their own colour.
        float f0 = max(0.06 * crystal, matSmooth > 0.0 ? 0.04 : 0.0);
        float fresnelM = (f0 + (1.0 - f0) * pow(fresnel, 5.0)) * smoothness;
        fresnelM = mix(fresnelM, smoothness * (0.6 + 0.4 * pow(fresnel, 5.0)), metal);
        if (fresnelM > 0.004) {
            vec3 rdir = reflect(nView, normal);
            vec3 skyRef = GetSky(rdir.y, dot(rdir, sunVec), dither, true, true) * pow2(skyLight);
            vec4 ssr = AU_GetSSR(uDepthTexture, playerPos, normal, 1.0 - smoothness, dither);
            vec3 refl = mix(skyRef, ssr.rgb, ssr.a) * mix(vec3(1.0), albedo * 1.7, metal);
            color = mix(color, refl, fresnelM);
        }
    }
#endif

#if AU_RAIN_PUDDLES
    // Rain puddles: blotchy puddles on open, upward faces while the world is
    // wet (uHookWetness lingers after the rain), rippling while it rains, mirror reflections.
    if (!hasBloom && subsurfaceMode == 0 && IsCameraUnderwater < 0.5) {
        float wetM = max(uHookWetness, rainFactor);
        float glow = max(blockLight.r, max(blockLight.g, blockLight.b)) * AU_BLOCKLIGHT_RANGE;
        float puddleMixer = smoothstep(0.93, 0.99, skyLight) * clamp((1.0 - 1.15 * glow) * 10.0, 0.0, 1.0)
                          * pow2(max0(normal.y - 0.5) * 2.0) * pow2(pow2(wetM));
        if (puddleMixer > 0.00001) {
            vec3 worldPos = playerPos + CameraPosition;
            vec2 puddlePosNormal = worldPos.xz * 0.1;
            vec2 puddlePosForm = puddlePosNormal * 0.05;
            float pFormNoise = textureLod(noisetex, puddlePosForm, 0.0).b * 3.0
                             + textureLod(noisetex, puddlePosForm * 0.5, 0.0).b * 5.0
                             + textureLod(noisetex, puddlePosForm * 0.25, 0.0).b * 8.0;
            pFormNoise *= sqrt1(wetM) * 0.5625 + 0.4375;
            puddleMixer *= clamp(pFormNoise - 7.0, 0.0, 1.0) * AU_RAIN_PUDDLE_STRENGTH;
            // Puddles are a close-up detail: far away at grazing angles they only read as pale
            // sky-coloured patches on the grass (snow-like), so fade them out with distance.
            puddleMixer *= 1.0 - smoothstep(40.0, 90.0, length(playerPos));

            vec2 puddleWind = vec2(uHookTime) * 0.03;
            vec3 pn1 = textureLod(noisetex, puddlePosNormal + puddleWind, 0.0).rgb;
            vec3 pn2 = textureLod(noisetex, puddlePosNormal + vec2(puddleWind.x * -1.5, puddleWind.y * -1.0), 0.0).rgb;
            vec2 pnXZ = (pn1.xy + pn2.xy - vec2(1.0)) * 0.03 * rainFactor;
            vec3 puddleNormal = normalize(vec3(pnXZ.x, 1.0, pnXZ.y));

            if (puddleMixer > 0.001) {
                vec3 nViewP = normalize(playerPos);
                float pFresnel = clamp(1.0 + dot(puddleNormal, nViewP), 0.0, 1.0);
                float pFresnelM = (pow2(pow2(pFresnel)) * 0.6 + 0.04) * puddleMixer;
                vec3 rdir = reflect(nViewP, puddleNormal);
                // The overcast rain sky is near white; reflected at full strength it turns grazing
                // puddles into a milky film, so the murky water dims it.
                vec3 skyRef = GetSky(rdir.y, dot(rdir, sunVec), dither, true, true) * pow2(skyLight) * 0.6;
                vec4 ssr = AU_GetSSR(uDepthTexture, playerPos, puddleNormal, 0.05, dither);
                color *= 1.0 - 0.35 * puddleMixer;   // wet ground is darker
                color = mix(color, mix(skyRef, ssr.rgb, ssr.a), pFresnelM);
            }
        }
    }
#endif

    DoAUFog(color, playerPos, dither, skyLight);
    color += AU_GetRainbow(playerPos / max(length(playerPos), 0.0001), length(playerPos), false, dither);

    // Volumetric light shafts in front of this surface.
    float lViewPos = length(playerPos);
    color = AU_AddVL(color, GetVolumetricLight(playerPos / max(lViewPos, 0.0001), lViewPos, false, dither));

#if AU_DEBUG_CLASS == 1
    color = vec3(hasBloom ? 1.0 : 0.0, subsurfaceMode != 0 ? 1.0 : 0.0, hasSSAO ? 0.6 : 0.0) * 0.5 + shadow * 0.15;
#elif AU_DEBUG_CLASS == 2
    color = vec3(shadow);
#elif AU_DEBUG_CLASS == 3
    // red: sun visibility, green: sky light (gamma-encoded for reading)
    color = sqrt(vec3(shadow, skyLight, 0.0)) * 0.6;
#elif AU_DEBUG_CLASS == 6
    color = vec3(GetEyeBrightness());
#elif AU_DEBUG_CLASS == 7
    color = sqrt(GetVolumetricLight(playerPos / max(lViewPos, 0.0001), lViewPos, false, dither) * 3.0);
#elif AU_DEBUG_CLASS == 8
    // Materials: red polished, white metal, blue porous (brighter = higher level); green ore glow.
    color = (matClass == 1u ? vec3(1.0, 0.1, 0.1) : matClass == 2u ? vec3(1.0) : matClass == 3u ? vec3(0.1, 0.3, 1.0) : vec3(0.0))
          * (0.3 + 0.7 * matLevel) + vec3(0.0, oreGlowAmount, 0.0);
#elif AU_DEBUG_CLASS == 4
    color = fragTexCoords.x < 0.5 ? rawStaticLight : blockLight;
#endif
#if AU_VOXELS && (AU_VOXEL_DEBUG == 1 || AU_VOXEL_DEBUG == 2)
    {
        // Voxel grid debug: what the path tracer sees, cast from the camera. Magenta = block
        // never seen on screen (no colour yet), green tint = leaves, blue tint = small model.
        ivec3 hb; vec3 hn; float ht; uint hv;
        vec3 dbg = vec3(0.02, 0.03, 0.08);
        if (AU_VoxTrace(CameraPosition, normalize(playerPos), 250.0, 512, 0.99, hb, hn, ht, hv)) {
            vec4 vc = AU_VoxGetColor(hb);
            vec3 base = vc.a > 0.5 ? vc.rgb : vec3(0.9, 0.1, 0.9);
            if ((hv & 3u) == AU_VOX_POROUS) base *= vec3(0.5, 1.0, 0.5);
            if ((hv & AU_VOX_SMALL) != 0u) base *= vec3(0.5, 0.6, 1.0);
            dbg = base * (0.3 + 0.7 * max(dot(hn, sunVec), 0.0) + 0.15 * hn.y) * 2.0;
        }
        color = AU_VOXEL_DEBUG == 1 ? dbg : mix(color, dbg, 0.5);
    }
#endif
#if AU_VOXELS && AU_PT_LIGHTS && AU_VOXEL_DEBUG == 3
    {
        // Light list probe: red = empty, green brighter with more lights.
        uint nl = imageLoad(auLights, ivec2(0, uHookFrame & 1)).r;
        color = mix(color, nl == 0u ? vec3(1.0, 0.0, 0.0) : vec3(0.0, min(float(nl) / 8.0, 1.0), 0.0), 0.5);
    }
#elif AU_VOXELS && AU_PT_LIGHTS && AU_VOXEL_DEBUG == 4
    color = sqrt(ptLight) * 0.7;   // traced torch light only
#elif AU_VOXELS && AU_VOXEL_DEBUG == 6
    color = sqrt(gi * AU_RTX_GI_STRENGTH) * 0.8;   // incoming bounce light only (before the surface colour)
#elif AU_VOXELS && AU_PT_LIGHTS && AU_VOXEL_DEBUG == 5
    {
        // Distance to the nearest listed light: rings every 2 blocks, red beyond 32.
        int row = uHookFrame & 1;
        uint nl = min(imageLoad(auLights, ivec2(0, row)).r, 64u);
        ivec3 base = ivec3(floor(CameraPosition)) - AU_VOX_HALF;
        float md = 1e9;
        for (uint k = 0u; k < nl; k++) {
            uint c = imageLoad(auLights, ivec2(1 + 2 * int(k), row)).r;
            ivec3 lb = base + ((ivec3(c & 255u, (c >> 8) & 127u, (c >> 15) & 255u) - base) & AU_VOX_MASK);
            md = min(md, distance(vec3(lb) + 0.5, playerPos + CameraPosition));
        }
        color = md > 32.0 ? vec3(0.5, 0.0, 0.0) : vec3(fract(md * 0.5), 1.0 - md / 32.0, 0.2);
    }
#endif
    // Meta for the bloom pass: 1 SSAO, 2 emissive, bits 2-4 ore glow level.
    uint oreLevel = uint(round(oreGlowAmount * 7.0));
    outColor = vec4(color, float((hasSSAO ? 1u : 0u) | (hasBloom ? 2u : 0u) | (oreLevel << 2)) / 255.0);
}
