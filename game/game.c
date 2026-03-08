#define SIZE 5

#if !defined(GAME_USE_UART) || defined(HOST_SIM_UART)
#include <stdio.h>
#endif

static char board[SIZE][SIZE];

#if defined(GAME_USE_UART)

#if !defined(HOST_SIM_UART)
#define UART_TX_DATA   (*(volatile unsigned int *)0x40000000u)
#define UART_TX_STATUS (*(volatile unsigned int *)0x40000004u)
#define UART_RX_DATA   (*(volatile unsigned int *)0x40000008u)
#define UART_RX_STATUS (*(volatile unsigned int *)0x4000000Cu)
#endif

static int uart_tx_ready(void)
{
#if defined(HOST_SIM_UART)
    return 1;
#else
    return (UART_TX_STATUS & 1u) != 0u;
#endif
}

static void uart_write_byte(unsigned char value)
{
#if defined(HOST_SIM_UART)
    putchar((int)value);
#else
    while (!uart_tx_ready()) {
    }
    UART_TX_DATA = (unsigned int)value;
#endif
}

static int uart_read_byte(void)
{
#if defined(HOST_SIM_UART)
    return getchar();
#else
    while ((UART_RX_STATUS & 1u) == 0u) {
    }
    return (int)(UART_RX_DATA & 0xFFu);
#endif
}

#else

static int uart_tx_ready(void)
{
    return 1;
}

static void uart_write_byte(unsigned char value)
{
    putchar((int)value);
}

#endif

static void io_putc(char ch)
{
    if (ch == '\n') {
        uart_write_byte('\r');
    }
    uart_write_byte((unsigned char)ch);
}

static void io_puts(const char *text)
{
    while (*text != '\0') {
        io_putc(*text++);
    }
}

static void io_put_uint(unsigned int value)
{
    char digits[10];
    unsigned int count = 0;

    if (value == 0u) {
        io_putc('0');
        return;
    }

    while (value != 0u) {
        digits[count++] = (char)('0' + (value % 10u));
        value /= 10u;
    }

    while (count != 0u) {
        io_putc(digits[--count]);
    }
}

static int io_read_replay_choice(void)
{
    int ch;

    while (1) {
#if defined(GAME_USE_UART)
        ch = uart_read_byte();
#else
        ch = getchar();
#endif
        if (ch < 0) {
            return -1;
        }

        if ((ch == ' ') || (ch == '\t') || (ch == '\r') || (ch == '\n')) {
            continue;
        }

        if ((ch >= 'A') && (ch <= 'Z')) {
            ch = ch - 'A' + 'a';
        }

        if ((ch == 'y') || (ch == 'n')) {
            io_putc((char)ch);
            return ch;
        }
    }
}

static int io_read_move(int *row, int *col)
{
#if defined(GAME_USE_UART)
    int ch;
    int values[2];
    int count = 0;

    while (count < 2) {
        ch = uart_read_byte();
        if (ch < 0) {
            return 0;
        }

        if ((ch >= '1') && (ch <= '5')) {
            io_putc((char)ch);
            values[count++] = ch - '0';
        } else if ((ch == ' ') || (ch == '\t')) {
            if (count != 0) {
                io_putc(' ');
            }
        } else if ((ch == '\r') || (ch == '\n')) {
            /* Ignore line endings. This also absorbs leftover newline from
             * the previous move without polluting the next prompt. */
        }
    }

    *row = values[0];
    *col = values[1];
    return 1;
#else
    return scanf("%d %d", row, col) == 2;
#endif
}

static void initBoard(void)
{
    int i;
    int j;

    for (i = 0; i < SIZE; i++) {
        for (j = 0; j < SIZE; j++) {
            board[i][j] = '.';
        }
    }
}

static void printBoard(void)
{
    int i;
    int j;

    io_putc('\n');
    io_puts("  1 2 3 4 5\n");
    for (i = 0; i < SIZE; i++) {
        io_put_uint((unsigned int)(i + 1));
        io_putc(' ');
        for (j = 0; j < SIZE; j++) {
            io_putc(board[i][j]);
            io_putc(' ');
        }
        io_putc('\n');
    }
}

static int checkWin(char player)
{
    int i;
    int j;

    for (i = 0; i < SIZE; i++) {
        int count = 0;
        for (j = 0; j < SIZE; j++) {
            if (board[i][j] == player) {
                count++;
            }
        }
        if (count == SIZE) {
            return 1;
        }
    }

    for (j = 0; j < SIZE; j++) {
        int count = 0;
        for (i = 0; i < SIZE; i++) {
            if (board[i][j] == player) {
                count++;
            }
        }
        if (count == SIZE) {
            return 1;
        }
    }

    {
        int count = 0;
        for (i = 0; i < SIZE; i++) {
            if (board[i][i] == player) {
                count++;
            }
        }
        if (count == SIZE) {
            return 1;
        }
    }

    {
        int count = 0;
        for (i = 0; i < SIZE; i++) {
            if (board[i][SIZE - i - 1] == player) {
                count++;
            }
        }
        if (count == SIZE) {
            return 1;
        }
    }

    return 0;
}

int main(void)
{
    while (1) {
        int row;
        int col;
        int turn = 0;
        int replay_choice;
        char currentPlayer;
        int game_finished = 0;

        initBoard();

        while (!game_finished) {
            printBoard();

            currentPlayer = ((turn % 2) == 0) ? 'A' : 'B';

            io_putc('\n');
            io_puts("Player ");
            io_putc(currentPlayer);
            io_puts(" move (row col): ");

            if (!io_read_move(&row, &col)) {
                io_puts("\nNo more input. Game stopped.\n");
                (void)uart_tx_ready();
                return 0;
            }

            if (row < 1 || row > SIZE || col < 1 || col > SIZE) {
                io_puts("Invalid move. Use 1..5.\n");
                continue;
            }

            if (board[row - 1][col - 1] != '.') {
                io_puts("Cell already used.\n");
                continue;
            }

            board[row - 1][col - 1] = currentPlayer;

            if (checkWin(currentPlayer)) {
                printBoard();
                io_putc('\n');
                io_puts("Player ");
                io_putc(currentPlayer);
                io_puts(" wins.\n");
                game_finished = 1;
                break;
            }

            turn++;

            if (turn == (SIZE * SIZE)) {
                printBoard();
                io_puts("\nDraw.\n");
                game_finished = 1;
            }
        }

        io_putc('\n');
        io_puts("Play again? (y/n): ");
        replay_choice = io_read_replay_choice();
        if (replay_choice < 0) {
            io_puts("\nNo more input. Game stopped.\n");
            break;
        }

        if (replay_choice != 'y') {
            io_puts("\nBye.\n");
            break;
        }

        io_putc('\n');
    }

    (void)uart_tx_ready();
    return 0;
}
