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

#define FIELD_PANEL_X 4u
#define FIELD_PANEL_Y 17u
#define FIELD_PANEL_W 106u
#define FIELD_PANEL_H 90u
#define FIELD_X 8u
#define FIELD_Y 20u

#define SIDE_X 112u
#define SIDE_Y 17u
#define SIDE_W 44u
#define SIDE_H 90u

#define FOOTER_X 4u
#define FOOTER_Y 109u
#define FOOTER_W 152u
#define FOOTER_H 10u

#define OVERLAY_X 24u
#define OVERLAY_Y 38u
#define OVERLAY_W 112u
#define OVERLAY_H 42u

#define BOARD_W 20
#define BOARD_H 16
#define MAX_GHOSTS 3
#define ROUND_COUNT 4u
#define CELL_PIXELS 5u
#define FIELD_W (BOARD_W * CELL_PIXELS)
#define FIELD_H (BOARD_H * CELL_PIXELS)
#define MAZE_VARIANT_COUNT 2u

#define TILE_FLOOR 0u
#define TILE_WALL 1u

#define PELLET_NONE 0u
#define PELLET_DOT 1u
#define PELLET_POWER 2u

#define MODE_READY 0
#define MODE_PLAY 1
#define MODE_CLEAR 2
#define MODE_LOSE 3
#define MODE_FINISH 4

#define DIR_UP 0
#define DIR_RIGHT 1
#define DIR_DOWN 2
#define DIR_LEFT 3

#define DOT_SCORE 10u
#define POWER_SCORE 50u
#define GHOST_SCORE 200u
#define START_LIVES 3u
#define GAME_STEP_DIV 5u
#define POLL_SPIN 2200u

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 6u
#define COLOR_TEXT 7u
#define COLOR_LABEL 14u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_ACCENT 3u
#define COLOR_OVERLAY 12u
#define COLOR_FIELD_BG 0u
#define COLOR_WALL 11u
#define COLOR_WALL_EDGE 6u
#define COLOR_DOT 15u
#define COLOR_POWER 3u
#define COLOR_POWER_RING 7u
#define COLOR_PLAYER 15u
#define COLOR_PLAYER_EDGE 3u
#define COLOR_EYE 0u
#define COLOR_GHOST_RED 1u
#define COLOR_GHOST_CYAN 6u
#define COLOR_GHOST_ORANGE 4u
#define COLOR_GHOST_GREEN 2u
#define COLOR_GHOST_FRIGHT 11u
#define COLOR_GHOST_FLASH 15u

static const char *const maze_rows_a[BOARD_H] = {
    "####################",
    "#o.....##.....o....#",
    "#.##..#..##..#..##.#",
    "#..................#",
    "#.####..##..####...#",
    "#..A.....B....C....#",
    "#.##..#..##..#..##.#",
    "#....####..####....#",
    "#.......P..........#",
    "#..##..######..##..#",
    "#..................#",
    "#.#..##....##..##.##",
    "#..................#",
    "#..##..######..##..#",
    "#o.....##.....o....#",
    "####################"
};

static const char *const maze_rows_b[BOARD_H] = {
    "####################",
    "#o.....##.....A...o#",
    "#.###..##..###..##.#",
    "#..................#",
    "#..##.######.##..B.#",
    "#..##....##....##..#",
    "#......#....#......#",
    "#.####.#.P..#.####.#",
    "#......#..C.#......#",
    "#..##....##....##..#",
    "#.##..######..##...#",
    "#..................#",
    "#.###..##..###..##.#",
    "#...##......##.....#",
    "#o.....##.....##..o#",
    "####################"
};

typedef struct {
    int x;
    int y;
    int spawn_x;
    int spawn_y;
    int dir;
    unsigned int release_timer;
} ghost_t;

static unsigned char base_map[BOARD_H][BOARD_W];
static unsigned char pellet_map[BOARD_H][BOARD_W];
static unsigned int shown_field[BOARD_H][BOARD_W];
static ghost_t ghosts[MAX_GHOSTS];

static int player_x;
static int player_y;
static int player_spawn_x;
static int player_spawn_y;
static int player_dir;
static int queued_dir;

static unsigned int lives = START_LIVES;
static unsigned int score = 0u;
static unsigned int best_score = 0u;
static unsigned int round_no = 1u;
static unsigned int pellets_left = 0u;
static unsigned int power_left = 0u;
static unsigned int frightened_timer = 0u;
static unsigned int player_tick = 0u;
static unsigned int ghost_tick = 0u;
static unsigned int tick_divider = 0u;
static unsigned int anim_tick = 0u;
static unsigned int player_anim_phase = 0u;
static unsigned int rng_state = 0x58D13C27u;
static unsigned int maze_variant = 0u;
static int mode = MODE_READY;
static int scene_valid = 0;
static int need_redraw = 1;
static int chrome_redraw = 1;
static int swallow_lf = 0;

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
    for (;;) {
    }
#endif
}
#endif

static void load_round(unsigned int next_round);

static const char *maze_row_for(unsigned int variant, int row)
{
    if ((variant & 1u) == 0u) {
        return maze_rows_a[row];
    }
    return maze_rows_b[row];
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

static void draw_uint(unsigned int x, unsigned int y, unsigned int scale,
                      unsigned int value, unsigned char color)
{
    char buffer[11];
    unsigned int out = 0u;
    unsigned int i;

    if (value == 0u) {
        buffer[out++] = '0';
    } else {
        while (value != 0u) {
            buffer[out++] = (char)('0' + (value % 10u));
            value /= 10u;
        }
        for (i = 0u; i < (out >> 1); i++) {
            char tmp = buffer[i];
            buffer[i] = buffer[out - 1u - i];
            buffer[out - 1u - i] = tmp;
        }
    }
    buffer[out] = '\0';
    draw_text(x, y, buffer, scale, color);
}

static unsigned int random_next(void)
{
    rng_state ^= (rng_state << 13);
    rng_state ^= (rng_state >> 17);
    rng_state ^= (rng_state << 5);
    return rng_state;
}

static unsigned int random_small(unsigned int limit)
{
    if (limit <= 1u) {
        return 0u;
    }
    return random_next() % limit;
}

static int abs_int(int value)
{
    return (value < 0) ? -value : value;
}

static int dir_dx(int dir)
{
    switch (dir) {
    case DIR_RIGHT: return 1;
    case DIR_LEFT: return -1;
    default: return 0;
    }
}

static int dir_dy(int dir)
{
    switch (dir) {
    case DIR_DOWN: return 1;
    case DIR_UP: return -1;
    default: return 0;
    }
}

static int reverse_dir(int dir)
{
    return (dir + 2) & 3;
}

static void invalidate_field_cache(void)
{
    int row;
    int col;

    for (row = 0; row < BOARD_H; row++) {
        for (col = 0; col < BOARD_W; col++) {
            shown_field[row][col] = 0xFFFFFFFFu;
        }
    }
}

static void mark_scene_dirty(void)
{
    scene_valid = 0;
    chrome_redraw = 1;
    need_redraw = 1;
    invalidate_field_cache();
}

static void mark_field_dirty(void)
{
    need_redraw = 1;
}

static void mark_chrome_dirty(void)
{
    chrome_redraw = 1;
    need_redraw = 1;
}

static unsigned int player_step_period(void)
{
    if (round_no >= 3u) {
        return 12u;
    }
    if (round_no == 2u) {
        return 13u;
    }
    return 14u;
}

static unsigned int ghost_step_period(void)
{
    unsigned int base = 42u;

    if (round_no > 1u) {
        unsigned int delta = round_no - 1u;
        if (delta > 2u) {
            delta = 2u;
        }
        base -= (delta << 1);
    }
    if (frightened_timer != 0u) {
        base += 8u;
    }
    return base;
}

static unsigned int fright_ticks_for_round(void)
{
    if (round_no >= 3u) {
        return 30u;
    }
    if (round_no == 2u) {
        return 36u;
    }
    return 42u;
}

static unsigned int mouth_phase(void)
{
    return player_anim_phase & 1u;
}

static unsigned int power_phase(void)
{
    return 0u;
}

static unsigned int fright_flash_phase(void)
{
    return 0u;
}

static unsigned char ghost_body_color(unsigned int ghost_index)
{
    switch (ghost_index) {
    case 0u: return COLOR_GHOST_RED;
    case 1u: return COLOR_GHOST_CYAN;
    case 2u: return COLOR_GHOST_ORANGE;
    default: return COLOR_GHOST_GREEN;
    }
}

static int in_bounds(int x, int y)
{
    return x >= 0 && x < BOARD_W && y >= 0 && y < BOARD_H;
}

static int tile_walkable(int x, int y)
{
    if (!in_bounds(x, y)) {
        return 0;
    }
    return base_map[y][x] != TILE_WALL;
}

static int ghost_index_at(int x, int y)
{
    unsigned int i;

    for (i = 0u; i < MAX_GHOSTS; i++) {
        if (ghosts[i].x == x && ghosts[i].y == y) {
            return (int)i;
        }
    }
    return -1;
}

static int ghost_index_at_except(int x, int y, unsigned int skip)
{
    unsigned int i;

    for (i = 0u; i < MAX_GHOSTS; i++) {
        if (i == skip) {
            continue;
        }
        if (ghosts[i].x == x && ghosts[i].y == y) {
            return (int)i;
        }
    }
    return -1;
}

static int can_move_dir(int x, int y, int dir)
{
    return tile_walkable(x + dir_dx(dir), y + dir_dy(dir));
}

static void reset_actors(void)
{
    unsigned int i;

    player_x = player_spawn_x;
    player_y = player_spawn_y;
    player_dir = DIR_LEFT;
    queued_dir = DIR_LEFT;
    player_tick = 0u;
    ghost_tick = 0u;
    frightened_timer = 0u;
    player_anim_phase = 0u;

    for (i = 0u; i < MAX_GHOSTS; i++) {
        ghosts[i].x = ghosts[i].spawn_x;
        ghosts[i].y = ghosts[i].spawn_y;
        ghosts[i].dir = (i & 1u) ? DIR_LEFT : DIR_RIGHT;
        if (i == 0u) {
            ghosts[i].release_timer = 10u;
        } else if (i == 1u) {
            ghosts[i].release_timer = 24u;
        } else {
            ghosts[i].release_timer = 40u;
        }
    }
}

static void set_mode(int next_mode)
{
    if (mode == next_mode) {
        return;
    }
    mode = next_mode;
    mark_scene_dirty();
}

static void load_round(unsigned int next_round)
{
    int row;
    int col;
    unsigned int next_variant = random_next() & (MAZE_VARIANT_COUNT - 1u);
    int player_found = 0;
    unsigned int ghost_found_mask = 0u;
    unsigned int fallback_variant;

    round_no = next_round;
    pellets_left = 0u;
    power_left = 0u;
    if (next_round > 1u && next_variant == maze_variant) {
        next_variant ^= 1u;
    }
    maze_variant = next_variant;

    for (fallback_variant = 0u; fallback_variant < MAZE_VARIANT_COUNT; fallback_variant++) {
        unsigned int use_variant = (fallback_variant == 0u) ? maze_variant : 0u;

        pellets_left = 0u;
        power_left = 0u;
        player_found = 0;
        ghost_found_mask = 0u;

        for (row = 0; row < BOARD_H; row++) {
            const char *maze_row = maze_row_for(use_variant, row);

            for (col = 0; col < BOARD_W; col++) {
                char cell = maze_row[col];

                base_map[row][col] = TILE_FLOOR;
                pellet_map[row][col] = PELLET_NONE;

                if (cell == '#') {
                    base_map[row][col] = TILE_WALL;
                } else if (cell == '.') {
                    pellet_map[row][col] = PELLET_DOT;
                    pellets_left++;
                } else if (cell == 'o') {
                    pellet_map[row][col] = PELLET_POWER;
                    pellets_left++;
                    power_left++;
                } else if (cell == 'P') {
                    player_spawn_x = col;
                    player_spawn_y = row;
                    player_found = 1;
                } else if (cell >= 'A' && cell < ('A' + MAX_GHOSTS)) {
                    unsigned int ghost_index = (unsigned int)(cell - 'A');
                    ghosts[ghost_index].spawn_x = col;
                    ghosts[ghost_index].spawn_y = row;
                    ghost_found_mask |= 1u << ghost_index;
                }
            }
        }

        if (player_found && pellets_left != 0u &&
            ghost_found_mask == ((1u << MAX_GHOSTS) - 1u)) {
            maze_variant = use_variant;
            break;
        }
    }

    reset_actors();
    set_mode(MODE_READY);
}

static void start_new_game(void)
{
    lives = START_LIVES;
    score = 0u;
    rng_state ^= (anim_tick << 7) ^ 0x9E37u;
    load_round(1u);
}

static void lose_life(void)
{
    if (lives > 1u) {
        lives--;
        reset_actors();
        mode = MODE_READY;
        mark_scene_dirty();
        return;
    }

    lives = 0u;
    if (score > best_score) {
        best_score = score;
    }
    set_mode(MODE_LOSE);
}

static void complete_round(void)
{
    if (score > best_score) {
        best_score = score;
    }

    if (round_no >= ROUND_COUNT) {
        set_mode(MODE_FINISH);
        return;
    }

    set_mode(MODE_CLEAR);
}

static void respawn_ghost(unsigned int ghost_index)
{
    ghosts[ghost_index].x = ghosts[ghost_index].spawn_x;
    ghosts[ghost_index].y = ghosts[ghost_index].spawn_y;
    ghosts[ghost_index].dir = DIR_LEFT;
    ghosts[ghost_index].release_timer = 6u + ghost_index + ghost_index;
}

static int handle_player_vs_ghost(unsigned int ghost_index)
{
    if (player_x != ghosts[ghost_index].x || player_y != ghosts[ghost_index].y) {
        return 0;
    }

    if (frightened_timer != 0u) {
        score += GHOST_SCORE;
        if (score > best_score) {
            best_score = score;
        }
        respawn_ghost(ghost_index);
        mark_chrome_dirty();
        return 1;
    }

    lose_life();
    return -1;
}

static int check_collisions(void)
{
    unsigned int i;

    for (i = 0u; i < MAX_GHOSTS; i++) {
        int result = handle_player_vs_ghost(i);
        if (result < 0) {
            return -1;
        }
    }
    return 0;
}

static void consume_pellet(void)
{
    unsigned char pellet = pellet_map[player_y][player_x];

    if (pellet == PELLET_NONE) {
        return;
    }

    pellet_map[player_y][player_x] = PELLET_NONE;
    if (pellet == PELLET_DOT) {
        score += DOT_SCORE;
    } else {
        score += POWER_SCORE;
        frightened_timer = fright_ticks_for_round();
        if (power_left != 0u) {
            power_left--;
        }
    }

    if (score > best_score) {
        best_score = score;
    }
    if (pellets_left != 0u) {
        pellets_left--;
    }
    mark_chrome_dirty();
    mark_field_dirty();

    if (pellets_left == 0u) {
        complete_round();
    }
}

static void move_player_step(void)
{
    if (mode != MODE_PLAY) {
        return;
    }

    if (can_move_dir(player_x, player_y, queued_dir)) {
        player_dir = queued_dir;
    }
    if (!can_move_dir(player_x, player_y, player_dir)) {
        mark_field_dirty();
        return;
    }

    player_x += dir_dx(player_dir);
    player_y += dir_dy(player_dir);
    player_anim_phase ^= 1u;
    mark_field_dirty();

    consume_pellet();
    if (mode == MODE_PLAY) {
        (void)check_collisions();
    }
}

static void ghost_target(unsigned int ghost_index, int *target_x, int *target_y)
{
    int ahead_dx = dir_dx(player_dir);
    int ahead_dy = dir_dy(player_dir);
    int ahead_x = player_x + ahead_dx + ahead_dx;
    int ahead_y = player_y + ahead_dy + ahead_dy;

    if (ahead_x < 0) {
        ahead_x = 0;
    } else if (ahead_x >= BOARD_W) {
        ahead_x = BOARD_W - 1;
    }
    if (ahead_y < 0) {
        ahead_y = 0;
    } else if (ahead_y >= BOARD_H) {
        ahead_y = BOARD_H - 1;
    }

    switch (ghost_index) {
    case 0u:
        *target_x = player_x;
        *target_y = player_y;
        break;
    case 1u:
        *target_x = ahead_x;
        *target_y = ahead_y;
        break;
    case 2u:
        if ((abs_int(player_x - ghosts[ghost_index].x) + abs_int(player_y - ghosts[ghost_index].y)) <= 4) {
            *target_x = player_x;
            *target_y = player_y;
        } else {
            *target_x = BOARD_W - 2;
            *target_y = 1;
        }
        break;
    default:
        if ((abs_int(player_x - ghosts[ghost_index].x) + abs_int(player_y - ghosts[ghost_index].y)) <= 3) {
            *target_x = 1;
            *target_y = BOARD_H - 2;
        } else {
            *target_x = player_x;
            *target_y = player_y;
        }
        break;
    }
}

static int choose_ghost_dir(unsigned int ghost_index)
{
    int options[4];
    unsigned int option_count = 0u;
    int best_dir = ghosts[ghost_index].dir;
    int best_score = 0x7FFFFFFF;
    int target_x = player_x;
    int target_y = player_y;
    int dir;

    for (dir = 0; dir < 4; dir++) {
        int nx;
        int ny;

        if (!can_move_dir(ghosts[ghost_index].x, ghosts[ghost_index].y, dir)) {
            continue;
        }

        nx = ghosts[ghost_index].x + dir_dx(dir);
        ny = ghosts[ghost_index].y + dir_dy(dir);
        if (ghost_index_at_except(nx, ny, ghost_index) >= 0) {
            continue;
        }
        options[option_count++] = dir;
    }

    if (option_count == 0u) {
        return ghosts[ghost_index].dir;
    }

    if (frightened_timer != 0u) {
        return options[random_small(option_count)];
    }

    ghost_target(ghost_index, &target_x, &target_y);
    for (dir = 0; dir < (int)option_count; dir++) {
        int option_dir = options[dir];
        int nx = ghosts[ghost_index].x + dir_dx(option_dir);
        int ny = ghosts[ghost_index].y + dir_dy(option_dir);
        int score_metric = abs_int(target_x - nx) + abs_int(target_y - ny);

        if (option_count > 1u && option_dir == reverse_dir(ghosts[ghost_index].dir)) {
            score_metric += 3;
        }

        if (score_metric < best_score) {
            best_score = score_metric;
            best_dir = option_dir;
        } else if (score_metric == best_score && ((random_next() >> 8) & 1u) != 0u) {
            best_dir = option_dir;
        }
    }

    return best_dir;
}

static void move_ghosts_step(void)
{
    unsigned int i;

    if (mode != MODE_PLAY) {
        return;
    }

    for (i = 0u; i < MAX_GHOSTS; i++) {
        if (ghosts[i].release_timer != 0u) {
            ghosts[i].release_timer--;
            continue;
        }

        ghosts[i].dir = choose_ghost_dir(i);
        if (can_move_dir(ghosts[i].x, ghosts[i].y, ghosts[i].dir)) {
            ghosts[i].x += dir_dx(ghosts[i].dir);
            ghosts[i].y += dir_dy(ghosts[i].dir);
        }
        if (check_collisions() < 0) {
            return;
        }
    }

    mark_field_dirty();
}

static unsigned int cell_visual_code(int row, int col)
{
    unsigned int code = base_map[row][col];
    int ghost_index = ghost_index_at(col, row);

    code |= ((unsigned int)pellet_map[row][col]) << 3;
    if (pellet_map[row][col] == PELLET_POWER) {
        code |= power_phase() << 5;
    }
    if (player_x == col && player_y == row) {
        code |= 1u << 6;
        code |= ((unsigned int)player_dir & 3u) << 7;
        code |= mouth_phase() << 9;
    }
    if (ghost_index >= 0) {
        code |= 1u << 10;
        code |= ((unsigned int)ghost_index & 3u) << 11;
        if (frightened_timer != 0u) {
            code |= 1u << 13;
            code |= fright_flash_phase() << 14;
        }
    }

    return code;
}

static void draw_floor_tile(unsigned int px, unsigned int py)
{
    fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, COLOR_FIELD_BG);
}

static void draw_wall_tile(unsigned int px, unsigned int py)
{
    fill_rect(px, py, CELL_PIXELS, CELL_PIXELS, COLOR_WALL_EDGE);
    fill_rect(px + 1u, py + 1u, CELL_PIXELS - 2u, CELL_PIXELS - 2u, COLOR_WALL);
    fill_rect(px + 1u, py + 1u, CELL_PIXELS - 2u, 1u, COLOR_TEXT);
    fill_rect(px + 1u, py + CELL_PIXELS - 2u, CELL_PIXELS - 2u, 1u, COLOR_FRAME);
}

static void draw_dot(unsigned int px, unsigned int py)
{
    vga_fb_put_pixel(px + 2u, py + 2u, COLOR_DOT);
}

static void draw_power(unsigned int px, unsigned int py)
{
    unsigned char body = power_phase() ? COLOR_POWER : COLOR_POWER_RING;
    unsigned char ring = power_phase() ? COLOR_POWER_RING : COLOR_DOT;

    vga_fb_put_pixel(px + 2u, py + 2u, body);
    vga_fb_put_pixel(px + 2u, py + 1u, ring);
    vga_fb_put_pixel(px + 1u, py + 2u, ring);
    vga_fb_put_pixel(px + 3u, py + 2u, ring);
    vga_fb_put_pixel(px + 2u, py + 3u, ring);
}

static void draw_player(unsigned int px, unsigned int py)
{
    unsigned int mouth_open = (mode == MODE_PLAY) ? mouth_phase() : 0u;

    fill_rect(px + 1u, py + 1u, 3u, 3u, COLOR_PLAYER);
    vga_fb_put_pixel(px + 2u, py, COLOR_PLAYER);
    vga_fb_put_pixel(px + 2u, py + 4u, COLOR_PLAYER);
    vga_fb_put_pixel(px + 1u, py + 1u, COLOR_PLAYER_EDGE);
    vga_fb_put_pixel(px + 3u, py + 1u, COLOR_PLAYER_EDGE);
    vga_fb_put_pixel(px + 1u, py + 3u, COLOR_PLAYER_EDGE);
    vga_fb_put_pixel(px + 3u, py + 3u, COLOR_PLAYER_EDGE);

    if (mouth_open != 0u) {
        if (player_dir == DIR_RIGHT) {
            vga_fb_put_pixel(px + 3u, py + 2u, COLOR_FIELD_BG);
            vga_fb_put_pixel(px + 4u, py + 2u, COLOR_FIELD_BG);
            vga_fb_put_pixel(px + 3u, py + 3u, COLOR_FIELD_BG);
        } else if (player_dir == DIR_LEFT) {
            vga_fb_put_pixel(px + 1u, py + 2u, COLOR_FIELD_BG);
            vga_fb_put_pixel(px, py + 2u, COLOR_FIELD_BG);
            vga_fb_put_pixel(px + 1u, py + 3u, COLOR_FIELD_BG);
        } else if (player_dir == DIR_UP) {
            vga_fb_put_pixel(px + 2u, py + 1u, COLOR_FIELD_BG);
            vga_fb_put_pixel(px + 2u, py, COLOR_FIELD_BG);
            vga_fb_put_pixel(px + 3u, py + 1u, COLOR_FIELD_BG);
        } else {
            vga_fb_put_pixel(px + 2u, py + 3u, COLOR_FIELD_BG);
            vga_fb_put_pixel(px + 2u, py + 4u, COLOR_FIELD_BG);
            vga_fb_put_pixel(px + 3u, py + 3u, COLOR_FIELD_BG);
        }
    }
}

static void draw_ghost(unsigned int px, unsigned int py, unsigned int ghost_index)
{
    unsigned char body = ghost_body_color(ghost_index);
    unsigned char eye = COLOR_DOT;

    if (frightened_timer != 0u) {
        body = fright_flash_phase() ? COLOR_GHOST_FLASH : COLOR_GHOST_FRIGHT;
        eye = COLOR_TEXT;
    }

    fill_rect(px + 1u, py + 1u, 3u, 1u, body);
    fill_rect(px, py + 2u, 5u, 1u, body);
    fill_rect(px, py + 3u, 5u, 1u, body);
    fill_rect(px + 1u, py + 4u, 1u, 1u, body);
    fill_rect(px + 3u, py + 4u, 1u, 1u, body);

    vga_fb_put_pixel(px + 1u, py + 2u, eye);
    vga_fb_put_pixel(px + 3u, py + 2u, eye);
    if (frightened_timer == 0u) {
        vga_fb_put_pixel(px + 1u, py + 3u, COLOR_EYE);
        vga_fb_put_pixel(px + 3u, py + 3u, COLOR_EYE);
    }
}

static void draw_field_cell(int row, int col)
{
    unsigned int ucol = (unsigned int)col;
    unsigned int urow = (unsigned int)row;
    unsigned int px = FIELD_X + (ucol << 2) + ucol;
    unsigned int py = FIELD_Y + (urow << 2) + urow;
    int ghost_index = ghost_index_at(col, row);

    if (base_map[row][col] == TILE_WALL) {
        draw_wall_tile(px, py);
        return;
    }

    draw_floor_tile(px, py);
    if (pellet_map[row][col] == PELLET_DOT) {
        draw_dot(px, py);
    } else if (pellet_map[row][col] == PELLET_POWER) {
        draw_power(px, py);
    }
    if (ghost_index >= 0) {
        draw_ghost(px, py, (unsigned int)ghost_index);
    }
    if (player_x == col && player_y == row) {
        draw_player(px, py);
    }
}

static const char *state_text(void)
{
    if (mode == MODE_READY) {
        return "READY";
    }
    if (mode == MODE_CLEAR || mode == MODE_FINISH) {
        return "CLEAR";
    }
    if (mode == MODE_LOSE) {
        return "DOWN";
    }
    if (frightened_timer != 0u) {
        return "POWER";
    }
    return "CHASE";
}

static const char *overlay_title(void)
{
    if (mode == MODE_CLEAR) {
        return "ROUND CLEAR";
    }
    if (mode == MODE_FINISH) {
        return "YOU WIN";
    }
    if (mode == MODE_LOSE) {
        return "GAME OVER";
    }
    return "PAC-MAN LITE";
}

static const char *overlay_line_two(void)
{
    if (mode == MODE_CLEAR) {
        return "SPACE NEXT MAP";
    }
    if (mode == MODE_FINISH) {
        return "ALL MAZES CLEAR";
    }
    if (mode == MODE_LOSE) {
        return "R RETRY";
    }
    return "SPACE OR MOVE";
}

static const char *overlay_hint(void)
{
    if (mode == MODE_CLEAR) {
        return "N17 MENU";
    }
    if (mode == MODE_FINISH) {
        return "R RESTART  N17 MENU";
    }
    if (mode == MODE_LOSE) {
        return "N17 MENU";
    }
    return "WASD TURN";
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
    draw_text_centered(FOOTER_X, FOOTER_Y + 2u, FOOTER_W, "WASD TURN SPC START R RESET N17 MENU", 1u, COLOR_TEXT);
    scene_valid = 1;
}

static void render_title(void)
{
    fill_rect(TITLE_X + 1u, TITLE_Y + 1u, TITLE_W - 2u, TITLE_H - 2u, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    draw_text_centered(TITLE_X, TITLE_Y + 3u, TITLE_W, "PAC-MAN LITE", 2u, COLOR_TEXT);
}

static void draw_life_icon(unsigned int x, unsigned int y)
{
    fill_rect(x + 1u, y + 1u, 4u, 4u, COLOR_PLAYER);
    fill_rect(x + 2u, y, 2u, 1u, COLOR_PLAYER);
    vga_fb_put_pixel(x + 4u, y + 2u, COLOR_FIELD_BG);
    vga_fb_put_pixel(x + 4u, y + 3u, COLOR_FIELD_BG);
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
            unsigned int visual = cell_visual_code(row, col);
            if (shown_field[row][col] != visual) {
                draw_field_cell(row, col);
                shown_field[row][col] = visual;
            }
        }
    }
}

static void render_side_panel(int force_full)
{
    unsigned int i;
    unsigned int icon_x = SIDE_X + 7u;

    if (!force_full && !chrome_redraw) {
        return;
    }

    fill_rect(SIDE_X + 1u, SIDE_Y + 1u, SIDE_W - 2u, SIDE_H - 2u, COLOR_PANEL);
    fill_rect(SIDE_X + 2u, SIDE_Y + 2u, SIDE_W - 4u, 2u, COLOR_ACCENT);

    draw_text_centered(SIDE_X, SIDE_Y + 6u, SIDE_W, "SCORE", 1u, COLOR_LABEL);
    draw_frame(SIDE_X + 6u, SIDE_Y + 14u, 36u, 10u, COLOR_FRAME, COLOR_CARD);
    draw_uint(SIDE_X + 11u, SIDE_Y + 17u, 1u, score, COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 24u, SIDE_W, "DOTS", 1u, COLOR_LABEL);
    draw_frame(SIDE_X + 6u, SIDE_Y + 32u, 36u, 10u, COLOR_FRAME, COLOR_CARD);
    draw_uint(SIDE_X + 11u, SIDE_Y + 35u, 1u, pellets_left, COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 42u, SIDE_W, "ROUND", 1u, COLOR_LABEL);
    draw_frame(SIDE_X + 6u, SIDE_Y + 50u, 36u, 10u, COLOR_FRAME, COLOR_CARD);
    draw_uint(SIDE_X + 19u, SIDE_Y + 53u, 1u, round_no, COLOR_TEXT);

    draw_text_centered(SIDE_X, SIDE_Y + 64u, SIDE_W, state_text(), 1u, COLOR_LABEL);
    draw_text_centered(SIDE_X, SIDE_Y + 74u, SIDE_W, "LIVES", 1u, COLOR_LABEL);
    fill_rect(SIDE_X + 6u, SIDE_Y + 79u, 36u, 6u, COLOR_PANEL);
    for (i = 0u; i < lives; i++) {
        draw_life_icon(icon_x, SIDE_Y + 79u);
        icon_x += 8u;
    }

    chrome_redraw = 0;
}

static void render_overlay(void)
{
    if (mode == MODE_PLAY) {
        return;
    }

    draw_frame(OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H, COLOR_FRAME, COLOR_OVERLAY);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 9u, OVERLAY_W, overlay_title(), 1u, COLOR_TEXT);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 21u, OVERLAY_W, overlay_line_two(), 1u, COLOR_LABEL);
    draw_text_centered(OVERLAY_X, OVERLAY_Y + 31u, OVERLAY_W, overlay_hint(), 1u, COLOR_TEXT);
}

static void render_scene(void)
{
    int force_full = 0;

    if (!scene_valid) {
        draw_static_scene();
        force_full = 1;
    }

    if (force_full) {
        render_title();
    }
    render_field(force_full);
    render_side_panel(force_full);
    render_overlay();
    need_redraw = 0;
}

static void queue_dir(int dir)
{
    queued_dir = dir;
    if (mode == MODE_READY) {
        set_mode(MODE_PLAY);
    }
}

static void advance_round_from_clear(void)
{
    if (mode == MODE_CLEAR) {
        load_round(round_no + 1u);
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
        start_new_game();
        return 0;
    }
    if (ch == '\n') {
        return 0;
    }
    if (ch == '\r') {
        swallow_lf = 1;
        if (mode == MODE_CLEAR) {
            advance_round_from_clear();
        } else if (mode == MODE_READY) {
            set_mode(MODE_PLAY);
        } else if (mode == MODE_FINISH || mode == MODE_LOSE) {
            start_new_game();
        }
        return 0;
    }
    if (ch == ' ') {
        if (mode == MODE_CLEAR) {
            advance_round_from_clear();
        } else if (mode == MODE_READY) {
            set_mode(MODE_PLAY);
        } else if (mode == MODE_FINISH || mode == MODE_LOSE) {
            start_new_game();
        }
        return 0;
    }
    if (mode == MODE_CLEAR || mode == MODE_LOSE || mode == MODE_FINISH) {
        return 0;
    }

    switch (ch) {
    case 'w':
        queue_dir(DIR_UP);
        break;
    case 'a':
        queue_dir(DIR_LEFT);
        break;
    case 's':
        queue_dir(DIR_DOWN);
        break;
    case 'd':
        queue_dir(DIR_RIGHT);
        break;
    default:
        break;
    }

    return 0;
}

static void step_world(void)
{
    anim_tick++;

    if (frightened_timer != 0u) {
        frightened_timer--;
        if (frightened_timer == 0u) {
            mark_chrome_dirty();
            mark_field_dirty();
        }
    }

    if (mode == MODE_PLAY) {
        player_tick++;
        ghost_tick++;

        if (player_tick >= player_step_period()) {
            player_tick = 0u;
            move_player_step();
        }
        if (mode == MODE_PLAY && ghost_tick >= ghost_step_period()) {
            ghost_tick = 0u;
            move_ghosts_step();
        }
    }
}

int main(void)
{
    ui_clear_screen();
    ui_puts("VGA Pac-Man Lite (160x120 framebuffer)\n");
    ui_puts("Use UART: w/a/s/d turn, space start, r reset, BTNC launcher menu.\n");
    ui_drain_input();

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();
    invalidate_field_cache();
    start_new_game();

    while (1) {
        int ch = ui_read_byte_nonblocking();

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        if (ui_launcher_menu_requested()) {
            launcher_button_return();
        }
#endif

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
