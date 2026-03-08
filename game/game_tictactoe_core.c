#define TTT_SIZE 5

#include "game_tictactoe_core.h"

static char ttt_board[TTT_SIZE][TTT_SIZE];

typedef enum {
    TTT_CMD_MOVE = 0,
    TTT_CMD_MENU = 1,
    TTT_CMD_QUIT = 2
} ttt_cmd_t;

typedef enum {
    TTT_POST_REPLAY = 0,
    TTT_POST_MENU = 1,
    TTT_POST_QUIT = 2
} ttt_post_result_t;

static void ttt_init_board(void)
{
    int i;
    int j;

    for (i = 0; i < TTT_SIZE; i++) {
        for (j = 0; j < TTT_SIZE; j++) {
            ttt_board[i][j] = '.';
        }
    }
}

static void ttt_print_board(void)
{
    int i;
    int j;

    ui_putc('\n');
    ui_puts("  1 2 3 4 5\n");
    for (i = 0; i < TTT_SIZE; i++) {
        ui_put_uint((unsigned int)(i + 1));
        ui_putc(' ');
        for (j = 0; j < TTT_SIZE; j++) {
            ui_putc(ttt_board[i][j]);
            ui_putc(' ');
        }
        ui_putc('\n');
    }
}

static int ttt_check_win(char player)
{
    int i;
    int j;

    for (i = 0; i < TTT_SIZE; i++) {
        int count = 0;
        for (j = 0; j < TTT_SIZE; j++) {
            if (ttt_board[i][j] == player) {
                count++;
            }
        }
        if (count == TTT_SIZE) {
            return 1;
        }
    }

    for (j = 0; j < TTT_SIZE; j++) {
        int count = 0;
        for (i = 0; i < TTT_SIZE; i++) {
            if (ttt_board[i][j] == player) {
                count++;
            }
        }
        if (count == TTT_SIZE) {
            return 1;
        }
    }

    {
        int count = 0;
        for (i = 0; i < TTT_SIZE; i++) {
            if (ttt_board[i][i] == player) {
                count++;
            }
        }
        if (count == TTT_SIZE) {
            return 1;
        }
    }

    {
        int count = 0;
        for (i = 0; i < TTT_SIZE; i++) {
            if (ttt_board[i][TTT_SIZE - i - 1] == player) {
                count++;
            }
        }
        if (count == TTT_SIZE) {
            return 1;
        }
    }

    return 0;
}

static ttt_cmd_t ttt_read_move(const ttt_game_options_t *options, int *row, int *col)
{
    int ch;
    int values[2];
    int count = 0;

    while (count < 2) {
        ch = ui_read_byte_blocking();
        if (ch < 0) {
            return TTT_CMD_QUIT;
        }

        ch = ui_to_lower(ch);

        if ((ch == 'm') && (count == 0) && options->allow_menu) {
            ui_putc('m');
            return TTT_CMD_MENU;
        }

        if ((ch == 'q') && (count == 0) && options->allow_quit) {
            ui_putc('q');
            return TTT_CMD_QUIT;
        }

        if ((ch >= '1') && (ch <= '5')) {
            ui_putc((char)ch);
            values[count++] = ch - '0';
        } else if ((ch == ' ') || (ch == '\t')) {
            if (count != 0) {
                ui_putc(' ');
            }
        } else if ((ch == '\r') || (ch == '\n')) {
        }
    }

    *row = values[0];
    *col = values[1];
    return TTT_CMD_MOVE;
}

static ttt_post_result_t ttt_post_game_prompt(const ttt_game_options_t *options)
{
    int ch;

    ui_putc('\n');
    ui_puts("y: replay");
    if (options->allow_menu) {
        ui_puts("   m: menu");
    }
    if (options->allow_quit) {
        ui_puts("   q: quit");
    }
    ui_putc('\n');
    ui_puts("Select: ");

    while (1) {
        ch = ui_read_byte_blocking();
        if (ch < 0) {
            return TTT_POST_QUIT;
        }
        ch = ui_to_lower(ch);
        if ((ch == '\r') || (ch == '\n') || (ch == ' ') || (ch == '\t')) {
            continue;
        }
        if (ch == 'y') {
            ui_putc('y');
            ui_putc('\n');
            return TTT_POST_REPLAY;
        }
        if ((ch == 'm') && options->allow_menu) {
            ui_putc('m');
            ui_putc('\n');
            return TTT_POST_MENU;
        }
        if ((ch == 'q') && options->allow_quit) {
            ui_putc('q');
            ui_putc('\n');
            return TTT_POST_QUIT;
        }
    }
}

game_run_result_t ttt_run_game(const ttt_game_options_t *options)
{
    while (1) {
        int row;
        int col;
        int turn = 0;
        char current_player;
        int finished = 0;
        ttt_post_result_t post_result;

        ttt_init_board();

        while (!finished) {
            ui_clear_screen();
            if (options->title != 0) {
                ui_puts(options->title);
                ui_putc('\n');
            }
            if (options->input_help != 0) {
                ui_puts(options->input_help);
                ui_putc('\n');
            }
            if (options->nav_help != 0) {
                ui_puts(options->nav_help);
                ui_putc('\n');
            }
            ttt_print_board();

            current_player = ((turn & 1) == 0) ? 'A' : 'B';
            ui_putc('\n');
            ui_puts("Player ");
            ui_putc(current_player);
            ui_puts(" move (row col): ");

            switch (ttt_read_move(options, &row, &col)) {
            case TTT_CMD_MENU:
                return GAME_RUN_MENU;
            case TTT_CMD_QUIT:
                return GAME_RUN_QUIT;
            default:
                break;
            }

            if (row < 1 || row > TTT_SIZE || col < 1 || col > TTT_SIZE) {
                ui_puts("\nInvalid move. Use 1..5.\n");
                ui_puts("Press any key to continue...");
                (void)ui_read_byte_blocking();
                continue;
            }

            if (ttt_board[row - 1][col - 1] != '.') {
                ui_puts("\nCell already used.\n");
                ui_puts("Press any key to continue...");
                (void)ui_read_byte_blocking();
                continue;
            }

            ttt_board[row - 1][col - 1] = current_player;

            if (ttt_check_win(current_player)) {
                ui_clear_screen();
                ttt_print_board();
                ui_putc('\n');
                ui_puts("Player ");
                ui_putc(current_player);
                ui_puts(" wins.\n");
                finished = 1;
            } else {
                turn++;
                if (turn == (TTT_SIZE * TTT_SIZE)) {
                    ui_clear_screen();
                    ttt_print_board();
                    ui_puts("\nDraw.\n");
                    finished = 1;
                }
            }
        }

        post_result = ttt_post_game_prompt(options);
        if (post_result == TTT_POST_REPLAY) {
            continue;
        }
        if (post_result == TTT_POST_MENU) {
            return GAME_RUN_MENU;
        }
        return GAME_RUN_QUIT;
    }
}
