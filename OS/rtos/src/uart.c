#include "uart.h"

#define RTOS_UART_TX_DATA      ( *( volatile uint32_t * ) 0x40000000u )
#define RTOS_UART_TX_STATUS    ( *( volatile uint32_t * ) 0x40000004u )

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
