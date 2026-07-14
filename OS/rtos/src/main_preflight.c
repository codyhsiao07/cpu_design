#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "board_control.h"
#include "uart.h"

#define PREFLIGHT_QUEUE_LENGTH      4u
#define PREFLIGHT_TASK_STACK_WORDS  384u
#define PREFLIGHT_EXCHANGES         3u

static StaticTask_t producer_tcb;
static StaticTask_t consumer_tcb;
static StackType_t producer_stack[ PREFLIGHT_TASK_STACK_WORDS ];
static StackType_t consumer_stack[ PREFLIGHT_TASK_STACK_WORDS ];
static StaticQueue_t queue_tcb;
static uint32_t queue_storage[ PREFLIGHT_QUEUE_LENGTH ];
static QueueHandle_t preflight_queue;

static void preflight_fail( const char * reason ) __attribute__( ( noreturn ) );

static void preflight_fail( const char * reason ) {
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "RTOS_PREFLIGHT_FAIL reason=" );
    rtos_uart_write_line( reason );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

static void producer_task( void * arg ) {
    uint32_t value = 0x13570000u;
    ( void ) arg;

    for( ;; ) {
        value++;
        if( xQueueSend( preflight_queue, &value, portMAX_DELAY ) != pdPASS ) {
            preflight_fail( "queue_send" );
        }
        vTaskDelay( 2u );
    }
}

static void consumer_task( void * arg ) {
    uint32_t value;
    uint32_t expected = 0x13570001u;
    uint32_t received = 0u;
    ( void ) arg;

    for( ;; ) {
        if( xQueueReceive( preflight_queue, &value, portMAX_DELAY ) != pdPASS ) {
            preflight_fail( "queue_receive" );
        }
        if( value != expected ) {
            preflight_fail( "queue_data" );
        }
        expected++;
        received++;

        if( received == PREFLIGHT_EXCHANGES ) {
            if( xTaskGetTickCount() == 0u ) {
                preflight_fail( "tick" );
            }
            taskENTER_CRITICAL();
            rtos_uart_write_line( "RTOS_PREFLIGHT_PASS" );
            rtos_board_request_image_reload();
        }
        vTaskDelay( 1u );
    }
}

int main( void ) {
    TaskHandle_t handle;

    rtos_uart_write_line( "RTOS_PREFLIGHT_BEGIN" );

    preflight_queue = xQueueCreateStatic(
        PREFLIGHT_QUEUE_LENGTH,
        sizeof( uint32_t ),
        ( uint8_t * ) queue_storage,
        &queue_tcb
    );
    if( preflight_queue == NULL ) {
        preflight_fail( "queue_create" );
    }

    handle = xTaskCreateStatic(
        producer_task,
        "preflight_tx",
        PREFLIGHT_TASK_STACK_WORDS,
        NULL,
        2u,
        producer_stack,
        &producer_tcb
    );
    if( handle == NULL ) {
        preflight_fail( "task_tx" );
    }

    handle = xTaskCreateStatic(
        consumer_task,
        "preflight_rx",
        PREFLIGHT_TASK_STACK_WORDS,
        NULL,
        2u,
        consumer_stack,
        &consumer_tcb
    );
    if( handle == NULL ) {
        preflight_fail( "task_rx" );
    }

    vTaskStartScheduler();
    preflight_fail( "scheduler_return" );
}
