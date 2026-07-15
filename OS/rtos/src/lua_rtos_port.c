#include <stddef.h>
#include <stdint.h>

#include "uart.h"

static int ascii_space( char value ) {
    return value == ' ' || value == '\t' || value == '\n' ||
           value == '\r' || value == '\f' || value == '\v';
}

static float quiet_nan( void ) {
    union {
        uint32_t bits;
        float value;
    } data;
    data.bits = 0x7FC00000u;
    return data.value;
}

static int copy_text( char * buffer, size_t size, const char * text ) {
    size_t count = 0u;
    if( size == 0u ) {
        return 0;
    }
    while( text[ count ] != '\0' && count + 1u < size ) {
        buffer[ count ] = text[ count ];
        count++;
    }
    buffer[ count ] = '\0';
    return ( int ) count;
}

static int format_unsigned( char * buffer, size_t size, uint32_t value ) {
    char reverse[ 10 ];
    size_t digits = 0u;
    size_t out = 0u;

    do {
        reverse[ digits++ ] = ( char ) ( '0' + ( value % 10u ) );
        value /= 10u;
    } while( value != 0u );
    if( size == 0u ) {
        return 0;
    }
    while( digits != 0u && out + 1u < size ) {
        buffer[ out++ ] = reverse[ --digits ];
    }
    buffer[ out ] = '\0';
    return ( int ) out;
}

int rtos_lua_integer2str( char * buffer, size_t size, int32_t value ) {
    uint32_t magnitude;
    int count;

    if( size == 0u ) {
        return 0;
    }
    if( value >= 0 ) {
        return format_unsigned( buffer, size, ( uint32_t ) value );
    }
    buffer[ 0 ] = '-';
    if( size == 1u ) {
        return 0;
    }
    magnitude = ( uint32_t ) ( -( value + 1 ) ) + 1u;
    count = format_unsigned( buffer + 1, size - 1u, magnitude );
    return count + 1;
}

static int format_fixed_positive( char * buffer, size_t size, float value ) {
    uint32_t whole = ( uint32_t ) value;
    uint32_t fraction;
    int count = format_unsigned( buffer, size, whole );
    int digits = 6;

    if( ( size_t ) count + 1u >= size ) {
        return count;
    }
    value = ( value - ( float ) whole ) * 1000000.0f;
    if( value < 0.0f ) {
        value = 0.0f;
    }
    fraction = ( uint32_t ) ( value + 0.5f );
    if( fraction >= 1000000u ) {
        return format_unsigned( buffer, size, whole + 1u );
    }
    if( fraction == 0u ) {
        return count;
    }
    buffer[ count++ ] = '.';
    while( digits > 0 && ( size_t ) count + 1u < size ) {
        uint32_t divisor = 1u;
        int i;
        for( i = 1; i < digits; i++ ) {
            divisor *= 10u;
        }
        buffer[ count++ ] = ( char ) ( '0' + ( fraction / divisor ) % 10u );
        digits--;
    }
    while( count > 0 && buffer[ count - 1 ] == '0' ) {
        count--;
    }
    if( count > 0 && buffer[ count - 1 ] == '.' ) {
        count--;
    }
    buffer[ count ] = '\0';
    return count;
}

int rtos_lua_number2str( char * buffer, size_t size, float value ) {
    int negative = 0;
    int exponent = 0;
    int count;

    if( value != value ) {
        return copy_text( buffer, size, "nan" );
    }
    if( value < 0.0f ) {
        negative = 1;
        value = -value;
    }
    if( value == 0.0f ) {
        return copy_text( buffer, size, negative ? "-0" : "0" );
    }
    while( value >= 10000000.0f && exponent < 99 ) {
        value *= 0.1f;
        exponent++;
    }
    while( value < 0.000001f && exponent > -99 ) {
        value *= 10.0f;
        exponent--;
    }
    if( size == 0u ) {
        return 0;
    }
    count = 0;
    if( negative ) {
        buffer[ count++ ] = '-';
    }
    count += format_fixed_positive( buffer + count, size - ( size_t ) count, value );
    if( exponent != 0 && ( size_t ) count + 2u < size ) {
        int exp_count;
        buffer[ count++ ] = 'e';
        exp_count = rtos_lua_integer2str(
            buffer + count,
            size - ( size_t ) count,
            exponent
        );
        count += exp_count;
    }
    return count;
}

int rtos_lua_pointer2str( char * buffer, size_t size, const void * value ) {
    static const char hex[] = "0123456789abcdef";
    uintptr_t address = ( uintptr_t ) value;
    int count = 0;
    int shift;

    if( size < 3u ) {
        return copy_text( buffer, size, "0" );
    }
    buffer[ count++ ] = '0';
    buffer[ count++ ] = 'x';
    for( shift = ( int ) ( sizeof( uintptr_t ) * 8u ) - 4; shift >= 0; shift -= 4 ) {
        if( ( size_t ) count + 1u >= size ) {
            break;
        }
        buffer[ count++ ] = hex[ ( address >> shift ) & 0xFu ];
    }
    buffer[ count ] = '\0';
    return count;
}

void rtos_lua_writestring( const char * text, size_t length ) {
    size_t i;
    for( i = 0u; i < length; i++ ) {
        rtos_uart_putc( text[ i ] );
    }
}

void rtos_lua_writeline( void ) {
    rtos_uart_write( "\n" );
}

void rtos_lua_writestringerror( const char * prefix, const char * detail ) {
    while( *prefix != '\0' ) {
        if( prefix[ 0 ] == '%' && prefix[ 1 ] == 's' ) {
            rtos_uart_write( detail != NULL ? detail : "(null)" );
            prefix += 2;
        } else {
            rtos_uart_putc( *prefix++ );
        }
    }
}

unsigned int rtos_lua_seed( void ) {
    static uint32_t sequence = 0x6C756100u;
    uint32_t timer = *( ( volatile uint32_t * ) 0x40000020u );
    sequence = ( sequence << 5u ) ^ ( sequence >> 3u ) ^ timer ^ 0x9E3779B9u;
    return sequence;
}

float strtof( const char * text, char ** endptr ) {
    const char * start = text;
    float value = 0.0f;
    float fraction = 0.1f;
    int negative = 0;
    int digits = 0;
    int exponent = 0;
    int exponent_negative = 0;

    while( ascii_space( *text ) ) {
        text++;
    }
    if( *text == '-' || *text == '+' ) {
        negative = *text == '-';
        text++;
    }
    while( *text >= '0' && *text <= '9' ) {
        value = value * 10.0f + ( float ) ( *text - '0' );
        text++;
        digits++;
    }
    if( *text == '.' ) {
        text++;
        while( *text >= '0' && *text <= '9' ) {
            value += ( float ) ( *text - '0' ) * fraction;
            fraction *= 0.1f;
            text++;
            digits++;
        }
    }
    if( digits != 0 && ( *text == 'e' || *text == 'E' ) ) {
        const char * exponent_start = text++;
        if( *text == '-' || *text == '+' ) {
            exponent_negative = *text == '-';
            text++;
        }
        if( *text < '0' || *text > '9' ) {
            text = exponent_start;
        } else {
            while( *text >= '0' && *text <= '9' ) {
                if( exponent < 1000 ) {
                    exponent = exponent * 10 + ( *text - '0' );
                }
                text++;
            }
            if( exponent_negative ) {
                while( exponent-- > 0 ) {
                    value *= 0.1f;
                }
            } else {
                while( exponent-- > 0 ) {
                    value *= 10.0f;
                }
            }
        }
    }
    if( endptr != NULL ) {
        *endptr = ( char * ) ( digits == 0 ? start : text );
    }
    return negative ? -value : value;
}

float rtos_lua_strx2number( const char * text, char ** endptr ) {
    const char * start = text;
    float value = 0.0f;
    float scale = 1.0f;
    int negative = 0;
    int digits = 0;
    int exponent = 0;
    int exponent_negative = 0;
    int after_dot = 0;

    while( ascii_space( *text ) ) {
        text++;
    }
    if( *text == '-' || *text == '+' ) {
        negative = *text == '-';
        text++;
    }
    if( text[ 0 ] != '0' || ( text[ 1 ] != 'x' && text[ 1 ] != 'X' ) ) {
        if( endptr != NULL ) {
            *endptr = ( char * ) start;
        }
        return 0.0f;
    }
    text += 2;
    for( ;; ) {
        int digit;
        if( *text >= '0' && *text <= '9' ) {
            digit = *text - '0';
        } else if( *text >= 'a' && *text <= 'f' ) {
            digit = *text - 'a' + 10;
        } else if( *text >= 'A' && *text <= 'F' ) {
            digit = *text - 'A' + 10;
        } else if( *text == '.' && !after_dot ) {
            after_dot = 1;
            text++;
            continue;
        } else {
            break;
        }
        if( after_dot ) {
            scale *= 0.0625f;
            value += ( float ) digit * scale;
        } else {
            value = value * 16.0f + ( float ) digit;
        }
        digits++;
        text++;
    }
    if( digits != 0 && ( *text == 'p' || *text == 'P' ) ) {
        const char * exponent_start = text++;
        if( *text == '-' || *text == '+' ) {
            exponent_negative = *text == '-';
            text++;
        }
        if( *text < '0' || *text > '9' ) {
            text = exponent_start;
        } else {
            while( *text >= '0' && *text <= '9' ) {
                exponent = exponent * 10 + ( *text - '0' );
                text++;
            }
            while( exponent-- > 0 ) {
                value *= exponent_negative ? 0.5f : 2.0f;
            }
        }
    }
    if( endptr != NULL ) {
        *endptr = ( char * ) ( digits == 0 ? start : text );
    }
    return negative ? -value : value;
}

void * memchr( const void * memory, int value, size_t size ) {
    const unsigned char * bytes = ( const unsigned char * ) memory;
    size_t i;
    for( i = 0u; i < size; i++ ) {
        if( bytes[ i ] == ( unsigned char ) value ) {
            return ( void * ) ( bytes + i );
        }
    }
    return NULL;
}

int strcmp( const char * left, const char * right ) {
    while( *left != '\0' && *left == *right ) {
        left++;
        right++;
    }
    return ( int ) ( unsigned char ) *left - ( int ) ( unsigned char ) *right;
}

int strncmp( const char * left, const char * right, size_t size ) {
    size_t i;
    for( i = 0u; i < size; i++ ) {
        unsigned char a = ( unsigned char ) left[ i ];
        unsigned char b = ( unsigned char ) right[ i ];
        if( a != b || a == '\0' ) {
            return ( int ) a - ( int ) b;
        }
    }
    return 0;
}

size_t strspn( const char * text, const char * accept ) {
    size_t length = 0u;
    while( text[ length ] != '\0' ) {
        const char * candidate = accept;
        int found = 0;
        while( *candidate != '\0' ) {
            if( text[ length ] == *candidate++ ) {
                found = 1;
                break;
            }
        }
        if( !found ) {
            break;
        }
        length++;
    }
    return length;
}

int strcoll( const char * left, const char * right ) {
    return strcmp( left, right );
}

char * strcpy( char * dest, const char * src ) {
    char * result = dest;
    do {
        *dest++ = *src;
    } while( *src++ != '\0' );
    return result;
}

char * strchr( const char * text, int value ) {
    char target = ( char ) value;
    do {
        if( *text == target ) {
            return ( char * ) text;
        }
    } while( *text++ != '\0' );
    return NULL;
}

char * strpbrk( const char * text, const char * accept ) {
    while( *text != '\0' ) {
        const char * candidate = accept;
        while( *candidate != '\0' ) {
            if( *text == *candidate++ ) {
                return ( char * ) text;
            }
        }
        text++;
    }
    return NULL;
}

int abs( int value ) {
    return value < 0 ? -value : value;
}

static int lua_errno_value;

int * __errno( void ) {
    return &lua_errno_value;
}

char * strerror( int error ) {
    ( void ) error;
    return "RTOS I/O unavailable";
}

float fabsf( float value ) {
    return value < 0.0f ? -value : value;
}

float floorf( float value ) {
    int32_t integer;
    if( value != value || value >= 2147483520.0f || value <= -2147483648.0f ) {
        return value;
    }
    integer = ( int32_t ) value;
    if( ( float ) integer > value ) {
        integer--;
    }
    return ( float ) integer;
}

float ceilf( float value ) {
    int32_t integer;
    if( value != value || value >= 2147483520.0f || value <= -2147483648.0f ) {
        return value;
    }
    integer = ( int32_t ) value;
    if( ( float ) integer < value ) {
        integer++;
    }
    return ( float ) integer;
}

float fmodf( float left, float right ) {
    float quotient;
    int32_t truncated;
    if( right == 0.0f || left != left || right != right ) {
        return quiet_nan();
    }
    quotient = left / right;
    if( quotient >= 2147483520.0f || quotient <= -2147483648.0f ) {
        return left;
    }
    truncated = ( int32_t ) quotient;
    return left - ( ( float ) truncated * right );
}

float sqrtf( float value ) {
    float estimate;
    int i;
    if( value < 0.0f ) {
        return quiet_nan();
    }
    if( value == 0.0f ) {
        return 0.0f;
    }
    estimate = value > 1.0f ? value : 1.0f;
    for( i = 0; i < 12; i++ ) {
        estimate = 0.5f * ( estimate + value / estimate );
    }
    return estimate;
}

float powf( float base, float exponent ) {
    int32_t power;
    uint32_t magnitude;
    float result = 1.0f;

    if( exponent == 0.5f ) {
        return sqrtf( base );
    }
    if( exponent != floorf( exponent ) || exponent > 63.0f || exponent < -63.0f ) {
        return quiet_nan();
    }
    power = ( int32_t ) exponent;
    magnitude = ( uint32_t ) ( power < 0 ? -power : power );
    while( magnitude != 0u ) {
        if( ( magnitude & 1u ) != 0u ) {
            result *= base;
        }
        base *= base;
        magnitude >>= 1u;
    }
    return power < 0 ? 1.0f / result : result;
}

float ldexpf( float value, int exponent ) {
    while( exponent > 0 ) {
        value *= 2.0f;
        exponent--;
    }
    while( exponent < 0 ) {
        value *= 0.5f;
        exponent++;
    }
    return value;
}

float frexpf( float value, int * exponent ) {
    int output_exponent = 0;
    float sign = 1.0f;

    if( value < 0.0f ) {
        sign = -1.0f;
        value = -value;
    }
    if( value == 0.0f || value != value ) {
        *exponent = 0;
        return value * sign;
    }
    while( value >= 1.0f ) {
        value *= 0.5f;
        output_exponent++;
    }
    while( value < 0.5f ) {
        value *= 2.0f;
        output_exponent--;
    }
    *exponent = output_exponent;
    return value * sign;
}

void abort( void ) {
    __asm volatile ( "csrc mstatus, 8" );
    rtos_uart_write_line( "[LUA] abort" );
    for( ;; ) {
        __asm volatile ( "nop" );
    }
}
