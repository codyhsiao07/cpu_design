"""Translate Windows console key events into standard UART terminal bytes."""

WINDOWS_EXTENDED_KEYS = {
    "H": b"\x1b[A",  # Up
    "P": b"\x1b[B",  # Down
    "M": b"\x1b[C",  # Right
    "K": b"\x1b[D",  # Left
    "G": b"\x1b[H",  # Home
    "O": b"\x1b[F",  # End
    "S": b"\x1b[3~",  # Delete
}


def windows_key_to_uart(first, second=None):
    """Return bytes for one getwch event (and its optional extended scan code)."""
    if first in ("\x00", "\xe0"):
        return WINDOWS_EXTENDED_KEYS.get(second, b"")
    if first == "\r":
        return b"\r\n"
    if first == "\x08":
        return b"\x08"
    return first.encode("ascii", errors="ignore")
