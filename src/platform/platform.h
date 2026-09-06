#ifndef READ_PLATFORM_H
#define READ_PLATFORM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void (*on_scroll)(float delta_x, float delta_y, int hovered_block_id);
    void (*on_resize)(int width, int height);
    void (*on_key)(int key_code, int hovered_block_id);
    void (*on_draw)(int width, int height);
    void (*on_link)(const char* url, int url_len);
    int (*on_tick)(float dt_ms);
    void (*on_scroll_to)(float scroll_y);
} PlatformCallbacks;

int platform_init(const char* title, int width, int height, PlatformCallbacks callbacks);
void platform_run_loop(void);
void platform_request_redraw(void);
void platform_request_redraw_rect(float x, float y, float w, float h);
int platform_get_pending_damage(float* x, float* y, float* w, float* h);
void platform_sync_scroll(float scroll_y);
void platform_smooth_kick(void);
void platform_set_scroll_info(float scroll_y, float max_scroll_y, float view_h);

void platform_draw_rect(float x, float y, float w, float h, unsigned char r, unsigned char g, unsigned char b, unsigned char a);
void platform_register_text_run(const char* text, int len, float x, float y, float w, float h, float font_size, int is_bold, int is_italic, int is_mono, int is_heading, const char* link_url, int link_url_len);
void platform_set_test_damage(float x, float y, float w, float h, int valid);
int platform_text_record_count(void);
void platform_set_test_selection(float x1, float y1, float x2, float y2, int enable);
void platform_draw_text(const char* text, int len, float x, float y, float font_size, int is_bold, int is_italic, int is_mono, int is_heading, unsigned char r, unsigned char g, unsigned char b, unsigned char a, const char* link_url, int link_url_len);
void platform_draw_image(const char* url, int url_len, float x, float y, float w, float h);
void platform_get_image_size(const char* url, int url_len, float* out_w, float* out_h);
void platform_arm_images(void);
void platform_register_code_block(float x, float y, float w, float h, const char* code_text, int code_len);
void platform_register_scrollable_block(int block_id, float x, float y, float w, float h, float max_scroll_x);
void platform_begin_clip(float x, float y, float w, float h);
void platform_end_clip(void);
float platform_measure_text(const char* text, int len, float font_size, int is_bold, int is_mono);
void platform_glyph_cache_stats(unsigned long long* hits, unsigned long long* misses, unsigned long long* flushes);

int platform_render_to_png(const char* output_path, int width, int height, void (*render_fn)(int width, int height));

#ifdef __cplusplus
}
#endif

#endif // READ_PLATFORM_H
