#include <stdint.h>

#include "board_control.h"
#include "uart.h"

#define RTOS_LAUNCHER_RESET ( *( volatile uint32_t * ) 0x40000014u )

void rtos_board_disable_external_interrupts( void ) {
    const uint32_t machine_external_interrupt_enable = 1u << 11u;
    __asm volatile ( "csrc mie, %0" :: "r" ( machine_external_interrupt_enable ) : "memory" );
}

void rtos_board_request_image_reload( void ) {
    /* Do not reset the UART while its final status line is still shifting. */
    rtos_uart_wait_tx_idle();
    __asm volatile ( "fence iorw, iorw" ::: "memory" );
    RTOS_LAUNCHER_RESET = 1u;
    __asm volatile ( "fence iorw, iorw" ::: "memory" );

    /* Hardware takes ownership of DDR and resets the CPU after its arm delay. */
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}
