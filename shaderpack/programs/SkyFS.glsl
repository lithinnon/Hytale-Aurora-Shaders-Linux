#version 410 core

// Aurora Shaders for Hytale - sky.
// Procedural sky (gradient, sunset, glare), stars and light shafts.

#include "SceneData_inc.glsl"
#include "Fog_inc.glsl"
#include "AU_Sky.glsl"
#include "AU_VL.glsl"
#include "AU_Rainbow.glsl"

uniform sampler2D uStarsTexture;
uniform float uStarsOpacity;
uniform vec3 uSunPosition;
uniform float uSunScale;
uniform vec4 uSunGlowColor;
uniform float uMoonOpacity;
uniform float uMoonScale;
uniform vec4 uMoonGlowColor;
uniform vec3 uFogBackColor;
uniform vec4 uDrawSkySunMoonStars;

in vec3 fragSpherePosition;
in vec2 fragTexCoords;
in vec4 fragBackgroundSunsetColor;
#if USE_MOOD_FOG
in vec4 fragFogInfo;
#endif

layout (location = 0) out vec4 outColor;

vec3 GetViewDirWS()
{
    vec2 ndc = gl_FragCoord.xy * InvViewportSize * 2.0 - 1.0;
    vec4 p = InvViewProjectionMatrix * vec4(ndc, 1.0, 1.0);
    return normalize(p.xyz / p.w);
}

#if AU_STARS == 2
// Hytale's star texture (dense stars and the milky way) carried by a celestial sphere that turns
// with the sun: the stars keep their place relative to the sun, so through the night they rise
// in the east and set in the west around a pole low in the sky, like the real thing.
// Hytale's sun crosses the horizon at +-x and leans toward +z at noon (max elevation ~67 deg),
// so the turning axis is perpendicular to x and to the sun, ~23 deg above the -z horizon.
vec3 GetHytaleStars(vec3 dir)
{
    if (dir.y <= 0.0 || 1.0 != uDrawSkySunMoonStars.w) return vec3(0.0);
    vec2 yz = vec2(-sunVec.z, sunVec.y);
    vec3 axis = dot(yz, yz) > 0.0025 ? normalize(vec3(0.0, yz)) : vec3(0.0, 0.392, -0.92);
    if (axis.y < 0.0) axis = -axis;
    vec3 e1 = normalize(sunVec - axis * dot(sunVec, axis));
    vec3 e2 = cross(axis, e1);
    vec3 c = vec3(dot(dir, e1), dot(dir, e2), dot(dir, axis));

    const float invTau = 0.15915494, invPi = 0.31830989;
    float lon = atan(c.y, c.x) * invTau + 0.5;
    float lat = acos(clamp(c.z, -1.0, 1.0)) * invPi;
    vec2 scale = vec2(8.0, 4.0) * AU_STARS_SCALE;   // square texels on the celestial equator
    vec2 uv = vec2(lon, lat) * scale;
    // Mip selection across the longitude seam: take the derivatives of whichever of the two
    // seam placements is continuous here.
    vec2 uvAlt = vec2(fract(lon + 0.5), lat) * scale;
    vec2 dx = dFdx(uv), dy = dFdy(uv), dxA = dFdx(uvAlt), dyA = dFdy(uvAlt);
    if (dot(dxA, dxA) + dot(dyA, dyA) < dot(dx, dx) + dot(dy, dy)) { dx = dxA; dy = dyA; }
    vec4 starsTexel = textureGrad(uStarsTexture, uv, dx, dy);
    // Around the celestial poles that longitude/latitude mapping squeezes the texture into
    // streaks converging on the pole; blend to a planar (stereographic) projection there,
    // scaled to the same star size (texels per radian) as the equator.
    vec2 uvP = c.xy / (1.0 + abs(c.z)) * (2.546 * AU_STARS_SCALE) + (c.z < 0.0 ? vec2(0.37, 0.61) : vec2(0.0));
    vec4 starsPolar = textureGrad(uStarsTexture, uvP, dFdx(uvP), dFdy(uvP));
    starsTexel = mix(starsTexel, starsPolar, smoothstep(0.72, 0.9, abs(c.z)));

    // Hytale's visibility: night level, fade toward the horizon, the game's star opacity.
    float nightLevel = clamp(-sunVec.y * 1.5, 0.0, 1.0);
    float vis = nightLevel * clamp(dir.y * 5.0, 0.0, 1.0) * min(abs(dir.y) * 1.5, 1.0)
              * uStarsOpacity * starsTexel.a * invRainFactor;
    return starsTexel.rgb * min(vis, 1.0) * AU_STARS_BRIGHTNESS;
}
#endif

void main()
{
    AU_InitCommon();
    // Keep every vertex input active: the game looks up vertTexCoords and fails if it is
    // optimised away.
    if (fragTexCoords.x < -1.0e9 || fragSpherePosition.x < -1.0e9) discard;

    if (0.0 == uDrawSkySunMoonStars.x) {
        outColor = vec4(uFogBackColor, 1.0);
        return;
    }

    vec3 dir = GetViewDirWS();
    float VdotU = dir.y;
    float VdotS = dot(dir, sunVec);
    float dither = GetDither(gl_FragCoord.xy);

    vec3 sky = GetSky(VdotU, VdotS, dither, true, false);

#if AU_STARS == 2
    sky += GetHytaleStars(dir);
#elif AU_STARS
    if (1.0 == uDrawSkySunMoonStars.w) sky += GetStars(dir, VdotU, VdotS);
#endif

    // Hytale's moon glow: the halo around the moon, in the colour the game sets for it.
    if (1.0 == uDrawSkySunMoonStars.z && AU_MOON_GLOW > 0.0) {
        float dm = min(distance(fragSpherePosition, -uSunPosition) / (uMoonScale * 0.4), 0.99);
        // (Not behind the disc itself: the moon is drawn over the sky and washed out.)
        float glow = (1.0 - clamp(sin(dm * 1.5707963), 0.0, 1.0)) * smoothstep(0.15, 0.4, dm);
        sky = mix(sky, uMoonGlowColor.rgb, clamp(uMoonGlowColor.a * glow * uMoonOpacity * AU_MOON_GLOW, 0.0, 1.0));
    }

    sky += AU_GetRainbow(dir, 100000.0, true, dither);
    sky = AU_AddVL(sky, GetVolumetricLight(dir, 100000.0, true, dither));
    // Sky seen from inside a cave (openings, or chunks the game culled): cave fog.
    // Only when deep inside (openings, or chunks the game culled), not while stepping out.
    DoCaveFog(sky, 100000.0, smoothstep(0.1, 0.35, GetEyeBrightness()));

    outColor = vec4(sky, 1.0);
}
