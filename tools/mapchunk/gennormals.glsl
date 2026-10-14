#if AU_GENERATED_NORMALS
    // Generated normals: compare the texel's brightness
    // with neighbours a fraction of a texel away, so only texel edges bevel, with a dead zone
    // and a clamp. Tangent frame rebuilt from screen derivatives (Hytale has no tangents).
    // Not on REFLECTIVE blocks (ore crystals): bevelling every texel edge made them look grainy
    // instead of smooth and glossy.
    if (hasSSAO && !hasBloom && shadingMode != SHADING_REFLECTIVE)
    {
        const float normalThreshold = 0.05;
        const float normalClamp = 0.2;
        vec2 atlasSize = vec2(textureSize(uTexture, 0).xy);
        vec2 tileSize = 32.0 / atlasSize;                       // Hytale block textures are 32 px
        vec2 originalOffsetR = tileSize / AU_GENERATED_NORMAL_RES;
        vec2 offsetR = max(originalOffsetR, fwidth(fragTexCoords));
        vec2 minCoord = floor(fragTexCoords / tileSize) * tileSize;
        vec2 maxCoord = minCoord + tileSize;
        float lOriginal = length(texColor.rgb);

        vec3 nts = vec3(0.0, 0.0, 1.0);
        vec2 oc; float d;
#define AU_GN_DIF(coord) (d = lOriginal - length(texture(uTexture, vec3(coord, fragAtlasPages.x)).rgb), d = d > 0.0 ? max(d - normalThreshold, 0.0) : min(d + normalThreshold, 0.0), clamp(d, -normalClamp, normalClamp))
        oc = fragTexCoords + vec2(0.0, offsetR.y); if (oc.y < maxCoord.y) nts.y += AU_GN_DIF(oc);
        oc = fragTexCoords + vec2(offsetR.x, 0.0); if (oc.x < maxCoord.x) nts.x += AU_GN_DIF(oc);
        oc = fragTexCoords - vec2(0.0, offsetR.y); if (oc.y > minCoord.y) nts.y -= AU_GN_DIF(oc);
        oc = fragTexCoords - vec2(offsetR.x, 0.0); if (oc.x > minCoord.x) nts.x -= AU_GN_DIF(oc);
#undef AU_GN_DIF
        nts.xy *= AU_GENERATED_NORMAL_MULT * 0.025 * sqrt(AU_GENERATED_NORMAL_RES / 128.0) * (originalOffsetR / offsetR);
        nts.xy = clamp(nts.xy, vec2(-1.0), vec2(1.0));

        if (nts.xy != vec2(0.0)) {
            vec4 ndcPos = vec4(gl_FragCoord.xy * InvViewportSize * 2.0 - 1.0, gl_FragCoord.z * 2.0 - 1.0, 1.0);
            vec4 wp = InvViewProjectionMatrix * ndcPos;
            vec3 pos = wp.xyz / wp.w;
            vec3 dp1 = dFdx(pos), dp2 = dFdy(pos);
            vec2 duv1 = dFdx(fragTexCoords), duv2 = dFdy(fragTexCoords);
            vec3 dp2perp = cross(dp2, normalWS);
            vec3 dp1perp = cross(normalWS, dp1);
            vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
            vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
            float tbLen = max(dot(T, T), dot(B, B));
            if (tbLen > 1e-20) {
                float invmax = inversesqrt(tbLen);
                vec3 bumped = normalize(T * invmax * nts.x + B * invmax * nts.y + normalWS * nts.z);
                if (dot(bumped, normalWS) > 0.2) normalWS = bumped;
            }
        }
    }
#endif

    // Block materials: the hook recognises every tile of the block atlas (its pixels against
    // the game's own block textures, classified by name at install) and hands the result over
    // per tile: class 1 polished, 2 metal, 3 porous; level 0-7. Written to G-buffer meta: class
    // in bits 5-6, level in bits 2-4 (the ore glow level's bits: ores are REFLECTIVE, these never).
    float auMatClass = 0.0, auMatLevel = 0.0;
#if AU_MATERIALS
    if (!hasBloom && shadingMode != SHADING_REFLECTIVE)
    {
        ivec3 auTile = ivec3(ivec2(fragTexCoords * vec2(textureSize(uTexture, 0).xy) / 32.0), int(fragAtlasPages.x + 0.5));
        vec2 auMat = texelFetch(uHookMaterials, auTile, 0).rg * 255.0;
        auMatClass = floor(auMat.x + 0.5);
        auMatLevel = floor(auMat.y + 0.5);
    }
#endif

    // Glowing ores: Hytale shades the crystal models of ore blocks (and crystal blocks, gems)
    // REFLECTIVE - their 32px textures are all crystal - so those glow as a whole, more the more
    // gem-like a texel is (colourful, or bright like silver / mithril). Judged on the texel
    // blended with its neighbourhood (4 taps of the half-size mip around it, kept inside the
    // tile), so the glow is even over a crystal instead of grainy. Hytale's sweeping glint over
    // these blocks (near chunks) comes back as part of the same glow. Stored as 8 levels in
    // G-buffer meta bits 2-4.
    float auOreGlow = 0.0;
#if AU_ORE_GLOW
    if (shadingMode == SHADING_REFLECTIVE && !hasBloom)
    {
        vec2 auTexel = 1.0 / vec2(textureSize(uTexture, 0).xy);
        vec2 auTile = 32.0 * auTexel;
        vec2 auTileMin = floor(fragTexCoords / auTile) * auTile;
        vec2 auLo = auTileMin + auTexel, auHi = auTileMin + auTile - auTexel;
        vec3 auN = vec3(0.0);
        for (int i = 0; i < 4; i++) {
            vec2 o = vec2(i & 1, i >> 1) * 2.0 - 1.0;
            auN += textureLod(uTexture, vec3(clamp(fragTexCoords + o * 1.5 * auTexel, auLo, auHi), fragAtlasPages.x), 1.0).rgb;
        }
        vec3 auC = mix(texColor.rgb, auN * 0.25, 0.6);
        float auMx = max(auC.r, max(auC.g, auC.b)), auMn = min(auC.r, min(auC.g, auC.b));
        float auSat = (auMx - auMn) / max(auMx, 0.001), auLum = dot(auC, vec3(0.299, 0.587, 0.114));
        float auGem = max(smoothstep(0.4, 0.8, auSat) * smoothstep(0.05, 0.35, auLum), smoothstep(0.35, 0.75, auLum));
        auOreGlow = 0.3 + 0.7 * auGem;
#if NEAR
        // Hytale's sweeping glint: a band of light passing over the crystal faces one after
        // another. Like Hytale, it brightens the colour (the glow then carries it); stronger,
        // since our crystals already glow.
        vec4 auShine = computeFakeShininess(texColor.rgb, normalWS, CameraDirection.xyz);
        albedo.rgb += auShine.rgb * (2.5 * AU_ORE_SHINE);
        auOreGlow = max(auOreGlow, auShine.a * AU_ORE_SHINE);
#endif
#if AU_ORE_GLOW == 2
        auOreGlow = 1.0;   // debug: every REFLECTIVE block
#endif
    }
#endif
