#ifndef LAUNCHER_JUMP_H
#define LAUNCHER_JUMP_H

__attribute__((noreturn)) void launcher_jump_to_address(unsigned int addr);
__attribute__((noreturn)) void launcher_jump_to_menu(void);
__attribute__((noreturn)) void launcher_jump_to_menu_soft_reset(void);

#endif
