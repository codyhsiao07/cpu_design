#include <stddef.h>

void * memset( void * dest, int value, size_t size ) {
    unsigned char * d = ( unsigned char * ) dest;
    size_t i;

    for( i = 0u; i < size; ++i ) {
        d[ i ] = ( unsigned char ) value;
    }
    return dest;
}

void * memcpy( void * dest, const void * src, size_t size ) {
    unsigned char * d = ( unsigned char * ) dest;
    const unsigned char * s = ( const unsigned char * ) src;
    size_t i;

    for( i = 0u; i < size; ++i ) {
        d[ i ] = s[ i ];
    }
    return dest;
}

void * memmove( void * dest, const void * src, size_t size ) {
    unsigned char * d = ( unsigned char * ) dest;
    const unsigned char * s = ( const unsigned char * ) src;

    if( ( d == s ) || ( size == 0u ) ) {
        return dest;
    }

    if( d < s ) {
        size_t i;
        for( i = 0u; i < size; ++i ) {
            d[ i ] = s[ i ];
        }
    } else {
        while( size > 0u ) {
            size--;
            d[ size ] = s[ size ];
        }
    }
    return dest;
}

int memcmp( const void * a, const void * b, size_t size ) {
    const unsigned char * pa = ( const unsigned char * ) a;
    const unsigned char * pb = ( const unsigned char * ) b;
    size_t i;

    for( i = 0u; i < size; ++i ) {
        if( pa[ i ] != pb[ i ] ) {
            return ( int ) pa[ i ] - ( int ) pb[ i ];
        }
    }
    return 0;
}

size_t strlen( const char * text ) {
    size_t n = 0u;

    while( text[ n ] != '\0' ) {
        n++;
    }
    return n;
}
