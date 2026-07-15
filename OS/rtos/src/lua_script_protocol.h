#ifndef OS_RTOS_LUA_SCRIPT_PROTOCOL_H
#define OS_RTOS_LUA_SCRIPT_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define LUA_SCRIPT_MAX_BYTES             65536u
#define LUA_SCRIPT_TIMEOUT_MAX_MS        600000u
#define LUA_SCRIPT_INSTRUCTION_MAX       100000000u

typedef enum LuaScriptControlType {
    LUA_SCRIPT_CONTROL_NONE = 0,
    LUA_SCRIPT_CONTROL_RUN,
    LUA_SCRIPT_CONTROL_STOP,
    LUA_SCRIPT_CONTROL_STATUS
} LuaScriptControlType_t;

typedef struct LuaScriptControl {
    LuaScriptControlType_t type;
    uint32_t length;
    uint32_t crc32;
    uint32_t timeout_ms;
    uint32_t instruction_limit;
} LuaScriptControl_t;

uint32_t lua_script_crc32( const void * data, size_t length );

/*
 * Returns 1 for a valid @lua control line, 0 for a normal REPL line, and -1
 * for a malformed @lua control line.
 */
int lua_script_parse_control( const char * line,
                              size_t length,
                              LuaScriptControl_t * control );

#endif
