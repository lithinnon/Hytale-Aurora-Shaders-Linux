// Aurora Shaders for Hytale - volumetric light shafts.
// Ray-marched shafts tracing Hytale's sun shadow cascades.

#ifndef AU_VL
#define AU_VL

#include "AU_Shadow.glsl"
#include "AU_Fog.glsl"

// The scene is still in gamma space here (PostEffectFS applies the pow 2.2); the shafts belong
// in linear space, after that pow.
vec3 AU_AddVL(vec3 color, vec3 vl)
{
    return pow(pow(max(color, vec3(0.0)), vec3(2.2)) + vl, vec3(1.0 / 2.2));
}

// nPlayerPos: normalised world-space view direction. lViewPos1: distance to the opaque
// surface (ignored for sky pixels).
vec3 GetVolumetricLight(vec3 nPlayerPos, float lViewPos1, bool sky, float dither)
{
#if AU_LIGHTSHAFTS
    float far = AU_LIGHTSHAFT_DISTANCE;
    float vlMult = AU_LIGHTSHAFT_STRENGTH;
    vec3 vlColor = lightColor;   // r5.9 volumetricLight.glsl uses the sun light colour
    // Only the darkness around the camera (caves, rooms) widens the shafts globally: Hytale eases
    // it smoothly. The overhead-cover check went per frame through a shadow map Hytale refits to
    // the view every frame, so it jumped at canopy edges and the whole screen's haze flickered;
    // beams under trees now come from the per-sample boost below instead.
    float vlSceneIntensity = clamp((0.6 - GetEyeBrightness()) * 2.5, 0.0, 1.0) * AU_LIGHTSHAFT_SCENE_AWARE;

    if (sunVisibility < 0.5) {
        vlSceneIntensity = 0.0;
        float vlMultNightModifier = 0.3 + 0.4 * rainFactor2 + 0.5 * max0(far - lViewPos1) / far;
        vlMult *= vlMultNightModifier;
        vlColor = normalize(pow(vlColor, vec3(1.0 - max0(1.0 - 1.5 * nightFactor) + rainFactor)));
        vlColor *= 0.0766 + 0.0766 * vsBrightness;
    }

    float VdotL = dot(nPlayerPos, lightVec);
    float VdotU = nPlayerPos.y;
    float rainyNight = (1.0 - sunVisibility) * rainFactor;
    float VdotLM = max((VdotL + 1.0) / 2.0, 0.0);
    float VdotUmax0 = max(VdotU, 0.0);
    // Haze fades toward the sky as you look up; beams (the boosted part below) keep the
    // under-cover version of that fade wherever the camera is, so shafts falling through a
    // roof or a canopy stay visible when you look up at them.
    float VdotUM = mix(pow2(1.0 - VdotUmax0), 1.0, 0.5 * vlSceneIntensity);
    VdotUM = pow(smoothstep1(VdotUM), min(lViewPos1 / far, 1.0) * (3.0 - 2.0 * vlSceneIntensity));
    float VdotUMShaft = pow(smoothstep1(mix(pow2(1.0 - VdotUmax0), 1.0, 0.5)), min(lViewPos1 / far, 1.0));
    float dirBase = mix(VdotUM * VdotLM, 1.0, 0.4 * rainyNight);
    float dirShaft = mix(VdotUMShaft * VdotLM, 1.0, 0.4 * rainyNight);

    float vlTime = min(abs(SdotU) - 0.05, 0.15) / 0.15;
    vlMult *= vlTime;
    float noonMult = mix(invNoonFactor2 * 0.875 + 0.125, 1.0, rainFactor2);
    vlMult *= noonMult;
    vlMult *= 1.4 - 0.4 * rainFactor;
    // Scene-aware strength per sample: light right after shadow along the ray - a shaft - gets
    // full strength at noon plus the boost wherever the camera is, under the trees or looking at
    // them from outside. Open daylit air (a door, a gap, an open field) keeps the dimmed noon haze.
    float shaftMult = (1.0 / noonMult) * (1.0 + AU_LIGHTSHAFT_SCENE_BOOST * float(sunVisibility > 0.5));
    // How much of the boost a ray gets depends on the ray itself, not on where the camera is: the
    // share of it that ran through shadow so far (rooms, caves, under a canopy: most of it; an
    // open field: little). Only nearby air counts (below), so distant forests don't haze over.
    float shaftAmount = AU_LIGHTSHAFT_SCENE_AWARE;
    float shadowSum = 0.0, shadowN = 0.0;

    if (vlMult * max(dirBase, dirShaft * shaftMult) < 0.0001) return vec3(0.0);

    // Short rays (rooms, under trees) get up to 75% more samples: they are cheap there, and thin
    // beams crossing them otherwise sparkle at their edges.
    float rayLenGuess = !sky ? lViewPos1 : 1.0e9;
    int nearSamples = int(mix(float(AU_LIGHTSHAFT_SAMPLES), 1.5 * float(AU_LIGHTSHAFT_SAMPLES), vlSceneIntensity)
                          * clamp(48.0 / max(rayLenGuess, 1.0), 1.0, 1.75));
    int farSamples = 1;
    float fogCurve = mix(0.9, 0.5, max(vlSceneIntensity, rainFactor));
    float sampleDistribution = mix(2.0, 1.5, vlSceneIntensity);
    float sampleDistributionFar = 2.5;
    float maxDistance = max(far * 0.98, 128.0);
    if (IsCameraUnderwater > 0.5) maxDistance = min(maxDistance, 128.0);
    float shadowRange = SunShadowCascadeStats[AU_SHADOW_CASCADES - 1].x;
    float qualityThreshold = min(far, shadowRange > 1.0 ? shadowRange : far) * 0.98;
    qualityThreshold = mix(qualityThreshold, 100.0, vlSceneIntensity);

    float rayEnd = !sky ? min(lViewPos1, maxDistance) : maxDistance;
    float lastDistance = 0.0;
    float activeThreshold = min(qualityThreshold, maxDistance);
    // March the near samples over the ray that actually exists: indoors the ray ends at a wall
    // 10-20 blocks away, and spreading the samples over the full shaft range left only a dozen
    // of them in the room, ~1.7 blocks apart - coarser than a light beam through a hole, so the
    // beam came out as heavy grain.
    float nearEnd = min(activeThreshold, rayEnd);
    int totalSamples = (rayEnd <= qualityThreshold) ? nearSamples : (nearSamples + farSamples);
    float eyeBrightnessM = GetEyeBrightness();

    float vlBase = 0.0, vlShaft = 0.0;
    // Hytale fits its cascades tightly around the view, so a ray can leave them sideways well
    // inside the shaft range; the box side then projects as a hard line through the sun.
    // Carry the last real shadow value along the ray instead of assuming full light.
    float lastDensity = eyeBrightnessM;
    // Short-memory average of the samples so far: the scene-aware boost only lifts light that
    // stands out right after shadow along the ray (a shaft crossing a dark room), not the run of
    // daylit air seen through a door or a gap, which would otherwise turn into bright fog.
    float litRecent = 0.0;
    for (int i = 0; i <= totalSamples; i++) {
        float nextDistance;
        float localDensity;

        if (i <= nearSamples) {
            float t = (float(i) + dither) / float(nearSamples);
            nextDistance = pow(t, sampleDistribution) * nearEnd;
            if (nextDistance >= rayEnd) break;
            vec3 sc;
            if (GetShadowCoord(nPlayerPos * nextDistance, sc)) {
                localDensity = texture(uHookShadowMap, vec3(sc.xy, sc.z - 0.0002));
                lastDensity = localDensity;
            } else {
                localDensity = lastDensity;
            }
        } else {
            float t = (float(i - nearSamples) + dither) / float(farSamples);
            nextDistance = mix(activeThreshold, maxDistance, pow(t, sampleDistributionFar));
            if (nextDistance >= rayEnd) nextDistance = rayEnd;
            localDensity = eyeBrightnessM;
        }

        float currentWeight = smoothstep1(pow(lastDistance / maxDistance, fogCurve));
        float nextWeight = smoothstep1(pow(nextDistance / maxDistance, fogCurve));
        // Beams use the dense, near-weighted curve of enclosed spaces everywhere.
        float shaftWeight = smoothstep1(sqrt(nextDistance / maxDistance)) - smoothstep1(sqrt(lastDistance / maxDistance));
        shadowSum += 1.0 - localDensity;
        shadowN += 1.0;
        float enclosed = shadowSum / shadowN;
        float nearW = (1.0 - smoothstep(12.0, 48.0, nextDistance)) * (1.0 - litRecent) * shaftAmount * mix(0.4, 1.0, enclosed);
        float sampleLight = localDensity * (nextWeight - currentWeight);
        vlBase += sampleLight;
        vlShaft += localDensity * shaftWeight * (shaftMult - 1.0) * nearW;
        litRecent = mix(litRecent, localDensity, 0.6);
        lastDistance = nextDistance;
    }

    vlColor = pow(vlColor, vec3(0.5 + (0.5 + 0.25 * sunVisibility) * invNoonFactor * invRainFactor + 0.3 * rainFactor));
    vlColor *= 1.0 - (0.3 + 0.3 * noonFactor) * rainFactor - 0.5 * rainyNight + sunVisibility * invNoonFactor2 * invRainFactor;

    // Strength per time of day (noon / sunset / night).
    if (IsCameraUnderwater < 0.5)
        vlMult *= mix(AU_LIGHTSHAFT_NIGHT_I, mix(AU_LIGHTSHAFT_SUNSET_I, AU_LIGHTSHAFT_NOON_I, auPow3(noonFactor)), sunVisibility);
    // The open-air haze (vlBase) has its own strength: Hytale's land is darker than Minecraft's
    // under Complementary's light, and at full strength the haze turned open views milky. Beams
    // (vlShaft: light right after shadow - forests, caves, windows) keep theirs.
    vec3 volumetricLight = (vlBase * dirBase * AU_LIGHTSHAFT_HAZE + vlShaft * dirShaft) * vlColor * vlMult;
    if (IsCameraUnderwater > 0.5) volumetricLight *= pow2(vec3(0.46, 0.62, 1.0) * 0.55);
    return max(volumetricLight - dither * 0.005, vec3(0.0));
#else
    return vec3(0.0);
#endif
}

#endif // AU_VL
