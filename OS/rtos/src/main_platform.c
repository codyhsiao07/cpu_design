#include <stddef.h>
#include <stdint.h>

#include "FreeRTOS.h"
#include "event_groups.h"
#include "queue.h"
#include "semphr.h"
#include "stream_buffer.h"
#include "task.h"
#include "timers.h"
#include "board_control.h"
#include "uart.h"

#define PLATFORM_WORKER_STACK_WORDS       384u
#define PLATFORM_COORD_STACK_WORDS        640u
#define PLATFORM_DYNAMIC_STACK_WORDS      384u
#define PLATFORM_WORK_ITERATIONS          250u
#define PLATFORM_STREAM_BYTES             32u
#define PLATFORM_LINE_BYTES               32u
#define PLATFORM_WAIT_TICKS               100u

#define EVENT_START                       ( 1u << 0u )
#define EVENT_WORKER_A                     ( 1u << 1u )
#define EVENT_WORKER_B                     ( 1u << 2u )
#define EVENT_STREAM                       ( 1u << 3u )
#define EVENT_TIMER                        ( 1u << 4u )
#define EVENT_ALL_RESULTS                  ( EVENT_WORKER_A | EVENT_WORKER_B | EVENT_STREAM | EVENT_TIMER )

extern void * malloc( size_t size );
extern void free( void * ptr );
extern void * calloc( size_t count, size_t size );
extern void * realloc( void * ptr, size_t size );

static StaticTask_t worker_a_tcb;
static StaticTask_t worker_b_tcb;
static StaticTask_t coordinator_tcb;
static StackType_t worker_a_stack[ PLATFORM_WORKER_STACK_WORDS ];
static StackType_t worker_b_stack[ PLATFORM_WORKER_STACK_WORDS ];
static StackType_t coordinator_stack[ PLATFORM_COORD_STACK_WORDS ];
static TaskHandle_t worker_a_handle;
static TaskHandle_t worker_b_handle;

static StaticSemaphore_t mutex_tcb;
static StaticSemaphore_t recursive_mutex_tcb;
static StaticSemaphore_t completion_sem_tcb;
static SemaphoreHandle_t test_mutex;
static SemaphoreHandle_t test_recursive_mutex;
static SemaphoreHandle_t completion_sem;
static QueueSetHandle_t completion_set;

static StaticEventGroup_t event_group_tcb;
static EventGroupHandle_t test_events;

static StaticStreamBuffer_t stream_tcb;
static uint8_t stream_storage[ PLATFORM_STREAM_BYTES ];
static StreamBufferHandle_t test_stream;

static StaticTimer_t timer_tcb;
static TimerHandle_t test_timer;

static volatile uint32_t shared_counter;
static volatile uint32_t self_test_complete;
static const uint8_t stream_pattern[] = {
    0x12u, 0x34u, 0x56u, 0x78u, 0x9Au, 0xBCu, 0xDEu, 0xF0u,
    0x55u, 0xAAu, 0xC3u, 0x3Cu
};

static void platform_fail( const char * reason ) __attribute__( ( noreturn ) );

static int text_equal( const char * a, const char * b ) {
    while( ( *a != '\0' ) && ( *a == *b ) ) {
        a++;
        b++;
    }
    return *a == *b;
}

static void platform_fail( const char * reason ) {
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[PLATFORM] FAIL reason=" );
    rtos_uart_write_line( reason );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

static void worker_task( void * arg ) {
    uint32_t worker_id = ( uint32_t ) ( uintptr_t ) arg;
    uint32_t i;
    EventBits_t done_bit = ( worker_id == 0u ) ? EVENT_WORKER_A : EVENT_WORKER_B;

    ( void ) xEventGroupWaitBits( test_events, EVENT_START, pdFALSE, pdTRUE, portMAX_DELAY );
    for( i = 0u; i < PLATFORM_WORK_ITERATIONS; i++ ) {
        if( xSemaphoreTake( test_mutex, portMAX_DELAY ) != pdPASS ) {
            platform_fail( "mutex_take" );
        }
        shared_counter++;
        if( xSemaphoreGive( test_mutex ) != pdPASS ) {
            platform_fail( "mutex_give" );
        }
        if( ( i & 0xFu ) == 0u ) {
            taskYIELD();
        }
    }

    if( xSemaphoreGive( completion_sem ) != pdPASS ) {
        platform_fail( "completion_give" );
    }
    ( void ) xEventGroupSetBits( test_events, done_bit );
    vTaskSuspend( NULL );
    platform_fail( "worker_resume" );
}

static void dynamic_stream_task( void * arg ) {
    uint8_t received[ sizeof( stream_pattern ) ];
    size_t total = 0u;
    size_t i;
    ( void ) arg;

    while( total < sizeof( received ) ) {
        size_t count = xStreamBufferReceive(
            test_stream,
            &received[ total ],
            sizeof( received ) - total,
            portMAX_DELAY
        );
        if( count == 0u ) {
            platform_fail( "stream_receive" );
        }
        total += count;
    }
    for( i = 0u; i < sizeof( received ); i++ ) {
        if( received[ i ] != stream_pattern[ i ] ) {
            platform_fail( "stream_data" );
        }
    }
    ( void ) xEventGroupSetBits( test_events, EVENT_STREAM );
    vTaskDelete( NULL );
}

static void timer_callback( TimerHandle_t timer ) {
    ( void ) timer;
    ( void ) xEventGroupSetBits( test_events, EVENT_TIMER );
}

static void test_c_heap( void ) {
    uint8_t * block;
    uint8_t * zero_block;
    size_t i;

    block = ( uint8_t * ) malloc( 64u );
    if( block == NULL ) {
        platform_fail( "malloc" );
    }
    for( i = 0u; i < 64u; i++ ) {
        block[ i ] = ( uint8_t ) ( i ^ 0xA5u );
    }
    block = ( uint8_t * ) realloc( block, 160u );
    if( block == NULL ) {
        platform_fail( "realloc" );
    }
    for( i = 0u; i < 64u; i++ ) {
        if( block[ i ] != ( uint8_t ) ( i ^ 0xA5u ) ) {
            platform_fail( "realloc_data" );
        }
    }
    zero_block = ( uint8_t * ) calloc( 32u, 4u );
    if( zero_block == NULL ) {
        platform_fail( "calloc" );
    }
    for( i = 0u; i < 128u; i++ ) {
        if( zero_block[ i ] != 0u ) {
            platform_fail( "calloc_data" );
        }
    }
    free( zero_block );
    free( block );
}

static void print_platform_stats( void ) {
    rtos_uart_write( "PLATFORM_STATS tick=" );
    rtos_uart_write_u32( ( uint32_t ) xTaskGetTickCount() );
    rtos_uart_write( " tasks=" );
    rtos_uart_write_u32( ( uint32_t ) uxTaskGetNumberOfTasks() );
    rtos_uart_write( " heap_free=" );
    rtos_uart_write_u32( ( uint32_t ) xPortGetFreeHeapSize() );
    rtos_uart_write( " heap_min=" );
    rtos_uart_write_u32( ( uint32_t ) xPortGetMinimumEverFreeHeapSize() );
    rtos_uart_write( " irq=" );
    rtos_uart_write_u32( rtos_uart_rx_interrupt_count() );
    rtos_uart_write( " hw_overrun=" );
    rtos_uart_write_u32( rtos_uart_rx_hardware_overrun_count() );
    rtos_uart_write( " stream_drop=" );
    rtos_uart_write_u32( rtos_uart_rx_stream_drop_count() );
    rtos_uart_write( "\n" );
}

static void interactive_loop( void ) {
    char line[ PLATFORM_LINE_BYTES ];
    uint32_t length = 0u;

    rtos_uart_write_line( "Commands: irqping, stats, reload" );
    rtos_uart_write( "platform> " );
    for( ;; ) {
        char value;
        uint32_t overrun = 0u;

        if( rtos_uart_getc( &value, portMAX_DELAY, &overrun ) == 0 ) {
            continue;
        }
        if( overrun != 0u ) {
            rtos_uart_write_line( "[PLATFORM] UART_RX_OVERRUN" );
        }
        if( ( value == '\r' ) || ( value == '\n' ) ) {
            if( length == 0u ) {
                continue;
            }
            line[ length ] = '\0';
            rtos_uart_write( "\n" );
            if( text_equal( line, "irqping" ) ) {
                rtos_uart_write( "UART_IRQ_PASS count=" );
                rtos_uart_write_u32( rtos_uart_rx_interrupt_count() );
                rtos_uart_write( "\n" );
            } else if( text_equal( line, "stats" ) ) {
                print_platform_stats();
            } else if( text_equal( line, "reload" ) ) {
                rtos_uart_write_line( "RELOADING" );
                rtos_board_request_image_reload();
            } else {
                rtos_uart_write_line( "ERR expected: irqping, stats, reload" );
            }
            length = 0u;
            rtos_uart_write( "platform> " );
        } else if( ( value >= ' ' ) && ( value <= '~' ) ) {
            rtos_uart_putc( value );
            if( length < ( PLATFORM_LINE_BYTES - 1u ) ) {
                line[ length++ ] = value;
            }
        }
    }
}

static void coordinator_task( void * arg ) {
    EventBits_t bits;
    uint32_t irq_before;
    uint32_t runtime_total = 0u;
    uint32_t completions;
    UBaseType_t task_count;
    TaskStatus_t task_status[ 12 ];
    ( void ) arg;

    rtos_uart_write_line( "[PLATFORM] test=heap begin" );
    test_c_heap();
    if( xPortGetFreeHeapSize() < ( 1024u * 1024u ) ) {
        platform_fail( "heap_capacity" );
    }
    rtos_uart_write_line( "[PLATFORM] test=heap pass" );

    if( xSemaphoreTakeRecursive( test_recursive_mutex, 0u ) != pdPASS ) {
        platform_fail( "recursive_take_1" );
    }
    if( xSemaphoreTakeRecursive( test_recursive_mutex, 0u ) != pdPASS ) {
        platform_fail( "recursive_take_2" );
    }
    if( xSemaphoreGiveRecursive( test_recursive_mutex ) != pdPASS ) {
        platform_fail( "recursive_give_1" );
    }
    if( xSemaphoreGiveRecursive( test_recursive_mutex ) != pdPASS ) {
        platform_fail( "recursive_give_2" );
    }
    rtos_uart_write_line( "[PLATFORM] test=recursive-mutex pass" );

    if( xStreamBufferSend( test_stream, stream_pattern, sizeof( stream_pattern ), 0u ) !=
        sizeof( stream_pattern ) ) {
        platform_fail( "stream_send" );
    }
    if( xTimerStart( test_timer, 0u ) != pdPASS ) {
        platform_fail( "timer_start" );
    }
    ( void ) xEventGroupSetBits( test_events, EVENT_START );

    irq_before = rtos_uart_rx_interrupt_count();
    rtos_uart_trigger_test_interrupt();
    vTaskDelay( 2u );
    if( rtos_uart_rx_interrupt_count() <= irq_before ) {
        platform_fail( "external_irq" );
    }
    rtos_uart_write_line( "[PLATFORM] test=external-irq pass" );

    bits = xEventGroupWaitBits(
        test_events,
        EVENT_ALL_RESULTS,
        pdFALSE,
        pdTRUE,
        PLATFORM_WAIT_TICKS
    );
    if( ( bits & EVENT_ALL_RESULTS ) != EVENT_ALL_RESULTS ) {
        platform_fail( "event_timeout" );
    }

    for( completions = 0u; completions < 2u; completions++ ) {
        QueueSetMemberHandle_t member = xQueueSelectFromSet( completion_set, 0u );
        if( member != ( QueueSetMemberHandle_t ) completion_sem ) {
            platform_fail( "queue_set_select" );
        }
        if( xSemaphoreTake( completion_sem, 0u ) != pdPASS ) {
            platform_fail( "counting_semaphore" );
        }
    }
    if( shared_counter != ( 2u * PLATFORM_WORK_ITERATIONS ) ) {
        platform_fail( "mutex_counter" );
    }
    rtos_uart_write_line( "[PLATFORM] test=sync-event-stream-timer pass" );

    vTaskDelay( 2u );
    if( eTaskGetState( worker_a_handle ) != eSuspended ||
        eTaskGetState( worker_b_handle ) != eSuspended ) {
        platform_fail( "task_state" );
    }
    if( uxTaskGetStackHighWaterMark( NULL ) == 0u ||
        uxTaskGetStackHighWaterMark( worker_a_handle ) == 0u ||
        uxTaskGetStackHighWaterMark( worker_b_handle ) == 0u ) {
        platform_fail( "stack_watermark" );
    }
    task_count = uxTaskGetSystemState( task_status, 12u, &runtime_total );
    if( task_count < 5u || runtime_total == 0u ) {
        platform_fail( "runtime_stats" );
    }
    rtos_uart_write( "[PLATFORM] test=diagnostics pass tasks=" );
    rtos_uart_write_u32( ( uint32_t ) task_count );
    rtos_uart_write( " runtime=" );
    rtos_uart_write_u32( runtime_total );
    rtos_uart_write( "\n" );

    self_test_complete = 1u;
    print_platform_stats();
    rtos_uart_write_line( "RTOS_PLATFORM_PASS" );
    interactive_loop();
}

int main( void ) {
    TaskHandle_t dynamic_handle;

    rtos_uart_write_line( "RTOS_PLATFORM_BEGIN" );

    test_mutex = xSemaphoreCreateMutexStatic( &mutex_tcb );
    test_recursive_mutex = xSemaphoreCreateRecursiveMutexStatic( &recursive_mutex_tcb );
    completion_sem = xSemaphoreCreateCountingStatic( 2u, 0u, &completion_sem_tcb );
    completion_set = xQueueCreateSet( 2u );
    test_events = xEventGroupCreateStatic( &event_group_tcb );
    test_stream = xStreamBufferCreateStatic(
        PLATFORM_STREAM_BYTES,
        1u,
        stream_storage,
        &stream_tcb
    );
    test_timer = xTimerCreateStatic(
        "platform_tm",
        5u,
        pdFALSE,
        NULL,
        timer_callback,
        &timer_tcb
    );
    if( test_mutex == NULL || test_recursive_mutex == NULL || completion_sem == NULL ||
        completion_set == NULL || test_events == NULL || test_stream == NULL || test_timer == NULL ) {
        platform_fail( "object_create" );
    }
    if( xQueueAddToSet( ( QueueSetMemberHandle_t ) completion_sem, completion_set ) != pdPASS ) {
        platform_fail( "queue_set_add" );
    }
    if( rtos_uart_rx_interrupt_init() == 0 ) {
        platform_fail( "uart_rx_init" );
    }

    worker_a_handle = xTaskCreateStatic(
        worker_task, "plat_work_a", PLATFORM_WORKER_STACK_WORDS,
        ( void * ) ( uintptr_t ) 0u, 2u, worker_a_stack, &worker_a_tcb
    );
    worker_b_handle = xTaskCreateStatic(
        worker_task, "plat_work_b", PLATFORM_WORKER_STACK_WORDS,
        ( void * ) ( uintptr_t ) 1u, 2u, worker_b_stack, &worker_b_tcb
    );
    if( worker_a_handle == NULL || worker_b_handle == NULL ) {
        platform_fail( "static_task_create" );
    }
    if( xTaskCreate(
            dynamic_stream_task,
            "plat_stream",
            PLATFORM_DYNAMIC_STACK_WORDS,
            NULL,
            2u,
            &dynamic_handle ) != pdPASS ) {
        platform_fail( "dynamic_task_create" );
    }
    ( void ) dynamic_handle;
    if( xTaskCreateStatic(
            coordinator_task,
            "plat_coord",
            PLATFORM_COORD_STACK_WORDS,
            NULL,
            3u,
            coordinator_stack,
            &coordinator_tcb ) == NULL ) {
        platform_fail( "coordinator_create" );
    }

    vTaskStartScheduler();
    platform_fail( "scheduler_return" );
}
