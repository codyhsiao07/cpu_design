#ifndef OS_RTOS_UART_H
#define OS_RTOS_UART_H

#include <stdint.h>

void rtos_uart_putc( char c );
void rtos_uart_write( const char * text );
void rtos_uart_write_u32( uint32_t value );
void rtos_uart_write_hex32( uint32_t value );
void rtos_uart_write_line( const char * text );
void rtos_uart_wait_tx_idle( void );
int rtos_uart_try_getc( char * value, uint32_t * overrun );

#endif
