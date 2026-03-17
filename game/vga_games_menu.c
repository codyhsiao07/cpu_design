#include "vga_fb.h"
#include "games_shared_ui.h"
#include "launcher_jump.h"
#include "launcher_slots.h"

#define COLOR_BG 0u
#define COLOR_PANEL 1u
#define COLOR_PANEL_ALT 2u
#define COLOR_TEXT 15u
#define COLOR_TEXT_DIM 7u
#define COLOR_ACCENT 14u
#define COLOR_ACCENT_DARK 6u
#define COLOR_CARD 3u
#define COLOR_CARD_ALT 5u
#define COLOR_CARD_TEXT 15u
#define COLOR_CARD_DIM 11u

#define MENU_COLS 3u
#define MENU_ROWS 3u
#define CARD_W 46u
#define CARD_H 24u
#define CARD_GAP_X 5u
#define CARD_GAP_Y 5u
#define CARD_X0 7u
#define CARD_Y0 24u
#define POLL_SPIN 1800u

static int menu_selection = 0;
static int swallow_lf = 0;
static int need_redraw = 1;

static int handle_menu_input(int ch);

static const char *menu_title_for(unsigned int index)
{
    switch (index) {
    case 0u: return "TETRIS";
    case 1u: return "GOMOKU";
    case 2u: return "BREAKOUT";
    case 3u: return "SNAKE";
    case 4u: return "MINES";
    case 5u: return "BOMBER";
    case 6u: return "SOKOBAN";
    case 7u: return "PACMAN";
    default: return "CHESS";
    }
}

static void launch_game_slot(int selection)
{
    ui_input_barrier();
    ui_launcher_sync_button_state();
    ui_launcher_ignore_button_polls(2048u);
    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_present();

    switch (selection) {
    case 0:
        launcher_jump_to_address(LAUNCHER_TETRIS_ADDR);
        break;
    case 1:
        launcher_jump_to_address(LAUNCHER_GOMOKU_ADDR);
        break;
    case 2:
        launcher_jump_to_address(LAUNCHER_BREAKOUT_ADDR);
        break;
    case 3:
        launcher_jump_to_address(LAUNCHER_SNAKE_ADDR);
        break;
    case 4:
        launcher_jump_to_address(LAUNCHER_MINES_ADDR);
        break;
    case 5:
        launcher_jump_to_address(LAUNCHER_BOMBER_ADDR);
        break;
    case 6:
        launcher_jump_to_address(LAUNCHER_SOKOBAN_ADDR);
        break;
    case 7:
        launcher_jump_to_address(LAUNCHER_PACMAN_ADDR);
        break;
    default:
        launcher_jump_to_address(LAUNCHER_CHESS_ADDR);
        break;
    }
}

static unsigned int menu_col_for(unsigned int index)
{
    while (index >= MENU_COLS) {
        index -= MENU_COLS;
    }
    return index;
}

static unsigned int menu_row_for(unsigned int index)
{
    unsigned int row = 0u;

    while (index >= MENU_COLS) {
        index -= MENU_COLS;
        row++;
    }
    return row;
}

static int menu_index_for(int col, int row)
{
    return (row * 3) + col;
}

static void fill_rect(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned char color)
{
    unsigned int yy;
    unsigned int xx;

    if (w == 0u || h == 0u) {
        return;
    }

    for (yy = 0u; yy < h; yy++) {
        for (xx = 0u; xx < w; xx++) {
            vga_fb_put_pixel(x + xx, y + yy, color);
        }
    }
}

static void draw_frame(unsigned int x, unsigned int y, unsigned int w, unsigned int h,
                       unsigned char frame_color, unsigned char fill_color)
{
    fill_rect(x, y, w, h, frame_color);
    if (w > 2u && h > 2u) {
        fill_rect(x + 1u, y + 1u, w - 2u, h - 2u, fill_color);
    }
}

static void draw_block(unsigned int x, unsigned int y, unsigned int scale, unsigned char color)
{
    fill_rect(x, y, scale, scale, color);
}

static const unsigned char *glyph_rows_for(int ch)
{
    static const unsigned char glyph_space[5] = {0x0, 0x0, 0x0, 0x0, 0x0};
    static const unsigned char glyph_dash[5] = {0x0, 0x0, 0x7, 0x0, 0x0};
    static const unsigned char glyph_0[5] = {0x7, 0x5, 0x5, 0x5, 0x7};
    static const unsigned char glyph_1[5] = {0x2, 0x6, 0x2, 0x2, 0x7};
    static const unsigned char glyph_2[5] = {0x7, 0x1, 0x7, 0x4, 0x7};
    static const unsigned char glyph_3[5] = {0x7, 0x1, 0x7, 0x1, 0x7};
    static const unsigned char glyph_4[5] = {0x5, 0x5, 0x7, 0x1, 0x1};
    static const unsigned char glyph_5[5] = {0x7, 0x4, 0x7, 0x1, 0x7};
    static const unsigned char glyph_6[5] = {0x7, 0x4, 0x7, 0x5, 0x7};
    static const unsigned char glyph_7[5] = {0x7, 0x1, 0x2, 0x2, 0x2};
    static const unsigned char glyph_8[5] = {0x7, 0x5, 0x7, 0x5, 0x7};
    static const unsigned char glyph_9[5] = {0x7, 0x5, 0x7, 0x1, 0x7};
    static const unsigned char glyph_a[5] = {0x2, 0x5, 0x7, 0x5, 0x5};
    static const unsigned char glyph_b[5] = {0x6, 0x5, 0x6, 0x5, 0x6};
    static const unsigned char glyph_c[5] = {0x7, 0x4, 0x4, 0x4, 0x7};
    static const unsigned char glyph_d[5] = {0x6, 0x5, 0x5, 0x5, 0x6};
    static const unsigned char glyph_e[5] = {0x7, 0x4, 0x6, 0x4, 0x7};
    static const unsigned char glyph_g[5] = {0x7, 0x4, 0x5, 0x5, 0x7};
    static const unsigned char glyph_h[5] = {0x5, 0x5, 0x7, 0x5, 0x5};
    static const unsigned char glyph_i[5] = {0x7, 0x2, 0x2, 0x2, 0x7};
    static const unsigned char glyph_k[5] = {0x5, 0x5, 0x6, 0x5, 0x5};
    static const unsigned char glyph_l[5] = {0x4, 0x4, 0x4, 0x4, 0x7};
    static const unsigned char glyph_m[5] = {0x5, 0x7, 0x7, 0x5, 0x5};
    static const unsigned char glyph_n[5] = {0x5, 0x7, 0x7, 0x7, 0x5};
    static const unsigned char glyph_o[5] = {0x7, 0x5, 0x5, 0x5, 0x7};
    static const unsigned char glyph_p[5] = {0x6, 0x5, 0x6, 0x4, 0x4};
    static const unsigned char glyph_q[5] = {0x7, 0x5, 0x5, 0x7, 0x1};
    static const unsigned char glyph_r[5] = {0x6, 0x5, 0x6, 0x5, 0x5};
    static const unsigned char glyph_s[5] = {0x7, 0x4, 0x7, 0x1, 0x7};
    static const unsigned char glyph_t[5] = {0x7, 0x2, 0x2, 0x2, 0x2};
    static const unsigned char glyph_u[5] = {0x5, 0x5, 0x5, 0x5, 0x7};
    static const unsigned char glyph_v[5] = {0x5, 0x5, 0x5, 0x5, 0x2};
    static const unsigned char glyph_w[5] = {0x5, 0x5, 0x7, 0x7, 0x5};
    static const unsigned char glyph_y[5] = {0x5, 0x5, 0x2, 0x2, 0x2};

    if (ch >= 'a' && ch <= 'z') {
        ch -= ('a' - 'A');
    }

    switch (ch) {
    case '0': return glyph_0;
    case '1': return glyph_1;
    case '2': return glyph_2;
    case '3': return glyph_3;
    case '4': return glyph_4;
    case '5': return glyph_5;
    case '6': return glyph_6;
    case '7': return glyph_7;
    case '8': return glyph_8;
    case '9': return glyph_9;
    case 'A': return glyph_a;
    case 'B': return glyph_b;
    case 'C': return glyph_c;
    case 'D': return glyph_d;
    case 'E': return glyph_e;
    case 'G': return glyph_g;
    case 'H': return glyph_h;
    case 'I': return glyph_i;
    case 'K': return glyph_k;
    case 'L': return glyph_l;
    case 'M': return glyph_m;
    case 'N': return glyph_n;
    case 'O': return glyph_o;
    case 'P': return glyph_p;
    case 'Q': return glyph_q;
    case 'R': return glyph_r;
    case 'S': return glyph_s;
    case 'T': return glyph_t;
    case 'U': return glyph_u;
    case 'V': return glyph_v;
    case 'W': return glyph_w;
    case 'Y': return glyph_y;
    case '-': return glyph_dash;
    case ' ': return glyph_space;
    default:  return glyph_space;
    }
}

static unsigned int text_width(const char *text, unsigned int scale)
{
    unsigned int width = 0u;
    unsigned int step = scale << 2;

    while (*text != '\0') {
        width += step;
        text++;
    }

    if (width == 0u) {
        return 0u;
    }
    return width - scale;
}

static void draw_char(unsigned int x, unsigned int y, int ch, unsigned int scale, unsigned char color)
{
    const unsigned char *rows = glyph_rows_for(ch);
    unsigned int row;
    unsigned int row_y = y;

    for (row = 0u; row < 5u; row++) {
        unsigned int col_x = x;

        if ((rows[row] & 0x4u) != 0u) {
            draw_block(col_x, row_y, scale, color);
        }
        col_x += scale;
        if ((rows[row] & 0x2u) != 0u) {
            draw_block(col_x, row_y, scale, color);
        }
        col_x += scale;
        if ((rows[row] & 0x1u) != 0u) {
            draw_block(col_x, row_y, scale, color);
        }
        row_y += scale;
    }
}

static void draw_text_raw(unsigned int x, unsigned int y, const char *text,
                          unsigned int scale, unsigned char color)
{
    unsigned int step = scale << 2;

    while (*text != '\0') {
        draw_char(x, y, *text, scale, color);
        x += step;
        text++;
    }
}

static void draw_text(unsigned int x, unsigned int y, const char *text,
                      unsigned int scale, unsigned char color)
{
    if (color != COLOR_BG) {
        draw_text_raw(x + 1u, y + 1u, text, scale, COLOR_BG);
    }
    draw_text_raw(x, y, text, scale, color);
}

static void draw_text_centered(unsigned int x, unsigned int y, unsigned int w,
                               const char *text, unsigned int scale, unsigned char color)
{
    unsigned int width = text_width(text, scale);
    unsigned int start_x = x;

    if (w > width) {
        start_x = x + ((w - width) >> 1);
    }
    draw_text(start_x, y, text, scale, color);
}

static void draw_background(void)
{
    unsigned int stripe_x;

    vga_fb_clear(COLOR_BG);
    fill_rect(0u, 0u, VGA_FB_WIDTH, 16u, COLOR_PANEL);
    fill_rect(0u, 16u, VGA_FB_WIDTH, 8u, COLOR_PANEL_ALT);
    fill_rect(0u, 110u, VGA_FB_WIDTH, 10u, COLOR_PANEL);

    for (stripe_x = 0u; stripe_x < VGA_FB_WIDTH; stripe_x += 16u) {
        fill_rect(stripe_x, 18u, 8u, 2u, COLOR_ACCENT_DARK);
    }
}

static void draw_card(unsigned int index, int selected)
{
    unsigned int col = menu_col_for(index);
    unsigned int row = menu_row_for(index);
    unsigned int x = CARD_X0 + (col * (CARD_W + CARD_GAP_X));
    unsigned int y = CARD_Y0 + (row * (CARD_H + CARD_GAP_Y));
    unsigned char frame_color = selected ? COLOR_ACCENT : COLOR_CARD_ALT;
    unsigned char fill_color = selected ? COLOR_CARD_ALT : COLOR_CARD;
    unsigned char title_color = selected ? COLOR_TEXT : COLOR_CARD_TEXT;
    unsigned char badge_color = selected ? COLOR_ACCENT : COLOR_PANEL_ALT;
    char badge[2];

    draw_frame(x, y, CARD_W, CARD_H, frame_color, fill_color);
    draw_frame(x + 2u, y + 2u, 11u, 8u, badge_color, COLOR_PANEL);

    badge[0] = (char)('1' + index);
    badge[1] = '\0';
    draw_text_centered(x + 2u, y + 3u, 11u, badge, 1u, COLOR_TEXT);
    draw_text_centered(x + 1u, y + 11u, CARD_W - 2u, menu_title_for(index), 1u, title_color);
    draw_text_centered(x + 1u, y + 17u, CARD_W - 2u,
                       selected ? "SPACE START" : "WASD MOVE", 1u,
                       selected ? COLOR_ACCENT : COLOR_CARD_DIM);
}

static void render_menu(void)
{
    unsigned int index;

    vga_fb_set_draw_buffer(0u);
    draw_background();
    draw_text_centered(0u, 4u, VGA_FB_WIDTH, "9 GAMES", 2u, COLOR_TEXT);
    draw_text_centered(0u, 18u, VGA_FB_WIDTH, "WASD SELECT  1-9 DIRECT", 1u, COLOR_TEXT_DIM);

    for (index = 0u; index < 9u; index++) {
        draw_card(index, (int)index == menu_selection);
    }

    draw_text_centered(0u, 112u, VGA_FB_WIDTH, "SPACE START  BTNC TO MENU", 1u, COLOR_TEXT);
    vga_fb_present();
    need_redraw = 0;
}

static void move_selection(int dx, int dy)
{
    int col = (int)menu_col_for((unsigned int)menu_selection);
    int row = (int)menu_row_for((unsigned int)menu_selection);
    int next_col = col + dx;
    int next_row = row + dy;

    if (next_col < 0 || next_col >= (int)MENU_COLS ||
        next_row < 0 || next_row >= (int)MENU_ROWS) {
        return;
    }

    menu_selection = menu_index_for(next_col, next_row);
    need_redraw = 1;
}

static void launch_selected_game(void)
{
    ui_puts("\nLaunching ");
    ui_puts(menu_title_for((unsigned int)menu_selection));
    ui_puts("...\n");
    launch_game_slot(menu_selection);
}

static void menu_runtime_init(void)
{
    ui_set_input_policy(UI_INPUT_POLICY_IGNORE_Q);
    ui_input_barrier();
    ui_launcher_sync_button_state();
    ui_launcher_ignore_button_polls(2048u);
    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_set_draw_buffer(1u);
    vga_fb_clear(0u);
    vga_fb_set_draw_buffer(0u);
    vga_fb_present();
    menu_selection = 0;
    swallow_lf = 0;
    need_redraw = 1;
}

__attribute__((noreturn)) void launcher_menu_reentry(void)
{
    menu_runtime_init();

    while (1) {
        int ch;

        if (need_redraw) {
            render_menu();
        }

        ch = ui_read_byte_nonblocking();
        if (ch >= 0) {
            (void)handle_menu_input(ch);
        }

        ui_short_pause(POLL_SPIN);
    }
}

__attribute__((noreturn)) void launcher_menu_soft_reset(void)
{
    ui_set_input_policy(UI_INPUT_POLICY_IGNORE_Q);
    ui_input_barrier();
    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_set_draw_buffer(1u);
    vga_fb_clear(0u);
    vga_fb_set_draw_buffer(0u);
    vga_fb_present();
    ui_launcher_request_menu();
    for (;;) {
    }
}

static int handle_menu_input(int ch)
{
    ch = ui_to_lower(ch);

    if (swallow_lf && ch == '\n') {
        swallow_lf = 0;
        return 0;
    }
    swallow_lf = 0;

    if (ch == 'w') {
        move_selection(0, -1);
        return 0;
    }
    if (ch == 's') {
        move_selection(0, 1);
        return 0;
    }
    if (ch == 'a') {
        move_selection(-1, 0);
        return 0;
    }
    if (ch == 'd') {
        move_selection(1, 0);
        return 0;
    }
    if (ch >= '1' && ch <= '9') {
        menu_selection = ch - '1';
        need_redraw = 1;
        launch_selected_game();
        return 1;
    }
    if (ch == '\n') {
        return 0;
    }
    if (ch == '\r') {
        swallow_lf = 1;
        launch_selected_game();
        return 1;
    }
    if (ch == ' ') {
        launch_selected_game();
        return 1;
    }
    return 0;
}

int main(void)
{
    ui_clear_screen();
    ui_puts("VGA launcher ready.\n");
    ui_puts("Use WASD or 1-9 to select, space to launch.\n");
    ui_puts("Press BTNC inside a game to return here.\n");

    launcher_menu_reentry();
}
