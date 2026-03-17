#include "vga_fb.h"

#define VGA_FB_WORDS32 2400u
#define VGA_FB_WORDS16_PER_ROW 40u
#define VGA_FB_PRESENT_SYNC_POLLS 2000000u

static unsigned int vga_fb_draw_base = VGA_FB_BASE_ADDR;
static unsigned int vga_fb_draw_index = 0u;

static volatile unsigned int *vga_fb32_ptr(void)
{
    return (volatile unsigned int *)vga_fb_draw_base;
}

static volatile unsigned short *vga_fb16_ptr(void)
{
    return (volatile unsigned short *)vga_fb_draw_base;
}

void vga_fb_set_draw_buffer(unsigned int index)
{
    vga_fb_draw_index = index & 1u;
    vga_fb_draw_base = VGA_FB_BASE_ADDR + (vga_fb_draw_index * VGA_FB_BUFFER_STRIDE);
}

void vga_fb_present(void)
{
    (*(volatile unsigned int *)VGA_FB_CTRL_ADDR) = vga_fb_draw_index;
}

int vga_fb_present_sync(void)
{
    unsigned int polls = VGA_FB_PRESENT_SYNC_POLLS;
    unsigned int target = vga_fb_draw_index & 1u;

    vga_fb_present();
    while (polls != 0u) {
        if (((*(volatile unsigned int *)VGA_FB_CTRL_ADDR) & 1u) == target) {
            return 1;
        }
        polls--;
    }
    return 0;
}

void vga_fb_swap_draw_buffer(void)
{
    vga_fb_set_draw_buffer(vga_fb_draw_index ^ 1u);
}

unsigned int vga_fb_draw_buffer_index(void)
{
    return vga_fb_draw_index;
}

unsigned int vga_fb_display_buffer_index(void)
{
    return (*(volatile unsigned int *)VGA_FB_CTRL_ADDR) & 1u;
}

static unsigned short vga_fb_pack4(unsigned char color)
{
    unsigned short c = (unsigned short)(color & 0x0Fu);
    return (unsigned short)((c << 12) | (c << 8) | (c << 4) | c);
}

void vga_fb_clear(unsigned char color)
{
    unsigned int i;
    unsigned int word = (unsigned int)vga_fb_pack4(color);
    volatile unsigned int *fb32 = vga_fb32_ptr();
    word |= (word << 16);

    for (i = 0u; i < VGA_FB_WORDS32; i++) {
        fb32[i] = word;
    }
}

void vga_fb_put_pixel(unsigned int x, unsigned int y, unsigned char color)
{
    unsigned int word_index;
    unsigned int nibble_sel;
    unsigned short shift;
    unsigned short mask;
    unsigned short value;
    volatile unsigned short *fb16 = vga_fb16_ptr();

    if (x >= VGA_FB_WIDTH || y >= VGA_FB_HEIGHT) {
        return;
    }

    word_index = (y << 5) + (y << 3) + (x >> 2);
    nibble_sel = x & 3u;
    shift = (unsigned short)((3u - nibble_sel) << 2);
    mask = (unsigned short)(0xFu << shift);
    value = fb16[word_index];
    value = (unsigned short)((value & (unsigned short)(~mask)) | ((unsigned short)(color & 0x0Fu) << shift));
    fb16[word_index] = value;
}

void vga_fb_fill_rect4(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned char color)
{
    unsigned int row;
    unsigned int col_word;
    unsigned int row_base;
    unsigned short packed;
    volatile unsigned short *fb16 = vga_fb16_ptr();

    if (x >= VGA_FB_WIDTH || y >= VGA_FB_HEIGHT || w == 0u || h == 0u) {
        return;
    }
    if ((x & 3u) != 0u || (w & 3u) != 0u) {
        return;
    }
    if ((x + w) > VGA_FB_WIDTH || (y + h) > VGA_FB_HEIGHT) {
        return;
    }

    packed = vga_fb_pack4(color);
    for (row = 0u; row < h; row++) {
        row_base = ((y + row) << 5) + ((y + row) << 3) + (x >> 2);
        for (col_word = 0u; col_word < (w >> 2); col_word++) {
            fb16[row_base + col_word] = packed;
        }
    }
}
