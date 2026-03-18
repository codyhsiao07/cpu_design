#include "games_shared_ui.h"
#include "vga_fb.h"
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
#include "launcher_jump.h"
#endif

#define GOMOKU_SIZE 9
#define GOMOKU_WIN_LEN 5

#define VIEW_MENU 0
#define VIEW_GAME 1

#define MODE_SINGLE_AI 0
#define MODE_DUAL 1

#define NOTE_NONE 0
#define NOTE_USED 1

#define PLAYER_BLACK 1
#define PLAYER_WHITE 2
#define RESULT_DRAW 3

#define SCREEN_W 160u
#define SCREEN_H 120u

#define TITLE_X 6u
#define TITLE_Y 4u
#define TITLE_W 148u
#define TITLE_H 12u
#define TITLE_BADGE_X 122u
#define TITLE_BADGE_Y 6u
#define TITLE_BADGE_W 26u
#define TITLE_BADGE_H 8u

#define BOARD_PANEL_X 4u
#define BOARD_PANEL_Y 18u
#define BOARD_PANEL_W 98u
#define BOARD_PANEL_H 90u
#define GRID_X 16u
#define GRID_Y 24u
#define CELL_SIZE 9u
#define GRID_W (GOMOKU_SIZE * CELL_SIZE)
#define GRID_H (GOMOKU_SIZE * CELL_SIZE)
#define GRID_CENTER 4u

#define PANEL_X 106u
#define PANEL_Y 18u
#define PANEL_W 50u
#define PANEL_H 90u
#define PANEL_BOX_X 111u
#define PANEL_BOX_W 40u
#define MODE_LABEL_Y 22u
#define MODE_BOX_Y 27u
#define TURN_LABEL_Y 38u
#define TURN_BOX_Y 43u
#define STATE_LABEL_Y 54u
#define STATE_BOX_Y 59u
#define CURSOR_LABEL_Y 70u
#define CURSOR_BOX_Y 75u
#define LAST_LABEL_Y 86u
#define LAST_BOX_Y 91u
#define PANEL_BOX_H 10u

#define FOOTER_X 4u
#define FOOTER_Y 111u
#define FOOTER_W 152u
#define FOOTER_H 7u

#define OVERLAY_X 21u
#define OVERLAY_Y 51u
#define OVERLAY_W 74u
#define OVERLAY_H 22u

#define MENU_PANEL_X 18u
#define MENU_PANEL_Y 22u
#define MENU_PANEL_W 124u
#define MENU_PANEL_H 78u
#define MENU_BOX_X 26u
#define MENU_BOX_W 108u
#define MENU_BOX1_Y 42u
#define MENU_BOX2_Y 66u
#define MENU_BOX_H 18u

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 14u
#define COLOR_ACCENT 4u
#define COLOR_TEXT 7u
#define COLOR_SUBTEXT 14u
#define COLOR_LABEL 4u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_BOARD 11u
#define COLOR_BOARD_SHADE 14u
#define COLOR_GRID 8u
#define COLOR_BLACK_STONE 0u
#define COLOR_BLACK_EDGE 8u
#define COLOR_WHITE_STONE 7u
#define COLOR_WHITE_EDGE 14u
#define COLOR_WHITE_SHADE 14u
#define COLOR_CURSOR_BLACK 6u
#define COLOR_CURSOR_WHITE 15u
#define COLOR_LAST 1u
#define COLOR_WIN 2u
#define COLOR_OVERLAY 12u
#define COLOR_MENU_SEL 14u
#define COLOR_MENU_FILL 13u
#define COLOR_MENU_BAR 6u
#define COLOR_SHADOW 8u

#define POLL_SPIN 3000u
#define QUIT_ARM_POLLS 240u

#include "games_shared_ui.h"
#include "vga_fb.h"

static unsigned char board[GOMOKU_SIZE][GOMOKU_SIZE];
static unsigned char win_marks[GOMOKU_SIZE][GOMOKU_SIZE];
static int screen_view;
static int game_mode;
static int menu_selection;
static int cursor_x;
static int cursor_y;
static int current_player;
static int winner;
static int note_code;
static int last_x;
static int last_y;
static int swallow_lf;
static unsigned int move_count;
static unsigned int quit_arm_polls;
static int scene_valid;
static int need_redraw;

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
static __attribute__((noreturn)) void launcher_button_return(void)
{
    ui_input_barrier();
    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();
#if defined(LAUNCHER_DIRECT_MENU_JUMP)
    launcher_jump_to_menu_soft_reset();
#else
    ui_launcher_request_menu();
#endif
}
#endif

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

static void draw_hline(unsigned int x, unsigned int y, unsigned int w, unsigned char color)
{
    fill_rect(x, y, w, 1u, color);
}

static void draw_vline(unsigned int x, unsigned int y, unsigned int h, unsigned char color)
{
    fill_rect(x, y, 1u, h, color);
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
    char buf[11];
    unsigned int len = 0u;
    unsigned int i;

    if (value == 0u) {
        buf[len++] = '0';
    } else {
        while (value != 0u) {
            buf[len++] = (char)('0' + (value % 10u));
            value /= 10u;
        }
        for (i = 0u; i < (len >> 1); i++) {
            char tmp = buf[i];
            buf[i] = buf[len - 1u - i];
            buf[len - 1u - i] = tmp;
        }
    }
    buf[len] = '\0';
    draw_text(x, y, buf, scale, color);
}

static unsigned int abs_diff_u(unsigned int a, unsigned int b)
{
    return (a >= b) ? (a - b) : (b - a);
}

static int in_bounds(int x, int y)
{
    return (x >= 0) && (x < GOMOKU_SIZE) && (y >= 0) && (y < GOMOKU_SIZE);
}

static int is_star_point(int row, int col)
{
    return ((row == 2 || row == 6) && (col == 2 || col == 6)) || (row == 4 && col == 4);
}

static void clear_win_marks(void)
{
    int row;
    int col;

    for (row = 0; row < GOMOKU_SIZE; row++) {
        for (col = 0; col < GOMOKU_SIZE; col++) {
            win_marks[row][col] = 0u;
        }
    }
}

static void reset_game(void)
{
    int row;
    int col;

    for (row = 0; row < GOMOKU_SIZE; row++) {
        for (col = 0; col < GOMOKU_SIZE; col++) {
            board[row][col] = 0u;
        }
    }

    clear_win_marks();
    cursor_x = GOMOKU_SIZE / 2;
    cursor_y = GOMOKU_SIZE / 2;
    current_player = PLAYER_BLACK;
    winner = 0;
    note_code = NOTE_NONE;
    last_x = -1;
    last_y = -1;
    move_count = 0u;
    quit_arm_polls = 0u;
    swallow_lf = 0;
    need_redraw = 1;
}

static void start_selected_mode(void)
{
    game_mode = menu_selection;
    screen_view = VIEW_GAME;
    scene_valid = 0;
    reset_game();
    ui_drain_input_limited(8u);
}

static void return_to_menu(void)
{
    screen_view = VIEW_MENU;
    scene_valid = 0;
    note_code = NOTE_NONE;
    quit_arm_polls = 0u;
    swallow_lf = 0;
    need_redraw = 1;
}

static void draw_corner_marks(unsigned int px, unsigned int py, unsigned int size, unsigned int len, unsigned char color)
{
    draw_hline(px, py, len, color);
    draw_vline(px, py, len, color);

    draw_hline(px + size - len, py, len, color);
    draw_vline(px + size - 1u, py, len, color);

    draw_hline(px, py + size - 1u, len, color);
    draw_vline(px, py + size - len, len, color);

    draw_hline(px + size - len, py + size - 1u, len, color);
    draw_vline(px + size - 1u, py + size - len, len, color);
}

static void draw_stone(unsigned int x, unsigned int y, int player)
{
    unsigned char edge;
    unsigned char fill;
    unsigned char sparkle;

    if (player == PLAYER_BLACK) {
        edge = COLOR_BLACK_EDGE;
        fill = COLOR_BLACK_STONE;
        sparkle = COLOR_PANEL;
    } else {
        edge = COLOR_WHITE_EDGE;
        fill = COLOR_WHITE_STONE;
        sparkle = COLOR_WHITE_SHADE;
    }

    fill_rect(x + 2u, y + 0u, 3u, 1u, edge);
    fill_rect(x + 1u, y + 1u, 5u, 1u, edge);
    fill_rect(x + 0u, y + 2u, 7u, 3u, edge);
    fill_rect(x + 1u, y + 5u, 5u, 1u, edge);
    fill_rect(x + 2u, y + 6u, 3u, 1u, edge);

    fill_rect(x + 2u, y + 1u, 3u, 1u, fill);
    fill_rect(x + 1u, y + 2u, 5u, 3u, fill);
    fill_rect(x + 2u, y + 5u, 3u, 1u, fill);

    vga_fb_put_pixel(x + 2u, y + 2u, sparkle);
    vga_fb_put_pixel(x + 3u, y + 2u, sparkle);
    if (player == PLAYER_WHITE) {
        vga_fb_put_pixel(x + 4u, y + 4u, COLOR_SUBTEXT);
        vga_fb_put_pixel(x + 5u, y + 4u, COLOR_SUBTEXT);
    }
}

static int is_winning_cell(int row, int col)
{
    return win_marks[row][col] != 0u;
}

static void draw_board_cell(int row, int col)
{
    unsigned int px = GRID_X + ((unsigned int)col * CELL_SIZE);
    unsigned int py = GRID_Y + ((unsigned int)row * CELL_SIZE);
    int occupied = board[row][col];
    int is_cursor = (cursor_x == col) && (cursor_y == row) && (winner == 0) &&
                    !((game_mode == MODE_SINGLE_AI) && (current_player == PLAYER_WHITE));
    int is_last = (last_x == col) && (last_y == row);
    unsigned char cursor_color = (current_player == PLAYER_BLACK) ? COLOR_CURSOR_BLACK : COLOR_CURSOR_WHITE;

    fill_rect(px, py, CELL_SIZE, CELL_SIZE, COLOR_BOARD);

    draw_hline(px + 2u, py + GRID_CENTER, CELL_SIZE - 4u, COLOR_GRID);
    draw_vline(px + GRID_CENTER, py + 2u, CELL_SIZE - 4u, COLOR_GRID);

    if (is_star_point(row, col) && occupied == 0) {
        fill_rect(px + GRID_CENTER, py + GRID_CENTER, 1u, 1u, COLOR_FRAME);
    }

    if (occupied != 0) {
        draw_stone(px + 1u, py + 1u, occupied);
    }

    if (is_last) {
        fill_rect(px + CELL_SIZE - 3u, py + 1u, 2u, 2u, COLOR_LAST);
    }

    if (is_winning_cell(row, col)) {
        draw_corner_marks(px + 1u, py + 1u, CELL_SIZE - 2u, 2u, COLOR_WIN);
    }

    if (is_cursor) {
        draw_corner_marks(px, py, CELL_SIZE, 3u, cursor_color);
        if (occupied == 0) {
            fill_rect(px + 3u, py + 3u, 3u, 3u, cursor_color);
        }
    }
}

static int mark_winning_line(int x, int y, int dx, int dy, int player)
{
    int sx = x;
    int sy = y;
    int ex = x;
    int ey = y;
    int count = 1;
    int step;

    while (in_bounds(sx - dx, sy - dy) && board[sy - dy][sx - dx] == player) {
        sx -= dx;
        sy -= dy;
        count++;
    }

    while (in_bounds(ex + dx, ey + dy) && board[ey + dy][ex + dx] == player) {
        ex += dx;
        ey += dy;
        count++;
    }

    if (count < GOMOKU_WIN_LEN) {
        return 0;
    }

    clear_win_marks();
    for (step = 0; ; step++) {
        int mx = sx + (step * dx);
        int my = sy + (step * dy);
        win_marks[my][mx] = 1u;
        if (mx == ex && my == ey) {
            break;
        }
    }

    return 1;
}

static int check_win_from(int x, int y, int player)
{
    if (mark_winning_line(x, y, 1, 0, player)) {
        return 1;
    }
    if (mark_winning_line(x, y, 0, 1, player)) {
        return 1;
    }
    if (mark_winning_line(x, y, 1, 1, player)) {
        return 1;
    }
    if (mark_winning_line(x, y, 1, -1, player)) {
        return 1;
    }
    return 0;
}

static int max_line_after_place(int x, int y, int player)
{
    static const int dir_table[4][2] = {
        {1, 0},
        {0, 1},
        {1, 1},
        {1, -1}
    };
    int dir;
    int best = 1;

    for (dir = 0; dir < 4; dir++) {
        int dx = dir_table[dir][0];
        int dy = dir_table[dir][1];
        int count = 1;
        int sx = x - dx;
        int sy = y - dy;
        int ex = x + dx;
        int ey = y + dy;

        while (in_bounds(sx, sy) && board[sy][sx] == player) {
            count++;
            sx -= dx;
            sy -= dy;
        }
        while (in_bounds(ex, ey) && board[ey][ex] == player) {
            count++;
            ex += dx;
            ey += dy;
        }
        if (count > best) {
            best = count;
        }
    }

    return best;
}

static unsigned int line_pattern_score(unsigned int stones, unsigned int open_ends)
{
    if (stones >= 5u) {
        return 100000u;
    }
    if (stones == 4u) {
        return (open_ends == 2u) ? 20000u : 7000u;
    }
    if (stones == 3u) {
        return (open_ends == 2u) ? 2500u : 500u;
    }
    if (stones == 2u) {
        return (open_ends == 2u) ? 250u : 60u;
    }
    if (stones == 1u) {
        return (open_ends == 2u) ? 25u : 8u;
    }
    return 0u;
}

static unsigned int evaluate_cell_for_player(int x, int y, int player)
{
    static const int dir_table[4][2] = {
        {1, 0},
        {0, 1},
        {1, 1},
        {1, -1}
    };
    unsigned int total = 0u;
    int dir;

    for (dir = 0; dir < 4; dir++) {
        int dx = dir_table[dir][0];
        int dy = dir_table[dir][1];
        unsigned int left = 0u;
        unsigned int right = 0u;
        unsigned int open_ends = 0u;
        int cx;
        int cy;

        cx = x - dx;
        cy = y - dy;
        while (in_bounds(cx, cy) && board[cy][cx] == player) {
            left++;
            cx -= dx;
            cy -= dy;
        }
        if (in_bounds(cx, cy) && board[cy][cx] == 0u) {
            open_ends++;
        }

        cx = x + dx;
        cy = y + dy;
        while (in_bounds(cx, cy) && board[cy][cx] == player) {
            right++;
            cx += dx;
            cy += dy;
        }
        if (in_bounds(cx, cy) && board[cy][cx] == 0u) {
            open_ends++;
        }

        total += line_pattern_score(1u + left + right, open_ends);
    }

    total += 24u;
    total += (8u - abs_diff_u((unsigned int)x, (unsigned int)(GOMOKU_SIZE / 2))) * 2u;
    total += (8u - abs_diff_u((unsigned int)y, (unsigned int)(GOMOKU_SIZE / 2))) * 2u;
    return total;
}

static void apply_move_at(int x, int y, int player)
{
    note_code = NOTE_NONE;
    board[y][x] = (unsigned char)player;
    last_x = x;
    last_y = y;
    move_count++;

    if (check_win_from(x, y, player)) {
        winner = player;
        current_player = player;
    } else if (move_count == (GOMOKU_SIZE * GOMOKU_SIZE)) {
        clear_win_marks();
        winner = RESULT_DRAW;
    } else {
        current_player = (player == PLAYER_BLACK) ? PLAYER_WHITE : PLAYER_BLACK;
    }

    need_redraw = 1;
}

static void ai_choose_move(int *best_x, int *best_y)
{
    unsigned int best_score = 0u;
    int found = 0;
    int row;
    int col;

    *best_x = GOMOKU_SIZE / 2;
    *best_y = GOMOKU_SIZE / 2;

    for (row = 0; row < GOMOKU_SIZE; row++) {
        for (col = 0; col < GOMOKU_SIZE; col++) {
            if (board[row][col] != 0u) {
                continue;
            }
            if (max_line_after_place(col, row, PLAYER_WHITE) >= GOMOKU_WIN_LEN) {
                *best_x = col;
                *best_y = row;
                return;
            }
        }
    }

    for (row = 0; row < GOMOKU_SIZE; row++) {
        for (col = 0; col < GOMOKU_SIZE; col++) {
            if (board[row][col] != 0u) {
                continue;
            }
            if (max_line_after_place(col, row, PLAYER_BLACK) >= GOMOKU_WIN_LEN) {
                *best_x = col;
                *best_y = row;
                return;
            }
        }
    }

    for (row = 0; row < GOMOKU_SIZE; row++) {
        for (col = 0; col < GOMOKU_SIZE; col++) {
            unsigned int score;
            unsigned int center_dist;

            if (board[row][col] != 0u) {
                continue;
            }

            score = evaluate_cell_for_player(col, row, PLAYER_WHITE) * 3u;
            score += evaluate_cell_for_player(col, row, PLAYER_BLACK) * 2u;
            center_dist = abs_diff_u((unsigned int)col, (unsigned int)(GOMOKU_SIZE / 2)) +
                          abs_diff_u((unsigned int)row, (unsigned int)(GOMOKU_SIZE / 2));
            score += (12u - center_dist);

            if (!found || score > best_score) {
                best_score = score;
                *best_x = col;
                *best_y = row;
                found = 1;
            } else if (score == best_score) {
                unsigned int best_dist = abs_diff_u((unsigned int)(*best_x), (unsigned int)(GOMOKU_SIZE / 2)) +
                                         abs_diff_u((unsigned int)(*best_y), (unsigned int)(GOMOKU_SIZE / 2));
                if (center_dist < best_dist) {
                    *best_x = col;
                    *best_y = row;
                }
            }
        }
    }
}

static void ai_take_turn(void)
{
    int best_x;
    int best_y;

    if (winner != 0 || game_mode != MODE_SINGLE_AI || current_player != PLAYER_WHITE) {
        return;
    }

    ai_choose_move(&best_x, &best_y);
    apply_move_at(best_x, best_y, PLAYER_WHITE);
}

static const char *mode_text(void)
{
    return (game_mode == MODE_SINGLE_AI) ? "1P-AI" : "2P-DUAL";
}

static const char *turn_text(void)
{
    if (game_mode == MODE_SINGLE_AI && current_player == PLAYER_WHITE) {
        return "AI";
    }
    if (current_player == PLAYER_BLACK) {
        return "P1";
    }
    return "P2";
}

static const char *state_text(void)
{
    if (note_code == NOTE_USED) {
        return "USED";
    }
    if (winner == PLAYER_BLACK) {
        return "P1 WIN";
    }
    if (winner == PLAYER_WHITE) {
        return (game_mode == MODE_SINGLE_AI) ? "AI WIN" : "P2 WIN";
    }
    if (winner == RESULT_DRAW) {
        return "DRAW";
    }
    return "READY";
}

static const char *overlay_text(void)
{
    if (winner == PLAYER_BLACK) {
        return "P1 WINS";
    }
    if (winner == PLAYER_WHITE) {
        return (game_mode == MODE_SINGLE_AI) ? "AI WINS" : "P2 WINS";
    }
    if (winner == RESULT_DRAW) {
        return "DRAW";
    }
    return "";
}

static const char *overlay_hint_text(void)
{
    if (quit_arm_polls != 0u) {
        return "PRESS Q AGAIN";
    }
    return "R AGAIN   M MENU";
}

static void draw_title_bar(int show_badge)
{
    fill_rect(TITLE_X + 1u, TITLE_Y + 1u, TITLE_W - 2u, TITLE_H - 2u, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    draw_text_centered(TITLE_X, TITLE_Y + 4u, TITLE_W, "GOMOKU", 2u, COLOR_TEXT);

    if (show_badge) {
        draw_frame(TITLE_BADGE_X, TITLE_BADGE_Y, TITLE_BADGE_W, TITLE_BADGE_H, COLOR_SUBTEXT, COLOR_CARD);
        draw_text(TITLE_BADGE_X + 3u, TITLE_BADGE_Y + 2u, "MV", 1u, COLOR_LABEL);
        draw_uint(TITLE_BADGE_X + 13u, TITLE_BADGE_Y + 2u, 1u, move_count, COLOR_TEXT);
    }
}

static void draw_game_background(void)
{
    unsigned int idx;

    vga_fb_clear(COLOR_BG);

    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(BOARD_PANEL_X, BOARD_PANEL_Y, BOARD_PANEL_W, BOARD_PANEL_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(GRID_X - 4u, GRID_Y - 4u, GRID_W + 8u, GRID_H + 8u, COLOR_FRAME, COLOR_ACCENT);
    fill_rect(GRID_X - 2u, GRID_Y - 2u, GRID_W + 4u, GRID_H + 4u, COLOR_BOARD);
    draw_hline(GRID_X - 2u, GRID_Y - 2u, GRID_W + 4u, COLOR_BOARD_SHADE);

    for (idx = 0u; idx < GOMOKU_SIZE; idx++) {
        draw_uint(GRID_X + (idx * CELL_SIZE) + 3u, GRID_Y - 8u, 1u, idx + 1u, COLOR_LABEL);
        draw_uint(GRID_X - 9u, GRID_Y + (idx * CELL_SIZE) + 2u, 1u, idx + 1u, COLOR_LABEL);
    }

    draw_frame(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(PANEL_X + 2u, PANEL_Y + 2u, PANEL_W - 4u, 2u, COLOR_ACCENT);

    draw_text_centered(PANEL_BOX_X, MODE_LABEL_Y, PANEL_BOX_W, "MODE", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, MODE_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_ACCENT, COLOR_CARD);

    draw_text_centered(PANEL_BOX_X, TURN_LABEL_Y, PANEL_BOX_W, "TURN", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, TURN_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_SUBTEXT, COLOR_CARD);

    draw_text_centered(PANEL_BOX_X, STATE_LABEL_Y, PANEL_BOX_W, "STATE", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, STATE_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_SUBTEXT, COLOR_CARD);

    draw_text_centered(PANEL_BOX_X, CURSOR_LABEL_Y, PANEL_BOX_W, "CURSOR", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, CURSOR_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_SUBTEXT, COLOR_CARD);

    draw_text_centered(PANEL_BOX_X, LAST_LABEL_Y, PANEL_BOX_W, "LAST", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, LAST_BOX_Y, PANEL_BOX_W, PANEL_BOX_H, COLOR_SUBTEXT, COLOR_CARD);

    draw_frame(FOOTER_X, FOOTER_Y, FOOTER_W, FOOTER_H, COLOR_FRAME, COLOR_PANEL);
    draw_text_centered(FOOTER_X, FOOTER_Y + 1u, FOOTER_W, "WASD CUR  SPC OK  R RESET  M MENU", 1u, COLOR_TEXT);

    scene_valid = 1;
}

static void render_board(void)
{
    int row;
    int col;

    for (row = 0; row < GOMOKU_SIZE; row++) {
        for (col = 0; col < GOMOKU_SIZE; col++) {
            draw_board_cell(row, col);
        }
    }
}

static void render_panel(void)
{
    fill_rect(PANEL_BOX_X + 1u, MODE_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);
    fill_rect(PANEL_BOX_X + 1u, TURN_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);
    fill_rect(PANEL_BOX_X + 1u, STATE_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);
    fill_rect(PANEL_BOX_X + 1u, CURSOR_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);
    fill_rect(PANEL_BOX_X + 1u, LAST_BOX_Y + 1u, PANEL_BOX_W - 2u, PANEL_BOX_H - 2u, COLOR_CARD);

    draw_text_centered(PANEL_BOX_X, MODE_BOX_Y + 2u, PANEL_BOX_W, mode_text(), 1u, COLOR_TEXT);

    draw_stone(PANEL_BOX_X + 4u, TURN_BOX_Y + 1u, current_player);
    draw_text(PANEL_BOX_X + 18u, TURN_BOX_Y + 2u, turn_text(), 1u, COLOR_TEXT);

    draw_text_centered(PANEL_BOX_X, STATE_BOX_Y + 2u, PANEL_BOX_W, state_text(), 1u, COLOR_TEXT);

    draw_text(PANEL_BOX_X + 3u, CURSOR_BOX_Y + 2u, "R", 1u, COLOR_LABEL);
    draw_uint(PANEL_BOX_X + 10u, CURSOR_BOX_Y + 2u, 1u, (unsigned int)(cursor_y + 1), COLOR_TEXT);
    draw_text(PANEL_BOX_X + 20u, CURSOR_BOX_Y + 2u, "C", 1u, COLOR_LABEL);
    draw_uint(PANEL_BOX_X + 27u, CURSOR_BOX_Y + 2u, 1u, (unsigned int)(cursor_x + 1), COLOR_TEXT);

    draw_text(PANEL_BOX_X + 3u, LAST_BOX_Y + 2u, "R", 1u, COLOR_LABEL);
    if (last_x >= 0 && last_y >= 0) {
        draw_uint(PANEL_BOX_X + 10u, LAST_BOX_Y + 2u, 1u, (unsigned int)(last_y + 1), COLOR_TEXT);
        draw_text(PANEL_BOX_X + 20u, LAST_BOX_Y + 2u, "C", 1u, COLOR_LABEL);
        draw_uint(PANEL_BOX_X + 27u, LAST_BOX_Y + 2u, 1u, (unsigned int)(last_x + 1), COLOR_TEXT);
    } else {
        draw_text(PANEL_BOX_X + 10u, LAST_BOX_Y + 2u, "-", 1u, COLOR_TEXT);
        draw_text(PANEL_BOX_X + 20u, LAST_BOX_Y + 2u, "C", 1u, COLOR_LABEL);
        draw_text(PANEL_BOX_X + 27u, LAST_BOX_Y + 2u, "-", 1u, COLOR_TEXT);
    }
}

static void render_overlay(void)
{
    if (winner == 0) {
        return;
    }

    draw_frame(OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H, COLOR_FRAME, COLOR_OVERLAY);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 4u, OVERLAY_W, overlay_text(), 1u, COLOR_TEXT);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 12u, OVERLAY_W, overlay_hint_text(), 1u, COLOR_LABEL);
}

static void render_game_footer(void)
{
    fill_rect(FOOTER_X + 1u, FOOTER_Y + 1u, FOOTER_W - 2u, FOOTER_H - 2u, COLOR_PANEL);
    if (quit_arm_polls != 0u) {
        draw_text_centered(FOOTER_X, FOOTER_Y + 1u, FOOTER_W, "PRESS Q AGAIN TO QUIT", 1u, COLOR_TEXT);
    } else {
        draw_text_centered(FOOTER_X, FOOTER_Y + 1u, FOOTER_W, "WASD CUR  SPC OK  R RESET  M MENU", 1u, COLOR_TEXT);
    }
}

static void render_game_scene(void)
{
    if (!scene_valid) {
        draw_game_background();
    }

    draw_title_bar(1);
    render_panel();
    render_board();
    render_overlay();
    render_game_footer();
}

static void draw_menu_option(unsigned int y, int selected,
                             const char *slot, const char *title, const char *detail, const char *tag)
{
    unsigned char frame_color = selected ? COLOR_ACCENT : COLOR_FRAME;
    unsigned char fill_color = selected ? COLOR_PANEL : COLOR_CARD;
    unsigned char bar_color = selected ? COLOR_ACCENT : COLOR_SUBTEXT;

    draw_frame(MENU_BOX_X, y, MENU_BOX_W, MENU_BOX_H, frame_color, fill_color);
    fill_rect(MENU_BOX_X + 2u, y + 2u, 4u, MENU_BOX_H - 4u, bar_color);
    draw_text(MENU_BOX_X + 10u, y + 3u, slot, 1u, selected ? COLOR_TEXT : COLOR_LABEL);
    draw_text(MENU_BOX_X + 20u, y + 3u, title, 1u, COLOR_TEXT);
    draw_text(MENU_BOX_X + 20u, y + 10u, detail, 1u, COLOR_LABEL);
    draw_frame(MENU_BOX_X + MENU_BOX_W - 24u, y + 3u, 16u, 8u, bar_color, COLOR_CARD);
    draw_text(MENU_BOX_X + MENU_BOX_W - 21u, y + 5u, tag, 1u, COLOR_TEXT);
}

static void render_menu_scene(void)
{
    vga_fb_clear(COLOR_BG);

    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    draw_title_bar(0);

    draw_frame(MENU_PANEL_X, MENU_PANEL_Y, MENU_PANEL_W, MENU_PANEL_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(MENU_PANEL_X + 2u, MENU_PANEL_Y + 2u, MENU_PANEL_W - 4u, 2u, COLOR_ACCENT);
    draw_text_centered(MENU_PANEL_X, MENU_PANEL_Y + 9u, MENU_PANEL_W, "SELECT MODE", 1u, COLOR_LABEL);

    draw_menu_option(MENU_BOX1_Y, menu_selection == MODE_SINGLE_AI, "1", "1P VS AI", "YOU BLACK", "AI");
    draw_menu_option(MENU_BOX2_Y, menu_selection == MODE_DUAL, "2", "2P DUAL", "LOCAL PLAY", "PVP");

    draw_frame(FOOTER_X, FOOTER_Y, FOOTER_W, FOOTER_H, COLOR_FRAME, COLOR_PANEL);
    if (quit_arm_polls != 0u) {
        draw_text_centered(FOOTER_X, FOOTER_Y + 1u, FOOTER_W, "PRESS Q AGAIN TO QUIT", 1u, COLOR_TEXT);
    } else {
        draw_text_centered(FOOTER_X, FOOTER_Y + 1u, FOOTER_W, "WS SELECT  SPC OK  N17 MENU", 1u, COLOR_TEXT);
    }
}

static void render_scene(void)
{
    if (screen_view == VIEW_MENU) {
        render_menu_scene();
    } else {
        render_game_scene();
    }
    need_redraw = 0;
}

static void move_cursor(int dx, int dy)
{
    int next_x = cursor_x + dx;
    int next_y = cursor_y + dy;

    if (next_x < 0) {
        next_x = 0;
    } else if (next_x >= GOMOKU_SIZE) {
        next_x = GOMOKU_SIZE - 1;
    }

    if (next_y < 0) {
        next_y = 0;
    } else if (next_y >= GOMOKU_SIZE) {
        next_y = GOMOKU_SIZE - 1;
    }

    if (next_x != cursor_x || next_y != cursor_y) {
        cursor_x = next_x;
        cursor_y = next_y;
        note_code = NOTE_NONE;
        need_redraw = 1;
    }
}

static void place_human_stone(void)
{
    if (winner != 0) {
        return;
    }

    if (board[cursor_y][cursor_x] != 0u) {
        note_code = NOTE_USED;
        need_redraw = 1;
        return;
    }

    apply_move_at(cursor_x, cursor_y, current_player);
    if (winner == 0 && game_mode == MODE_SINGLE_AI && current_player == PLAYER_WHITE) {
        ai_take_turn();
    }
}

static int handle_menu_input(int ch)
{
    if (swallow_lf && ch == '\n') {
        swallow_lf = 0;
        return 0;
    }
    swallow_lf = 0;

    ch = ui_to_lower(ch);

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
    if (ch == '1') {
        menu_selection = MODE_SINGLE_AI;
        start_selected_mode();
        return 0;
    }
    if (ch == '2') {
        menu_selection = MODE_DUAL;
        start_selected_mode();
        return 0;
    }
    if (ch == 'w' || ch == 'a') {
        if (menu_selection != MODE_SINGLE_AI) {
            menu_selection = MODE_SINGLE_AI;
            need_redraw = 1;
        }
        return 0;
    }
    if (ch == 's' || ch == 'd') {
        if (menu_selection != MODE_DUAL) {
            menu_selection = MODE_DUAL;
            need_redraw = 1;
        }
        return 0;
    }
    if (ch == '\n') {
        start_selected_mode();
        return 0;
    }
    if (ch == '\r') {
        swallow_lf = 1;
        start_selected_mode();
        return 0;
    }
    if (ch == ' ') {
        start_selected_mode();
        return 0;
    }
    return 0;
}

static int handle_game_input(int ch)
{
    if (swallow_lf && ch == '\n') {
        swallow_lf = 0;
        return 0;
    }
    swallow_lf = 0;

    ch = ui_to_lower(ch);

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
    if (ch == 'm') {
        return_to_menu();
        return 0;
    }
    if (ch == 'r') {
        scene_valid = 0;
        reset_game();
        return 0;
    }
    if (ch == '\n') {
        place_human_stone();
        return 0;
    }
    if (ch == '\r') {
        swallow_lf = 1;
        place_human_stone();
        return 0;
    }
    if (ch == ' ') {
        place_human_stone();
        return 0;
    }
    if (winner != 0) {
        return 0;
    }

    switch (ch) {
    case 'w':
        move_cursor(0, -1);
        break;
    case 'a':
        move_cursor(-1, 0);
        break;
    case 's':
        move_cursor(0, 1);
        break;
    case 'd':
        move_cursor(1, 0);
        break;
    default:
        break;
    }

    return 0;
}

int main(void)
{
    ui_clear_screen();
    ui_puts("VGA Gomoku demo (9x9, 160x120 framebuffer)\n");
    ui_puts("Menu: w/s select, space or Enter confirm, BTNC launcher menu. Game: w/a/s/d move, space or Enter place, r restart, m mode menu, BTNC launcher menu.\n");

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();

    screen_view = VIEW_MENU;
    game_mode = MODE_SINGLE_AI;
    menu_selection = MODE_SINGLE_AI;
    scene_valid = 0;
    need_redraw = 1;
    swallow_lf = 0;
    reset_game();
    return_to_menu();

    while (1) {
        int ch = ui_read_byte_nonblocking();

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        if (ui_launcher_menu_requested()) {
            launcher_button_return();
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
            if ((screen_view == VIEW_MENU ? handle_menu_input(ch) : handle_game_input(ch)) < 0) {
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
