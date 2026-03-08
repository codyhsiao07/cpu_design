#ifndef GAME_TETRIS_CORE_H
#define GAME_TETRIS_CORE_H

#include "games_shared_ui.h"

typedef struct {
    const char *title;
    int allow_menu;
    int allow_quit;
} tetris_game_options_t;

game_run_result_t tetris_run_game(const tetris_game_options_t *options);

#endif
