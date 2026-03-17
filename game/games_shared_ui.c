#if !defined(GAME_USE_UART) || defined(HOST_SIM_UART)
#include <stdio.h>
#endif

#include "games_shared_ui.h"

#if defined(GAME_USE_UART)

#if !defined(HOST_SIM_UART)
#define UART_TX_DATA   (*(volatile unsigned int *)0x40000000u)
#define UART_TX_STATUS (*(volatile unsigned int *)0x40000004u)
#define UART_RX_DATA   (*(volatile unsigned int *)0x40000008u)
#define UART_RX_STATUS (*(volatile unsigned int *)0x4000000Cu)
#define UART_LAUNCHER_STATUS (*(volatile unsigned int *)0x40000010u)
#define UART_LAUNCHER_RESET  (*(volatile unsigned int *)0x40000014u)
#endif

#endif

#define UI_INPUT_BARRIER_DRAIN 256u
#define UI_LAUNCHER_RELEASE_POLLS 64u
#define UI_LAUNCHER_RELEASE_SPIN 400u

static ui_input_policy_t ui_input_policy = UI_INPUT_POLICY_NORMAL;
static int ui_q_arm_active = 0;
static unsigned int ui_launcher_ignore_polls = 0u;
static int ui_launcher_prev_pressed = 0;

int ui_tx_ready(void)
{
#if defined(GAME_USE_UART)
#if defined(HOST_SIM_UART)
    return 1;
#else
    return (UART_TX_STATUS & 1u) != 0u;
#endif
#else
    return 1;
#endif
}

static void ui_write_byte(unsigned char value)
{
#if defined(GAME_USE_UART)
#if defined(HOST_SIM_UART)
    putchar((int)value);
#else
    while (!ui_tx_ready()) {
    }
    UART_TX_DATA = (unsigned int)value;
#endif
#else
    putchar((int)value);
#endif
}

void ui_putc(char ch)
{
    if (ch == '\n') {
        ui_write_byte('\r');
    }
    ui_write_byte((unsigned char)ch);
}

void ui_puts(const char *text)
{
    while (*text != '\0') {
        ui_putc(*text++);
    }
}

void ui_put_uint(unsigned int value)
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
            ui_putc((char)('0' + digit));
            started = 1;
        }
    }
}

void ui_clear_screen(void)
{
    ui_puts("\x1B[2J\x1B[H");
}

void ui_home_cursor(void)
{
    ui_puts("\x1B[H");
}

void ui_short_pause(unsigned int spins)
{
    volatile unsigned int i;
    for (i = 0u; i < spins; i++) {
    }
}

static int ui_read_byte_blocking_raw(void)
{
#if defined(GAME_USE_UART)
#if defined(HOST_SIM_UART)
    return getchar();
#else
    while ((UART_RX_STATUS & 1u) == 0u) {
    }
    return (int)(UART_RX_DATA & 0xFFu);
#endif
#else
    return getchar();
#endif
}

static int ui_read_byte_nonblocking_raw(void)
{
#if defined(GAME_USE_UART)
#if defined(HOST_SIM_UART)
    return -1;
#else
    if ((UART_RX_STATUS & 1u) == 0u) {
        return -1;
    }
    return (int)(UART_RX_DATA & 0xFFu);
#endif
#else
    return -1;
#endif
}

static int ui_filter_input(int ch, int blocking)
{
    for (;;) {
        if (ch < 0) {
            return -1;
        }

        ch = ui_to_lower(ch);

        if (ui_input_policy == UI_INPUT_POLICY_IGNORE_Q) {
            if (ch == 'q') {
                ch = blocking ? ui_read_byte_blocking_raw() : ui_read_byte_nonblocking_raw();
                continue;
            }
            return ch;
        }

        if (ui_input_policy == UI_INPUT_POLICY_FILTER_DOUBLE_Q) {
            if (ch == 'q') {
                if (ui_q_arm_active) {
                    ui_q_arm_active = 0;
                    return ch;
                }
                ui_q_arm_active = 1;
                ui_puts("\nPress q again to return to menu.\n");
                ch = blocking ? ui_read_byte_blocking_raw() : ui_read_byte_nonblocking_raw();
                continue;
            }
            ui_q_arm_active = 0;
            return ch;
        }

        ui_q_arm_active = 0;
        return ch;
    }
}

int ui_read_byte_blocking(void)
{
    return ui_filter_input(ui_read_byte_blocking_raw(), 1);
}

int ui_read_byte_nonblocking(void)
{
    return ui_filter_input(ui_read_byte_nonblocking_raw(), 0);
}

void ui_drain_input_limited(unsigned int max_reads)
{
    unsigned int reads = 0u;

    while (reads < max_reads && ui_read_byte_nonblocking_raw() >= 0) {
        reads++;
    }
    ui_q_arm_active = 0;
}

void ui_drain_input(void)
{
    ui_drain_input_limited(128u);
}

void ui_input_barrier(void)
{
    ui_drain_input_limited(UI_INPUT_BARRIER_DRAIN);
}

int ui_to_lower(int ch)
{
    if ((ch >= 'A') && (ch <= 'Z')) {
        return ch - 'A' + 'a';
    }
    return ch;
}

void ui_set_input_policy(ui_input_policy_t policy)
{
    ui_input_policy = policy;
    ui_q_arm_active = 0;
}

int ui_launcher_button_pressed(void)
{
#if defined(GAME_USE_UART)
#if defined(HOST_SIM_UART)
    return 0;
#else
    return (UART_LAUNCHER_STATUS & 1u) != 0u;
#endif
#else
    return 0;
#endif
}

void ui_launcher_wait_button_release(void)
{
    unsigned int stable_polls = 0u;

    while (stable_polls < UI_LAUNCHER_RELEASE_POLLS) {
        if (ui_launcher_button_pressed()) {
            stable_polls = 0u;
        } else {
            stable_polls++;
        }
        ui_short_pause(UI_LAUNCHER_RELEASE_SPIN);
    }
}

void ui_launcher_ignore_button_polls(unsigned int polls)
{
    ui_launcher_ignore_polls = polls;
}

void ui_launcher_sync_button_state(void)
{
    ui_launcher_prev_pressed = ui_launcher_button_pressed();
}

int ui_launcher_menu_requested(void)
{
    int pressed = ui_launcher_button_pressed();

    if (ui_launcher_ignore_polls != 0u) {
        ui_launcher_ignore_polls--;
        ui_launcher_prev_pressed = pressed;
        return 0;
    }

    if (pressed && !ui_launcher_prev_pressed) {
        ui_launcher_prev_pressed = pressed;
        return 1;
    }

    ui_launcher_prev_pressed = pressed;
    return 0;
}

void ui_launcher_request_menu(void)
{
#if defined(GAME_USE_UART)
#if !defined(HOST_SIM_UART)
    UART_LAUNCHER_RESET = 1u;
    for (;;) {
    }
#endif
#endif
}
