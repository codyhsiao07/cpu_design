#include "FreeRTOS.h"
#include "task.h"
#include "uart.h"
#include "vga_fb.h"

#define RTOS_VGA_TASK_STACK_WORDS 512u

#define COLOR_BG      0u
#define COLOR_HEADER  1u
#define COLOR_PANEL   8u
#define COLOR_LEFT    2u
#define COLOR_MIDDLE  4u
#define COLOR_RIGHT   14u
#define COLOR_FRAME   6u
#define COLOR_TRACE   15u

static StaticTask_t left_tcb;
static StaticTask_t middle_tcb;
static StaticTask_t right_tcb;
static StackType_t left_stack[ RTOS_VGA_TASK_STACK_WORDS ];
static StackType_t middle_stack[ RTOS_VGA_TASK_STACK_WORDS ];
static StackType_t right_stack[ RTOS_VGA_TASK_STACK_WORDS ];

static volatile uint32_t left_frames;
static volatile uint32_t middle_frames;
static volatile uint32_t right_frames;

static void draw_panel_static( void ) {
    vga_fb_set_draw_buffer( 0u );
    vga_fb_clear( COLOR_BG );
    vga_fb_fill_rect4( 0u, 0u, 160u, 16u, COLOR_HEADER );
    vga_fb_fill_rect4( 0u, 17u, 160u, 2u, COLOR_FRAME );
    vga_fb_fill_rect4( 0u, 20u, 48u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 56u, 20u, 48u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 112u, 20u, 48u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 52u, 20u, 4u, 88u, COLOR_FRAME );
    vga_fb_fill_rect4( 108u, 20u, 4u, 88u, COLOR_FRAME );
    vga_fb_present();
}

static void draw_left_frame( uint32_t phase ) {
    uint32_t y = ( ( phase & 1u ) == 0u ) ? 28u : 72u;
    uint32_t mark_x = 4u + ( ( phase & 7u ) * 4u );

    vga_fb_fill_rect4( 4u, 20u, 40u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 8u, y, 32u, 24u, COLOR_LEFT );
    vga_fb_fill_rect4( mark_x, 104u, 4u, 4u, COLOR_TRACE );
    vga_fb_present();
}

static void draw_middle_frame( uint32_t phase ) {
    uint32_t y = ( ( phase & 1u ) == 0u ) ? 72u : 28u;
    uint32_t mark_x = 60u + ( ( phase & 7u ) * 4u );

    vga_fb_fill_rect4( 60u, 20u, 40u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 64u, y, 32u, 24u, COLOR_MIDDLE );
    vga_fb_fill_rect4( mark_x, 104u, 4u, 4u, COLOR_TRACE );
    vga_fb_present();
}

static void draw_right_frame( uint32_t phase ) {
    uint32_t y = ( ( phase & 1u ) == 0u ) ? 72u : 28u;
    uint32_t mark_x = 116u + ( ( phase & 7u ) * 4u );

    vga_fb_fill_rect4( 116u, 20u, 40u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 120u, y, 32u, 24u, COLOR_RIGHT );
    vga_fb_fill_rect4( mark_x, 104u, 4u, 4u, COLOR_TRACE );
    vga_fb_present();
}

static void log_frame( const char * task_name, uint32_t frame ) {
    taskENTER_CRITICAL();
    rtos_uart_write( "[VGA] tick=" );
    rtos_uart_write_hex32( ( uint32_t ) xTaskGetTickCount() );
    rtos_uart_write( " task=" );
    rtos_uart_write( task_name );
    rtos_uart_write( " frame=" );
    rtos_uart_write_hex32( frame );
    rtos_uart_write( "\n" );
    taskEXIT_CRITICAL();
}

static void left_task( void * arg ) {
    ( void ) arg;

    taskENTER_CRITICAL();
    rtos_uart_write_line( "[VGA] task=L start" );
    taskEXIT_CRITICAL();

    for( ;; ) {
        left_frames++;
        draw_left_frame( left_frames );
        if( ( left_frames & 3u ) == 0u ) {
            log_frame( "L", left_frames );
        }
        vTaskDelay( pdMS_TO_TICKS( 500u ) );
    }
}

static void middle_task( void * arg ) {
    ( void ) arg;

    taskENTER_CRITICAL();
    rtos_uart_write_line( "[VGA] task=M start" );
    taskEXIT_CRITICAL();

    for( ;; ) {
        middle_frames++;
        draw_middle_frame( middle_frames );
        if( ( middle_frames & 3u ) == 0u ) {
            log_frame( "M", middle_frames );
        }
        vTaskDelay( pdMS_TO_TICKS( 600u ) );
    }
}

static void right_task( void * arg ) {
    ( void ) arg;

    taskENTER_CRITICAL();
    rtos_uart_write_line( "[VGA] task=R start" );
    taskEXIT_CRITICAL();

    for( ;; ) {
        right_frames++;
        draw_right_frame( right_frames );
        if( ( right_frames & 3u ) == 0u ) {
            log_frame( "R", right_frames );
        }
        vTaskDelay( pdMS_TO_TICKS( 700u ) );
    }
}

static void fatal( const char * reason ) {
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[VGA] fatal " );
    rtos_uart_write_line( reason );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

int main( void ) {
    TaskHandle_t handle;

    rtos_uart_write_line( "[VGA] RTOS VGA multitask demo boot" );
    draw_panel_static();

    handle = xTaskCreateStatic( left_task, "VGA-L", RTOS_VGA_TASK_STACK_WORDS, NULL, 2u, left_stack, &left_tcb );
    if( handle == NULL ) {
        fatal( "taskL" );
    }
    rtos_uart_write_line( "[VGA] taskL" );

    handle = xTaskCreateStatic( middle_task, "VGA-M", RTOS_VGA_TASK_STACK_WORDS, NULL, 2u, middle_stack, &middle_tcb );
    if( handle == NULL ) {
        fatal( "taskM" );
    }
    rtos_uart_write_line( "[VGA] taskM" );

    handle = xTaskCreateStatic( right_task, "VGA-R", RTOS_VGA_TASK_STACK_WORDS, NULL, 2u, right_stack, &right_tcb );
    if( handle == NULL ) {
        fatal( "taskR" );
    }
    rtos_uart_write_line( "[VGA] taskR" );

    rtos_uart_write_line( "[VGA] scheduler" );
    vTaskStartScheduler();
    fatal( "scheduler_return" );
    return 1;
}
