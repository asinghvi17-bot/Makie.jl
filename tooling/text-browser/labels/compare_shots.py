import sys
from PIL import Image, ImageChops, ImageStat
def load(p): return Image.open(p).convert('RGB')
def stats(a, b, box=None):
    A, B = (a.crop(box), b.crop(box)) if box else (a, b)
    d = ImageChops.difference(A, B).convert('L')
    s = ImageStat.Stat(d)
    nz = sum(1 for v in d.getdata() if v > 32)
    return round(s.mean[0], 3), nz, d
pre = sys.argv[1]; names = sys.argv[2:]
nat = load(f'{pre}_native_none.png')
print('size', nat.size)
sheets = [nat]
for n in names:
    im = load(f'{pre}_{n}.png')
    m, nz, d = stats(nat, im)
    print(f'{n}: mean |diff| {m}, pixels with diff>32: {nz} of {nat.size[0]*nat.size[1]}')
    sheets.append(im)
    d2 = ImageChops.difference(nat, im).point(lambda v: min(255, v * 3))
    sheets.append(ImageChops.invert(d2))
W = sum(s.size[0] for s in sheets); H = nat.size[1]
out = Image.new('RGB', (W, H), 'white'); x = 0
for s in sheets: out.paste(s, (x, 0)); x += s.size[0]
out.save(f'{pre}_sheet.png'); print('sheet', out.size)
