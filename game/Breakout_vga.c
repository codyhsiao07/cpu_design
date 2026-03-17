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

#define FIELD_X 6u
#define FIELD_Y 18u
#define FIELD_W 148u
#define FIELD_H 90u
#define INNER_X 8u
#define INNER_Y 20u
#define INNER_W 144u
#define INNER_H 86u

#define FOOTER_X 4u
#define FOOTER_Y 111u
#define FOOTER_W 152u
#define FOOTER_H 7u

#define OVERLAY_X 38u
#define OVERLAY_Y 46u
#define OVERLAY_W 84u
#define OVERLAY_H 22u

#define BRICK_COLS 10
#define BRICK_ROWS 5
#define BRICK_W 13u
#define BRICK_H 5u
#define BRICK_GAP_X 1u
#define BRICK_GAP_Y 1u
#define BRICK_X 10u
#define BRICK_Y 24u

#define PADDLE_W 22u
#define PADDLE_H 4u
#define PADDLE_Y 96u
#define PADDLE_STEP 5u
#define PADDLE_MIN_X (INNER_X + 2u)
#define PADDLE_MAX_X (INNER_X + INNER_W - 2u - PADDLE_W)

#define BALL_SIZE 3u
#define MAX_LEVELS 3u
#define START_LIVES 3u

#define STATE_SERVE 0
#define STATE_PLAY 1
#define STATE_GAME_OVER 2
#define STATE_CLEAR 3

#define SERVE_START 0
#define SERVE_LIFE 1
#define SERVE_LEVEL 2

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 6u
#define COLOR_ACCENT 15u
#define COLOR_TEXT 7u
#define COLOR_LABEL 4u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_FIELD 0u
#define COLOR_GRID 10u
#define COLOR_PADDLE 6u
#define COLOR_PADDLE_EDGE 7u
#define COLOR_BALL 4u
#define COLOR_BALL_GLOW 15u
#define COLOR_OVERLAY 12u
#define COLOR_SHADOW 10u

#define POLL_SPIN 2200u
#define INPUT_BURST_LIMIT 8u
#define QUIT_ARM_POLLS 240u

#include "games_shared_ui.h"
#include "vga_fb.h"

static unsigned char bricks[BRICK_ROWS][BRICK_COLS];
static unsigned int paddle_x;
static unsigned int ball_x;
static unsigned int ball_y;
static int ball_vx;
static int ball_vy;
static unsigned int score;
static unsigned int lives;
static unsigned int level_no;
static unsigned int bricks_left;
static unsigned int state;
static unsigned int serve_reason;
static unsigned int tick_counter;
static int scene_valid;
static int need_redraw;
static int field_full_redraw;
static int chrome_redraw;
static int have_prev_dynamic;
static unsigned int quit_arm_polls;
static unsigned int prev_paddle_x;
static unsigned int prev_ball_x;
static unsigned int prev_ball_y;

static int rects_overlap(unsigned int ax, unsigned int ay, unsigned int aw, unsigned int ah,
                         unsigned int bx, unsigned int by, unsigned int bw, unsigned int bh);

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

static void draw_text_centered(unsigned int x, unsigned int y, unsigned int w, const char *text, unsigned int scale, unsigned char color)
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

static unsigned char brick_color_for_row(unsigned int row)
{
    static const unsigned char colors[BRICK_ROWS] = {1u, 15u, 4u, 2u, 6u};
    return colors[row];
}

static int is_mod3_zero(unsigned int value)
{
    while (value >= 3u) {
        value -= 3u;
    }
    return value == 0u;
}

static unsigned int speed_goal_for_level(void)
{
    unsigned int base = 16u;
    unsigned int reduce = (level_no > 0u) ? ((level_no - 1u) * 3u) : 0u;

    if (reduce >= 8u) {
        return 8u;
    }
    if (base <= reduce + 4u) {
        return 8u;
    }
    return base - reduce;
}

static void request_full_redraw(void)
{
    field_full_redraw = 1;
    chrome_redraw = 1;
    have_prev_dynamic = 0;
    need_redraw = 1;
}

static void reset_ball_to_paddle(void)
{
    ball_x = paddle_x + (PADDLE_W >> 1) - (BALL_SIZE >> 1);
    ball_y = PADDLE_Y - BALL_SIZE - 1u;
    ball_vx = 1;
    ball_vy = -1;
    tick_counter = 0u;
}

static void init_level_bricks(void)
{
    unsigned int row;
    unsigned int col;

    bricks_left = 0u;
    for (row = 0u; row < BRICK_ROWS; row++) {
        for (col = 0u; col < BRICK_COLS; col++) {
            unsigned char active = 1u;

            if (level_no == 2u) {
                active = (unsigned char)(((row + col) & 1u) == 0u ? 1u : 0u);
                if (row == 0u || row == BRICK_ROWS - 1u) {
                    active = 1u;
                }
            } else if (level_no >= 3u) {
                active = (unsigned char)((row == 0u) || (row == BRICK_ROWS - 1u) ||
                                         (col == 0u) || (col == BRICK_COLS - 1u) ||
                                         is_mod3_zero(row + col));
            }

            bricks[row][col] = active;
            if (active != 0u) {
                bricks_left++;
            }
        }
    }
}

static void start_new_run(void)
{
    score = 0u;
    lives = START_LIVES;
    level_no = 1u;
    paddle_x = (INNER_X + ((INNER_W - PADDLE_W) >> 1));
    init_level_bricks();
    reset_ball_to_paddle();
    state = STATE_SERVE;
    serve_reason = SERVE_START;
    scene_valid = 0;
    quit_arm_polls = 0u;
    request_full_redraw();
}

static void advance_to_next_level(void)
{
    if (level_no >= MAX_LEVELS) {
        state = STATE_CLEAR;
        quit_arm_polls = 0u;
        request_full_redraw();
        return;
    }

    level_no++;
    init_level_bricks();
    paddle_x = (INNER_X + ((INNER_W - PADDLE_W) >> 1));
    reset_ball_to_paddle();
    state = STATE_SERVE;
    serve_reason = SERVE_LEVEL;
    quit_arm_polls = 0u;
    request_full_redraw();
}

static void lose_ball(void)
{
    if (lives > 1u) {
        lives--;
        paddle_x = (INNER_X + ((INNER_W - PADDLE_W) >> 1));
        reset_ball_to_paddle();
        state = STATE_SERVE;
        serve_reason = SERVE_LIFE;
    } else {
        lives = 0u;
        state = STATE_GAME_OVER;
    }
    quit_arm_polls = 0u;
    request_full_redraw();
}

static void draw_brick(unsigned int row, unsigned int col)
{
    unsigned int x = BRICK_X + (col * (BRICK_W + BRICK_GAP_X));
    unsigned int y = BRICK_Y + (row * (BRICK_H + BRICK_GAP_Y));
    unsigned char base = brick_color_for_row(row);

    if (bricks[row][col] == 0u) {
        return;
    }

    fill_rect(x, y, BRICK_W, BRICK_H, base);
    fill_rect(x, y, BRICK_W, 1u, COLOR_TEXT);
    if (BRICK_W > 2u) {
        fill_rect(x + 1u, y + BRICK_H - 1u, BRICK_W - 2u, 1u, COLOR_SHADOW);
    }
    if (BRICK_W > 4u && BRICK_H > 3u) {
        fill_rect(x + 2u, y + 2u, BRICK_W - 4u, 1u, COLOR_ACCENT);
    }
}

static void draw_paddle(void)
{
    fill_rect(paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, COLOR_PADDLE);
    fill_rect(paddle_x, PADDLE_Y, PADDLE_W, 1u, COLOR_PADDLE_EDGE);
    fill_rect(paddle_x, PADDLE_Y + PADDLE_H - 1u, PADDLE_W, 1u, COLOR_SHADOW);
}

static void draw_ball(void)
{
    fill_rect(ball_x, ball_y, BALL_SIZE, BALL_SIZE, COLOR_BALL_GLOW);
    fill_rect(ball_x + 1u, ball_y + 1u, 1u, 1u, COLOR_BALL);
}

static const char *overlay_title(void)
{
    if (state == STATE_GAME_OVER) {
        return "GAME OVER";
    }
    if (state == STATE_CLEAR) {
        return "YOU WIN";
    }
    if (serve_reason == SERVE_LEVEL) {
        return "LEVEL UP";
    }
    return "PRESS SPACE";
}

static const char *overlay_hint(void)
{
    if (state == STATE_GAME_OVER || state == STATE_CLEAR) {
        if (quit_arm_polls != 0u) {
            return "PRESS Q AGAIN";
        }
        return "R RESET  Q AGAIN";
    }
    if (quit_arm_polls != 0u) {
        return "PRESS Q AGAIN";
    }
    return "A D MOVE  SPACE";
}

static void draw_overlay(void)
{
    if (state == STATE_PLAY) {
        return;
    }

    draw_frame(OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H, COLOR_FRAME, COLOR_OVERLAY);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 4u, OVERLAY_W, overlay_title(), 1u, COLOR_TEXT);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 12u, OVERLAY_W, overlay_hint(), 1u, COLOR_LABEL);
}

static void draw_static_scene(void)
{
    vga_fb_clear(COLOR_BG);

    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FIELD_X, FIELD_Y, FIELD_W, FIELD_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FOOTER_X, FOOTER_Y, FOOTER_W, FOOTER_H, COLOR_FRAME, COLOR_PANEL);

    fill_rect(INNER_X, INNER_Y, INNER_W, INNER_H, COLOR_FIELD);
    fill_rect(INNER_X, INNER_Y, INNER_W, 1u, COLOR_GRID);
    fill_rect(INNER_X, INNER_Y + INNER_H - 1u, INNER_W, 1u, COLOR_GRID);
    scene_valid = 1;
}

static void render_chrome(void)
{
    const char *footer_text = "A D MOVE  SPC LAUNCH  R RESET  Q QUIT";

    if (!chrome_redraw) {
        return;
    }

    if (quit_arm_polls != 0u) {
        footer_text = "A D MOVE  SPC LAUNCH  R RESET  Q AGAIN";
    }

    fill_rect(TITLE_X + 1u, TITLE_Y + 1u, TITLE_W - 2u, TITLE_H - 2u, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    draw_text(TITLE_X + 6u, TITLE_Y + 3u, "SC", 1u, COLOR_LABEL);
    draw_uint(TITLE_X + 18u, TITLE_Y + 3u, 1u, score, COLOR_TEXT);
    draw_text_centered(TITLE_X, TITLE_Y + 3u, TITLE_W, "BREAKOUT", 2u, COLOR_TEXT);
    draw_text(TITLE_X + 112u, TITLE_Y + 3u, "LV", 1u, COLOR_LABEL);
    draw_uint(TITLE_X + 123u, TITLE_Y + 3u, 1u, level_no, COLOR_TEXT);
    draw_text(TITLE_X + 133u, TITLE_Y + 3u, "L", 1u, COLOR_LABEL);
    draw_uint(TITLE_X + 140u, TITLE_Y + 3u, 1u, lives, COLOR_TEXT);

    fill_rect(FOOTER_X + 1u, FOOTER_Y + 1u, FOOTER_W - 2u, FOOTER_H - 2u, COLOR_PANEL);
    draw_text_centered(FOOTER_X, FOOTER_Y + 1u, FOOTER_W, footer_text, 1u, COLOR_TEXT);
    chrome_redraw = 0;
}

static void render_field_full(void)
{
    unsigned int row;
    unsigned int col;

    fill_rect(INNER_X, INNER_Y, INNER_W, INNER_H, COLOR_FIELD);
    fill_rect(INNER_X + 1u, INNER_Y + 12u, INNER_W - 2u, 1u, COLOR_GRID);

    for (row = 0u; row < BRICK_ROWS; row++) {
        for (col = 0u; col < BRICK_COLS; col++) {
            draw_brick(row, col);
        }
    }

    draw_paddle();
    draw_ball();
    draw_overlay();
    prev_paddle_x = paddle_x;
    prev_ball_x = ball_x;
    prev_ball_y = ball_y;
    have_prev_dynamic = 1;
    field_full_redraw = 0;
}

static int clip_field_rect(unsigned int *x, unsigned int *y, unsigned int *w, unsigned int *h)
{
    unsigned int x0 = *x;
    unsigned int y0 = *y;
    unsigned int x1 = x0 + *w;
    unsigned int y1 = y0 + *h;
    unsigned int field_x1 = INNER_X + INNER_W;
    unsigned int field_y1 = INNER_Y + INNER_H;

    if (x0 < INNER_X) {
        x0 = INNER_X;
    }
    if (y0 < INNER_Y) {
        y0 = INNER_Y;
    }
    if (x1 > field_x1) {
        x1 = field_x1;
    }
    if (y1 > field_y1) {
        y1 = field_y1;
    }
    if (x0 >= x1 || y0 >= y1) {
        return 0;
    }

    *x = x0;
    *y = y0;
    *w = x1 - x0;
    *h = y1 - y0;
    return 1;
}

static void redraw_field_line_if_visible(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned int line_y)
{
    if (line_y >= y && line_y < (y + h)) {
        fill_rect(x, line_y, w, 1u, COLOR_GRID);
    }
}

static void redraw_field_region(unsigned int x, unsigned int y, unsigned int w, unsigned int h)
{
    unsigned int row;
    unsigned int col;

    if (!clip_field_rect(&x, &y, &w, &h)) {
        return;
    }

    fill_rect(x, y, w, h, COLOR_FIELD);
    redraw_field_line_if_visible(x, y, w, h, INNER_Y);
    redraw_field_line_if_visible(x, y, w, h, INNER_Y + 12u);
    redraw_field_line_if_visible(x, y, w, h, INNER_Y + INNER_H - 1u);

    for (row = 0u; row < BRICK_ROWS; row++) {
        for (col = 0u; col < BRICK_COLS; col++) {
            unsigned int brick_x;
            unsigned int brick_y;

            if (bricks[row][col] == 0u) {
                continue;
            }

            brick_x = BRICK_X + (col * (BRICK_W + BRICK_GAP_X));
            brick_y = BRICK_Y + (row * (BRICK_H + BRICK_GAP_Y));
            if (rects_overlap(x, y, w, h, brick_x, brick_y, BRICK_W, BRICK_H)) {
                draw_brick(row, col);
            }
        }
    }

    if (state != STATE_PLAY && rects_overlap(x, y, w, h, OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H)) {
        draw_overlay();
    }
}

static void render_field_dynamic(void)
{
    if (field_full_redraw || !have_prev_dynamic) {
        render_field_full();
        return;
    }

    redraw_field_region(prev_paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H);
    redraw_field_region(prev_ball_x, prev_ball_y, BALL_SIZE, BALL_SIZE);
    draw_paddle();
    draw_ball();
    prev_paddle_x = paddle_x;
    prev_ball_x = ball_x;
    prev_ball_y = ball_y;
}

static void render_scene(void)
{
    if (!scene_valid) {
        draw_static_scene();
    }
    render_chrome();
    render_field_dynamic();
    need_redraw = 0;
}

static void move_paddle_left(void)
{
    if (paddle_x > PADDLE_MIN_X) {
        if (paddle_x > (PADDLE_MIN_X + PADDLE_STEP)) {
            paddle_x -= PADDLE_STEP;
        } else {
            paddle_x = PADDLE_MIN_X;
        }
        if (state == STATE_SERVE) {
            reset_ball_to_paddle();
        }
        need_redraw = 1;
    }
}

static void move_paddle_right(void)
{
    if (paddle_x < PADDLE_MAX_X) {
        if ((paddle_x + PADDLE_STEP) < PADDLE_MAX_X) {
            paddle_x += PADDLE_STEP;
        } else {
            paddle_x = PADDLE_MAX_X;
        }
        if (state == STATE_SERVE) {
            reset_ball_to_paddle();
        }
        need_redraw = 1;
    }
}

static int rects_overlap(unsigned int ax, unsigned int ay, unsigned int aw, unsigned int ah,
                         unsigned int bx, unsigned int by, unsigned int bw, unsigned int bh)
{
    if ((ax + aw) <= bx || (bx + bw) <= ax) {
        return 0;
    }
    if ((ay + ah) <= by || (by + bh) <= ay) {
        return 0;
    }
    return 1;
}

static void handle_paddle_collision(void)
{
    if (rects_overlap(ball_x, ball_y, BALL_SIZE, BALL_SIZE, paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H) && ball_vy > 0) {
        unsigned int center = paddle_x + (PADDLE_W >> 1);
        unsigned int ball_center = ball_x + 1u;

        ball_y = PADDLE_Y - BALL_SIZE;
        ball_vy = -ball_vy;

        if (ball_center + 2u < center) {
            ball_vx = -2;
        } else if (ball_center < center) {
            ball_vx = -1;
        } else if (ball_center > center + 2u) {
            ball_vx = 2;
        } else {
            ball_vx = 1;
        }
    }
}

static int handle_brick_collision(void)
{
    unsigned int row;
    unsigned int col;

    for (row = 0u; row < BRICK_ROWS; row++) {
        for (col = 0u; col < BRICK_COLS; col++) {
            unsigned int brick_x;
            unsigned int brick_y;

            if (bricks[row][col] == 0u) {
                continue;
            }

            brick_x = BRICK_X + (col * (BRICK_W + BRICK_GAP_X));
            brick_y = BRICK_Y + (row * (BRICK_H + BRICK_GAP_Y));
            if (rects_overlap(ball_x, ball_y, BALL_SIZE, BALL_SIZE, brick_x, brick_y, BRICK_W, BRICK_H)) {
                bricks[row][col] = 0u;
                if (bricks_left != 0u) {
                    bricks_left--;
                }
                score += 10u * level_no;
                chrome_redraw = 1;

                if ((ball_y + BALL_SIZE) <= (brick_y + 1u) || ball_y >= (brick_y + BRICK_H - 1u)) {
                    ball_vy = -ball_vy;
                } else {
                    ball_vx = -ball_vx;
                }

                if (bricks_left == 0u) {
                    score += 100u * level_no;
                    chrome_redraw = 1;
                    advance_to_next_level();
                } else {
                    field_full_redraw = 1;
                    need_redraw = 1;
                }
                return 1;
            }
        }
    }

    return 0;
}

static void step_ball(void)
{
    int next_x;
    int next_y;

    if (state != STATE_PLAY) {
        return;
    }

    next_x = (int)ball_x + ball_vx;
    next_y = (int)ball_y + ball_vy;

    if (next_x <= (int)INNER_X) {
        ball_x = INNER_X;
        if (ball_vx < 0) {
            ball_vx = -ball_vx;
        }
    } else if ((unsigned int)(next_x + (int)BALL_SIZE) >= (INNER_X + INNER_W)) {
        ball_x = INNER_X + INNER_W - BALL_SIZE;
        if (ball_vx > 0) {
            ball_vx = -ball_vx;
        }
    } else {
        ball_x = (unsigned int)next_x;
    }

    if (next_y <= (int)INNER_Y) {
        ball_y = INNER_Y;
        if (ball_vy < 0) {
            ball_vy = -ball_vy;
        }
    } else {
        ball_y = (unsigned int)next_y;
    }

    handle_paddle_collision();
    if (state == STATE_PLAY) {
        (void)handle_brick_collision();
    }

    if ((ball_y + BALL_SIZE) >= (INNER_Y + INNER_H)) {
        lose_ball();
    } else {
        need_redraw = 1;
    }
}

static void launch_ball(void)
{
    if (state == STATE_SERVE) {
        state = STATE_PLAY;
        if (serve_reason == SERVE_LEVEL) {
            ball_vx = -1;
        } else {
            ball_vx = 1;
        }
        ball_vy = -1;
        tick_counter = 0u;
        quit_arm_polls = 0u;
        request_full_redraw();
    }
}

static int handle_input_burst(void)
{
    unsigned int count = 0u;
    int move_dir = 0;

    while (count < INPUT_BURST_LIMIT) {
        int ch = ui_read_byte_nonblocking();

        if (ch < 0) {
            break;
        }

        ch = ui_to_lower(ch);
        if (ch == 'q') {
            if (quit_arm_polls != 0u) {
                return -1;
            }
            quit_arm_polls = QUIT_ARM_POLLS;
            chrome_redraw = 1;
            need_redraw = 1;
            ui_puts("\nPress q again to return to menu.\n");
            count++;
            continue;
        }
        if (ch == 'r') {
            start_new_run();
            move_dir = 0;
            count++;
            continue;
        }
        if ((ch == '\r') || (ch == '\n')) {
            count++;
            continue;
        }
        if (quit_arm_polls != 0u) {
            quit_arm_polls = 0u;
            chrome_redraw = 1;
            need_redraw = 1;
        }
        if (ch == 'a') {
            move_dir = -1;
            count++;
            continue;
        }
        if (ch == 'd') {
            move_dir = 1;
            count++;
            continue;
        }
        if (ch == ' ') {
            launch_ball();
        }
        count++;
    }

    if (move_dir < 0) {
        move_paddle_left();
    } else if (move_dir > 0) {
        move_paddle_right();
    }

    return 0;
}

int main(void)
{
    ui_clear_screen();
    ui_puts("VGA Breakout demo (160x120 framebuffer)\n");
    ui_puts("Use UART as keyboard: a/d move, space launch, r reset, q twice to quit.\n");
    ui_drain_input();

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_present();
    start_new_run();

    while (1) {
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        if (ui_launcher_menu_requested()) {
            ui_input_barrier();
            ui_launcher_request_menu();
        }
#endif

        if (quit_arm_polls != 0u) {
            quit_arm_polls--;
            if (quit_arm_polls == 0u) {
                chrome_redraw = 1;
                need_redraw = 1;
            }
        }

        if (handle_input_burst() < 0) {
            ui_puts("\nBye.\n");
            break;
        }

        if (state == STATE_PLAY) {
            tick_counter++;
            if (tick_counter >= speed_goal_for_level()) {
                tick_counter = 0u;
                step_ball();
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
