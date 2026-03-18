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
#define FIELD_PANEL_W 96u
#define FIELD_PANEL_H 82u
#define FIELD_X 11u
#define FIELD_Y 23u

#define SIDE_X 106u
#define SIDE_Y 18u
#define SIDE_W 50u
#define SIDE_H 82u

#define FOOTER_X 4u
#define FOOTER_Y 104u
#define FOOTER_W 152u
#define FOOTER_H 12u

#define OVERLAY_X 26u
#define OVERLAY_Y 38u
#define OVERLAY_W 108u
#define OVERLAY_H 40u

#define BOARD_W 11
#define BOARD_H 9
#define CELL_SHIFT 3
#define CELL_PIXELS 8u
#define FIELD_W (BOARD_W * CELL_PIXELS)
#define FIELD_H (BOARD_H * CELL_PIXELS)

#define MAX_ENEMIES 3

#define TILE_FLOOR 0
#define TILE_WALL 1
#define TILE_CRATE 2

#define MODE_PLAY 0
#define MODE_WIN 1
#define MODE_LOSE 2

#define DIR_UP 0
#define DIR_RIGHT 1
#define DIR_DOWN 2
#define DIR_LEFT 3

#define BOMB_FUSE_TICKS 24u
#define BLAST_TICKS 5u
#define BLAST_RANGE 2
#define ENEMY_STEP_TICKS 12u
#define GAME_STEP_DIV 4u
#define POLL_SPIN 2200u

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 6u
#define COLOR_TEXT 7u
#define COLOR_LABEL 14u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_SHADOW 8u
#define COLOR_ACCENT 2u
#define COLOR_FIELD_BG 0u
#define COLOR_FLOOR 9u
#define COLOR_FLOOR_DOT 8u
#define COLOR_WALL 11u
#define COLOR_WALL_EDGE 8u
#define COLOR_CRATE 4u
#define COLOR_CRATE_EDGE 1u
#define COLOR_PLAYER 6u
#define COLOR_PLAYER_FACE 15u
#define COLOR_ENEMY 1u
#define COLOR_ENEMY_FACE 15u
#define COLOR_BOMB 0u
#define COLOR_FUSE 1u
#define COLOR_BLAST_EDGE 3u
#define COLOR_BLAST_CORE 15u
#define COLOR_OVERLAY 12u

static unsigned char tile_map[BOARD_H][BOARD_W];
static unsigned char blast_map[BOARD_H][BOARD_W];
static unsigned char enemy_alive[MAX_ENEMIES];
static unsigned char enemy_dir[MAX_ENEMIES];
static unsigned char shown_field[BOARD_H][BOARD_W];
static int enemy_x[MAX_ENEMIES];
static int enemy_y[MAX_ENEMIES];

static int player_x;
static int player_y;
static int bomb_active;
static int bomb_x;
static int bomb_y;
static unsigned int bomb_timer;
static unsigned int enemy_step_tick;
static unsigned int tick_divider;
static unsigned int round_no;
static unsigned int rng_state = 0x42A5C89Du;
static int mode = MODE_PLAY;
static int scene_valid = 0;
static int need_redraw = 1;
static int chrome_redraw = 1;
static int swallow_lf = 0;

static void invalidate_field_cache(void)
{
    int row;
    int col;

    for (row = 0; row < BOARD_H; row++) {
        for (col = 0; col < BOARD_W; col++) {
            shown_field[row][col] = 0xFFu;
        }
    }
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

static unsigned int alive_enemy_count(void)
{
    unsigned int count = 0u;
    unsigned int i;

    for (i = 0u; i < MAX_ENEMIES; i++) {
        if (enemy_alive[i] != 0u) {
            count++;
        }
    }
    return count;
}

static void rng_mix(unsigned int mix)
{
    rng_state ^= mix + 0x9E3779B9u + round_no;
    rng_state ^= rng_state << 7;
    rng_state ^= rng_state >> 9;
    rng_state ^= rng_state << 8;
    if (rng_state == 0u) {
        rng_state = 0xA341316Cu;
    }
}

static unsigned int rng_next(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    if (rng_state == 0u) {
        rng_state = 0x41C64E6Du;
    }
    return rng_state;
}

static int in_bounds(int x, int y)
{
    return (x >= 0) && (x < BOARD_W) && (y >= 0) && (y < BOARD_H);
}

static int is_spawn_protected(int x, int y)
{
    if (x <= 2 && y <= 2) {
        return 1;
    }
    if (x >= (BOARD_W - 3) && y <= 2) {
        return 1;
    }
    if (x <= 2 && y >= (BOARD_H - 3)) {
        return 1;
    }
    if (x >= (BOARD_W - 3) && y >= (BOARD_H - 3)) {
        return 1;
    }
    return 0;
}

static void clear_maps(void)
{
    int row;
    int col;

    for (row = 0; row < BOARD_H; row++) {
        for (col = 0; col < BOARD_W; col++) {
            tile_map[row][col] = TILE_FLOOR;
            blast_map[row][col] = 0u;
        }
    }
    invalidate_field_cache();
}

static void spawn_enemies(void)
{
    enemy_x[0] = BOARD_W - 2;
    enemy_y[0] = BOARD_H - 2;
    enemy_x[1] = BOARD_W - 2;
    enemy_y[1] = 1;
    enemy_x[2] = 1;
    enemy_y[2] = BOARD_H - 2;

    enemy_alive[0] = 1u;
    enemy_alive[1] = 1u;
    enemy_alive[2] = 1u;

    enemy_dir[0] = DIR_LEFT;
    enemy_dir[1] = DIR_DOWN;
    enemy_dir[2] = DIR_RIGHT;
}

static void generate_field(void)
{
    int row;
    int col;

    clear_maps();

    for (row = 0; row < BOARD_H; row++) {
        for (col = 0; col < BOARD_W; col++) {
            if (row == 0 || row == (BOARD_H - 1) || col == 0 || col == (BOARD_W - 1)) {
                tile_map[row][col] = TILE_WALL;
            } else if (((row & 1) != 0) && ((col & 1) != 0)) {
                tile_map[row][col] = TILE_WALL;
            } else {
                tile_map[row][col] = TILE_FLOOR;
            }
        }
    }

    rng_mix(0x5A1Du + round_no);
    for (row = 1; row < (BOARD_H - 1); row++) {
        for (col = 1; col < (BOARD_W - 1); col++) {
            if (tile_map[row][col] != TILE_FLOOR || is_spawn_protected(col, row)) {
                continue;
            }
            if ((rng_next() & 3u) <= 1u) {
                tile_map[row][col] = TILE_CRATE;
            }
        }
    }

    tile_map[1][1] = TILE_FLOOR;
    tile_map[1][2] = TILE_FLOOR;
    tile_map[2][1] = TILE_FLOOR;

    tile_map[1][BOARD_W - 2] = TILE_FLOOR;
    tile_map[1][BOARD_W - 3] = TILE_FLOOR;
    tile_map[2][BOARD_W - 2] = TILE_FLOOR;

    tile_map[BOARD_H - 2][1] = TILE_FLOOR;
    tile_map[BOARD_H - 2][2] = TILE_FLOOR;
    tile_map[BOARD_H - 3][1] = TILE_FLOOR;

    tile_map[BOARD_H - 2][BOARD_W - 2] = TILE_FLOOR;
    tile_map[BOARD_H - 2][BOARD_W - 3] = TILE_FLOOR;
    tile_map[BOARD_H - 3][BOARD_W - 2] = TILE_FLOOR;

    player_x = 1;
    player_y = 1;
    spawn_enemies();
    bomb_active = 0;
    bomb_x = -1;
    bomb_y = -1;
    bomb_timer = 0u;
}

static void mark_mode(int next_mode)
{
    mode = next_mode;
    chrome_redraw = 1;
    need_redraw = 1;
}

static void start_round(void)
{
    round_no++;
    enemy_step_tick = 0u;
    tick_divider = 0u;
    swallow_lf = 0;
    generate_field();
    spawn_enemies();
    bomb_active = 0;
    bomb_x = -1;
    bomb_y = -1;
    bomb_timer = 0u;
    mode = MODE_PLAY;
    chrome_redraw = 1;
    need_redraw = 1;
    scene_valid = 0;
    mark_mode(MODE_PLAY);
}

static int bomb_at(int x, int y)
{
    return bomb_active && bomb_x == x && bomb_y == y;
}

static int enemy_at(int x, int y, int skip)
{
    int i;

    for (i = 0; i < MAX_ENEMIES; i++) {
        if (i == skip || enemy_alive[i] == 0u) {
            continue;
        }
        if (enemy_x[i] == x && enemy_y[i] == y) {
            return 1;
        }
    }
    return 0;
}

static void kill_enemy_at(int x, int y)
{
    int i;

    for (i = 0; i < MAX_ENEMIES; i++) {
        if (enemy_alive[i] != 0u && enemy_x[i] == x && enemy_y[i] == y) {
            enemy_alive[i] = 0u;
            chrome_redraw = 1;
            need_redraw = 1;
        }
    }
}

static void mark_blast_cell(int x, int y)
{
    if (!in_bounds(x, y)) {
        return;
    }

    blast_map[y][x] = (unsigned char)BLAST_TICKS;
    if (player_x == x && player_y == y) {
        mark_mode(MODE_LOSE);
    }
    kill_enemy_at(x, y);
}

static void detonate_bomb(void)
{
    static const int dir_table[4][2] = {
        {0, -1},
        {1, 0},
        {0, 1},
        {-1, 0}
    };
    int dir;

    if (!bomb_active) {
        return;
    }

    bomb_active = 0;
    mark_blast_cell(bomb_x, bomb_y);

    for (dir = 0; dir < 4; dir++) {
        int x = bomb_x;
        int y = bomb_y;
        unsigned int step;

        for (step = 0u; step < BLAST_RANGE; step++) {
            x += dir_table[dir][0];
            y += dir_table[dir][1];

            if (!in_bounds(x, y) || tile_map[y][x] == TILE_WALL) {
                break;
            }

            mark_blast_cell(x, y);
            if (tile_map[y][x] == TILE_CRATE) {
                tile_map[y][x] = TILE_FLOOR;
                break;
            }
        }
    }

    chrome_redraw = 1;
    need_redraw = 1;
}

static int decay_blasts(void)
{
    int row;
    int col;
    int changed = 0;

    for (row = 0; row < BOARD_H; row++) {
        for (col = 0; col < BOARD_W; col++) {
            if (blast_map[row][col] != 0u) {
                blast_map[row][col]--;
                changed = 1;
            }
        }
    }
    return changed;
}

static void apply_blast_damage(void)
{
    int row;
    int col;

    for (row = 0; row < BOARD_H; row++) {
        for (col = 0; col < BOARD_W; col++) {
            if (blast_map[row][col] == 0u) {
                continue;
            }
            if (player_x == col && player_y == row) {
                mark_mode(MODE_LOSE);
            }
            kill_enemy_at(col, row);
        }
    }
}

static int enemy_can_move_to(int x, int y, int skip)
{
    if (!in_bounds(x, y) || tile_map[y][x] != TILE_FLOOR || bomb_at(x, y) || enemy_at(x, y, skip)) {
        return 0;
    }
    return 1;
}

static int dir_dx(int dir)
{
    if (dir == DIR_RIGHT) {
        return 1;
    }
    if (dir == DIR_LEFT) {
        return -1;
    }
    return 0;
}

static int dir_dy(int dir)
{
    if (dir == DIR_DOWN) {
        return 1;
    }
    if (dir == DIR_UP) {
        return -1;
    }
    return 0;
}

static int step_enemy(int idx)
{
    unsigned int base;
    int attempt;
    int stay_dir;
    int old_x;
    int old_y;

    if (enemy_alive[idx] == 0u) {
        return 0;
    }

    if (blast_map[enemy_y[idx]][enemy_x[idx]] != 0u) {
        enemy_alive[idx] = 0u;
        chrome_redraw = 1;
        need_redraw = 1;
        return 1;
    }

    base = rng_next() & 3u;
    stay_dir = enemy_dir[idx];
    old_x = enemy_x[idx];
    old_y = enemy_y[idx];

    for (attempt = 0; attempt < 5; attempt++) {
        int dir = (attempt == 0) ? stay_dir : (int)((base + (unsigned int)(attempt - 1)) & 3u);
        int next_x = enemy_x[idx] + dir_dx(dir);
        int next_y = enemy_y[idx] + dir_dy(dir);

        if (!enemy_can_move_to(next_x, next_y, idx)) {
            continue;
        }

        enemy_x[idx] = next_x;
        enemy_y[idx] = next_y;
        enemy_dir[idx] = (unsigned char)dir;
        break;
    }

    if (enemy_x[idx] == player_x && enemy_y[idx] == player_y) {
        mark_mode(MODE_LOSE);
    }
    return (enemy_x[idx] != old_x) || (enemy_y[idx] != old_y);
}

static int step_enemies(void)
{
    int idx;
    int changed = 0;

    for (idx = 0; idx < MAX_ENEMIES; idx++) {
        if (step_enemy(idx)) {
            changed = 1;
        }
    }
    return changed;
}

static void check_end_state(void)
{
    if (mode == MODE_PLAY && alive_enemy_count() == 0u) {
        mark_mode(MODE_WIN);
    }
}

static void step_world(void)
{
    int visual_changed = 0;

    if (mode != MODE_PLAY) {
        return;
    }

    if (bomb_active) {
        if (bomb_timer != 0u) {
            bomb_timer--;
            chrome_redraw = 1;
            visual_changed = 1;
        }
        if (bomb_timer == 0u) {
            detonate_bomb();
            visual_changed = 1;
        }
    }

    apply_blast_damage();

    enemy_step_tick++;
    if (enemy_step_tick >= ENEMY_STEP_TICKS) {
        enemy_step_tick = 0u;
        if (step_enemies()) {
            visual_changed = 1;
        }
    }

    apply_blast_damage();
    check_end_state();
    if (decay_blasts()) {
        visual_changed = 1;
    }
    if (visual_changed) {
        need_redraw = 1;
    }
}

static int player_can_move_to(int x, int y)
{
    if (!in_bounds(x, y) || tile_map[y][x] != TILE_FLOOR || bomb_at(x, y) || enemy_at(x, y, -1)) {
        return 0;
    }
    return 1;
}

static void try_move_player(int dx, int dy)
{
    int next_x;
    int next_y;

    if (mode != MODE_PLAY) {
        return;
    }

    next_x = player_x + dx;
    next_y = player_y + dy;
    if (!player_can_move_to(next_x, next_y)) {
        return;
    }

    player_x = next_x;
    player_y = next_y;
    if (blast_map[player_y][player_x] != 0u) {
        mark_mode(MODE_LOSE);
    } else {
        need_redraw = 1;
    }
}

static void place_bomb(void)
{
    if (mode != MODE_PLAY || bomb_active) {
        return;
    }

    bomb_active = 1;
    bomb_x = player_x;
    bomb_y = player_y;
    bomb_timer = BOMB_FUSE_TICKS;
    chrome_redraw = 1;
    need_redraw = 1;
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
    fill_rect(px, py, 1u, CELL_PIXELS, COLOR_WALL_EDGE);
    fill_rect(px + 2u, py + 2u, 4u, 4u, COLOR_PANEL);
}

static void draw_crate(unsigned int px, unsigned int py)
{
    fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, COLOR_CRATE);
    fill_rect(px, py, CELL_PIXELS, 1u, COLOR_CRATE_EDGE);
    fill_rect(px, py + CELL_PIXELS - 1u, CELL_PIXELS, 1u, COLOR_CRATE_EDGE);
    fill_rect(px + 1u, py + 2u, CELL_PIXELS - 2u, 1u, COLOR_CRATE_EDGE);
    fill_rect(px + 1u, py + 5u, CELL_PIXELS - 2u, 1u, COLOR_CRATE_EDGE);
    fill_rect(px + 3u, py + 1u, 1u, CELL_PIXELS - 2u, COLOR_CRATE_EDGE);
}

static void draw_player(unsigned int px, unsigned int py)
{
    fill_rect(px + 1u, py + 1u, 6u, 6u, COLOR_PLAYER);
    fill_rect(px + 2u, py + 2u, 4u, 4u, COLOR_PANEL);
    vga_fb_put_pixel(px + 2u, py + 2u, COLOR_PLAYER_FACE);
    vga_fb_put_pixel(px + 5u, py + 2u, COLOR_PLAYER_FACE);
    fill_rect(px + 3u, py + 5u, 2u, 1u, COLOR_PLAYER_FACE);
}

static void draw_enemy(unsigned int px, unsigned int py)
{
    fill_rect(px + 1u, py + 1u, 6u, 5u, COLOR_ENEMY);
    fill_rect(px + 2u, py + 5u, 1u, 2u, COLOR_ENEMY);
    fill_rect(px + 5u, py + 5u, 1u, 2u, COLOR_ENEMY);
    vga_fb_put_pixel(px + 2u, py + 2u, COLOR_ENEMY_FACE);
    vga_fb_put_pixel(px + 5u, py + 2u, COLOR_ENEMY_FACE);
    fill_rect(px + 3u, py + 4u, 2u, 1u, COLOR_ENEMY_FACE);
}

static void draw_bomb(unsigned int px, unsigned int py)
{
    fill_rect(px + 2u, py + 2u, 4u, 4u, COLOR_BOMB);
    fill_rect(px + 3u, py + 1u, 2u, 1u, COLOR_FUSE);
    vga_fb_put_pixel(px + 5u, py + 1u, COLOR_FUSE);
    vga_fb_put_pixel(px + 6u, py + 0u, COLOR_FUSE);
}

static void draw_blast(unsigned int px, unsigned int py)
{
    fill_rect(px + 3u, py + 0u, 2u, 8u, COLOR_BLAST_EDGE);
    fill_rect(px + 0u, py + 3u, 8u, 2u, COLOR_BLAST_EDGE);
    fill_rect(px + 2u, py + 2u, 4u, 4u, COLOR_BLAST_CORE);
}

static unsigned char cell_visual_code(int row, int col)
{
    unsigned char visual = tile_map[row][col];
    int i;

    visual = (unsigned char)(visual & 0x3u);
    if (blast_map[row][col] != 0u) {
        visual = (unsigned char)(visual | 0x04u);
    } else if (bomb_at(col, row)) {
        visual = (unsigned char)(visual | 0x08u);
    }

    for (i = 0; i < MAX_ENEMIES; i++) {
        if (enemy_alive[i] != 0u && enemy_x[i] == col && enemy_y[i] == row) {
            visual = (unsigned char)(visual | 0x10u);
        }
    }

    if (player_x == col && player_y == row) {
        visual = (unsigned char)(visual | 0x20u);
    }

    return visual;
}

static void draw_field_cell(int row, int col)
{
    unsigned int px = FIELD_X + ((unsigned int)col << CELL_SHIFT);
    unsigned int py = FIELD_Y + ((unsigned int)row << CELL_SHIFT);
    int i;

    if (tile_map[row][col] == TILE_WALL) {
        draw_wall(px, py);
    } else if (tile_map[row][col] == TILE_CRATE) {
        draw_crate(px, py);
    } else {
        draw_floor(px, py);
    }

    if (blast_map[row][col] != 0u) {
        draw_blast(px, py);
    } else if (bomb_at(col, row)) {
        draw_bomb(px, py);
    }

    for (i = 0; i < MAX_ENEMIES; i++) {
        if (enemy_alive[i] != 0u && enemy_x[i] == col && enemy_y[i] == row) {
            draw_enemy(px, py);
        }
    }

    if (player_x == col && player_y == row) {
        draw_player(px, py);
    }
}

static const char *state_text(void)
{
    if (mode == MODE_WIN) {
        return "CLEAR";
    }
    if (mode == MODE_LOSE) {
        return "DANGER";
    }
    if (bomb_active) {
        return "HOT";
    }
    return "READY";
}

static const char *overlay_title(void)
{
    return (mode == MODE_WIN) ? "YOU WIN" : "TRY AGAIN";
}

static const char *overlay_hint(void)
{
    return (mode == MODE_WIN) ? "R NEXT  QQ MENU" : "R RETRY  QQ MENU";
}

static void draw_static_scene(void)
{
    vga_fb_clear(COLOR_BG);
    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FIELD_PANEL_X, FIELD_PANEL_Y, FIELD_PANEL_W, FIELD_PANEL_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FIELD_X - 3u, FIELD_Y - 3u, FIELD_W + 6u, FIELD_H + 6u, COLOR_FRAME, COLOR_ACCENT);
    fill_rect(FIELD_X - 1u, FIELD_Y - 1u, FIELD_W + 2u, FIELD_H + 2u, COLOR_FIELD_BG);
    draw_frame(SIDE_X, SIDE_Y, SIDE_W, SIDE_H, COLOR_FRAME, COLOR_PANEL);
    draw_frame(FOOTER_X, FOOTER_Y, FOOTER_W, FOOTER_H, COLOR_FRAME, COLOR_PANEL);
    draw_text_centered(FOOTER_X, FOOTER_Y + 3u, FOOTER_W, "WASD MOVE  SPC BOMB  R RESET  QQ MENU", 1u, COLOR_TEXT);
    scene_valid = 1;
}

static void render_title(void)
{
    fill_rect(TITLE_X + 1u, TITLE_Y + 1u, TITLE_W - 2u, TITLE_H - 2u, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    draw_text_centered(TITLE_X, TITLE_Y + 3u, TITLE_W, "BOMBER LITE", 2u, COLOR_TEXT);
}

static void render_field(int force_full)
{
    int row;
    int col;

    if (force_full) {
        fill_rect(FIELD_X, FIELD_Y, FIELD_W, FIELD_H, COLOR_FIELD_BG);
        invalidate_field_cache();
    }

    for (row = 0; row < BOARD_H; row++) {
        for (col = 0; col < BOARD_W; col++) {
            unsigned char visual = cell_visual_code(row, col);
            if (shown_field[row][col] != visual) {
                draw_field_cell(row, col);
                shown_field[row][col] = visual;
            }
        }
    }
}

static void render_side_panel(int force_full)
{
    if (!force_full && !chrome_redraw) {
        return;
    }

    fill_rect(SIDE_X + 1u, SIDE_Y + 1u, SIDE_W - 2u, SIDE_H - 2u, COLOR_PANEL);
    fill_rect(SIDE_X + 2u, SIDE_Y + 2u, SIDE_W - 4u, 2u, COLOR_ACCENT);

    draw_text_centered(SIDE_X, SIDE_Y + 6u, SIDE_W, "ROUND", 1u, COLOR_LABEL);
    draw_frame(SIDE_X + 8u, SIDE_Y + 14u, 34u, 10u, COLOR_FRAME, COLOR_CARD);
    draw_uint(SIDE_X + 20u, SIDE_Y + 17u, 1u, round_no, COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 30u, SIDE_W, "ENEMY", 1u, COLOR_LABEL);
    draw_frame(SIDE_X + 8u, SIDE_Y + 38u, 34u, 10u, COLOR_FRAME, COLOR_CARD);
    draw_uint(SIDE_X + 20u, SIDE_Y + 41u, 1u, alive_enemy_count(), COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 54u, SIDE_W, "BOMB", 1u, COLOR_LABEL);
    draw_frame(SIDE_X + 8u, SIDE_Y + 62u, 34u, 10u, COLOR_FRAME, COLOR_CARD);
    if (bomb_active) {
        draw_uint(SIDE_X + 16u, SIDE_Y + 65u, 1u, bomb_timer, COLOR_TEXT);
    } else {
        draw_text_centered(SIDE_X + 8u, SIDE_Y + 65u, 34u, "READY", 1u, COLOR_TEXT);
    }

    draw_text_centered(SIDE_X, SIDE_Y + 74u, SIDE_W, state_text(), 1u, COLOR_LABEL);
    chrome_redraw = 0;
}

static void render_overlay(void)
{
    if (mode == MODE_PLAY) {
        return;
    }

    draw_frame(OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H, COLOR_FRAME, COLOR_OVERLAY);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 10u, OVERLAY_W, overlay_title(), 1u, COLOR_TEXT);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 22u, OVERLAY_W, overlay_hint(), 1u, COLOR_LABEL);
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
        start_round();
        return 0;
    }
    if (ch == '\n') {
        return 0;
    }
    if (ch == '\r') {
        swallow_lf = 1;
        place_bomb();
        return 0;
    }
    if (ch == ' ') {
        place_bomb();
        return 0;
    }
    if (mode != MODE_PLAY) {
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
    ui_puts("VGA Bomber Lite (160x120 framebuffer)\n");
    ui_puts("Use UART: w/a/s/d move, space place bomb, r reset, q twice to quit.\n");
    ui_drain_input();

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();

    start_round();

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

        tick_divider++;
        if (tick_divider >= GAME_STEP_DIV) {
            tick_divider = 0u;
            step_world();
        }

        ui_short_pause(POLL_SPIN);
    }

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_present();
    return 0;
}
