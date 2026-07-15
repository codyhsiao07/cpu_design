#ifndef OS_RTOS_PERF_COUNTERS_H
#define OS_RTOS_PERF_COUNTERS_H

#include <stdint.h>

#define PERF_COUNTER_MMIO_BASE       0x40000100u
#define PERF_COUNTER_EXPECTED_ID     0x50455246u
#define PERF_COUNTER_ABI_VERSION     1u
#define PERF_COUNTER_COUNT           24u

typedef enum PerfCounterIndex {
    PERF_CYCLES = 0,
    PERF_INST_RETIRED,
    PERF_FRONTEND_STALL_CYCLES,
    PERF_BACKEND_STALL_CYCLES,
    PERF_LOAD_USE_HAZARD_CYCLES,
    PERF_EX_BUSY_CYCLES,
    PERF_BRANCHES,
    PERF_BRANCH_TAKEN,
    PERF_JUMPS,
    PERF_CONTROL_MISPREDICTS,
    PERF_LOADS,
    PERF_STORES,
    PERF_ICACHE_ACCESSES,
    PERF_ICACHE_MISSES,
    PERF_DCACHE_ACCESSES,
    PERF_DCACHE_MISSES,
    PERF_DCACHE_WRITEBACK_BEATS,
    PERF_MMIO_READS,
    PERF_MMIO_WRITES,
    PERF_DDR_READ_COMMANDS,
    PERF_DDR_WRITE_COMMANDS,
    PERF_EXCEPTIONS,
    PERF_INTERRUPTS,
    PERF_PIPELINE_FLUSHES
} PerfCounterIndex_t;

typedef struct PerfCounterSnapshot {
    uint64_t value[ PERF_COUNTER_COUNT ];
    uint32_t status;
} PerfCounterSnapshot_t;

int perf_counters_available( void );
uint32_t perf_counters_info( void );
uint32_t perf_counters_status( void );
void perf_counters_reset_start( void );
void perf_counters_reset_stop( void );
void perf_counters_start( void );
void perf_counters_stop( void );
int perf_counters_snapshot( PerfCounterSnapshot_t * snapshot, int stop_after );
const char * perf_counter_name( uint32_t index );
uint32_t perf_counters_per_mille( uint64_t numerator, uint64_t denominator );

#endif
