// Minimal deterministic PNG writer for the Linux headless renderer.
//
// Encodes 8-bit RGBA (color type 6) with filter type 0 on every scanline
// and a zlib stream (header 78 01) built from stored (uncompressed)
// deflate blocks, so no compressor tables or timestamps exist anywhere:
// identical pixels always produce identical bytes. CRC32 uses the standard
// table-driven IEEE polynomial. No timestamps: no tIME chunk, and the
// zlib header carries no OS byte beyond the fixed 78 01.
//
// Usage: caller allocates out buffers generously (see LINUX_PNG_BOUND),
// calls linux_png_encode(w, h, rgba, out, &out_len), then writes out.
//
// AGENTS.md: zero third-party deps — this file is self-contained C99.
#ifndef READ_LINUX_PNG_H
#define READ_LINUX_PNG_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Generous bound: raw bytes (filter byte + 4*w per row) + exact stored-
// block headers (5 bytes per 65535-byte chunk) + zlib header/trailer +
// IHDR/IEND framing, with slack.
#define LINUX_PNG_RAW(w, h) ((size_t)(h) * ((size_t)4 * (w) + 1))
#define LINUX_PNG_BOUND(w, h) \
    (LINUX_PNG_RAW(w, h) + (LINUX_PNG_RAW(w, h) + 65534) / 65535 * 5 + 64)

static uint32_t linux_png_crc_table[256];
static int linux_png_crc_ready = 0;

static void linux_png_crc_init(void) {
    if (linux_png_crc_ready) return;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        linux_png_crc_table[i] = c;
    }
    linux_png_crc_ready = 1;
}

static uint32_t linux_png_crc(const uint8_t *data, size_t len) {
    linux_png_crc_init();
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++)
        c = linux_png_crc_table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static void linux_png_put32be(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

// Appends one chunk (length + type + body + crc) at *pos. Returns 0 on
// success, -1 when the output buffer is too small.
static int linux_png_chunk(uint8_t *out, size_t out_cap, size_t *pos,
                           const char *type, const uint8_t *body, size_t body_len) {
    if (*pos + 12 + body_len > out_cap) return -1;
    linux_png_put32be(out + *pos, (uint32_t)body_len);
    memcpy(out + *pos + 4, type, 4);
    if (body_len) memcpy(out + *pos + 8, body, body_len);
    uint32_t c = 0xFFFFFFFFu;
    linux_png_crc_init();
    for (int i = 0; i < 4; i++)
        c = linux_png_crc_table[(c ^ (uint8_t)type[i]) & 0xFF] ^ (c >> 8);
    for (size_t i = 0; i < body_len; i++)
        c = linux_png_crc_table[(c ^ body[i]) & 0xFF] ^ (c >> 8);
    linux_png_put32be(out + *pos + 8 + body_len, c ^ 0xFFFFFFFFu);
    *pos += 12 + body_len;
    return 0;
}

// Encodes w*h RGBA pixels (row-major, top-down) into out[0..out_cap].
// On success sets *out_len and returns 0; negative on bad input (-1)
// or short buffer (-2). Stored blocks cap each raw run at 65535 bytes;
// a scanline (filter byte + 4*w) is split across blocks when wider.
static int linux_png_encode(int w, int h, const uint8_t *rgba,
                            uint8_t *out, size_t out_cap, size_t *out_len) {
    if (!rgba || !out || !out_len || w <= 0 || h <= 0) return -1;
    static const uint8_t sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    size_t pos = 0;
    if (out_cap < 8) return -2;
    memcpy(out, sig, 8);
    pos = 8;

    uint8_t ihdr[13];
    linux_png_put32be(ihdr, (uint32_t)w);
    linux_png_put32be(ihdr + 4, (uint32_t)h);
    ihdr[8] = 8;  // bit depth
    ihdr[9] = 6;  // color type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // filter 0 only
    ihdr[12] = 0; // no interlace
    if (linux_png_chunk(out, out_cap, &pos, "IHDR", ihdr, 13) != 0) return -2;

    // Raw deflate payload, assembled on the stack frame of the caller via
    // direct chunk emission below: header + stored blocks + adler32.
    // First compute the Adler32 over filter bytes + pixel bytes.
    const uint32_t MOD = 65521u;
    uint32_t a = 1, b = 0;
    for (int y = 0; y < h; y++) {
        uint8_t f = 0;
        a += f; if (a >= MOD) a -= MOD; b += a; if (b >= MOD) b -= MOD;
        const uint8_t *row = rgba + (size_t)y * (size_t)w * 4;
        for (size_t i = 0; i < (size_t)w * 4; i++) {
            a += row[i]; if (a >= MOD) a -= MOD; b += a; if (b >= MOD) b -= MOD;
        }
    }

    // Total raw length (filter bytes + pixels) determines IDAT sizing.
    size_t raw_len = (size_t)h * ((size_t)4 * (uint32_t)w + 1);
    size_t n_blocks = (raw_len + 65534) / 65535; // ceil, raw_len > 0
    if (n_blocks == 0) n_blocks = 1;
    // IDAT body: 2-byte zlib header + per-block 5-byte headers + raw + adler.
    size_t idat_len = 2 + n_blocks * 5 + raw_len + 4;
    // Emit IDAT via chunk header reservation: write chunk framing manually
    // since the body streams out piecewise.
    if (pos + 12 + idat_len > out_cap) return -2;
    linux_png_put32be(out + pos, (uint32_t)idat_len);
    memcpy(out + pos + 4, "IDAT", 4);
    size_t bp = pos + 8; // body cursor
    pos += 12 + idat_len; // final chunk end (crc filled after body)
    out[bp++] = 0x78;
    out[bp++] = 0x01;
    size_t remaining = raw_len;
    int y = 0;
    size_t row_off = 0; // 0 = filter byte pending, else 1 + pixel offset
    while (remaining > 0) {
        size_t take = remaining > 65535 ? 65535 : remaining;
        int last = (take == remaining) ? 1 : 0;
        out[bp++] = (uint8_t)last;
        out[bp++] = (uint8_t)(take & 0xFF);
        out[bp++] = (uint8_t)((take >> 8) & 0xFF);
        out[bp++] = (uint8_t)(~take & 0xFF);
        out[bp++] = (uint8_t)((~take >> 8) & 0xFF);
        for (size_t i = 0; i < take; i++) {
            if (row_off == 0) {
                out[bp++] = 0; // filter type 0
                row_off = 1;
            } else {
                const uint8_t *row = rgba + (size_t)y * (size_t)w * 4;
                out[bp++] = row[row_off - 1];
                row_off++;
                if (row_off - 1 >= (size_t)4 * (uint32_t)w) {
                    y++;
                    row_off = 0;
                }
            }
        }
        remaining -= take;
    }
    linux_png_put32be(out + bp, (b << 16) | a);
    bp += 4;
    // CRC over "IDAT" + body.
    uint32_t c = 0xFFFFFFFFu;
    linux_png_crc_init();
    const char idat_tag[4] = { 'I', 'D', 'A', 'T' };
    for (int i = 0; i < 4; i++)
        c = linux_png_crc_table[(c ^ (uint8_t)idat_tag[i]) & 0xFF] ^ (c >> 8);
    // CRC over "IDAT" + body. Note pos was already advanced past the
    // chunk: the body runs [pos-idat_len-4, bp) (chunk start + 8), and the
    // 4 tag bytes before it were fed manually above.
    for (size_t i = pos - idat_len - 4; i < bp; i++)
        c = linux_png_crc_table[(c ^ out[i]) & 0xFF] ^ (c >> 8);
    linux_png_put32be(out + bp, c ^ 0xFFFFFFFFu);

    if (linux_png_chunk(out, out_cap, &pos, "IEND", NULL, 0) != 0) return -2;
    *out_len = pos;
    return 0;
}

#endif // READ_LINUX_PNG_H
