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
#endif

#endif

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

int ui_read_byte_blocking(void)
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

int ui_read_byte_nonblocking(void)
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

int ui_to_lower(int ch)
{
    if ((ch >= 'A') && (ch <= 'Z')) {
        return ch - 'A' + 'a';
    }
    return ch;
}
