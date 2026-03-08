#ifndef GAMES_SHARED_UI_H
#define GAMES_SHARED_UI_H

typedef enum {
    GAME_RUN_MENU = 0,
    GAME_RUN_QUIT = 1
} game_run_result_t;

int ui_tx_ready(void);
void ui_putc(char ch);
void ui_puts(const char *text);
void ui_put_uint(unsigned int value);
void ui_clear_screen(void);
void ui_home_cursor(void);
void ui_short_pause(unsigned int spins);
int ui_read_byte_blocking(void);
int ui_read_byte_nonblocking(void);
int ui_to_lower(int ch);

#endif
