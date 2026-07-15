#include <stddef.h>
#include <stdint.h>

#include "FreeRTOS.h"

#define RTOS_ALLOC_MAGIC 0xA110CA7Eu

typedef struct RtosAllocHeader {
    size_t size;
    uint32_t magic;
    uint32_t reserved0;
    uint32_t reserved1;
} RtosAllocHeader_t;

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

void * malloc( size_t size ) {
    RtosAllocHeader_t * header;

    if( size == 0u ) {
        size = 1u;
    }
    if( size > ( ( size_t ) -1 ) - sizeof( RtosAllocHeader_t ) ) {
        return NULL;
    }
    header = ( RtosAllocHeader_t * ) pvPortMalloc( size + sizeof( RtosAllocHeader_t ) );
    if( header == NULL ) {
        return NULL;
    }
    header->size = size;
    header->magic = RTOS_ALLOC_MAGIC;
    header->reserved0 = 0u;
    header->reserved1 = 0u;
    return ( void * ) ( header + 1 );
}

void free( void * ptr ) {
    RtosAllocHeader_t * header;

    if( ptr == NULL ) {
        return;
    }
    header = ( ( RtosAllocHeader_t * ) ptr ) - 1;
    configASSERT( header->magic == RTOS_ALLOC_MAGIC );
    header->magic = 0u;
    vPortFree( header );
}

void * calloc( size_t count, size_t size ) {
    size_t total;
    void * ptr;

    if( ( size != 0u ) && ( count > ( ( size_t ) -1 ) / size ) ) {
        return NULL;
    }
    total = count * size;
    ptr = malloc( total );
    if( ptr != NULL ) {
        memset( ptr, 0, total );
    }
    return ptr;
}

void * realloc( void * ptr, size_t size ) {
    RtosAllocHeader_t * old_header;
    void * new_ptr;
    size_t copy_size;

    if( ptr == NULL ) {
        return malloc( size );
    }
    if( size == 0u ) {
        free( ptr );
        return NULL;
    }
    old_header = ( ( RtosAllocHeader_t * ) ptr ) - 1;
    configASSERT( old_header->magic == RTOS_ALLOC_MAGIC );
    new_ptr = malloc( size );
    if( new_ptr == NULL ) {
        return NULL;
    }
    copy_size = old_header->size < size ? old_header->size : size;
    memcpy( new_ptr, ptr, copy_size );
    free( ptr );
    return new_ptr;
}
