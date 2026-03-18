#include "games_shared_ui.h"
#include "vga_fb.h"
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
#include "launcher_jump.h"
#endif

#define SCREEN_W 160u
#define SCREEN_H 120u

#define TITLE_X 4u
#define TITLE_Y 4u
#define TITLE_W 152u
#define TITLE_H 12u

#define BOARD_PANEL_X 4u
#define BOARD_PANEL_Y 18u
#define BOARD_PANEL_W 98u
#define BOARD_PANEL_H 90u
#define BOARD_X 10u
#define BOARD_Y 21u
#define CELL_SIZE 11u
#define BOARD_PIXELS 88u

#define PANEL_X 106u
#define PANEL_Y 18u
#define PANEL_W 50u
#define PANEL_H 90u
#define PANEL_BOX_X 111u
#define PANEL_BOX_W 40u
#define PANEL_BOX_H 10u
#define PANEL_MODE_Y 25u
#define PANEL_TURN_Y 41u
#define PANEL_STATE_Y 57u
#define PANEL_LAST_Y 73u
#define PANEL_NOTE_Y 89u

#define FOOTER_X 4u
#define FOOTER_Y 111u
#define FOOTER_W 152u
#define FOOTER_H 7u

#define MENU_PANEL_X 18u
#define MENU_PANEL_Y 20u
#define MENU_PANEL_W 124u
#define MENU_PANEL_H 82u
#define MENU_BOX_X 25u
#define MENU_BOX_W 110u
#define MENU_BOX_H 16u
#define MENU_BOX1_Y 40u
#define MENU_BOX2_Y 59u
#define MENU_BOX3_Y 78u

#define OVERLAY_X 22u
#define OVERLAY_Y 46u
#define OVERLAY_W 116u
#define OVERLAY_H 28u

#define BOARD_SIZE 8
#define MOVE_MAX 256u

#define VIEW_MENU 0
#define VIEW_GAME 1

#define MODE_TWO 0
#define MODE_AI_MED 1
#define MODE_AI_STRONG 2

#define RESULT_NONE 0
#define RESULT_WHITE_WIN 1
#define RESULT_BLACK_WIN 2
#define RESULT_DRAW 3

#define NOTE_READY 0
#define NOTE_PICK 1
#define NOTE_MOVE 2
#define NOTE_BAD_PICK 3
#define NOTE_NO_MOVE 4
#define NOTE_CHECK 5
#define NOTE_AI 6
#define NOTE_AUTOQ 7

#define SIDE_WHITE 0
#define SIDE_BLACK 1

#define PIECE_EMPTY 0u
#define PIECE_PAWN 1u
#define PIECE_KNIGHT 2u
#define PIECE_BISHOP 3u
#define PIECE_ROOK 4u
#define PIECE_QUEEN 5u
#define PIECE_KING 6u
#define PIECE_BLACK 8u
#define PIECE_TYPE_MASK 7u
#define PIECE_COLOR_MASK 8u

#define CASTLE_WHITE_K 0x1u
#define CASTLE_WHITE_Q 0x2u
#define CASTLE_BLACK_K 0x4u
#define CASTLE_BLACK_Q 0x8u

#define MOVE_CAPTURE 0x1u
#define MOVE_CASTLE_K 0x2u
#define MOVE_CASTLE_Q 0x4u
#define MOVE_EN_PASSANT 0x8u
#define MOVE_PROMOTE 0x10u
#define MOVE_PAWN_DOUBLE 0x20u

#define AI_MED_DEPTH 1u
#define AI_STRONG_DEPTH 2u
#define SEARCH_INF 300000
#define SEARCH_MATE 250000

#define POLL_SPIN 2600u

#define COLOR_BG 10u
#define COLOR_PANEL 13u
#define COLOR_CARD 0u
#define COLOR_FRAME 6u
#define COLOR_TEXT 7u
#define COLOR_LABEL 14u
#define COLOR_TEXT_SHADOW 0u
#define COLOR_SHADOW 8u
#define COLOR_ACCENT 11u
#define COLOR_OVERLAY 12u
#define COLOR_LIGHT_SQUARE 11u
#define COLOR_DARK_SQUARE 3u
#define COLOR_LAST_FROM 6u
#define COLOR_LAST_TO 14u
#define COLOR_CURSOR 15u
#define COLOR_SELECT 1u
#define COLOR_HINT 14u
#define COLOR_WHITE_PIECE 15u
#define COLOR_WHITE_EDGE 14u
#define COLOR_BLACK_PIECE 0u
#define COLOR_BLACK_EDGE 8u
#define COLOR_WHITE_LETTER 0u
#define COLOR_BLACK_LETTER 15u
#define COLOR_STATUS_GOOD 2u
#define COLOR_STATUS_WARN 4u
#define COLOR_STATUS_BAD 1u
#define COLOR_MENU_FILL 13u
#define COLOR_MENU_SEL 7u

typedef struct {
    unsigned char board[BOARD_SIZE][BOARD_SIZE];
    unsigned char side_to_move;
    unsigned char castling_rights;
    signed char ep_x;
    signed char ep_y;
    unsigned char king_x[2];
    unsigned char king_y[2];
    unsigned int fullmove;
} chess_state_t;

typedef struct {
    unsigned char from_x;
    unsigned char from_y;
    unsigned char to_x;
    unsigned char to_y;
    unsigned char flags;
    unsigned char promote;
    int order_score;
} chess_move_t;

static chess_state_t game_state;
static chess_move_t legal_moves[MOVE_MAX];
static unsigned int legal_move_count = 0u;
static int view_mode = VIEW_MENU;
static int game_mode = MODE_TWO;
static int menu_selection = 0;
static int cursor_x = 4;
static int cursor_y = 6;
static int selected_x = -1;
static int selected_y = -1;
static int result_code = RESULT_NONE;
static int note_code = NOTE_READY;
static int swallow_lf = 0;
static int scene_valid = 0;
static int need_redraw = 1;
static int last_from_x = -1;
static int last_from_y = -1;
static int last_to_x = -1;
static int last_to_y = -1;
static unsigned int rng_state = 0x3A71C52Du;
static int launcher_exit_pending = 0;

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
static __attribute__((noreturn)) void launcher_button_return(void)
{
    ui_input_barrier();
    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();
#if defined(LAUNCHER_DIRECT_MENU_JUMP)
    launcher_jump_to_menu_soft_reset();
#else
    ui_launcher_request_menu();
    for (;;) {
    }
#endif
}

static void launcher_abort_if_requested(void)
{
    if (ui_launcher_menu_requested()) {
        launcher_exit_pending = 1;
    }
}
#endif

static int abs_i(int value)
{
    return (value < 0) ? -value : value;
}

static int inside_board(int x, int y)
{
    return x >= 0 && x < BOARD_SIZE && y >= 0 && y < BOARD_SIZE;
}

static unsigned int random_next(void)
{
    rng_state = (rng_state * 1664525u) + 1013904223u;
    return rng_state;
}

static unsigned char make_piece(int side, unsigned char type)
{
    return (unsigned char)(((side == SIDE_BLACK) ? PIECE_BLACK : 0u) | type);
}

static int piece_side(unsigned char piece)
{
    return ((piece & PIECE_COLOR_MASK) != 0u) ? SIDE_BLACK : SIDE_WHITE;
}

static unsigned char piece_type(unsigned char piece)
{
    return (unsigned char)(piece & PIECE_TYPE_MASK);
}

static int is_side_piece(unsigned char piece, int side)
{
    return piece != PIECE_EMPTY && piece_side(piece) == side;
}

static int is_enemy_piece(unsigned char piece, int side)
{
    return piece != PIECE_EMPTY && piece_side(piece) != side;
}

static int piece_value(unsigned char piece)
{
    switch (piece_type(piece)) {
    case PIECE_PAWN:   return 100;
    case PIECE_KNIGHT: return 320;
    case PIECE_BISHOP: return 330;
    case PIECE_ROOK:   return 500;
    case PIECE_QUEEN:  return 900;
    case PIECE_KING:   return 20000;
    default:           return 0;
    }
}

static void fill_rect(unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned char color)
{
    unsigned int xx;
    unsigned int yy;

    if (x >= SCREEN_W || y >= SCREEN_H || w == 0u || h == 0u) {
        return;
    }
    if ((x + w) > SCREEN_W) {
        w = SCREEN_W - x;
    }
    if ((y + h) > SCREEN_H) {
        h = SCREEN_H - y;
    }

    if (((x & 3u) == 0u) && ((w & 3u) == 0u)) {
        vga_fb_fill_rect4(x, y, w, h, color);
        return;
    }

    for (yy = 0u; yy < h; yy++) {
        for (xx = 0u; xx < w; xx++) {
            vga_fb_put_pixel(x + xx, y + yy, color);
        }
    }
}

static void draw_frame(unsigned int x, unsigned int y, unsigned int w, unsigned int h,
                       unsigned char frame_color, unsigned char fill_color)
{
    fill_rect(x, y, w, h, frame_color);
    if (w > 2u && h > 2u) {
        fill_rect(x + 1u, y + 1u, w - 2u, h - 2u, fill_color);
    }
}

static void draw_block(unsigned int x, unsigned int y, unsigned int scale, unsigned char color)
{
    fill_rect(x, y, scale, scale, color);
}

static const unsigned char *glyph_rows_for(int ch)
{
    static const unsigned char glyph_space[5] = {0x0, 0x0, 0x0, 0x0, 0x0};
    static const unsigned char glyph_dash[5] = {0x0, 0x0, 0x7, 0x0, 0x0};
    static const unsigned char glyph_0[5] = {0x7, 0x5, 0x5, 0x5, 0x7};
    static const unsigned char glyph_1[5] = {0x2, 0x6, 0x2, 0x2, 0x7};
    static const unsigned char glyph_2[5] = {0x7, 0x1, 0x7, 0x4, 0x7};
    static const unsigned char glyph_3[5] = {0x7, 0x1, 0x7, 0x1, 0x7};
    static const unsigned char glyph_4[5] = {0x5, 0x5, 0x7, 0x1, 0x1};
    static const unsigned char glyph_5[5] = {0x7, 0x4, 0x7, 0x1, 0x7};
    static const unsigned char glyph_6[5] = {0x7, 0x4, 0x7, 0x5, 0x7};
    static const unsigned char glyph_7[5] = {0x7, 0x1, 0x2, 0x2, 0x2};
    static const unsigned char glyph_8[5] = {0x7, 0x5, 0x7, 0x5, 0x7};
    static const unsigned char glyph_9[5] = {0x7, 0x5, 0x7, 0x1, 0x7};
    static const unsigned char glyph_a[5] = {0x2, 0x5, 0x7, 0x5, 0x5};
    static const unsigned char glyph_b[5] = {0x6, 0x5, 0x6, 0x5, 0x6};
    static const unsigned char glyph_c[5] = {0x7, 0x4, 0x4, 0x4, 0x7};
    static const unsigned char glyph_d[5] = {0x6, 0x5, 0x5, 0x5, 0x6};
    static const unsigned char glyph_e[5] = {0x7, 0x4, 0x6, 0x4, 0x7};
    static const unsigned char glyph_f[5] = {0x7, 0x4, 0x6, 0x4, 0x4};
    static const unsigned char glyph_g[5] = {0x7, 0x4, 0x5, 0x5, 0x7};
    static const unsigned char glyph_h[5] = {0x5, 0x5, 0x7, 0x5, 0x5};
    static const unsigned char glyph_i[5] = {0x7, 0x2, 0x2, 0x2, 0x7};
    static const unsigned char glyph_k[5] = {0x5, 0x5, 0x6, 0x5, 0x5};
    static const unsigned char glyph_l[5] = {0x4, 0x4, 0x4, 0x4, 0x7};
    static const unsigned char glyph_m[5] = {0x5, 0x7, 0x7, 0x5, 0x5};
    static const unsigned char glyph_n[5] = {0x5, 0x7, 0x7, 0x7, 0x5};
    static const unsigned char glyph_o[5] = {0x7, 0x5, 0x5, 0x5, 0x7};
    static const unsigned char glyph_p[5] = {0x6, 0x5, 0x6, 0x4, 0x4};
    static const unsigned char glyph_q[5] = {0x7, 0x5, 0x5, 0x7, 0x1};
    static const unsigned char glyph_r[5] = {0x6, 0x5, 0x6, 0x5, 0x5};
    static const unsigned char glyph_s[5] = {0x7, 0x4, 0x7, 0x1, 0x7};
    static const unsigned char glyph_t[5] = {0x7, 0x2, 0x2, 0x2, 0x2};
    static const unsigned char glyph_u[5] = {0x5, 0x5, 0x5, 0x5, 0x7};
    static const unsigned char glyph_v[5] = {0x5, 0x5, 0x5, 0x5, 0x2};
    static const unsigned char glyph_w[5] = {0x5, 0x5, 0x7, 0x7, 0x5};
    static const unsigned char glyph_y[5] = {0x5, 0x5, 0x2, 0x2, 0x2};

    if (ch >= 'a' && ch <= 'z') {
        ch -= ('a' - 'A');
    }

    switch (ch) {
    case '0': return glyph_0;
    case '1': return glyph_1;
    case '2': return glyph_2;
    case '3': return glyph_3;
    case '4': return glyph_4;
    case '5': return glyph_5;
    case '6': return glyph_6;
    case '7': return glyph_7;
    case '8': return glyph_8;
    case '9': return glyph_9;
    case 'A': return glyph_a;
    case 'B': return glyph_b;
    case 'C': return glyph_c;
    case 'D': return glyph_d;
    case 'E': return glyph_e;
    case 'F': return glyph_f;
    case 'G': return glyph_g;
    case 'H': return glyph_h;
    case 'I': return glyph_i;
    case 'K': return glyph_k;
    case 'L': return glyph_l;
    case 'M': return glyph_m;
    case 'N': return glyph_n;
    case 'O': return glyph_o;
    case 'P': return glyph_p;
    case 'Q': return glyph_q;
    case 'R': return glyph_r;
    case 'S': return glyph_s;
    case 'T': return glyph_t;
    case 'U': return glyph_u;
    case 'V': return glyph_v;
    case 'W': return glyph_w;
    case 'Y': return glyph_y;
    case '-': return glyph_dash;
    case ' ': return glyph_space;
    default:  return glyph_space;
    }
}

static unsigned int text_width(const char *text, unsigned int scale)
{
    unsigned int width = 0u;
    unsigned int step = scale << 2;

    while (*text != '\0') {
        width += step;
        text++;
    }
    if (width == 0u) {
        return 0u;
    }
    return width - scale;
}

static void draw_char(unsigned int x, unsigned int y, int ch, unsigned int scale, unsigned char color)
{
    const unsigned char *rows = glyph_rows_for(ch);
    unsigned int row;
    unsigned int row_y = y;

    for (row = 0u; row < 5u; row++) {
        unsigned int col_x = x;
        if ((rows[row] & 0x4u) != 0u) {
            draw_block(col_x, row_y, scale, color);
        }
        col_x += scale;
        if ((rows[row] & 0x2u) != 0u) {
            draw_block(col_x, row_y, scale, color);
        }
        col_x += scale;
        if ((rows[row] & 0x1u) != 0u) {
            draw_block(col_x, row_y, scale, color);
        }
        row_y += scale;
    }
}

static void draw_text_raw(unsigned int x, unsigned int y, const char *text, unsigned int scale, unsigned char color)
{
    unsigned int step = scale << 2;

    while (*text != '\0') {
        draw_char(x, y, *text, scale, color);
        x += step;
        text++;
    }
}

static void draw_text(unsigned int x, unsigned int y, const char *text, unsigned int scale, unsigned char color)
{
    if (color != COLOR_TEXT_SHADOW) {
        draw_text_raw(x + 1u, y + 1u, text, scale, COLOR_TEXT_SHADOW);
    }
    draw_text_raw(x, y, text, scale, color);
}

static void draw_text_centered(unsigned int x, unsigned int y, unsigned int w,
                               const char *text, unsigned int scale, unsigned char color)
{
    unsigned int width = text_width(text, scale);
    unsigned int start_x = x;

    if (w > width) {
        start_x = x + ((w - width) >> 1);
    }
    draw_text(start_x, y, text, scale, color);
}

static void video_reset(void)
{
    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(COLOR_BG);
    vga_fb_present();
}

static unsigned int board_cell_x(int x)
{
    return BOARD_X + ((unsigned int)x * CELL_SIZE);
}

static unsigned int board_cell_y(int y)
{
    return BOARD_Y + ((unsigned int)y * CELL_SIZE);
}

static char piece_letter(unsigned char piece)
{
    switch (piece_type(piece)) {
    case PIECE_PAWN:   return 'P';
    case PIECE_KNIGHT: return 'N';
    case PIECE_BISHOP: return 'B';
    case PIECE_ROOK:   return 'R';
    case PIECE_QUEEN:  return 'Q';
    case PIECE_KING:   return 'K';
    default:           return ' ';
    }
}

static const char *mode_name(void)
{
    if (game_mode == MODE_AI_MED) {
        return "AI MED";
    }
    if (game_mode == MODE_AI_STRONG) {
        return "AI STRONG";
    }
    return "TWO";
}

static const char *turn_name(void)
{
    return (game_state.side_to_move == SIDE_WHITE) ? "WHITE" : "BLACK";
}

static const char *state_name(void)
{
    if (result_code == RESULT_DRAW) {
        return "DRAW";
    }
    if (result_code != RESULT_NONE) {
        return "MATE";
    }
    if (note_code == NOTE_CHECK) {
        return "CHECK";
    }
    return "READY";
}

static const char *note_name(void)
{
    switch (note_code) {
    case NOTE_PICK:     return "PICK";
    case NOTE_MOVE:     return "GOAL";
    case NOTE_BAD_PICK: return "OWN";
    case NOTE_NO_MOVE:  return "NOMOV";
    case NOTE_CHECK:    return "CHECK";
    case NOTE_AI:       return "AI";
    case NOTE_AUTOQ:    return "QUEEN";
    default:            return "READY";
    }
}

static void square_text(int x, int y, char out[3])
{
    out[0] = (char)('A' + x);
    out[1] = (char)('8' - y);
    out[2] = '\0';
}

static void last_move_text(char out[6])
{
    if (last_from_x < 0 || last_to_x < 0) {
        out[0] = '-';
        out[1] = '-';
        out[2] = '\0';
        return;
    }

    out[0] = (char)('A' + last_from_x);
    out[1] = (char)('8' - last_from_y);
    out[2] = ' ';
    out[3] = (char)('A' + last_to_x);
    out[4] = (char)('8' - last_to_y);
    out[5] = '\0';
}

static int is_square_attacked(const chess_state_t *state, int x, int y, int by_side)
{
    static const int knight_dx[8] = {1, 2, 2, 1, -1, -2, -2, -1};
    static const int knight_dy[8] = {-2, -1, 1, 2, 2, 1, -1, -2};
    static const int bishop_dx[4] = {1, 1, -1, -1};
    static const int bishop_dy[4] = {1, -1, 1, -1};
    static const int rook_dx[4] = {1, -1, 0, 0};
    static const int rook_dy[4] = {0, 0, 1, -1};
    int i;

    if (by_side == SIDE_WHITE) {
        if (inside_board(x - 1, y + 1) && state->board[y + 1][x - 1] == make_piece(SIDE_WHITE, PIECE_PAWN)) {
            return 1;
        }
        if (inside_board(x + 1, y + 1) && state->board[y + 1][x + 1] == make_piece(SIDE_WHITE, PIECE_PAWN)) {
            return 1;
        }
    } else {
        if (inside_board(x - 1, y - 1) && state->board[y - 1][x - 1] == make_piece(SIDE_BLACK, PIECE_PAWN)) {
            return 1;
        }
        if (inside_board(x + 1, y - 1) && state->board[y - 1][x + 1] == make_piece(SIDE_BLACK, PIECE_PAWN)) {
            return 1;
        }
    }

    for (i = 0; i < 8; i++) {
        int nx = x + knight_dx[i];
        int ny = y + knight_dy[i];
        if (inside_board(nx, ny) && state->board[ny][nx] == make_piece(by_side, PIECE_KNIGHT)) {
            return 1;
        }
    }

    for (i = 0; i < 4; i++) {
        int nx = x + bishop_dx[i];
        int ny = y + bishop_dy[i];
        while (inside_board(nx, ny)) {
            unsigned char piece = state->board[ny][nx];
            if (piece != PIECE_EMPTY) {
                if (piece == make_piece(by_side, PIECE_BISHOP) || piece == make_piece(by_side, PIECE_QUEEN)) {
                    return 1;
                }
                break;
            }
            nx += bishop_dx[i];
            ny += bishop_dy[i];
        }
    }

    for (i = 0; i < 4; i++) {
        int nx = x + rook_dx[i];
        int ny = y + rook_dy[i];
        while (inside_board(nx, ny)) {
            unsigned char piece = state->board[ny][nx];
            if (piece != PIECE_EMPTY) {
                if (piece == make_piece(by_side, PIECE_ROOK) || piece == make_piece(by_side, PIECE_QUEEN)) {
                    return 1;
                }
                break;
            }
            nx += rook_dx[i];
            ny += rook_dy[i];
        }
    }

    for (i = -1; i <= 1; i++) {
        int j;
        for (j = -1; j <= 1; j++) {
            if (i == 0 && j == 0) {
                continue;
            }
            if (inside_board(x + i, y + j) &&
                state->board[y + j][x + i] == make_piece(by_side, PIECE_KING)) {
                return 1;
            }
        }
    }

    return 0;
}

static void apply_move(chess_state_t *state, const chess_move_t *move)
{
    unsigned char piece = state->board[move->from_y][move->from_x];
    unsigned char target = state->board[move->to_y][move->to_x];
    int side = piece_side(piece);
    unsigned char type = piece_type(piece);

    state->board[move->from_y][move->from_x] = PIECE_EMPTY;

    if ((move->flags & MOVE_EN_PASSANT) != 0u) {
        int captured_y = move->to_y + ((side == SIDE_WHITE) ? 1 : -1);
        if (inside_board(move->to_x, captured_y)) {
            target = state->board[captured_y][move->to_x];
            state->board[captured_y][move->to_x] = PIECE_EMPTY;
        }
    }

    if ((move->flags & MOVE_CASTLE_K) != 0u) {
        state->board[move->to_y][5] = state->board[move->to_y][7];
        state->board[move->to_y][7] = PIECE_EMPTY;
    } else if ((move->flags & MOVE_CASTLE_Q) != 0u) {
        state->board[move->to_y][3] = state->board[move->to_y][0];
        state->board[move->to_y][0] = PIECE_EMPTY;
    }

    if ((move->flags & MOVE_PROMOTE) != 0u) {
        piece = make_piece(side, move->promote);
    }

    state->board[move->to_y][move->to_x] = piece;

    if (type == PIECE_KING) {
        state->king_x[side] = move->to_x;
        state->king_y[side] = move->to_y;
        if (side == SIDE_WHITE) {
            state->castling_rights &= (unsigned char)(~(CASTLE_WHITE_K | CASTLE_WHITE_Q));
        } else {
            state->castling_rights &= (unsigned char)(~(CASTLE_BLACK_K | CASTLE_BLACK_Q));
        }
    }

    if (type == PIECE_ROOK) {
        if (side == SIDE_WHITE && move->from_y == 7u) {
            if (move->from_x == 0u) {
                state->castling_rights &= (unsigned char)(~CASTLE_WHITE_Q);
            } else if (move->from_x == 7u) {
                state->castling_rights &= (unsigned char)(~CASTLE_WHITE_K);
            }
        } else if (side == SIDE_BLACK && move->from_y == 0u) {
            if (move->from_x == 0u) {
                state->castling_rights &= (unsigned char)(~CASTLE_BLACK_Q);
            } else if (move->from_x == 7u) {
                state->castling_rights &= (unsigned char)(~CASTLE_BLACK_K);
            }
        }
    }

    if (target == make_piece(SIDE_WHITE, PIECE_ROOK) && move->to_y == 7u) {
        if (move->to_x == 0u) {
            state->castling_rights &= (unsigned char)(~CASTLE_WHITE_Q);
        } else if (move->to_x == 7u) {
            state->castling_rights &= (unsigned char)(~CASTLE_WHITE_K);
        }
    } else if (target == make_piece(SIDE_BLACK, PIECE_ROOK) && move->to_y == 0u) {
        if (move->to_x == 0u) {
            state->castling_rights &= (unsigned char)(~CASTLE_BLACK_Q);
        } else if (move->to_x == 7u) {
            state->castling_rights &= (unsigned char)(~CASTLE_BLACK_K);
        }
    }

    state->ep_x = -1;
    state->ep_y = -1;
    if ((move->flags & MOVE_PAWN_DOUBLE) != 0u) {
        state->ep_x = (signed char)move->to_x;
        state->ep_y = (signed char)((move->from_y + move->to_y) >> 1);
    }

    if (side == SIDE_BLACK) {
        state->fullmove++;
    }
    state->side_to_move = (unsigned char)(side ^ 1);
}

static int move_order_hint(const chess_state_t *state, const chess_move_t *move)
{
    int score = 0;
    unsigned char mover = state->board[move->from_y][move->from_x];
    unsigned char captured = state->board[move->to_y][move->to_x];

    if ((move->flags & MOVE_EN_PASSANT) != 0u) {
        captured = make_piece((piece_side(mover) == SIDE_WHITE) ? SIDE_BLACK : SIDE_WHITE, PIECE_PAWN);
    }

    if (captured != PIECE_EMPTY) {
        score += (piece_value(captured) * 10) - piece_value(mover);
    }
    if ((move->flags & MOVE_PROMOTE) != 0u) {
        score += 850;
    }
    if ((move->flags & (MOVE_CASTLE_K | MOVE_CASTLE_Q)) != 0u) {
        score += 60;
    }
    score += 18 - (abs_i((int)move->to_x - 3) + abs_i((int)move->to_y - 3));
    return score;
}

static void sort_moves(chess_move_t *moves, unsigned int count)
{
    unsigned int i;

    for (i = 1u; i < count; i++) {
        chess_move_t key = moves[i];
        unsigned int j = i;
        while (j > 0u && moves[j - 1u].order_score < key.order_score) {
            moves[j] = moves[j - 1u];
            j--;
        }
        moves[j] = key;
    }
}

static void add_legal_move(const chess_state_t *state, chess_move_t *moves, unsigned int *count,
                           int from_x, int from_y, int to_x, int to_y, unsigned char flags, unsigned char promote)
{
    chess_move_t move;
    chess_state_t next;
    int side = state->side_to_move;

    if (*count >= MOVE_MAX) {
        return;
    }

    move.from_x = (unsigned char)from_x;
    move.from_y = (unsigned char)from_y;
    move.to_x = (unsigned char)to_x;
    move.to_y = (unsigned char)to_y;
    move.flags = flags;
    move.promote = promote;
    move.order_score = 0;

    next = *state;
    apply_move(&next, &move);
    if (is_square_attacked(&next, next.king_x[side], next.king_y[side], side ^ 1)) {
        return;
    }

    move.order_score = move_order_hint(state, &move);
    moves[*count] = move;
    (*count)++;
}

static unsigned int generate_legal_moves_for(const chess_state_t *state, chess_move_t *moves)
{
    int y;
    unsigned int count = 0u;
    int side = state->side_to_move;

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
    if (launcher_exit_pending) {
        return 0u;
    }
#endif

    for (y = 0; y < BOARD_SIZE; y++) {
        int x;
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        launcher_abort_if_requested();
        if (launcher_exit_pending) {
            return 0u;
        }
#endif
        for (x = 0; x < BOARD_SIZE; x++) {
            unsigned char piece = state->board[y][x];
            unsigned char type;

            if (!is_side_piece(piece, side)) {
                continue;
            }

            type = piece_type(piece);
            if (type == PIECE_PAWN) {
                int dir = (side == SIDE_WHITE) ? -1 : 1;
                int start_row = (side == SIDE_WHITE) ? 6 : 1;
                int promote_row = (side == SIDE_WHITE) ? 0 : 7;
                int one_y = y + dir;

                if (inside_board(x, one_y) && state->board[one_y][x] == PIECE_EMPTY) {
                    unsigned char flags = 0u;
                    unsigned char promote = 0u;
                    if (one_y == promote_row) {
                        flags |= MOVE_PROMOTE;
                        promote = PIECE_QUEEN;
                    }
                    add_legal_move(state, moves, &count, x, y, x, one_y, flags, promote);
                    if (y == start_row) {
                        int two_y = y + (dir << 1);
                        if (inside_board(x, two_y) && state->board[two_y][x] == PIECE_EMPTY) {
                            add_legal_move(state, moves, &count, x, y, x, two_y, MOVE_PAWN_DOUBLE, 0u);
                        }
                    }
                }

                {
                    int dx;
                    for (dx = -1; dx <= 1; dx += 2) {
                        int nx = x + dx;
                        int ny = y + dir;
                        if (!inside_board(nx, ny)) {
                            continue;
                        }
                        if (is_enemy_piece(state->board[ny][nx], side)) {
                            unsigned char flags = MOVE_CAPTURE;
                            unsigned char promote = 0u;
                            if (ny == promote_row) {
                                flags |= MOVE_PROMOTE;
                                promote = PIECE_QUEEN;
                            }
                            add_legal_move(state, moves, &count, x, y, nx, ny, flags, promote);
                        } else if (state->ep_x == nx && state->ep_y == ny) {
                            add_legal_move(state, moves, &count, x, y, nx, ny,
                                           MOVE_CAPTURE | MOVE_EN_PASSANT, 0u);
                        }
                    }
                }
            } else if (type == PIECE_KNIGHT) {
                static const int knight_dx[8] = {1, 2, 2, 1, -1, -2, -2, -1};
                static const int knight_dy[8] = {-2, -1, 1, 2, 2, 1, -1, -2};
                int i;
                for (i = 0; i < 8; i++) {
                    int nx = x + knight_dx[i];
                    int ny = y + knight_dy[i];
                    if (!inside_board(nx, ny) || is_side_piece(state->board[ny][nx], side)) {
                        continue;
                    }
                    add_legal_move(state, moves, &count, x, y, nx, ny,
                                   (state->board[ny][nx] != PIECE_EMPTY) ? MOVE_CAPTURE : 0u, 0u);
                }
            } else if (type == PIECE_BISHOP || type == PIECE_ROOK || type == PIECE_QUEEN) {
                static const int slide_dx[8] = {1, 1, -1, -1, 1, -1, 0, 0};
                static const int slide_dy[8] = {1, -1, 1, -1, 0, 0, 1, -1};
                int start_dir = 0;
                int end_dir = 8;
                int dir_index;

                if (type == PIECE_BISHOP) {
                    end_dir = 4;
                } else if (type == PIECE_ROOK) {
                    start_dir = 4;
                }

                for (dir_index = start_dir; dir_index < end_dir; dir_index++) {
                    int nx = x + slide_dx[dir_index];
                    int ny = y + slide_dy[dir_index];
                    while (inside_board(nx, ny)) {
                        if (is_side_piece(state->board[ny][nx], side)) {
                            break;
                        }
                        add_legal_move(state, moves, &count, x, y, nx, ny,
                                       (state->board[ny][nx] != PIECE_EMPTY) ? MOVE_CAPTURE : 0u, 0u);
                        if (state->board[ny][nx] != PIECE_EMPTY) {
                            break;
                        }
                        nx += slide_dx[dir_index];
                        ny += slide_dy[dir_index];
                    }
                }
            } else if (type == PIECE_KING) {
                int dx;
                int dy;
                for (dy = -1; dy <= 1; dy++) {
                    for (dx = -1; dx <= 1; dx++) {
                        int nx;
                        int ny;
                        if (dx == 0 && dy == 0) {
                            continue;
                        }
                        nx = x + dx;
                        ny = y + dy;
                        if (!inside_board(nx, ny) || is_side_piece(state->board[ny][nx], side)) {
                            continue;
                        }
                        add_legal_move(state, moves, &count, x, y, nx, ny,
                                       (state->board[ny][nx] != PIECE_EMPTY) ? MOVE_CAPTURE : 0u, 0u);
                    }
                }

                if (side == SIDE_WHITE && y == 7 && x == 4 &&
                    !is_square_attacked(state, 4, 7, SIDE_BLACK)) {
                    if ((state->castling_rights & CASTLE_WHITE_K) != 0u &&
                        state->board[7][5] == PIECE_EMPTY && state->board[7][6] == PIECE_EMPTY &&
                        state->board[7][7] == make_piece(SIDE_WHITE, PIECE_ROOK) &&
                        !is_square_attacked(state, 5, 7, SIDE_BLACK) &&
                        !is_square_attacked(state, 6, 7, SIDE_BLACK)) {
                        add_legal_move(state, moves, &count, 4, 7, 6, 7, MOVE_CASTLE_K, 0u);
                    }
                    if ((state->castling_rights & CASTLE_WHITE_Q) != 0u &&
                        state->board[7][1] == PIECE_EMPTY && state->board[7][2] == PIECE_EMPTY &&
                        state->board[7][3] == PIECE_EMPTY &&
                        state->board[7][0] == make_piece(SIDE_WHITE, PIECE_ROOK) &&
                        !is_square_attacked(state, 3, 7, SIDE_BLACK) &&
                        !is_square_attacked(state, 2, 7, SIDE_BLACK)) {
                        add_legal_move(state, moves, &count, 4, 7, 2, 7, MOVE_CASTLE_Q, 0u);
                    }
                } else if (side == SIDE_BLACK && y == 0 && x == 4 &&
                           !is_square_attacked(state, 4, 0, SIDE_WHITE)) {
                    if ((state->castling_rights & CASTLE_BLACK_K) != 0u &&
                        state->board[0][5] == PIECE_EMPTY && state->board[0][6] == PIECE_EMPTY &&
                        state->board[0][7] == make_piece(SIDE_BLACK, PIECE_ROOK) &&
                        !is_square_attacked(state, 5, 0, SIDE_WHITE) &&
                        !is_square_attacked(state, 6, 0, SIDE_WHITE)) {
                        add_legal_move(state, moves, &count, 4, 0, 6, 0, MOVE_CASTLE_K, 0u);
                    }
                    if ((state->castling_rights & CASTLE_BLACK_Q) != 0u &&
                        state->board[0][1] == PIECE_EMPTY && state->board[0][2] == PIECE_EMPTY &&
                        state->board[0][3] == PIECE_EMPTY &&
                        state->board[0][0] == make_piece(SIDE_BLACK, PIECE_ROOK) &&
                        !is_square_attacked(state, 3, 0, SIDE_WHITE) &&
                        !is_square_attacked(state, 2, 0, SIDE_WHITE)) {
                        add_legal_move(state, moves, &count, 4, 0, 2, 0, MOVE_CASTLE_Q, 0u);
                    }
                }
            }
        }
    }

    sort_moves(moves, count);
    return count;
}

static int evaluate_piece_square(unsigned char piece, int x, int y)
{
    int px = x;
    int py = y;
    int center = 6 - (abs_i(px - 3) + abs_i(py - 3));

    if (piece_side(piece) == SIDE_BLACK) {
        py = 7 - py;
    }

    switch (piece_type(piece)) {
    case PIECE_PAWN:
        return (6 - py) * 7 - (abs_i(px - 3) * 2);
    case PIECE_KNIGHT:
        return center * 5;
    case PIECE_BISHOP:
        return center * 4;
    case PIECE_ROOK:
        return (6 - py) * 2;
    case PIECE_QUEEN:
        return center * 2;
    case PIECE_KING:
        if (py >= 6) {
            return 10 - abs_i(px - 4);
        }
        return -(center * 3);
    default:
        return 0;
    }
}

static int evaluate_position(const chess_state_t *state)
{
    int y;
    int score = 0;

    for (y = 0; y < BOARD_SIZE; y++) {
        int x;
        for (x = 0; x < BOARD_SIZE; x++) {
            unsigned char piece = state->board[y][x];
            int value;
            if (piece == PIECE_EMPTY) {
                continue;
            }
            value = piece_value(piece) + evaluate_piece_square(piece, x, y);
            if (piece_side(piece) == SIDE_WHITE) {
                score += value;
            } else {
                score -= value;
            }
        }
    }

    if ((state->castling_rights & (CASTLE_WHITE_K | CASTLE_WHITE_Q)) != 0u) {
        score += 18;
    }
    if ((state->castling_rights & (CASTLE_BLACK_K | CASTLE_BLACK_Q)) != 0u) {
        score -= 18;
    }

    return score;
}

static int search_position(const chess_state_t *state, unsigned int depth, int alpha, int beta)
{
    chess_move_t moves[MOVE_MAX];
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
    if (launcher_exit_pending) {
        return 0;
    }
#endif
    unsigned int count = generate_legal_moves_for(state, moves);

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
    launcher_abort_if_requested();
    if (launcher_exit_pending) {
        return 0;
    }
#endif

    if (count == 0u) {
        if (is_square_attacked(state, state->king_x[state->side_to_move], state->king_y[state->side_to_move],
                               state->side_to_move ^ 1)) {
            if (state->side_to_move == SIDE_WHITE) {
                return -SEARCH_MATE - (int)depth;
            }
            return SEARCH_MATE + (int)depth;
        }
        return 0;
    }

    if (depth == 0u) {
        return evaluate_position(state);
    }

    if (state->side_to_move == SIDE_WHITE) {
        int best = -SEARCH_INF;
        unsigned int i;
        for (i = 0u; i < count; i++) {
            chess_state_t next = *state;
            int score;
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
            launcher_abort_if_requested();
            if (launcher_exit_pending) {
                return 0;
            }
#endif
            apply_move(&next, &moves[i]);
            score = search_position(&next, depth - 1u, alpha, beta);
            if (score > best) {
                best = score;
            }
            if (score > alpha) {
                alpha = score;
            }
            if (alpha >= beta) {
                break;
            }
        }
        return best;
    }

    {
        int best = SEARCH_INF;
        unsigned int i;
        for (i = 0u; i < count; i++) {
            chess_state_t next = *state;
            int score;
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
            launcher_abort_if_requested();
            if (launcher_exit_pending) {
                return 0;
            }
#endif
            apply_move(&next, &moves[i]);
            score = search_position(&next, depth - 1u, alpha, beta);
            if (score < best) {
                best = score;
            }
            if (score < beta) {
                beta = score;
            }
            if (alpha >= beta) {
                break;
            }
        }
        return best;
    }
}

static chess_move_t choose_ai_move(void)
{
    chess_move_t best_move = legal_moves[0];
    int best_score = SEARCH_INF;
    unsigned int depth = (game_mode == MODE_AI_STRONG) ? AI_STRONG_DEPTH : AI_MED_DEPTH;
    unsigned int i;

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
    if (launcher_exit_pending) {
        return best_move;
    }
#endif

    if (game_mode == MODE_AI_STRONG && legal_move_count > 12u) {
        depth = 1u;
    }

    for (i = 0u; i < legal_move_count; i++) {
        chess_state_t next = game_state;
        int score;
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        launcher_abort_if_requested();
        if (launcher_exit_pending) {
            return best_move;
        }
#endif
        apply_move(&next, &legal_moves[i]);
        if (game_mode == MODE_AI_MED) {
            score = evaluate_position(&next);
            if (is_square_attacked(&next, next.king_x[SIDE_WHITE], next.king_y[SIDE_WHITE], SIDE_BLACK)) {
                score -= 28;
            }
            score += (int)(random_next() & 0x1Fu) - 16;
        } else {
            score = search_position(&next, depth - 1u, -SEARCH_INF, SEARCH_INF);
        }
        if (score < best_score || (score == best_score && (random_next() & 1u) == 0u)) {
            best_score = score;
            best_move = legal_moves[i];
        }
    }

    return best_move;
}

static void refresh_turn_state(void)
{
    legal_move_count = generate_legal_moves_for(&game_state, legal_moves);
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
    if (launcher_exit_pending) {
        return;
    }
#endif
    if (legal_move_count == 0u) {
        if (is_square_attacked(&game_state, game_state.king_x[game_state.side_to_move],
                               game_state.king_y[game_state.side_to_move], game_state.side_to_move ^ 1)) {
            result_code = (game_state.side_to_move == SIDE_WHITE) ? RESULT_BLACK_WIN : RESULT_WHITE_WIN;
            note_code = NOTE_CHECK;
        } else {
            result_code = RESULT_DRAW;
            note_code = NOTE_READY;
        }
    } else if (is_square_attacked(&game_state, game_state.king_x[game_state.side_to_move],
                                  game_state.king_y[game_state.side_to_move], game_state.side_to_move ^ 1)) {
        note_code = NOTE_CHECK;
    } else if (selected_x >= 0 && selected_y >= 0) {
        note_code = NOTE_MOVE;
    } else {
        note_code = NOTE_PICK;
    }
}

static void reset_position(void)
{
    int x;
    int y;

    for (y = 0; y < BOARD_SIZE; y++) {
        for (x = 0; x < BOARD_SIZE; x++) {
            game_state.board[y][x] = PIECE_EMPTY;
        }
    }

    game_state.board[0][0] = make_piece(SIDE_BLACK, PIECE_ROOK);
    game_state.board[0][1] = make_piece(SIDE_BLACK, PIECE_KNIGHT);
    game_state.board[0][2] = make_piece(SIDE_BLACK, PIECE_BISHOP);
    game_state.board[0][3] = make_piece(SIDE_BLACK, PIECE_QUEEN);
    game_state.board[0][4] = make_piece(SIDE_BLACK, PIECE_KING);
    game_state.board[0][5] = make_piece(SIDE_BLACK, PIECE_BISHOP);
    game_state.board[0][6] = make_piece(SIDE_BLACK, PIECE_KNIGHT);
    game_state.board[0][7] = make_piece(SIDE_BLACK, PIECE_ROOK);
    for (x = 0; x < BOARD_SIZE; x++) {
        game_state.board[1][x] = make_piece(SIDE_BLACK, PIECE_PAWN);
        game_state.board[6][x] = make_piece(SIDE_WHITE, PIECE_PAWN);
    }
    game_state.board[7][0] = make_piece(SIDE_WHITE, PIECE_ROOK);
    game_state.board[7][1] = make_piece(SIDE_WHITE, PIECE_KNIGHT);
    game_state.board[7][2] = make_piece(SIDE_WHITE, PIECE_BISHOP);
    game_state.board[7][3] = make_piece(SIDE_WHITE, PIECE_QUEEN);
    game_state.board[7][4] = make_piece(SIDE_WHITE, PIECE_KING);
    game_state.board[7][5] = make_piece(SIDE_WHITE, PIECE_BISHOP);
    game_state.board[7][6] = make_piece(SIDE_WHITE, PIECE_KNIGHT);
    game_state.board[7][7] = make_piece(SIDE_WHITE, PIECE_ROOK);

    game_state.side_to_move = SIDE_WHITE;
    game_state.castling_rights = CASTLE_WHITE_K | CASTLE_WHITE_Q | CASTLE_BLACK_K | CASTLE_BLACK_Q;
    game_state.ep_x = -1;
    game_state.ep_y = -1;
    game_state.king_x[SIDE_WHITE] = 4u;
    game_state.king_y[SIDE_WHITE] = 7u;
    game_state.king_x[SIDE_BLACK] = 4u;
    game_state.king_y[SIDE_BLACK] = 0u;
    game_state.fullmove = 1u;

    cursor_x = 4;
    cursor_y = 6;
    selected_x = -1;
    selected_y = -1;
    result_code = RESULT_NONE;
    note_code = NOTE_PICK;
    last_from_x = -1;
    last_from_y = -1;
    last_to_x = -1;
    last_to_y = -1;
    scene_valid = 0;
    need_redraw = 1;

    rng_state ^= (game_state.fullmove << 5);
    refresh_turn_state();
}

static void begin_game(int next_mode)
{
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
    launcher_exit_pending = 0;
#endif
    game_mode = next_mode;
    view_mode = VIEW_GAME;
    reset_position();
}

static int is_ai_turn(void)
{
    return view_mode == VIEW_GAME &&
           result_code == RESULT_NONE &&
           game_mode != MODE_TWO &&
           game_state.side_to_move == SIDE_BLACK;
}

static int selected_move_to(int to_x, int to_y, chess_move_t *out)
{
    unsigned int i;

    for (i = 0u; i < legal_move_count; i++) {
        if ((int)legal_moves[i].from_x == selected_x &&
            (int)legal_moves[i].from_y == selected_y &&
            (int)legal_moves[i].to_x == to_x &&
            (int)legal_moves[i].to_y == to_y) {
            *out = legal_moves[i];
            return 1;
        }
    }
    return 0;
}

static int selected_has_any_move(void)
{
    unsigned int i;
    for (i = 0u; i < legal_move_count; i++) {
        if ((int)legal_moves[i].from_x == selected_x &&
            (int)legal_moves[i].from_y == selected_y) {
            return 1;
        }
    }
    return 0;
}

static int square_is_hint(int x, int y)
{
    unsigned int i;

    if (selected_x < 0 || selected_y < 0) {
        return 0;
    }

    for (i = 0u; i < legal_move_count; i++) {
        if ((int)legal_moves[i].from_x == selected_x &&
            (int)legal_moves[i].from_y == selected_y &&
            (int)legal_moves[i].to_x == x &&
            (int)legal_moves[i].to_y == y) {
            return 1;
        }
    }
    return 0;
}

static void commit_move(const chess_move_t *move)
{
    int mover = game_state.side_to_move;

    last_from_x = move->from_x;
    last_from_y = move->from_y;
    last_to_x = move->to_x;
    last_to_y = move->to_y;
    apply_move(&game_state, move);
    selected_x = -1;
    selected_y = -1;
    note_code = ((move->flags & MOVE_PROMOTE) != 0u) ? NOTE_AUTOQ : NOTE_PICK;
    if (mover == SIDE_BLACK) {
        cursor_x = move->to_x;
        cursor_y = move->to_y;
    }
    refresh_turn_state();
    need_redraw = 1;
}

static void do_ai_move(void)
{
    chess_move_t move;

    if (!is_ai_turn()) {
        return;
    }

    note_code = NOTE_AI;
    need_redraw = 1;
    move = choose_ai_move();
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
    if (launcher_exit_pending) {
        return;
    }
#endif
    commit_move(&move);
}

static void draw_piece_token(unsigned int x, unsigned int y, unsigned char piece)
{
    unsigned char fill = (piece_side(piece) == SIDE_WHITE) ? COLOR_WHITE_PIECE : COLOR_BLACK_PIECE;
    unsigned char edge = (piece_side(piece) == SIDE_WHITE) ? COLOR_WHITE_EDGE : COLOR_BLACK_EDGE;
    unsigned char letter = (piece_side(piece) == SIDE_WHITE) ? COLOR_WHITE_LETTER : COLOR_BLACK_LETTER;
    char text[2];

    text[0] = piece_letter(piece);
    text[1] = '\0';

    draw_frame(x + 2u, y + 2u, 7u, 7u, edge, fill);
    fill_rect(x + 3u, y + 3u, 5u, 1u, (piece_side(piece) == SIDE_WHITE) ? COLOR_LABEL : COLOR_SHADOW);
    draw_text_centered(x + 2u, y + 3u, 7u, text, 1u, letter);
}

static void draw_board_square(int x, int y)
{
    unsigned int px = board_cell_x(x);
    unsigned int py = board_cell_y(y);
    unsigned char base = (((x + y) & 1) == 0) ? COLOR_LIGHT_SQUARE : COLOR_DARK_SQUARE;
    unsigned char border = base;
    unsigned char piece = game_state.board[y][x];

    fill_rect(px, py, CELL_SIZE, CELL_SIZE, base);

    if (x == last_from_x && y == last_from_y) {
        fill_rect(px + 1u, py + 1u, CELL_SIZE - 2u, 1u, COLOR_LAST_FROM);
        fill_rect(px + 1u, py + CELL_SIZE - 2u, CELL_SIZE - 2u, 1u, COLOR_LAST_FROM);
        fill_rect(px + 1u, py + 1u, 1u, CELL_SIZE - 2u, COLOR_LAST_FROM);
        fill_rect(px + CELL_SIZE - 2u, py + 1u, 1u, CELL_SIZE - 2u, COLOR_LAST_FROM);
    } else if (x == last_to_x && y == last_to_y) {
        fill_rect(px + 1u, py + 1u, CELL_SIZE - 2u, 1u, COLOR_LAST_TO);
        fill_rect(px + 1u, py + CELL_SIZE - 2u, CELL_SIZE - 2u, 1u, COLOR_LAST_TO);
        fill_rect(px + 1u, py + 1u, 1u, CELL_SIZE - 2u, COLOR_LAST_TO);
        fill_rect(px + CELL_SIZE - 2u, py + 1u, 1u, CELL_SIZE - 2u, COLOR_LAST_TO);
    }

    if (square_is_hint(x, y)) {
        fill_rect(px + 4u, py + 4u, 3u, 3u, COLOR_HINT);
    }

    if (piece != PIECE_EMPTY) {
        draw_piece_token(px, py, piece);
    }

    if (selected_x == x && selected_y == y) {
        border = COLOR_SELECT;
    }
    if (cursor_x == x && cursor_y == y) {
        border = COLOR_CURSOR;
    }
    if (selected_x == x && selected_y == y && cursor_x == x && cursor_y == y) {
        border = COLOR_STATUS_BAD;
    }

    fill_rect(px, py, CELL_SIZE, 1u, border);
    fill_rect(px, py + CELL_SIZE - 1u, CELL_SIZE, 1u, border);
    fill_rect(px, py, 1u, CELL_SIZE, border);
    fill_rect(px + CELL_SIZE - 1u, py, 1u, CELL_SIZE, border);
}

static void draw_board(void)
{
    int y;

    draw_frame(BOARD_PANEL_X, BOARD_PANEL_Y, BOARD_PANEL_W, BOARD_PANEL_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(BOARD_X - 2u, BOARD_Y - 2u, BOARD_PIXELS + 4u, BOARD_PIXELS + 4u, COLOR_CARD);
    for (y = 0; y < BOARD_SIZE; y++) {
        int x;
        for (x = 0; x < BOARD_SIZE; x++) {
            draw_board_square(x, y);
        }
    }
}

static void redraw_hint_group_for(int sel_x, int sel_y)
{
    unsigned int i;

    if (sel_x < 0 || sel_y < 0) {
        return;
    }

    draw_board_square(sel_x, sel_y);
    for (i = 0u; i < legal_move_count; i++) {
        if ((int)legal_moves[i].from_x == sel_x &&
            (int)legal_moves[i].from_y == sel_y) {
            draw_board_square((int)legal_moves[i].to_x, (int)legal_moves[i].to_y);
        }
    }
}

static void draw_cursor_note_area(void)
{
    char cursor_text[3];
    const char *note_text = note_name();

    square_text(cursor_x, cursor_y, cursor_text);
    draw_text(PANEL_BOX_X, PANEL_NOTE_Y - 6u, "CUR", 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, PANEL_NOTE_Y, 18u, PANEL_BOX_H, COLOR_FRAME, COLOR_CARD);
    draw_text_centered(PANEL_BOX_X, PANEL_NOTE_Y + 2u, 18u, cursor_text, 1u, COLOR_TEXT);
    draw_frame(PANEL_BOX_X + 21u, PANEL_NOTE_Y, 19u, PANEL_BOX_H, COLOR_FRAME, COLOR_CARD);
    draw_text_centered(PANEL_BOX_X + 21u, PANEL_NOTE_Y + 2u, 19u, note_text, 1u, COLOR_TEXT);
}

static void redraw_selection_cursor(int old_sel_x, int old_sel_y, int old_cursor_x, int old_cursor_y)
{
    if (!scene_valid) {
        need_redraw = 1;
        return;
    }

    redraw_hint_group_for(old_sel_x, old_sel_y);
    redraw_hint_group_for(selected_x, selected_y);
    draw_board_square(old_cursor_x, old_cursor_y);
    draw_board_square(cursor_x, cursor_y);
    draw_cursor_note_area();
}

static void draw_side_box(unsigned int y, const char *label, const char *value, unsigned char accent)
{
    draw_text(PANEL_BOX_X, y - 6u, label, 1u, COLOR_LABEL);
    draw_frame(PANEL_BOX_X, y, PANEL_BOX_W, PANEL_BOX_H, accent, COLOR_CARD);
    draw_text_centered(PANEL_BOX_X, y + 2u, PANEL_BOX_W, value, 1u, COLOR_TEXT);
}

static void render_game_scene(void)
{
    char last_text[6];
    const char *turn_text = turn_name();
    const char *state_text = state_name();
    unsigned char state_color = COLOR_ACCENT;

    if (!scene_valid) {
        video_reset();
    }

    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    fill_rect(TITLE_X + 2u, TITLE_Y + TITLE_H - 4u, TITLE_W - 4u, 1u, COLOR_LAST_TO);
    draw_text_centered(TITLE_X, TITLE_Y + 3u, TITLE_W, "CHESS", 2u, COLOR_TEXT);

    draw_board();

    draw_frame(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, COLOR_FRAME, COLOR_PANEL);
    draw_side_box(PANEL_MODE_Y, "MODE", mode_name(), COLOR_ACCENT);
    draw_side_box(PANEL_TURN_Y, "TURN", turn_text, (game_state.side_to_move == SIDE_WHITE) ? COLOR_LAST_TO : COLOR_STATUS_BAD);

    if (result_code == RESULT_DRAW) {
        state_color = COLOR_LABEL;
    } else if (result_code != RESULT_NONE || note_code == NOTE_CHECK) {
        state_color = COLOR_STATUS_BAD;
    } else if (game_mode != MODE_TWO && game_state.side_to_move == SIDE_BLACK) {
        state_color = COLOR_STATUS_WARN;
    } else {
        state_color = COLOR_STATUS_GOOD;
    }
    draw_side_box(PANEL_STATE_Y, "STATE", state_text, state_color);

    last_move_text(last_text);
    draw_side_box(PANEL_LAST_Y, "LAST", last_text, COLOR_FRAME);

    draw_cursor_note_area();

    draw_frame(FOOTER_X, FOOTER_Y, FOOTER_W, FOOTER_H, COLOR_FRAME, COLOR_PANEL);
    if (result_code == RESULT_NONE) {
        draw_text_centered(FOOTER_X, FOOTER_Y + 1u, FOOTER_W, "WASD MOVE  SPACE OK  R RESET  M MENU", 1u, COLOR_TEXT);
    } else {
        draw_text_centered(FOOTER_X, FOOTER_Y + 1u, FOOTER_W, "SPACE RESET  M MENU", 1u, COLOR_TEXT);
    }

    if (result_code != RESULT_NONE) {
        const char *line1 = "DRAW";
        const char *line2 = "SPACE RESET";

        if (result_code == RESULT_WHITE_WIN) {
            line1 = (game_mode == MODE_TWO) ? "WHITE WINS" : "YOU WIN";
            line2 = "CHECKMATE";
        } else if (result_code == RESULT_BLACK_WIN) {
            line1 = (game_mode == MODE_TWO) ? "BLACK WINS" : "AI WINS";
            line2 = "CHECKMATE";
        } else {
            line1 = "DRAW";
            line2 = "STALEMATE";
        }

        draw_frame(OVERLAY_X, OVERLAY_Y, OVERLAY_W, OVERLAY_H, COLOR_STATUS_BAD, COLOR_OVERLAY);
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 6u, OVERLAY_W, line1, 2u, COLOR_TEXT);
        draw_text_centered(OVERLAY_X, OVERLAY_Y + 17u, OVERLAY_W, line2, 1u, COLOR_TEXT);
    }

    scene_valid = 1;
    need_redraw = 0;
}

static void draw_menu_option(unsigned int y, const char *title, const char *detail, int selected)
{
    unsigned char fill = selected ? COLOR_MENU_SEL : COLOR_MENU_FILL;
    unsigned char frame = selected ? COLOR_ACCENT : COLOR_FRAME;
    unsigned char title_color = selected ? COLOR_CARD : COLOR_TEXT;
    unsigned char detail_color = selected ? COLOR_CARD : COLOR_LABEL;

    draw_frame(MENU_BOX_X, y, MENU_BOX_W, MENU_BOX_H, frame, fill);
    fill_rect(MENU_BOX_X + 2u, y + 2u, 4u, MENU_BOX_H - 4u, COLOR_ACCENT);
    draw_text(MENU_BOX_X + 10u, y + 3u, title, 1u, title_color);
    draw_text(MENU_BOX_X + 58u, y + 3u, detail, 1u, detail_color);
}

static void render_menu_scene(void)
{
    if (!scene_valid) {
        video_reset();
    }

    draw_frame(TITLE_X, TITLE_Y, TITLE_W, TITLE_H, COLOR_FRAME, COLOR_PANEL);
    fill_rect(TITLE_X + 2u, TITLE_Y + 2u, TITLE_W - 4u, 2u, COLOR_ACCENT);
    fill_rect(TITLE_X + 2u, TITLE_Y + TITLE_H - 4u, TITLE_W - 4u, 1u, COLOR_LAST_TO);
    draw_text_centered(TITLE_X, TITLE_Y + 3u, TITLE_W, "CHESS MODE", 2u, COLOR_TEXT);

    draw_frame(MENU_PANEL_X, MENU_PANEL_Y, MENU_PANEL_W, MENU_PANEL_H, COLOR_FRAME, COLOR_PANEL);
    draw_text_centered(MENU_PANEL_X, MENU_PANEL_Y + 8u, MENU_PANEL_W, "WHITE STARTS  AI PLAYS BLACK", 1u, COLOR_LABEL);
    draw_menu_option(MENU_BOX1_Y, "1 TWO PLAYER", "PASS PLAY", menu_selection == 0);
    draw_menu_option(MENU_BOX2_Y, "2 AI MED", "DEPTH 1", menu_selection == 1);
    draw_menu_option(MENU_BOX3_Y, "3 AI STRONG", "DEPTH 3", menu_selection == 2);

    draw_frame(FOOTER_X, 106u, FOOTER_W, 12u, COLOR_FRAME, COLOR_PANEL);
    draw_text_centered(FOOTER_X, 109u, FOOTER_W, "W S PICK  1 2 3 GO  SPACE START", 1u, COLOR_TEXT);

    scene_valid = 1;
    need_redraw = 0;
}

static void render_scene(void)
{
    if (view_mode == VIEW_MENU) {
        render_menu_scene();
    } else {
        render_game_scene();
    }
}

static void handle_menu_key(int ch, int *running)
{
    ch = ui_to_lower(ch);

    if (ch == 'q') {
        *running = 0;
        return;
    }
    if (ch == 'w') {
        if (menu_selection > 0) {
            menu_selection--;
            need_redraw = 1;
        }
        return;
    }
    if (ch == 's') {
        if (menu_selection < 2) {
            menu_selection++;
            need_redraw = 1;
        }
        return;
    }
    if (ch == '1') {
        menu_selection = 0;
        begin_game(MODE_TWO);
        return;
    }
    if (ch == '2') {
        menu_selection = 1;
        begin_game(MODE_AI_MED);
        return;
    }
    if (ch == '3') {
        menu_selection = 2;
        begin_game(MODE_AI_STRONG);
        return;
    }
    if (ch == ' ' || ch == '\r') {
        if (ch == '\r') {
            swallow_lf = 1;
        }
        begin_game(menu_selection);
    }
}

static void move_cursor(int dx, int dy)
{
    int nx = cursor_x + dx;
    int ny = cursor_y + dy;
    int old_cursor_x = cursor_x;
    int old_cursor_y = cursor_y;

    if (!inside_board(nx, ny)) {
        return;
    }
    cursor_x = nx;
    cursor_y = ny;
    redraw_selection_cursor(selected_x, selected_y, old_cursor_x, old_cursor_y);
}

static void handle_pick_or_move(void)
{
    unsigned char piece = game_state.board[cursor_y][cursor_x];
    int side = game_state.side_to_move;
    int old_sel_x = selected_x;
    int old_sel_y = selected_y;
    int old_cursor_x = cursor_x;
    int old_cursor_y = cursor_y;

    if (result_code != RESULT_NONE) {
        begin_game(game_mode);
        return;
    }

    if (selected_x >= 0 && selected_y >= 0) {
        chess_move_t move;
        if (selected_x == cursor_x && selected_y == cursor_y) {
            selected_x = -1;
            selected_y = -1;
            note_code = NOTE_PICK;
            redraw_selection_cursor(old_sel_x, old_sel_y, old_cursor_x, old_cursor_y);
            return;
        }
        if (selected_move_to(cursor_x, cursor_y, &move)) {
            commit_move(&move);
            return;
        }
        if (is_side_piece(piece, side)) {
            selected_x = cursor_x;
            selected_y = cursor_y;
            if (!selected_has_any_move()) {
                selected_x = -1;
                selected_y = -1;
                note_code = NOTE_NO_MOVE;
            } else {
                note_code = NOTE_MOVE;
            }
            redraw_selection_cursor(old_sel_x, old_sel_y, old_cursor_x, old_cursor_y);
            return;
        }
        note_code = NOTE_NO_MOVE;
        draw_cursor_note_area();
        return;
    }

    if (!is_side_piece(piece, side)) {
        note_code = NOTE_BAD_PICK;
        draw_cursor_note_area();
        return;
    }

    selected_x = cursor_x;
    selected_y = cursor_y;
    if (!selected_has_any_move()) {
        selected_x = -1;
        selected_y = -1;
        note_code = NOTE_NO_MOVE;
    } else {
        note_code = NOTE_MOVE;
    }
    redraw_selection_cursor(old_sel_x, old_sel_y, old_cursor_x, old_cursor_y);
}

static void handle_game_key(int ch, int *running)
{
    ch = ui_to_lower(ch);

    if (ch == 'q') {
        *running = 0;
        return;
    }
    if (ch == 'm') {
        view_mode = VIEW_MENU;
        menu_selection = game_mode;
        selected_x = -1;
        selected_y = -1;
        note_code = NOTE_READY;
        swallow_lf = 0;
        need_redraw = 1;
        scene_valid = 0;
        return;
    }
    if (ch == 'r') {
        begin_game(game_mode);
        return;
    }
    if (ch == 'w') {
        move_cursor(0, -1);
        return;
    }
    if (ch == 's') {
        move_cursor(0, 1);
        return;
    }
    if (ch == 'a') {
        move_cursor(-1, 0);
        return;
    }
    if (ch == 'd') {
        move_cursor(1, 0);
        return;
    }
    if (ch == ' ' || ch == '\r') {
        if (ch == '\r') {
            swallow_lf = 1;
        }
        if (!is_ai_turn()) {
            handle_pick_or_move();
        }
    }
}

int main(void)
{
    int running = 1;

    ui_clear_screen();
    ui_puts("Chess VGA\n");
    ui_puts("Menu: w/s or 1/2/3 choose mode, space start, BTNC launcher menu.\n");
    ui_puts("Game: w/a/s/d move, space pick or move, r reset, m mode menu, BTNC launcher menu.\n");
    ui_drain_input();

    video_reset();
    view_mode = VIEW_MENU;
    menu_selection = 0;
    need_redraw = 1;
    scene_valid = 0;
#if defined(LAUNCHER_SOFT_MENU_BUTTON)
    launcher_exit_pending = 0;
#endif

    while (running) {
        int ch;

#if defined(LAUNCHER_SOFT_MENU_BUTTON)
        if (launcher_exit_pending || ui_launcher_menu_requested()) {
            launcher_button_return();
        }
#endif

        if (need_redraw || !scene_valid) {
            render_scene();
        }

        if (is_ai_turn()) {
            do_ai_move();
            ui_short_pause(POLL_SPIN);
            continue;
        }

        ch = ui_read_byte_nonblocking();
        if (ch >= 0) {
            if (swallow_lf && ch == '\n') {
                swallow_lf = 0;
            } else {
                swallow_lf = 0;
                if (view_mode == VIEW_MENU) {
                    handle_menu_key(ch, &running);
                } else {
                    handle_game_key(ch, &running);
                }
            }
        }

        ui_short_pause(POLL_SPIN);
    }

    video_reset();
    ui_puts("\nLeaving Chess.\n");
    return 0;
}
