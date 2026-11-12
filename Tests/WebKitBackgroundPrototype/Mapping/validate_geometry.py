"""Compare red background boxes in the rendered PDF to DOM fixture geometry."""
import json
from pathlib import Path
from PIL import Image
from pypdf import PdfReader
root=Path('/tmp/moriq-wk-map-probe')
manifest=json.loads((root/'manifest.json').read_text())
image=Image.open(root/'mapped-render.png').convert('RGB')
pdf=PdfReader(root/'mapped.pdf')
scale=image.height/float(pdf.pages[0].mediabox.height)*0.75
rows=[]
for y in range(image.height):
    count=sum(1 for x in range(image.width) if (lambda c: c[0]>200 and c[1]<80 and c[2]<80)(image.getpixel((x,y))))
    if count>20: rows.append(y)
groups=[]
for y in rows:
    if not groups or y>groups[-1][-1]+1: groups.append([y])
    else: groups[-1].append(y)
assert len(groups)==2, groups
source_delta=manifest[1]['y']-manifest[0]['y']
output_delta=(groups[1][0]-groups[0][0])/scale
assert abs(source_delta-output_delta)<2,(source_delta,output_delta,scale)
for group,element in zip(groups,manifest):
    output_height=len(group)/scale
    assert abs(output_height-element['height'])<2,(output_height,element['height'])
print('PASS source/Word vertical offset and background heights within 2 CSS px:',source_delta,round(output_delta,2))
