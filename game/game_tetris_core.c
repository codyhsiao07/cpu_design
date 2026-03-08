#define BOARD_W 10
#define BOARD_H 20
#define DROP_POLLS_START 180u
#define DROP_POLLS_MIN 45u
#define DROP_POLLS_STEP 12u
#define LEVEL_LINES 5u
#define POLL_SPIN 3000u

#include "game_tetris_core.h"

static unsigned char board[BOARD_H][BOARD_W];

static int current_type;
static int current_rot;
static int current_x;
static int current_y;
static int next_type;
static unsigned int rng_state = 0x12345678u;
static unsigned int score;
static unsigned int lines_cleared_total;
static unsigned int piece_count;
static unsigned int level_value;
static unsigned int lines_until_level;
static unsigned int drop_polls_current;
static int game_over;
static int screen_inited;
static int need_redraw;

typedef enum {
    TETRIS_CONTINUE = 0,
    TETRIS_TO_MENU = 1,
    TETRIS_TO_QUIT = 2
} tetris_input_result_t;

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

static const char piece_chars[7] = {'I', 'O', 'T', 'S', 'Z', 'J', 'L'};

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
    unsigned char ch = (unsigned char)piece_chars[current_type];

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
                board[by][bx] = ch;
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
    game_over = 0;
    rng_state ^= 0x9E3779B9u;
    next_type = next_piece_type();
    spawn_piece();
    screen_inited = 0;
    need_redraw = 1;
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

static char board_cell_for_render(int row, int col)
{
    int r;
    int c;

    for (r = 0; r < 4; r++) {
        for (c = 0; c < 4; c++) {
            if (!piece_has_cell(current_type, current_rot, r, c)) {
                continue;
            }
            if ((current_y + r) == row && (current_x + c) == col) {
                return (char)piece_chars[current_type];
            }
        }
    }

    if (board[row][col] == 0u) {
        return '.';
    }
    return (char)board[row][col];
}

static void render_game(const tetris_game_options_t *options)
{
    int r;
    int c;

    if (!screen_inited) {
        ui_clear_screen();
        screen_inited = 1;
    } else {
        ui_home_cursor();
    }

    if (options->title != 0) {
        ui_puts(options->title);
    } else {
        ui_puts("UART Tetris");
    }
    ui_putc('\n');
    ui_puts("Controls: a/d move  w rotate  s drop  <space> hard drop\n");
    if (options->allow_menu && options->allow_quit) {
        ui_puts("m: menu   q: quit launcher\n");
    } else if (options->allow_menu) {
        ui_puts("m: menu\n");
    } else if (options->allow_quit) {
        ui_puts("q: quit\n");
    }
    ui_puts("Score: ");
    ui_put_uint(score);
    ui_puts("   Lines: ");
    ui_put_uint(lines_cleared_total);
    ui_puts("   Level: ");
    ui_put_uint(level_value);
    ui_puts("   Next: ");
    ui_putc(piece_chars[next_type]);
    ui_putc('\n');
    ui_puts("+----------+\n");

    for (r = 0; r < BOARD_H; r++) {
        ui_putc('|');
        for (c = 0; c < BOARD_W; c++) {
            ui_putc(board_cell_for_render(r, c));
        }
        ui_putc('|');
        ui_putc('\n');
    }

    ui_puts("+----------+\n");

    if (game_over) {
        ui_puts("Game over. Press r to restart");
        if (options->allow_menu) {
            ui_puts(", m for menu");
        }
        if (options->allow_quit) {
            ui_puts(", q to quit");
        }
        ui_puts(".\n");
    } else {
        ui_puts("Piece ");
        ui_put_uint(piece_count);
        ui_puts(" running...\n");
    }

    need_redraw = 0;
}

static tetris_input_result_t handle_runtime_input(const tetris_game_options_t *options, int ch)
{
    ch = ui_to_lower(ch);

    if ((ch == '\r') || (ch == '\n')) {
        return TETRIS_CONTINUE;
    }

    if (game_over) {
        if (ch == 'r') {
            start_new_game();
        } else if ((ch == 'm') && options->allow_menu) {
            return TETRIS_TO_MENU;
        } else if ((ch == 'q') && options->allow_quit) {
            return TETRIS_TO_QUIT;
        }
        return TETRIS_CONTINUE;
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
    } else if ((ch == 'm') && options->allow_menu) {
        return TETRIS_TO_MENU;
    } else if ((ch == 'q') && options->allow_quit) {
        return TETRIS_TO_QUIT;
    }

    return TETRIS_CONTINUE;
}

game_run_result_t tetris_run_game(const tetris_game_options_t *options)
{
    unsigned int drop_counter = 0u;

    start_new_game();

    while (1) {
        int ch = ui_read_byte_nonblocking();
        tetris_input_result_t input_result = TETRIS_CONTINUE;

        if (need_redraw) {
            render_game(options);
        }

        if (ch >= 0) {
            input_result = handle_runtime_input(options, ch);
            if (input_result == TETRIS_TO_MENU) {
                return GAME_RUN_MENU;
            }
            if (input_result == TETRIS_TO_QUIT) {
                return GAME_RUN_QUIT;
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
}
