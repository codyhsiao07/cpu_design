/* Runs real RV32 soft-float calls on the CPU, without a host libc oracle.
 * TEST=0 EXPECT_RD=8 EXPECT_VAL=51a0c0de; failure mask is in audit_failures.
 */
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <float.h>
#include "lua_rtos_config.h"

volatile uint32_t audit_failures;
volatile float audit_values[] = {1.0e-20f, 1.0e20f, 4294967296.0f, 3.0f, 16.0f, 0.25f};

static void check(int ok, unsigned bit) {
    if (!ok) audit_failures |= 1u << bit;
}

int main(void) {
    char text[64];
    char *end;
    float value;
    union { uint32_t bits; float number; } infinity = {0x7f800000u};

    value = sqrtf(audit_values[0]);
    check(value > 0.99999e-10f && value < 1.00001e-10f, 0);
    value = sqrtf(audit_values[1]);
    check(value > 0.99999e10f && value < 1.00001e10f, 1);
    check(fmodf(audit_values[2], audit_values[3]) == 1.0f, 2);
    check(powf(audit_values[4], audit_values[5]) == 2.0f, 3);
    rtos_lua_number2str(text, sizeof(text), infinity.number);
    check(strcmp(text, "inf") == 0, 4);
    rtos_lua_number2str(text, sizeof(text), -infinity.number);
    check(strcmp(text, "-inf") == 0, 5);
    text[0] = 'X'; text[1] = 'Y';
    check(rtos_lua_integer2str(text, 1, -1) == 0 && text[0] == '\0' && text[1] == 'Y', 6);
    text[0] = 'X';
    check(rtos_lua_number2str(text, 1, -1.0f) == 0 && text[0] == '\0', 7);
    value = rtos_lua_strx2number("0x1p4294967296", &end);
    check(value == infinity.number && *end == '\0', 8);
    value = rtos_lua_strx2number("0x1p-4294967296", &end);
    check(value == 0.0f && *end == '\0', 9);
    check(strtof("4294967296.0", &end) == 4294967296.0f && *end == '\0', 10);
    check(strtof("100000000000000000000000000000000000000000000000000e-50", &end)
          == 1.0f && *end == '\0', 11);
    check(strtof("1e-45", &end) == 0x1p-149f && *end == '\0', 12);
    check(strtof("3.4028235e38", &end) == FLT_MAX && *end == '\0', 13);
    check(strtof("0e999999999999", &end) == 0.0f && *end == '\0', 14);
    check(strtof("1e+", &end) == 1.0f && *end == 'e', 15);
    return audit_failures ? (int)(0xBAD00000u | audit_failures) : 0x51a0c0de;
}
