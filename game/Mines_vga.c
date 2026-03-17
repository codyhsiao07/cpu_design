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

#define BOARD_FRAME_X 20u
#define BOARD_FRAME_Y 18u
#define BOARD_FRAME_W 120u
#define BOARD_FRAME_H 84u
#define BOARD_X 24u
#define BOARD_Y 20u

#define FOOTER_X 4u
#define FOOTER_Y 104u
#define FOOTER_W 152u
#define FOOTER_H 12u

#define OVERLAY_X 28u
#define OVERLAY_Y 30u
#define OVERLAY_W 104u
#define OVERLAY_H 56u

#define POLL_SPIN 2600u

#define MAX_BOARD_W 14
#define MAX_BOARD_H 10
#define CELL_SHIFT 3
#define CELL_PIXELS 8u
#define BOARD_PIX_W (MAX_BOARD_W * CELL_PIXELS)
#define BOARD_PIX_H (MAX_BOARD_H * CELL_PIXELS)

#define MODE_SELECT 0
#define MODE_PLAY 1
#define MODE_WIN 2
#define MODE_LOSE 3

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 6u
#define COLOR_TEXT 7u
#define COLOR_LABEL 14u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_SHADOW 8u
#define COLOR_BOARD_BG 0u
#define COLOR_CELL_HIDDEN 9u
#define COLOR_CELL_TOP 14u
#define COLOR_CELL_BOTTOM 8u
#define COLOR_CELL_OPEN 15u
#define COLOR_CELL_OPEN_SHADOW 11u
#define COLOR_CURSOR 6u
#define COLOR_FLAG 1u
#define COLOR_MINE 4u
#define COLOR_MINE_BLAST 1u
#define COLOR_OVERLAY 12u

static const char *difficulty_names[3] = {"EASY", "NORMAL", "HARD"};
static const unsigned int difficulty_widths[3] = {10u, 12u, 14u};
static const unsigned int difficulty_heights[3] = {8u, 9u, 10u};
static const unsigned int difficulty_bombs[3] = {10u, 16u, 24u};
static const unsigned char difficulty_accents[3] = {2u, 4u, 1u};

static unsigned char mine_map[MAX_BOARD_H][MAX_BOARD_W];
static unsigned char adj_map[MAX_BOARD_H][MAX_BOARD_W];
static unsigned char revealed_map[MAX_BOARD_H][MAX_BOARD_W];
static unsigned char flagged_map[MAX_BOARD_H][MAX_BOARD_W];
static unsigned char prev_layout[MAX_BOARD_H][MAX_BOARD_W];
static unsigned char shown_visual[MAX_BOARD_H][MAX_BOARD_W];

static unsigned int board_w = 10u;
static unsigned int board_h = 8u;
static unsigned int board_bombs = 10u;
static unsigned int board_cells_total = 80u;
static unsigned int revealed_safe_count = 0u;
static unsigned int flag_count = 0u;
static unsigned int difficulty_index = 0u;
static unsigned int selected_difficulty = 0u;
static unsigned int board_generated = 0u;
static unsigned int board_nonce = 0u;
static unsigned int rng_state = 0x13579BDFu;
static unsigned int prev_layout_w = 0u;
static unsigned int prev_layout_h = 0u;
static unsigned int prev_layout_bombs = 0u;
static int cursor_x = 0;
static int cursor_y = 0;
static int mode = MODE_SELECT;
static int scene_valid = 0;
static int need_redraw = 1;
static int board_full_redraw = 1;
static int chrome_redraw = 1;
static int have_prev_layout = 0;

static const char *difficulty_name(unsigned int index)
{
    return difficulty_names[index];
}

static unsigned int difficulty_width(unsigned int index)
{
    return difficulty_widths[index];
}

static unsigned int difficulty_height(unsigned int index)
{
    return difficulty_heights[index];
}

static unsigned int difficulty_bomb_count(unsigned int index)
{
    return difficulty_bombs[index];
}

static unsigned char difficulty_accent(unsigned int index)
{
    return difficulty_accents[index];
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

static void invalidate_board_cache(void)
{
    unsigned int row;
    unsigned int col;

    for (row = 0u; row < MAX_BOARD_H; row++) {
        for (col = 0u; col < MAX_BOARD_W; col++) {
            shown_visual[row][col] = 0xFFu;
        }
    }
}

static unsigned int board_origin_x(void)
{
    return BOARD_X + ((BOARD_PIX_W - (board_w << CELL_SHIFT)) >> 1);
}

static unsigned int board_origin_y(void)
{
    return BOARD_Y + ((BOARD_PIX_H - (board_h << CELL_SHIFT)) >> 1);
}

static int in_bounds(int x, int y)
{
    return (x >= 0) && (y >= 0) && ((unsigned int)x < board_w) && ((unsigned int)y < board_h);
}

static unsigned int abs_diff(unsigned int a, unsigned int b)
{
    return (a > b) ? (a - b) : (b - a);
}

__attribute__((noinline))
static unsigned int mul_u32_shift_add(unsigned int a, unsigned int b)
{
    unsigned int result = 0u;

    while (b != 0u) {
        if ((b & 1u) != 0u) {
            result += a;
        }
        a <<= 1;
        b >>= 1;
    }
    return result;
}

static void rng_mix(unsigned int mix)
{
    rng_state ^= mix + 0x9E3779B9u + board_nonce;
    rng_state ^= rng_state << 7;
    rng_state ^= rng_state >> 9;
    rng_state ^= rng_state << 8;
    if (rng_state == 0u) {
        rng_state = 0x41C64E6Du;
    }
}

static unsigned int rng_next(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    if (rng_state == 0u) {
        rng_state = 0xA341316Cu;
    }
    return rng_state;
}

static void clear_round_maps(void)
{
    unsigned int row;
    unsigned int col;

    for (row = 0u; row < MAX_BOARD_H; row++) {
        for (col = 0u; col < MAX_BOARD_W; col++) {
            mine_map[row][col] = 0u;
            adj_map[row][col] = 0u;
            revealed_map[row][col] = 0u;
            flagged_map[row][col] = 0u;
        }
    }
}

static int same_as_previous_layout(void)
{
    unsigned int row;
    unsigned int col;

    if (!have_prev_layout ||
        prev_layout_w != board_w ||
        prev_layout_h != board_h ||
        prev_layout_bombs != board_bombs) {
        return 0;
    }

    for (row = 0u; row < board_h; row++) {
        for (col = 0u; col < board_w; col++) {
            if (prev_layout[row][col] != mine_map[row][col]) {
                return 0;
            }
        }
    }
    return 1;
}

static void snapshot_layout(void)
{
    unsigned int row;
    unsigned int col;

    prev_layout_w = board_w;
    prev_layout_h = board_h;
    prev_layout_bombs = board_bombs;
    have_prev_layout = 1;

    for (row = 0u; row < board_h; row++) {
        for (col = 0u; col < board_w; col++) {
            prev_layout[row][col] = mine_map[row][col];
        }
    }
}

static int in_safe_zone(unsigned int x, unsigned int y, unsigned int safe_x, unsigned int safe_y)
{
    return (abs_diff(x, safe_x) <= 1u) && (abs_diff(y, safe_y) <= 1u);
}

static void compute_adjacency(void)
{
    unsigned int row;
    unsigned int col;

    for (row = 0u; row < board_h; row++) {
        for (col = 0u; col < board_w; col++) {
            unsigned int count = 0u;
            int yy;
            int xx;

            if (mine_map[row][col] != 0u) {
                continue;
            }

            for (yy = (int)row - 1; yy <= (int)row + 1; yy++) {
                for (xx = (int)col - 1; xx <= (int)col + 1; xx++) {
                    if ((xx == (int)col && yy == (int)row) || !in_bounds(xx, yy)) {
                        continue;
                    }
                    if (mine_map[yy][xx] != 0u) {
                        count++;
                    }
                }
            }
            adj_map[row][col] = (unsigned char)count;
        }
    }
}

static void generate_board(unsigned int safe_x, unsigned int safe_y)
{
    unsigned int attempts = 0u;

    do {
        unsigned int placed = 0u;
        unsigned int row;
        unsigned int col;

        for (row = 0u; row < board_h; row++) {
            for (col = 0u; col < board_w; col++) {
                mine_map[row][col] = 0u;
                adj_map[row][col] = 0u;
            }
        }

        rng_mix((safe_x << 1) ^ (safe_y << 6) ^ (board_w << 12) ^ (board_h << 20) ^ board_bombs);
        while (placed < board_bombs) {
            unsigned int x = rng_next() & 0x0Fu;
            unsigned int y = rng_next() & 0x0Fu;

            if (x >= board_w || y >= board_h) {
                continue;
            }

            if (mine_map[y][x] != 0u || in_safe_zone(x, y, safe_x, safe_y)) {
                continue;
            }

            mine_map[y][x] = 1u;
            placed++;
        }

        attempts++;
        if (!same_as_previous_layout()) {
            break;
        }
        rng_mix(0xA511E9B3u + attempts);
    } while (attempts < 8u);

    compute_adjacency();
    snapshot_layout();
    board_generated = 1u;
}

static void reveal_flood(unsigned int start_x, unsigned int start_y)
{
    unsigned char queue_x[MAX_BOARD_W * MAX_BOARD_H];
    unsigned char queue_y[MAX_BOARD_W * MAX_BOARD_H];
    unsigned int head = 0u;
    unsigned int tail = 0u;

    revealed_map[start_y][start_x] = 1u;
    revealed_safe_count++;
    queue_x[tail] = (unsigned char)start_x;
    queue_y[tail] = (unsigned char)start_y;
    tail++;

    while (head < tail) {
        unsigned int x = queue_x[head];
        unsigned int y = queue_y[head];
        int yy;
        int xx;

        head++;
        if (adj_map[y][x] != 0u) {
            continue;
        }

        for (yy = (int)y - 1; yy <= (int)y + 1; yy++) {
            for (xx = (int)x - 1; xx <= (int)x + 1; xx++) {
                if (!in_bounds(xx, yy) || mine_map[yy][xx] != 0u || flagged_map[yy][xx] != 0u || revealed_map[yy][xx] != 0u) {
                    continue;
                }

                revealed_map[yy][xx] = 1u;
                revealed_safe_count++;
                if (adj_map[yy][xx] == 0u && tail < (MAX_BOARD_W * MAX_BOARD_H)) {
                    queue_x[tail] = (unsigned char)xx;
                    queue_y[tail] = (unsigned char)yy;
                    tail++;
                }
            }
        }
    }
}

static void mark_mode(int next_mode)
{
    mode = next_mode;
    scene_valid = 0;
    chrome_redraw = 1;
    board_full_redraw = 1;
    need_redraw = 1;
}

static void start_round(unsigned int diff_index)
{
    difficulty_index = diff_index;
    selected_difficulty = diff_index;
    board_w = difficulty_width(diff_index);
    board_h = difficulty_height(diff_index);
    board_bombs = difficulty_bomb_count(diff_index);
    board_cells_total = mul_u32_shift_add(board_w, board_h);
    revealed_safe_count = 0u;
    flag_count = 0u;
    board_generated = 0u;
    cursor_x = (int)(board_w >> 1);
    cursor_y = (int)(board_h >> 1);
    board_nonce++;
    rng_mix(board_nonce + board_bombs + (board_w << 8) + (board_h << 16));
    clear_round_maps();
    invalidate_board_cache();
    scene_valid = 0;
    board_full_redraw = 1;
    chrome_redraw = 1;
    need_redraw = 1;
    mode = MODE_PLAY;
}

static void show_select_screen(void)
{
    selected_difficulty = difficulty_index;
    mark_mode(MODE_SELECT);
}

static void open_cell(unsigned int x, unsigned int y)
{
    if (flagged_map[y][x] != 0u || revealed_map[y][x] != 0u) {
        return;
    }

    if (board_generated == 0u) {
        generate_board(x, y);
    }

    if (mine_map[y][x] != 0u) {
        revealed_map[y][x] = 1u;
        mark_mode(MODE_LOSE);
        return;
    }

    reveal_flood(x, y);
    if (revealed_safe_count + board_bombs == board_cells_total) {
        mark_mode(MODE_WIN);
        return;
    }

    need_redraw = 1;
}

static void toggle_flag(unsigned int x, unsigned int y)
{
    if (revealed_map[y][x] != 0u) {
        return;
    }

    if (flagged_map[y][x] != 0u) {
        flagged_map[y][x] = 0u;
        if (flag_count != 0u) {
            flag_count--;
        }
    } else {
        flagged_map[y][x] = 1u;
        flag_count++;
    }
    chrome_redraw = 1;
    need_redraw = 1;
}

static unsigned char number_color(unsigned int value)
{
    static const unsigned char colors[8] = {6u, 2u, 4u, 1u, 5u, 3u, 7u, 14u};
    if (value == 0u || value > 8u) {
        return COLOR_TEXT;
    }
    return colors[value - 1u];
}

static void draw_cell_cursor(unsigned int px, unsigned int py)
{
    fill_rect(px, py, CELL_PIXELS, 1u, COLOR_CURSOR);
    fill_rect(px, py + CELL_PIXELS - 1u, CELL_PIXELS, 1u, COLOR_CURSOR);
    fill_rect(px, py, 1u, CELL_PIXELS, COLOR_CURSOR);
    fill_rect(px + CELL_PIXELS - 1u, py, 1u, CELL_PIXELS, COLOR_CURSOR);
}

static void draw_flag_icon(unsigned int px, unsigned int py)
{
    fill_rect(px + 2u, py + 2u, 1u, 4u, COLOR_TEXT);
    fill_rect(px + 3u, py + 2u, 3u, 2u, COLOR_FLAG);
    vga_fb_put_pixel(px + 5u, py + 4u, COLOR_FLAG);
}

static void draw_mine_icon(unsigned int px, unsigned int py, unsigned char color)
{
    fill_rect(px + 2u, py + 3u, 4u, 1u, color);
    fill_rect(px + 3u, py + 2u, 1u, 3u, color);
    fill_rect(px + 4u, py + 2u, 1u, 3u, color);
    vga_fb_put_pixel(px + 2u, py + 2u, color);
    vga_fb_put_pixel(px + 5u, py + 2u, color);
    vga_fb_put_pixel(px + 2u, py + 4u, color);
    vga_fb_put_pixel(px + 5u, py + 4u, color);
}

static void draw_wrong_flag(unsigned int px, unsigned int py)
{
    draw_flag_icon(px, py);
    vga_fb_put_pixel(px + 1u, py + 1u, COLOR_MINE);
    vga_fb_put_pixel(px + 2u, py + 2u, COLOR_MINE);
    vga_fb_put_pixel(px + 5u, py + 5u, COLOR_MINE);
    vga_fb_put_pixel(px + 6u, py + 6u, COLOR_MINE);
    vga_fb_put_pixel(px + 6u, py + 1u, COLOR_MINE);
    vga_fb_put_pixel(px + 5u, py + 2u, COLOR_MINE);
    vga_fb_put_pixel(px + 2u, py + 5u, COLOR_MINE);
    vga_fb_put_pixel(px + 1u, py + 6u, COLOR_MINE);
}

static unsigned char cell_visual(unsigned int x, unsigned int y)
{
    unsigned char code;

    if (mode == MODE_LOSE && flagged_map[y][x] != 0u && mine_map[y][x] == 0u) {
        code = 3u;
    } else if (flagged_map[y][x] != 0u && revealed_map[y][x] == 0u) {
        code = 1u;
    } else if (revealed_map[y][x] == 0u) {
        if (mode == MODE_LOSE && mine_map[y][x] != 0u) {
            code = 4u;
        } else {
            code = 0u;
        }
    } else if (mine_map[y][x] != 0u) {
        code = 5u;
    } else if (adj_map[y][x] == 0u) {
        code = 2u;
    } else {
        code = (unsigned char)(5u + adj_map[y][x]);
    }

    if (mode == MODE_PLAY && x == (unsigned int)cursor_x && y == (unsigned int)cursor_y) {
        code = (unsigned char)(code | 0x80u);
    }
    return code;
}

static void draw_board_cell(unsigned int x, unsigned int y, unsigned char visual)
{
    unsigned int px = board_origin_x() + (x << CELL_SHIFT);
    unsigned int py = board_origin_y() + (y << CELL_SHIFT);
    unsigned char code = (unsigned char)(visual & 0x7Fu);
    int has_cursor = (visual & 0x80u) != 0u;

    if (code == 0u || code == 1u) {
        fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, COLOR_CELL_HIDDEN);
        fill_rect(px + 1u, py + 1u, CELL_PIXELS - 2u, 1u, COLOR_CELL_TOP);
        fill_rect(px + 1u, py + CELL_PIXELS - 2u, CELL_PIXELS - 2u, 1u, COLOR_CELL_BOTTOM);
        if (code == 1u) {
            draw_flag_icon(px, py);
        }
    } else if (code == 2u || (code >= 6u && code <= 13u) || code == 4u || code == 5u || code == 3u) {
        unsigned char fill = (code == 5u) ? COLOR_MINE_BLAST : COLOR_CELL_OPEN;

        fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, fill);
        fill_rect(px, py + CELL_PIXELS - 1u, CELL_PIXELS, 1u, COLOR_CELL_OPEN_SHADOW);

        if (code >= 6u && code <= 13u) {
            char digit[2];
            digit[0] = (char)('0' + (code - 5u));
            digit[1] = '\0';
            draw_text(px + 2u, py + 1u, digit, 1u, number_color((unsigned int)(code - 5u)));
        } else if (code == 4u || code == 5u) {
            draw_mine_icon(px, py, (code == 5u) ? COLOR_TEXT : COLOR_MINE);
        } else if (code == 3u) {
            draw_wrong_flag(px, py);
        }
    }

    if (has_cursor) {
        draw_cell_cursor(px, py);
    }
}

static void draw_static_scene(void)
{
    vga_fb_clear(COLOR_BG);
    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(BOARD_FRAME_X, BOARD_FRAME_Y, BOARD_FRAME_W, BOARD_FRAME_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FOOTER_X, FOOTER_Y, FOOTER_W, FOOTER_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(BOARD_X, BOARD_Y, BOARD_PIX_W, BOARD_PIX_H, COLOR_BOARD_BG);
    scene_valid = 1;
}

static void render_chrome(int force_full)
{
    unsigned int footer_y = FOOTER_Y + 3u;
    unsigned int diff_index = (mode == MODE_SELECT) ? selected_difficulty : difficulty_index;

    if (!force_full && !chrome_redraw) {
        return;
    }

    fill_rect(TITLE_X + 1u, TITLE_Y + 1u, TITLE_W - 2u, TITLE_H - 2u, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, difficulty_accent(diff_index));
    draw_text_centered(TITLE_X, TITLE_Y + 3u, TITLE_W, "MINES", 2u, COLOR_TEXT);

    fill_rect(FOOTER_X + 1u, FOOTER_Y + 1u, FOOTER_W - 2u, FOOTER_H - 2u, COLOR_PANEL);
    draw_text(FOOTER_X + 4u, footer_y, difficulty_name(diff_index), 1u, difficulty_accent(diff_index));

    if (mode == MODE_PLAY || mode == MODE_WIN || mode == MODE_LOSE) {
        draw_text(FOOTER_X + 30u, footer_y, "BM", 1u, COLOR_LABEL);
        draw_uint(FOOTER_X + 40u, footer_y, 1u, board_bombs, COLOR_TEXT);
        draw_text(FOOTER_X + 58u, footer_y, "FG", 1u, COLOR_LABEL);
        draw_uint(FOOTER_X + 68u, footer_y, 1u, flag_count, COLOR_TEXT);
        draw_text(FOOTER_X + 86u, footer_y, "SAFE", 1u, COLOR_LABEL);
        draw_uint(FOOTER_X + 108u, footer_y, 1u, revealed_safe_count, COLOR_TEXT);

        if (mode == MODE_PLAY) {
            draw_text_centered(FOOTER_X, FOOTER_Y + 7u, FOOTER_W, "WASD MOVE SPC OPEN F FLAG M MENU", 1u, COLOR_TEXT);
        } else if (mode == MODE_WIN) {
            draw_text_centered(FOOTER_X, FOOTER_Y + 7u, FOOTER_W, "R RETRY  1 2 3 NEW  M MENU", 1u, COLOR_TEXT);
        } else {
            draw_text_centered(FOOTER_X, FOOTER_Y + 7u, FOOTER_W, "R RETRY  1 2 3 NEW  M MENU", 1u, COLOR_TEXT);
        }
    } else {
        draw_text_centered(FOOTER_X, FOOTER_Y + 3u, FOOTER_W, "W/S MOVE  SPC START  N17 MENU", 1u, COLOR_TEXT);
        draw_text_centered(FOOTER_X, FOOTER_Y + 7u, FOOTER_W, "1 EASY  2 NORMAL  3 HARD", 1u, COLOR_LABEL);
    }

    chrome_redraw = 0;
}

static void render_board(int force_full)
{
    unsigned int row;
    unsigned int col;

    if (force_full || board_full_redraw) {
        fill_rect(BOARD_X, BOARD_Y, BOARD_PIX_W, BOARD_PIX_H, COLOR_BOARD_BG);
        draw_frame(board_origin_x() - 2u, board_origin_y() - 2u,
                   (board_w << CELL_SHIFT) + 4u, (board_h << CELL_SHIFT) + 4u,
                   difficulty_accent(difficulty_index), COLOR_BOARD_BG);
        invalidate_board_cache();
        board_full_redraw = 0;
    }

    for (row = 0u; row < board_h; row++) {
        for (col = 0u; col < board_w; col++) {
            unsigned char visual = cell_visual(col, row);
            if (shown_visual[row][col] != visual) {
                draw_board_cell(col, row, visual);
                shown_visual[row][col] = visual;
            }
        }
    }
}

static void draw_select_option(unsigned int y, unsigned int index)
{
    int selected = index == selected_difficulty;
    unsigned char frame = selected ? difficulty_accent(index) : COLOR_FRAME;
    unsigned char fill = selected ? COLOR_PANEL : COLOR_CARD;
    unsigned char text = selected ? COLOR_TEXT : COLOR_LABEL;

    draw_frame(OVERLAY_X + 8u, y, OVERLAY_W - 16u, 12u, frame, fill);
    draw_text(OVERLAY_X + 14u, y + 3u, (index == 0u) ? "1" : (index == 1u) ? "2" : "3", 1u, difficulty_accent(index));
    draw_text(OVERLAY_X + 26u, y + 3u, difficulty_name(index), 1u, text);
    draw_uint(OVERLAY_X + 68u, y + 3u, 1u, difficulty_bomb_count(index), COLOR_TEXT);
    draw_text(OVERLAY_X + 80u, y + 3u, "BOMBS", 1u, COLOR_LABEL);
}

static void render_overlay(void)
{
    fill_rect(BOARD_X, BOARD_Y, BOARD_PIX_W, BOARD_PIX_H, COLOR_BOARD_BG);
    draw_frame(OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H, COLOR_FRAME, COLOR_OVERLAY);

    if (mode == MODE_SELECT) {
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 6u, OVERLAY_W, "SELECT LEVEL", 1u, COLOR_TEXT);
        draw_select_option(OVERLAY_Y + 18u, 0u);
        draw_select_option(OVERLAY_Y + 31u, 1u);
        draw_select_option(OVERLAY_Y + 44u, 2u);
    } else if (mode == MODE_WIN) {
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 10u, OVERLAY_W, "YOU WIN", 1u, COLOR_TEXT);
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 22u, OVERLAY_W, "NO MINES LEFT", 1u, COLOR_LABEL);
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 36u, OVERLAY_W, "R RETRY  M MENU", 1u, COLOR_TEXT);
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 46u, OVERLAY_W, "1 2 3 NEW ROUND", 1u, COLOR_LABEL);
    } else {
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 10u, OVERLAY_W, "BOOM", 2u, COLOR_TEXT);
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 26u, OVERLAY_W, "TRY AGAIN", 1u, COLOR_LABEL);
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 38u, OVERLAY_W, "R RETRY  M MENU", 1u, COLOR_TEXT);
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 48u, OVERLAY_W, "1 2 3 NEW ROUND", 1u, COLOR_LABEL);
    }
}

static void render_scene(void)
{
    int force_full = 0;

    if (!scene_valid) {
        draw_static_scene();
        force_full = 1;
    }

    render_chrome(force_full);
    if (mode == MODE_PLAY) {
        render_board(force_full);
    } else {
        render_overlay();
    }
    need_redraw = 0;
}

static int move_cursor(int dx, int dy)
{
    int next_x = cursor_x + dx;
    int next_y = cursor_y + dy;

    if (mode != MODE_PLAY) {
        return 0;
    }
    if (!in_bounds(next_x, next_y)) {
        return 0;
    }

    cursor_x = next_x;
    cursor_y = next_y;
    need_redraw = 1;
    return 1;
}

static int handle_select_input(int ch)
{
    if (ch == 'q') {
        return -1;
    }
    if (ch == 'w') {
        if (selected_difficulty > 0u) {
            selected_difficulty--;
            scene_valid = 0;
            chrome_redraw = 1;
            need_redraw = 1;
        }
        return 0;
    }
    if (ch == 's') {
        if (selected_difficulty < 2u) {
            selected_difficulty++;
            scene_valid = 0;
            chrome_redraw = 1;
            need_redraw = 1;
        }
        return 0;
    }
    if (ch == '1') {
        start_round(0u);
        return 0;
    }
    if (ch == '2') {
        start_round(1u);
        return 0;
    }
    if (ch == '3') {
        start_round(2u);
        return 0;
    }
    if ((ch == ' ') || (ch == '\r') || (ch == '\n')) {
        start_round(selected_difficulty);
        return 0;
    }
    return 0;
}

static int handle_play_input(int ch)
{
    if (ch == 'q') {
        return -1;
    }
    if (ch == 'm') {
        show_select_screen();
        return 0;
    }
    if (ch == 'r') {
        start_round(difficulty_index);
        return 0;
    }
    if (ch == '1') {
        start_round(0u);
        return 0;
    }
    if (ch == '2') {
        start_round(1u);
        return 0;
    }
    if (ch == '3') {
        start_round(2u);
        return 0;
    }
    if (ch == 'w') {
        (void)move_cursor(0, -1);
        return 0;
    }
    if (ch == 's') {
        (void)move_cursor(0, 1);
        return 0;
    }
    if (ch == 'a') {
        (void)move_cursor(-1, 0);
        return 0;
    }
    if (ch == 'd') {
        (void)move_cursor(1, 0);
        return 0;
    }
    if (ch == 'f') {
        toggle_flag((unsigned int)cursor_x, (unsigned int)cursor_y);
        return 0;
    }
    if (ch == ' ') {
        open_cell((unsigned int)cursor_x, (unsigned int)cursor_y);
        return 0;
    }
    return 0;
}

static int handle_result_input(int ch)
{
    if (ch == 'q') {
        return -1;
    }
    if (ch == 'm') {
        show_select_screen();
        return 0;
    }
    if (ch == 'r') {
        start_round(difficulty_index);
        return 0;
    }
    if (ch == '1') {
        start_round(0u);
        return 0;
    }
    if (ch == '2') {
        start_round(1u);
        return 0;
    }
    if (ch == '3') {
        start_round(2u);
        return 0;
    }
    return 0;
}

static int handle_input(int ch)
{
    ch = ui_to_lower(ch);

    if (mode == MODE_SELECT) {
        return handle_select_input(ch);
    }
    if (mode == MODE_PLAY) {
        return handle_play_input(ch);
    }
    return handle_result_input(ch);
}

int main(void)
{
    ui_clear_screen();
    ui_puts("VGA Mines demo (160x120 framebuffer)\n");
    ui_puts("Use UART: w/a/s/d move, space open, f flag, 1/2/3 difficulty, r reset, m select menu, BTNC launcher menu.\n");
    ui_drain_input();

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();
    clear_round_maps();
    invalidate_board_cache();
    show_select_screen();

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

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_present();
    return 0;
}
