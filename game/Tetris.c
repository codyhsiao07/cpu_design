#define BOARD_W 10
#define BOARD_H 20
#define DROP_POLLS_START 180u
#define DROP_POLLS_MIN 45u
#define DROP_POLLS_STEP 12u
#define LEVEL_LINES 5u
#define POLL_SPIN 3000u

#if !defined(GAME_USE_UART) || defined(HOST_SIM_UART)
#include <stdio.h>
#endif

#if defined(GAME_USE_UART)

#if !defined(HOST_SIM_UART)
#define UART_TX_DATA   (*(volatile unsigned int *)0x40000000u)
#define UART_TX_STATUS (*(volatile unsigned int *)0x40000004u)
#define UART_RX_DATA   (*(volatile unsigned int *)0x40000008u)
#define UART_RX_STATUS (*(volatile unsigned int *)0x4000000Cu)
#endif

static int uart_tx_ready(void)
{
#if defined(HOST_SIM_UART)
    return 1;
#else
    return (UART_TX_STATUS & 1u) != 0u;
#endif
}

static void uart_write_byte(unsigned char value)
{
#if defined(HOST_SIM_UART)
    putchar((int)value);
#else
    while (!uart_tx_ready()) {
    }
    UART_TX_DATA = (unsigned int)value;
#endif
}

static int uart_read_byte_nonblocking(void)
{
#if defined(HOST_SIM_UART)
    return -1;
#else
    if ((UART_RX_STATUS & 1u) == 0u) {
        return -1;
    }
    return (int)(UART_RX_DATA & 0xFFu);
#endif
}

#else

static int uart_tx_ready(void)
{
    return 1;
}

static void uart_write_byte(unsigned char value)
{
    putchar((int)value);
}

static int uart_read_byte_nonblocking(void)
{
    return -1;
}

#endif

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

static void io_putc(char ch)
{
    if (ch == '\n') {
        uart_write_byte('\r');
    }
    uart_write_byte((unsigned char)ch);
}

static void io_puts(const char *text)
{
    while (*text != '\0') {
        io_putc(*text++);
    }
}

static void io_put_uint(unsigned int value)
{
    static const unsigned int div_table[10] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    unsigned int i;
    int started = 0;

    for (i = 0u; i < 10u; i++) {
        unsigned int digit = 0u;
        while (value >= div_table[i]) {
            value -= div_table[i];
            digit++;
        }
        if (digit != 0u || started || i == 9u) {
            io_putc((char)('0' + digit));
            started = 1;
        }
    }
}

static void io_clear_screen(void)
{
    io_puts("\x1B[2J\x1B[H");
}

static void io_home_cursor(void)
{
    io_puts("\x1B[H");
}

static void short_pause(void)
{
    volatile unsigned int i;
    for (i = 0u; i < POLL_SPIN; i++) {
    }
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

static void render_game(void)
{
    int r;
    int c;

    if (!screen_inited) {
        io_clear_screen();
        screen_inited = 1;
    } else {
        io_home_cursor();
    }

    io_puts("UART Tetris\n");
    io_puts("Controls: a/d move  w rotate  s drop  <space> hard drop  q quit\n");
    io_puts("Score: ");
    io_put_uint(score);
    io_puts("   Lines: ");
    io_put_uint(lines_cleared_total);
    io_puts("   Level: ");
    io_put_uint(level_value);
    io_puts("   Next: ");
    io_putc(piece_chars[next_type]);
    io_putc('\n');
    io_puts("+----------+\n");

    for (r = 0; r < BOARD_H; r++) {
        io_putc('|');
        for (c = 0; c < BOARD_W; c++) {
            io_putc(board_cell_for_render(r, c));
        }
        io_putc('|');
        io_putc('\n');
    }

    io_puts("+----------+\n");

    if (game_over) {
        io_puts("Game over. Press r to restart or q to quit.\n");
    } else {
        io_puts("Piece ");
        io_put_uint(piece_count);
        io_puts(" running...\n");
    }

    need_redraw = 0;
}

static int handle_runtime_input(int ch)
{
    if ((ch >= 'A') && (ch <= 'Z')) {
        ch = ch - 'A' + 'a';
    }

    if ((ch == '\r') || (ch == '\n')) {
        return 0;
    }

    if (game_over) {
        if (ch == 'r') {
            start_new_game();
        } else if (ch == 'q') {
            return -1;
        }
        return 0;
    }

    if (ch == 'a') {
        (void)move_piece(-1, 0);
    } else if (ch == 'd') {
        (void)move_piece(1, 0);
    } else if (ch == 's') {
        advance_game();
    } else if (ch == 'w' || ch == 'x') {
        rotate_piece();
    } else if (ch == ' ') {
        hard_drop();
        advance_game();
    } else if (ch == 'q') {
        return -1;
    }

    return 0;
}

int main(void)
{
    unsigned int drop_counter = 0u;

    start_new_game();

    while (1) {
        int ch = uart_read_byte_nonblocking();

        if (need_redraw) {
            render_game();
        }

        if (ch >= 0) {
            if (handle_runtime_input(ch) < 0) {
                io_puts("\nBye.\n");
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

        short_pause();
    }

    (void)uart_tx_ready();
    return 0;
}
