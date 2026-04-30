#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "uart.h"

#define RTOS_QUEUE_LENGTH       4u
#define RTOS_TASK_STACK_WORDS   384u
#define RTOS_PRODUCER_DELAY     2u
#define RTOS_CONSUMER_DELAY     1u

static StaticTask_t producer_tcb;
static StaticTask_t consumer_tcb;
static StackType_t producer_stack[ RTOS_TASK_STACK_WORDS ];
static StackType_t consumer_stack[ RTOS_TASK_STACK_WORDS ];
static StaticQueue_t queue_tcb;
static uint32_t queue_storage[ RTOS_QUEUE_LENGTH ];
static QueueHandle_t smoke_queue;
static volatile uint32_t produced_count;
static volatile uint32_t consumed_count;
static volatile uint32_t pass_printed;

static void rtos_log_prefix( const char * task_name ) {
    rtos_uart_write( "[RTOS] tick=" );
    rtos_uart_write_hex32( ( uint32_t ) xTaskGetTickCount() );
    rtos_uart_write( " task=" );
    rtos_uart_write( task_name );
}

static void producer_task( void * arg ) {
    uint32_t value = 0u;
    ( void ) arg;

    taskENTER_CRITICAL();
    rtos_uart_write_line( "[RTOS] task=A start" );
    taskEXIT_CRITICAL();

    for( ;; ) {
        value++;
        if( xQueueSend( smoke_queue, &value, portMAX_DELAY ) == pdPASS ) {
            produced_count++;
            taskENTER_CRITICAL();
            rtos_log_prefix( "A" );
            rtos_uart_write( " queue=send value=" );
            rtos_uart_write_hex32( value );
            rtos_uart_write( "\n" );
            taskEXIT_CRITICAL();
        }
        vTaskDelay( RTOS_PRODUCER_DELAY );
    }
}

static void consumer_task( void * arg ) {
    uint32_t value = 0u;
    ( void ) arg;

    taskENTER_CRITICAL();
    rtos_uart_write_line( "[RTOS] task=B start" );
    taskEXIT_CRITICAL();

    for( ;; ) {
        if( xQueueReceive( smoke_queue, &value, portMAX_DELAY ) == pdPASS ) {
            consumed_count++;
            taskENTER_CRITICAL();
            rtos_log_prefix( "B" );
            rtos_uart_write( " queue=recv value=" );
            rtos_uart_write_hex32( value );
            rtos_uart_write( "\n" );
            if( ( consumed_count >= 3u ) && ( pass_printed == 0u ) ) {
                pass_printed = 1u;
                rtos_uart_write_line( "RTOS_SMOKE_PASS" );
            }
            taskEXIT_CRITICAL();
        }
        vTaskDelay( RTOS_CONSUMER_DELAY );
    }
}

static void fatal( const char * reason ) {
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[RTOS] fatal " );
    rtos_uart_write_line( reason );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

int main( void ) {
    TaskHandle_t handle;

    rtos_uart_write_line( "[RTOS] boot" );

    smoke_queue = xQueueCreateStatic(
        RTOS_QUEUE_LENGTH,
        sizeof( uint32_t ),
        ( uint8_t * ) queue_storage,
        &queue_tcb
    );
    if( smoke_queue == NULL ) {
        fatal( "queue" );
    }
    rtos_uart_write_line( "[RTOS] queue" );

    handle = xTaskCreateStatic( producer_task, "A", RTOS_TASK_STACK_WORDS, NULL, 2u, producer_stack, &producer_tcb );
    if( handle == NULL ) {
        fatal( "taskA" );
    }
    rtos_uart_write_line( "[RTOS] taskA" );

    handle = xTaskCreateStatic( consumer_task, "B", RTOS_TASK_STACK_WORDS, NULL, 2u, consumer_stack, &consumer_tcb );
    if( handle == NULL ) {
        fatal( "taskB" );
    }
    rtos_uart_write_line( "[RTOS] taskB" );

    rtos_uart_write_line( "[RTOS] scheduler" );
    vTaskStartScheduler();
    fatal( "scheduler_return" );
    return 1;
}
