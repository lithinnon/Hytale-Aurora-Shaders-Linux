#version 410 core

// Aurora Shaders for Hytale - temporal anti-aliasing / accumulation.
// Hytale's TAA blends 50% of the previous frame at the same pixel, without reprojection, so the
// per-frame dithered effects (light shafts, soft shadows, GI) stay grainy and motion smears.
// This reprojects the history with the camera motion (Hytale's ReprojectionMatrix + linear
// depth), samples it with a sharp Catmull-Rom filter, clips it to the current neighbourhood in
// YCoCg (variance clipping) and accumulates ~10 frames, like modern TAA.

#include "SceneData_inc.glsl"
#include "Reconstruction_inc.glsl"
#include "AU_Settings.glsl"

uniform sampler2D uColorTexture;
uniform sampler2D uPreviousColorTexture;
uniform vec2 uPixelSize;
uniform int uNeighborHoodCheck;
uniform sampler2D uHookDepth;   // DeferredFS linear depth (0..1 of the far plane), shared by the hook

in vec2 fragTexCoords;

out vec4 outColor;

vec3 RGBToYCoCg(vec3 c)
{
    return vec3(dot(c, vec3(0.25, 0.5, 0.25)), dot(c, vec3(0.5, 0.0, -0.5)), dot(c, vec3(-0.25, 0.5, -0.25)));
}

vec3 YCoCgToRGB(vec3 c)
{
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// 5-tap Catmull-Rom (bicubic) history fetch: keeps the accumulated image sharp under motion.
vec3 SampleHistory(vec2 uv)
{
    vec2 texSize = 1.0 / uPixelSize;
    vec2 samplePos = uv * texSize;
    vec2 texPos1 = floor(samplePos - 0.5) + 0.5;
    vec2 f = samplePos - texPos1;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 texPos0 = (texPos1 - 1.0) * uPixelSize;
    vec2 texPos3 = (texPos1 + 2.0) * uPixelSize;
    vec2 texPos12 = (texPos1 + w2 / w12) * uPixelSize;
    float wA = w12.x * w0.y, wB = w0.x * w12.y, wC = w12.x * w12.y, wD = w3.x * w12.y, wE = w12.x * w3.y;
    vec3 r = texture(uPreviousColorTexture, vec2(texPos12.x, texPos0.y)).rgb * wA
           + texture(uPreviousColorTexture, vec2(texPos0.x, texPos12.y)).rgb * wB
           + texture(uPreviousColorTexture, vec2(texPos12.x, texPos12.y)).rgb * wC
           + texture(uPreviousColorTexture, vec2(texPos3.x, texPos12.y)).rgb * wD
           + texture(uPreviousColorTexture, vec2(texPos12.x, texPos3.y)).rgb * wE;
    return max(r / (wA + wB + wC + wD + wE), vec3(0.0));
}

void main()
{
    vec2 uv = fragTexCoords;
    vec4 current = texture(uColorTexture, uv);

#if AU_DLSS
    // DLSS (fed by PostEffectFS) replaces the anti-aliasing: pass the frame through.
    if (uNeighborHoodCheck < -1000) current.r += texture(uPreviousColorTexture, uv).r + texture(uHookDepth, uv).r;   // keep the game's uniforms referenced
    outColor = current;
    return;
#endif

#if AU_TAA
    // Reproject: this pixel's view-space position -> previous frame's screen position.
    float lin = min(texture(uHookDepth, uv).r, 1.0);
    vec3 posVS = PositionFromLinearDepth(uv, -lin * FarClip, ProjInfos);
    vec4 prevClip = ReprojectionMatrix * vec4(posVS, 1.0);
    vec4 curClip = ProjectionMatrix * vec4(posVS, 1.0);
    // Motion = previous minus current projection of the same point, so the depth
    // reconstruction's mismatch with Hytale's projection cancels out.
    vec2 prevUV = uv + (prevClip.xy / prevClip.w - curClip.xy / curClip.w) * 0.5;
    bool offscreen = any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)));

    // Neighbourhood statistics (3x3) for variance clipping.
    vec3 cur = RGBToYCoCg(current.rgb);
    vec3 m1 = vec3(0.0), m2 = vec3(0.0);
    vec3 nMin = vec3(1e9), nMax = vec3(-1e9);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec3 c = RGBToYCoCg(texture(uColorTexture, uv + vec2(x, y) * uPixelSize).rgb);
            m1 += c;
            m2 += c * c;
            nMin = min(nMin, c);
            nMax = max(nMax, c);
        }
    }
    m1 /= 9.0;
    vec3 sigma = sqrt(max(m2 / 9.0 - m1 * m1, vec3(0.0)));
    vec3 boxMin = max(nMin, m1 - AU_TAA_CLIP * sigma);
    vec3 boxMax = min(nMax, m1 + AU_TAA_CLIP * sigma);

    vec3 history = RGBToYCoCg(SampleHistory(prevUV));
    history = clamp(history, boxMin, boxMax);

    // Less history while moving fast (fresh detail), none for pixels coming from off-screen.
    float motion = length((prevUV - uv) / uPixelSize);
    float blend = offscreen ? 0.0 : mix(AU_TAA_BLEND, 0.7, clamp(motion / 40.0, 0.0, 1.0));
    if (uNeighborHoodCheck < -1000) blend = 0.0;   // keep the game's uniform referenced

    outColor = vec4(max(YCoCgToRGB(mix(cur, history, blend)), vec3(0.0)), current.a);
#if AU_DEBUG_TAA
    outColor.rgb = vec3(blend, clamp(motion / 40.0, 0.0, 1.0), offscreen ? 1.0 : lin);
#endif
#else
    // Hytale's original.
    vec4 previousColor = texture(uPreviousColorTexture, uv);
    if (1 == uNeighborHoodCheck) {
        vec4 nMin = current, nMax = current;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec4 n = texture(uColorTexture, uv + vec2(x, y) * uPixelSize);
                nMin = min(nMin, n);
                nMax = max(nMax, n);
            }
        }
        previousColor = clamp(previousColor, nMin, nMax);
    }
    outColor = mix(current, previousColor, 0.5);
#endif
}
