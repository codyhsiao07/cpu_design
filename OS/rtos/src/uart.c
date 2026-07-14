#include "uart.h"

#define RTOS_UART_TX_DATA      ( *( volatile uint32_t * ) 0x40000000u )
#define RTOS_UART_TX_STATUS    ( *( volatile uint32_t * ) 0x40000004u )
#define RTOS_UART_RX_DATA      ( *( volatile uint32_t * ) 0x40000008u )
#define RTOS_UART_RX_STATUS    ( *( volatile uint32_t * ) 0x4000000Cu )

void rtos_uart_putc( char c ) {
    while( ( RTOS_UART_TX_STATUS & 1u ) == 0u ) {
    }
    RTOS_UART_TX_DATA = ( uint32_t ) ( unsigned char ) c;
}

void rtos_uart_write( const char * text ) {
    while( *text != '\0' ) {
        if( *text == '\n' ) {
            rtos_uart_putc( '\r' );
        }
        rtos_uart_putc( *text );
        text++;
    }
}

void rtos_uart_write_u32( uint32_t value ) {
    char digits[ 10 ];
    uint32_t count = 0u;

    if( value == 0u ) {
        rtos_uart_putc( '0' );
        return;
    }

    while( value != 0u ) {
        digits[ count ] = ( char ) ( '0' + ( value % 10u ) );
        value /= 10u;
        count++;
    }
    while( count != 0u ) {
        count--;
        rtos_uart_putc( digits[ count ] );
    }
}

void rtos_uart_write_hex32( uint32_t value ) {
    static const char hex[] = "0123456789ABCDEF";
    uint32_t shift;

    rtos_uart_write( "0x" );
    for( shift = 28u; ; shift -= 4u ) {
        rtos_uart_putc( hex[ ( value >> shift ) & 0xFu ] );
        if( shift == 0u ) {
            break;
        }
    }
}

void rtos_uart_write_line( const char * text ) {
    rtos_uart_write( text );
    rtos_uart_write( "\n" );
}

void rtos_uart_wait_tx_idle( void ) {
    while( ( RTOS_UART_TX_STATUS & 1u ) == 0u ) {
    }
}

int rtos_uart_try_getc( char * value, uint32_t * overrun ) {
    uint32_t status = RTOS_UART_RX_STATUS;

    if( overrun != 0 ) {
        *overrun = ( status >> 1u ) & 1u;
    }
    if( ( status & 1u ) == 0u ) {
        return 0;
    }
    *value = ( char ) ( RTOS_UART_RX_DATA & 0xFFu );
    return 1;
}
