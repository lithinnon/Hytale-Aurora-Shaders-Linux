// Aurora Shaders for Hytale: forward pass (water + translucent blocks)
#include "AU_Settings.glsl"
uniform sampler2DArray uHookMaterials;   // per-tile block materials (hook.c materials_build)
#if !DEFERRED && !USE_SCENE_DATA_OVERRIDE
#define AU_FORWARD 1
#include "AU_Lighting.glsl"
#include "AU_Tonemap.glsl"
#include "AU_Fog.glsl"
#include "AU_Shadow.glsl"
#include "AU_VL.glsl"
#ifndef AU_HAS_CLOUDWATER
#define AU_HAS_CLOUDWATER
uniform sampler2D cloudWaterTex;
#endif
#include "AU_Caustics.glsl"
uniform sampler2D noisetex;

// Screen-space reflection for water: view-space march against Hytale's linear depth with a
// binary refinement, so reflections stay crisp. Rays that leave the
// geometry and point at on-screen sky reflect the real sky (clouds, sun) from the scene.
// Returns rgb + confidence.
vec4 AU_WaterSSR(sampler2D depthTex, sampler2D sceneTex, vec3 posVS, vec3 dirVS, float farClip, float dither)
{
    float lView = length(posVS);
    float stepLen = 0.2 + lView * 0.015;
    vec3 prevP = posVS;
    vec3 p = posVS + dirVS * stepLen * dither;
    for (int i = 0; i < AU_WATER_SSR_STEPS; i++) {
        prevP = p;
        p += dirVS * stepLen;
        stepLen *= 1.1;
        vec4 clip = ProjectionMatrix * vec4(p, 1.0);
        if (clip.w <= 0.0) break;
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;
        float sceneLin = texture(depthTex, uv).r * farClip;
        if (sceneLin >= farClip * 0.995) continue;
        float rayLin = -p.z;
        if (rayLin > sceneLin) {
            // Far behind that surface: the ray passed behind something in front (a tree
            // between the camera and the reflected spot). Keep going - giving up here showed the
            // sky fallback in a patch under the tree that slid around as the camera moved.
            if (rayLin - sceneLin > stepLen * 2.0 + 0.6) continue;
            vec3 a = prevP, b = p;
            for (int k = 0; k < 6; k++) {
                vec3 m = (a + b) * 0.5;
                vec4 cm = ProjectionMatrix * vec4(m, 1.0);
                vec2 um = cm.xy / cm.w * 0.5 + 0.5;
                if (-m.z > texture(depthTex, um).r * farClip) b = m; else a = m;
            }
            vec4 cb = ProjectionMatrix * vec4(b, 1.0);
            vec2 ub = cb.xy / cb.w * 0.5 + 0.5;
            vec2 e = abs(ub - 0.5) * 2.0;
            float fade = 1.0 - pow(max(e.x, e.y), 8.0);
            return vec4(textureLod(sceneTex, ub, 0.0).rgb, fade);
        }
    }
    // No geometry hit: reflect the real sky where the ray's far end lands on screen.
    vec4 cf = ProjectionMatrix * vec4(posVS + dirVS * 3000.0, 1.0);
    if (cf.w > 0.0) {
        vec2 uf = cf.xy / cf.w * 0.5 + 0.5;
        if (all(greaterThanEqual(uf, vec2(0.0))) && all(lessThanEqual(uf, vec2(1.0)))
            && texture(depthTex, uf).r * farClip >= farClip * 0.995) {
            vec2 e = abs(uf - 0.5) * 2.0;
            float fade = 1.0 - pow(max(e.x, e.y), 6.0);
            return vec4(textureLod(sceneTex, uf, 0.0).rgb, fade);
        }
    }
    return vec4(0.0);
}
#else
#define AU_FORWARD 0
#endif
