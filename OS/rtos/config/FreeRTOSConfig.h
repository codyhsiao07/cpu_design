#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#include <stdint.h>

#define configUSE_PREEMPTION                    1
#define configUSE_TIME_SLICING                  1
#ifndef configUSE_PORT_OPTIMISED_TASK_SELECTION
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 1
#endif
#define configTICK_TYPE_WIDTH_IN_BITS           TICK_TYPE_WIDTH_32_BITS

/* The MIG-backed board runs the core from the 50 MHz MIG ui_clk. */
#ifndef configCPU_CLOCK_HZ
#define configCPU_CLOCK_HZ                      ( ( uint32_t ) 50000000UL )
#endif

#ifndef configTICK_RATE_HZ
#define configTICK_RATE_HZ                      ( ( uint32_t ) 1000UL )
#endif

#define configMAX_PRIORITIES                    5
#define configMINIMAL_STACK_SIZE                ( ( uint16_t ) 128 )
#define configMAX_TASK_NAME_LEN                 12
#define configIDLE_SHOULD_YIELD                 1
#define configUSE_IDLE_HOOK                     0
#define configUSE_TICK_HOOK                     0
#define configUSE_DAEMON_TASK_STARTUP_HOOK      0
#define configUSE_MALLOC_FAILED_HOOK            1
#ifndef configCHECK_FOR_STACK_OVERFLOW
#define configCHECK_FOR_STACK_OVERFLOW          2
#endif
#define configUSE_TRACE_FACILITY                1
#define configUSE_STATS_FORMATTING_FUNCTIONS    0
#define configGENERATE_RUN_TIME_STATS           1
#define configUSE_APPLICATION_TASK_TAG          0
#define configUSE_NEWLIB_REENTRANT              0
#define configUSE_POSIX_ERRNO                   0

#define configSUPPORT_STATIC_ALLOCATION         1
#define configSUPPORT_DYNAMIC_ALLOCATION        1
#define configAPPLICATION_ALLOCATED_HEAP         1
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) ( 2UL * 1024UL * 1024UL ) )

#define configUSE_TASK_NOTIFICATIONS            1
#define configTASK_NOTIFICATION_ARRAY_ENTRIES   1
#define configUSE_MUTEXES                       1
#define configUSE_RECURSIVE_MUTEXES             1
#define configUSE_COUNTING_SEMAPHORES           1
#define configUSE_QUEUE_SETS                    1
#define configUSE_TIMERS                        1
#define configTIMER_TASK_PRIORITY               ( configMAX_PRIORITIES - 1 )
#define configTIMER_QUEUE_LENGTH                 8
#define configTIMER_TASK_STACK_DEPTH            512
#define configUSE_CO_ROUTINES                   0
#define configQUEUE_REGISTRY_SIZE               16

#define configNUMBER_OF_CORES                   1
#define configRUN_MULTIPLE_PRIORITIES           0
#define configUSE_CORE_AFFINITY                 0
#define configUSE_PASSIVE_IDLE_HOOK             0
#define configUSE_MINI_LIST_ITEM                1
#define configENABLE_BACKWARD_COMPATIBILITY     1

#define configISR_STACK_SIZE_WORDS              256
#ifndef configMTIME_BASE_ADDRESS
#define configMTIME_BASE_ADDRESS                ( 0x40000020UL )
#endif

#ifndef configMTIMECMP_BASE_ADDRESS
#define configMTIMECMP_BASE_ADDRESS             ( 0x40000028UL )
#endif

#define INCLUDE_vTaskDelay                      1
#define INCLUDE_xTaskDelayUntil                 1
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_vTaskSuspend                    1
#define INCLUDE_xTaskGetCurrentTaskHandle       1
#define INCLUDE_xTaskGetSchedulerState          1
#define INCLUDE_uxTaskPriorityGet               1
#define INCLUDE_vTaskPrioritySet                1
#define INCLUDE_eTaskGetState                   1
#define INCLUDE_xTimerPendFunctionCall          1
#define INCLUDE_uxTaskGetStackHighWaterMark     1
#define INCLUDE_uxTaskGetStackHighWaterMark2    1
#define INCLUDE_xTaskGetIdleTaskHandle          1

#ifndef __ASSEMBLER__
static inline uint32_t rtos_run_time_counter_value( void ) {
    return *( ( volatile uint32_t * ) 0x40000020u );
}
#define portCONFIGURE_TIMER_FOR_RUN_TIME_STATS() do { } while( 0 )
#define portGET_RUN_TIME_COUNTER_VALUE()         rtos_run_time_counter_value()
#endif

#ifndef __ASSEMBLER__
void vAssertCalled( const char * file, unsigned long line );

#endif

#define configASSERT( x )                       do { if( ( x ) == 0 ) { vAssertCalled( __FILE__, __LINE__ ); } } while( 0 )

#endif
