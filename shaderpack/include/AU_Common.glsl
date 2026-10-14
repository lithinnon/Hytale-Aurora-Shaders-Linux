// Aurora Shaders for Hytale - common state.
// Time of day, weather, sky colours and light / ambient colours shared by every pass.
// Requires SceneData_inc.glsl. Call AU_InitCommon() at the top of main().

#ifndef AU_COMMON
#define AU_COMMON

#include "AU_Settings.glsl"

// ---- Helpers -------------------------------------------------------------------------
#ifndef AU_HAS_POW2
#define AU_HAS_POW2
float pow2(float x) { return x * x; }
#endif
vec2 pow2(vec2 x) { return x * x; }
vec3 pow2(vec3 x) { return x * x; }
vec4 pow2(vec4 x) { return x * x; }
float pow1_5(float x) { return x * sqrt(x); }
float auPow3(float x) { return x * x * x; }
float sqrt1(float x) { return sqrt(max(x, 0.0)); }
float sqrt2(float x) { return sqrt(sqrt1(x)); }
float sqrt3(float x) { return sqrt(sqrt2(x)); }
float smoothstep1(float x) { return x * x * (3.0 - 2.0 * x); }
float max0(float x) { return max(x, 0.0); }
vec3 max0(vec3 x) { return max(x, vec3(0.0)); }
float min1(float x) { return min(x, 1.0); }
float clamp01(float x) { return clamp(x, 0.0, 1.0); }
vec3 clamp01(vec3 x) { return clamp(x, vec3(0.0), vec3(1.0)); }
float GetLuminance(vec3 color) { return dot(color, vec3(0.299, 0.587, 0.114)); }
vec3 DoLuminanceCorrection(vec3 color) { return color / (GetLuminance(color) + 0.0001); }

const float pi = 3.14159265359;
const float goldenRatio = 1.61803398875;

// ---- Values forwarded by the hook from other game passes -----------------------------
uniform int uHookFrame;
uniform float uHookTime;
uniform vec4 uHookTopGradientColor;   // Hytale sky top colour (biome / weather / time of day)
uniform vec4 uHookSunsetColor;
uniform vec4 uHookCloudColors[4];     // Hytale cloud layer tints (weather)
uniform int uHookCloudCount;
uniform float uHookMoonOpacity;
uniform float uHookStarsOpacity;

uniform sampler2D blueNoiseTex;   // 128x128 blue noise (tools/make_bluenoise.py), loaded by the hook

// Per-pixel dither for every stochastic effect (shafts, soft shadows, fog, reflections).
// Blue noise stepped by the golden ratio each frame: whatever the TAA leaves over is an even,
// very fine grain. Interleaved gradient noise has one strong diagonal frequency in every frame,
// so its leftover showed as a fine diagonal mesh over light shafts and dark walls.
float GetDither(vec2 fragCoord)
{
    float n = texelFetch(blueNoiseTex, ivec2(fragCoord) & 127, 0).r;
    return fract(n + goldenRatio * float(uHookFrame % 3600));
}

// Two more blue-noise values per pixel (decorrelated channels), animated the same way.
vec2 GetDither2(vec2 fragCoord)
{
    vec2 n = texelFetch(blueNoiseTex, ivec2(fragCoord) & 127, 0).gb;
    return fract(n + vec2(goldenRatio, 0.754878) * float(uHookFrame % 3600));
}

// ---- Time of day ---------------------------------------------------------------------
vec3 sunVec;        // world space, towards the sun
vec3 lightVec;      // sun during the day, moon at night
float SdotU, sunFactor, sunVisibility, sunVisibility2, shadowTime;
float noonFactor, nightFactor, invNightFactor, invNoonFactor, invNoonFactor2;
float rainFactor, rainFactor2, invRainFactor;
float vsBrightness;
vec3 skyColor;

// Sky palette (skyColors.glsl)
vec3 noonUpSkyColor, noonMiddleSkyColor, noonDownSkyColor;
vec3 sunsetUpSkyColor, sunsetMiddleSkyColor, sunsetDownSkyColorP, sunsetDownSkyColor;
vec3 dayUpSkyColor, dayMiddleSkyColor, dayDownSkyColor;
vec3 nightUpSkyColor, nightMiddleSkyColor, nightDownSkyColor;

// Light & ambient (lightAndAmbientColors.glsl)
vec3 lightColor, ambientColor;   // ground / cloud lighting
vec3 shaftColor;                 // light shaft colour (COMPOSITE1 variant)
vec3 waterFogColor;
vec3 blocklightCol;

float GetRainFactor()
{
    // Hytale has no rain uniform for the renderer; overcast/rain environments desaturate
    // the sky's top gradient colour, so use that as the weather signal.
    vec3 c = uHookTopGradientColor.rgb;
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float sat = mx > 0.001 ? (mx - mn) / mx : 0.5;
    // Weather sky tops at noon: rain 0.18-0.24, storms/snow < 0.1, cloudy 0.5+, sunny 0.9+.
    float r = smoothstep(0.40, 0.20, sat);
    // Only trust the signal when there is daylight to colour the sky.
    return r * smoothstep(0.0, 0.25, SdotU / AU_SUN_MAX_ELEVATION + 0.1);
}

void AU_InitCommon()
{
    sunVec = normalize(SunPositionWS);
#ifdef AU_DEBUG_FAKE_SUN
    // Debug: pretend the sun is at this elevation (sin), keeping its azimuth.
    vec2 az = normalize(sunVec.xz + vec2(0.0001));
    sunVec = normalize(vec3(az.x * sqrt(1.0 - AU_DEBUG_FAKE_SUN * AU_DEBUG_FAKE_SUN), AU_DEBUG_FAKE_SUN, az.y * sqrt(1.0 - AU_DEBUG_FAKE_SUN * AU_DEBUG_FAKE_SUN)));
#endif
    // Hytale's dusk/dawn linger with the sun at the horizon while the sky is still lit;
    // The palette is keyed to Minecraft's short sunset. Shift it so Hytale's dusk lands on
    // the golden hour instead of the sun/moon switch.
    SdotU = sunVec.y + AU_TWILIGHT_SHIFT;
    float SdotUn = clamp(SdotU / AU_SUN_MAX_ELEVATION, -1.0, 1.0);

    sunFactor = SdotU < 0.0 ? clamp(SdotU + 0.375, 0.0, 0.75) / 0.75 : clamp(SdotU + 0.03125, 0.0, 0.0625) / 0.0625;
    sunVisibility = clamp(SdotU + 0.0625, 0.0, 0.125) / 0.125;
    sunVisibility2 = sunVisibility * sunVisibility;
    float shadowTimeVar1 = abs(sunVisibility - 0.5) * 2.0;
    float shadowTimeVar2 = shadowTimeVar1 * shadowTimeVar1;
    shadowTime = shadowTimeVar2 * shadowTimeVar2;
    // Direct light comes from Hytale's shadow-casting light (sun or moon, with its "safe
    // angle" clamp) so N.L always agrees with the shadow map. It fades out near the horizon,
    // which also hides the moment Hytale swaps the shadows between sun and moon.
    vec3 shadowLight = -vec3(SunShadowMatrix[0][0][2], SunShadowMatrix[0][1][2], SunShadowMatrix[0][2][2]);
    lightVec = dot(shadowLight, shadowLight) > 0.01 ? normalize(shadowLight) : (sunVisibility > 0.5 ? sunVec : -sunVec);
    // Narrow: the low sun at dawn throws window patterns across rooms like Hytale's, and a wide
    // fade had it at a sixth of its light there.
    shadowTime *= smoothstep(-0.06, 0.02, lightVec.y);

    // The colour palette follows the real sun height, so the sun touching the horizon gets
    // the full sunset colours while the light (sunVisibility) stays up a while longer.
    float noonFactorRaw = max((sunVec.y + AU_SUNSET_SHIFT) / AU_SUN_MAX_ELEVATION, 0.0);
    noonFactor = sqrt(noonFactorRaw);
    nightFactor = max(-SdotUn, 0.0);
    invNightFactor = 1.0 - nightFactor;
    invNoonFactor = 1.0 - noonFactor;
    invNoonFactor2 = invNoonFactor * invNoonFactor;

    rainFactor = GetRainFactor();
    rainFactor2 = rainFactor * rainFactor;
    invRainFactor = 1.0 - rainFactor;
    vsBrightness = AU_SCREEN_BRIGHTNESS;

    // Vanilla Minecraft sky colour (plains), dimmed like Minecraft does over the day.
    vec3 baseSky = vec3(0.471, 0.655, 1.0);
    vec3 hytaleTop = uHookTopGradientColor.rgb;
    float hytaleLum = max(GetLuminance(hytaleTop), 0.001);
    vec3 hytaleTint = hytaleTop / hytaleLum * GetLuminance(baseSky);
    if (dot(hytaleTop, hytaleTop) > 0.0001) baseSky = mix(baseSky, hytaleTint, AU_HYTALE_SKY_TINT);
    skyColor = baseSky * clamp(SdotUn * 2.0 + 0.5, 0.0, 1.0);
    float skyLumRain = GetLuminance(skyColor) * 0.6;
    skyColor = mix(skyColor, vec3(skyLumRain), rainFactor * 0.75);

    // ---- skyColors.glsl ----
    vec3 skyColorSqrt = sqrt(skyColor);
    float invRainStrength2 = invRainFactor * invRainFactor;
    vec3 skyColorM = mix(max(skyColorSqrt, vec3(0.63, 0.67, 0.73)), skyColorSqrt, invRainStrength2);
    vec3 skyColorM2 = mix(max(skyColor, sunFactor * vec3(0.265, 0.295, 0.35)), skyColor, invRainStrength2);

    vec3 nuscWeatherM = vec3(0.1, 0.0, 0.1);
    vec3 nmscWeatherM = vec3(-0.1, -0.4, -0.6) + vec3(0.0, 0.06, 0.12) * noonFactor;
    vec3 ndscWeatherM = vec3(-0.15, -0.3, -0.42) + vec3(0.0, 0.02, 0.08) * noonFactor;

    noonUpSkyColor     = pow(skyColorM, vec3(2.9)) * (vec3(0.85, 0.92, 0.81) + rainFactor * nuscWeatherM);
    noonMiddleSkyColor = skyColorM * (vec3(1.4, 1.3, 1.3) + rainFactor * nmscWeatherM) + noonUpSkyColor * 0.25;
    noonDownSkyColor   = skyColorM * (vec3(0.9) + rainFactor * ndscWeatherM) + noonUpSkyColor * 0.25;

    sunsetUpSkyColor     = skyColorM2 * (vec3(0.72, 0.522, 0.47) + vec3(0.1, 0.2, 0.35) * rainFactor2);
    sunsetMiddleSkyColor = skyColorM2 * (vec3(1.8, 1.3, 1.2) + vec3(0.15, 0.25, -0.05) * rainFactor2);
    sunsetDownSkyColorP  = vec3(1.45, 0.86, 0.5) - vec3(0.8, 0.3, 0.0) * rainFactor;
    sunsetDownSkyColor   = sunsetDownSkyColorP * 0.5 + 0.25 * sunsetMiddleSkyColor;

    dayUpSkyColor     = mix(noonUpSkyColor, sunsetUpSkyColor, invNoonFactor2);
    dayMiddleSkyColor = mix(noonMiddleSkyColor, sunsetMiddleSkyColor, invNoonFactor2);
    dayDownSkyColor   = mix(noonDownSkyColor, sunsetDownSkyColor, invNoonFactor2);

    vec3 nightColFactor = 0.9 * vec3(0.07, 0.14, 0.24) * (1.0 - 0.5 * rainFactor) + skyColor;
    nightUpSkyColor     = pow(nightColFactor, vec3(0.90)) * 0.45;
    nightMiddleSkyColor = sqrt(nightUpSkyColor) * 0.65;
    // The sqrt() above drains the saturation, so the night horizon fades to grey;
    // Hytale's nights stay deep blue down to the horizon. Push it back toward the zenith's hue.
    float nightMiddleLum = dot(nightMiddleSkyColor, vec3(0.299, 0.587, 0.114));
    nightMiddleSkyColor = max(mix(vec3(nightMiddleLum), nightMiddleSkyColor, AU_NIGHT_SKY_SATURATION), 0.0);
    nightDownSkyColor   = nightMiddleSkyColor * vec3(0.82, 0.82, 0.88);

    // ---- lightAndAmbientColors.glsl ----
    vec3 noonClearLightColor = vec3(0.65, 0.55, 0.375) * 2.05;
    vec3 noonClearAmbientColor = pow(skyColor, vec3(0.75)) * 0.85;
    vec3 sunsetClearLightColor = pow(vec3(0.64, 0.45, 0.3), vec3(1.5 + invNoonFactor)) * 5.0;
    vec3 sunsetClearAmbientColor = noonClearAmbientColor * vec3(1.21, 0.92, 0.76) * 0.95;
    vec3 nightClearLightColor = 0.9 * vec3(0.15, 0.14, 0.20) * (0.4 + vsBrightness * 0.4);
    vec3 nightClearAmbientColor = 0.9 * vec3(0.09, 0.12, 0.17) * (1.55 + vsBrightness * 0.77);

    vec3 dayRainLightColor = vec3(0.21, 0.16, 0.13) * 0.85 + noonFactor * vec3(0.0, 0.02, 0.06);
    vec3 dayRainAmbientColor = vec3(0.2, 0.2, 0.25) * (1.8 + 0.5 * vsBrightness);
    vec3 nightRainLightColor = vec3(0.03, 0.035, 0.05) * (0.5 + 0.5 * vsBrightness);
    vec3 nightRainAmbientColor = vec3(0.16, 0.20, 0.3) * (0.75 + 0.6 * vsBrightness);

    vec3 dayLightColor = mix(sunsetClearLightColor, noonClearLightColor, noonFactor);
    vec3 dayAmbientColor = mix(sunsetClearAmbientColor, noonClearAmbientColor, noonFactor);
    vec3 clearLightColor = mix(nightClearLightColor, dayLightColor, sunVisibility2);
    vec3 clearAmbientColor = mix(nightClearAmbientColor, dayAmbientColor, sunVisibility2);

    float rainShadowVisReduce = 0.4;
    vec3 rainLightColor = mix(nightRainLightColor, dayRainLightColor * (1.0 - rainShadowVisReduce), sunVisibility2) * 2.5;
    vec3 rainAmbientColor = mix(nightRainAmbientColor, dayRainAmbientColor * (1.0 + rainShadowVisReduce), sunVisibility2);

    lightColor = mix(clearLightColor, rainLightColor, rainFactor);
    ambientColor = mix(clearAmbientColor, rainAmbientColor, rainFactor);

    // Light shaft colour (the COMPOSITE1 variant of the same file).
    vec3 noonShaft = vec3(0.4, 0.75, 1.3);
    vec3 sunsetShaft = pow(vec3(0.62, 0.39, 0.24), vec3(1.5 + invNoonFactor)) * 6.8;
    vec3 nightShaft = vec3(0.08, 0.12, 0.23);
    vec3 dayShaft = mix(sunsetShaft, noonShaft, noonFactor * noonFactor);
    vec3 clearShaft = mix(nightShaft, dayShaft, sunVisibility2);
    shaftColor = mix(clearShaft, rainLightColor, rainFactor);

    vec3 underwaterColorM1 = vec3(0.46, 0.62, 1.0);
    waterFogColor = underwaterColorM1 * vec3(0.2 + 0.1 * vsBrightness);

    blocklightCol = vec3(0.1775, 0.104, 0.077);
}

// ---- Space helpers -------------------------------------------------------------------
// Hytale renders camera-relative: "positionFromCameraWS" is world-oriented, camera at origin.
float GetRenderDistance()
{
    return FogParams.y > 1.0 ? FogParams.y : 512.0;
}

#endif // AU_COMMON
