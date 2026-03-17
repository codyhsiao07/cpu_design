#include "games_shared_ui.h"
#include "vga_fb.h"
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
#include "launcher_jump.h"
#endif

#define BOARD_W 10
#define BOARD_H 20
#define DROP_POLLS_START 180u
#define DROP_POLLS_MIN 45u
#define DROP_POLLS_STEP 12u
#define LEVEL_LINES 5u
#define POLL_SPIN 3000u

#define CELL_SHIFT 2
#define CELL_PIXELS 4u

#define SCREEN_W 160u
#define SCREEN_H 120u

#define TITLE_X 4u
#define TITLE_Y 4u
#define TITLE_W 152u
#define TITLE_H 12u

#define BOARD_FRAME_X 6u
#define BOARD_FRAME_Y 18u
#define BOARD_FRAME_W 44u
#define BOARD_FRAME_H 84u
#define BOARD_X 8u
#define BOARD_Y 20u
#define BOARD_PIX_W 40u
#define BOARD_PIX_H 80u

#define PANEL_X 56u
#define PANEL_Y 18u
#define PANEL_W 98u
#define PANEL_H 84u
#define SCORE_LABEL_Y 24u
#define SCORE_VALUE_X 82u
#define SCORE_VALUE_Y 32u
#define SCORE_DIGITS 6u
#define PREVIEW_LABEL_X 64u
#define PREVIEW_LABEL_Y 48u
#define PREVIEW_X 64u
#define PREVIEW_Y 56u
#define PREVIEW_CELL 4u
#define PREVIEW_BOX_W 16u
#define PREVIEW_BOX_H 16u
#define LEVEL_LABEL_X 92u
#define LEVEL_LABEL_Y 56u
#define LEVEL_VALUE_X 116u
#define LEVEL_VALUE_Y 56u
#define LINES_LABEL_X 92u
#define LINES_LABEL_Y 66u
#define LINES_VALUE_X 116u
#define LINES_VALUE_Y 66u
#define PIECES_LABEL_X 92u
#define PIECES_LABEL_Y 76u
#define PIECES_VALUE_X 116u
#define PIECES_VALUE_Y 76u
#define GOAL_LABEL_X 64u
#define GOAL_LABEL_Y 86u
#define GOAL_BAR_X 64u
#define GOAL_BAR_Y 94u
#define GOAL_BAR_W 80u
#define GOAL_BAR_H 4u
#define STATUS_X 56u
#define STATUS_Y 104u
#define STATUS_W 98u
#define STATUS_H 10u

#define GAME_OVER_X 9u
#define GAME_OVER_Y 55u
#define GAME_OVER_W 40u
#define GAME_OVER_H 10u
#define QUIT_ARM_POLLS 240u

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 6u
#define COLOR_ACCENT 15u
#define COLOR_LABEL 4u
#define COLOR_TEXT 7u
#define COLOR_SUBTEXT 14u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_WELL 0u
#define COLOR_GRID 10u
#define COLOR_OVERLAY 12u
#define COLOR_SHADOW 8u
#define COLOR_GOAL_BG 8u
#define COLOR_GOAL_FILL 2u

#include "games_shared_ui.h"
#include "vga_fb.h"

static unsigned char board[BOARD_H][BOARD_W];
static unsigned char shown_cells[BOARD_H][BOARD_W];

static int current_type;
static int current_rot;
static int current_x;
static int current_y;
static int next_type;
static int shown_next_type = -1;
static unsigned int rng_state = 0x12345678u;
static unsigned int score;
static unsigned int shown_score = 0xFFFFFFFFu;
static unsigned int lines_cleared_total;
static unsigned int shown_lines = 0xFFFFFFFFu;
static unsigned int piece_count;
static unsigned int shown_pieces = 0xFFFFFFFFu;
static unsigned int level_value;
static unsigned int shown_level = 0xFFFFFFFFu;
static unsigned int lines_until_level;
static unsigned int shown_lines_until = 0xFFFFFFFFu;
static unsigned int drop_polls_current;
static unsigned int quit_arm_polls;
static int game_over;
static int shown_game_over = -1;
static int shown_quit_arm = -1;
static int need_redraw;
static int scene_valid;

static const unsigned char piece_rows[7][4][4] = {
    {
        {0x0, 0xF, 0x0, 0x0},
        {0x2, 0x2, 0x2, 0x2},
        {0x0, 0x0, 0xF, 0x0},
        {0x4, 0x4, 0x4, 0x4}
    },
    {
        {0x6, 0x6, 0x0, 0x0},
        {0x6, 0x6, 0x0, 0x0},
        {0x6, 0x6, 0x0, 0x0},
        {0x6, 0x6, 0x0, 0x0}
    },
    {
        {0x2, 0x7, 0x0, 0x0},
        {0x2, 0x6, 0x2, 0x0},
        {0x0, 0x7, 0x2, 0x0},
        {0x2, 0x3, 0x2, 0x0}
    },
    {
        {0x3, 0x6, 0x0, 0x0},
        {0x2, 0x3, 0x1, 0x0},
        {0x3, 0x6, 0x0, 0x0},
        {0x2, 0x3, 0x1, 0x0}
    },
    {
        {0x6, 0x3, 0x0, 0x0},
        {0x1, 0x3, 0x2, 0x0},
        {0x6, 0x3, 0x0, 0x0},
        {0x1, 0x3, 0x2, 0x0}
    },
    {
        {0x4, 0x7, 0x0, 0x0},
        {0x3, 0x2, 0x2, 0x0},
        {0x0, 0x7, 0x1, 0x0},
        {0x2, 0x2, 0x6, 0x0}
    },
    {
        {0x1, 0x7, 0x0, 0x0},
        {0x2, 0x2, 0x3, 0x0},
        {0x0, 0x7, 0x4, 0x0},
        {0x6, 0x2, 0x2, 0x0}
    }
};

static const unsigned char piece_colors[7] = {
    6u, 4u, 3u, 2u, 1u, 13u, 15u
};

static const unsigned int pow10_table[10] = {
    1u, 10u, 100u, 1000u, 10000u,
    100000u, 1000000u, 10000000u, 100000000u, 1000000000u
};

static void fill_rect(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned char color)
{
    unsigned int yy;
    unsigned int xx;

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

static void draw_frame(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned char frame_color, unsigned char fill_color)
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
    static const unsigned char glyph_c[5] = {0x7, 0x4, 0x4, 0x4, 0x7};
    static const unsigned char glyph_e[5] = {0x7, 0x4, 0x6, 0x4, 0x7};
    static const unsigned char glyph_g[5] = {0x7, 0x4, 0x5, 0x5, 0x7};
    static const unsigned char glyph_i[5] = {0x7, 0x2, 0x2, 0x2, 0x7};
    static const unsigned char glyph_l[5] = {0x4, 0x4, 0x4, 0x4, 0x7};
    static const unsigned char glyph_m[5] = {0x5, 0x7, 0x7, 0x5, 0x5};
    static const unsigned char glyph_n[5] = {0x5, 0x7, 0x7, 0x7, 0x5};
    static const unsigned char glyph_o[5] = {0x7, 0x5, 0x5, 0x5, 0x7};
    static const unsigned char glyph_p[5] = {0x6, 0x5, 0x6, 0x4, 0x4};
    static const unsigned char glyph_r[5] = {0x6, 0x5, 0x6, 0x5, 0x5};
    static const unsigned char glyph_s[5] = {0x7, 0x4, 0x7, 0x1, 0x7};
    static const unsigned char glyph_t[5] = {0x7, 0x2, 0x2, 0x2, 0x2};
    static const unsigned char glyph_v[5] = {0x5, 0x5, 0x5, 0x5, 0x2};
    static const unsigned char glyph_x[5] = {0x5, 0x5, 0x2, 0x5, 0x5};

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
    case 'C': return glyph_c;
    case 'E': return glyph_e;
    case 'G': return glyph_g;
    case 'I': return glyph_i;
    case 'L': return glyph_l;
    case 'M': return glyph_m;
    case 'N': return glyph_n;
    case 'O': return glyph_o;
    case 'P': return glyph_p;
    case 'R': return glyph_r;
    case 'S': return glyph_s;
    case 'T': return glyph_t;
    case 'V': return glyph_v;
    case 'X': return glyph_x;
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

static void draw_text_centered(unsigned int x, unsigned int y, unsigned int w, const char *text, unsigned int scale, unsigned char color)
{
    unsigned int width = text_width(text, scale);
    unsigned int start_x = x;

    if (w > width) {
        start_x = x + ((w - width) >> 1);
    }
    draw_text(start_x, y, text, scale, color);
}

static void draw_uint_fixed(unsigned int x, unsigned int y, unsigned int digits, unsigned int scale, unsigned int value, unsigned char color)
{
    char buf[10];
    unsigned int i;
    unsigned int place;
    unsigned int digit;

    if (digits > 9u) {
        digits = 9u;
    }
    if (digits != 0u) {
        unsigned int max_value = pow10_table[digits] - 1u;
        if (value > max_value) {
            value = max_value;
        }
    }

    for (i = 0u; i < digits; i++) {
        place = pow10_table[digits - 1u - i];
        digit = 0u;
        while (value >= place && digit < 9u) {
            value -= place;
            digit++;
        }
        buf[i] = (char)('0' + digit);
    }
    buf[digits] = '\0';
    draw_text(x, y, buf, scale, color);
}

static unsigned int next_random(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

static int next_piece_type(void)
{
    unsigned int v = next_random() & 7u;
    if (v == 7u) {
        v = 6u;
    }
    return (int)v;
}

static int piece_has_cell(int type, int rot, int row, int col)
{
    unsigned char row_bits = piece_rows[type][rot & 3][row & 3];
    return (row_bits & (1u << (3 - (col & 3)))) != 0u;
}

static int collides(int type, int rot, int x, int y)
{
    int r;
    int c;

    for (r = 0; r < 4; r++) {
        for (c = 0; c < 4; c++) {
            int bx;
            int by;

            if (!piece_has_cell(type, rot, r, c)) {
                continue;
            }

            bx = x + c;
            by = y + r;
            if (bx < 0 || bx >= BOARD_W || by < 0 || by >= BOARD_H) {
                return 1;
            }
            if (board[by][bx] != 0u) {
                return 1;
            }
        }
    }

    return 0;
}

static void invalidate_render_cache(void)
{
    int r;
    int c;

    for (r = 0; r < BOARD_H; r++) {
        for (c = 0; c < BOARD_W; c++) {
            shown_cells[r][c] = 0xFFu;
        }
    }

    shown_next_type = -1;
    shown_score = 0xFFFFFFFFu;
    shown_lines = 0xFFFFFFFFu;
    shown_pieces = 0xFFFFFFFFu;
    shown_level = 0xFFFFFFFFu;
    shown_lines_until = 0xFFFFFFFFu;
    shown_game_over = -1;
    shown_quit_arm = -1;
}

static void clear_board(void)
{
    int r;
    int c;

    for (r = 0; r < BOARD_H; r++) {
        for (c = 0; c < BOARD_W; c++) {
            board[r][c] = 0u;
        }
    }
}

static void lock_piece(void)
{
    int r;
    int c;
    unsigned char cell_value = (unsigned char)(current_type + 1);

    for (r = 0; r < 4; r++) {
        for (c = 0; c < 4; c++) {
            int bx;
            int by;

            if (!piece_has_cell(current_type, current_rot, r, c)) {
                continue;
            }
            bx = current_x + c;
            by = current_y + r;
            if (bx >= 0 && bx < BOARD_W && by >= 0 && by < BOARD_H) {
                board[by][bx] = cell_value;
            }
        }
    }
}

static void clear_completed_lines(void)
{
    int r;
    unsigned int cleared = 0u;
    unsigned int cleared_total;

    for (r = BOARD_H - 1; r >= 0; r--) {
        int c;
        int full = 1;

        for (c = 0; c < BOARD_W; c++) {
            if (board[r][c] == 0u) {
                full = 0;
                break;
            }
        }

        if (full) {
            int rr;
            cleared++;
            for (rr = r; rr > 0; rr--) {
                for (c = 0; c < BOARD_W; c++) {
                    board[rr][c] = board[rr - 1][c];
                }
            }
            for (c = 0; c < BOARD_W; c++) {
                board[0][c] = 0u;
            }
            r++;
        }
    }

    if (cleared != 0u) {
        cleared_total = cleared;
        lines_cleared_total += cleared_total;

        if (cleared_total == 1u) {
            score += 100u;
        } else if (cleared_total == 2u) {
            score += 400u;
        } else if (cleared_total == 3u) {
            score += 900u;
        } else {
            score += 1600u;
        }

        while (cleared_total != 0u) {
            if (lines_until_level > 0u) {
                lines_until_level--;
            }
            if (lines_until_level == 0u) {
                level_value++;
                lines_until_level = LEVEL_LINES;
                if (drop_polls_current > (DROP_POLLS_MIN + DROP_POLLS_STEP)) {
                    drop_polls_current -= DROP_POLLS_STEP;
                } else {
                    drop_polls_current = DROP_POLLS_MIN;
                }
            }
            cleared_total--;
        }
    }
}

static void spawn_piece(void)
{
    current_type = next_type;
    current_rot = 0;
    current_x = 3;
    current_y = 0;
    next_type = next_piece_type();
    piece_count++;
    if (collides(current_type, current_rot, current_x, current_y)) {
        game_over = 1;
        ui_puts("\nGame over. Press r to restart or q to quit.\n");
    }
    need_redraw = 1;
}

static void start_new_game(void)
{
    clear_board();
    score = 0u;
    lines_cleared_total = 0u;
    piece_count = 0u;
    level_value = 1u;
    lines_until_level = LEVEL_LINES;
    drop_polls_current = DROP_POLLS_START;
    quit_arm_polls = 0u;
    game_over = 0;
    rng_state ^= 0x9E3779B9u;
    next_type = next_piece_type();
    spawn_piece();
    invalidate_render_cache();
    scene_valid = 0;
    need_redraw = 1;
    ui_puts("\nRestarted VGA Tetris.\n");
}

static int move_piece(int dx, int dy)
{
    if (!collides(current_type, current_rot, current_x + dx, current_y + dy)) {
        current_x += dx;
        current_y += dy;
        need_redraw = 1;
        return 1;
    }
    return 0;
}

static void rotate_piece(void)
{
    static const int kick_table[5] = {0, -1, 1, -2, 2};
    int next_rot = (current_rot + 1) & 3;
    int i;

    for (i = 0; i < 5; i++) {
        int nx = current_x + kick_table[i];
        if (!collides(current_type, next_rot, nx, current_y)) {
            current_rot = next_rot;
            current_x = nx;
            need_redraw = 1;
            return;
        }
    }
}

static void hard_drop(void)
{
    while (move_piece(0, 1)) {
    }
}

static void advance_game(void)
{
    if (!move_piece(0, 1)) {
        lock_piece();
        clear_completed_lines();
        spawn_piece();
    }
}

static unsigned char overlay_piece_cell(int row, int col)
{
    int r;
    int c;

    if (game_over) {
        return 0u;
    }

    for (r = 0; r < 4; r++) {
        for (c = 0; c < 4; c++) {
            if (!piece_has_cell(current_type, current_rot, r, c)) {
                continue;
            }
            if ((current_x + c) == col && (current_y + r) == row) {
                return (unsigned char)(current_type + 1);
            }
        }
    }

    return 0u;
}

static unsigned char visible_cell_value(int row, int col)
{
    unsigned char active = overlay_piece_cell(row, col);
    if (active != 0u) {
        return active;
    }
    return board[row][col];
}

static void draw_board_cell(unsigned int bx, unsigned int by, unsigned char cell)
{
    unsigned int px = BOARD_X + (bx << CELL_SHIFT);
    unsigned int py = BOARD_Y + (by << CELL_SHIFT);
    unsigned char fill = COLOR_WELL;

    if (cell == 0u) {
        fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, fill);
        return;
    }

    fill = piece_colors[cell - 1u];
    fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, fill);
    if (CELL_PIXELS > 3u) {
        fill_rect(px + 1u, py + 1u, CELL_PIXELS - 2u, 1u, COLOR_TEXT);
        vga_fb_put_pixel(px + 1u, py + CELL_PIXELS - 2u, COLOR_SHADOW);
        vga_fb_put_pixel(px + 2u, py + CELL_PIXELS - 2u, COLOR_SHADOW);
    }
}

static void draw_static_scene(void)
{
    vga_fb_clear(COLOR_BG);

    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    fill_rect(TITLE_X + 2u, TITLE_Y + TITLE_H - 4u, TITLE_W - 4u, 1u, COLOR_SUBTEXT);
    draw_text_centered(TITLE_X, TITLE_Y + 4u, TITLE_W, "TETRIS", 2u, COLOR_TEXT);

    draw_frame(BOARD_FRAME_X, BOARD_FRAME_Y, BOARD_FRAME_W, BOARD_FRAME_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(BOARD_X, BOARD_Y, BOARD_PIX_W, BOARD_PIX_H, COLOR_WELL);
    fill_rect(BOARD_X, BOARD_Y - 2u, BOARD_PIX_W, 1u, COLOR_ACCENT);

    draw_frame(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(PANEL_X + 2u, PANEL_Y + 2u, PANEL_W - 4u, 2u, COLOR_ACCENT);
    fill_rect(PANEL_X + 4u, 46u, PANEL_W - 8u, 1u, COLOR_SUBTEXT);
    draw_text_centered(PANEL_X, SCORE_LABEL_Y, PANEL_W, "SCORE", 1u, COLOR_LABEL);
    draw_frame(SCORE_VALUE_X - 4u, SCORE_VALUE_Y - 2u, 52u, 12u, COLOR_ACCENT, COLOR_CARD);
    draw_text(PREVIEW_LABEL_X, PREVIEW_LABEL_Y, "NEXT", 1u, COLOR_LABEL);
    draw_frame(PREVIEW_X - 2u, PREVIEW_Y - 2u, PREVIEW_BOX_W + 4u, PREVIEW_BOX_H + 4u, COLOR_ACCENT, COLOR_CARD);
    draw_text(LEVEL_LABEL_X, LEVEL_LABEL_Y, "LV", 1u, COLOR_LABEL);
    draw_frame(LEVEL_VALUE_X - 2u, LEVEL_VALUE_Y - 1u, 12u, 7u, COLOR_SUBTEXT, COLOR_CARD);
    draw_text(LINES_LABEL_X, LINES_LABEL_Y, "LN", 1u, COLOR_LABEL);
    draw_frame(LINES_VALUE_X - 2u, LINES_VALUE_Y - 1u, 16u, 7u, COLOR_SUBTEXT, COLOR_CARD);
    draw_text(PIECES_LABEL_X, PIECES_LABEL_Y, "PC", 1u, COLOR_LABEL);
    draw_frame(PIECES_VALUE_X - 2u, PIECES_VALUE_Y - 1u, 16u, 7u, COLOR_SUBTEXT, COLOR_CARD);
    draw_text(GOAL_LABEL_X, GOAL_LABEL_Y, "GOAL", 1u, COLOR_LABEL);
    draw_frame(GOAL_BAR_X - 2u, GOAL_BAR_Y - 2u, GOAL_BAR_W + 4u, GOAL_BAR_H + 4u, COLOR_SUBTEXT, COLOR_CARD);
    fill_rect(GOAL_BAR_X, GOAL_BAR_Y, GOAL_BAR_W, GOAL_BAR_H, COLOR_GOAL_BG);
    draw_frame(STATUS_X, STATUS_Y, STATUS_W, STATUS_H, COLOR_SUBTEXT, COLOR_CARD);

    scene_valid = 1;
}

static void render_board_cells(int force_full)
{
    int r;
    int c;

    for (r = 0; r < BOARD_H; r++) {
        for (c = 0; c < BOARD_W; c++) {
            unsigned char cell = visible_cell_value(r, c);
            if (force_full || shown_cells[r][c] != cell) {
                draw_board_cell((unsigned int)c, (unsigned int)r, cell);
                shown_cells[r][c] = cell;
            }
        }
    }
}

static void render_preview(int force_full)
{
    unsigned int r;
    unsigned int c;

    if (!force_full && shown_next_type == next_type) {
        return;
    }

    fill_rect(PREVIEW_X, PREVIEW_Y, PREVIEW_BOX_W, PREVIEW_BOX_H, COLOR_CARD);
    for (r = 0u; r < 4u; r++) {
        for (c = 0u; c < 4u; c++) {
            if (piece_has_cell(next_type, 0, (int)r, (int)c)) {
                fill_rect(PREVIEW_X + (c << 2), PREVIEW_Y + (r << 2), PREVIEW_CELL, PREVIEW_CELL, piece_colors[next_type]);
            }
        }
    }

    shown_next_type = next_type;
}

static void render_metrics(int force_full)
{
    unsigned int progress_fill;

    if (force_full || shown_score != score) {
        fill_rect(SCORE_VALUE_X, SCORE_VALUE_Y, 48u, 10u, COLOR_CARD);
        draw_uint_fixed(SCORE_VALUE_X, SCORE_VALUE_Y, SCORE_DIGITS, 2u, score, COLOR_TEXT);
        shown_score = score;
    }

    if (force_full || shown_level != level_value) {
        fill_rect(LEVEL_VALUE_X, LEVEL_VALUE_Y, 8u, 5u, COLOR_CARD);
        draw_uint_fixed(LEVEL_VALUE_X, LEVEL_VALUE_Y, 2u, 1u, level_value, COLOR_TEXT);
        shown_level = level_value;
    }

    if (force_full || shown_lines != lines_cleared_total) {
        fill_rect(LINES_VALUE_X, LINES_VALUE_Y, 12u, 5u, COLOR_CARD);
        draw_uint_fixed(LINES_VALUE_X, LINES_VALUE_Y, 3u, 1u, lines_cleared_total, COLOR_TEXT);
        shown_lines = lines_cleared_total;
    }

    if (force_full || shown_pieces != piece_count) {
        fill_rect(PIECES_VALUE_X, PIECES_VALUE_Y, 12u, 5u, COLOR_CARD);
        draw_uint_fixed(PIECES_VALUE_X, PIECES_VALUE_Y, 3u, 1u, piece_count, COLOR_TEXT);
        shown_pieces = piece_count;
    }

    if (force_full || shown_lines_until != lines_until_level) {
        fill_rect(GOAL_BAR_X, GOAL_BAR_Y, GOAL_BAR_W, GOAL_BAR_H, COLOR_GOAL_BG);
        progress_fill = (LEVEL_LINES - lines_until_level) * (GOAL_BAR_W / LEVEL_LINES);
        if (progress_fill > GOAL_BAR_W) {
            progress_fill = GOAL_BAR_W;
        }
        if (progress_fill != 0u) {
            fill_rect(GOAL_BAR_X, GOAL_BAR_Y, progress_fill, GOAL_BAR_H, COLOR_GOAL_FILL);
        }
        shown_lines_until = lines_until_level;
    }
}

static void render_game_over_overlay(int force_full)
{
    if (!force_full && shown_game_over == game_over) {
        return;
    }

    if (game_over) {
        draw_frame(GAME_OVER_X, GAME_OVER_Y, GAME_OVER_W, GAME_OVER_H, COLOR_FRAME, COLOR_OVERLAY);
        draw_text_centered(GAME_OVER_X, GAME_OVER_Y + 2u, GAME_OVER_W, "GAME OVER", 1u, COLOR_TEXT);
    } else {
        int r;
        int c;
        for (r = 0; r < BOARD_H; r++) {
            for (c = 0; c < BOARD_W; c++) {
                shown_cells[r][c] = 0xFFu;
            }
        }
        render_board_cells(1);
    }

    shown_game_over = game_over;
}

static void render_status_overlay(int force_full)
{
    int armed = (quit_arm_polls != 0u);

    if (!force_full && shown_quit_arm == armed) {
        return;
    }

    fill_rect(STATUS_X + 1u, STATUS_Y + 1u, STATUS_W - 2u, STATUS_H - 2u, COLOR_CARD);
    if (armed) {
        draw_text_centered(STATUS_X, STATUS_Y + 2u, STATUS_W, "PRESS AGAIN", 1u, COLOR_ACCENT);
    }

    shown_quit_arm = armed;
}

static void render_scene(void)
{
    int force_full = 0;

    if (!scene_valid) {
        draw_static_scene();
        force_full = 1;
    }

    render_board_cells(force_full);
    render_preview(force_full);
    render_metrics(force_full);
    render_game_over_overlay(force_full);
    render_status_overlay(force_full);
    need_redraw = 0;
}

static int handle_runtime_input(int ch)
{
    ch = ui_to_lower(ch);

    if ((ch == '\r') || (ch == '\n')) {
        return 0;
    }

    if (ch == 'q') {
        if (quit_arm_polls != 0u) {
            return -1;
        }
        quit_arm_polls = QUIT_ARM_POLLS;
        need_redraw = 1;
        ui_puts("\nPress q again to return to menu.\n");
        return 0;
    }

    if (quit_arm_polls != 0u) {
        quit_arm_polls = 0u;
        need_redraw = 1;
    }

    if (game_over) {
        if (ch == 'r') {
            start_new_game();
        }
        return 0;
    }

    if (ch == 'a') {
        (void)move_piece(-1, 0);
    } else if (ch == 'd') {
        (void)move_piece(1, 0);
    } else if (ch == 's') {
        advance_game();
    } else if ((ch == 'w') || (ch == 'x')) {
        rotate_piece();
    } else if (ch == ' ') {
        hard_drop();
        advance_game();
    }

    return 0;
}

int main(void)
{
    unsigned int drop_counter = 0u;

    ui_clear_screen();
    ui_puts("VGA Tetris demo (160x120 framebuffer)\n");
    ui_puts("Use UART as keyboard: a/d move, w/x rotate, s soft drop, space hard drop, q quit.\n");
    ui_drain_input();

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();

    invalidate_render_cache();
    scene_valid = 0;
    start_new_game();

    while (1) {
        int ch = ui_read_byte_nonblocking();

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        if (ui_launcher_menu_requested()) {
            ui_input_barrier();
            ui_launcher_request_menu();
        }
#endif

        if (quit_arm_polls != 0u) {
            quit_arm_polls--;
            if (quit_arm_polls == 0u) {
                need_redraw = 1;
            }
        }

        if (need_redraw) {
            render_scene();
        }

        if (ch >= 0) {
            if (handle_runtime_input(ch) < 0) {
                ui_puts("\nBye.\n");
                break;
            }
        }

        if (!game_over) {
            drop_counter++;
            if (drop_counter >= drop_polls_current) {
                drop_counter = 0u;
                advance_game();
            }
        }

        ui_short_pause(POLL_SPIN);
    }

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_present();
    return 0;
}
