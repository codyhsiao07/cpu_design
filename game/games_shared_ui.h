#ifndef GAMES_SHARED_UI_H
#define GAMES_SHARED_UI_H

typedef enum {
    GAME_RUN_MENU = 0,
    GAME_RUN_QUIT = 1
} game_run_result_t;

typedef enum {
    UI_INPUT_POLICY_NORMAL = 0,
    UI_INPUT_POLICY_IGNORE_Q = 1,
    UI_INPUT_POLICY_FILTER_DOUBLE_Q = 2
} ui_input_policy_t;

int ui_tx_ready(void);
void ui_putc(char ch);
void ui_puts(const char *text);
void ui_put_uint(unsigned int value);
void ui_clear_screen(void);
void ui_home_cursor(void);
void ui_short_pause(unsigned int spins);
int ui_read_byte_blocking(void);
int ui_read_byte_nonblocking(void);
void ui_drain_input_limited(unsigned int max_reads);
void ui_drain_input(void);
void ui_input_barrier(void);
int ui_to_lower(int ch);
void ui_set_input_policy(ui_input_policy_t policy);
int ui_launcher_button_pressed(void);
void ui_launcher_sync_button_state(void);
void ui_launcher_ignore_button_polls(unsigned int polls);
void ui_launcher_wait_button_release(void);
int ui_launcher_menu_requested(void);
void ui_launcher_request_menu(void);

#endif
