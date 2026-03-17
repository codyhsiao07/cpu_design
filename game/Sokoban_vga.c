#include "games_shared_ui.h"
#include "vga_fb.h"
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
#include "launcher_jump.h"
#endif

#define SCREEN_W 160u
#define SCREEN_H 120u

#define TITLE_X 4u
#define TITLE_Y 4u
#define TITLE_W 152u
#define TITLE_H 12u

#define FIELD_PANEL_X 6u
#define FIELD_PANEL_Y 18u
#define FIELD_PANEL_W 104u
#define FIELD_PANEL_H 78u
#define FIELD_X 10u
#define FIELD_Y 22u

#define SIDE_X 114u
#define SIDE_Y 18u
#define SIDE_W 42u
#define SIDE_H 78u

#define FOOTER_X 4u
#define FOOTER_Y 100u
#define FOOTER_W 152u
#define FOOTER_H 16u

#define OVERLAY_X 24u
#define OVERLAY_Y 34u
#define OVERLAY_W 112u
#define OVERLAY_H 46u

#define LEVEL_W 12
#define LEVEL_H 9
#define LEVEL_COUNT 8u
#define CELL_SHIFT 3
#define CELL_PIXELS 8u
#define FIELD_W (LEVEL_W * CELL_PIXELS)
#define FIELD_H (LEVEL_H * CELL_PIXELS)

#define TILE_FLOOR 0u
#define TILE_WALL 1u
#define TILE_GOAL 2u

#define MODE_PLAY 0
#define MODE_CLEAR 1
#define MODE_FINISH 2

#define POLL_SPIN 2600u

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 6u
#define COLOR_TEXT 7u
#define COLOR_LABEL 14u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_ACCENT 4u
#define COLOR_OVERLAY 12u
#define COLOR_FLOOR 9u
#define COLOR_FLOOR_DOT 8u
#define COLOR_WALL 11u
#define COLOR_WALL_EDGE 8u
#define COLOR_GOAL 3u
#define COLOR_GOAL_RING 15u
#define COLOR_BOX 4u
#define COLOR_BOX_EDGE 1u
#define COLOR_BOX_ON_GOAL 2u
#define COLOR_PLAYER 6u
#define COLOR_PLAYER_FACE 15u

static const char *const level0_rows[LEVEL_H] = {
    "############",
    "#   ###    #",
    "# .$ #   ###",
    "# #  # .   #",
    "# #$   ##  #",
    "#   ##  $  #",
    "# .   # @  #",
    "#          #",
    "############"
};

static const char *const level1_rows[LEVEL_H] = {
    "############",
    "#    ####  #",
    "# .  #  #  #",
    "# #  $ .#  #",
    "# #  #  ####",
    "#   ##     #",
    "#   . $  $ #",
    "#  @       #",
    "############"
};

static const char *const level2_rows[LEVEL_H] = {
    "############",
    "#    ####  #",
    "# .  #  #  #",
    "# #$   .#  #",
    "# #  #  ####",
    "#   ##   $ #",
    "#   .    $ #",
    "#      @   #",
    "############"
};

static const char *const level3_rows[LEVEL_H] = {
    "############",
    "#    ####  #",
    "# . $#  #  #",
    "# #    .#  #",
    "# #  # @####",
    "# $$##     #",
    "#   .      #",
    "#          #",
    "############"
};

static const char *const level4_rows[LEVEL_H] = {
    "############",
    "#    ####  #",
    "# .  #  #  #",
    "# #    .#  #",
    "# #  #$ ####",
    "# $ ##     #",
    "#   . $  @ #",
    "#          #",
    "############"
};

static const char *const level5_rows[LEVEL_H] = {
    "############",
    "#  @ ####  #",
    "# . $#  #  #",
    "# #$   .#  #",
    "# #  #  ####",
    "#   ##   $ #",
    "#   .      #",
    "#          #",
    "############"
};

static const char *const level6_rows[LEVEL_H] = {
    "############",
    "#  ####    #",
    "#  #  #$ . #",
    "#  #.    # #",
    "####@ #  # #",
    "#     ##$$ #",
    "#      .   #",
    "#          #",
    "############"
};

static const char *const level7_rows[LEVEL_H] = {
    "############",
    "#  #### @  #",
    "#  #  #$ . #",
    "#  #.   $# #",
    "####  #  # #",
    "# $   ##   #",
    "#      .   #",
    "#          #",
    "############"
};

static unsigned char base_map[LEVEL_H][LEVEL_W];
static unsigned char box_map[LEVEL_H][LEVEL_W];
static unsigned char shown_field[LEVEL_H][LEVEL_W];

static int player_x;
static int player_y;
static unsigned int level_index = 0u;
static unsigned int move_count = 0u;
static unsigned int push_count = 0u;
static int mode = MODE_PLAY;
static int scene_valid = 0;
static int need_redraw = 1;
static int chrome_redraw = 1;
static int swallow_lf = 0;
static int field_full_redraw = 1;

static void video_reset(void)
{
    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();
}

static void fill_rect(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned char color)
{
    unsigned int xx;
    unsigned int yy;

    if (x >= SCREEN_W || y >= SCREEN_H || w == 0u || h == 0u) {
        return;
    }
    if ((x + w) > SCREEN_W) {
        w = SCREEN_W - x;
    }
    if ((y + h) > SCREEN_H) {
        h = SCREEN_H - y;
    }

    if (((x & 3u) == 0u) && ((w & 3u) == 0u)) {
        vga_fb_fill_rect4(x, y, w, h, color);
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
    static const unsigned char glyph_colon[5] = {0x0, 0x2, 0x0, 0x2, 0x0};
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
    static const unsigned char glyph_f[5] = {0x7, 0x4, 0x6, 0x4, 0x4};
    static const unsigned char glyph_g[5] = {0x7, 0x4, 0x5, 0x5, 0x7};
    static const unsigned char glyph_h[5] = {0x5, 0x5, 0x7, 0x5, 0x5};
    static const unsigned char glyph_i[5] = {0x7, 0x2, 0x2, 0x2, 0x7};
    static const unsigned char glyph_j[5] = {0x1, 0x1, 0x1, 0x5, 0x7};
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
    static const unsigned char glyph_x[5] = {0x5, 0x5, 0x2, 0x5, 0x5};
    static const unsigned char glyph_y[5] = {0x5, 0x5, 0x2, 0x2, 0x2};
    static const unsigned char glyph_z[5] = {0x7, 0x1, 0x2, 0x4, 0x7};

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
    case 'F': return glyph_f;
    case 'G': return glyph_g;
    case 'H': return glyph_h;
    case 'I': return glyph_i;
    case 'J': return glyph_j;
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
    case 'X': return glyph_x;
    case 'Y': return glyph_y;
    case 'Z': return glyph_z;
    case '-': return glyph_dash;
    case ':': return glyph_colon;
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

static void draw_text_raw(unsigned int x, unsigned int y, const char *text, unsigned int scale, unsigned char color)
{
    unsigned int step = scale << 2;

    while (*text != '\0') {
        draw_char(x, y, *text, scale, color);
        x += step;
        text++;
    }
}

static void draw_text(unsigned int x, unsigned int y, const char *text, unsigned int scale, unsigned char color)
{
    if (color != COLOR_TEXT_SHADOW) {
        draw_text_raw(x + 1u, y + 1u, text, scale, COLOR_TEXT_SHADOW);
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

static void draw_uint(unsigned int x, unsigned int y, unsigned int scale, unsigned int value, unsigned char color)
{
    static const unsigned int div_table[10] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    char buf[11];
    unsigned int i;
    unsigned int index = 0u;
    int started = 0;

    for (i = 0u; i < 10u; i++) {
        unsigned int digit = 0u;
        while (value >= div_table[i]) {
            value -= div_table[i];
            digit++;
        }
        if (digit != 0u || started || i == 9u) {
            buf[index++] = (char)('0' + digit);
            started = 1;
        }
    }
    buf[index] = '\0';
    draw_text(x, y, buf, scale, color);
}

static void invalidate_field_cache(void)
{
    int row;
    int col;

    for (row = 0; row < LEVEL_H; row++) {
        for (col = 0; col < LEVEL_W; col++) {
            shown_field[row][col] = 0xFFu;
        }
    }
}

static void invalidate_field_cell(int row, int col)
{
    if (row < 0 || row >= LEVEL_H || col < 0 || col >= LEVEL_W) {
        return;
    }
    shown_field[row][col] = 0xFFu;
}

static const char *level_row(unsigned int level, unsigned int row)
{
    if (level == 0u) {
        return level0_rows[row];
    }
    if (level == 1u) {
        return level1_rows[row];
    }
    if (level == 2u) {
        return level2_rows[row];
    }
    if (level == 3u) {
        return level3_rows[row];
    }
    if (level == 4u) {
        return level4_rows[row];
    }
    if (level == 5u) {
        return level5_rows[row];
    }
    if (level == 6u) {
        return level6_rows[row];
    }
    return level7_rows[row];
}

static unsigned int remaining_goals(void)
{
    unsigned int count = 0u;
    int row;
    int col;

    for (row = 0; row < LEVEL_H; row++) {
        for (col = 0; col < LEVEL_W; col++) {
            if (base_map[row][col] == TILE_GOAL && box_map[row][col] == 0u) {
                count++;
            }
        }
    }
    return count;
}

static void mark_mode(int next_mode)
{
    mode = next_mode;
    chrome_redraw = 1;
    need_redraw = 1;
}

static void load_level(unsigned int index)
{
    int row;
    int col;

    level_index = index;
    move_count = 0u;
    push_count = 0u;
    swallow_lf = 0;
    scene_valid = 0;
    chrome_redraw = 1;
    need_redraw = 1;
    field_full_redraw = 1;
    mode = MODE_PLAY;

    for (row = 0; row < LEVEL_H; row++) {
        const char *row_text = level_row(index, (unsigned int)row);
        for (col = 0; col < LEVEL_W; col++) {
            char ch = row_text[col];

            base_map[row][col] = TILE_FLOOR;
            box_map[row][col] = 0u;

            if (ch == '#') {
                base_map[row][col] = TILE_WALL;
            } else if (ch == '.') {
                base_map[row][col] = TILE_GOAL;
            } else if (ch == '$') {
                box_map[row][col] = 1u;
            } else if (ch == '*') {
                base_map[row][col] = TILE_GOAL;
                box_map[row][col] = 1u;
            } else if (ch == '@') {
                player_x = col;
                player_y = row;
            } else if (ch == '+') {
                base_map[row][col] = TILE_GOAL;
                player_x = col;
                player_y = row;
            }
        }
    }

    invalidate_field_cache();
}

static int in_bounds(int x, int y)
{
    return (x >= 0) && (x < LEVEL_W) && (y >= 0) && (y < LEVEL_H);
}

static void maybe_finish_level(void)
{
    if (remaining_goals() != 0u) {
        return;
    }

    if ((level_index + 1u) < LEVEL_COUNT) {
        mark_mode(MODE_CLEAR);
    } else {
        mark_mode(MODE_FINISH);
    }
}

static void try_move_player(int dx, int dy)
{
    int old_x;
    int old_y;
    int next_x;
    int next_y;

    if (mode != MODE_PLAY) {
        return;
    }

    old_x = player_x;
    old_y = player_y;
    next_x = player_x + dx;
    next_y = player_y + dy;

    if (!in_bounds(next_x, next_y) || base_map[next_y][next_x] == TILE_WALL) {
        return;
    }

    if (box_map[next_y][next_x] != 0u) {
        int beyond_x = next_x + dx;
        int beyond_y = next_y + dy;

        if (!in_bounds(beyond_x, beyond_y) ||
            base_map[beyond_y][beyond_x] == TILE_WALL ||
            box_map[beyond_y][beyond_x] != 0u) {
            return;
        }

        box_map[next_y][next_x] = 0u;
        box_map[beyond_y][beyond_x] = 1u;
        player_x = next_x;
        player_y = next_y;
        move_count++;
        push_count++;
        chrome_redraw = 1;
        need_redraw = 1;
        invalidate_field_cell(old_y, old_x);
        invalidate_field_cell(next_y, next_x);
        invalidate_field_cell(beyond_y, beyond_x);
        maybe_finish_level();
        return;
    }

    player_x = next_x;
    player_y = next_y;
    move_count++;
    chrome_redraw = 1;
    need_redraw = 1;
    invalidate_field_cell(old_y, old_x);
    invalidate_field_cell(next_y, next_x);
}

static unsigned char cell_visual_code(int row, int col)
{
    unsigned char visual = base_map[row][col];

    if (box_map[row][col] != 0u) {
        visual = (unsigned char)(visual | 0x10u);
    }
    if (player_x == col && player_y == row) {
        visual = (unsigned char)(visual | 0x20u);
    }
    return visual;
}

static void draw_floor(unsigned int px, unsigned int py)
{
    fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, COLOR_FLOOR);
    vga_fb_put_pixel(px + 1u, py + 1u, COLOR_FLOOR_DOT);
    vga_fb_put_pixel(px + 6u, py + 2u, COLOR_FLOOR_DOT);
    vga_fb_put_pixel(px + 3u, py + 6u, COLOR_FLOOR_DOT);
}

static void draw_wall(unsigned int px, unsigned int py)
{
    fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, COLOR_WALL);
    fill_rect(px, py, CELL_PIXELS, 1u, COLOR_WALL_EDGE);
    fill_rect(px, py + CELL_PIXELS - 1u, CELL_PIXELS, 1u, COLOR_WALL_EDGE);
    fill_rect(px, py, 1u, CELL_PIXELS, COLOR_WALL_EDGE);
    fill_rect(px + CELL_PIXELS - 1u, py, 1u, CELL_PIXELS, COLOR_WALL_EDGE);
    fill_rect(px + 1u, py + 2u, CELL_PIXELS - 2u, 1u, COLOR_PANEL);
    fill_rect(px + 2u, py + 4u, CELL_PIXELS - 4u, 1u, COLOR_PANEL);
    fill_rect(px + 1u, py + 6u, CELL_PIXELS - 2u, 1u, COLOR_PANEL);
}

static void draw_goal(unsigned int px, unsigned int py)
{
    draw_floor(px, py);
    fill_rect(px + 2u, py + 2u, 4u, 4u, COLOR_GOAL_RING);
    fill_rect(px + 3u, py + 3u, 2u, 2u, COLOR_GOAL);
}

static void draw_box(unsigned int px, unsigned int py, int on_goal)
{
    unsigned char fill = on_goal ? COLOR_BOX_ON_GOAL : COLOR_BOX;

    fill_rect(px + 1u, py + 1u, 6u, 6u, fill);
    fill_rect(px + 1u, py + 1u, 6u, 1u, COLOR_BOX_EDGE);
    fill_rect(px + 1u, py + 6u, 6u, 1u, COLOR_BOX_EDGE);
    fill_rect(px + 1u, py + 1u, 1u, 6u, COLOR_BOX_EDGE);
    fill_rect(px + 6u, py + 1u, 1u, 6u, COLOR_BOX_EDGE);
    fill_rect(px + 3u, py + 1u, 1u, 6u, COLOR_BOX_EDGE);
    fill_rect(px + 1u, py + 3u, 6u, 1u, COLOR_BOX_EDGE);
}

static void draw_player(unsigned int px, unsigned int py)
{
    fill_rect(px + 1u, py + 1u, 6u, 6u, COLOR_PLAYER);
    fill_rect(px + 2u, py + 2u, 4u, 4u, COLOR_PANEL);
    vga_fb_put_pixel(px + 2u, py + 2u, COLOR_PLAYER_FACE);
    vga_fb_put_pixel(px + 5u, py + 2u, COLOR_PLAYER_FACE);
    fill_rect(px + 3u, py + 5u, 2u, 1u, COLOR_PLAYER_FACE);
}

static void draw_field_cell(int row, int col)
{
    unsigned int px = FIELD_X + ((unsigned int)col << CELL_SHIFT);
    unsigned int py = FIELD_Y + ((unsigned int)row << CELL_SHIFT);
    int on_goal = base_map[row][col] == TILE_GOAL;

    if (base_map[row][col] == TILE_WALL) {
        draw_wall(px, py);
    } else if (on_goal) {
        draw_goal(px, py);
    } else {
        draw_floor(px, py);
    }

    if (box_map[row][col] != 0u) {
        draw_box(px, py, on_goal);
    }
    if (player_x == col && player_y == row) {
        draw_player(px, py);
    }
}

static void draw_static_scene(void)
{
    vga_fb_clear(COLOR_BG);
    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FIELD_PANEL_X, FIELD_PANEL_Y, FIELD_PANEL_W, FIELD_PANEL_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FIELD_X - 3u, FIELD_Y - 3u, FIELD_W + 6u, FIELD_H + 6u, COLOR_FRAME, COLOR_ACCENT);
    fill_rect(FIELD_X - 1u, FIELD_Y - 1u, FIELD_W + 2u, FIELD_H + 2u, COLOR_CARD);
    draw_frame(SIDE_X, SIDE_Y, SIDE_W, SIDE_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FOOTER_X, FOOTER_Y, FOOTER_W, FOOTER_H, COLOR_FRAME, COLOR_PANEL);
    draw_text_centered(FOOTER_X, FOOTER_Y + 2u, FOOTER_W, "WASD MOVE  R RESET  N17 MENU", 1u, COLOR_TEXT);
    draw_text_centered(FOOTER_X, FOOTER_Y + 8u, FOOTER_W, "PUSH BOXES ONTO GOALS", 1u, COLOR_LABEL);
    scene_valid = 1;
}

static void render_title(void)
{
    fill_rect(TITLE_X + 1u, TITLE_Y + 1u, TITLE_W - 2u, TITLE_H - 2u, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    draw_text_centered(TITLE_X, TITLE_Y + 3u, TITLE_W, "SOKOBAN", 2u, COLOR_TEXT);
}

static void render_field(int force_full)
{
    int row;
    int col;

    if (force_full || field_full_redraw) {
        fill_rect(FIELD_X, FIELD_Y, FIELD_W, FIELD_H, COLOR_CARD);
        invalidate_field_cache();
    }

    for (row = 0; row < LEVEL_H; row++) {
        for (col = 0; col < LEVEL_W; col++) {
            unsigned char visual = cell_visual_code(row, col);
            if (shown_field[row][col] != visual) {
                draw_field_cell(row, col);
                shown_field[row][col] = visual;
            }
        }
    }

    field_full_redraw = 0;
}

static const char *state_text(void)
{
    if (mode == MODE_PLAY) {
        return "PLAY";
    }
    if (mode == MODE_CLEAR) {
        return "CLEAR";
    }
    return "DONE";
}

static const char *overlay_title(void)
{
    if (mode == MODE_CLEAR) {
        return "LEVEL CLEAR";
    }
    return "ALL CLEAR";
}

static const char *overlay_hint(void)
{
    if (mode == MODE_CLEAR) {
        return "SPC NEXT  R RETRY  N17 MENU";
    }
    return "SPC RESTART  N17 MENU";
}

static void render_side_panel(int force_full)
{
    if (!force_full && !chrome_redraw) {
        return;
    }

    fill_rect(SIDE_X + 1u, SIDE_Y + 1u, SIDE_W - 2u, SIDE_H - 2u, COLOR_PANEL);
    fill_rect(SIDE_X + 2u, SIDE_Y + 2u, SIDE_W - 4u, 2u, COLOR_ACCENT);

    draw_text_centered(SIDE_X, SIDE_Y + 7u, SIDE_W, "LV", 1u, COLOR_LABEL);
    draw_uint(SIDE_X + 18u, SIDE_Y + 14u, 1u, level_index + 1u, COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 25u, SIDE_W, "MOVE", 1u, COLOR_LABEL);
    draw_uint(SIDE_X + 12u, SIDE_Y + 32u, 1u, move_count, COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 43u, SIDE_W, "PUSH", 1u, COLOR_LABEL);
    draw_uint(SIDE_X + 12u, SIDE_Y + 50u, 1u, push_count, COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 61u, SIDE_W, "LEFT", 1u, COLOR_LABEL);
    draw_uint(SIDE_X + 12u, SIDE_Y + 68u, 1u, remaining_goals(), COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 72u, SIDE_W, state_text(), 1u, COLOR_LABEL);
    chrome_redraw = 0;
}

static void render_overlay(void)
{
    if (mode == MODE_PLAY) {
        return;
    }

    draw_frame(OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H, COLOR_FRAME, COLOR_OVERLAY);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 11u, OVERLAY_W, overlay_title(), 1u, COLOR_TEXT);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 24u, OVERLAY_W, overlay_hint(), 1u, COLOR_LABEL);
}

static void render_scene(void)
{
    int force_full = 0;

    if (!scene_valid) {
        draw_static_scene();
        force_full = 1;
    }

    render_title();
    render_field(force_full);
    render_side_panel(force_full);
    render_overlay();
    need_redraw = 0;
}

static void advance_after_clear(void)
{
    if (mode == MODE_PLAY) {
        return;
    }

    if (mode == MODE_CLEAR) {
        load_level(level_index + 1u);
    } else {
        load_level(0u);
    }
}

static int handle_input(int ch)
{
    ch = ui_to_lower(ch);

    if (swallow_lf && ch == '\n') {
        swallow_lf = 0;
        return 0;
    }
    swallow_lf = 0;

    if (ch == 'q') {
        return -1;
    }
    if (ch == 'r') {
        load_level(level_index);
        return 0;
    }
    if (mode != MODE_PLAY) {
        if (ch == ' ' || ch == 'n') {
            advance_after_clear();
            return 0;
        }
        if (ch == '\r') {
            swallow_lf = 1;
            advance_after_clear();
            return 0;
        }
        return 0;
    }

    switch (ch) {
    case 'w':
        try_move_player(0, -1);
        break;
    case 'a':
        try_move_player(-1, 0);
        break;
    case 's':
        try_move_player(0, 1);
        break;
    case 'd':
        try_move_player(1, 0);
        break;
    default:
        break;
    }

    return 0;
}

int main(void)
{
    ui_clear_screen();
    ui_puts("VGA Sokoban demo (160x120 framebuffer)\n");
    ui_puts("Use UART: w/a/s/d move, r reset, space next after clear, BTNC launcher menu.\n");
    ui_drain_input();

    video_reset();

    load_level(0u);

    while (1) {
        int ch = ui_read_byte_nonblocking();

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        if (ui_launcher_menu_requested()) {
            ui_input_barrier();
            ui_launcher_request_menu();
        }
#endif

        if (need_redraw) {
            render_scene();
        }

        if (ch >= 0) {
            if (handle_input(ch) < 0) {
                ui_puts("\nBye.\n");
                break;
            }
        }

        ui_short_pause(POLL_SPIN);
    }

    video_reset();
    return 0;
}
