#ifndef OS_RTOS_LUA_RTOS_LIBS_H
#define OS_RTOS_LUA_RTOS_LIBS_H

#include <stddef.h>
#include <stdint.h>

#include "lua.h"

#define RTOS_LUA_INPUT_LINE_BYTES 128u

int luaopen_rtos( lua_State * state );
int luaopen_rtos_string( lua_State * state );
int luaopen_rtos_math( lua_State * state );

/* Implemented by the Lua application so blocking C APIs remain stoppable. */
int rtos_lua_execution_should_abort( void );

/*
 * Receive one line collected by the UART RX task.
 * Returns 1 for a line, 0 for timeout, and -1 when execution was stopped.
 */
int rtos_lua_input_read( char * buffer,
                         size_t capacity,
                         uint32_t timeout_ms,
                         size_t * length );

#endif
