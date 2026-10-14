// Aurora Shaders - DLSS bridge (aud_dlss.c): NVIDIA DLSS on a private Vulkan device whose
// images are shared with the game's OpenGL context. All functions run on the GL thread with
// the game's context current.
#ifndef AUD_DLSS_H
#define AUD_DLSS_H

typedef void (*AudLogFn)(const char *fmt, ...);
typedef void *(*AudGetProcFn)(const char *name);   // GL entry points (core and extensions)

// Shared images, as GL textures. Inputs at render size, AUD_TEX_OUTPUT at output size.
enum {
    AUD_TEX_COLOR,      // RGBA16F scene colour
    AUD_TEX_DEPTH,      // R32F depth (hardware depth convention: 0 near, 1 far)
    AUD_TEX_MOTION,     // RG16F motion vectors, pixels from this frame to the last (render size)
    AUD_TEX_OUTPUT,     // RGBA16F upscaled result (output size)
    // Ray Reconstruction guides (render size, only with ray reconstruction):
    AUD_TEX_ALBEDO,     // RGBA8 diffuse albedo
    AUD_TEX_SPECULAR,   // RGBA8 specular albedo
    AUD_TEX_NORMALS,    // RGBA16F world-space normal, linear roughness in alpha
    AUD_TEX_COUNT
};

// Vulkan device + NGX core; dllDir holds nvngx_dlss.dll, dataDir gets NGX's log/cache.
// Returns 1 when DLSS super resolution is available on this machine.
int aud_init(AudLogFn log, AudGetProcFn glGetProc, const wchar_t *dllDir, const wchar_t *dataDir);

// 1 when DLSS Ray Reconstruction is available too (after aud_init).
int aud_rr_available(void);

// (Re)creates the DLSS feature and the shared images. quality: NVSDK_NGX_PerfQuality_Value.
// rr: Ray Reconstruction (DLSS-D, reads the guide images too) instead of Super Resolution.
// preset: the model (NVSDK_NGX_DLSS_Hint_Render_Preset / RayReconstruction one), 0 = default.
int aud_configure(int renderW, int renderH, int outW, int outH, int quality, int hdr, int rr, int preset);

unsigned aud_texture(int which);

// Hands this frame's inputs (already written into the shared textures) to DLSS and makes
// the GL context wait, on the GPU, until the output is ready. jitter in pixels; mvScale
// converts the motion texture into pixels; reset after camera cuts.
int aud_evaluate(float jitterX, float jitterY, float mvScaleX, float mvScaleY, int reset);

void aud_shutdown(void);

#endif
