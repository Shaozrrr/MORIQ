"""Restricted local-resource preparation experiment; not a production boundary.
Uses lxml and tinycss2. Unsupported constructs fail closed; no network access.
"""
import base64
from io import BytesIO
import mimetypes
import os
from pathlib import Path
import stat
from urllib.parse import unquote, urlsplit
from lxml import html, etree
from PIL import Image
import tinycss2
from tinycss2.ast import StringToken

class Unsupported(ValueError): pass
ALLOWED_TAGS={'html','head','body','title','meta','p','div','span','img','a','br','strong','em','b','i','style','link'}
ALLOWED_ATTRS={'id','class','style','src','href','alt','title','rel','charset','type','width','height'}
ALLOWED_PROPS={'background','background-image','background-color','background-position','background-repeat','background-size','color','margin','margin-top','margin-bottom','margin-left','margin-right','padding','padding-top','padding-bottom','padding-left','padding-right','width','height','font','font-size','font-family','font-weight','line-height','overflow','display','text-align','border'}
MAX_RESOURCE=10_000_000

class Resources:
    def __init__(self,root):
        self.root=Path(root).resolve(strict=True)
        self.root_fd=os.open(self.root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        self.total=0; self.references=[]
    def close(self): os.close(self.root_fd)
    def resolve(self,url,base):
        split=urlsplit(url.strip())
        if split.scheme or split.netloc or split.query or split.fragment or split.path.startswith('/'): raise Unsupported('仅支持本地相对资源')
        path=unquote(split.path)
        if not path or '\x00' in path or '\\' in path: raise Unsupported('资源路径无效')
        parts=list(base)
        for item in path.split('/'):
            if item in ('','.'): continue
            if item=='..':
                if not parts: raise Unsupported('资源超出目录')
                parts.pop()
            else: parts.append(item)
        if not parts: raise Unsupported('资源路径无效')
        return parts
    def read(self,parts):
        fd=os.dup(self.root_fd)
        try:
            for item in parts[:-1]:
                next_fd=os.open(item,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=next_fd
            file_fd=os.open(parts[-1],os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
            try:
                st=os.fstat(file_fd)
                if not stat.S_ISREG(st.st_mode) or st.st_size<=0 or st.st_size>MAX_RESOURCE: raise Unsupported('资源类型或大小不支持')
                chunks=[]; remaining=MAX_RESOURCE+1
                while remaining:
                    chunk=os.read(file_fd,min(1024*1024,remaining))
                    if not chunk: break
                    chunks.append(chunk);remaining-=len(chunk)
                data=b''.join(chunks)
                if len(data)>MAX_RESOURCE: raise Unsupported('资源过大')
            finally: os.close(file_fd)
        except OSError as error: raise Unsupported('资源缺失或包含符号链接') from error
        finally: os.close(fd)
        self.total+=len(data)
        if self.total>50_000_000 or len(self.references)>=100: raise Unsupported('资源总量超限')
        self.references.append('/'.join(parts))
        return data
    def image(self,url,base):
        parts=self.resolve(url,base); data=self.read(parts)
        try:
            with Image.open(BytesIO(data)) as image:
                if image.format not in ('PNG','JPEG','GIF','WEBP') or image.width*image.height>40_000_000: raise Unsupported('图片类型或尺寸不支持')
                image.verify();kind=image.format.lower()
        except Unsupported: raise
        except Exception as error: raise Unsupported('图片损坏') from error
        mime={'jpg':'jpeg'}.get(kind,kind)
        return 'data:image/'+mime+';base64,'+base64.b64encode(data).decode('ascii')

def replace_urls(tokens,resources,base):
    for token in tokens:
        if token.type=='error': raise Unsupported('CSS 无法解析')
        if token.type=='url':
            value=resources.image(token.value,base);token.value=value;token.representation='url("'+value+'")'
        elif token.type=='function':
            if token.lower_name=='url':
                args=[a for a in token.arguments if a.type!='whitespace']
                if len(args)!=1 or args[0].type not in ('string','url','ident'): raise Unsupported('CSS 图片地址不支持')
                value=resources.image(args[0].value,base); token.arguments=[StringToken(token.source_line,token.source_column,value,'"'+value+'"')]
            elif token.lower_name in ('rgb','rgba','linear-gradient','radial-gradient','calc'):
                replace_urls(token.arguments,resources,base)
            else: raise Unsupported('CSS 函数不支持')
        elif token.type in ('{} block','[] block','() block'):
            replace_urls(token.content,resources,base)

def declarations(tokens,resources,base):
    parsed=tinycss2.parse_declaration_list(tokens,skip_comments=True,skip_whitespace=True)
    for item in parsed:
        if item.type!='declaration' or item.lower_name not in ALLOWED_PROPS: raise Unsupported('CSS 属性不支持')
        replace_urls(item.value,resources,base)
    return tinycss2.serialize(parsed)

def stylesheet(data,resources,base,stack=()):
    if len(stack)>5: raise Unsupported('样式嵌套超限')
    try: text=data.decode('utf-8-sig')
    except UnicodeDecodeError as error: raise Unsupported('样式编码不支持') from error
    rules=tinycss2.parse_stylesheet(text,skip_comments=True,skip_whitespace=True)
    output=[]; saw_rule=False
    for rule in rules:
        if rule.type=='qualified-rule':
            saw_rule=True
            selector=tinycss2.serialize(rule.prelude)
            # Disable selectors with escaped/ambiguous syntax in this first subset.
            if any(x in selector for x in ('\\',':','[',']')): raise Unsupported('CSS 选择器不支持')
            output.append(selector+'{'+declarations(rule.content,resources,base)+'}')
        elif rule.type=='at-rule' and rule.lower_at_keyword=='import' and rule.content is None:
            if saw_rule: raise Unsupported('CSS 导入顺序不支持')
            pre=[t for t in rule.prelude if t.type!='whitespace']
            if len(pre)!=1: raise Unsupported('CSS 导入形式不支持')
            t=pre[0]
            if t.type in ('string','url'): path=t.value
            elif t.type=='function' and t.lower_name=='url':
                a=[x for x in t.arguments if x.type!='whitespace']
                if len(a)!=1 or a[0].type!='string': raise Unsupported('CSS 导入形式不支持')
                path=a[0].value
            else: raise Unsupported('CSS 导入形式不支持')
            parts=resources.resolve(path,base); key='/'.join(parts)
            if key in stack: raise Unsupported('CSS 循环导入')
            output.append(stylesheet(resources.read(parts),resources,parts[:-1],stack+(key,)))
        else: raise Unsupported('CSS 规则不支持')
    return '\n'.join(output)

def prepare(source):
    source=Path(source)
    try: resources=Resources(source.parent)
    except OSError: return {'html':None,'notice':'网页资源或样式暂不支持；需回退普通转换，背景可能丢失','reason':'源目录不可读取'}
    try:
        raw=resources.read([source.name])
        try: raw.decode('utf-8-sig')
        except UnicodeDecodeError as error: raise Unsupported('网页编码不支持') from error
        parser=html.HTMLParser(no_network=True,remove_comments=False,encoding='utf-8')
        doc=html.document_fromstring(raw,parser=parser)
        for element in list(doc.iter()):
            if not isinstance(element.tag,str): continue
            tag=element.tag.lower()
            if tag not in ALLOWED_TAGS: raise Unsupported('网页元素不支持')
            if any(a.lower() not in ALLOWED_ATTRS for a in element.attrib): raise Unsupported('网页属性不支持')
            if tag=='meta' and (any(a.lower()!='charset' for a in element.attrib) or element.get('charset','utf-8').lower() not in ('utf-8','utf8')): raise Unsupported('网页元信息不支持')
            if tag=='style': element.text=stylesheet((element.text or '').encode(),resources,[])
            if tag=='link':
                if element.get('rel','').lower()!='stylesheet' or not element.get('href'): raise Unsupported('链接资源不支持')
                parts=resources.resolve(element.get('href'),[])
                css=stylesheet(resources.read(parts),resources,parts[:-1],('/'.join(parts),))
                replacement=html.Element('style');replacement.text=css;element.getparent().replace(element,replacement)
            if element.get('style') is not None: element.set('style',declarations(element.get('style'),resources,[]))
            if tag=='img':
                if not element.get('src'): raise Unsupported('图片来源缺失')
                element.set('src',resources.image(element.get('src'),[]))
        return {'html':etree.tostring(doc,method='html',encoding='unicode',doctype='<!doctype html>'),'notice':None,'resources':resources.references}
    except (Unsupported,ValueError,etree.ParserError) as error:
        return {'html':None,'notice':'网页资源或样式暂不支持；需回退普通转换，背景可能丢失','reason':str(error)}
    finally: resources.close()
