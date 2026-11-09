import warnings; warnings.simplefilter('ignore')
# python3 -I compare_shots.py PREFIX FIG [CTLPREFIX]: native vs B' screenshots (and native vs a second native screenshot: the noise floor)
import sys
from PIL import Image, ImageChops, ImageStat
pre, fig = sys.argv[1], sys.argv[2]
ctl = sys.argv[3] if len(sys.argv) > 3 else None
def load(p): return Image.open(p).convert('RGB')
def stats(a, b):
    d = ImageChops.difference(a, b).convert('L')
    px = list(d.getdata()); n = len(px)
    ink = [i for i, (p, q) in enumerate(zip(a.convert('L').getdata(), b.convert('L').getdata())) if p < 250 or q < 250]
    return dict(mean=round(sum(px) / n, 4), over32=sum(v > 32 for v in px), over8=sum(v > 8 for v in px), max=max(px), ink_pixels=len(ink),
                mean_on_ink=round(sum(px[i] for i in ink) / max(1, len(ink)), 3), total=n)
nat, b = load(f'{pre}_{fig}_native.png'), load(f'{pre}_{fig}_bsdf.png')
print('size', nat.size)
print('native vs B\'  ', stats(nat, b))
if ctl:
    print('native vs native (noise floor)', stats(nat, load(f'{ctl}_{fig}_native.png')))
d = ImageChops.invert(ImageChops.difference(nat, b).point(lambda v: min(255, v * 4)))
W = nat.size[0] * 3
out = Image.new('RGB', (W, nat.size[1]), 'white')
for i, im in enumerate([nat, b, d]): out.paste(im, (i * nat.size[0], 0))
out.save(f'{pre}_{fig}_sheet.png')
