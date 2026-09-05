#ifndef READ_PLATFORM_H
#define READ_PLATFORM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void (*on_scroll)(float delta_x, float delta_y);
    void (*on_resize)(int width, int height);
    void (*on_key)(int key_code);
    void (*on_draw)(int width, int height);
} PlatformCallbacks;

int platform_init(const char* title, int width, int height, PlatformCallbacks callbacks);
void platform_run_loop(void);
void platform_request_redraw(void);
void platform_sync_scroll(float scroll_y);

void platform_draw_rect(float x, float y, float w, float h, unsigned char r, unsigned char g, unsigned char b, unsigned char a);
void platform_draw_text(const char* text, int len, float x, float y, float font_size, int is_bold, int is_italic, int is_mono, int is_heading, unsigned char r, unsigned char g, unsigned char b, unsigned char a, const char* link_url, int link_url_len);
void platform_register_code_block(float x, float y, float w, float h, const char* code_text, int code_len);
float platform_measure_text(const char* text, int len, float font_size, int is_bold, int is_mono);

int platform_render_to_png(const char* output_path, int width, int height, void (*render_fn)(int width, int height));

#ifdef __cplusplus
}
#endif

#endif // READ_PLATFORM_H
