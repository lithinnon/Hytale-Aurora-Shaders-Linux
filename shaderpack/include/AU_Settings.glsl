// Aurora Shaders for Hytale - settings.
// Saving this file hot-reloads every shader in the game.

#ifndef AU_SETTINGS
#define AU_SETTINGS

// ---- Preset --------------------------------------------------------------------------
// 1 = Standard
// 2 = RTX: + screen-space global illumination, glossy reflections on all solid surfaces,
//          more shadow / light shaft / cloud samples
#define AU_PRESET 2

// ---- General -------------------------------------------------------------------------
#define AU_SUN_MAX_ELEVATION 0.92   // sin(max sun elevation) of Hytale's sun path, maps time-of-day factors
#define AU_SCREEN_BRIGHTNESS 1.00    // Minecraft "brightness" slider equivalent (0 = moody, 1 = bright)
#define AU_TWILIGHT_SHIFT 0.10      // keeps daylight up longer to fit Hytale's long dusk
#define AU_SUNSET_SHIFT 0.0         // sun height (sin) offset for the sunset colour palette

// ---- Lighting ------------------------------------------------------------------------
#define AU_ALBEDO_MULT 0.78          // Hytale textures are painted brighter than Minecraft's
#define AU_ALBEDO_SATURATION 0.92
#define AU_SIDE_SHADOWING 1
#define AU_DIRECTIONAL_SHADING 1
#define AU_BLOCKLIGHT_STRENGTH 1.0
#define AU_BLOCKLIGHT_RANGE 1.75       // Hytale glow -> Minecraft lightmap scale
#define AU_BLOCKLIGHT_HYTALE_HUE 1.0 // 0 = warm torch light, 1 = Hytale's per-light colours
#define AU_EMISSION_STRENGTH 3.00
#define AU_EMISSIVE_MAX 1.6           // brightest a glowing ore texel gets (keeps its colour; the glow is bloom)
#define AU_EMISSIVE_BLOOM 4.0        // extra bloom for emissive blocks (flames, potions, lava)
#define AU_ORE_GLOW 1                 // ore specks glow (1), 2 = debug: every REFLECTIVE block glows
#define AU_ORE_GLOW_STRENGTH 2.0
#define AU_ORE_BLOOM 10.0             // coloured glow halo around ore crystals
#define AU_ORE_LIGHT 8.0              // light ore crystals cast on what is around them (RTX preset)
#define AU_ORE_SHINE 1.0              // Hytale's sweeping glint over ores (near chunks)
#define AU_MATERIALS 1                // block materials: polished stone/bricks/planks/ice gloss, metal reflections, rain soaking
#define AU_MATERIAL_GLOSS 1.0
#define AU_RAIN_WETNESS 1.0           // how wet and glossy rain makes everything open to the sky
#define AU_ORE_GLOSS 1.0              // ore crystals glossy like gems (sun glints, reflections)
#define AU_SSAO_STRENGTH 1.25
#define AU_CAVE_LIGHTING 250.0        // minimum light underground, %
#define AU_SUBSURFACE 1              // foliage translucency
#define AU_SUBSURFACE_GLOW 0.35
#define AU_GENERATED_NORMALS 1        // per-texel relief from block textures
#define AU_GENERATED_NORMAL_MULT 100.0  // relief strength (25-400)
#define AU_GENERATED_NORMAL_RES 128.0   // relief resolution (16-512)
#define AU_LIGHT_HIGHLIGHT 1         // soft GGX sun highlight

// ---- Shadows -------------------------------------------------------------------------
#if AU_PRESET >= 2
#define AU_SHADOW_SAMPLES 24
#else
#define AU_SHADOW_SAMPLES 12         // PCF taps for soft shadows
#endif
#define AU_SHADOW_SOFTNESS 1.0
#define AU_SHADOW_CASCADES 4
#if AU_PRESET >= 2
#define AU_PCSS 1                    // contact-hardening shadows (needs the hook's raw shadow share)
#else
#define AU_PCSS 0
#endif
#define AU_PCSS_SEARCH 9.0           // max penumbra / blocker search radius in shadow texels
#define AU_PCSS_SCALE 900.0          // shadow-depth difference -> penumbra texels
#define AU_CONTACT_SHADOWS 1         // screen-space shadows for grass/plants (not in Hytale's shadow map)
#define AU_CONTACT_SHADOW_LENGTH 1.6
#define AU_CONTACT_SHADOW_STEPS 18
#define AU_CONTACT_SHADOW_DISTANCE 480.0
#define AU_FAR_SHADOWS 1              // screen-space shadows past the shadow map
#define AU_CLOTH_TRANSMIT 0.5         // sun through cloth and other two-sided models (a curtain shows the window behind it)
#define AU_FAR_SHADOW_STEPS 32
#define AU_NEAR_IGNORE 1.2             // depth (blocks) below which geometry is the first-person hand

// ---- Sky / atmosphere ----------------------------------------------------------------
#define AU_STARS 2                    // 0 off, 1 procedural, 2 Hytale's star texture (turning with the sky)
#define AU_STARS_BRIGHTNESS 2.0
#define AU_MOON_GLOW 1.0              // Hytale's halo around the moon
#define AU_STARS_SCALE 1.0             // star texture size on the sky (lower = bigger stars)
#define AU_NIGHT_SKY_SATURATION 3.0   // night horizon colour (1 = grey-blue, higher = deep blue)
#define AU_ATMOSPHERIC_FOG 1
#define AU_ATM_FOG_MULT 0.95
#define AU_ATM_FOG_DISTANCE 1.0
#define AU_BORDER_FOG 1
#define AU_CAVE_ALTITUDE 95.0        // below this height with no sky light around = cave (cave fog)
#define AU_RAINBOWS 1                // rainbow opposite the sun after rain (morning / evening)
#define AU_RAINBOW_DIAMETER 1.0
#define AU_HYTALE_SKY_TINT 0.15      // how much Hytale's biome/weather sky colour bleeds into the palette

// ---- Clouds (Unbound style volumetric) -----------------------------------------------
#define AU_CLOUDS 1
#define AU_CLOUD_ALT1 300.0          // world height of the first cloud layer
#define AU_CLOUD_ALT2 340.0          // second layer (set AU_CLOUD_LAYERS 1 to disable)
#define AU_CLOUD_LAYERS 2
#define AU_CLOUD_AMOUNT 1.0
#define AU_CLOUD_SPEED 1.00
#if AU_PRESET >= 2
#define AU_CLOUD_STEP 14.0
#else
#define AU_CLOUD_STEP 32.0           // ray step in blocks (lower = better quality, slower)
#endif
#define AU_CLOUD_DISTANCE 2400.0
#define AU_CLOUD_SHADOWS 1
#define AU_CLOUD_SHADOW_STRENGTH 1.0

// ---- Volumetric light ----------------------------------------------------------------
#define AU_LIGHTSHAFTS 1
#if AU_PRESET >= 2
#define AU_LIGHTSHAFT_SAMPLES 28
#else
#define AU_LIGHTSHAFT_SAMPLES 12
#endif
#define AU_LIGHTSHAFT_STRENGTH 1.0
#define AU_LIGHTSHAFT_HAZE 0.4         // open-air haze (beams through trees / windows are separate)
#define AU_LIGHTSHAFT_DISTANCE 192.0
#define AU_LIGHTSHAFT_SCENE_AWARE 1.00  // stronger shafts in caves / forests (0 = off)
#define AU_LIGHTSHAFT_NOON_I 1.0
#define AU_LIGHTSHAFT_SUNSET_I 0.5    // low-sun haze (the low sun's light colour is strong; 1.0 drowned the land)
#define AU_LIGHTSHAFT_NIGHT_I 0.35     // moonlight haze (1.0 washes Hytale nights out)
#define AU_LIGHTSHAFT_SCENE_BOOST 1.0  // extra shaft strength under canopies / in caves (0 = off)

// ---- Water ---------------------------------------------------------------------------
#define AU_WATER 1
#define AU_GLASS 1                    // glass tints and reflects what is behind it
#define AU_GLASS_TINT 0.7
#define AU_GLASS_ABSORB 0.35            // how much light glass takes away from the view through it
#define AU_GLASS_REFLECT 0.8
#define AU_WATER_FOG_MULT 1.0
#define AU_WATER_SSR_STEPS 48
#define AU_WATER_REFRACTION 2.00       // refraction strength
#define AU_WATER_FOAM 0.5              // shoreline foam
#define AU_WATER_CAUSTICS 1          // Unbound caustics on sunlit surfaces while the camera is under water
#define AU_CAUSTICS_STRENGTH 1.4
#define AU_DEBUG_WATER 0

// ---- Rain puddles ---------------------------------------------------------------------
#define AU_RAIN_PUDDLES 1             // reflective puddles while wet
#define AU_RAIN_PUDDLE_STRENGTH 1.0

// ---- RTX preset ----------------------------------------------------------------------
#define AU_RTX_GI_RAYS 8
#define AU_RTX_GI_RADIUS 8.0
#define AU_RTX_GI_STRENGTH 1.0
#define AU_RTX_GI_EMISSIVE 1.0       // bounce from emissive blocks (torch flames, lava)
#define AU_RTX_AO_RADIUS 2.5        // reach (blocks) of the ray-traced AO
#define AU_RTX_GI_AO 0.55          // how much the GI rays darken occluded ambient
#define AU_RTX_SSR_STEPS 32
#define AU_RTX_SMOOTHNESS 0.0          // dry surfaces stay matte (only rain makes them reflective)

// ---- Path tracing (RTX preset) -------------------------------------------------------
// Voxel path tracing: the hook keeps a 256x128x256 block grid of the world around the
// player (include/AU_Voxel.glsl) and the bounce light traces rays through it.
#define AU_PATH_TRACING 1             // experimental: heavy, and the look is close to the screen-space GI
#define AU_PT_GI_STRENGTH 1.5         // bounce light strength with path tracing
#define AU_VOXELS (AU_PRESET >= 2 && AU_PATH_TRACING)
#define AU_PT_RAYS 3                  // rays per pixel per frame
#define AU_PT_REACH 24.0              // how far (blocks) rays travel
#define AU_PT_HISTORY 24.0            // frames the path tracer averages over (more = smoother, slower to react)
#define AU_PT_SKY_LIGHT 0.8           // how much the traced sky visibility shapes the ambient light
#define AU_PT_LIGHTS 0                // experimental: path-traced light from FULLBRIGHT blocks (misses torches, they are models)
#define AU_PT_LIGHT_STRENGTH 1.50
#define AU_PT_LIGHT_RANGE 14.0        // blocks
#define AU_PT_AMBIENT_BOUNCE 1.0      // how much sky light bounced surfaces pass on (multiple bounces)
#define AU_VOXEL_DEBUG 0              // 1 = show the voxel grid (ray cast from the camera), 2 = blend over the scene

// ---- Post ----------------------------------------------------------------------------
#define AU_TM_EXPOSURE 1.00
#define AU_TM_CONTRAST 1.10
#define AU_TM_WHITE_PATH 1.00
#define AU_TM_DARK_DESATURATION 0.25
#define AU_SATURATION 1.00
#define AU_VIBRANCE 1.00
#define AU_BLOOM 1
#define AU_BLOOM_STRENGTH 0.12
#define AU_BLOOM_FOG 1                // glowing haze at night, in rain, caves and underwater
#define AU_KEEP_HYTALE_GRADING 0.6   // how much of Hytale's per-biome colour filter/saturation to keep
#define AU_VIGNETTE 1
#define AU_LENSFLARE 1                // lens flare (sun and moon)
#define AU_LENSFLARE_I 2.50             // lens flare strength
#define AU_SUN_GLARE 1.0              // soft lens glare around the visible sun
#define AU_TAA 1                      // reprojected TAA (cleans up dithered shafts / shadows / GI)
#define AU_DLSS 0                     // NVIDIA DLSS instead of the TAA (hook/aud_dlss.c; RTX GPUs)
#define AU_DLSS_RR 0                  // DLSS Ray Reconstruction (denoiser + upscaler in one) instead of Super Resolution
#define AU_RENDER_SCALE 0            // hook: Hytale's Render Scale = DLSS render size, written for the next start (0 = Hytale's slider)
#define AU_DLSS_PRESET 0              // hook: DLSS model, 0 NVIDIA's default, 1 sharpest (K / RR E), 2 less ghosting (J / RR D)
#define AU_DLSS_JITTER 1              // hook: sub-pixel camera jitter while DLSS runs
#define AU_DLSS_JITTER_SX 1           // hook: sign of the jitter handed to DLSS (axis conventions)
#define AU_DLSS_JITTER_SY 1
#define AU_DLSS_MOTION_SX 1           // hook: sign of the motion vectors handed to DLSS
#define AU_DLSS_MOTION_SY 1
#define AU_DLSS_DEBUG 0               // hook: 1 = show DLSS's colour input, 2 = reset every frame, 3 = depth, 4 = motion
#define AU_DLSS_DEPTH_HW 0            // hand DLSS hardware-style (non-linear) depth instead of linear
#define AU_TAA_BLEND 0.93             // history weight (higher = smoother, softer motion)
#define AU_TAA_CLIP 1.25              // neighbourhood variance clip (lower = less ghosting)
#define AU_SHARPENING 2               // image sharpening (0-10)

#define AU_DEBUG_CLASS 0
#define AU_DEBUG_TAA 0
//#define AU_DEBUG_FAKE_SUN 0.9     // debug: force a sun elevation (sin)
#define AU_DEBUG 0                   // on-screen value bars (top-left)

#endif
