#include "perf_counters.h"

#define PERF_ID_REG          ( *( volatile uint32_t * ) ( PERF_COUNTER_MMIO_BASE + 0x00u ) )
#define PERF_INFO_REG        ( *( volatile uint32_t * ) ( PERF_COUNTER_MMIO_BASE + 0x04u ) )
#define PERF_CONTROL_REG     ( *( volatile uint32_t * ) ( PERF_COUNTER_MMIO_BASE + 0x08u ) )
#define PERF_STATUS_REG      ( *( volatile uint32_t * ) ( PERF_COUNTER_MMIO_BASE + 0x0Cu ) )
#define PERF_COUNTER_REGS    ( ( volatile uint32_t * ) ( PERF_COUNTER_MMIO_BASE + 0x10u ) )

#define PERF_CONTROL_ENABLE            ( 1u << 0u )
#define PERF_CONTROL_CLEAR             ( 1u << 1u )
#define PERF_CONTROL_SNAPSHOT          ( 1u << 2u )
#define PERF_CONTROL_RELEASE_SNAPSHOT  ( 1u << 3u )

static void perf_io_barrier( void ) {
    __asm volatile ( "" ::: "memory" );
}

int perf_counters_available( void ) {
    uint32_t info;

    if( PERF_ID_REG != PERF_COUNTER_EXPECTED_ID ) {
        return 0;
    }
    info = PERF_INFO_REG;
    return ( ( info >> 16u ) == PERF_COUNTER_ABI_VERSION ) &&
           ( ( info & 0xFFu ) >= PERF_COUNTER_COUNT );
}

uint32_t perf_counters_info( void ) {
    return PERF_INFO_REG;
}

uint32_t perf_counters_status( void ) {
    return PERF_STATUS_REG;
}

void perf_counters_reset_start( void ) {
    PERF_CONTROL_REG = PERF_CONTROL_ENABLE | PERF_CONTROL_CLEAR;
    perf_io_barrier();
}

void perf_counters_reset_stop( void ) {
    PERF_CONTROL_REG = PERF_CONTROL_CLEAR;
    perf_io_barrier();
}

void perf_counters_start( void ) {
    PERF_CONTROL_REG = PERF_CONTROL_ENABLE | PERF_CONTROL_RELEASE_SNAPSHOT;
    perf_io_barrier();
}

void perf_counters_stop( void ) {
    PERF_CONTROL_REG = PERF_CONTROL_RELEASE_SNAPSHOT;
    perf_io_barrier();
}

int perf_counters_snapshot( PerfCounterSnapshot_t * snapshot, int stop_after ) {
    uint32_t control;
    uint32_t index;

    if( ( snapshot == ( PerfCounterSnapshot_t * ) 0 ) ||
        ( perf_counters_available() == 0 ) ) {
        return 0;
    }

    control = PERF_CONTROL_REG & PERF_CONTROL_ENABLE;
    if( stop_after != 0 ) {
        control = 0u;
    }
    PERF_CONTROL_REG = control | PERF_CONTROL_SNAPSHOT;
    perf_io_barrier();

    snapshot->status = PERF_STATUS_REG;
    for( index = 0u; index < PERF_COUNTER_COUNT; index++ ) {
        uint32_t low = PERF_COUNTER_REGS[ index * 2u ];
        uint32_t high = PERF_COUNTER_REGS[ ( index * 2u ) + 1u ];
        snapshot->value[ index ] = ( ( uint64_t ) high << 32u ) | low;
    }

    if( stop_after == 0 ) {
        PERF_CONTROL_REG = control | PERF_CONTROL_RELEASE_SNAPSHOT;
        perf_io_barrier();
    }
    return 1;
}

const char * perf_counter_name( uint32_t index ) {
    static const char * const names[ PERF_COUNTER_COUNT ] = {
        "cycles", "instret", "frontend_stall", "backend_stall",
        "load_use", "ex_busy", "branches", "branch_taken",
        "jumps", "control_mispredict", "loads", "stores",
        "icache_access", "icache_miss", "dcache_access", "dcache_miss",
        "dcache_wb_beats", "mmio_read", "mmio_write", "ddr_read",
        "ddr_write", "exceptions", "interrupts", "pipeline_flush"
    };

    if( index >= PERF_COUNTER_COUNT ) {
        return "unknown";
    }
    return names[ index ];
}

uint32_t perf_counters_per_mille( uint64_t numerator, uint64_t denominator ) {
    const uint64_t max_value = ~( ( uint64_t ) 0u );
    uint64_t scaled;

    if( denominator == 0u ) {
        return 0u;
    }
    while( ( numerator > ( max_value / 1000u ) ) ||
           ( denominator > ( max_value / 1000u ) ) ) {
        numerator >>= 1u;
        denominator >>= 1u;
    }
    if( denominator == 0u ) {
        return 0u;
    }
    scaled = ( numerator * 1000u ) / denominator;
    if( scaled > 0xFFFFFFFFu ) {
        return 0xFFFFFFFFu;
    }
    return ( uint32_t ) scaled;
}
