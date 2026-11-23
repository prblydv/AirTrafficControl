"""Split the cleaned user atlas into asset-catalog sprites; preserve pixel colours.
Requires Pillow and NumPy for this offline preparation step only.
"""
from pathlib import Path
from collections import deque
import json
import numpy as np
from PIL import Image

root = Path(__file__).resolve().parent.parent
source = root / 'art/aircraft/cleaned-atlas.png'
image = Image.open(source).convert('RGBA')
rgba = np.asarray(image)
height, width = rgba.shape[:2]
# Nearly transparent fringe is ignored for measuring bounds. Crops retain the
# original alpha and antialiasing; no aircraft is painted or reconstructed here.
mask = rgba[:, :, 3] > 32
seen = np.zeros(mask.shape, dtype=bool)
components = []
for row, col in zip(*np.where(mask)):
    if seen[row, col]:
        continue
    queue = deque([(int(col), int(row))])
    seen[row, col] = True
    area = 0
    xmin = xmax = int(col)
    ymin = ymax = int(row)
    while queue:
        x, y = queue.popleft()
        area += 1
        xmin = min(xmin, x); xmax = max(xmax, x)
        ymin = min(ymin, y); ymax = max(ymax, y)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((nx, ny))
    if area >= 1000:
        components.append((area, (xmin, ymin, xmax + 1, ymax + 1)))

def ordering(component):
    _, (left, top, right, bottom) = component
    return (round(((top + bottom) / 2 - 140) / 280), (left + right) / 2)

components.sort(key=ordering)
assert len(components) == 20, f'Expected twenty aircraft; found {len(components)}'
manifest = []
for index, (area, bounds) in enumerate(components, 1):
    left, top, right, bottom = bounds
    box = (max(0, left - 3), max(0, top - 3), min(width, right + 3), min(height, bottom + 3))
    sprite = image.crop(box)
    name = f'Aircraft-{index:02}'
    directory = root / 'AirTrafficControl/Assets.xcassets' / f'{name}.imageset'
    directory.mkdir(exist_ok=True)
    filename = name.lower() + '.png'
    sprite.save(directory / filename)
    (directory / 'Contents.json').write_text(json.dumps({'images': [{'filename': filename, 'idiom': 'universal'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    manifest.append({'asset': name, 'sourceBounds': box, 'size': list(sprite.size), 'foregroundPixels': area})
    print(name, box, sprite.size)
(root / 'art/aircraft/import-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
