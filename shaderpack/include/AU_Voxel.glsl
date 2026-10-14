// Aurora Shaders for Hytale - voxel world for the path tracer.
//
// A 256x128x256 block grid around the player, kept by the hook (opengl32.dll) in two 3D
// images that persist across frames: auVoxGeo (what is in each block) and auVoxCol (its
// colour). The grid wraps around (block b lives in cell b & mask), so walking never needs a
// copy; every cell carries a tag of which wrap it was written for, and a cell whose tag does
// not match the block asked for reads as unknown.
//
// Writers: MapChunkVS (every block the game draws: solid / porous / partial) and DeferredFS
// (colour of what is on screen, air in front of visible block faces - this is what removes
// broken blocks). The program file needs "#extension GL_ARB_shader_image_load_store : enable"
// before anything else.
#ifndef AU_VOXEL_INC
#define AU_VOXEL_INC

#define AU_VOX_SIZE  ivec3(256, 128, 256)
#define AU_VOX_MASK  ivec3(255, 127, 255)
#define AU_VOX_SHIFT ivec3(8, 7, 8)
#define AU_VOX_HALF  ivec3(128, 64, 128)

// auVoxGeo cell: bits 0-1 type, bit 2 small model (torch, rock: no vertex on a cell corner),
// bit 3 emissive, bits 8-13 wrap tag.
#define AU_VOX_UNKNOWN 0u
#define AU_VOX_AIR     1u
#define AU_VOX_SOLID   2u
#define AU_VOX_POROUS  3u   // leaves: light gets through the gaps
#define AU_VOX_SMALL   4u
#define AU_VOX_EMISSIVE 8u

layout(r32ui) uniform uimage3D auVoxGeo;
layout(rgba8) uniform image3D auVoxCol;

// This frame's light sources (MapChunkVS): row = frame parity; texel 0 the count, then per
// light its cell (x | y << 8 | z << 15) and colour (RGBA8). DeferredFS empties the other row
// for the next frame. The top 16 bits of a light's auVoxGeo cell stamp the frame it was listed.
layout(r32ui) uniform uimage2D auLights;
#define AU_PT_MAX_LIGHTS 1024u
#ifdef AU_VOX_WRITER_ONLY
uniform int uHookFrame;
#endif

uint AU_VoxTag(ivec3 b)
{
    ivec3 k = (b >> AU_VOX_SHIFT) & 3;
    return uint(k.x | (k.y << 2) | (k.z << 4));
}

// Blocks the grid can hold right now: the window centred on the camera's block.
bool AU_VoxInWindow(ivec3 b, ivec3 camBlock)
{
    ivec3 d = b - camBlock + AU_VOX_HALF;
    return all(greaterThanEqual(d, ivec3(0))) && all(lessThan(d, AU_VOX_SIZE));
}

// Raw cell of block b, or 0 (unknown) when the cell belongs to another wrap.
uint AU_VoxGet(ivec3 b)
{
    uint v = imageLoad(auVoxGeo, b & AU_VOX_MASK).r;
    return ((v >> 8) & 63u) == AU_VoxTag(b) ? v : 0u;
}

// Albedo of block b; a = 0 when it was never seen on screen.
vec4 AU_VoxGetColor(ivec3 b)
{
    vec4 c = imageLoad(auVoxCol, b & AU_VOX_MASK);
    uint tag = uint(c.a * 255.0 + 0.5);
    return (tag & 64u) != 0u && (tag & 63u) == AU_VoxTag(b) ? vec4(c.rgb, 1.0) : vec4(0.0);
}

#ifndef AU_VOX_WRITER_ONLY

float AU_VoxHash(ivec3 b, float salt)
{
    return fract(sin(dot(vec3(b), vec3(12.9898, 78.233, 37.719)) + salt) * 43758.5453);
}

// Amanatides-Woo walk through the grid from `origin` (world space) along `dir`. Solid blocks
// stop the ray; leaves and partial blocks stop it only part of the time (`rnd` 0-1 decides,
// per block), which averages to light getting through. The start block is never tested.
// Unknown blocks count as air. Returns false when the ray leaves the grid or `maxDist`.
bool AU_VoxTrace(vec3 origin, vec3 dir, float maxDist, int maxSteps, float rnd,
                 out ivec3 hitBlock, out vec3 hitNormal, out float hitT, out uint hitCell)
{
    ivec3 camBlock = ivec3(floor(CameraPosition));
    ivec3 b = ivec3(floor(origin));
    dir = mix(dir, vec3(1e-6), lessThan(abs(dir), vec3(1e-6)));
    ivec3 stepDir = ivec3(sign(dir));
    vec3 tDelta = abs(1.0 / dir);
    vec3 tMax = (vec3(b) + max(vec3(stepDir), 0.0) - origin) / dir;
    hitBlock = b;
    hitNormal = vec3(0.0);
    hitT = 0.0;
    hitCell = 0u;
    for (int i = 0; i < maxSteps; i++) {
        // One axis per step, also on exact ties: stepping two at once slips diagonally
        // between blocks that only touch at an edge.
        vec3 mf = tMax.x < tMax.y ? (tMax.x < tMax.z ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0))
                                  : (tMax.y < tMax.z ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0));
        float t = dot(tMax, mf);
        if (t > maxDist) return false;
        b += ivec3(mf) * stepDir;
        tMax += mf * tDelta;
        if (!AU_VoxInWindow(b, camBlock)) return false;
        uint v = AU_VoxGet(b);
        uint type = v & 3u;
        if (type < AU_VOX_SOLID) continue;
        float pass = type == AU_VOX_POROUS ? 0.45 : ((v & AU_VOX_SMALL) != 0u ? 0.5 : 0.0);
        if (pass > 0.0 && fract(rnd + AU_VoxHash(b, 0.0)) < pass) continue;
        hitBlock = b;
        hitNormal = -mf * vec3(stepDir);
        hitT = t;
        hitCell = v;
        return true;
    }
    return false;
}

// DeferredFS: teaches the grid what is on screen. A tenth of the pixels per frame (`rnd`)
// blend their albedo slowly into the block behind them (a steady average of its texture), and clear a full block standing right in
// front of a visible block face - a face can only be seen when nothing solid is there, so
// that block was broken.
void AU_VoxFeed(vec3 playerPos, vec3 normal, vec3 albedo, bool foliage, bool emissive, float rnd)
{
    if (rnd > 0.1 || dot(playerPos, playerPos) > 128.0 * 128.0) return;
    ivec3 camBlock = ivec3(floor(CameraPosition));
    vec3 wp = playerPos + CameraPosition;
    // Only pixels well inside a face: at its edges the position from the depth buffer can
    // slip into the neighbouring block, which would then be coloured or cleared by mistake.
    vec3 an = abs(normal);
    vec3 axis = step(vec3(0.99), an);
    vec3 edge = abs(wp - round(wp));
    if (max(an.x, max(an.y, an.z)) > 0.99 && dot(step(edge, vec3(0.08)), 1.0 - axis) > 0.0) return;

    ivec3 inside = ivec3(floor(wp - normal * 0.08));
    uint insideCell = AU_VoxGet(inside);
    // Plants are not in the grid; their colour goes to the ground they grow on (grass
    // covers most of the ground's own pixels).
    bool plant = (insideCell & 3u) < AU_VOX_SOLID;
    if (plant) inside = ivec3(floor(wp)) - ivec3(0, 1, 0);
    // Flames and glowing pixels are not the block's colour (and animate).
    if (!emissive && AU_VoxInWindow(inside, camBlock) && (AU_VoxGet(inside) & 3u) >= AU_VOX_SOLID) {
        ivec3 c = inside & AU_VOX_MASK;
        uint tag = AU_VoxTag(inside);
        vec4 old = imageLoad(auVoxCol, c);
        uint oldTag = uint(old.a * 255.0 + 0.5);
        vec3 col = (oldTag & 64u) != 0u && (oldTag & 63u) == tag ? mix(old.rgb, albedo, 0.05) : albedo;
        imageStore(auVoxCol, c, vec4(col, float(64u | tag) / 255.0));
    }

    // Only from the face of a full block the grid knows: a grass blade standing against a
    // hill step would otherwise erase the step every frame (and the chunk pass re-add it).
    if (!plant && !foliage && (insideCell & 7u) == AU_VOX_SOLID && max(an.x, max(an.y, an.z)) > 0.99) {
        float offBoundary = dot(edge, axis);
        if (offBoundary < 0.04) {
            ivec3 front = ivec3(floor(wp + normal * 0.5));
            uint fv = AU_VoxGet(front);
            if (AU_VoxInWindow(front, camBlock) && (fv & 3u) == AU_VOX_SOLID && (fv & AU_VOX_SMALL) == 0u)
                imageStore(auVoxGeo, front & AU_VOX_MASK, uvec4(AU_VOX_AIR | (AU_VoxTag(front) << 8)));
        }
    }
}

#ifdef AU_RTX
// Sun light leaving a block face the camera can't see: the block's colour (grey until it
// has been on screen) lit by the sun when a shadow ray through the grid reaches the sky.
vec3 AU_VoxHitLight(ivec3 hb, vec3 hn, uint hv, vec3 hitWorld, float rnd)
{
    float NdotL = (hv & 3u) == AU_VOX_POROUS ? 0.6 : max0(dot(hn, lightVec));
    vec4 c = AU_VoxGetColor(hb);
    vec3 alb = c.a > 0.5 ? c.rgb : vec3(0.3);
    vec3 amb = ambientColor * (AU_PT_AMBIENT_BOUNCE * 0.5);   // its sky light is unknown off screen
    ivec3 sb; vec3 sn; float st; uint sv;
    if (AU_VoxTrace(hitWorld + hn * 0.02, lightVec, 64.0, 64, rnd, sb, sn, st, sv)) return alb * amb;
    return alb * (lightColor * NdotL + amb);
}

// Path-traced diffuse bounce + ambient occlusion through the voxel grid; same outputs as
// AU_GetSSGI (AU_RTX.glsl), which it replaces, plus the share of rays that reach the open
// sky. Rays are stratified over the cosine hemisphere with blue noise. A hit on a surface
// that is on screen takes that surface's light from the G-buffer (exact shadows, texture
// colour); hits behind objects or off screen are lit from the grid.
vec2 AU_GIHitAlbedoSky(vec2 uv);   // defined by the including program (G-buffer access)

float AU_PTHash(float salt)
{
    return fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233)) + salt + float(uHookFrame % 997) * 0.731) * 43758.5453);
}

// Direct light from this frame's light list (next event estimation): 8 random candidate
// lights, one kept in proportion to what it could give this point (resampled importance
// sampling), then a shadow ray through the grid to it. Hytale's own torch light can not do
// this: its vertex light keeps only the brighter of sunlight and glow, so by day anywhere the
// sky reaches the torches give nothing.
vec3 AU_PTDirectLight(vec3 playerPos, vec3 normal, bool flatShading, float rnd)
{
    int row = uHookFrame & 1;
    uint n = min(imageLoad(auLights, ivec2(0, row)).r, AU_PT_MAX_LIGHTS);
    if (n == 0u) return vec3(0.0);
    ivec3 base = ivec3(floor(CameraPosition)) - AU_VOX_HALF;
    vec3 wp = playerPos + CameraPosition + normal * 0.03;
    float wSum = 0.0, pickW = 0.0;
    vec3 pickPos = vec3(0.0), pickF = vec3(0.0);
    ivec3 pickBlock = ivec3(0);
    const int M = 8;
    for (int i = 0; i < M; i++) {
        uint k = min(uint(fract(rnd + float(i) * 0.618034) * float(n)), n - 1u);
        uint c = imageLoad(auLights, ivec2(1 + 2 * int(k), row)).r;
        ivec3 lb = base + ((ivec3(c & 255u, (c >> 8) & 127u, (c >> 15) & 255u) - base) & AU_VOX_MASK);
        vec3 lp = vec3(lb) + vec3(0.5, 0.6, 0.5);
        vec3 d = lp - wp;
        float dist = length(d);
        float fall = pow2(max0(1.0 - dist / AU_PT_LIGHT_RANGE));
        float nl = flatShading ? 0.7 : max0(dot(normal, d / max(dist, 0.001)));
        vec3 f = unpackUnorm4x8(imageLoad(auLights, ivec2(2 + 2 * int(k), row)).r).rgb * (fall * nl);
        float w = GetLuminance(f);
        wSum += w;
        if (w > 0.0 && AU_PTHash(float(i) * 1.37) * wSum < w) { pickW = w; pickF = f; pickPos = lp; pickBlock = lb; }
    }
    if (pickW <= 0.0) return vec3(0.0);
    vec3 d = pickPos - wp;
    float dist = length(d);
    ivec3 hb; vec3 hn; float ht; uint hv;
    if (AU_VoxTrace(wp, d / dist, dist + 0.5, 48, AU_PTHash(9.1), hb, hn, ht, hv) && hb != pickBlock) return vec3(0.0);
    return pickF / pickW * (wSum / float(M)) * float(n);
}

vec3 AU_GetVoxelGI(sampler2D depthTex, vec3 playerPos, vec3 normal, float skyLightHere,
                   out float occlusion, out float skyVis)
{
    const int rays = AU_PT_RAYS;
    const float reach = AU_PT_REACH;
    vec3 origin = playerPos + CameraPosition + normal * 0.02;
    vec2 pn = GetDither2(gl_FragCoord.xy);
    vec3 gi = vec3(0.0);
    float occluded = 0.0, escaped = 0.0;
    for (int r = 0; r < rays; r++) {
        float u1 = (float(r) + pn.x) / float(rays);
        float u2 = fract(float(r) * 0.618034 + pn.y);
        vec3 dir = AU_HemisphereDir(normal, u1, u2);
        float rnd = fract(pn.x * 13.73 + pn.y * 7.31 + float(r) * 0.381966);
        ivec3 hb; vec3 hn; float ht; uint hv;
        if (!AU_VoxTrace(origin, dir, reach, 96, rnd, hb, hn, ht, hv)) { escaped += 1.0; continue; }
        occluded += max(0.0, 1.0 - ht / AU_RTX_AO_RADIUS);
        vec3 hitRel = origin - CameraPosition + dir * ht;
        vec2 uv = AU_ProjectToScreen(hitRel);
        float slin = all(greaterThan(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0))) ? AU_SceneLinAt(depthTex, uv) : -1.0;
        float lin = AU_LinOf(hitRel);
        bool onScreen = slin > AU_NEAR_IGNORE && abs(slin - lin) < 0.35 + lin * 0.01;
        vec3 light = onScreen ? AU_GIHitLight(uv) : AU_VoxHitLight(hb, hn, hv, hitRel + CameraPosition, rnd);
        // A hit surface passes on part of the sky light it gets itself (more bounces):
        // its albedo x its sky light (off screen: this pixel's).
        vec4 hitCol = onScreen ? vec4(0.0) : AU_VoxGetColor(hb);
        vec2 hitAS = onScreen ? AU_GIHitAlbedoSky(uv) : vec2(hitCol.a > 0.5 ? GetLuminance(hitCol.rgb) : 0.3, skyLightHere);
        escaped += hitAS.x * smoothstep1(clamp(hitAS.y, 0.0, 1.0));
        gi += min(light, vec3(1.5)) * (0.5 + 0.5 * (1.0 - ht / reach));
    }
    occlusion = 1.0 - occluded / float(rays);
    skyVis = escaped / float(rays);
    return gi / float(rays);
}

// Temporal accumulation of the path tracer's output (history kept by the hook, see
// hook.c gi_bind): each pixel finds where its surface was last frame (Hytale's
// ReprojectionMatrix) and averages with what was accumulated there, over up to
// AU_PT_HISTORY frames. The history stores the world position it belongs to; a pixel whose
// surface was not there last frame (disocclusion, moving things) starts over.
uniform sampler2D auGIHist;      // last frame: bounce rgb, sky visibility
uniform sampler2D auGIHistPos;   // last frame: world position, frames + AO fraction
uniform sampler2D auGIHistLight; // last frame: direct light from the light list
layout(rgba16f) uniform image2D auGIOut;
layout(rgba32f) uniform image2D auGIOutPos;
layout(rgba16f) uniform image2D auGIOutLight;

void AU_PTAccumulate(vec3 playerPos, inout vec3 gi, inout float occlusion, inout float skyVis, inout vec3 directLight)
{
    vec3 wp = playerPos + CameraPosition;
    vec4 prev = ReprojectionMatrix * vec4((ViewMatrix * vec4(playerPos, 1.0)).xyz, 1.0);
    vec2 puv = prev.xy / prev.w * 0.5 + 0.5;
    float len = 0.0, histAO = 1.0;
    vec4 hist = vec4(0.0);
    vec3 histLight = vec3(0.0);
    if (all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0)))) {
        ivec2 pp = ivec2(puv * vec2(textureSize(auGIHistPos, 0)));
        vec4 hp = texelFetch(auGIHistPos, pp, 0);
        if (distance(hp.xyz, wp) < 0.06 + length(playerPos) * 0.006) {
            len = floor(hp.w);
            histAO = fract(hp.w) / 0.999;
            hist = texelFetch(auGIHist, pp, 0);
            histLight = texelFetch(auGIHistLight, pp, 0).rgb;
        }
    }
    len = min(len + 1.0, AU_PT_HISTORY);
    float w = 1.0 / len;
    vec4 acc = mix(hist, vec4(gi, skyVis), w);
    occlusion = mix(histAO, clamp(occlusion, 0.0, 1.0), w);
    ivec2 pix = ivec2(gl_FragCoord.xy);
    imageStore(auGIOut, pix, acc);
    imageStore(auGIOutPos, pix, vec4(wp, len + occlusion * 0.999));
    directLight = mix(histLight, directLight, w);
    imageStore(auGIOutLight, pix, vec4(directLight, 1.0));
    gi = acc.rgb;
    skyVis = acc.a;
}
#endif // AU_RTX

#endif // !AU_VOX_WRITER_ONLY

#endif // AU_VOXEL_INC
