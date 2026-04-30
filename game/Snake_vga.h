#ifndef SNAKE_VGA_H
#define SNAKE_VGA_H

void snake_game_init(void);
int snake_game_handle_input_char(int ch);
void snake_game_update_tick(void);
void snake_game_render_if_needed(void);
void snake_game_shutdown(void);
unsigned int snake_game_score(void);
unsigned int snake_game_length(void);
unsigned int snake_game_speed_ticks(void);
unsigned int snake_game_state(void);

#endif
