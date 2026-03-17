#include "games_shared_ui.h"
#include "launcher_jump.h"

#ifndef LAUNCHER_INPUT_POLICY
#define LAUNCHER_INPUT_POLICY UI_INPUT_POLICY_NORMAL
#endif

void launcher_slot_before_main(void)
{
    ui_set_input_policy((ui_input_policy_t)LAUNCHER_INPUT_POLICY);
    ui_input_barrier();
    ui_launcher_sync_button_state();
    ui_launcher_ignore_button_polls(2048u);
}

void launcher_slot_after_main(void)
{
    ui_input_barrier();
    launcher_jump_to_menu();
}
