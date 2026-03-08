#ifndef GAME_TICTACTOE_CORE_H
#define GAME_TICTACTOE_CORE_H

#include "games_shared_ui.h"

typedef struct {
    const char *title;
    const char *input_help;
    const char *nav_help;
    int allow_menu;
    int allow_quit;
} ttt_game_options_t;

game_run_result_t ttt_run_game(const ttt_game_options_t *options);

#endif
