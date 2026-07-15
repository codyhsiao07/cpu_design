#ifndef OS_RTOS_LUA_RTOS_CONFIG_H
#define OS_RTOS_LUA_RTOS_CONFIG_H

#ifndef __ASSEMBLER__

#include <stddef.h>
#include <stdint.h>

typedef void * RtosLuaJumpBuffer_t[ 5 ];

int rtos_lua_integer2str( char * buffer, size_t size, int32_t value );
int rtos_lua_number2str( char * buffer, size_t size, float value );
int rtos_lua_pointer2str( char * buffer, size_t size, const void * value );
float rtos_lua_strx2number( const char * text, char ** endptr );
unsigned int rtos_lua_seed( void );
void rtos_lua_writestring( const char * text, size_t length );
void rtos_lua_writeline( void );
void rtos_lua_writestringerror( const char * prefix, const char * detail );

#define LUA_USE_RTOS                 1
#define lua_integer2str( s, sz, n )  rtos_lua_integer2str( ( s ), ( sz ), ( int32_t ) ( n ) )
#define lua_number2str( s, sz, n )   rtos_lua_number2str( ( s ), ( sz ), ( float ) ( n ) )
#define lua_pointer2str( s, sz, p )  rtos_lua_pointer2str( ( s ), ( sz ), ( p ) )
#define lua_strx2number( s, p )      rtos_lua_strx2number( ( s ), ( p ) )
#define lua_getlocaledecpoint()      '.'

#define lua_writestring( s, l )      rtos_lua_writestring( ( s ), ( l ) )
#define lua_writeline()              rtos_lua_writeline()
#define lua_writestringerror( s, p ) rtos_lua_writestringerror( ( s ), ( p ) )

#define luai_makeseed( L )           ( ( void ) ( L ), rtos_lua_seed() )
#define l_randomizePivot()           rtos_lua_seed()

#define luai_jmpbuf                  RtosLuaJumpBuffer_t
#define LUAI_TRY( L, c, a )          if( __builtin_setjmp( ( c )->b ) == 0 ) { a }
#define LUAI_THROW( L, c )           do { ( void ) ( L ); __builtin_longjmp( ( c )->b, 1 ); } while( 0 )

#endif

#endif
