#version 410 core

// Aurora Shaders for Hytale - deferred sun shadows.
// Writes raw sun visibility (1 = lit, 0 = shadowed) with soft Vogel-disk PCF, instead of
// Hytale's intensity-remapped value. The SSAO pass temporally filters this mask.

#include "SceneData_inc.glsl"
#include "Reconstruction_inc.glsl"
#include "Deferred_inc.glsl"
#include "AU_Settings.glsl"

#ifndef CASCADE_COUNT
#define CASCADE_COUNT 4
#endif

uniform sampler2DShadow uShadowMap;
#if AU_PCSS
uniform sampler2D uHookShadowDepth;   // same shadow atlas, raw depth (hook sampler, no compare)
#endif
uniform sampler2D uDepthTexture;
#if USE_NORMAL_BIAS || USE_CLEAN_BACKFACES
uniform sampler2D uGBuffer1Texture;
#endif
uniform int uHookFrame;

in vec3 fragFrustumRay;
in vec2 fragTexCoords;

out vec4 outColor;

uniform sampler2D blueNoiseTex;   // hook-loaded blue noise (see AU_Common GetDither)

// Blue-noise value per pixel, stepped by the golden ratio each frame (channel c of the texture).
float BlueNoise(vec2 p, int c)
{
    return fract(texelFetch(blueNoiseTex, ivec2(p) & 127, 0)[c] + 0.618034 * float(uHookFrame % 3600));
}

int getCascade(vec3 positionFromCameraWS, vec3 normalWS, out vec4 positionLS)
{
    for (int c = 0; c < CASCADE_COUNT; c++) {
        float normalBias = clamp(0.0175 / SunShadowCascadeStats[c].y, 0.075, 0.35);
        positionLS = SunShadowMatrix[c] * vec4(normalWS * normalBias + positionFromCameraWS + SunShadowCascadeCachedTranslations[c].xyz, 1.0);
        vec3 limit = c == CASCADE_COUNT - 1 ? vec3(1.0) : vec3(0.999);
        if (all(lessThanEqual(abs(positionLS.xyz), limit))) return c;
    }
    return -1;
}

// Screen-space contact shadow: march towards the sun through the depth buffer. Catches the
// grass, plants and small props that Hytale leaves out of its shadow map.
// planeN: the surface's real orientation (from the depth buffer). Hits on that plane are the
// surface itself: seen at an angle, the ray just in front of it projects onto pixels where the
// same surface is nearer the camera, and it shadowed itself (the patch of sun a window across
// the room puts on a curtain was blacked out).
float ContactShadow(vec3 pos, vec3 normalWS, vec3 planeN, vec3 toSun, float dither)
{
    float lView = length(pos);
    // Grows with distance so far trees still shadow themselves and the ground beyond the
    // shadow cascades.
    float maxDist = AU_CONTACT_SHADOW_LENGTH * (1.0 + lView * 0.03) + max(lView - 48.0, 0.0) * 0.06;
    const int steps = AU_CONTACT_SHADOW_STEPS;
    vec3 start = pos + normalWS * (0.02 + lView * 0.0015) + toSun * 0.02;
    for (int i = 0; i < steps; i++) {
        float t = maxDist * pow((float(i) + dither) / float(steps), 1.4);
        vec3 p = start + toSun * t;
        vec4 clip = ViewProjectionMatrix * vec4(p, 1.0);
        vec3 ndc = clip.xyz / clip.w;
        vec2 uv = ndc.xy * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;
        float sceneZ = texture(uDepthTexture, uv).r;
        float rayZ = ndc.z * 0.5 + 0.5;
        if (rayZ > sceneZ && sceneZ < 1.0) {
            float linS = GetLinearDepthFromDepthHW(sceneZ, ProjectionMatrix);
            float linR = GetLinearDepthFromDepthHW(rayZ, ProjectionMatrix);
            float diff = linR - linS;
            float thickness = 0.2 + t * 0.35 + lView * 0.004;
            // The occluding point the depth buffer shows at this pixel (same view ray, nearer).
            vec3 occ = p * (linS / max(linR, 0.0001));
            bool ownPlane = abs(dot(occ - pos, planeN)) < 0.04 + lView * 0.002;
            // The first-person hand / held item is in the depth buffer: never an occluder.
            if (linS > AU_NEAR_IGNORE && diff > 0.005 && diff < thickness && !ownPlane) return 0.0;
        }
    }
    return 1.0;
}

// Distant-terrain shadows: beyond
// the shadow map, trace towards the sun through the depth buffer in big steps so distant
// trees and hills still shade themselves and the ground behind them.
float FarShadow(vec3 pos, vec3 toSun, float dither, bool foliage)
{
    float lView = length(pos);
    float shadow = 1.0;
    float stepLen = 2.5 * max(1.0, lView / 400.0);
    vec3 traceStep = toSun * stepLen;
    vec3 tracePos = pos + traceStep * (dither + 0.2);
    if (!foliage) tracePos -= pos / max(lView, 0.001) * 1.5;   // imitates shadow bias
    float thickness = stepLen * 2.0;
    for (int i = 0; i < AU_FAR_SHADOW_STEPS; i++) {
        vec4 clip = ViewProjectionMatrix * vec4(tracePos, 1.0);
        vec3 ndc = clip.xyz / clip.w;
        vec2 uv = ndc.xy * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;
        float sceneZ = texture(uDepthTexture, uv).r;
        if (sceneZ < 1.0) {
            float zDelta = GetLinearDepthFromDepthHW(ndc.z * 0.5 + 0.5, ProjectionMatrix)
                         - GetLinearDepthFromDepthHW(sceneZ, ProjectionMatrix);
            shadow *= 1.0 - smoothstep(0.0, 0.01, zDelta) * smoothstep(thickness, thickness * 0.8, zDelta);
        }
        tracePos += traceStep;
    }
    return shadow;
}

void main()
{
    float depth = texture(uDepthTexture, fragTexCoords).r;
    if (depth >= 1.0) discard;

#if USE_LINEAR_Z
    vec3 positionFromCameraWS = fragFrustumRay * depth;
#else
    vec3 positionFromCameraWS = PositionFromDepth(depth, fragTexCoords, InvViewProjectionMatrix);
#endif

    vec3 normalWS = vec3(0.0, 1.0, 0.0);
    bool useCleanShadowBackfaces = false;
    bool hasBloom = false, hasSSAO = true;
#if USE_NORMAL_BIAS || USE_CLEAN_BACKFACES
    vec3 tex = texture(uGBuffer1Texture, fragTexCoords).rga;
    normalWS = decodeNormal(tex.rg);
    // The render flags moved to the albedo target (not bound here); this target's alpha
    // carries only the clean-backface flag, which is off exactly for foliage.
    useCleanShadowBackfaces = tex.b > 0.5;
    hasSSAO = useCleanShadowBackfaces;
#endif
#if !USE_NORMAL_BIAS
    vec3 biasNormal = vec3(0.0);
#else
    vec3 biasNormal = normalWS;
#endif

    vec3 lightDir = normalize(vec3(SunShadowMatrix[0][0][2], SunShadowMatrix[0][1][2], SunShadowMatrix[0][2][2]));
    positionFromCameraWS -= lightDir * 0.1;

    vec3 positionNoBias = positionFromCameraWS + lightDir * 0.1;
    float lView = length(positionNoBias);
    float farCascade = max(SunShadowCascadeStats[CASCADE_COUNT - 1].x, 1.0);
    vec4 positionLS;
    int cascade = getCascade(positionFromCameraWS, biasNormal, positionLS);
    float visibility = 1.0;
    bool backLit = false;   // a face turned away from the sun
    if (cascade >= 0) {

    vec3 uvw = positionLS.xyz * 0.5 + 0.5;
    const float cascadeScale = 1.0 / float(CASCADE_COUNT);
    uvw.x = uvw.x * cascadeScale + cascadeScale * float(cascade);

    // Soft shadows: Vogel disk, rotated per pixel and per frame (resolved by temporal filtering).
    vec2 texel = 1.0 / vec2(textureSize(uShadowMap, 0));
    float radius = 2.2 * AU_SHADOW_SOFTNESS / (1.0 + 0.6 * float(cascade));
    float rot = 6.2831853 * BlueNoise(gl_FragCoord.xy, 1);
    float cascadeMinX = cascadeScale * float(cascade) + texel.x * 2.0;
    float cascadeMaxX = cascadeScale * float(cascade + 1) - texel.x * 2.0;

    float blockerFrac = 0.0;
#if AU_PCSS
    // Contact-hardening shadows: average blocker depth -> penumbra width.
    {
        float blockerSum = 0.0;
        float blockers = 0.0;
        float searchR = AU_PCSS_SEARCH / (1.0 + 0.6 * float(cascade));
        for (int i = 0; i < 10; i++) {
            float r = sqrt((float(i) + 0.5) / 10.0);
            float a = float(i) * 2.39996323 + rot + 1.3;
            vec2 o = vec2(cos(a), sin(a)) * r * searchR * texel;
            vec2 suv = vec2(clamp(uvw.x + o.x, cascadeMinX, cascadeMaxX), uvw.y + o.y);
            float d = texture(uHookShadowDepth, suv).r;
            if (d < uvw.z - 0.0003) { blockerSum += d; blockers += 1.0; }
        }
        blockerFrac = blockers / 10.0;
        if (blockers > 0.0) {
            float dz = uvw.z - blockerSum / blockers;
            float scale = 1.0 / (1.0 + 1.5 * float(cascade));
            radius = clamp(dz * AU_PCSS_SCALE * scale, 0.6, AU_PCSS_SEARCH) * AU_SHADOW_SOFTNESS;
        } else {
            radius = 0.6;
        }
    }
#endif
    visibility = 0.0;
    for (int i = 0; i < AU_SHADOW_SAMPLES; i++) {
        float r = sqrt((float(i) + 0.5) / float(AU_SHADOW_SAMPLES));
        float a = float(i) * 2.39996323 + rot;
        vec2 o = vec2(cos(a), sin(a)) * r * radius * texel;
        vec2 suv = vec2(clamp(uvw.x + o.x, cascadeMinX, cascadeMaxX), uvw.y + o.y);
        visibility += texture(uShadowMap, vec3(suv, uvw.z - 0.0001));
    }
    visibility /= float(AU_SHADOW_SAMPLES);
    // Nearly every blocker-search sample occluded: the point is deep in shadow. A wide penumbra
    // (from a far blocker) would otherwise smear a one-texel corner leak into a lit band.
    visibility = min(visibility, 1.0 - smoothstep(0.75, 0.95, blockerFrac));

#if USE_CLEAN_BACKFACES
    // Faces turned away from the sun are dark; the lighting's N.L handles the gradient.
    float nDotL = dot(normalWS, lightDir);
    backLit = useCleanShadowBackfaces && nDotL >= 0.0;
    if (backLit) visibility = 0.0;
    // Sun at a grazing angle on a block face: the shadow map can't resolve it - each cascade
    // refit shifts the lit sliver along the wall (a sun streak through a roof gap that slid
    // around as the camera moved) - and the real light there is tiny. Fade it out, measured
    // on the block face rather than the bumpy generated normal.
    if (useCleanShadowBackfaces) {
        vec3 an = abs(normalWS);
        vec3 faceN = an.y >= max(an.x, an.z) ? vec3(0.0, sign(normalWS.y), 0.0)
                   : (an.z >= an.x ? vec3(0.0, 0.0, sign(normalWS.z)) : vec3(sign(normalWS.x), 0.0, 0.0));
        visibility *= smoothstep(0.1, 0.16, -dot(faceN, lightDir));
    }
#endif

    // Fade out at the edge of the last cascade - only out where the shadow range ends; nearby
    // points can land in the last cascade too, and fading them lit drew moving light strips.
    if (cascade == CASCADE_COUNT - 1 && lView > farCascade * 0.6) {
        float border = pow(length(positionLS.xy), 20.0);
        visibility = max(visibility, border);
    }
    } // cascade >= 0

    float dither = BlueNoise(gl_FragCoord.xy, 2);
    // A nearby point outside every cascade: Hytale fits the cascades tightly to the view, so
    // this happens toward the screen edges. Trace the depth buffer instead of calling it lit,
    // which showed as sunlit strips that moved with the camera.
    if (cascade < 0 && lView < farCascade * 0.8)
        visibility = FarShadow(positionNoBias, -lightDir, dither, !hasSSAO && !hasBloom);
#if AU_CONTACT_SHADOWS
    float contactDist = min(AU_CONTACT_SHADOW_DISTANCE, farCascade);
    vec3 planeN = fastNormalFromPosition(positionNoBias);   // screen derivatives: outside the branch
    if (visibility > 0.01 && lView < contactDist && !backLit) {
        float contact = ContactShadow(positionNoBias, normalWS, planeN, -lightDir, dither);
        float fade = smoothstep(contactDist * 0.8, contactDist, lView);
        visibility = min(visibility, mix(contact, 1.0, fade));
    }
#endif

    // Past the cascades: distant-terrain screen-space shadows.
    float farW = smoothstep(0.8, 0.97, lView / farCascade);
#if AU_FAR_SHADOWS
    if (farW > 0.0) {
        float farVis = FarShadow(positionNoBias, -lightDir, dither, !hasSSAO && !hasBloom);
        visibility = mix(visibility, farVis, farW);
    }
#else
    visibility = max(visibility, farW);
#endif

#ifdef AU_DEBUG_SHADOWMAP
    // Left third: compare against ref 0. Middle: ref 1. Right: raw depth (hook sampler).
    {
        vec2 uvA = fragTexCoords;
        float v;
        if (uvA.x < 0.333) v = texture(uShadowMap, vec3(uvA.x * 3.0, uvA.y, 0.0));
        else if (uvA.x < 0.666) v = texture(uShadowMap, vec3(uvA.x * 3.0 - 1.0, uvA.y, 1.0));
        else v = texture(uHookShadowDepth, vec2(uvA.x * 3.0 - 2.0, uvA.y)).r;
        outColor = vec4(v);
        return;
    }
#endif
    if (visibility >= 0.995) discard;
    outColor = vec4(visibility);
}
