#include <stddef.h>
#include <stdint.h>

#include "FreeRTOS.h"
#include "queue.h"
#include "task.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lua_rtos_libs.h"
#include "lua_script_protocol.h"
#include "board_control.h"
#include "uart.h"

#define LUA_TASK_STACK_WORDS          4096u
#define LUA_RX_TASK_STACK_WORDS       768u
#define LUA_HEARTBEAT_STACK_WORDS     256u
#define LUA_LINE_BYTES                384u
#define LUA_COMMAND_QUEUE_LENGTH      1u
#define LUA_INPUT_QUEUE_LENGTH        4u
#define LUA_REPL_TIMEOUT_MS           5000u
#define LUA_REPL_INSTRUCTION_LIMIT    1000000u
#define LUA_HOOK_INTERVAL             100u
#define LUA_SCRIPT_RX_IDLE_TIMEOUT_MS 2000u

typedef enum LuaCommandKind {
    LUA_COMMAND_REPL = 1,
    LUA_COMMAND_SCRIPT
} LuaCommandKind_t;

typedef struct LuaCommand {
    LuaCommandKind_t kind;
    uint32_t length;
    uint32_t timeout_ms;
    uint32_t instruction_limit;
} LuaCommand_t;

typedef struct LuaInputLine {
    uint32_t length;
    char text[ RTOS_LUA_INPUT_LINE_BYTES ];
} LuaInputLine_t;

typedef enum LuaExecutionPhase {
    LUA_PHASE_IDLE = 0,
    LUA_PHASE_RECEIVING,
    LUA_PHASE_QUEUED,
    LUA_PHASE_RUNNING
} LuaExecutionPhase_t;

typedef enum LuaGuardReason {
    LUA_GUARD_NONE = 0,
    LUA_GUARD_STOP,
    LUA_GUARD_TIMEOUT,
    LUA_GUARD_INSTRUCTION_LIMIT
} LuaGuardReason_t;

static StaticTask_t lua_task_tcb;
static StaticTask_t rx_task_tcb;
static StaticTask_t heartbeat_task_tcb;
static StackType_t lua_task_stack[ LUA_TASK_STACK_WORDS ];
static StackType_t rx_task_stack[ LUA_RX_TASK_STACK_WORDS ];
static StackType_t heartbeat_task_stack[ LUA_HEARTBEAT_STACK_WORDS ];

static StaticQueue_t lua_command_queue_tcb;
static uint8_t lua_command_queue_storage[
    LUA_COMMAND_QUEUE_LENGTH * sizeof( LuaCommand_t )
];
static QueueHandle_t lua_command_queue;

static StaticQueue_t lua_input_queue_tcb;
static uint8_t lua_input_queue_storage[
    LUA_INPUT_QUEUE_LENGTH * sizeof( LuaInputLine_t )
];
static QueueHandle_t lua_input_queue;

static char * lua_source_buffer;
static volatile uint32_t lua_runtime_ready;
static volatile uint32_t lua_execution_busy;
static volatile uint32_t lua_input_waiting;
static volatile LuaExecutionPhase_t lua_execution_phase;
static volatile uint32_t lua_abort_requested;

static volatile uint32_t lua_guard_active;
static volatile uint32_t lua_guard_deadline;
static volatile uint32_t lua_guard_instructions;
static volatile uint32_t lua_guard_instruction_limit;
static volatile LuaGuardReason_t lua_guard_reason;

volatile uint32_t lua_heartbeat_count;

static void lua_fatal( const char * reason ) __attribute__( ( noreturn ) );

static void lua_fatal( const char * reason ) {
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[LUA] FATAL reason=" );
    rtos_uart_write_line( reason );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}

static int lua_panic_handler( lua_State * state ) {
    const char * message = lua_tostring( state, -1 );
    taskDISABLE_INTERRUPTS();
    rtos_uart_write( "[LUA] PANIC " );
    rtos_uart_write_line( message != NULL ? message : "(no message)" );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
    return 0;
}

static void open_library( lua_State * state,
                          const char * name,
                          lua_CFunction open_function ) {
    luaL_requiref( state, name, open_function, 1 );
    lua_pop( state, 1 );
}

static void open_libraries( lua_State * state ) {
    open_library( state, LUA_GNAME, luaopen_base );
    open_library( state, LUA_COLIBNAME, luaopen_coroutine );
    open_library( state, LUA_TABLIBNAME, luaopen_table );
    open_library( state, LUA_UTF8LIBNAME, luaopen_utf8 );
    open_library( state, LUA_STRLIBNAME, luaopen_rtos_string );
    open_library( state, LUA_MATHLIBNAME, luaopen_rtos_math );
    open_library( state, "rtos", luaopen_rtos );
}

static void report_lua_error( lua_State * state, const char * prefix ) {
    const char * message = lua_tostring( state, -1 );
    rtos_uart_write( prefix );
    rtos_uart_write_line( message != NULL ? message : "(non-string error)" );
    lua_pop( state, 1 );
}

static void run_protocol_self_test( void ) {
    static const char control_line[] =
        "@lua run 3 352441C2 1000 10000";
    static const char crc_text[] = "abc";
    LuaScriptControl_t control;

    if( lua_script_crc32( crc_text, sizeof( crc_text ) - 1u ) != 0x352441C2u ||
        lua_script_parse_control(
            control_line,
            sizeof( control_line ) - 1u,
            &control ) != 1 ||
        control.type != LUA_SCRIPT_CONTROL_RUN ||
        control.length != 3u ||
        control.crc32 != 0x352441C2u ||
        control.timeout_ms != 1000u ||
        control.instruction_limit != 10000u ) {
        lua_fatal( "script_protocol" );
    }
    rtos_uart_write_line( "LUA_SCRIPT_PROTOCOL_PASS" );
}

static void run_boot_self_test( lua_State * state ) {
    static const char script[] =
        "local t, sum = {}, 0\n"
        "for i = 1, 20 do t[i] = i * i; sum = sum + t[i] end\n"
        "assert(sum == 2870)\n"
        "assert(t[20] == 400 and #t == 20)\n"
        "assert(string.upper('fpga') == 'FPGA')\n"
        "assert(string.sub('FreeRTOS', 5) == 'RTOS')\n"
        "assert(math.floor(7.75) == 7)\n"
        "assert(math.sqrt(81) == 9)\n"
        "assert(math.sqrt(1e-20) > 0.99999e-10 and math.sqrt(1e-20) < 1.00001e-10)\n"
        "assert(math.sqrt(1e20) > 0.99999e10 and math.sqrt(1e20) < 1.00001e10)\n"
        "assert(4294967296.0 % 3.0 == 1)\n"
        "assert(16 ^ 0.25 == 2)\n"
        "assert(tostring(1/0) == 'inf' and tostring(-1/0) == '-inf')\n"
        "assert(tonumber('0x1p4294967296') == 1/0)\n"
        "assert(tonumber('0x1p-4294967296') == 0)\n"
        "local infinity_key = {[1/0] = 7}; assert(infinity_key[1/0] == 7)\n"
        "assert(rtos.heap_free() > 1000000)\n"
        "print('LUA_FLOAT_PASS', math.floor(7.75), math.sqrt(81))\n"
        "print('LUA_SELFTEST_PASS', sum)\n";
    int status = luaL_loadbuffer( state, script, sizeof( script ) - 1u, "=boot-selftest" );

    if( status == LUA_OK ) {
        status = lua_pcall( state, 0, 0, 0 );
    }
    if( status != LUA_OK ) {
        report_lua_error( state, "[LUA] SELFTEST_ERROR " );
        lua_fatal( "selftest" );
    }
    lua_settop( state, 0 );
}

static void print_results( lua_State * state ) {
    int results = lua_gettop( state );
    int index;

    if( results == 0 ) {
        return;
    }
    rtos_uart_write( "=> " );
    for( index = 1; index <= results; index++ ) {
        size_t length;
        const char * text;
        if( index != 1 ) {
            rtos_uart_putc( '\t' );
        }
        text = luaL_tolstring( state, index, &length );
        rtos_lua_writestring( text, length );
        lua_pop( state, 1 );
    }
    rtos_uart_write( "\n" );
}

static int tick_reached( uint32_t now, uint32_t deadline ) {
    return ( int32_t ) ( now - deadline ) >= 0;
}

int rtos_lua_execution_should_abort( void ) {
    if( lua_guard_active == 0u ) {
        return 0;
    }
    if( lua_abort_requested != 0u ) {
        lua_guard_reason = LUA_GUARD_STOP;
        return 1;
    }
    if( tick_reached(
            ( uint32_t ) xTaskGetTickCount(),
            lua_guard_deadline ) ) {
        lua_guard_reason = LUA_GUARD_TIMEOUT;
        return 1;
    }
    return 0;
}

int rtos_lua_input_read( char * buffer,
                         size_t capacity,
                         uint32_t timeout_ms,
                         size_t * length ) {
    LuaInputLine_t input;
    uint32_t deadline = ( uint32_t ) xTaskGetTickCount() + timeout_ms;

    if( buffer == NULL || capacity == 0u || length == NULL ) {
        return 0;
    }
    lua_input_waiting = 1u;
    for( ;; ) {
        uint32_t now;
        uint32_t remaining;
        TickType_t wait_ticks;
        size_t copy_length;
        size_t index;

        if( rtos_lua_execution_should_abort() ) {
            lua_input_waiting = 0u;
            return -1;
        }
        now = ( uint32_t ) xTaskGetTickCount();
        if( timeout_ms == 0u || tick_reached( now, deadline ) ) {
            lua_input_waiting = 0u;
            return 0;
        }
        remaining = deadline - now;
        wait_ticks = remaining > 50u ? 50u : ( TickType_t ) remaining;
        if( xQueueReceive( lua_input_queue, &input, wait_ticks ) != pdPASS ) {
            continue;
        }
        copy_length = input.length;
        if( copy_length >= capacity ) {
            copy_length = capacity - 1u;
        }
        for( index = 0u; index < copy_length; index++ ) {
            buffer[ index ] = input.text[ index ];
        }
        buffer[ copy_length ] = '\0';
        *length = copy_length;
        lua_input_waiting = 0u;
        return 1;
    }
}

static const char * guard_error_text( void ) {
    switch( lua_guard_reason ) {
        case LUA_GUARD_STOP:
            return "execution stopped";
        case LUA_GUARD_TIMEOUT:
            return "execution timeout";
        case LUA_GUARD_INSTRUCTION_LIMIT:
            return "instruction limit exceeded";
        default:
            return "execution interrupted";
    }
}

static void execution_hook( lua_State * state, lua_Debug * debug ) {
    ( void ) debug;

    if( rtos_lua_execution_should_abort() ) {
        luaL_error( state, "%s", guard_error_text() );
        return;
    }
    if( lua_guard_instructions >=
        lua_guard_instruction_limit - LUA_HOOK_INTERVAL ) {
        lua_guard_instructions = lua_guard_instruction_limit;
        lua_guard_reason = LUA_GUARD_INSTRUCTION_LIMIT;
        luaL_error( state, "%s", guard_error_text() );
        return;
    }
    lua_guard_instructions += LUA_HOOK_INTERVAL;
}

static void begin_guard( lua_State * state,
                         uint32_t timeout_ms,
                         uint32_t instruction_limit ) {
    lua_guard_reason = LUA_GUARD_NONE;
    lua_guard_instructions = 0u;
    lua_guard_instruction_limit = instruction_limit;
    lua_guard_deadline = ( uint32_t ) xTaskGetTickCount() + timeout_ms;
    lua_guard_active = 1u;
    lua_sethook( state, execution_hook, LUA_MASKCOUNT, LUA_HOOK_INTERVAL );
}

static void end_guard( lua_State * state ) {
    lua_sethook( state, NULL, 0, 0 );
    lua_guard_active = 0u;
}

static int protected_call( lua_State * state,
                           uint32_t timeout_ms,
                           uint32_t instruction_limit ) {
    int status;

    begin_guard( state, timeout_ms, instruction_limit );
    status = lua_pcall( state, 0, LUA_MULTRET, 0 );
    end_guard( state );
    return status;
}

static void report_guarded_error( lua_State * state, int script_mode ) {
    if( lua_guard_reason == LUA_GUARD_STOP ) {
        rtos_uart_write_line(
            script_mode ? "LUA_SCRIPT_STOPPED" : "LUA_REPL_STOPPED" );
        report_lua_error( state, "[LUA] detail=" );
    } else if( lua_guard_reason == LUA_GUARD_TIMEOUT ) {
        rtos_uart_write_line(
            script_mode ? "LUA_SCRIPT_TIMEOUT" : "LUA_REPL_TIMEOUT" );
        report_lua_error( state, "[LUA] detail=" );
    } else if( lua_guard_reason == LUA_GUARD_INSTRUCTION_LIMIT ) {
        rtos_uart_write_line(
            script_mode ? "LUA_SCRIPT_LIMIT" : "LUA_REPL_LIMIT" );
        report_lua_error( state, "[LUA] detail=" );
    } else {
        report_lua_error(
            state,
            script_mode ? "LUA_SCRIPT_ERROR " : "LUA_ERROR " );
    }
}

static void execute_line( lua_State * state,
                          const char * line,
                          size_t length,
                          uint32_t timeout_ms,
                          uint32_t instruction_limit ) {
    char expression[ LUA_LINE_BYTES + 8u ];
    static const char prefix[] = "return ";
    size_t i;
    int status;

    for( i = 0u; i < sizeof( prefix ) - 1u; i++ ) {
        expression[ i ] = prefix[ i ];
    }
    for( i = 0u; i < length; i++ ) {
        expression[ sizeof( prefix ) - 1u + i ] = line[ i ];
    }
    expression[ sizeof( prefix ) - 1u + length ] = '\0';

    status = luaL_loadbuffer(
        state,
        expression,
        sizeof( prefix ) - 1u + length,
        "=uart"
    );
    if( status != LUA_OK ) {
        lua_pop( state, 1 );
        status = luaL_loadbuffer( state, line, length, "=uart" );
    }
    if( status == LUA_OK ) {
        status = protected_call( state, timeout_ms, instruction_limit );
    }
    if( status != LUA_OK ) {
        report_guarded_error( state, 0 );
    } else {
        print_results( state );
    }
    lua_settop( state, 0 );
}

static void execute_script( lua_State * state, const LuaCommand_t * command ) {
    int status;

    ( void ) xQueueReset( lua_input_queue );
    rtos_uart_write( "LUA_SCRIPT_START length=" );
    rtos_uart_write_u32( command->length );
    rtos_uart_write( " timeout_ms=" );
    rtos_uart_write_u32( command->timeout_ms );
    rtos_uart_write( " instructions=" );
    rtos_uart_write_u32( command->instruction_limit );
    rtos_uart_write( "\n" );

    status = luaL_loadbuffer(
        state,
        lua_source_buffer,
        command->length,
        "@uart-script.lua"
    );
    if( status == LUA_OK ) {
        status = protected_call(
            state,
            command->timeout_ms,
            command->instruction_limit
        );
    }
    if( status != LUA_OK ) {
        report_guarded_error( state, 1 );
    } else {
        print_results( state );
        rtos_uart_write_line( "LUA_SCRIPT_PASS" );
    }
    lua_settop( state, 0 );
    ( void ) lua_gc( state, LUA_GCCOLLECT );
}

static void write_prompt( void ) {
    rtos_uart_write( "lua> " );
}

static void finish_execution( void ) {
    ( void ) xQueueReset( lua_input_queue );
    lua_input_waiting = 0u;
    lua_abort_requested = 0u;
    lua_execution_phase = LUA_PHASE_IDLE;
    lua_execution_busy = 0u;
    write_prompt();
}

static void lua_task( void * arg ) {
    static const char repl_statement_test[] =
        "local t={}; for i=1,10 do t[i]=i*i end; assert(t[10]==100)";
    static const char repl_recovery_test[] =
        "print('LUA_REPL_RECOVERY_PASS',math.floor(7.75),math.sqrt(81))";
    LuaCommand_t command;
    lua_State * state;
    ( void ) arg;

    state = luaL_newstate();
    if( state == NULL ) {
        lua_fatal( "newstate" );
    }
    lua_atpanic( state, lua_panic_handler );
    open_libraries( state );
    run_protocol_self_test();
    run_boot_self_test( state );
    execute_line(
        state,
        repl_statement_test,
        sizeof( repl_statement_test ) - 1u,
        LUA_REPL_TIMEOUT_MS,
        LUA_REPL_INSTRUCTION_LIMIT
    );
    execute_line(
        state,
        repl_recovery_test,
        sizeof( repl_recovery_test ) - 1u,
        LUA_REPL_TIMEOUT_MS,
        LUA_REPL_INSTRUCTION_LIMIT
    );

    rtos_uart_write( "LUA_VERSION " );
    rtos_uart_write_line( LUA_VERSION );
    rtos_uart_write( "LUA_HEAP_READY free=" );
    rtos_uart_write_u32( ( uint32_t ) xPortGetFreeHeapSize() );
    rtos_uart_write( " min=" );
    rtos_uart_write_u32( ( uint32_t ) xPortGetMinimumEverFreeHeapSize() );
    rtos_uart_write( "\n" );
    rtos_uart_write_line( "LUA_RTOS_READY" );
    rtos_uart_write_line( "Lua upload: python tools/run_lua_script.py --port COM5 --file app.lua" );
    rtos_uart_write_line( "Lua REPL: arrows, Backspace and Delete edit the current line" );
    lua_runtime_ready = 1u;
    write_prompt();

    for( ;; ) {
        if( xQueueReceive(
                lua_command_queue,
                &command,
                portMAX_DELAY ) != pdPASS ) {
            continue;
        }
        lua_execution_phase = LUA_PHASE_RUNNING;
        if( command.kind == LUA_COMMAND_SCRIPT ) {
            execute_script( state, &command );
        } else {
            execute_line(
                state,
                lua_source_buffer,
                command.length,
                command.timeout_ms,
                command.instruction_limit
            );
        }
        finish_execution();
    }
}

static void editor_backspaces( size_t count ) {
    while( count != 0u ) {
        rtos_uart_putc( '\b' );
        count--;
    }
}

static void editor_insert( char * line,
                           size_t * length,
                           size_t * cursor,
                           char value ) {
    size_t index;
    size_t start = *cursor;

    if( *length >= LUA_LINE_BYTES - 1u ) {
        return;
    }
    for( index = *length; index > start; index-- ) {
        line[ index ] = line[ index - 1u ];
    }
    line[ start ] = value;
    ( *length )++;
    ( *cursor )++;
    for( index = start; index < *length; index++ ) {
        rtos_uart_putc( line[ index ] );
    }
    editor_backspaces( *length - *cursor );
}

static void editor_backspace( char * line, size_t * length, size_t * cursor ) {
    size_t index;
    size_t old_length = *length;

    if( *cursor == 0u ) {
        return;
    }
    ( *cursor )--;
    for( index = *cursor; index + 1u < *length; index++ ) {
        line[ index ] = line[ index + 1u ];
    }
    ( *length )--;
    rtos_uart_putc( '\b' );
    for( index = *cursor; index < *length; index++ ) {
        rtos_uart_putc( line[ index ] );
    }
    rtos_uart_putc( ' ' );
    editor_backspaces( old_length - *cursor );
}

static void editor_delete( char * line, size_t * length, size_t cursor ) {
    size_t index;
    size_t old_length = *length;

    if( cursor >= *length ) {
        return;
    }
    for( index = cursor; index + 1u < *length; index++ ) {
        line[ index ] = line[ index + 1u ];
    }
    ( *length )--;
    for( index = cursor; index < *length; index++ ) {
        rtos_uart_putc( line[ index ] );
    }
    rtos_uart_putc( ' ' );
    editor_backspaces( old_length - cursor );
}

static void write_phase( LuaExecutionPhase_t phase ) {
    switch( phase ) {
        case LUA_PHASE_RECEIVING:
            rtos_uart_write( "receiving" );
            break;
        case LUA_PHASE_QUEUED:
            rtos_uart_write( "queued" );
            break;
        case LUA_PHASE_RUNNING:
            rtos_uart_write( "running" );
            break;
        default:
            rtos_uart_write( "idle" );
            break;
    }
}

static void report_script_status( void ) {
    rtos_uart_write( "LUA_SCRIPT_STATUS ready=" );
    rtos_uart_write_u32( lua_runtime_ready );
    rtos_uart_write( " busy=" );
    rtos_uart_write_u32( lua_execution_busy );
    rtos_uart_write( " input_waiting=" );
    rtos_uart_write_u32( lua_input_waiting );
    rtos_uart_write( " phase=" );
    write_phase( lua_execution_phase );
    rtos_uart_write( " heartbeat=" );
    rtos_uart_write_u32( lua_heartbeat_count );
    rtos_uart_write( "\n" );
}

static void queue_lua_input( const char * line, size_t length ) {
    LuaInputLine_t input;
    size_t index;

    if( length >= RTOS_LUA_INPUT_LINE_BYTES ) {
        rtos_uart_write( "LUA_INPUT_TOO_LONG max=" );
        rtos_uart_write_u32( RTOS_LUA_INPUT_LINE_BYTES - 1u );
        rtos_uart_write( "\n" );
        return;
    }
    input.length = ( uint32_t ) length;
    for( index = 0u; index < length; index++ ) {
        input.text[ index ] = line[ index ];
    }
    input.text[ length ] = '\0';
    if( xQueueSend( lua_input_queue, &input, 0u ) != pdPASS ) {
        rtos_uart_write_line( "LUA_INPUT_QUEUE_FULL" );
    }
}

static int queue_lua_command( const LuaCommand_t * command ) {
    lua_execution_phase = LUA_PHASE_QUEUED;
    if( xQueueSend( lua_command_queue, command, 0u ) != pdPASS ) {
        rtos_uart_write_line( "LUA_SCRIPT_QUEUE_ERROR" );
        lua_execution_phase = LUA_PHASE_IDLE;
        lua_execution_busy = 0u;
        return 0;
    }
    return 1;
}

static int ensure_source_buffer( void ) {
    if( lua_source_buffer == NULL ) {
        lua_source_buffer = ( char * ) pvPortMalloc(
            LUA_SCRIPT_MAX_BYTES + 1u
        );
    }
    return lua_source_buffer != NULL;
}

static void complete_script_receive( const LuaCommand_t * command,
                                     uint32_t expected_crc ) {
    uint32_t actual_crc = lua_script_crc32(
        lua_source_buffer,
        command->length
    );

    lua_source_buffer[ command->length ] = '\0';
    if( actual_crc != expected_crc ) {
        rtos_uart_write( "LUA_SCRIPT_CRC_ERROR expected=" );
        rtos_uart_write_hex32( expected_crc );
        rtos_uart_write( " actual=" );
        rtos_uart_write_hex32( actual_crc );
        rtos_uart_write( "\n" );
        lua_execution_phase = LUA_PHASE_IDLE;
        lua_execution_busy = 0u;
        write_prompt();
        return;
    }
    rtos_uart_write( "LUA_SCRIPT_ACCEPTED length=" );
    rtos_uart_write_u32( command->length );
    rtos_uart_write( " crc=" );
    rtos_uart_write_hex32( actual_crc );
    rtos_uart_write( "\n" );
    ( void ) queue_lua_command( command );
}

static void begin_script_receive( const LuaScriptControl_t * control,
                                  LuaCommand_t * command,
                                  uint32_t * expected_crc,
                                  uint32_t * received,
                                  uint32_t * idle_deadline,
                                  uint32_t * skip_optional_lf ) {
    if( !ensure_source_buffer() ) {
        rtos_uart_write_line( "LUA_SCRIPT_ALLOC_ERROR" );
        write_prompt();
        return;
    }
    command->kind = LUA_COMMAND_SCRIPT;
    command->length = control->length;
    command->timeout_ms = control->timeout_ms;
    command->instruction_limit = control->instruction_limit;
    *expected_crc = control->crc32;
    *received = 0u;
    *idle_deadline = ( uint32_t ) xTaskGetTickCount() +
                     LUA_SCRIPT_RX_IDLE_TIMEOUT_MS;
    *skip_optional_lf = 1u;
    lua_abort_requested = 0u;
    lua_execution_busy = 1u;
    lua_execution_phase = LUA_PHASE_RECEIVING;
    rtos_uart_write( "LUA_SCRIPT_RX_READY length=" );
    rtos_uart_write_u32( control->length );
    rtos_uart_write( "\n" );
    if( control->length == 0u ) {
        complete_script_receive( command, *expected_crc );
    }
}

static void process_input_line( const char * line,
                                size_t length,
                                LuaCommand_t * receive_command,
                                uint32_t * expected_crc,
                                uint32_t * received,
                                uint32_t * idle_deadline,
                                uint32_t * skip_optional_lf ) {
    LuaScriptControl_t control;
    int parsed = lua_script_parse_control( line, length, &control );

    if( parsed == 0 &&
        length == 6u &&
        line[ 0 ] == 'r' && line[ 1 ] == 'e' && line[ 2 ] == 'l' &&
        line[ 3 ] == 'o' && line[ 4 ] == 'a' && line[ 5 ] == 'd' ) {
        rtos_uart_write_line( "RELOADING" );
        rtos_board_request_image_reload();
    }

    if( parsed < 0 ) {
        rtos_uart_write_line( "LUA_SCRIPT_HEADER_ERROR" );
        if( lua_execution_busy == 0u ) {
            write_prompt();
        }
        return;
    }
    if( parsed > 0 ) {
        if( control.type == LUA_SCRIPT_CONTROL_STATUS ) {
            report_script_status();
            if( lua_execution_busy == 0u ) {
                write_prompt();
            }
        } else if( control.type == LUA_SCRIPT_CONTROL_STOP ) {
            if( lua_execution_busy != 0u ) {
                lua_abort_requested = 1u;
                rtos_uart_write_line( "LUA_SCRIPT_STOP_REQUESTED" );
            } else {
                rtos_uart_write_line( "LUA_SCRIPT_IDLE" );
                write_prompt();
            }
        } else if( lua_runtime_ready == 0u ) {
            rtos_uart_write_line( "LUA_SCRIPT_NOT_READY" );
        } else if( lua_execution_busy != 0u ) {
            rtos_uart_write_line( "LUA_SCRIPT_BUSY" );
        } else {
            begin_script_receive(
                &control,
                receive_command,
                expected_crc,
                received,
                idle_deadline,
                skip_optional_lf
            );
        }
        return;
    }
    if( lua_execution_busy != 0u && lua_input_waiting != 0u &&
        lua_execution_phase == LUA_PHASE_RUNNING ) {
        queue_lua_input( line, length );
        return;
    }
    if( length == 0u ) {
        write_prompt();
        return;
    }
    if( lua_runtime_ready == 0u ) {
        rtos_uart_write_line( "LUA_NOT_READY" );
        return;
    }
    if( lua_execution_busy != 0u ) {
        rtos_uart_write_line( "LUA_BUSY use @lua stop or @lua status" );
        return;
    }
    if( length >= LUA_LINE_BYTES ) {
        rtos_uart_write_line( "LUA_ERROR input line too long" );
        write_prompt();
        return;
    }
    if( !ensure_source_buffer() ) {
        rtos_uart_write_line( "LUA_ERROR script buffer allocation failed" );
        write_prompt();
        return;
    }
    {
        size_t index;
        LuaCommand_t command;

        for( index = 0u; index < length; index++ ) {
            lua_source_buffer[ index ] = line[ index ];
        }
        lua_source_buffer[ length ] = '\0';
        command.kind = LUA_COMMAND_REPL;
        command.length = ( uint32_t ) length;
        command.timeout_ms = LUA_REPL_TIMEOUT_MS;
        command.instruction_limit = LUA_REPL_INSTRUCTION_LIMIT;
        lua_abort_requested = 0u;
        lua_execution_busy = 1u;
        ( void ) queue_lua_command( &command );
    }
}

static void rx_task( void * arg ) {
    char line[ LUA_LINE_BYTES ];
    size_t length = 0u;
    size_t cursor = 0u;
    uint32_t escape_state = 0u;
    uint32_t previous_was_cr = 0u;
    LuaCommand_t receive_command;
    uint32_t expected_crc = 0u;
    uint32_t received = 0u;
    uint32_t idle_deadline = 0u;
    uint32_t skip_optional_lf = 0u;
    ( void ) arg;

    for( ;; ) {
        char value;
        uint32_t overrun = 0u;
        uint32_t timeout = lua_execution_phase == LUA_PHASE_RECEIVING ?
                           100u : portMAX_DELAY;

        if( rtos_uart_getc( &value, timeout, &overrun ) == 0 ) {
            if( lua_execution_phase == LUA_PHASE_RECEIVING &&
                tick_reached(
                    ( uint32_t ) xTaskGetTickCount(),
                    idle_deadline ) ) {
                rtos_uart_write_line( "LUA_SCRIPT_RX_TIMEOUT" );
                lua_execution_phase = LUA_PHASE_IDLE;
                lua_execution_busy = 0u;
                write_prompt();
            }
            continue;
        }
        if( overrun != 0u ) {
            rtos_uart_write_line( "[LUA] UART_RX_OVERRUN" );
        }
        if( lua_execution_phase == LUA_PHASE_RECEIVING ) {
            if( skip_optional_lf != 0u ) {
                skip_optional_lf = 0u;
                if( value == '\n' ) {
                    continue;
                }
            }
            if( received < receive_command.length ) {
                lua_source_buffer[ received++ ] = value;
                idle_deadline = ( uint32_t ) xTaskGetTickCount() +
                                LUA_SCRIPT_RX_IDLE_TIMEOUT_MS;
            }
            if( received == receive_command.length ) {
                complete_script_receive( &receive_command, expected_crc );
            }
            continue;
        }

        if( escape_state != 0u ) {
            if( escape_state == 1u ) {
                escape_state = value == '[' ? 2u : 0u;
            } else if( escape_state == 2u ) {
                if( value == 'D' ) {
                    if( cursor != 0u ) {
                        cursor--;
                        rtos_uart_putc( '\b' );
                    }
                    escape_state = 0u;
                } else if( value == 'C' ) {
                    if( cursor < length ) {
                        rtos_uart_putc( line[ cursor++ ] );
                    }
                    escape_state = 0u;
                } else if( value == 'H' ) {
                    editor_backspaces( cursor );
                    cursor = 0u;
                    escape_state = 0u;
                } else if( value == 'F' ) {
                    while( cursor < length ) {
                        rtos_uart_putc( line[ cursor++ ] );
                    }
                    escape_state = 0u;
                } else if( value == '3' ) {
                    escape_state = 3u;
                } else {
                    /* Up/down and unsupported CSI keys are consumed. */
                    escape_state = 0u;
                }
            } else {
                if( value == '~' ) {
                    editor_delete( line, &length, cursor );
                }
                escape_state = 0u;
            }
            continue;
        }
        if( ( unsigned char ) value == 0x1Bu ) {
            escape_state = 1u;
            continue;
        }
        if( value == '\r' || value == '\n' ) {
            if( value == '\n' && previous_was_cr != 0u ) {
                previous_was_cr = 0u;
                continue;
            }
            previous_was_cr = value == '\r';
            while( cursor < length ) {
                rtos_uart_putc( line[ cursor++ ] );
            }
            rtos_uart_write( "\n" );
            process_input_line(
                line,
                length,
                &receive_command,
                &expected_crc,
                &received,
                &idle_deadline,
                &skip_optional_lf
            );
            length = 0u;
            cursor = 0u;
        } else {
            previous_was_cr = 0u;
            if( value == '\b' || ( unsigned char ) value == 0x7Fu ) {
                editor_backspace( line, &length, &cursor );
            } else if( value >= ' ' && value <= '~' ) {
                editor_insert( line, &length, &cursor, value );
            }
        }
    }
}

static void heartbeat_task( void * arg ) {
    ( void ) arg;
    for( ;; ) {
        vTaskDelay( 1000u );
        lua_heartbeat_count++;
    }
}

int main( void ) {
    rtos_uart_write_line( "LUA_RTOS_BOOT" );

    if( rtos_uart_rx_interrupt_init() == 0 ) {
        lua_fatal( "uart_rx_init" );
    }
    lua_command_queue = xQueueCreateStatic(
        LUA_COMMAND_QUEUE_LENGTH,
        sizeof( LuaCommand_t ),
        lua_command_queue_storage,
        &lua_command_queue_tcb
    );
    if( lua_command_queue == NULL ) {
        lua_fatal( "command_queue" );
    }
    lua_input_queue = xQueueCreateStatic(
        LUA_INPUT_QUEUE_LENGTH,
        sizeof( LuaInputLine_t ),
        lua_input_queue_storage,
        &lua_input_queue_tcb
    );
    if( lua_input_queue == NULL ) {
        lua_fatal( "input_queue" );
    }
    if( xTaskCreateStatic(
            lua_task,
            "lua",
            LUA_TASK_STACK_WORDS,
            NULL,
            2u,
            lua_task_stack,
            &lua_task_tcb ) == NULL ) {
        lua_fatal( "lua_task" );
    }
    if( xTaskCreateStatic(
            rx_task,
            "lua_rx",
            LUA_RX_TASK_STACK_WORDS,
            NULL,
            3u,
            rx_task_stack,
            &rx_task_tcb ) == NULL ) {
        lua_fatal( "rx_task" );
    }
    if( xTaskCreateStatic(
            heartbeat_task,
            "lua_heart",
            LUA_HEARTBEAT_STACK_WORDS,
            NULL,
            1u,
            heartbeat_task_stack,
            &heartbeat_task_tcb ) == NULL ) {
        lua_fatal( "heartbeat_task" );
    }

    vTaskStartScheduler();
    lua_fatal( "scheduler_return" );
}
