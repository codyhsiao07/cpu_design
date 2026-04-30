#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "uart.h"
#include "vga_fb.h"

#define PIPE_TASK_STACK_WORDS 512u
#define PIPE_QUEUE_LENGTH     6u

#define COLOR_BG        0u
#define COLOR_HEADER    1u
#define COLOR_PANEL     8u
#define COLOR_FRAME     6u
#define COLOR_PRODUCER  2u
#define COLOR_RENDERER  14u
#define COLOR_HEART     4u
#define COLOR_TRACE     15u
#define COLOR_WARN      12u
#define COLOR_TEXT      15u
#define COLOR_DIM       7u

typedef struct PipelineEvent {
    uint32_t seq;
    uint32_t level;
    uint32_t color;
} PipelineEvent_t;

static StaticTask_t producer_tcb;
static StaticTask_t renderer_tcb;
static StaticTask_t heartbeat_tcb;
static StackType_t producer_stack[ PIPE_TASK_STACK_WORDS ];
static StackType_t renderer_stack[ PIPE_TASK_STACK_WORDS ];
static StackType_t heartbeat_stack[ PIPE_TASK_STACK_WORDS ];

static StaticQueue_t event_queue_tcb;
static uint8_t event_queue_storage[ PIPE_QUEUE_LENGTH * sizeof( PipelineEvent_t ) ];
static QueueHandle_t event_queue;

static volatile uint32_t produced_count;
static volatile uint32_t rendered_count;
static volatile uint32_t dropped_count;
static volatile uint32_t heartbeat_count;

static uint8_t block_glyph_rows( char ch, uint32_t row ) {
    static const uint8_t blank[ 7 ] = { 0u, 0u, 0u, 0u, 0u, 0u, 0u };
    static const uint8_t zero[ 7 ] = { 14u, 17u, 19u, 21u, 25u, 17u, 14u };
    static const uint8_t one[ 7 ] = { 4u, 12u, 4u, 4u, 4u, 4u, 14u };
    static const uint8_t two[ 7 ] = { 14u, 17u, 1u, 2u, 4u, 8u, 31u };
    static const uint8_t three[ 7 ] = { 30u, 1u, 1u, 14u, 1u, 1u, 30u };
    static const uint8_t four[ 7 ] = { 2u, 6u, 10u, 18u, 31u, 2u, 2u };
    static const uint8_t five[ 7 ] = { 31u, 16u, 16u, 30u, 1u, 1u, 30u };
    static const uint8_t six[ 7 ] = { 14u, 16u, 16u, 30u, 17u, 17u, 14u };
    static const uint8_t seven[ 7 ] = { 31u, 1u, 2u, 4u, 8u, 8u, 8u };
    static const uint8_t eight[ 7 ] = { 14u, 17u, 17u, 14u, 17u, 17u, 14u };
    static const uint8_t nine[ 7 ] = { 14u, 17u, 17u, 15u, 1u, 1u, 14u };
    static const uint8_t glyph_a[ 7 ] = { 14u, 17u, 17u, 31u, 17u, 17u, 17u };
    static const uint8_t glyph_b[ 7 ] = { 30u, 17u, 17u, 30u, 17u, 17u, 30u };
    static const uint8_t glyph_c[ 7 ] = { 14u, 17u, 16u, 16u, 16u, 17u, 14u };
    static const uint8_t glyph_d[ 7 ] = { 30u, 17u, 17u, 17u, 17u, 17u, 30u };
    static const uint8_t glyph_e[ 7 ] = { 31u, 16u, 16u, 30u, 16u, 16u, 31u };
    static const uint8_t glyph_f[ 7 ] = { 31u, 16u, 16u, 30u, 16u, 16u, 16u };
    static const uint8_t glyph_h[ 7 ] = { 17u, 17u, 17u, 31u, 17u, 17u, 17u };
    static const uint8_t glyph_p[ 7 ] = { 30u, 17u, 17u, 30u, 16u, 16u, 16u };
    static const uint8_t glyph_q[ 7 ] = { 14u, 17u, 17u, 17u, 21u, 18u, 13u };
    static const uint8_t glyph_r[ 7 ] = { 30u, 17u, 17u, 30u, 20u, 18u, 17u };
    const uint8_t * rows = blank;

    switch( ch ) {
        case '0': rows = zero; break;
        case '1': rows = one; break;
        case '2': rows = two; break;
        case '3': rows = three; break;
        case '4': rows = four; break;
        case '5': rows = five; break;
        case '6': rows = six; break;
        case '7': rows = seven; break;
        case '8': rows = eight; break;
        case '9': rows = nine; break;
        case 'A': rows = glyph_a; break;
        case 'B': rows = glyph_b; break;
        case 'C': rows = glyph_c; break;
        case 'D': rows = glyph_d; break;
        case 'E': rows = glyph_e; break;
        case 'F': rows = glyph_f; break;
        case 'H': rows = glyph_h; break;
        case 'P': rows = glyph_p; break;
        case 'Q': rows = glyph_q; break;
        case 'R': rows = glyph_r; break;
        default: rows = blank; break;
    }

    return rows[ row ];
}

static void draw_block_char( uint32_t x, uint32_t y, char ch, uint8_t color ) {
    uint32_t row;
    uint32_t col;
    uint8_t bits;

    for( row = 0u; row < 7u; row++ ) {
        bits = block_glyph_rows( ch, row );
        for( col = 0u; col < 5u; col++ ) {
            if( ( bits & ( 1u << ( 4u - col ) ) ) != 0u ) {
                vga_fb_fill_rect4( x + ( col * 4u ), y + row, 4u, 1u, color );
            }
        }
    }
}

static void draw_arrow( uint32_t x, uint32_t y, uint8_t color ) {
    vga_fb_fill_rect4( x, y + 4u, 8u, 4u, color );
    vga_fb_fill_rect4( x + 8u, y, 4u, 12u, color );
}

static void draw_small_arrow( uint32_t x, uint32_t y, uint8_t color ) {
    vga_fb_fill_rect4( x, y + 3u, 8u, 1u, color );
    vga_fb_fill_rect4( x + 8u, y + 1u, 4u, 5u, color );
}

static void draw_phase_bar( uint32_t x, uint32_t y, uint32_t phase, uint8_t color ) {
    uint32_t i;
    uint32_t active = phase & 7u;

    for( i = 0u; i < 8u; i++ ) {
        vga_fb_fill_rect4( x + ( i * 4u ), y, 4u, 5u, COLOR_DIM );
    }
    vga_fb_fill_rect4( x + ( active * 4u ), y, 4u, 5u, color );
}

static void uart_log_u32( const char * tag, const char * op, uint32_t value ) {
    taskENTER_CRITICAL();
    rtos_uart_write( "[PIPE] tick=" );
    rtos_uart_write_hex32( ( uint32_t ) xTaskGetTickCount() );
    rtos_uart_write( " task=" );
    rtos_uart_write( tag );
    rtos_uart_write( " " );
    rtos_uart_write( op );
    rtos_uart_write( "=" );
    rtos_uart_write_hex32( value );
    rtos_uart_write( "\n" );
    taskEXIT_CRITICAL();
}

static void draw_static_screen( void ) {
    vga_fb_set_draw_buffer( 0u );
    vga_fb_clear( COLOR_BG );

    vga_fb_fill_rect4( 0u, 0u, 160u, 12u, COLOR_HEADER );
    vga_fb_fill_rect4( 0u, 13u, 160u, 2u, COLOR_FRAME );

    vga_fb_fill_rect4( 0u, 18u, 48u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 56u, 18u, 48u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 112u, 18u, 48u, 88u, COLOR_PANEL );
    vga_fb_fill_rect4( 52u, 18u, 4u, 88u, COLOR_FRAME );
    vga_fb_fill_rect4( 108u, 18u, 4u, 88u, COLOR_FRAME );

    draw_block_char( 8u, 3u, 'P', COLOR_PRODUCER );
    draw_small_arrow( 32u, 4u, COLOR_TRACE );
    draw_block_char( 48u, 3u, 'Q', COLOR_TEXT );
    draw_small_arrow( 72u, 4u, COLOR_TRACE );
    draw_block_char( 88u, 3u, 'R', COLOR_RENDERER );
    draw_block_char( 132u, 3u, 'H', COLOR_HEART );

    draw_arrow( 44u, 52u, COLOR_PRODUCER );
    draw_arrow( 100u, 52u, COLOR_RENDERER );
    draw_phase_bar( 8u, 108u, 0u, COLOR_PRODUCER );
    draw_phase_bar( 64u, 108u, 0u, COLOR_RENDERER );
    draw_phase_bar( 120u, 108u, 0u, COLOR_HEART );
    vga_fb_present();
}

static void draw_producer_state( uint32_t seq, uint32_t sent_ok ) {
    uint32_t x = 4u + ( ( seq & 7u ) * 4u );
    uint32_t h = 8u + ( ( seq & 7u ) * 8u );
    uint32_t y = 98u - h;
    uint32_t color = sent_ok ? COLOR_PRODUCER : COLOR_WARN;

    vga_fb_fill_rect4( 4u, 40u, 40u, 62u, COLOR_PANEL );
    vga_fb_fill_rect4( x, 96u, 4u, 6u, COLOR_TRACE );
    draw_phase_bar( 8u, 108u, seq, color );
    vga_fb_fill_rect4( 16u, y, 16u, h, color );
    vga_fb_present();
}

static void draw_renderer_event( const PipelineEvent_t * event ) {
    uint32_t slot = event->seq % PIPE_QUEUE_LENGTH;
    uint32_t x = 60u + ( slot * 4u );
    uint32_t h = 12u + ( ( event->level & 7u ) * 8u );
    uint32_t y = 98u - h;
    uint32_t i;

    vga_fb_fill_rect4( 60u, 40u, 40u, 62u, COLOR_PANEL );

    for( i = 0u; i < PIPE_QUEUE_LENGTH; i++ ) {
        vga_fb_fill_rect4( 60u + ( i * 4u ), 40u, 4u, 8u, COLOR_DIM );
    }
    vga_fb_fill_rect4( x, 40u, 4u, 8u, COLOR_TRACE );
    draw_phase_bar( 64u, 108u, event->seq, COLOR_RENDERER );
    vga_fb_fill_rect4( 72u, y, 16u, h, ( uint8_t ) event->color );
    vga_fb_present();
}

static void draw_heartbeat_state( uint32_t beat ) {
    uint32_t x = 116u + ( ( beat & 7u ) * 4u );
    uint32_t y = ( ( beat & 1u ) == 0u ) ? 34u : 70u;

    vga_fb_fill_rect4( 116u, 40u, 40u, 62u, COLOR_PANEL );
    vga_fb_fill_rect4( 124u, y, 24u, 20u, COLOR_HEART );
    vga_fb_fill_rect4( x, 96u, 4u, 6u, COLOR_TRACE );
    draw_phase_bar( 120u, 108u, beat, COLOR_HEART );
    vga_fb_present();
}

static void producer_task( void * arg ) {
    PipelineEvent_t event;
    BaseType_t ok;
    ( void ) arg;

    taskENTER_CRITICAL();
    rtos_uart_write_line( "[PIPE] task=P producer start" );
    taskEXIT_CRITICAL();

    event.seq = 0u;
    for( ;; ) {
        event.seq++;
        event.level = event.seq & 7u;
        event.color = 2u + ( event.seq % 12u );
        if( event.color == COLOR_PANEL ) {
            event.color = COLOR_TRACE;
        }

        ok = xQueueSend( event_queue, &event, pdMS_TO_TICKS( 10u ) );
        if( ok == pdPASS ) {
            produced_count++;
            draw_producer_state( event.seq, 1u );
            if( ( produced_count & 3u ) == 0u ) {
                uart_log_u32( "P", "send", event.seq );
            }
        } else {
            dropped_count++;
            draw_producer_state( event.seq, 0u );
            uart_log_u32( "P", "drop", dropped_count );
        }

        vTaskDelay( pdMS_TO_TICKS( 250u ) );
    }
}

static void renderer_task( void * arg ) {
    PipelineEvent_t event;
    ( void ) arg;

    taskENTER_CRITICAL();
    rtos_uart_write_line( "[PIPE] task=R renderer start" );
    taskEXIT_CRITICAL();

    for( ;; ) {
        if( xQueueReceive( event_queue, &event, portMAX_DELAY ) == pdPASS ) {
            rendered_count++;
            draw_renderer_event( &event );
            if( ( rendered_count & 3u ) == 0u ) {
                uart_log_u32( "R", "recv", event.seq );
            }
        }
    }
}

static void heartbeat_task( void * arg ) {
    ( void ) arg;

    taskENTER_CRITICAL();
    rtos_uart_write_line( "[PIPE] task=H heartbeat start" );
    taskEXIT_CRITICAL();

    for( ;; ) {
        heartbeat_count++;
        draw_heartbeat_state( heartbeat_count );
        uart_log_u32( "H", "beat", heartbeat_count );
        vTaskDelay( pdMS_TO_TICKS( 1000u ) );
    }
}

static void fatal( const char * reason ) {
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[PIPE] fatal " );
    rtos_uart_write_line( reason );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

int main( void ) {
    TaskHandle_t handle;

    rtos_uart_write_line( "[PIPE] RTOS queue VGA pipeline boot" );
    draw_static_screen();

    event_queue = xQueueCreateStatic(
        PIPE_QUEUE_LENGTH,
        sizeof( PipelineEvent_t ),
        event_queue_storage,
        &event_queue_tcb
    );
    if( event_queue == NULL ) {
        fatal( "queue" );
    }
    rtos_uart_write_line( "[PIPE] queue" );

    handle = xTaskCreateStatic( producer_task, "PIPE-P", PIPE_TASK_STACK_WORDS, NULL, 2u, producer_stack, &producer_tcb );
    if( handle == NULL ) {
        fatal( "producer" );
    }
    rtos_uart_write_line( "[PIPE] producer" );

    handle = xTaskCreateStatic( renderer_task, "PIPE-R", PIPE_TASK_STACK_WORDS, NULL, 3u, renderer_stack, &renderer_tcb );
    if( handle == NULL ) {
        fatal( "renderer" );
    }
    rtos_uart_write_line( "[PIPE] renderer" );

    handle = xTaskCreateStatic( heartbeat_task, "PIPE-H", PIPE_TASK_STACK_WORDS, NULL, 2u, heartbeat_stack, &heartbeat_tcb );
    if( handle == NULL ) {
        fatal( "heartbeat" );
    }
    rtos_uart_write_line( "[PIPE] heartbeat" );

    rtos_uart_write_line( "[PIPE] scheduler" );
    vTaskStartScheduler();
    fatal( "scheduler_return" );
    return 1;
}
