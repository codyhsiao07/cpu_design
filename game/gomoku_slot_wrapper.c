#include "games_shared_ui.h"
#include "launcher_jump.h"

int gomoku_vga_slot_entry(void);

int main(void)
{
    ui_set_input_policy(UI_INPUT_POLICY_IGNORE_Q);
    ui_drain_input_limited(8u);
    ui_input_barrier();
    ui_launcher_sync_button_state();
    ui_launcher_ignore_button_polls(2048u);
    (void)gomoku_vga_slot_entry();
    ui_input_barrier();
    launcher_jump_to_menu();
    return 0;
}
