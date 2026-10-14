#if AU_VOXELS && DEFERRED && !ALPHA_BLEND && !ANIMATED && !USE_SCENE_DATA_OVERRIDE
    // Aurora Shaders: record this block in the path tracer's voxel grid (AU_Voxel.glsl).
    // Every vertex of a block writes the same cell; the chunk origin is uModelMatrix's
    // camera-relative translation plus the camera position, the block from the vertex id.
    {
        ivec3 auBlock = ivec3(floor(nodeMatrix[3].xyz + CameraPosition + 0.5)) + blockPosition;
        if (AU_VoxInWindow(auBlock, ivec3(floor(CameraPosition))))
        {
            // A block with no vertex on a corner of its cell is a small model (torch, rock,
            // flower pot) the rays may pass; slabs, stairs and grass with overhangs all have
            // corner vertices and count as solid.
            vec3 auLocal = vec3(vertPositionPacked) / 512.0 - vec3(blockPosition);
            vec3 auOff = abs(auLocal - round(auLocal));
            bool auCorner = max(auOff.x, max(auOff.y, auOff.z)) < 0.01
                         && all(greaterThan(auLocal, vec3(-0.01))) && all(lessThan(auLocal, vec3(1.01)));
            vec3 auN = abs(normal);
            bool auAxis = max(auN.x, max(auN.y, auN.z)) > 0.99;
#if ALPHA_TEST
            // Cut-out blocks: leaves and bushes (axis-aligned) are porous; cross-quad grass
            // and flowers (diagonal) are left out.
            bool auWrite = auAxis;
            uint auType = AU_VOX_POROUS;
#else
            bool auWrite = true;
            uint auType = AU_VOX_SOLID;
#endif
            if (auWrite)
            {
                ivec3 auCell = auBlock & AU_VOX_MASK;
                uint auTag = AU_VoxTag(auBlock) << 8;
                uint auOld = imageLoad(auVoxGeo, auCell).r;
                uint auOldType = (auOld & 0x3F00u) == auTag ? auOld & 3u : AU_VOX_UNKNOWN;
                // Some blocks are drawn twice (a solid block plus a cut-out overlay): solid wins,
                // or the two draws would flip the cell every frame.
                if (auOldType < AU_VOX_SOLID || (auType == AU_VOX_SOLID && auOldType == AU_VOX_POROUS))
                    imageStore(auVoxGeo, auCell, uvec4(auType | auTag | (auCorner ? 0u : AU_VOX_SMALL)));
                else if (auType == auOldType && auCorner && (auOld & AU_VOX_SMALL) != 0u)
                    imageAtomicAnd(auVoxGeo, auCell, ~AU_VOX_SMALL);
            }
#if AU_PT_LIGHTS
            // Light sources: Hytale draws glowing faces (flames, crystals) FULLBRIGHT. The first
            // such vertex of a block this frame (frame stamp in the cell's top 16 bits) adds the
            // block to this frame's light list, with Hytale's light colour there.
            vec3 auGlow = glowColorAndSunlight.rgb;
            if (shadingMode == SHADING_FULLBRIGHT && max(auGlow.r, max(auGlow.g, auGlow.b)) > 0.25)
            {
                ivec3 auLCell = auBlock & AU_VOX_MASK;
                uint auStamp = (uint(uHookFrame) & 0xFFFFu) << 16;
                uint auCur = imageLoad(auVoxGeo, auLCell).r;
                if ((auCur & 0xFFFF0000u) != auStamp
                    && imageAtomicCompSwap(auVoxGeo, auLCell, auCur, (auCur & 0xFFFFu) | auStamp) == auCur)
                {
                    int auRow = uHookFrame & 1;
                    uint auIdx = imageAtomicAdd(auLights, ivec2(0, auRow), 1u);
                    if (auIdx < AU_PT_MAX_LIGHTS)
                    {
                        imageStore(auLights, ivec2(1 + 2 * int(auIdx), auRow), uvec4(uint(auLCell.x | (auLCell.y << 8) | (auLCell.z << 15))));
                        imageStore(auLights, ivec2(2 + 2 * int(auIdx), auRow), uvec4(packUnorm4x8(vec4(auGlow, 0.0))));
                    }
                }
            }
#endif
        }
    }
#endif
