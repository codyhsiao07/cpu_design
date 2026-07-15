#include "lua_script_protocol.h"

static int is_space( char value ) {
    return value == ' ' || value == '\t';
}

static void skip_spaces( const char * line, size_t length, size_t * position ) {
    while( *position < length && is_space( line[ *position ] ) ) {
        ( *position )++;
    }
}

static int match_word( const char * line,
                       size_t length,
                       size_t * position,
                       const char * word ) {
    size_t cursor = *position;

    while( *word != '\0' ) {
        if( cursor >= length || line[ cursor ] != *word ) {
            return 0;
        }
        cursor++;
        word++;
    }
    if( cursor < length && !is_space( line[ cursor ] ) ) {
        return 0;
    }
    *position = cursor;
    return 1;
}

static int parse_decimal( const char * line,
                          size_t length,
                          size_t * position,
                          uint32_t * value ) {
    uint32_t result = 0u;
    size_t digits = 0u;

    skip_spaces( line, length, position );
    while( *position < length ) {
        uint32_t digit;
        char current = line[ *position ];

        if( current < '0' || current > '9' ) {
            break;
        }
        digit = ( uint32_t ) ( current - '0' );
        if( result > ( 0xFFFFFFFFu - digit ) / 10u ) {
            return 0;
        }
        result = result * 10u + digit;
        ( *position )++;
        digits++;
    }
    if( digits == 0u ) {
        return 0;
    }
    *value = result;
    return 1;
}

static int parse_hex( const char * line,
                      size_t length,
                      size_t * position,
                      uint32_t * value ) {
    uint32_t result = 0u;
    size_t digits = 0u;

    skip_spaces( line, length, position );
    if( *position + 2u <= length &&
        line[ *position ] == '0' &&
        ( line[ *position + 1u ] == 'x' || line[ *position + 1u ] == 'X' ) ) {
        *position += 2u;
    }
    while( *position < length ) {
        uint32_t digit;
        char current = line[ *position ];

        if( current >= '0' && current <= '9' ) {
            digit = ( uint32_t ) ( current - '0' );
        } else if( current >= 'a' && current <= 'f' ) {
            digit = ( uint32_t ) ( current - 'a' ) + 10u;
        } else if( current >= 'A' && current <= 'F' ) {
            digit = ( uint32_t ) ( current - 'A' ) + 10u;
        } else {
            break;
        }
        if( digits >= 8u ) {
            return 0;
        }
        result = ( result << 4u ) | digit;
        ( *position )++;
        digits++;
    }
    if( digits == 0u ) {
        return 0;
    }
    *value = result;
    return 1;
}

static int at_end( const char * line, size_t length, size_t position ) {
    skip_spaces( line, length, &position );
    return position == length;
}

uint32_t lua_script_crc32( const void * data, size_t length ) {
    const uint8_t * bytes = ( const uint8_t * ) data;
    uint32_t crc = 0xFFFFFFFFu;
    size_t index;

    for( index = 0u; index < length; index++ ) {
        uint32_t bit;

        crc ^= bytes[ index ];
        for( bit = 0u; bit < 8u; bit++ ) {
            uint32_t mask = 0u - ( crc & 1u );
            crc = ( crc >> 1u ) ^ ( 0xEDB88320u & mask );
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

int lua_script_parse_control( const char * line,
                              size_t length,
                              LuaScriptControl_t * control ) {
    size_t position = 0u;

    if( length < 4u ||
        line[ 0 ] != '@' ||
        line[ 1 ] != 'l' ||
        line[ 2 ] != 'u' ||
        line[ 3 ] != 'a' ) {
        return 0;
    }
    control->type = LUA_SCRIPT_CONTROL_NONE;
    control->length = 0u;
    control->crc32 = 0u;
    control->timeout_ms = 0u;
    control->instruction_limit = 0u;

    position = 4u;
    if( position >= length || !is_space( line[ position ] ) ) {
        return -1;
    }
    skip_spaces( line, length, &position );
    if( match_word( line, length, &position, "stop" ) ) {
        if( !at_end( line, length, position ) ) {
            return -1;
        }
        control->type = LUA_SCRIPT_CONTROL_STOP;
        return 1;
    }
    if( match_word( line, length, &position, "status" ) ) {
        if( !at_end( line, length, position ) ) {
            return -1;
        }
        control->type = LUA_SCRIPT_CONTROL_STATUS;
        return 1;
    }
    if( !match_word( line, length, &position, "run" ) ||
        !parse_decimal( line, length, &position, &control->length ) ||
        !parse_hex( line, length, &position, &control->crc32 ) ||
        !parse_decimal( line, length, &position, &control->timeout_ms ) ||
        !parse_decimal( line, length, &position, &control->instruction_limit ) ||
        !at_end( line, length, position ) ) {
        return -1;
    }
    if( control->length > LUA_SCRIPT_MAX_BYTES ||
        control->timeout_ms == 0u ||
        control->timeout_ms > LUA_SCRIPT_TIMEOUT_MAX_MS ||
        control->instruction_limit < 100u ||
        control->instruction_limit > LUA_SCRIPT_INSTRUCTION_MAX ) {
        return -1;
    }
    control->type = LUA_SCRIPT_CONTROL_RUN;
    return 1;
}
