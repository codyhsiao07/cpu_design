#include "launcher_jump.h"
#include "launcher_slots.h"

__attribute__((noreturn)) void launcher_jump_to_address(unsigned int addr)
{
    __asm__ volatile(
        "jalr x0, 0(%0)\n"
        :
        : "r"(addr)
        : "memory");

    for (;;) {
    }
}

__attribute__((noreturn)) void launcher_jump_to_menu(void)
{
#if defined(LAUNCHER_MENU_RETURN_ADDR)
    launcher_jump_to_address(LAUNCHER_MENU_RETURN_ADDR);
#else
    launcher_jump_to_address(LAUNCHER_MENU_ADDR);
#endif
}

__attribute__((noreturn)) void launcher_jump_to_menu_soft_reset(void)
{
#if defined(LAUNCHER_MENU_SOFT_RESET_ADDR)
    launcher_jump_to_address(LAUNCHER_MENU_SOFT_RESET_ADDR);
#else
    launcher_jump_to_menu();
#endif
}
