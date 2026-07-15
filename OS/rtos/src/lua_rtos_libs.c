#include <stddef.h>
#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"
#include "lua.h"
#include "lauxlib.h"
#include "board_control.h"
#include "lua_rtos_libs.h"
#include "uart.h"

extern volatile uint32_t lua_heartbeat_count;
extern float floorf( float value );
extern float ceilf( float value );
extern float sqrtf( float value );

static lua_Integer relative_position( lua_Integer position, size_t length ) {
    if( position < 0 ) {
        position += ( lua_Integer ) length + 1;
    }
    return position;
}

static int string_len( lua_State * state ) {
    size_t length;
    ( void ) luaL_checklstring( state, 1, &length );
    lua_pushinteger( state, ( lua_Integer ) length );
    return 1;
}

static int string_sub( lua_State * state ) {
    size_t length;
    const char * text = luaL_checklstring( state, 1, &length );
    lua_Integer start = relative_position( luaL_checkinteger( state, 2 ), length );
    lua_Integer end = relative_position( luaL_optinteger( state, 3, -1 ), length );

    if( start < 1 ) {
        start = 1;
    }
    if( end > ( lua_Integer ) length ) {
        end = ( lua_Integer ) length;
    }
    if( start <= end ) {
        lua_pushlstring(
            state,
            text + ( size_t ) ( start - 1 ),
            ( size_t ) ( end - start + 1 )
        );
    } else {
        lua_pushliteral( state, "" );
    }
    return 1;
}

static int string_upper( lua_State * state ) {
    size_t length;
    size_t i;
    const char * text = luaL_checklstring( state, 1, &length );
    luaL_Buffer buffer;
    char * output = luaL_buffinitsize( state, &buffer, length );

    for( i = 0u; i < length; i++ ) {
        char value = text[ i ];
        if( value >= 'a' && value <= 'z' ) {
            value = ( char ) ( value - ( 'a' - 'A' ) );
        }
        output[ i ] = value;
    }
    luaL_pushresultsize( &buffer, length );
    return 1;
}

static int string_lower( lua_State * state ) {
    size_t length;
    size_t i;
    const char * text = luaL_checklstring( state, 1, &length );
    luaL_Buffer buffer;
    char * output = luaL_buffinitsize( state, &buffer, length );

    for( i = 0u; i < length; i++ ) {
        char value = text[ i ];
        if( value >= 'A' && value <= 'Z' ) {
            value = ( char ) ( value + ( 'a' - 'A' ) );
        }
        output[ i ] = value;
    }
    luaL_pushresultsize( &buffer, length );
    return 1;
}

static int string_reverse( lua_State * state ) {
    size_t length;
    size_t i;
    const char * text = luaL_checklstring( state, 1, &length );
    luaL_Buffer buffer;
    char * output = luaL_buffinitsize( state, &buffer, length );

    for( i = 0u; i < length; i++ ) {
        output[ i ] = text[ length - i - 1u ];
    }
    luaL_pushresultsize( &buffer, length );
    return 1;
}

static int string_rep( lua_State * state ) {
    size_t text_length;
    size_t separator_length;
    lua_Integer repetitions;
    lua_Integer i;
    const char * text = luaL_checklstring( state, 1, &text_length );
    repetitions = luaL_checkinteger( state, 2 );
    const char * separator = luaL_optlstring( state, 3, "", &separator_length );
    luaL_Buffer buffer;

    luaL_argcheck( state, repetitions >= 0 && repetitions <= 4096, 2, "expected 0..4096" );
    luaL_buffinit( state, &buffer );
    for( i = 0; i < repetitions; i++ ) {
        if( i != 0 ) {
            luaL_addlstring( &buffer, separator, separator_length );
        }
        luaL_addlstring( &buffer, text, text_length );
    }
    luaL_pushresult( &buffer );
    return 1;
}

static int string_byte( lua_State * state ) {
    size_t length;
    const unsigned char * text =
        ( const unsigned char * ) luaL_checklstring( state, 1, &length );
    lua_Integer position = relative_position( luaL_optinteger( state, 2, 1 ), length );

    if( position < 1 || position > ( lua_Integer ) length ) {
        return 0;
    }
    lua_pushinteger( state, text[ position - 1 ] );
    return 1;
}

static int string_char( lua_State * state ) {
    int count = lua_gettop( state );
    int i;
    luaL_Buffer buffer;
    char * output = luaL_buffinitsize( state, &buffer, ( size_t ) count );

    for( i = 1; i <= count; i++ ) {
        lua_Integer value = luaL_checkinteger( state, i );
        luaL_argcheck( state, value >= 0 && value <= 255, i, "byte out of range" );
        output[ i - 1 ] = ( char ) value;
    }
    luaL_pushresultsize( &buffer, ( size_t ) count );
    return 1;
}

static const luaL_Reg string_functions[] = {
    { "len", string_len },
    { "sub", string_sub },
    { "upper", string_upper },
    { "lower", string_lower },
    { "reverse", string_reverse },
    { "rep", string_rep },
    { "byte", string_byte },
    { "char", string_char },
    { NULL, NULL }
};

int luaopen_rtos_string( lua_State * state ) {
    luaL_newlib( state, string_functions );
    lua_newtable( state );
    lua_pushliteral( state, "" );
    lua_pushvalue( state, -2 );
    lua_setmetatable( state, -2 );
    lua_pop( state, 1 );
    lua_pushvalue( state, -2 );
    lua_setfield( state, -2, "__index" );
    lua_pop( state, 1 );
    return 1;
}

static int math_abs( lua_State * state ) {
    if( lua_isinteger( state, 1 ) ) {
        lua_Integer value = lua_tointeger( state, 1 );
        if( value >= 0 ) {
            lua_pushinteger( state, value );
        } else {
            lua_pushnumber( state, -( lua_Number ) value );
        }
    } else {
        lua_Number value = luaL_checknumber( state, 1 );
        lua_pushnumber( state, value < 0 ? -value : value );
    }
    return 1;
}

static int math_floor( lua_State * state ) {
    if( lua_isinteger( state, 1 ) ) {
        lua_settop( state, 1 );
    } else {
        lua_pushnumber( state, floorf( luaL_checknumber( state, 1 ) ) );
    }
    return 1;
}

static int math_ceil( lua_State * state ) {
    if( lua_isinteger( state, 1 ) ) {
        lua_settop( state, 1 );
    } else {
        lua_pushnumber( state, ceilf( luaL_checknumber( state, 1 ) ) );
    }
    return 1;
}

static int math_sqrt( lua_State * state ) {
    lua_pushnumber( state, sqrtf( luaL_checknumber( state, 1 ) ) );
    return 1;
}

static int math_min( lua_State * state ) {
    int count = lua_gettop( state );
    int best = 1;
    int i;
    luaL_argcheck( state, count >= 1, 1, "value expected" );
    for( i = 2; i <= count; i++ ) {
        if( lua_compare( state, i, best, LUA_OPLT ) ) {
            best = i;
        }
    }
    lua_pushvalue( state, best );
    return 1;
}

static int math_max( lua_State * state ) {
    int count = lua_gettop( state );
    int best = 1;
    int i;
    luaL_argcheck( state, count >= 1, 1, "value expected" );
    for( i = 2; i <= count; i++ ) {
        if( lua_compare( state, best, i, LUA_OPLT ) ) {
            best = i;
        }
    }
    lua_pushvalue( state, best );
    return 1;
}

static const luaL_Reg math_functions[] = {
    { "abs", math_abs },
    { "floor", math_floor },
    { "ceil", math_ceil },
    { "sqrt", math_sqrt },
    { "min", math_min },
    { "max", math_max },
    { NULL, NULL }
};

int luaopen_rtos_math( lua_State * state ) {
    luaL_newlib( state, math_functions );
    lua_pushnumber( state, 3.14159265f );
    lua_setfield( state, -2, "pi" );
    return 1;
}

static int rtos_tick( lua_State * state ) {
    lua_pushinteger( state, ( lua_Integer ) xTaskGetTickCount() );
    return 1;
}

static int rtos_heap_free( lua_State * state ) {
    lua_pushinteger( state, ( lua_Integer ) xPortGetFreeHeapSize() );
    return 1;
}

static int rtos_heap_min( lua_State * state ) {
    lua_pushinteger( state, ( lua_Integer ) xPortGetMinimumEverFreeHeapSize() );
    return 1;
}

static int rtos_tasks( lua_State * state ) {
    lua_pushinteger( state, ( lua_Integer ) uxTaskGetNumberOfTasks() );
    return 1;
}

static int rtos_heartbeat( lua_State * state ) {
    lua_pushinteger( state, ( lua_Integer ) lua_heartbeat_count );
    return 1;
}

static int rtos_irq_count( lua_State * state ) {
    lua_pushinteger( state, ( lua_Integer ) rtos_uart_rx_interrupt_count() );
    return 1;
}

static int rtos_sleep( lua_State * state ) {
    lua_Integer milliseconds = luaL_checkinteger( state, 1 );
    TickType_t remaining;

    luaL_argcheck( state, milliseconds >= 0 && milliseconds <= 60000, 1, "expected 0..60000" );
    remaining = ( TickType_t ) milliseconds;
    while( remaining != 0u ) {
        TickType_t slice = remaining > 50u ? 50u : remaining;

        if( rtos_lua_execution_should_abort() ) {
            return luaL_error( state, "execution interrupted during rtos.sleep" );
        }
        vTaskDelay( slice );
        remaining -= slice;
    }
    if( rtos_lua_execution_should_abort() ) {
        return luaL_error( state, "execution interrupted during rtos.sleep" );
    }
    return 0;
}

static int rtos_read_line( lua_State * state ) {
    lua_Integer timeout_ms = luaL_optinteger( state, 1, 30000 );
    char line[ RTOS_LUA_INPUT_LINE_BYTES ];
    size_t length = 0u;
    int result;

    luaL_argcheck(
        state,
        timeout_ms >= 0 && timeout_ms <= 60000,
        1,
        "expected 0..60000"
    );
    result = rtos_lua_input_read(
        line,
        sizeof( line ),
        ( uint32_t ) timeout_ms,
        &length
    );
    if( result < 0 ) {
        return luaL_error(
            state,
            "execution interrupted during rtos.read_line"
        );
    }
    if( result == 0 ) {
        lua_pushnil( state );
        lua_pushliteral( state, "timeout" );
        return 2;
    }
    lua_pushlstring( state, line, length );
    return 1;
}

static int rtos_ping( lua_State * state ) {
    uint32_t tick = ( uint32_t ) xTaskGetTickCount();
    rtos_uart_write( "LUA_RTOS_PONG tick=" );
    rtos_uart_write_u32( tick );
    rtos_uart_write( "\n" );
    lua_pushinteger( state, ( lua_Integer ) tick );
    return 1;
}

static int rtos_status( lua_State * state ) {
    rtos_uart_write( "LUA_RTOS_STATUS tick=" );
    rtos_uart_write_u32( ( uint32_t ) xTaskGetTickCount() );
    rtos_uart_write( " heap_free=" );
    rtos_uart_write_u32( ( uint32_t ) xPortGetFreeHeapSize() );
    rtos_uart_write( " heap_min=" );
    rtos_uart_write_u32( ( uint32_t ) xPortGetMinimumEverFreeHeapSize() );
    rtos_uart_write( " heartbeat=" );
    rtos_uart_write_u32( lua_heartbeat_count );
    rtos_uart_write( " irq=" );
    rtos_uart_write_u32( rtos_uart_rx_interrupt_count() );
    rtos_uart_write( "\n" );
    ( void ) state;
    return 0;
}

static int rtos_reload( lua_State * state ) {
    ( void ) state;
    rtos_uart_write_line( "RELOADING" );
    rtos_board_request_image_reload();
}

static const luaL_Reg rtos_functions[] = {
    { "tick", rtos_tick },
    { "heap_free", rtos_heap_free },
    { "heap_min", rtos_heap_min },
    { "tasks", rtos_tasks },
    { "heartbeat", rtos_heartbeat },
    { "irq_count", rtos_irq_count },
    { "sleep", rtos_sleep },
    { "read_line", rtos_read_line },
    { "ping", rtos_ping },
    { "status", rtos_status },
    { "reload", rtos_reload },
    { NULL, NULL }
};

int luaopen_rtos( lua_State * state ) {
    luaL_newlib( state, rtos_functions );
    lua_pushliteral( state, "FreeRTOS RV32 Platform v1" );
    lua_setfield( state, -2, "platform" );
    return 1;
}
