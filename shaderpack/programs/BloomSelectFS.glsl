#version 410 core

// Aurora Shaders for Hytale - bloom input.
// The whole (linear) scene blooms, not just emissive pixels. Hytale's bloom buffers are RGB8,
// so store pow(linear / 128, 0.25).
// Bloom fog: multiplying the scene by GetBloomFog before the bloom pass and dividing it back
// out of the sharp image afterwards, so only the bloom carries it - same as boosting
// the bloom input here.

#include "SceneData_inc.glsl"
#include "AU_Settings.glsl"
#if AU_BLOOM_FOG
#include "AU_Common.glsl"
#include "AU_Fog.glsl"
#ifndef AU_HOOK_DEPTH
#define AU_HOOK_DEPTH
uniform sampler2D uHookGBuffer1;    // G-buffer normals + sky light (.b), shared by the hook
uniform sampler2D uHookDepth;       // DeferredFS linear depth (0..1 of the far plane), shared by the hook
#endif
#endif

uniform sampler2D uSceneColorTexture;
#if EMISSIVE
uniform sampler2D uEmissiveTexture;
uniform float uPower;
#endif

in vec2 fragTexCoords;

out vec3 outColor;

void main(void)
{
    vec4 scene = texture(uSceneColorTexture, fragTexCoords.xy);
    vec3 color = max(scene.rgb, vec3(0.0));
    vec3 linearColor = pow(color, vec3(2.2));
    // Emissive blocks (flames, potions, lava) and glowing ores bloom much more than the rest,
    // like Hytale's own glow. DeferredFS leaves 1 SSAO / 2 emissive / 4 ore in the alpha
    // (larger values: sky and other passes).
    uint meta = uint(round(scene.a * 255.0));
    if (meta < 32u) {
        if ((meta & 2u) != 0u) linearColor *= AU_EMISSIVE_BLOOM;
        else linearColor *= mix(1.0, AU_ORE_BLOOM, float((meta >> 2) & 7u) / 7.0);
    }
#if EMISSIVE
    vec4 emissive = texture(uEmissiveTexture, fragTexCoords.xy);
    // Glow from see-through and particle sources (flames, glowing glass) - as strong as the rest.
    linearColor += pow(max(emissive.rgb, vec3(0.0)), vec3(2.2)) * emissive.a * AU_EMISSIVE_BLOOM;
#endif
#if AU_BLOOM_FOG
    AU_InitCommon();
    float lViewPos = texture(uHookDepth, fragTexCoords.xy).r * FarClip;
    float linDepth = texture(uHookDepth, fragTexCoords.xy).r;
    float openness = linDepth >= 1.0 ? 1.0 : AU_Openness(texture(uHookGBuffer1, fragTexCoords.xy).b);
    linearColor *= GetBloomFog(lViewPos, openness);
#endif
    outColor = pow(linearColor / 128.0, vec3(0.25));
}
