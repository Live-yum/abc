import tempfile
import unittest
from pathlib import Path

from PIL import Image

from computer_shell_visual import compare


class PixelComparisonTest(unittest.TestCase):
    def test_encoded_bytes_may_differ_when_decoded_pixels_match(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = (Path(directory) / name for name in ('a.png', 'b.png'))
            image = Image.new('RGBA', (8, 8), (20, 30, 40, 255))
            image.save(a, compress_level=0)
            image.save(b, compress_level=9)
            result = compare(a, b, (8, 8))
            self.assertNotEqual(result['A']['pngSha256'], result['B']['pngSha256'])
            self.assertTrue(result['exactPixelMatch'])

    def test_one_rgb_channel_change_is_not_hidden_by_unchanged_alpha(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = (Path(directory) / name for name in ('a.png', 'b.png'))
            image = Image.new('RGBA', (8, 8), (20, 30, 40, 255))
            image.save(a)
            image.putpixel((3, 5), (28, 30, 40, 255))
            image.save(b)
            result = compare(a, b, (8, 8))
            self.assertFalse(result['exactPixelMatch'])
            self.assertEqual(result['differentPixels'], 1)
            self.assertEqual(result['maximumChannelDifference'], 8)

    def test_incorrect_viewport_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = (Path(directory) / name for name in ('a.png', 'b.png'))
            Image.new('RGBA', (8, 8)).save(a)
            Image.new('RGBA', (8, 7)).save(b)
            with self.assertRaises(ValueError):
                compare(a, b, (8, 8))


if __name__ == '__main__':
    unittest.main()
