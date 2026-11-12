"""Isolated synthetic proof only: map marker-tagged elements to Word paragraphs.
Not a production HTML parser or a security boundary.
"""
import copy
import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile
from lxml import etree as ET
from zipfile import ZipFile

ROOT=Path('/tmp/moriq-wk-map-probe')
TEMPLATE=Path('/tmp/moriq-wk-background-probe/paragraph-before.docx')
NS={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
    'wp':'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing',
    'a':'http://schemas.openxmlformats.org/drawingml/2006/main',
    'r':'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
    'rel':'http://schemas.openxmlformats.org/package/2006/relationships',
    'ct':'http://schemas.openxmlformats.org/package/2006/content-types'}
for name,uri in NS.items(): ET.register_namespace(name,uri)

def run(source:Path, manifest:Path, output:Path):
    records=json.loads(manifest.read_text())
    if not records or len({r['marker'] for r in records}) != len(records): raise ValueError('duplicate or missing marker')
    images=[]
    for i,r in enumerate(records):
        image=ROOT/f'element-{i}.png'
        if not image.is_file(): raise ValueError('missing background resource')
        if not (0 < r['width'] <= 1000 and 0 < r['height'] <= 1000 and 0 < r['lineHeight'] <= r['height'] and 0 <= r['marginBottom'] <= 1000): raise ValueError('unsupported geometry')
        images.append(image.read_bytes())
    with ZipFile(TEMPLATE) as template, ZipFile(source) as original:
        template_xml=ET.fromstring(template.read('word/document.xml'))
        sample=template_xml.find('.//w:r[w:drawing]',NS)
        if sample is None: raise ValueError('background template missing')
        doc=ET.fromstring(original.read('word/document.xml'))
        relationships=ET.fromstring(original.read('word/_rels/document.xml.rels'))
        types=ET.fromstring(original.read('[Content_Types].xml'))
        paragraphs=doc.findall('.//w:p',NS)
        mapping=[]
        for r in records:
            found=[]
            for p in paragraphs:
                text=''.join(t.text or '' for t in p.findall('.//w:t',NS))
                if r['marker'] in text: found.append((p,text))
            if len(found)!=1 or found[0][1].count(r['marker'])!=1: raise ValueError('marker missing or ambiguous')
            mapping.append(found[0])
        if len({id(p) for p,_ in mapping}) != len(mapping): raise ValueError('multiple elements mapped to one paragraph')
        taken={r.get('Id') for r in relationships}
        for i,((paragraph,text),record) in enumerate(zip(mapping,records)):
            # GenOffice maps CSS spacing to Word twips. For this strictly
            # single-line fixture, include the unused box height in spacing so
            # the following paragraph starts at the original CSS position.
            ppr=paragraph.find('w:pPr',NS)
            if ppr is None: ppr=ET.Element('{%s}pPr'%NS['w']);paragraph.insert(0,ppr)
            spacing=ppr.find('w:spacing',NS)
            if spacing is None: spacing=ET.SubElement(ppr,'{%s}spacing'%NS['w'])
            spacing.set('{%s}before'%NS['w'],'0')
            spacing.set('{%s}after'%NS['w'],str(round((record['height']+record['marginBottom']-record['lineHeight'])*15)))
            spacing.set('{%s}line'%NS['w'],str(round(record['lineHeight']*15)))
            spacing.set('{%s}lineRule'%NS['w'],'exact')
            marker=record['marker']; start=text.index(marker);end=start+len(marker); cursor=0
            for t in paragraph.findall('.//w:t',NS):
                value=t.text or ''; left=max(0,start-cursor); right=min(len(value),end-cursor)
                if left < right: t.text=value[:left]+value[right:]
                cursor += len(value)
            rid='rIdMoriqMapping'+str(i)
            if rid in taken: raise ValueError('relationship collision')
            taken.add(rid)
            ET.SubElement(relationships,'{%s}Relationship'%NS['rel'],{'Id':rid,'Type':'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image','Target':f'media/moriq-mapping-{i}.png'})
            run=copy.deepcopy(sample); anchor=run.find('.//wp:anchor',NS)
            if anchor is None: raise ValueError('missing anchor')
            anchor.find('wp:positionH',NS).set('relativeFrom','column')
            anchor.find('wp:positionV',NS).set('relativeFrom','paragraph')
            extent=anchor.find('wp:extent',NS);extent.set('cx',str(round(record['width']*9525)));extent.set('cy',str(round(record['height']*9525)))
            graphic=anchor.find('.//a:xfrm/a:ext',NS);graphic.set('cx',extent.get('cx'));graphic.set('cy',extent.get('cy'))
            anchor.find('.//a:blip',NS).set('{%s}embed'%NS['r'],rid)
            anchor.find('wp:docPr',NS).set('id',str(987600+i))
            paragraph.append(run)
        if not any(x.get('Extension','').lower()=='png' for x in types): ET.SubElement(types,'{%s}Default'%NS['ct'],{'Extension':'png','ContentType':'image/png'})
        remaining=''.join(t.text or '' for t in doc.findall('.//w:t',NS))
        if any(r['marker'] in remaining for r in records): raise ValueError('marker remains')
        updates={'word/document.xml':ET.tostring(doc,encoding='utf-8',xml_declaration=True),'word/_rels/document.xml.rels':ET.tostring(relationships,encoding='utf-8',xml_declaration=True),'[Content_Types].xml':ET.tostring(types,encoding='utf-8',xml_declaration=True)}
        with NamedTemporaryFile(dir=output.parent,suffix='.docx',delete=False) as temp: temp_path=temp.name
        try:
            with ZipFile(temp_path,'w') as result:
                for item in original.infolist(): result.writestr(item,updates.get(item.filename,original.read(item.filename)))
                for i,data in enumerate(images): result.writestr(f'word/media/moriq-mapping-{i}.png',data)
            os.replace(temp_path,output)
        finally:
            if os.path.exists(temp_path): os.unlink(temp_path)
if __name__=='__main__':
    run(ROOT/'marked.docx',ROOT/'manifest.json',ROOT/'mapped.docx')
    print('PASS distinct markers mapped to separate Word paragraphs; no marker remains')
