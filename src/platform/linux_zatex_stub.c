// Empty ZaTeX backend stub (AGENTS.md §7 differential twin). Included by
// src/platform/linux.c when READ_PLUGIN_STUB=1 instead of linux_zatex.c:
#include <stdint.h>
// same TU, same flags, trivial bodies. Sizes never resolve and draws are
// no-ops, so the twin's __TEXT delta is exactly the ZaTeX-attributable
// platform code. Never shipped, never bundled — observability tooling only.
int platform_math_size(const char* tex, int tex_len, int display, float font_px,
                       float* out_w, float* out_above, float* out_below) {
    (void)tex; (void)tex_len; (void)display; (void)font_px;
    if (out_w) *out_w = 0;
    if (out_above) *out_above = 0;
    if (out_below) *out_below = 0;
    return 1;
}

int platform_math_last_error(const char* tex, int tex_len, int display,
                             unsigned int* out_offset, int* out_code) {
    (void)tex; (void)tex_len; (void)display;
    (void)out_offset; (void)out_code;
    return 0;
}

void platform_draw_math(const char* tex, int tex_len, int display, float font_px,
                        float x, float y_top,
                        unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    (void)tex; (void)tex_len; (void)display; (void)font_px;
    (void)x; (void)y_top; (void)r; (void)g; (void)b; (void)a;
}

#ifdef TEST_HOOKS
void platform_math_atlas_stats(uint64_t* hits, uint64_t* misses) {
    if (hits) *hits = 0;
    if (misses) *misses = 0;
}

void platform_math_engine_info(unsigned int* version, unsigned int* use_ex, unsigned int* conform_ran,
                               int* conform_n, unsigned int* caps) {
    if (version) *version = 0;
    if (use_ex) *use_ex = 0;
    if (conform_ran) *conform_ran = 0;
    if (conform_n) *conform_n = 0;
    if (caps) *caps = 0;
}
#endif

void zatex_drop_math_rasters(void) {}
