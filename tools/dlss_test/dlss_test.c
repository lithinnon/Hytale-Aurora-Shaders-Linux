// Standalone check of the DLSS bridge (hook/aud_dlss.c) outside the game: a hidden OpenGL
// window, DLSS upscaling a half red / half blue picture 2x, the result read back through GL.
//   tools\dlss_test\build.ps1, then run dlss_test.exe (needs nvngx_dlss.dll next to it)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <GL/gl.h>
#include "../../hook/aud_dlss.h"

#define GL_FRAMEBUFFER 0x8D40
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GLAPI __stdcall
typedef void (GLAPI *PFN_glGenFramebuffers)(GLsizei, GLuint *);
typedef void (GLAPI *PFN_glBindFramebuffer)(GLenum, GLuint);
typedef void (GLAPI *PFN_glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
typedef void (GLAPI *PFN_glClearBufferfv)(GLenum, GLint, const float *);

static void logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
}

static HMODULE g_gl32;
static void *get_proc(const char *name)
{
    void *p = (void *)wglGetProcAddress(name);
    if (!p || p == (void *)1 || p == (void *)2 || p == (void *)3 || p == (void *)-1) p = (void *)GetProcAddress(g_gl32, name);
    return p;
}

static void clear_tex(GLuint fbo, GLuint tex, int x, int y, int w, int h, float r, float g, float b, float a)
{
    static PFN_glBindFramebuffer bind;
    static PFN_glFramebufferTexture2D attach;
    static PFN_glClearBufferfv clearBuf;
    if (!bind) {
        bind = get_proc("glBindFramebuffer");
        attach = get_proc("glFramebufferTexture2D");
        clearBuf = get_proc("glClearBufferfv");
    }
    bind(GL_FRAMEBUFFER, fbo);
    attach(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    glEnable(GL_SCISSOR_TEST);
    glScissor(x, y, w, h);
    float c[4] = {r, g, b, a};
    clearBuf(GL_COLOR, 0, c);
    glDisable(GL_SCISSOR_TEST);
    bind(GL_FRAMEBUFFER, 0);
}

int main(void)
{
    wchar_t dir[MAX_PATH];
    GetModuleFileNameW(NULL, dir, MAX_PATH);
    *wcsrchr(dir, L'\\') = 0;

    HWND wnd = CreateWindowW(L"STATIC", L"dlss_test", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, NULL, NULL, NULL, NULL);
    HDC dc = GetDC(wnd);
    PIXELFORMATDESCRIPTOR pfd = {sizeof(pfd), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER, PFD_TYPE_RGBA, 32};
    SetPixelFormat(dc, ChoosePixelFormat(dc, &pfd), &pfd);
    HGLRC rc = wglCreateContext(dc);
    wglMakeCurrent(dc, rc);
    g_gl32 = GetModuleHandleW(L"opengl32.dll");
    logf_("GL: %s / %s", glGetString(GL_VENDOR), glGetString(GL_RENDERER));

    if (!aud_init(logf_, get_proc, dir, dir)) { logf_("FAIL: aud_init"); return 1; }
    const int rw = 960, rh = 540, ow = 1920, oh = 1080;
    if (!aud_configure(rw, rh, ow, oh, 0 /* MaxPerf: 50% */, 1, 0, 0)) { logf_("FAIL: aud_configure"); return 1; }

    PFN_glGenFramebuffers genFb = get_proc("glGenFramebuffers");
    GLuint fbo;
    genFb(1, &fbo);
    for (int frame = 0; frame < 8; frame++) {
        clear_tex(fbo, aud_texture(AUD_TEX_COLOR), 0, 0, rw / 2, rh, 1.0f, 0.1f, 0.1f, 1.0f);
        clear_tex(fbo, aud_texture(AUD_TEX_COLOR), rw / 2, 0, rw - rw / 2, rh, 0.1f, 0.1f, 1.0f, 1.0f);
        clear_tex(fbo, aud_texture(AUD_TEX_DEPTH), 0, 0, rw, rh, 0.5f, 0, 0, 0);
        clear_tex(fbo, aud_texture(AUD_TEX_MOTION), 0, 0, rw, rh, 0, 0, 0, 0);
        if (!aud_evaluate(0.0f, 0.0f, 1.0f, 1.0f, frame == 0)) { logf_("FAIL: aud_evaluate frame %d", frame); return 1; }
    }
    glFinish();

    float *px = (float *)malloc((size_t)ow * oh * 4 * sizeof(float));
    glBindTexture(GL_TEXTURE_2D, aud_texture(AUD_TEX_OUTPUT));
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_FLOAT, px);
    const float *l = px + ((size_t)(oh / 2) * ow + ow / 4) * 4;
    const float *r = px + ((size_t)(oh / 2) * ow + ow * 3 / 4) * 4;
    logf_("output left  (%.3f %.3f %.3f)  expect ~(1.0 0.1 0.1)", l[0], l[1], l[2]);
    logf_("output right (%.3f %.3f %.3f)  expect ~(0.1 0.1 1.0)", r[0], r[1], r[2]);
    int ok = l[0] > 0.7f && l[2] < 0.3f && r[2] > 0.7f && r[0] < 0.3f;
    logf_(ok ? "PASS: DLSS upscaled through the GL<->Vulkan bridge" : "FAIL: unexpected output");
    aud_shutdown();
    return ok ? 0 : 1;
}
