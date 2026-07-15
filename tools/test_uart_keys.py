import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from uart_keys import windows_key_to_uart


class UartKeyTests(unittest.TestCase):
    def test_printable_key(self):
        self.assertEqual(windows_key_to_uart("k"), b"k")

    def test_backspace_is_forwarded(self):
        self.assertEqual(windows_key_to_uart("\x08"), b"\x08")

    def test_extended_cursor_and_delete_keys(self):
        self.assertEqual(windows_key_to_uart("\xe0", "K"), b"\x1b[D")
        self.assertEqual(windows_key_to_uart("\xe0", "M"), b"\x1b[C")
        self.assertEqual(windows_key_to_uart("\xe0", "S"), b"\x1b[3~")

    def test_unknown_extended_key_is_consumed(self):
        self.assertEqual(windows_key_to_uart("\xe0", "X"), b"")


if __name__ == "__main__":
    unittest.main()
