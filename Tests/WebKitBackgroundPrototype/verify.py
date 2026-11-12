from pathlib import Path
from PIL import Image
root = Path('/tmp/moriq-wk-background-probe')
def color(name, x, y):
    return Image.open(root / ('snapshot-' + name + '.png')).convert('RGB').getpixel((x, y))
def red(c): return c[0] > 200 and c[2] < 80
def blue(c): return c[2] > 200 and c[0] < 80
def white(c): return min(c) > 240
for name in ('repeat', 'cover'):
    img = Image.open(root / ('snapshot-' + name + '.png'))
    assert img.size == (640, 480), (name, img.size)
    for point in ((0, 0), (639, 0), (0, 479), (639, 479)):
        assert not white(color(name, *point)), (name, point)
assert white(color('element', 100, 100))
assert red(color('element', 130, 110)) and blue(color('element', 170, 110))
assert white(color('pagination', 130, 130))
assert red(color('pagination-2', 130, 130)) and blue(color('pagination-2', 170, 130))
print('PASS snapshot edges, element geometry and second viewport')
