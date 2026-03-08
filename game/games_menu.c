#include "games_shared_ui.h"
#include "game_tictactoe_menu.h"
#include "game_tetris_menu.h"

static void show_menu(void)
{
    ui_clear_screen();
    ui_puts("==== Game Menu ====\n");
    ui_puts("1. Tic-Tac-Toe\n");
    ui_puts("2. Tetris\n");
    ui_puts("q. Quit\n");
    ui_puts("\n");
    ui_puts("Select: ");
}

static int read_menu_choice(void)
{
    int ch;

    while (1) {
        ch = ui_read_byte_blocking();
        if (ch < 0) {
            return 'q';
        }
        ch = ui_to_lower(ch);
        if ((ch == '\r') || (ch == '\n') || (ch == ' ') || (ch == '\t')) {
            continue;
        }
        if ((ch == '1') || (ch == '2') || (ch == 'q')) {
            ui_putc((char)ch);
            ui_putc('\n');
            return ch;
        }
    }
}

int main(void)
{
    while (1) {
        game_run_result_t result;
        int choice;

        show_menu();
        choice = read_menu_choice();
        if (choice == 'q') {
            break;
        }

        if (choice == '1') {
            result = game_tictactoe_run();
        } else {
            result = game_tetris_run();
        }

        if (result == GAME_RUN_QUIT) {
            break;
        }
    }

    ui_puts("\nBye.\n");
    return 0;
}
