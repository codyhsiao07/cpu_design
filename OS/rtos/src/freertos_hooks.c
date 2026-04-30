#include "FreeRTOS.h"
#include "task.h"
#include "uart.h"

#define RTOS_IDLE_STACK_WORDS 256u

extern void * volatile pxCurrentTCB;

static StaticTask_t idle_tcb;
static StackType_t idle_stack[ RTOS_IDLE_STACK_WORDS ];

#if defined( RTOS_VGA_DEMO_TRACE )
#define RTOS_VGA_TRACE_BASE       ( ( volatile uint32_t * ) 0x50000000u )
#define RTOS_VGA_TRACE_WORDS_ROW  20u
#define RTOS_VGA_TRACE_BG         0x11111111u

static volatile uint32_t trace_in_pos;
static volatile uint32_t trace_out_pos;
static void * volatile trace_tcb0;
static void * volatile trace_tcb1;
static void * volatile trace_tcb2;

static uint32_t trace_word_for_tcb( void * tcb ) {
    if( trace_tcb0 == NULL || trace_tcb0 == tcb ) {
        trace_tcb0 = tcb;
        return 0x22222222u;
    }
    if( trace_tcb1 == NULL || trace_tcb1 == tcb ) {
        trace_tcb1 = tcb;
        return 0xEEEEEEEEu;
    }
    if( trace_tcb2 == NULL || trace_tcb2 == tcb ) {
        trace_tcb2 = tcb;
        return 0x44444444u;
    }
    return 0xFFFFFFFFu;
}

static void trace_cursor_row( uint32_t row, volatile uint32_t * pos, uint32_t word ) {
    uint32_t old_col = *pos % RTOS_VGA_TRACE_WORDS_ROW;
    uint32_t new_col = ( old_col + 1u ) % RTOS_VGA_TRACE_WORDS_ROW;

    RTOS_VGA_TRACE_BASE[ ( row * RTOS_VGA_TRACE_WORDS_ROW ) + old_col ] = RTOS_VGA_TRACE_BG;
    RTOS_VGA_TRACE_BASE[ ( row * RTOS_VGA_TRACE_WORDS_ROW ) + new_col ] = word;
    *pos = new_col;
}

void rtos_vga_trace_switched_in( void * tcb ) {
    trace_cursor_row( 2u, &trace_in_pos, trace_word_for_tcb( tcb ) );
}

void rtos_vga_trace_switched_out( void * tcb ) {
    trace_cursor_row( 5u, &trace_out_pos, trace_word_for_tcb( tcb ) );
}
#endif

#if defined( RTOS_VGA_DEMO_NO_MTIME )
void vPortSetupTimerInterrupt( void ) {
    volatile uint32_t * const mmio_msip = ( volatile uint32_t * ) 0x40000018u;
    volatile uint32_t * const mmio_meip = ( volatile uint32_t * ) 0x4000001Cu;
    volatile uint32_t * const mmio_mtimecmp_lo = ( volatile uint32_t * ) 0x40000028u;
    volatile uint32_t * const mmio_mtimecmp_hi = ( volatile uint32_t * ) 0x4000002Cu;
    volatile uint32_t * const uart_rx_data = ( volatile uint32_t * ) 0x40000008u;
    volatile uint32_t * const uart_rx_status = ( volatile uint32_t * ) 0x4000000Cu;
    uint32_t i;

    __asm volatile ( "csrci mstatus, 8" );
    __asm volatile ( "csrw mie, zero" );

    *mmio_msip = 0u;
    *mmio_meip = 0u;
    *mmio_mtimecmp_lo = 0xFFFFFFFFu;
    *mmio_mtimecmp_hi = 0xFFFFFFFFu;

    for( i = 0u; i < 16u; i++ ) {
        if( ( *uart_rx_status & 1u ) == 0u ) {
            break;
        }
        ( void ) *uart_rx_data;
    }
}
#endif

void vAssertCalled( const char * file, unsigned long line ) {
    uintptr_t caller_ra;
    uintptr_t current_sp;

    __asm volatile ( "mv %0, ra" : "=r" ( caller_ra ) );
    __asm volatile ( "mv %0, sp" : "=r" ( current_sp ) );
    __asm volatile ( "csrc mstatus, 8" );
    rtos_uart_write( "[RTOS] assert file=" );
    rtos_uart_write_hex32( ( uint32_t ) ( uintptr_t ) file );
    rtos_uart_write( " line=" );
    rtos_uart_write_hex32( ( uint32_t ) line );
    rtos_uart_write( " ra=" );
    rtos_uart_write_hex32( ( uint32_t ) caller_ra );
    rtos_uart_write( " tcb=" );
    rtos_uart_write_hex32( ( uint32_t ) ( uintptr_t ) pxCurrentTCB );
    rtos_uart_write( " sp=" );
    rtos_uart_write_hex32( ( uint32_t ) current_sp );
    rtos_uart_write( "\n" );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

void vApplicationGetIdleTaskMemory( StaticTask_t ** idle_tcb_buffer,
                                    StackType_t ** idle_stack_buffer,
                                    configSTACK_DEPTH_TYPE * idle_stack_size ) {
    *idle_tcb_buffer = &idle_tcb;
    *idle_stack_buffer = idle_stack;
    *idle_stack_size = RTOS_IDLE_STACK_WORDS;
}

void vApplicationStackOverflowHook( TaskHandle_t task, char * task_name ) {
    ( void ) task;

    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[RTOS] stack overflow " );
    rtos_uart_write_line( task_name ? task_name : "(unknown)" );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

void freertos_risc_v_application_exception_handler( uint32_t mcause, uint32_t mepc ) {
    uintptr_t current_sp;
    uint32_t mtval;
    uint32_t mstatus;
    uint32_t mie;
    uint32_t mip;

    __asm volatile ( "mv %0, sp" : "=r" ( current_sp ) );
    __asm volatile ( "csrr %0, mtval" : "=r" ( mtval ) );
    __asm volatile ( "csrr %0, mstatus" : "=r" ( mstatus ) );
    __asm volatile ( "csrr %0, mie" : "=r" ( mie ) );
    __asm volatile ( "csrr %0, mip" : "=r" ( mip ) );
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[RTOS] exception mcause=" );
    rtos_uart_write_hex32( mcause );
    rtos_uart_write( " mepc=" );
    rtos_uart_write_hex32( mepc );
    rtos_uart_write( " mtval=" );
    rtos_uart_write_hex32( mtval );
    rtos_uart_write( " mstatus=" );
    rtos_uart_write_hex32( mstatus );
    rtos_uart_write( " mie=" );
    rtos_uart_write_hex32( mie );
    rtos_uart_write( " mip=" );
    rtos_uart_write_hex32( mip );
    rtos_uart_write( " tcb=" );
    rtos_uart_write_hex32( ( uint32_t ) ( uintptr_t ) pxCurrentTCB );
    rtos_uart_write( " sp=" );
    rtos_uart_write_hex32( ( uint32_t ) current_sp );
    rtos_uart_write( "\n" );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

void freertos_risc_v_application_interrupt_handler( uint32_t mcause ) {
    uintptr_t current_sp;
    uint32_t mepc;
    uint32_t mtval;
    uint32_t mstatus;
    uint32_t mie;
    uint32_t mip;

    __asm volatile ( "mv %0, sp" : "=r" ( current_sp ) );
    __asm volatile ( "csrr %0, mepc" : "=r" ( mepc ) );
    __asm volatile ( "csrr %0, mtval" : "=r" ( mtval ) );
    __asm volatile ( "csrr %0, mstatus" : "=r" ( mstatus ) );
    __asm volatile ( "csrr %0, mie" : "=r" ( mie ) );
    __asm volatile ( "csrr %0, mip" : "=r" ( mip ) );
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[RTOS] unexpected interrupt mcause=" );
    rtos_uart_write_hex32( mcause );
    rtos_uart_write( " mepc=" );
    rtos_uart_write_hex32( mepc );
    rtos_uart_write( " mtval=" );
    rtos_uart_write_hex32( mtval );
    rtos_uart_write( " mstatus=" );
    rtos_uart_write_hex32( mstatus );
    rtos_uart_write( " mie=" );
    rtos_uart_write_hex32( mie );
    rtos_uart_write( " mip=" );
    rtos_uart_write_hex32( mip );
    rtos_uart_write( " tcb=" );
    rtos_uart_write_hex32( ( uint32_t ) ( uintptr_t ) pxCurrentTCB );
    rtos_uart_write( " sp=" );
    rtos_uart_write_hex32( ( uint32_t ) current_sp );
    rtos_uart_write( "\n" );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}
