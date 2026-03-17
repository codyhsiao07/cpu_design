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

#define BOARD_FRAME_X 6u
#define BOARD_FRAME_Y 18u
#define BOARD_FRAME_W 104u
#define BOARD_FRAME_H 79u
#define BOARD_X 8u
#define BOARD_Y 20u

#define PANEL_X 114u
#define PANEL_Y 18u
#define PANEL_W 42u
#define PANEL_H 79u
#define PANEL_BOX_X 118u
#define PANEL_BOX_W 34u
#define SCORE_LABEL_Y 24u
#define SCORE_BOX_Y 30u
#define BEST_LABEL_Y 43u
#define BEST_BOX_Y 49u
#define LEN_LABEL_Y 62u
#define LEN_BOX_Y 68u
#define SPEED_LABEL_Y 81u
#define SPEED_BOX_Y 87u
#define PANEL_BOX_H 8u

#define FOOTER_X 4u
#define FOOTER_Y 101u
#define FOOTER_W 152u
#define FOOTER_H 15u

#define OVERLAY_X 28u
#define OVERLAY_Y 44u
#define OVERLAY_W 60u
#define OVERLAY_H 22u

#define GRID_W 20u
#define GRID_H 15u
#define CELL_SIZE 5u
#define BOARD_PIX_W (GRID_W * CELL_SIZE)
#define BOARD_PIX_H (GRID_H * CELL_SIZE)
#define MAX_SNAKE_CELLS (GRID_W * GRID_H)
#define START_LEN 4u

#define STATE_READY 0u
#define STATE_PLAY 1u
#define STATE_GAME_OVER 2u
#define STATE_WIN 3u

#define STEP_TICKS_START 120u
#define STEP_TICKS_MIN 42u
#define STEP_TICKS_DECAY 6u
#define POLL_SPIN 2200u

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 6u
#define COLOR_ACCENT 15u
#define COLOR_TEXT 7u
#define COLOR_LABEL 14u
#define COLOR_SUBTEXT 13u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_FIELD_A 0u
#define COLOR_FIELD_B 0u
#define COLOR_SNAKE 2u
#define COLOR_SNAKE_EDGE 9u
#define COLOR_HEAD 15u
#define COLOR_HEAD_EDGE 4u
#define COLOR_FOOD 1u
#define COLOR_FOOD_SPARK 7u
#define COLOR_OVERLAY 13u
#define COLOR_OVERLAY_TEXT 7u

#include "games_shared_ui.h"
#include "vga_fb.h"

static unsigned char snake_x[MAX_SNAKE_CELLS];
static unsigned char snake_y[MAX_SNAKE_CELLS];
static unsigned int snake_len;
static int dir_x;
static int dir_y;
static int next_dir_x;
static int next_dir_y;
static unsigned char food_x;
static unsigned char food_y;
static unsigned int score;
static unsigned int best_score;
static unsigned int speed_ticks;
static unsigned int step_counter;
static unsigned int game_state;
static unsigned int rng_state = 0x53A9C17Du;
static int scene_valid;
static int need_redraw;
static int board_redraw;
static int hud_redraw;

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

static unsigned int next_random(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

static unsigned int speed_level(void)
{
    unsigned int level = 1u;
    unsigned int ticks = STEP_TICKS_START;

    while (ticks > speed_ticks) {
        level++;
        if (ticks > (STEP_TICKS_MIN + STEP_TICKS_DECAY)) {
            ticks -= STEP_TICKS_DECAY;
        } else {
            ticks = STEP_TICKS_MIN;
        }
    }
    return level;
}

static void mark_full_redraw(void)
{
    board_redraw = 1;
    hud_redraw = 1;
    need_redraw = 1;
}

static int snake_hits_cell(unsigned int x, unsigned int y, int ignore_tail)
{
    unsigned int i;
    unsigned int limit = snake_len;

    if (ignore_tail && limit > 0u) {
        limit--;
    }

    for (i = 0u; i < limit; i++) {
        if ((unsigned int)snake_x[i] == x && (unsigned int)snake_y[i] == y) {
            return 1;
        }
    }
    return 0;
}

static void update_speed(void)
{
    unsigned int reduce = 0u;
    unsigned int extra = (snake_len > START_LEN) ? (snake_len - START_LEN) : 0u;

    while (extra >= 2u) {
        extra -= 2u;
        reduce += STEP_TICKS_DECAY;
    }

    if (reduce >= (STEP_TICKS_START - STEP_TICKS_MIN)) {
        speed_ticks = STEP_TICKS_MIN;
    } else {
        speed_ticks = STEP_TICKS_START - reduce;
    }
}

static unsigned int scale_cell(unsigned int value)
{
    return (value << 2) + value;
}

static void spawn_food(void)
{
    unsigned int free_count = MAX_SNAKE_CELLS - snake_len;
    unsigned int target;
    unsigned int x;
    unsigned int y;
    unsigned int index = 0u;

    if (free_count == 0u) {
        game_state = STATE_WIN;
        if (score > best_score) {
            best_score = score;
        }
        mark_full_redraw();
        return;
    }

    target = next_random() & 0x1FFu;
    while (target >= free_count) {
        target -= free_count;
    }

    for (y = 0u; y < GRID_H; y++) {
        for (x = 0u; x < GRID_W; x++) {
            if (!snake_hits_cell(x, y, 0)) {
                if (index == target) {
                    food_x = (unsigned char)x;
                    food_y = (unsigned char)y;
                    return;
                }
                index++;
            }
        }
    }
}

static void start_new_game(void)
{
    unsigned int start_x = GRID_W >> 1;
    unsigned int start_y = GRID_H >> 1;
    unsigned int i;

    snake_len = START_LEN;
    for (i = 0u; i < START_LEN; i++) {
        snake_x[i] = (unsigned char)(start_x - i);
        snake_y[i] = (unsigned char)start_y;
    }
    dir_x = 1;
    dir_y = 0;
    next_dir_x = 1;
    next_dir_y = 0;
    score = 0u;
    step_counter = 0u;
    game_state = STATE_READY;
    scene_valid = 0;
    update_speed();
    spawn_food();
    mark_full_redraw();
}

static void draw_snake_segment(unsigned int cell_x, unsigned int cell_y, int is_head)
{
    unsigned int px = BOARD_X + scale_cell(cell_x);
    unsigned int py = BOARD_Y + scale_cell(cell_y);
    unsigned char edge = is_head ? COLOR_HEAD_EDGE : COLOR_SNAKE_EDGE;
    unsigned char fill = is_head ? COLOR_HEAD : COLOR_SNAKE;

    fill_rect(px, py, CELL_SIZE, CELL_SIZE, edge);
    if (CELL_SIZE > 2u) {
        fill_rect(px + 1u, py + 1u, CELL_SIZE - 2u, CELL_SIZE - 2u, fill);
    }
    if (is_head) {
        vga_fb_put_pixel(px + 1u, py + 1u, COLOR_TEXT);
    }
}

static void draw_food(void)
{
    unsigned int px = BOARD_X + scale_cell((unsigned int)food_x);
    unsigned int py = BOARD_Y + scale_cell((unsigned int)food_y);

    fill_rect(px, py, CELL_SIZE, CELL_SIZE, COLOR_FOOD);
    if (CELL_SIZE > 2u) {
        fill_rect(px + 1u, py + 1u, CELL_SIZE - 2u, CELL_SIZE - 2u, COLOR_ACCENT);
        vga_fb_put_pixel(px + 2u, py + 1u, COLOR_FOOD_SPARK);
    }
}

static void draw_board(void)
{
    unsigned int y;
    unsigned int x;
    unsigned int i;

    for (y = 0u; y < GRID_H; y++) {
        for (x = 0u; x < GRID_W; x++) {
            unsigned char tone = (((x + y) & 1u) == 0u) ? COLOR_FIELD_A : COLOR_FIELD_B;
            fill_rect(BOARD_X + scale_cell(x), BOARD_Y + scale_cell(y), CELL_SIZE, CELL_SIZE, tone);
        }
    }

    draw_food();
    for (i = snake_len; i > 0u; i--) {
        draw_snake_segment((unsigned int)snake_x[i - 1u], (unsigned int)snake_y[i - 1u], i == 1u);
    }

    board_redraw = 0;
}

static void draw_title_bar(void)
{
    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    draw_text_centered(TITLE_X, TITLE_Y + 3u, TITLE_W, "SNAKE", 2u, COLOR_TEXT);
}

static void draw_static_scene(void)
{
    vga_fb_clear(COLOR_BG);
    draw_title_bar();
    draw_frame(BOARD_FRAME_X, BOARD_FRAME_Y, BOARD_FRAME_W, BOARD_FRAME_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(PANEL_X + 2u, PANEL_Y + 2u, PANEL_W - 4u, 2u, COLOR_ACCENT);
    draw_frame(FOOTER_X, FOOTER_Y, FOOTER_W, FOOTER_H, COLOR_FRAME, COLOR_PANEL);
    scene_valid = 1;
}

static void render_hud(void)
{
    if (!hud_redraw) {
        return;
    }

    draw_text_centered(PANEL_BOX_X, SCORE_LABEL_Y, PANEL_BOX_W, "SCORE", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, SCORE_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_ACCENT, COLOR_CARD);
    fill_rect(PANEL_BOX_X + 1u, SCORE_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);
    draw_uint(PANEL_BOX_X + 4u, SCORE_BOX_Y + 2u, 1u, score, COLOR_TEXT);

    draw_text_centered(PANEL_BOX_X, BEST_LABEL_Y, PANEL_BOX_W, "BEST", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, BEST_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_SUBTEXT, COLOR_CARD);
    fill_rect(PANEL_BOX_X + 1u, BEST_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);
    draw_uint(PANEL_BOX_X + 4u, BEST_BOX_Y + 2u, 1u, best_score, COLOR_TEXT);

    draw_text_centered(PANEL_BOX_X, LEN_LABEL_Y, PANEL_BOX_W, "LEN", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, LEN_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_SUBTEXT, COLOR_CARD);
    fill_rect(PANEL_BOX_X + 1u, LEN_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);
    draw_uint(PANEL_BOX_X + 4u, LEN_BOX_Y + 2u, 1u, snake_len, COLOR_TEXT);

    draw_text_centered(PANEL_BOX_X, SPEED_LABEL_Y, PANEL_BOX_W, "SPD", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, SPEED_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_SUBTEXT, COLOR_CARD);
    fill_rect(PANEL_BOX_X + 1u, SPEED_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);
    draw_uint(PANEL_BOX_X + 4u, SPEED_BOX_Y + 2u, 1u, speed_level(), COLOR_TEXT);

    fill_rect(FOOTER_X + 1u, FOOTER_Y + 1u, FOOTER_W - 2u, FOOTER_H - 2u, COLOR_PANEL);
    draw_text_centered(FOOTER_X, FOOTER_Y + 2u, FOOTER_W, "WASD TURN  SPC START  R RESET  QQ BACK", 1u, COLOR_TEXT);
    hud_redraw = 0;
}

static const char *overlay_title(void)
{
    if (game_state == STATE_GAME_OVER) {
        return "GAME OVER";
    }
    if (game_state == STATE_WIN) {
        return "YOU WIN";
    }
    return "SPACE START";
}

static const char *overlay_hint(void)
{
    if (game_state == STATE_READY) {
        return "WASD TO TURN";
    }
    if (game_state == STATE_WIN) {
        return "R RESET  QQ BACK";
    }
    return "R RESET  QQ BACK";
}

static void render_overlay(void)
{
    if (game_state == STATE_PLAY) {
        return;
    }

    draw_frame(OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H, COLOR_FRAME, COLOR_OVERLAY);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 4u, OVERLAY_W, overlay_title(), 1u, COLOR_OVERLAY_TEXT);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 12u, OVERLAY_W, overlay_hint(), 1u, COLOR_OVERLAY_TEXT);
}

static void render_scene(void)
{
    if (!scene_valid) {
        draw_static_scene();
        board_redraw = 1;
        hud_redraw = 1;
    }

    render_hud();
    if (board_redraw) {
        draw_board();
    }
    render_overlay();
    need_redraw = 0;
}

static void begin_play(void)
{
    if (game_state == STATE_READY) {
        game_state = STATE_PLAY;
        step_counter = 0u;
        board_redraw = 1;
        need_redraw = 1;
    }
}

static void queue_direction(int dx, int dy)
{
    if ((dx == 0 && dy == 0) ||
        ((dx == -dir_x) && (dy == -dir_y)) ||
        ((dx == -next_dir_x) && (dy == -next_dir_y))) {
        return;
    }

    next_dir_x = dx;
    next_dir_y = dy;
    if (game_state == STATE_READY) {
        begin_play();
    }
}

static void shift_snake(unsigned int new_x, unsigned int new_y, int grow)
{
    unsigned int i;
    unsigned int limit = grow ? snake_len : (snake_len - 1u);

    for (i = limit; i > 0u; i--) {
        snake_x[i] = snake_x[i - 1u];
        snake_y[i] = snake_y[i - 1u];
    }
    snake_x[0] = (unsigned char)new_x;
    snake_y[0] = (unsigned char)new_y;
    if (grow) {
        snake_len++;
    }
}

static void advance_snake(void)
{
    int head_x;
    int head_y;
    int next_x;
    int next_y;
    unsigned int grow;

    if (game_state != STATE_PLAY) {
        return;
    }

    dir_x = next_dir_x;
    dir_y = next_dir_y;
    head_x = (int)snake_x[0];
    head_y = (int)snake_y[0];
    next_x = head_x + dir_x;
    next_y = head_y + dir_y;

    if (next_x < 0 || next_x >= (int)GRID_W || next_y < 0 || next_y >= (int)GRID_H) {
        game_state = STATE_GAME_OVER;
        if (score > best_score) {
            best_score = score;
        }
        mark_full_redraw();
        return;
    }

    grow = ((unsigned int)next_x == (unsigned int)food_x && (unsigned int)next_y == (unsigned int)food_y) ? 1u : 0u;
    if (snake_hits_cell((unsigned int)next_x, (unsigned int)next_y, !grow)) {
        game_state = STATE_GAME_OVER;
        if (score > best_score) {
            best_score = score;
        }
        mark_full_redraw();
        return;
    }

    shift_snake((unsigned int)next_x, (unsigned int)next_y, grow != 0u);
    if (grow) {
        score += 10u;
        if (score > best_score) {
            best_score = score;
        }
        update_speed();
        spawn_food();
        hud_redraw = 1;
    }

    board_redraw = 1;
    need_redraw = 1;
}

static int handle_input(int ch)
{
    ch = ui_to_lower(ch);

    if (ch == 'q') {
        return -1;
    }
    if (ch == 'r') {
        start_new_game();
        return 0;
    }
    if ((ch == '\r') || (ch == '\n')) {
        return 0;
    }
    if (ch == ' ') {
        begin_play();
        return 0;
    }
    if (ch == 'w') {
        queue_direction(0, -1);
        return 0;
    }
    if (ch == 'a') {
        queue_direction(-1, 0);
        return 0;
    }
    if (ch == 's') {
        queue_direction(0, 1);
        return 0;
    }
    if (ch == 'd') {
        queue_direction(1, 0);
        return 0;
    }
    return 0;
}

int main(void)
{
    ui_clear_screen();
    ui_puts("VGA Snake demo (160x120 framebuffer)\n");
    ui_puts("Use UART keyboard: w/a/s/d turn, space start, r reset, q twice to go back.\n");
    ui_drain_input();

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();
    start_new_game();

    while (1) {
        int ch = ui_read_byte_nonblocking();

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        if (ui_launcher_menu_requested()) {
            ui_input_barrier();
            ui_launcher_request_menu();
        }
#endif

        if (ch >= 0) {
            if (handle_input(ch) < 0) {
                ui_puts("\nBye.\n");
                break;
            }
        }

        if (game_state == STATE_PLAY) {
            step_counter++;
            if (step_counter >= speed_ticks) {
                step_counter = 0u;
                advance_snake();
            }
        }

        if (need_redraw) {
            render_scene();
        }

        ui_short_pause(POLL_SPIN);
    }

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_present();
    return 0;
}
