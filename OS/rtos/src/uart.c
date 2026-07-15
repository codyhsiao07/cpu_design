#include "uart.h"

#include "FreeRTOS.h"
#include "stream_buffer.h"

#define RTOS_UART_TX_DATA      ( *( volatile uint32_t * ) 0x40000000u )
#define RTOS_UART_TX_STATUS    ( *( volatile uint32_t * ) 0x40000004u )
#define RTOS_UART_RX_DATA      ( *( volatile uint32_t * ) 0x40000008u )
#define RTOS_UART_RX_STATUS    ( *( volatile uint32_t * ) 0x4000000Cu )
#define RTOS_UART_MEIP         ( *( volatile uint32_t * ) 0x4000001Cu )
#define RTOS_UART_RX_STREAM_BYTES 256u

static StaticStreamBuffer_t rx_stream_tcb;
static uint8_t rx_stream_storage[ RTOS_UART_RX_STREAM_BYTES ];
static StreamBufferHandle_t rx_stream;
static volatile uint32_t rx_interrupts;
static volatile uint32_t rx_hardware_overruns;
static volatile uint32_t rx_stream_drops;
static uint32_t rx_reported_errors;

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

void rtos_uart_write_u64( uint64_t value ) {
    char digits[ 20 ];
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

int rtos_uart_rx_interrupt_init( void ) {
    uint32_t status;
    const uint32_t machine_external_interrupt_enable = 1u << 11u;

    if( rx_stream == NULL ) {
        rx_stream = xStreamBufferCreateStatic(
            RTOS_UART_RX_STREAM_BYTES,
            1u,
            rx_stream_storage,
            &rx_stream_tcb
        );
    }
    if( rx_stream == NULL ) {
        return 0;
    }

    status = RTOS_UART_RX_STATUS;
    if( ( status & 1u ) != 0u ) {
        ( void ) RTOS_UART_RX_DATA;
    }
    if( ( status & 2u ) != 0u ) {
        rx_hardware_overruns++;
    }
    RTOS_UART_MEIP = 0u;
    __asm volatile ( "csrs mie, %0" :: "r" ( machine_external_interrupt_enable ) : "memory" );
    return 1;
}

int rtos_uart_handle_external_interrupt( void ) {
    BaseType_t higher_priority_task_woken = pdFALSE;
    uint32_t status = RTOS_UART_RX_STATUS;

    rx_interrupts++;
    if( ( status & 2u ) != 0u ) {
        rx_hardware_overruns++;
    }
    if( ( status & 1u ) != 0u ) {
        uint8_t value = ( uint8_t ) ( RTOS_UART_RX_DATA & 0xFFu );
        if( rx_stream != NULL ) {
            if( xStreamBufferSendFromISR(
                    rx_stream,
                    &value,
                    1u,
                    &higher_priority_task_woken ) != 1u ) {
                rx_stream_drops++;
            }
        } else {
            rx_stream_drops++;
        }
    }

    RTOS_UART_MEIP = 0u;
    return higher_priority_task_woken != pdFALSE;
}

int rtos_uart_try_getc( char * value, uint32_t * overrun ) {
    uint32_t status;
    uint32_t errors;

    if( rx_stream != NULL ) {
        errors = rx_hardware_overruns + rx_stream_drops;
        if( overrun != NULL ) {
            *overrun = errors != rx_reported_errors;
        }
        rx_reported_errors = errors;
        return xStreamBufferReceive( rx_stream, value, 1u, 0u ) == 1u;
    }

    status = RTOS_UART_RX_STATUS;
    if( overrun != NULL ) {
        *overrun = ( status >> 1u ) & 1u;
    }
    if( ( status & 1u ) == 0u ) {
        return 0;
    }
    *value = ( char ) ( RTOS_UART_RX_DATA & 0xFFu );
    return 1;
}

int rtos_uart_getc( char * value, uint32_t timeout_ticks, uint32_t * overrun ) {
    uint32_t errors;

    if( rx_stream == NULL ) {
        return rtos_uart_try_getc( value, overrun );
    }
    errors = rx_hardware_overruns + rx_stream_drops;
    if( overrun != NULL ) {
        *overrun = errors != rx_reported_errors;
    }
    rx_reported_errors = errors;
    return xStreamBufferReceive(
               rx_stream,
               value,
               1u,
               ( TickType_t ) timeout_ticks ) == 1u;
}

uint32_t rtos_uart_rx_interrupt_count( void ) {
    return rx_interrupts;
}

uint32_t rtos_uart_rx_hardware_overrun_count( void ) {
    return rx_hardware_overruns;
}

uint32_t rtos_uart_rx_stream_drop_count( void ) {
    return rx_stream_drops;
}

void rtos_uart_trigger_test_interrupt( void ) {
    RTOS_UART_MEIP = 1u;
}
