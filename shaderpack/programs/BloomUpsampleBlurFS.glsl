#version 410 core

// Aurora Shaders for Hytale - bloom upsample.
// Hytale adds the pyramid levels together with intensity weights; this bloom is a
// normalised blend of levels, and the RGB8 encoding needs values to stay in range. Blended as
// light, not as the stored pow(linear / 128, 0.25) (see BloomDownsampleBlurFS).

uniform sampler2D uColorTexture;
uniform sampler2D uColorLowResTexture;
uniform vec2 uPixelSize;
uniform float uScale;
uniform vec2 uIntensity;

in vec2 fragTexCoords;

layout(location = 0) out vec3 outColor;

vec3 AU_BloomDecode(vec3 e) { e *= e; return e * e * 128.0; }
vec3 AU_BloomEncode(vec3 l) { return pow(max(l, vec3(0.0)) / 128.0, vec3(0.25)); }

void main(void)
{
    mat3 weight;
    weight[0] = vec3(1.0, 2.0, 1.0) * 0.0625;
    weight[1] = vec3(2.0, 4.0, 2.0) * 0.0625;
    weight[2] = vec3(1.0, 2.0, 1.0) * 0.0625;

    vec3 low = vec3(0.0);
    for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
        low += AU_BloomDecode(texture(uColorLowResTexture, fragTexCoords + max(uScale, 1.0) * uPixelSize * vec2(i - 1, 1 - j)).rgb) * weight[i][j];

    vec3 current = AU_BloomDecode(texture(uColorTexture, fragTexCoords).rgb);
    outColor = AU_BloomEncode(mix(current, low, 0.6));
}
