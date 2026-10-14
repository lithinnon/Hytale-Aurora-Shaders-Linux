// Aurora Shaders for Hytale - tonemapping and grading.
// Tonemap, saturation / vibrance and vignette.

#ifndef AU_TONEMAP
#define AU_TONEMAP

#include "AU_Settings.glsl"

float AU_Lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

void LinearToRGB(inout vec3 color)
{
    const vec3 k = vec3(0.055);
    color = mix((vec3(1.0) + k) * pow(color, vec3(1.0 / 2.4)) - k, 12.92 * color, lessThan(color, vec3(0.0031308)));
}

// Lottes 2016 tonemap, modified.
void DoTonemap(inout vec3 color)
{
    color = AU_TM_EXPOSURE * color;

    float initialLuminance = AU_Lum(color);

    vec3 a      = vec3(AU_TM_CONTRAST);
    vec3 d      = vec3(1.0);
    vec3 hdrMax = vec3(8.0);
    vec3 midIn  = vec3(0.25);
    vec3 midOut = vec3(0.25);

    vec3 a_d = a * d;
    vec3 hdrMaxA = pow(hdrMax, a);
    vec3 hdrMaxAD = pow(hdrMax, a_d);
    vec3 midInA = pow(midIn, a);
    vec3 midInAD = pow(midIn, a_d);
    vec3 HM1 = hdrMaxA * midOut;
    vec3 HM2 = hdrMaxAD - midInAD;

    vec3 b = (-midInA + HM1) / (HM2 * midOut);
    vec3 c = (hdrMaxAD * midInA - HM1 * midInAD) / (HM2 * midOut);

    vec3 colorOut = pow(color, a) / (pow(color, a_d) * b + c);
    LinearToRGB(colorOut);

    // Remove tonemapping from darker colours for better readability
    const float darkLiftStart = 0.1;
    const float darkLiftMix = 0.75;
    float darkLift = smoothstep(darkLiftStart, 0.0, initialLuminance);
    vec3 smoothColor = pow(color, vec3(1.0 / 2.2));
    colorOut = mix(colorOut, smoothColor, darkLift * darkLiftMix * max(0.55 - abs(1.05 - AU_TM_CONTRAST), 0.0) / 0.55);

    // Path to white
    const float wpInputCurveMax = 16.0;
    float modifiedLuminance = pow(initialLuminance / wpInputCurveMax, 2.0 - AU_TM_WHITE_PATH) * wpInputCurveMax;
    float whitePath = smoothstep(0.0, wpInputCurveMax, modifiedLuminance);
    colorOut = mix(colorOut, vec3(1.0), whitePath);

    // Desaturate dark colours
    float desaturatePath = smoothstep(0.1, 0.0, initialLuminance);
    colorOut = mix(colorOut, vec3(AU_Lum(colorOut)), desaturatePath * AU_TM_DARK_DESATURATION);

    color = clamp(colorOut, vec3(0.0), vec3(1.0));
}

// Inverse of DoTonemap's curve (per channel; the dark lift and white path barely touch the
// values it is used for): the scene colour that comes out of the tonemap as `displayLinear`.
// Emissive texels use it to show their own colour, like Hytale's full-bright glow.
vec3 AU_InverseTonemap(vec3 displayLinear)
{
    vec3 a = vec3(AU_TM_CONTRAST);
    vec3 hdrMax = vec3(8.0);
    vec3 midIn = vec3(0.25);
    vec3 midOut = vec3(0.25);
    vec3 hdrMaxA = pow(hdrMax, a);
    vec3 midInA = pow(midIn, a);
    vec3 HM1 = hdrMaxA * midOut;
    vec3 HM2 = hdrMaxA - midInA;
    vec3 b = (-midInA + HM1) / (HM2 * midOut);
    vec3 c = (hdrMaxA * midInA - HM1 * midInA) / (HM2 * midOut);
    vec3 y = min(displayLinear, 0.98 / b);
    return pow(y * c / max(1.0 - y * b, vec3(1e-4)), 1.0 / a) / AU_TM_EXPOSURE;
}

void DoBSLColorSaturation(inout vec3 color)
{
    float saturationFactor = AU_SATURATION + 0.07;

    float grayVibrance = (color.r + color.g + color.b) / 3.0;
    float graySaturation = grayVibrance;
    if (saturationFactor < 1.00) graySaturation = dot(color, vec3(0.299, 0.587, 0.114));

    float mn = min(color.r, min(color.g, color.b));
    float mx = max(color.r, max(color.g, color.b));
    float sat = (1.0 - (mx - mn)) * (1.0 - mx) * grayVibrance * 5.0;
    vec3 lightness = vec3((mn + mx) * 0.5);

    color = mix(color, mix(color, lightness, 1.0 - AU_VIBRANCE), sat);
    color = mix(color, lightness, (1.0 - lightness) * (2.0 - AU_VIBRANCE) / 2.0 * abs(AU_VIBRANCE - 1.0));
    color = color * saturationFactor - graySaturation * (saturationFactor - 1.0);
}

void DoVignette(inout vec3 color, vec2 texCoord)
{
    vec2 texCoordMin = texCoord - 0.5;
    float vignette = 1.0 - dot(texCoordMin, texCoordMin) * (1.0 - AU_Lum(color));
    color *= vignette;
}

#endif // AU_TONEMAP
