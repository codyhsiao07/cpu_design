#include "game_tictactoe_menu.h"

game_run_result_t game_tictactoe_run(void)
{
    static const ttt_game_options_t options = {
        "Tic-Tac-Toe",
        "Enter two digits 1..5, e.g. 11 or 24.",
        "m: menu   q: quit launcher",
        1,
        1
    };

    return ttt_run_game(&options);
}
