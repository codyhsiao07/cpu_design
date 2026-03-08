#include "game_tetris_menu.h"

game_run_result_t game_tetris_run(void)
{
    static const tetris_game_options_t options = {
        "UART Tetris",
        1,
        1
    };

    return tetris_run_game(&options);
}
