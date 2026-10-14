// Aurora Shaders - DLSS bridge.
//
// Hytale renders with OpenGL 4.1, and DLSS only exists for D3D11/12 and Vulkan. This file
// creates a Vulkan device on the same GPU, loads NVIDIA's NGX core from the driver
// (_nvngx.dll) and creates the DLSS feature there. NVIDIA's SDK library only wraps the
// driver's exports and is MSVC-only, so they are called directly: the signatures and the
// NVSDK_NGX_Parameter method table order follow the SDK 310.9 library.
//
// The images DLSS reads and writes are Vulkan images with exportable memory, imported into
// OpenGL as textures (EXT_memory_object_win32). Two shared semaphores (EXT_semaphore_win32)
// order the work on the GPU: GL signals when the inputs are written, Vulkan runs DLSS and
// signals back, GL waits before reading the output. The CPU never waits for the GPU.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <wchar.h>
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include "nvsdk_ngx_defs.h"
#include "nvsdk_ngx_defs_vk.h"
#include "nvsdk_ngx_defs_dlssd.h"
#include "aud_dlss.h"

static AudLogFn g_log;
#define LOG(...) do { if (g_log) g_log(__VA_ARGS__); } while (0)

// ----------------------------------------------------------------------------------------
// Vulkan entry points

static PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr_;
#define VK_FUNCS(X) \
    X(vkCreateInstance) X(vkEnumerateInstanceExtensionProperties) X(vkDestroyInstance) \
    X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties2) X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkGetPhysicalDeviceMemoryProperties) X(vkGetPhysicalDeviceFeatures2) X(vkEnumerateDeviceExtensionProperties) \
    X(vkCreateDevice) X(vkGetDeviceProcAddr) X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkDeviceWaitIdle) \
    X(vkCreateCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
    X(vkResetCommandBuffer) X(vkQueueSubmit) X(vkQueueWaitIdle) X(vkCreateFence) X(vkWaitForFences) \
    X(vkResetFences) X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) X(vkAllocateMemory) \
    X(vkFreeMemory) X(vkBindImageMemory) X(vkCreateImageView) X(vkDestroyImageView) \
    X(vkGetMemoryWin32HandleKHR) X(vkCreateSemaphore) X(vkGetSemaphoreWin32HandleKHR) X(vkCmdPipelineBarrier)
#define VK_DECL(n) static PFN_##n n##_;
VK_FUNCS(VK_DECL)

static VkInstance g_inst;
static VkPhysicalDevice g_phys;
static VkDevice g_dev;
static VkQueue g_queue;
static uint32_t g_qfam;
static VkCommandPool g_pool;
#define AUD_FRAMES 3
static VkCommandBuffer g_cmd[AUD_FRAMES];
static VkFence g_fence[AUD_FRAMES];
static int g_frameIdx;
static VkPhysicalDeviceMemoryProperties g_memProps;

// ----------------------------------------------------------------------------------------
// NGX core (driver) entry points

typedef NVSDK_NGX_Result (*PFN_NGX_RequiredExtensions)(unsigned int *, const char ***, unsigned int *, const char ***);
typedef NVSDK_NGX_Result (*PFN_NGX_Init_ProjectID_Ext)(const char *, NVSDK_NGX_EngineType, const char *, const wchar_t *,
                                                       VkInstance, VkPhysicalDevice, VkDevice, PFN_vkGetInstanceProcAddr,
                                                       PFN_vkGetDeviceProcAddr, NVSDK_NGX_Version, const NVSDK_NGX_FeatureCommonInfo *);
typedef NVSDK_NGX_Result (*PFN_NGX_Shutdown1)(VkDevice);
typedef NVSDK_NGX_Result (*PFN_NGX_GetParams)(NVSDK_NGX_Parameter **);
typedef NVSDK_NGX_Result (*PFN_NGX_DestroyParameters)(NVSDK_NGX_Parameter *);
typedef NVSDK_NGX_Result (*PFN_NGX_CreateFeature1)(VkDevice, VkCommandBuffer, NVSDK_NGX_Feature, NVSDK_NGX_Parameter *, NVSDK_NGX_Handle **);
typedef NVSDK_NGX_Result (*PFN_NGX_EvaluateFeature)(VkCommandBuffer, const NVSDK_NGX_Handle *, const NVSDK_NGX_Parameter *, void *);
typedef NVSDK_NGX_Result (*PFN_NGX_ReleaseFeature)(NVSDK_NGX_Handle *);

static HMODULE g_ngx;
static PFN_NGX_RequiredExtensions ngxRequiredExtensions;
static PFN_NGX_Init_ProjectID_Ext ngxInit;
static PFN_NGX_Shutdown1 ngxShutdown1;
static PFN_NGX_GetParams ngxGetCapabilityParameters, ngxAllocateParameters;
static PFN_NGX_DestroyParameters ngxDestroyParameters;
static PFN_NGX_CreateFeature1 ngxCreateFeature1;
static PFN_NGX_EvaluateFeature ngxEvaluateFeature;
static PFN_NGX_ReleaseFeature ngxReleaseFeature;

// NVSDK_NGX_Parameter is a C++ interface; MSVC lists overloaded virtuals in reverse order:
// Set(void*) 0, Set(int) 3, Set(unsigned) 4, Set(float) 6, Get(void**) 8, Get(int*) 11,
// Get(unsigned*) 12, Get(float*) 14.
#define NGX_VT(p) (*(void ***)(p))
static void ngx_set_ptr(NVSDK_NGX_Parameter *p, const char *n, void *v) { ((void (*)(void *, const char *, void *))NGX_VT(p)[0])(p, n, v); }
static void ngx_set_i(NVSDK_NGX_Parameter *p, const char *n, int v) { ((void (*)(void *, const char *, int))NGX_VT(p)[3])(p, n, v); }
static void ngx_set_ui(NVSDK_NGX_Parameter *p, const char *n, unsigned v) { ((void (*)(void *, const char *, unsigned))NGX_VT(p)[4])(p, n, v); }
static void ngx_set_f(NVSDK_NGX_Parameter *p, const char *n, float v) { ((void (*)(void *, const char *, float))NGX_VT(p)[6])(p, n, v); }
static NVSDK_NGX_Result ngx_get_i(NVSDK_NGX_Parameter *p, const char *n, int *v) { return ((NVSDK_NGX_Result (*)(void *, const char *, int *))NGX_VT(p)[11])(p, n, v); }
static NVSDK_NGX_Result ngx_get_ui(NVSDK_NGX_Parameter *p, const char *n, unsigned *v) { return ((NVSDK_NGX_Result (*)(void *, const char *, unsigned *))NGX_VT(p)[12])(p, n, v); }

static NVSDK_NGX_Parameter *g_params;
static NVSDK_NGX_Handle *g_feature;
static int g_ngxReady;
static int g_rrAvailable, g_rr;   // Ray Reconstruction available / the configured feature is RR

// ----------------------------------------------------------------------------------------
// GL interop entry points

typedef unsigned int GLuint;
typedef int GLint;
typedef unsigned int GLenum;
typedef int GLsizei;
typedef unsigned long long GLuint64;
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE_BINDING_2D 0x8069
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_NEAREST 0x2600
#define GL_LINEAR 0x2601
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_RGBA16F 0x881A
#define GL_R32F 0x822E
#define GL_RG16F 0x822F
#define GL_RGBA8 0x8058
#define GL_HANDLE_TYPE_OPAQUE_WIN32_EXT 0x9587
#define GL_DEDICATED_MEMORY_OBJECT_EXT 0x9581
#define GL_LAYOUT_GENERAL_EXT 0x958D
#define GL_NUM_DEVICE_UUIDS_EXT 0x9596
#define GL_DEVICE_UUID_EXT 0x9597
#define GLAPI __stdcall
typedef void (GLAPI *PFN_glCreateMemoryObjectsEXT)(GLsizei, GLuint *);
typedef void (GLAPI *PFN_glDeleteMemoryObjectsEXT)(GLsizei, const GLuint *);
typedef void (GLAPI *PFN_glMemoryObjectParameterivEXT)(GLuint, GLenum, const GLint *);
typedef void (GLAPI *PFN_glImportMemoryWin32HandleEXT)(GLuint, GLuint64, GLenum, void *);
typedef void (GLAPI *PFN_glTexStorageMem2DEXT)(GLenum, GLsizei, GLenum, GLsizei, GLsizei, GLuint, GLuint64);
typedef void (GLAPI *PFN_glGenSemaphoresEXT)(GLsizei, GLuint *);
typedef void (GLAPI *PFN_glImportSemaphoreWin32HandleEXT)(GLuint, GLenum, void *);
typedef void (GLAPI *PFN_glSignalSemaphoreEXT)(GLuint, GLuint, const GLuint *, GLuint, const GLuint *, const GLenum *);
typedef void (GLAPI *PFN_glWaitSemaphoreEXT)(GLuint, GLuint, const GLuint *, GLuint, const GLuint *, const GLenum *);
typedef void (GLAPI *PFN_glGetUnsignedBytei_vEXT)(GLenum, GLuint, unsigned char *);
typedef void (GLAPI *PFN_glGenTextures)(GLsizei, GLuint *);
typedef void (GLAPI *PFN_glDeleteTextures)(GLsizei, const GLuint *);
typedef void (GLAPI *PFN_glBindTexture)(GLenum, GLuint);
typedef void (GLAPI *PFN_glTexParameteri)(GLenum, GLenum, GLint);
typedef void (GLAPI *PFN_glGetIntegerv)(GLenum, GLint *);
typedef void (GLAPI *PFN_glFlush)(void);

static struct {
    PFN_glCreateMemoryObjectsEXT CreateMemoryObjects;
    PFN_glDeleteMemoryObjectsEXT DeleteMemoryObjects;
    PFN_glMemoryObjectParameterivEXT MemoryObjectParameteriv;
    PFN_glImportMemoryWin32HandleEXT ImportMemoryWin32Handle;
    PFN_glTexStorageMem2DEXT TexStorageMem2D;
    PFN_glGenSemaphoresEXT GenSemaphores;
    PFN_glImportSemaphoreWin32HandleEXT ImportSemaphoreWin32Handle;
    PFN_glSignalSemaphoreEXT SignalSemaphore;
    PFN_glWaitSemaphoreEXT WaitSemaphore;
    PFN_glGetUnsignedBytei_vEXT GetUnsignedBytei_v;
    PFN_glGenTextures GenTextures;
    PFN_glDeleteTextures DeleteTextures;
    PFN_glBindTexture BindTexture;
    PFN_glTexParameteri TexParameteri;
    PFN_glGetIntegerv GetIntegerv;
    PFN_glFlush Flush;
} gl;

// ----------------------------------------------------------------------------------------
// Shared images and semaphores

typedef struct {
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkFormat format;
    unsigned w, h;
    GLuint glTex, glMem;
    NVSDK_NGX_Resource_VK res;
} AudImage;

static AudImage g_img[AUD_TEX_COUNT];
static VkSemaphore g_semGLDone, g_semVKDone;
static GLuint g_glSemGLDone, g_glSemVKDone;
static int g_renderW, g_renderH, g_outW, g_outH;

static uint32_t find_memory_type(uint32_t bits, VkMemoryPropertyFlags want)
{
    for (uint32_t i = 0; i < g_memProps.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (g_memProps.memoryTypes[i].propertyFlags & want) == want) return i;
    return UINT32_MAX;
}

static void destroy_image(AudImage *im)
{
    if (im->glTex) gl.DeleteTextures(1, &im->glTex);
    if (im->glMem) gl.DeleteMemoryObjects(1, &im->glMem);
    if (im->view) vkDestroyImageView_(g_dev, im->view, NULL);
    if (im->image) vkDestroyImage_(g_dev, im->image, NULL);
    if (im->memory) vkFreeMemory_(g_dev, im->memory, NULL);
    memset(im, 0, sizeof(*im));
}

static int create_image(AudImage *im, unsigned w, unsigned h, VkFormat vkFmt, GLenum glFmt)
{
    VkExternalMemoryImageCreateInfo ext = {VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
    ext.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    VkImageCreateInfo ici = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &ext};
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = vkFmt;
    ici.extent.width = w;
    ici.extent.height = h;
    ici.extent.depth = 1;
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage_(g_dev, &ici, NULL, &im->image) != VK_SUCCESS) { LOG("dlss: vkCreateImage failed"); return 0; }

    VkMemoryRequirements req;
    vkGetImageMemoryRequirements_(g_dev, im->image, &req);
    VkMemoryDedicatedAllocateInfo ded = {VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
    ded.image = im->image;
    VkExportMemoryAllocateInfo exp = {VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO, &ded};
    exp.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &exp};
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = find_memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory_(g_dev, &mai, NULL, &im->memory) != VK_SUCCESS) {
        LOG("dlss: vkAllocateMemory failed");
        return 0;
    }
    vkBindImageMemory_(g_dev, im->image, im->memory, 0);

    VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    vci.image = im->image;
    vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vci.format = vkFmt;
    vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    vci.subresourceRange.levelCount = 1;
    vci.subresourceRange.layerCount = 1;
    if (vkCreateImageView_(g_dev, &vci, NULL, &im->view) != VK_SUCCESS) { LOG("dlss: vkCreateImageView failed"); return 0; }

    VkMemoryGetWin32HandleInfoKHR hi = {VK_STRUCTURE_TYPE_MEMORY_GET_WIN32_HANDLE_INFO_KHR};
    hi.memory = im->memory;
    hi.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    HANDLE handle = NULL;
    if (vkGetMemoryWin32HandleKHR_(g_dev, &hi, &handle) != VK_SUCCESS || !handle) { LOG("dlss: memory export failed"); return 0; }

    gl.CreateMemoryObjects(1, &im->glMem);
    GLint dedicated = 1;
    gl.MemoryObjectParameteriv(im->glMem, GL_DEDICATED_MEMORY_OBJECT_EXT, &dedicated);
    gl.ImportMemoryWin32Handle(im->glMem, req.size, GL_HANDLE_TYPE_OPAQUE_WIN32_EXT, handle);
    CloseHandle(handle);
    GLint prev = 0;
    gl.GetIntegerv(GL_TEXTURE_BINDING_2D, &prev);
    gl.GenTextures(1, &im->glTex);
    gl.BindTexture(GL_TEXTURE_2D, im->glTex);
    gl.TexStorageMem2D(GL_TEXTURE_2D, 1, glFmt, (GLsizei)w, (GLsizei)h, im->glMem, 0);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl.BindTexture(GL_TEXTURE_2D, (GLuint)prev);

    im->format = vkFmt;
    im->w = w;
    im->h = h;
    memset(&im->res, 0, sizeof(im->res));
    im->res.Resource.ImageViewInfo.ImageView = im->view;
    im->res.Resource.ImageViewInfo.Image = im->image;
    im->res.Resource.ImageViewInfo.SubresourceRange = vci.subresourceRange;
    im->res.Resource.ImageViewInfo.Format = vkFmt;
    im->res.Resource.ImageViewInfo.Width = w;
    im->res.Resource.ImageViewInfo.Height = h;
    im->res.Type = NVSDK_NGX_RESOURCE_VK_TYPE_VK_IMAGEVIEW;
    im->res.ReadWrite = true;
    return 1;
}

static int create_semaphore(VkSemaphore *vk, GLuint *glSem)
{
    VkExportSemaphoreCreateInfo exp = {VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO};
    exp.handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    VkSemaphoreCreateInfo sci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &exp};
    if (vkCreateSemaphore_(g_dev, &sci, NULL, vk) != VK_SUCCESS) return 0;
    VkSemaphoreGetWin32HandleInfoKHR hi = {VK_STRUCTURE_TYPE_SEMAPHORE_GET_WIN32_HANDLE_INFO_KHR};
    hi.semaphore = *vk;
    hi.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    HANDLE handle = NULL;
    if (vkGetSemaphoreWin32HandleKHR_(g_dev, &hi, &handle) != VK_SUCCESS || !handle) return 0;
    gl.GenSemaphores(1, glSem);
    gl.ImportSemaphoreWin32Handle(*glSem, GL_HANDLE_TYPE_OPAQUE_WIN32_EXT, handle);
    CloseHandle(handle);
    return 1;
}

// ----------------------------------------------------------------------------------------
// Initialisation

static void NVSDK_CONV ngx_log_cb(const char *message, NVSDK_NGX_Logging_Level level, NVSDK_NGX_Feature component)
{
    (void)level;
    (void)component;
    char line[512];
    snprintf(line, sizeof(line), "%s", message);
    size_t n = strlen(line);
    while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
    LOG("ngx: %s", line);
}

static HMODULE load_ngx_core(void)
{
    static const struct { const wchar_t *key, *value; } regs[] = {
        {L"SYSTEM\\CurrentControlSet\\Services\\nvlddmkm\\Parameters\\NGXCore", L"NGXPath"},
        {L"SYSTEM\\CurrentControlSet\\Services\\nvlddmkm\\NGXCore", L"NGXPath"},
        {L"SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore", L"FullPath"},
    };
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    for (int i = 0; i < 3; i++) {
        DWORD sz = sizeof(dir);
        if (RegGetValueW(HKEY_LOCAL_MACHINE, regs[i].key, regs[i].value, RRF_RT_REG_SZ, NULL, dir, &sz) != ERROR_SUCCESS) continue;
        _snwprintf(path, MAX_PATH, L"%ls\\_nvngx.dll", dir);
        HMODULE m = LoadLibraryW(path);
        if (m) return m;
    }
    // The NVIDIA OpenGL/Vulkan driver lives in the same driver-store folder.
    HMODULE drv = GetModuleHandleW(L"nvoglv64.dll");
    if (drv && GetModuleFileNameW(drv, dir, MAX_PATH)) {
        wchar_t *slash = wcsrchr(dir, L'\\');
        if (slash) *slash = 0;
        _snwprintf(path, MAX_PATH, L"%ls\\_nvngx.dll", dir);
        HMODULE m = LoadLibraryW(path);
        if (m) return m;
    }
    return NULL;
}

static int has_ext(const char *name, const char **list, unsigned n)
{
    for (unsigned i = 0; i < n; i++) if (!strcmp(list[i], name)) return 1;
    return 0;
}

int aud_init(AudLogFn log, AudGetProcFn glGetProc, const wchar_t *dllDir, const wchar_t *dataDir)
{
    g_log = log;
#define GLP(field, name) gl.field = (void *)glGetProc(name); if (!gl.field) { LOG("dlss: GL entry point %s missing", name); return 0; }
    GLP(CreateMemoryObjects, "glCreateMemoryObjectsEXT")
    GLP(DeleteMemoryObjects, "glDeleteMemoryObjectsEXT")
    GLP(MemoryObjectParameteriv, "glMemoryObjectParameterivEXT")
    GLP(ImportMemoryWin32Handle, "glImportMemoryWin32HandleEXT")
    GLP(TexStorageMem2D, "glTexStorageMem2DEXT")
    GLP(GenSemaphores, "glGenSemaphoresEXT")
    GLP(ImportSemaphoreWin32Handle, "glImportSemaphoreWin32HandleEXT")
    GLP(SignalSemaphore, "glSignalSemaphoreEXT")
    GLP(WaitSemaphore, "glWaitSemaphoreEXT")
    GLP(GetUnsignedBytei_v, "glGetUnsignedBytei_vEXT")
    GLP(GenTextures, "glGenTextures")
    GLP(DeleteTextures, "glDeleteTextures")
    GLP(BindTexture, "glBindTexture")
    GLP(TexParameteri, "glTexParameteri")
    GLP(GetIntegerv, "glGetIntegerv")
    GLP(Flush, "glFlush")
#undef GLP

    HMODULE vk = LoadLibraryW(L"vulkan-1.dll");
    if (!vk) { LOG("dlss: vulkan-1.dll not found"); return 0; }
    vkGetInstanceProcAddr_ = (PFN_vkGetInstanceProcAddr)GetProcAddress(vk, "vkGetInstanceProcAddr");
    vkCreateInstance_ = (PFN_vkCreateInstance)vkGetInstanceProcAddr_(NULL, "vkCreateInstance");
    vkEnumerateInstanceExtensionProperties_ = (PFN_vkEnumerateInstanceExtensionProperties)vkGetInstanceProcAddr_(NULL, "vkEnumerateInstanceExtensionProperties");

    // The NGX core must be found before the instance: it lists the extensions DLSS needs.
    // The driver's Vulkan ICD is not loaded yet, so the registry is the way to it here.
    g_ngx = load_ngx_core();
    if (!g_ngx) { LOG("dlss: NVIDIA NGX core (_nvngx.dll) not found"); return 0; }
#define NGXP(var, name) var = (void *)GetProcAddress(g_ngx, name); if (!var) { LOG("dlss: NGX export %s missing", name); return 0; }
    NGXP(ngxRequiredExtensions, "NVSDK_NGX_VULKAN_RequiredExtensions")
    NGXP(ngxInit, "NVSDK_NGX_VULKAN_Init_ProjectID_Ext")
    NGXP(ngxShutdown1, "NVSDK_NGX_VULKAN_Shutdown1")
    NGXP(ngxGetCapabilityParameters, "NVSDK_NGX_VULKAN_GetCapabilityParameters")
    NGXP(ngxAllocateParameters, "NVSDK_NGX_VULKAN_AllocateParameters")
    NGXP(ngxDestroyParameters, "NVSDK_NGX_VULKAN_DestroyParameters")
    NGXP(ngxCreateFeature1, "NVSDK_NGX_VULKAN_CreateFeature1")
    NGXP(ngxEvaluateFeature, "NVSDK_NGX_VULKAN_EvaluateFeature")
    NGXP(ngxReleaseFeature, "NVSDK_NGX_VULKAN_ReleaseFeature")
#undef NGXP

    unsigned nInst = 0, nDev = 0;
    const char **instExts = NULL, **devExts = NULL;
    NVSDK_NGX_Result r = ngxRequiredExtensions(&nInst, &instExts, &nDev, &devExts);
    if (NVSDK_NGX_FAILED(r)) { LOG("dlss: NGX RequiredExtensions failed 0x%x", r); return 0; }

    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "Aurora Shaders DLSS";
    app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = nInst;
    ici.ppEnabledExtensionNames = instExts;
    VkResult vr = vkCreateInstance_(&ici, NULL, &g_inst);
    if (vr != VK_SUCCESS) { LOG("dlss: vkCreateInstance failed %d", (int)vr); return 0; }
#define VK_LOAD_I(n) n##_ = (PFN_##n)vkGetInstanceProcAddr_(g_inst, #n);
    VK_FUNCS(VK_LOAD_I)

    uint32_t nPhys = 0;
    vkEnumeratePhysicalDevices_(g_inst, &nPhys, NULL);
    VkPhysicalDevice phys[8];
    if (nPhys > 8) nPhys = 8;
    vkEnumeratePhysicalDevices_(g_inst, &nPhys, phys);
    // The GPU the GL context runs on (device UUID), else the first NVIDIA one.
    unsigned char glUuid[VK_UUID_SIZE] = {0};
    gl.GetUnsignedBytei_v(GL_DEVICE_UUID_EXT, 0, glUuid);
    for (uint32_t i = 0; i < nPhys && !g_phys; i++) {
        VkPhysicalDeviceIDProperties idp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
        VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &idp};
        vkGetPhysicalDeviceProperties2_(phys[i], &p2);
        if (!memcmp(idp.deviceUUID, glUuid, VK_UUID_SIZE)) {
            g_phys = phys[i];
            LOG("dlss: Vulkan device %s (same GPU as the GL context)", p2.properties.deviceName);
        }
    }
    for (uint32_t i = 0; i < nPhys && !g_phys; i++) {
        VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
        vkGetPhysicalDeviceProperties2_(phys[i], &p2);
        if (p2.properties.vendorID == 0x10DE) {
            g_phys = phys[i];
            LOG("dlss: Vulkan device %s (GL device UUID did not match)", p2.properties.deviceName);
        }
    }
    if (!g_phys) { LOG("dlss: no NVIDIA Vulkan device"); return 0; }
    vkGetPhysicalDeviceMemoryProperties_(g_phys, &g_memProps);

    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties_(g_phys, &nq, NULL);
    VkQueueFamilyProperties qf[16];
    if (nq > 16) nq = 16;
    vkGetPhysicalDeviceQueueFamilyProperties_(g_phys, &nq, qf);
    g_qfam = UINT32_MAX;
    for (uint32_t i = 0; i < nq; i++)
        if ((qf[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) == (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) { g_qfam = i; break; }
    if (g_qfam == UINT32_MAX) { LOG("dlss: no graphics queue"); return 0; }

    // Extensions: NGX's plus the external memory / semaphore ones, those the device has.
    uint32_t nAvail = 0;
    vkEnumerateDeviceExtensionProperties_(g_phys, NULL, &nAvail, NULL);
    VkExtensionProperties *avail = (VkExtensionProperties *)calloc(nAvail, sizeof(VkExtensionProperties));
    vkEnumerateDeviceExtensionProperties_(g_phys, NULL, &nAvail, avail);
    const char *want[64];
    unsigned nWant = 0;
    const char *extra[] = {"VK_KHR_external_memory_win32", "VK_KHR_external_semaphore_win32"};
    for (unsigned i = 0; i < nDev + 2 && nWant < 64; i++) {
        const char *e = i < nDev ? devExts[i] : extra[i - nDev];
        int ok = 0;
        for (uint32_t k = 0; k < nAvail; k++) if (!strcmp(avail[k].extensionName, e)) ok = 1;
        if (!ok) { LOG("dlss: device extension %s not available", e); continue; }
        if (!has_ext(e, want, nWant)) want[nWant++] = e;
    }
    free(avail);

    // Every feature the device supports (DLSS uses several), minus robust buffer access.
    VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &f13};
    VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12};
    VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11};
    vkGetPhysicalDeviceFeatures2_(g_phys, &f2);
    f2.features.robustBufferAccess = VK_FALSE;
    f13.robustImageAccess = VK_FALSE;

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = g_qfam;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = nWant;
    dci.ppEnabledExtensionNames = want;
    vr = vkCreateDevice_(g_phys, &dci, NULL, &g_dev);
    if (vr != VK_SUCCESS) { LOG("dlss: vkCreateDevice failed %d", (int)vr); return 0; }
#define VK_LOAD_D(n) { PFN_vkVoidFunction f = vkGetDeviceProcAddr_(g_dev, #n); if (f) n##_ = (PFN_##n)f; }
    VK_FUNCS(VK_LOAD_D)
    vkGetDeviceQueue_(g_dev, g_qfam, 0, &g_queue);

    VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pci.queueFamilyIndex = g_qfam;
    vkCreateCommandPool_(g_dev, &pci, NULL, &g_pool);
    VkCommandBufferAllocateInfo cai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cai.commandPool = g_pool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = AUD_FRAMES;
    vkAllocateCommandBuffers_(g_dev, &cai, g_cmd);
    for (int i = 0; i < AUD_FRAMES; i++) {
        VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        fci.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        vkCreateFence_(g_dev, &fci, NULL, &g_fence[i]);
    }
    if (!create_semaphore(&g_semGLDone, &g_glSemGLDone) || !create_semaphore(&g_semVKDone, &g_glSemVKDone)) {
        LOG("dlss: shared semaphores failed");
        return 0;
    }

    const wchar_t *paths[1] = {dllDir};
    NVSDK_NGX_FeatureCommonInfo info;
    memset(&info, 0, sizeof(info));
    info.PathListInfo.Path = paths;
    info.PathListInfo.Length = 1;
    info.LoggingInfo.LoggingCallback = ngx_log_cb;
    info.LoggingInfo.MinimumLoggingLevel = NVSDK_NGX_LOGGING_LEVEL_ON;
    r = ngxInit("a3f1c9e2-7b4d-4e8a-9c6f-5d2b8e1a4f70", NVSDK_NGX_ENGINE_TYPE_CUSTOM, "1.0", dataDir,
                g_inst, g_phys, g_dev, vkGetInstanceProcAddr_, vkGetDeviceProcAddr_, NVSDK_NGX_Version_API, &info);
    if (NVSDK_NGX_FAILED(r)) { LOG("dlss: NGX init failed 0x%x", r); return 0; }
    g_ngxReady = 1;

    NVSDK_NGX_Parameter *cap = NULL;
    r = ngxGetCapabilityParameters(&cap);
    if (NVSDK_NGX_FAILED(r) || !cap) { LOG("dlss: NGX capability query failed 0x%x", r); return 0; }
    int ss = 0, needsDriver = 0, rr = 0;
    NVSDK_NGX_Result rs = ngx_get_i(cap, NVSDK_NGX_Parameter_SuperSampling_Available, &ss);
    ngx_get_i(cap, NVSDK_NGX_Parameter_SuperSampling_NeedsUpdatedDriver, &needsDriver);
    ngx_get_i(cap, NVSDK_NGX_Parameter_SuperSamplingDenoising_Available, &rr);
    LOG("dlss: super resolution available=%d (query 0x%x) needs newer driver=%d, ray reconstruction available=%d", ss, rs, needsDriver, rr);
    ngxDestroyParameters(cap);
    g_rrAvailable = rr;
    if (!ss) return 0;
    ngxAllocateParameters(&g_params);
    return g_params != NULL;
}

// ----------------------------------------------------------------------------------------
// Feature + images

static VkCommandBuffer begin_cmd(void)
{
    VkCommandBuffer cb = g_cmd[g_frameIdx];
    vkWaitForFences_(g_dev, 1, &g_fence[g_frameIdx], VK_TRUE, UINT64_MAX);
    vkResetFences_(g_dev, 1, &g_fence[g_frameIdx]);
    vkResetCommandBuffer_(cb, 0);
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer_(cb, &bi);
    return cb;
}

int aud_rr_available(void)
{
    return g_rrAvailable;
}

static void barrier_all(VkCommandBuffer cb, int acquire)
{
    VkImageMemoryBarrier b[AUD_TEX_COUNT];
    unsigned n = 0;
    for (int i = 0; i < AUD_TEX_COUNT; i++) {
        if (!g_img[i].image) continue;
        VkImageMemoryBarrier *m = &b[n++];
        memset(m, 0, sizeof(*m));
        m->sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        m->srcAccessMask = acquire ? 0 : VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT;
        m->dstAccessMask = acquire ? VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT : 0;
        m->oldLayout = VK_IMAGE_LAYOUT_GENERAL;
        m->newLayout = VK_IMAGE_LAYOUT_GENERAL;
        m->srcQueueFamilyIndex = acquire ? VK_QUEUE_FAMILY_EXTERNAL : g_qfam;
        m->dstQueueFamilyIndex = acquire ? g_qfam : VK_QUEUE_FAMILY_EXTERNAL;
        m->image = g_img[i].image;
        m->subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        m->subresourceRange.levelCount = 1;
        m->subresourceRange.layerCount = 1;
    }
    vkCmdPipelineBarrier_(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, n, b);
}

static void release_feature(void)
{
    if (!g_dev) return;
    vkDeviceWaitIdle_(g_dev);
    if (g_feature) { ngxReleaseFeature(g_feature); g_feature = NULL; }
    for (int i = 0; i < AUD_TEX_COUNT; i++) destroy_image(&g_img[i]);
}

int aud_configure(int renderW, int renderH, int outW, int outH, int quality, int hdr, int rr, int preset)
{
    if (!g_ngxReady || !g_params) return 0;
    release_feature();
    g_rr = rr && g_rrAvailable;
    g_renderW = renderW;
    g_renderH = renderH;
    g_outW = outW;
    g_outH = outH;
    if (!create_image(&g_img[AUD_TEX_COLOR], renderW, renderH, VK_FORMAT_R16G16B16A16_SFLOAT, GL_RGBA16F) ||
        !create_image(&g_img[AUD_TEX_DEPTH], renderW, renderH, VK_FORMAT_R32_SFLOAT, GL_R32F) ||
        !create_image(&g_img[AUD_TEX_MOTION], renderW, renderH, VK_FORMAT_R16G16_SFLOAT, GL_RG16F) ||
        !create_image(&g_img[AUD_TEX_OUTPUT], outW, outH, VK_FORMAT_R16G16B16A16_SFLOAT, GL_RGBA16F) ||
        (g_rr && (!create_image(&g_img[AUD_TEX_ALBEDO], renderW, renderH, VK_FORMAT_R8G8B8A8_UNORM, GL_RGBA8) ||
                  !create_image(&g_img[AUD_TEX_SPECULAR], renderW, renderH, VK_FORMAT_R8G8B8A8_UNORM, GL_RGBA8) ||
                  !create_image(&g_img[AUD_TEX_NORMALS], renderW, renderH, VK_FORMAT_R16G16B16A16_SFLOAT, GL_RGBA16F)))) {
        release_feature();
        return 0;
    }

    // First use: the images go from UNDEFINED to GENERAL and stay there.
    VkCommandBuffer cb = begin_cmd();
    VkImageMemoryBarrier b[AUD_TEX_COUNT];
    unsigned nb = 0;
    for (int i = 0; i < AUD_TEX_COUNT; i++) {
        if (!g_img[i].image) continue;
        VkImageMemoryBarrier *m = &b[nb++];
        memset(m, 0, sizeof(*m));
        m->sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        m->dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
        m->oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        m->newLayout = VK_IMAGE_LAYOUT_GENERAL;
        m->srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        m->dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        m->image = g_img[i].image;
        m->subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        m->subresourceRange.levelCount = 1;
        m->subresourceRange.layerCount = 1;
    }
    vkCmdPipelineBarrier_(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, nb, b);

    NVSDK_NGX_Parameter *p = g_params;
    ngx_set_ui(p, NVSDK_NGX_Parameter_CreationNodeMask, 1);
    ngx_set_ui(p, NVSDK_NGX_Parameter_VisibilityNodeMask, 1);
    ngx_set_ui(p, NVSDK_NGX_Parameter_Width, (unsigned)renderW);
    ngx_set_ui(p, NVSDK_NGX_Parameter_Height, (unsigned)renderH);
    ngx_set_ui(p, NVSDK_NGX_Parameter_OutWidth, (unsigned)outW);
    ngx_set_ui(p, NVSDK_NGX_Parameter_OutHeight, (unsigned)outH);
    ngx_set_i(p, NVSDK_NGX_Parameter_PerfQualityValue, quality);
    ngx_set_i(p, NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags,
              NVSDK_NGX_DLSS_Feature_Flags_MVLowRes | (hdr ? NVSDK_NGX_DLSS_Feature_Flags_IsHDR : 0));
    ngx_set_i(p, NVSDK_NGX_Parameter_DLSS_Enable_Output_Subrects, 0);
    // The model for every quality mode (0 = NVIDIA's default, what the SDK library fills in
    // when unset; an override in the NVIDIA app still wins).
    unsigned sr = g_rr ? 0u : (unsigned)preset, rp = g_rr ? (unsigned)preset : 0u;
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_DLAA, sr);
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_Quality, sr);
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_Balanced, sr);
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_Performance, sr);
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_UltraPerformance, sr);
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_UltraQuality, sr);
    // Ray Reconstruction (what NGX_VULKAN_CREATE_DLSSD_EXT1 sets): the DL denoiser-upscaler,
    // roughness packed into the normals' alpha, linear depth.
    ngx_set_i(p, NVSDK_NGX_Parameter_DLSS_Denoise_Mode, g_rr ? NVSDK_NGX_DLSS_Denoise_Mode_DLUnified : NVSDK_NGX_DLSS_Denoise_Mode_Off);
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Roughness_Mode, NVSDK_NGX_DLSS_Roughness_Mode_Packed);
    ngx_set_ui(p, NVSDK_NGX_Parameter_Use_HW_Depth, NVSDK_NGX_DLSS_Depth_Type_Linear);
    ngx_set_ui(p, NVSDK_NGX_Parameter_RayReconstruction_Hint_Render_Preset_DLAA, rp);
    ngx_set_ui(p, NVSDK_NGX_Parameter_RayReconstruction_Hint_Render_Preset_Quality, rp);
    ngx_set_ui(p, NVSDK_NGX_Parameter_RayReconstruction_Hint_Render_Preset_Balanced, rp);
    ngx_set_ui(p, NVSDK_NGX_Parameter_RayReconstruction_Hint_Render_Preset_Performance, rp);
    ngx_set_ui(p, NVSDK_NGX_Parameter_RayReconstruction_Hint_Render_Preset_UltraPerformance, rp);
    ngx_set_ui(p, NVSDK_NGX_Parameter_RayReconstruction_Hint_Render_Preset_UltraQuality, rp);
    NVSDK_NGX_Result r = ngxCreateFeature1(g_dev, cb, g_rr ? NVSDK_NGX_Feature_RayReconstruction : NVSDK_NGX_Feature_SuperSampling, p, &g_feature);
    vkEndCommandBuffer_(cb);
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    vkQueueSubmit_(g_queue, 1, &si, g_fence[g_frameIdx]);
    vkQueueWaitIdle_(g_queue);
    g_frameIdx = (g_frameIdx + 1) % AUD_FRAMES;
    if (NVSDK_NGX_FAILED(r) || !g_feature) {
        LOG("dlss: CreateFeature failed 0x%x", r);
        release_feature();
        return 0;
    }
    LOG("dlss: %s created %dx%d -> %dx%d (quality %d, preset %d%s)", g_rr ? "ray reconstruction" : "super resolution",
        renderW, renderH, outW, outH, quality, preset, hdr ? ", HDR" : "");
    return 1;
}

unsigned aud_texture(int which)
{
    return which >= 0 && which < AUD_TEX_COUNT ? g_img[which].glTex : 0;
}

int aud_evaluate(float jitterX, float jitterY, float mvScaleX, float mvScaleY, int reset)
{
    if (!g_feature) return 0;
    GLuint texs[AUD_TEX_COUNT];
    GLenum layouts[AUD_TEX_COUNT];
    GLuint ntex = 0;
    for (int i = 0; i < AUD_TEX_COUNT; i++) if (g_img[i].glTex) { texs[ntex] = g_img[i].glTex; layouts[ntex++] = GL_LAYOUT_GENERAL_EXT; }
    gl.SignalSemaphore(g_glSemGLDone, 0, NULL, ntex, texs, layouts);
    gl.Flush();

    VkCommandBuffer cb = begin_cmd();
    barrier_all(cb, 1);
    NVSDK_NGX_Parameter *p = g_params;
    ngx_set_ptr(p, NVSDK_NGX_Parameter_Color, &g_img[AUD_TEX_COLOR].res);
    ngx_set_ptr(p, NVSDK_NGX_Parameter_Output, &g_img[AUD_TEX_OUTPUT].res);
    ngx_set_ptr(p, NVSDK_NGX_Parameter_Depth, &g_img[AUD_TEX_DEPTH].res);
    ngx_set_ptr(p, NVSDK_NGX_Parameter_MotionVectors, &g_img[AUD_TEX_MOTION].res);
    ngx_set_f(p, NVSDK_NGX_Parameter_Jitter_Offset_X, jitterX);
    ngx_set_f(p, NVSDK_NGX_Parameter_Jitter_Offset_Y, jitterY);
    ngx_set_f(p, NVSDK_NGX_Parameter_Sharpness, 0.0f);
    ngx_set_i(p, NVSDK_NGX_Parameter_Reset, reset);
    ngx_set_f(p, NVSDK_NGX_Parameter_MV_Scale_X, mvScaleX);
    ngx_set_f(p, NVSDK_NGX_Parameter_MV_Scale_Y, mvScaleY);
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, (unsigned)g_renderW);
    ngx_set_ui(p, NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, (unsigned)g_renderH);
    ngx_set_f(p, NVSDK_NGX_Parameter_DLSS_Pre_Exposure, 1.0f);
    ngx_set_f(p, NVSDK_NGX_Parameter_DLSS_Exposure_Scale, 1.0f);
    if (g_rr) {
        ngx_set_ptr(p, NVSDK_NGX_Parameter_DiffuseAlbedo, &g_img[AUD_TEX_ALBEDO].res);
        ngx_set_ptr(p, NVSDK_NGX_Parameter_SpecularAlbedo, &g_img[AUD_TEX_SPECULAR].res);
        ngx_set_ptr(p, NVSDK_NGX_Parameter_GBuffer_Normals, &g_img[AUD_TEX_NORMALS].res);
        ngx_set_ptr(p, NVSDK_NGX_Parameter_GBuffer_Roughness, NULL);   // packed into the normals
    }
    NVSDK_NGX_Result r = ngxEvaluateFeature(cb, g_feature, p, NULL);
    barrier_all(cb, 0);
    vkEndCommandBuffer_(cb);

    VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.waitSemaphoreCount = 1;
    si.pWaitSemaphores = &g_semGLDone;
    si.pWaitDstStageMask = &waitStage;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores = &g_semVKDone;
    vkQueueSubmit_(g_queue, 1, &si, g_fence[g_frameIdx]);
    g_frameIdx = (g_frameIdx + 1) % AUD_FRAMES;

    gl.WaitSemaphore(g_glSemVKDone, 0, NULL, ntex, texs, layouts);
    if (NVSDK_NGX_FAILED(r)) {
        static int logged;
        if (logged++ < 5) LOG("dlss: EvaluateFeature failed 0x%x", r);
        return 0;
    }
    return 1;
}

void aud_shutdown(void)
{
    if (!g_dev) return;
    release_feature();
    if (g_params) { ngxDestroyParameters(g_params); g_params = NULL; }
    if (g_ngxReady) { ngxShutdown1(g_dev); g_ngxReady = 0; }
}
