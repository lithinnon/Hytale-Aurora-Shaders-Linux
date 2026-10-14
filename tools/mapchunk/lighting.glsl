#if AU_FORWARD
    AU_InitCommon();
    float auDither = GetDither(gl_FragCoord.xy);
    vec3 auForwardVL = vec3(0.0);   // light shafts in front of water we composite ourselves
    bool auGlass = false;           // glass composited here (written opaque into the OIT pass)
    vec3 auHytaleLit = outColor0.rgb;   // Hytale's own lighting of this fragment
    {
        vec3 auBlock = max(AU_ExtractBlockLight(fragStaticLight.rgb, fragStaticLight.a, normalWS, shadingMode != SHADING_REFLECTIVE), dynamicLight * 0.5);
        float auShadow = SampleShadowWS(fragPositionWS + normalWS * 0.35 + lightVec * 0.2, 1.0);
        outColor0.rgb = AU_DoLighting(albedo * AU_ALBEDO_MULT, normalWS, fragPositionWS, fragStaticLight.a, auBlock, auShadow,
                                      1.0, 0, hasBloom ? AU_EMISSION_STRENGTH : 0.0, 0.0, 1.0, false);
    }
#if ALPHA_BLEND
    // See-through emissive surfaces (the glowing panes Hytale puts in windows for the daylight
    // coming in, glowing fluids): Hytale's own colour, mapped through the inverse of our
    // tonemap so it comes out in that colour - our lighting boosted them to a warm white that
    // vanished into the bright view behind.
    if (hasBloom && !isWater(effectID))
        outColor0.rgb = AU_InverseTonemap(pow(clamp(auHytaleLit, 0.0, 0.88), vec3(2.2)));
#endif
#if ALPHA_BLEND && AU_GLASS
    // Glass and other see-through blocks composite themselves, like the water: the scene
    // behind (the refraction copy) dimmed and tinted by the glass, the lit glass texture over
    // it by its own alpha, and the sky it reflects, mostly at grazing angles. Blended by texture
    // alpha alone, a dim pane over our bright HDR outside vanished after the tonemap.
    if (!isWater(effectID) && !hasBloom && texColor.a < 0.99) {
        auGlass = true;
        vec3 auBehind = textureLod(uRefractionTexture, gl_FragCoord.xy * uCurrentInvViewportSize, 0.0).rgb;
        vec3 auTint = albedo / max(max(albedo.r, max(albedo.g, albedo.b)), 0.05);
        vec3 auThrough = auBehind * mix(vec3(1.0), auTint, AU_GLASS_TINT) * (1.0 - AU_GLASS_ABSORB);
        // The pane itself as Hytale lights it (open to the sky on one side, which our lighting
        // of a block in a wall misses), over the view through it.
        outColor0.rgb = mix(auThrough, auHytaleLit, texColor.a);
        vec3 auV = fragPositionWS / max(length(fragPositionWS), 0.0001);
        vec3 auN = dot(normalWS, auV) > 0.0 ? -normalWS : normalWS;   // panes are seen from both sides
        float auF = pow(clamp(1.0 + dot(auN, auV), 0.0, 1.0), 5.0);
        vec3 auR = reflect(auV, auN);
        vec3 auSky = GetSky(auR.y, dot(auR, sunVec), auDither, true, true) * pow2(fragStaticLight.a);
        outColor0.rgb = mix(outColor0.rgb, auSky, (0.04 + 0.96 * auF) * AU_GLASS_REFLECT);
    }
#endif
#if AU_DEBUG_CLASS == 9 && ALPHA_BLEND
    // Debug: see-through blocks' texture alpha (red: emissive, blue: composited as glass).
    if (!isWater(effectID)) outColor0.rgb = vec3(hasBloom ? 1.0 : 0.0, texColor.a, auGlass ? 1.0 : 0.0);
#endif
#endif
