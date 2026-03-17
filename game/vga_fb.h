#ifndef VGA_FB_H
#define VGA_FB_H

#define VGA_FB_WIDTH 160u
#define VGA_FB_HEIGHT 120u
#define VGA_FB_BASE_ADDR 0x50000000u
#define VGA_FB_BUFFER_STRIDE 0x00004000u
#define VGA_FB_CTRL_ADDR 0x50007FFCu

void vga_fb_clear(unsigned char color);
void vga_fb_put_pixel(unsigned int x, unsigned int y, unsigned char color);
void vga_fb_fill_rect4(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned char color);
void vga_fb_set_draw_buffer(unsigned int index);
void vga_fb_present(void);
int vga_fb_present_sync(void);
void vga_fb_swap_draw_buffer(void);
unsigned int vga_fb_draw_buffer_index(void);
unsigned int vga_fb_display_buffer_index(void);

#endif
