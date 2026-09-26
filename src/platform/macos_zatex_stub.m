// Empty ZaTeX backend stub (AGENTS.md §7 differential twin). Included by
// src/platform/macos.m when READ_PLUGIN_STUB=1 instead of macos_zatex.m:
// same TU, same flags, trivial bodies. Sizes never resolve and draws are
// no-ops, so the twin's __TEXT delta is exactly the ZaTeX-attributable
// platform code. Never shipped, never bundled — observability tooling only.
int platform_math_size(const char* tex, int tex_len, int display, float font_px,
                       float* out_w, float* out_above, float* out_below) {
    (void)tex;
    (void)tex_len;
    (void)display;
    (void)font_px;
    if (out_w) *out_w = 0;
    if (out_above) *out_above = 0;
    if (out_below) *out_below = 0;
    return 1;
}
void platform_draw_math(const char* tex, int tex_len, int display, float font_px,
                        float x, float y_top,
                        unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    (void)tex;
    (void)tex_len;
    (void)display;
    (void)font_px;
    (void)x;
    (void)y_top;
    (void)r;
    (void)g;
    (void)b;
    (void)a;
}
