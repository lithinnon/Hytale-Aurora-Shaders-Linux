#version 410 core

// Aurora Shaders for Hytale - bloom downsample.
// The bloom buffers are RGB8 holding pow(linear / 128, 0.25) (BloomSelectFS). Averaging those
// stored values instead of the light they stand for crushed small bright sources - a potion or
// a candle flame lost almost all of its glow - so every tap is decoded, averaged as light and
// encoded again. 13-tap filter (Jimenez, "Next Generation Post Processing in Call of Duty").

uniform sampler2D uColorTexture;
uniform vec2 uPixelSize;

in vec2 fragTexCoords;

layout(location = 0) out vec3 outColor;

vec3 AU_BloomDecode(vec3 e) { e *= e; return e * e * 128.0; }
vec3 AU_BloomEncode(vec3 l) { return pow(max(l, vec3(0.0)) / 128.0, vec3(0.25)); }
vec3 AU_Tap(vec2 o) { return AU_BloomDecode(texture(uColorTexture, fragTexCoords + o * uPixelSize).rgb); }

void main(void)
{
    vec3 a = AU_Tap(vec2(-0.5,  0.5)), b = AU_Tap(vec2(0.5,  0.5));
    vec3 c = AU_Tap(vec2(-0.5, -0.5)), d = AU_Tap(vec2(0.5, -0.5));
    vec3 e = AU_Tap(vec2(-1.0,  1.0)), f = AU_Tap(vec2(0.0,  1.0)), g = AU_Tap(vec2(1.0,  1.0));
    vec3 l = AU_Tap(vec2(-1.0,  0.0)), m = AU_Tap(vec2(0.0,  0.0)), h = AU_Tap(vec2(1.0,  0.0));
    vec3 k = AU_Tap(vec2(-1.0, -1.0)), j = AU_Tap(vec2(0.0, -1.0)), i = AU_Tap(vec2(1.0, -1.0));
    vec3 sum = (a + b + c + d) * 0.125
             + (e + f + l + m) * 0.03125 + (f + g + m + h) * 0.03125
             + (m + h + j + i) * 0.03125 + (l + m + k + j) * 0.03125;
    outColor = AU_BloomEncode(sum);
}
