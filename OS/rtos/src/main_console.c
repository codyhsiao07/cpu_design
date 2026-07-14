#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "board_control.h"
#include "uart.h"

#define CONSOLE_LINE_BYTES          64u
#define COMMAND_QUEUE_LENGTH        4u
#define WORK_QUEUE_LENGTH           2u
#define RESULT_QUEUE_LENGTH         2u
#define RX_STACK_WORDS              384u
#define COMMAND_STACK_WORDS         512u
#define WORKER_STACK_WORDS          384u
#define HEARTBEAT_STACK_WORDS       256u
#define RX_IDLE_POLL_TICKS          1u
#define WORK_DEFAULT_ITERATIONS     1000u
#define WORK_MAX_ITERATIONS         100000u

typedef struct ConsoleCommand {
    char text[ CONSOLE_LINE_BYTES ];
} ConsoleCommand_t;

typedef struct WorkRequest {
    uint32_t id;
    uint32_t iterations;
} WorkRequest_t;

typedef struct WorkResult {
    uint32_t id;
    uint32_t iterations;
    uint32_t result;
} WorkResult_t;

static StaticTask_t rx_tcb;
static StaticTask_t command_tcb;
static StaticTask_t worker_tcb;
static StaticTask_t heartbeat_tcb;
static StackType_t rx_stack[ RX_STACK_WORDS ];
static StackType_t command_stack[ COMMAND_STACK_WORDS ];
static StackType_t worker_stack[ WORKER_STACK_WORDS ];
static StackType_t heartbeat_stack[ HEARTBEAT_STACK_WORDS ];

static StaticQueue_t command_queue_tcb;
static StaticQueue_t work_queue_tcb;
static StaticQueue_t result_queue_tcb;
static ConsoleCommand_t command_queue_storage[ COMMAND_QUEUE_LENGTH ];
static WorkRequest_t work_queue_storage[ WORK_QUEUE_LENGTH ];
static WorkResult_t result_queue_storage[ RESULT_QUEUE_LENGTH ];
static QueueHandle_t command_queue;
static QueueHandle_t work_queue;
static QueueHandle_t result_queue;

static volatile uint32_t rx_lines;
static volatile uint32_t rx_overruns;
static volatile uint32_t rx_line_overflows;
static volatile uint32_t command_drops;
static volatile uint32_t command_count;
static volatile uint32_t heartbeat_count;
static volatile uint32_t jobs_queued;
static volatile uint32_t jobs_completed;
static volatile uint32_t last_job_result;
static uint32_t next_job_id = 1u;

static void fatal( const char * reason ) __attribute__( ( noreturn ) );

static char ascii_lower( char value ) {
    if( ( value >= 'A' ) && ( value <= 'Z' ) ) {
        return ( char ) ( value + ( 'a' - 'A' ) );
    }
    return value;
}

static const char * skip_spaces( const char * text ) {
    while( *text == ' ' ) {
        text++;
    }
    return text;
}

static int command_match( const char * line, const char * name, const char ** args ) {
    while( ( *name != '\0' ) && ( ascii_lower( *line ) == *name ) ) {
        line++;
        name++;
    }
    if( *name != '\0' ) {
        return 0;
    }
    if( ( *line != '\0' ) && ( *line != ' ' ) ) {
        return 0;
    }
    *args = skip_spaces( line );
    return 1;
}

static int parse_u32( const char * text, uint32_t * value ) {
    uint32_t parsed = 0u;
    uint32_t digits = 0u;

    text = skip_spaces( text );
    while( ( *text >= '0' ) && ( *text <= '9' ) ) {
        uint32_t digit = ( uint32_t ) ( *text - '0' );
        if( parsed > ( 0xFFFFFFFFu - digit ) / 10u ) {
            return 0;
        }
        parsed = ( parsed * 10u ) + digit;
        digits++;
        text++;
    }
    text = skip_spaces( text );
    if( ( digits == 0u ) || ( *text != '\0' ) ) {
        return 0;
    }
    *value = parsed;
    return 1;
}

static void console_prompt( void ) {
    rtos_uart_write( "> " );
}

static void print_help( void ) {
    rtos_uart_write_line( "Commands:" );
    rtos_uart_write_line( "  help              show this list" );
    rtos_uart_write_line( "  ping              scheduler response check" );
    rtos_uart_write_line( "  status            runtime counters and queues" );
    rtos_uart_write_line( "  tasks             configured FreeRTOS tasks" );
    rtos_uart_write_line( "  echo <text>       echo text through command task" );
    rtos_uart_write_line( "  work [iterations] run a queued worker job" );
    rtos_uart_write_line( "  reload            return to UART bootloader" );
}

static void print_status( void ) {
    rtos_uart_write( "STATUS tick=" );
    rtos_uart_write_u32( ( uint32_t ) xTaskGetTickCount() );
    rtos_uart_write( " heartbeat=" );
    rtos_uart_write_u32( heartbeat_count );
    rtos_uart_write( " commands=" );
    rtos_uart_write_u32( command_count );
    rtos_uart_write( " lines=" );
    rtos_uart_write_u32( rx_lines );
    rtos_uart_write( "\n" );

    rtos_uart_write( "STATUS jobs=" );
    rtos_uart_write_u32( jobs_completed );
    rtos_uart_write( "/" );
    rtos_uart_write_u32( jobs_queued );
    rtos_uart_write( " last=" );
    rtos_uart_write_hex32( last_job_result );
    rtos_uart_write( " cmdq=" );
    rtos_uart_write_u32( ( uint32_t ) uxQueueMessagesWaiting( command_queue ) );
    rtos_uart_write( " workq=" );
    rtos_uart_write_u32( ( uint32_t ) uxQueueMessagesWaiting( work_queue ) );
    rtos_uart_write( "\n" );

    rtos_uart_write( "STATUS rx_overrun=" );
    rtos_uart_write_u32( rx_overruns );
    rtos_uart_write( " line_overflow=" );
    rtos_uart_write_u32( rx_line_overflows );
    rtos_uart_write( " command_drop=" );
    rtos_uart_write_u32( command_drops );
    rtos_uart_write( "\n" );
}

static void print_tasks( void ) {
    rtos_uart_write_line( "TASK name=console_rx priority=3 role=UART-input" );
    rtos_uart_write_line( "TASK name=console_cmd priority=2 role=parser" );
    rtos_uart_write_line( "TASK name=worker priority=1 role=queued-work" );
    rtos_uart_write_line( "TASK name=heartbeat priority=1 role=liveness" );
    rtos_uart_write_line( "TASK name=IDLE priority=0 role=FreeRTOS-idle" );
}

static uint32_t run_workload( uint32_t iterations ) {
    uint32_t value = 0xC001D00Du ^ iterations;
    uint32_t i;

    for( i = 0u; i < iterations; i++ ) {
        value = ( value << 5u ) | ( value >> 27u );
        value ^= 0x9E3779B9u + i;
        if( ( i & 0xFFu ) == 0u ) {
            taskYIELD();
        }
    }
    return value;
}

static void rx_submit_line( const char * line ) {
    ConsoleCommand_t command;
    uint32_t i = 0u;

    while( ( i < ( CONSOLE_LINE_BYTES - 1u ) ) && ( line[ i ] != '\0' ) ) {
        command.text[ i ] = line[ i ];
        i++;
    }
    command.text[ i ] = '\0';
    if( xQueueSend( command_queue, &command, 0u ) != pdPASS ) {
        command_drops++;
        rtos_uart_write_line( "ERR command queue full" );
        console_prompt();
    } else {
        rx_lines++;
    }
}

static void rx_task( void * arg ) {
    char line[ CONSOLE_LINE_BYTES ];
    uint32_t length = 0u;
    uint32_t line_overflow = 0u;
    uint32_t previous_was_cr = 0u;
    ( void ) arg;

    /* The upstream RISC-V FreeRTOS port enables MEIE together with MTIE.
     * UART is deliberately polled by this task, so disable only MEIE before
     * accepting input; the machine timer interrupt remains enabled. */
    rtos_board_disable_external_interrupts();

    for( ;; ) {
        char value;
        uint32_t overrun;

        if( rtos_uart_try_getc( &value, &overrun ) == 0 ) {
            if( overrun != 0u ) {
                rx_overruns++;
            }
            vTaskDelay( RX_IDLE_POLL_TICKS );
            continue;
        }
        if( overrun != 0u ) {
            rx_overruns++;
        }

        if( ( value == '\r' ) || ( value == '\n' ) ) {
            if( ( value == '\n' ) && ( previous_was_cr != 0u ) ) {
                previous_was_cr = 0u;
                continue;
            }
            previous_was_cr = ( value == '\r' ) ? 1u : 0u;
            rtos_uart_write( "\n" );
            if( line_overflow != 0u ) {
                rx_line_overflows++;
                rtos_uart_write_line( "ERR line too long" );
                console_prompt();
            } else if( length != 0u ) {
                line[ length ] = '\0';
                rx_submit_line( line );
            } else {
                console_prompt();
            }
            length = 0u;
            line_overflow = 0u;
        } else {
            previous_was_cr = 0u;
            if( ( value == '\b' ) || ( value == 0x7Fu ) ) {
                if( length != 0u ) {
                    length--;
                    rtos_uart_write( "\b \b" );
                }
            } else if( ( value >= ' ' ) && ( value <= '~' ) ) {
                rtos_uart_putc( value );
                if( length < ( CONSOLE_LINE_BYTES - 1u ) ) {
                    line[ length ] = value;
                    length++;
                } else {
                    line_overflow = 1u;
                }
            }
        }
    }
}

static void command_task( void * arg ) {
    ConsoleCommand_t command;
    ( void ) arg;

    rtos_uart_write_line( "APP_READY" );
    rtos_uart_write_line( "RTOS Console ready. Type 'help'." );
    console_prompt();

    for( ;; ) {
        const char * args;

        if( xQueueReceive( command_queue, &command, portMAX_DELAY ) != pdPASS ) {
            fatal( "command_receive" );
        }
        command_count++;

        if( command_match( command.text, "help", &args ) ) {
            print_help();
        } else if( command_match( command.text, "ping", &args ) ) {
            rtos_uart_write( "PONG tick=" );
            rtos_uart_write_u32( ( uint32_t ) xTaskGetTickCount() );
            rtos_uart_write( "\n" );
        } else if( command_match( command.text, "status", &args ) ) {
            print_status();
        } else if( command_match( command.text, "tasks", &args ) ) {
            print_tasks();
        } else if( command_match( command.text, "echo", &args ) ) {
            rtos_uart_write( "ECHO " );
            rtos_uart_write_line( args );
        } else if( command_match( command.text, "work", &args ) ) {
            WorkRequest_t request;
            WorkResult_t result;

            request.iterations = WORK_DEFAULT_ITERATIONS;
            if( *args != '\0' ) {
                if( ( parse_u32( args, &request.iterations ) == 0 ) ||
                    ( request.iterations == 0u ) ||
                    ( request.iterations > WORK_MAX_ITERATIONS ) ) {
                    rtos_uart_write_line( "ERR work iterations must be 1..100000" );
                    console_prompt();
                    continue;
                }
            }
            request.id = next_job_id++;
            if( xQueueSend( work_queue, &request, 0u ) != pdPASS ) {
                rtos_uart_write_line( "ERR worker queue full" );
            } else {
                jobs_queued++;
                rtos_uart_write( "WORK queued id=" );
                rtos_uart_write_u32( request.id );
                rtos_uart_write( " iterations=" );
                rtos_uart_write_u32( request.iterations );
                rtos_uart_write( "\n" );
                if( xQueueReceive( result_queue, &result, portMAX_DELAY ) != pdPASS ) {
                    fatal( "result_receive" );
                }
                rtos_uart_write( "WORK done id=" );
                rtos_uart_write_u32( result.id );
                rtos_uart_write( " result=" );
                rtos_uart_write_hex32( result.result );
                rtos_uart_write( "\n" );
            }
        } else if( command_match( command.text, "reload", &args ) ) {
            rtos_uart_write_line( "RELOADING" );
            rtos_board_request_image_reload();
        } else {
            rtos_uart_write( "ERR unknown command: " );
            rtos_uart_write_line( command.text );
        }
        console_prompt();
    }
}

static void worker_task( void * arg ) {
    WorkRequest_t request;
    WorkResult_t result;
    ( void ) arg;

    for( ;; ) {
        if( xQueueReceive( work_queue, &request, portMAX_DELAY ) != pdPASS ) {
            fatal( "work_receive" );
        }
        result.id = request.id;
        result.iterations = request.iterations;
        result.result = run_workload( request.iterations );
        last_job_result = result.result;
        jobs_completed++;
        if( xQueueSend( result_queue, &result, portMAX_DELAY ) != pdPASS ) {
            fatal( "result_send" );
        }
    }
}

static void heartbeat_task( void * arg ) {
    ( void ) arg;
    for( ;; ) {
        vTaskDelay( 1000u );
        heartbeat_count++;
    }
}

static void fatal( const char * reason ) {
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[CONSOLE] fatal " );
    rtos_uart_write_line( reason );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

int main( void ) {
    TaskHandle_t handle;

    rtos_uart_write_line( "RTOS_CONSOLE_BOOT" );

    command_queue = xQueueCreateStatic(
        COMMAND_QUEUE_LENGTH,
        sizeof( ConsoleCommand_t ),
        ( uint8_t * ) command_queue_storage,
        &command_queue_tcb
    );
    work_queue = xQueueCreateStatic(
        WORK_QUEUE_LENGTH,
        sizeof( WorkRequest_t ),
        ( uint8_t * ) work_queue_storage,
        &work_queue_tcb
    );
    result_queue = xQueueCreateStatic(
        RESULT_QUEUE_LENGTH,
        sizeof( WorkResult_t ),
        ( uint8_t * ) result_queue_storage,
        &result_queue_tcb
    );
    if( ( command_queue == NULL ) || ( work_queue == NULL ) || ( result_queue == NULL ) ) {
        fatal( "queue_create" );
    }

    handle = xTaskCreateStatic( rx_task, "console_rx", RX_STACK_WORDS, NULL, 3u, rx_stack, &rx_tcb );
    if( handle == NULL ) { fatal( "task_rx" ); }
    handle = xTaskCreateStatic( command_task, "console_cmd", COMMAND_STACK_WORDS, NULL, 2u, command_stack, &command_tcb );
    if( handle == NULL ) { fatal( "task_command" ); }
    handle = xTaskCreateStatic( worker_task, "worker", WORKER_STACK_WORDS, NULL, 1u, worker_stack, &worker_tcb );
    if( handle == NULL ) { fatal( "task_worker" ); }
    handle = xTaskCreateStatic( heartbeat_task, "heartbeat", HEARTBEAT_STACK_WORDS, NULL, 1u, heartbeat_stack, &heartbeat_tcb );
    if( handle == NULL ) { fatal( "task_heartbeat" ); }

    vTaskStartScheduler();
    fatal( "scheduler_return" );
}
