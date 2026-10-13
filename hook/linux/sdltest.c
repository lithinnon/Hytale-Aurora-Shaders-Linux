// Smoke test for the Aurora Linux hook: resolves SDL3 exactly like the Hytale client does
// (dlopen + dlsym, so the hook's dlsym interposition hands back SDL_GL_GetProcAddress ->
// au_getproc), creates a hidden GL context, and feeds the game's own BasicFS source through
// glShaderSource. If the interception works, shaderpack/hook.log shows
// "override applied: BasicFS (fs)" (or a COMPILE ERROR for BasicFS, which also proves it).
//
// Built by hook/linux/build.sh as build/sdltest. Run inside the Flatpak sandbox:
//   AURORA_FORCE=1 AURORA_PACK_DIR=<repo>/shaderpack LD_PRELOAD=<...>/libaurora-hook.so ./sdltest <libSDL3.so>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define STEP(x) do { fprintf(stderr, "[sdltest] %s\n", x); fflush(stderr); } while (0)

typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef unsigned int GLenum;
typedef char GLchar;

int main(int argc, char **argv)
{
    STEP("start");
    if (argc < 2) { fprintf(stderr, "usage: sdltest <path to libSDL3.so>\n"); return 2; }
    STEP("dlopen");
    void *sdl = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    if (!sdl) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }

    STEP("dlsym");
    int (*SDL_Init)(unsigned) = dlsym(sdl, "SDL_Init");
    void *(*SDL_CreateWindow)(const char *, int, int, unsigned) = dlsym(sdl, "SDL_CreateWindow");
    void *(*SDL_GL_CreateContext)(void *) = dlsym(sdl, "SDL_GL_CreateContext");
    void *(*SDL_GL_GetProcAddress)(const char *) = dlsym(sdl, "SDL_GL_GetProcAddress");
    int (*SDL_GL_SetAttribute)(int, int) = dlsym(sdl, "SDL_GL_SetAttribute");
    printf("SDL_GL_GetProcAddress = %p\n", SDL_GL_GetProcAddress);
    if (!SDL_Init || !SDL_CreateWindow || !SDL_GL_CreateContext || !SDL_GL_GetProcAddress) return 1;

    STEP("SDL_Init");
    const char *(*SDL_GetError)(void) = dlsym(sdl, "SDL_GetError");
    if (!SDL_Init(0x20 /*VIDEO*/)) { fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError ? SDL_GetError() : "?"); return 1; }
    SDL_GL_SetAttribute(17 /*GL_CONTEXT_MAJOR_VERSION*/, 4);
    SDL_GL_SetAttribute(18 /*GL_CONTEXT_MINOR_VERSION*/, 1);
    SDL_GL_SetAttribute(21 /*GL_CONTEXT_PROFILE_MASK*/, 1 /*CORE*/);
    STEP("CreateWindow");
    void *win = SDL_CreateWindow("aurora-test", 64, 64, 0x2 /*OPENGL*/ | 0x8 /*HIDDEN*/);
    if (!win) { fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError ? SDL_GetError() : "?"); return 1; }
    STEP("CreateContext");
    void *ctx = SDL_GL_CreateContext(win);
    if (!ctx) { fprintf(stderr, "SDL_GL_CreateContext failed: %s\n", SDL_GetError ? SDL_GetError() : "?"); return 1; }

    STEP("getproc");
    GLuint (*glCreateShader)(GLenum) = SDL_GL_GetProcAddress("glCreateShader");
    void (*glShaderSource)(GLuint, GLsizei, const GLchar *const *, const GLint *) = SDL_GL_GetProcAddress("glShaderSource");
    void (*glCompileShader)(GLuint) = SDL_GL_GetProcAddress("glCompileShader");
    void (*glGetShaderiv)(GLuint, GLenum, GLint *) = SDL_GL_GetProcAddress("glGetShaderiv");
    void (*glGetShaderInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *) = SDL_GL_GetProcAddress("glGetShaderInfoLog");

    // The game's BasicFS source straight from shaderpack/original (via AURORA_PACK_DIR).
    const char *pack = getenv("AURORA_PACK_DIR");
    char path[1024];
    snprintf(path, sizeof(path), "%s/original/BasicFS.glsl", pack ? pack : "shaderpack");
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *src = malloc(n + 1);
    fread(src, 1, n, f);
    src[n] = 0;
    fclose(f);

    STEP("shader source");
    GLuint sh = glCreateShader(0x8B30 /*FRAGMENT_SHADER*/);
    glShaderSource(sh, 1, (const GLchar **)&src, NULL);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, 0x8B81 /*COMPILE_STATUS*/, &ok);
    char log[4096] = {0};
    glGetShaderInfoLog(sh, sizeof(log) - 1, NULL, log);
    STEP("done");
    printf("compile ok=%d\n%s\n", ok, log);
    printf("now check shaderpack/hook.log for 'override applied: BasicFS'\n");
    return 0;
}
