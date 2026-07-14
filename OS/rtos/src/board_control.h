#ifndef OS_RTOS_BOARD_CONTROL_H
#define OS_RTOS_BOARD_CONTROL_H

void rtos_board_request_image_reload( void ) __attribute__( ( noreturn ) );
void rtos_board_disable_external_interrupts( void );

#endif
