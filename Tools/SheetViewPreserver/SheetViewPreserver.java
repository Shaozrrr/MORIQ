import java.io.*;
import java.nio.file.*;
import java.awt.Font;
import java.awt.font.FontRenderContext;
import java.awt.geom.AffineTransform;
import java.util.*;
import java.util.zip.*;
import javax.xml.XMLConstants;
import javax.xml.parsers.*;
import javax.xml.transform.*;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import org.w3c.dom.*;

/** Preserve frozen panes in the native view metadata of XLSX and ODS files. */
public final class SheetViewPreserver {
    static final String XL="http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    static final String REL="http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    static final String PKG="http://schemas.openxmlformats.org/package/2006/relationships";
    static final String CFG="urn:oasis:names:tc:opendocument:xmlns:config:1.0";
    static final String STYLE="urn:oasis:names:tc:opendocument:xmlns:style:1.0";
    static final String TABLE="urn:oasis:names:tc:opendocument:xmlns:table:1.0";
    static final String FO="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0";
    static final int MAX_XML=32*1024*1024;
    record Freeze(int x,int y) {}
    record Sheet(String name,String path) {}
    record DefaultFont(String name,double size,double digit) {}
    static Document xml(byte[] data) throws Exception {
        if(data.length>MAX_XML) throw new IOException("XML too large");
        DocumentBuilderFactory f=DocumentBuilderFactory.newInstance(); f.setNamespaceAware(true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl",true);
        f.setFeature("http://xml.org/sax/features/external-general-entities",false);
        f.setFeature("http://xml.org/sax/features/external-parameter-entities",false);
        f.setXIncludeAware(false); f.setExpandEntityReferences(false);
        return f.newDocumentBuilder().parse(new ByteArrayInputStream(data));
    }
    static byte[] bytes(Document d) throws Exception {
        TransformerFactory f=TransformerFactory.newInstance(); f.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING,true);
        f.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD,""); f.setAttribute(XMLConstants.ACCESS_EXTERNAL_STYLESHEET,"");
        Transformer t=f.newTransformer(); t.setOutputProperty(OutputKeys.ENCODING,"UTF-8");
        ByteArrayOutputStream b=new ByteArrayOutputStream(); t.transform(new DOMSource(d),new StreamResult(b)); return b.toByteArray();
    }
    static byte[] read(ZipFile z,String path) throws IOException {
        ZipEntry e=z.getEntry(path); if(e==null) throw new IOException("missing "+path);
        if(e.getSize()>MAX_XML) throw new IOException("XML too large");
        try(InputStream in=z.getInputStream(e)){byte[] b=in.readNBytes(MAX_XML+1); if(b.length>MAX_XML) throw new IOException("XML too large"); return b;}
    }
    static List<Element> children(Element p,String ns,String name) {
        List<Element> a=new ArrayList<>(); for(Node n=p.getFirstChild();n!=null;n=n.getNextSibling()) if(n instanceof Element e && ns.equals(e.getNamespaceURI()) && name.equals(e.getLocalName())) a.add(e); return a;
    }
    static Element first(Element e,String ns,String name){List<Element> a=children(e,ns,name);return a.isEmpty()?null:a.get(0);}
    static List<Sheet> sheets(ZipFile z) throws Exception {
        Document wb=xml(read(z,"xl/workbook.xml")), rel=xml(read(z,"xl/_rels/workbook.xml.rels"));
        Map<String,String> paths=new HashMap<>(); NodeList links=rel.getElementsByTagNameNS(PKG,"Relationship");
        for(int i=0;i<links.getLength();i++){Element e=(Element)links.item(i);if("External".equals(e.getAttribute("TargetMode")))continue;
            String target=e.getAttribute("Target"); Path p=target.startsWith("/")?Path.of(target.substring(1)):Path.of("xl").resolve(target); p=p.normalize();
            String path=p.toString().replace('\\','/'); if(path.startsWith("xl/")&&!path.contains("../"))paths.put(e.getAttribute("Id"),path);
        }
        List<Sheet> out=new ArrayList<>(); NodeList ss=wb.getElementsByTagNameNS(XL,"sheet");
        for(int i=0;i<ss.getLength();i++){Element e=(Element)ss.item(i);String path=paths.get(e.getAttributeNS(REL,"id"));if(path!=null)out.add(new Sheet(e.getAttribute("name"),path));}
        return out;
    }
    static int number(String s,int max) { try { double v=Double.parseDouble(s); return v>=0&&v<=max&&v==Math.floor(v)?(int)v:0; } catch(Exception e){return 0;} }
    static Map<String,Freeze> fromXlsx(ZipFile z) throws Exception {
        Map<String,Freeze> out=new LinkedHashMap<>(); for(Sheet s:sheets(z)) {Document d=xml(read(z,s.path())); NodeList ps=d.getElementsByTagNameNS(XL,"pane");
            if(ps.getLength()==0)continue; Element p=(Element)ps.item(0);if(!p.getAttribute("state").startsWith("frozen"))continue;
            int x=number(p.getAttribute("xSplit"),16383),y=number(p.getAttribute("ySplit"),1048575);if(x>0||y>0)out.put(s.name(),new Freeze(x,y));
        } return out;
    }
    static Map<String,Freeze> fromOds(ZipFile z) throws Exception {
        Map<String,Freeze> out=new LinkedHashMap<>(); if(z.getEntry("settings.xml")==null)return out; Document d=xml(read(z,"settings.xml")); NodeList maps=d.getElementsByTagNameNS(CFG,"config-item-map-named");
        for(int i=0;i<maps.getLength();i++){Element map=(Element)maps.item(i);if(!"Tables".equals(map.getAttributeNS(CFG,"name")))continue;
            for(Element entry:children(map,CFG,"config-item-map-entry")){Map<String,String> v=new HashMap<>();for(Element e:children(entry,CFG,"config-item"))v.put(e.getAttributeNS(CFG,"name"),e.getTextContent());
                int x="2".equals(v.get("HorizontalSplitMode"))?number(v.get("HorizontalSplitPosition"),16383):0;
                int y="2".equals(v.get("VerticalSplitMode"))?number(v.get("VerticalSplitPosition"),1048575):0;
                if(x>0||y>0)out.put(entry.getAttributeNS(CFG,"name"),new Freeze(x,y));
            } break;
        } return out;
    }
    static void item(Document d,Element p,String name,String type,String value){Element e=d.createElementNS(CFG,"config:config-item");e.setAttributeNS(CFG,"config:name",name);e.setAttributeNS(CFG,"config:type",type);e.setTextContent(value);p.appendChild(e);}
    static byte[] odsSettings(ZipFile z,Map<String,Freeze> frozen) throws Exception {
        Document d=xml(read(z,"settings.xml"));NodeList sets=d.getElementsByTagNameNS(CFG,"config-item-set");Element view=null;
        for(int i=0;i<sets.getLength();i++){Element e=(Element)sets.item(i);if("ooo:view-settings".equals(e.getAttributeNS(CFG,"name"))){view=e;break;}}
        if(view==null)throw new IOException("missing ODS view settings");
        Element views=null;for(Element e:children(view,CFG,"config-item-map-indexed"))if("Views".equals(e.getAttributeNS(CFG,"name")))views=e;
        if(views==null){views=d.createElementNS(CFG,"config:config-item-map-indexed");views.setAttributeNS(CFG,"config:name","Views");view.appendChild(views);}
        Element v=first(views,CFG,"config-item-map-entry"); if(v==null){v=d.createElementNS(CFG,"config:config-item-map-entry");views.appendChild(v);item(d,v,"ViewId","string","view1");}
        Element tables=null;for(Element e:children(v,CFG,"config-item-map-named"))if("Tables".equals(e.getAttributeNS(CFG,"name")))tables=e;
        if(tables==null){tables=d.createElementNS(CFG,"config:config-item-map-named");tables.setAttributeNS(CFG,"config:name","Tables");v.appendChild(tables);}
        for(var pair:frozen.entrySet()) {Element sheet=null;for(Element e:children(tables,CFG,"config-item-map-entry"))if(pair.getKey().equals(e.getAttributeNS(CFG,"name")))sheet=e;
            if(sheet==null){sheet=d.createElementNS(CFG,"config:config-item-map-entry");sheet.setAttributeNS(CFG,"config:name",pair.getKey());tables.appendChild(sheet);}
            Set<String> names=Set.of("HorizontalSplitMode","VerticalSplitMode","HorizontalSplitPosition","VerticalSplitPosition","PositionRight","PositionBottom","ActiveSplitRange");
            for(Element e:new ArrayList<>(children(sheet,CFG,"config-item")))if(names.contains(e.getAttributeNS(CFG,"name")))sheet.removeChild(e);
            Freeze f=pair.getValue();item(d,sheet,"HorizontalSplitMode","short",f.x()>0?"2":"0");item(d,sheet,"VerticalSplitMode","short",f.y()>0?"2":"0");
            item(d,sheet,"HorizontalSplitPosition","int",Integer.toString(f.x()));item(d,sheet,"VerticalSplitPosition","int",Integer.toString(f.y()));
            item(d,sheet,"PositionRight","int",Integer.toString(f.x()));item(d,sheet,"PositionBottom","int",Integer.toString(f.y()));item(d,sheet,"ActiveSplitRange","short",f.x()>0&&f.y()>0?"3":f.x()>0?"1":"2");
        } return bytes(d);
    }
    static String column(int n){String s="";for(n++;n>0;n=(n-1)/26)s=(char)('A'+(n-1)%26)+s;return s;}
    // XLSX column widths are in units of the Normal font's digit width;
    // ODS stores physical lengths.  Read the current ODS values instead of
    // relying on a fixed multiplier or a stale copy of the original workbook.
    static DefaultFont odsDefaultFont(ZipFile z) throws Exception {
        Document d=xml(read(z,"styles.xml")); NodeList styles=d.getElementsByTagNameNS(STYLE,"style");
        for(int i=0;i<styles.getLength();i++) {
            Element e=(Element)styles.item(i);
            if(!"Default".equals(e.getAttributeNS(STYLE,"name")) || !"table-cell".equals(e.getAttributeNS(STYLE,"family"))) continue;
            Element p=first(e,STYLE,"text-properties"); if(p==null)return null;
            String name=p.getAttributeNS(FO,"font-family").trim().replaceAll("^['\"]|['\"]$","");
            if(name.isEmpty())name=p.getAttributeNS(STYLE,"font-name").trim();
            String size=p.getAttributeNS(FO,"font-size");
            if(name.isEmpty() || !size.endsWith("pt"))return null;
            double points; try { points=Double.parseDouble(size.substring(0,size.length()-2)); } catch(Exception ex){return null;}
            if(!Double.isFinite(points)||points<4||points>200)return null;
            if("bold".equalsIgnoreCase(p.getAttributeNS(FO,"font-weight")) || "italic".equalsIgnoreCase(p.getAttributeNS(FO,"font-style")))return null;
            Font font=new Font(name,Font.PLAIN,1).deriveFont((float)points);
            if(!font.getFamily(Locale.ROOT).equalsIgnoreCase(name) && !font.getFontName(Locale.ROOT).equalsIgnoreCase(name))return null;
            FontRenderContext frc=new FontRenderContext(new AffineTransform(),true,true);double width=0;
            for(char c='0';c<='9';c++)width=Math.max(width,font.getStringBounds(Character.toString(c),frc).getWidth());
            return width>0 && Double.isFinite(width) ? new DefaultFont(name,points,width) : null;
        } return null;
    }
    static double odsLength(String text) {
        String s=text.trim().toLowerCase(Locale.ROOT);double scale;
        if(s.endsWith("cm")){scale=72/2.54;s=s.substring(0,s.length()-2);}
        else if(s.endsWith("mm")){scale=72/25.4;s=s.substring(0,s.length()-2);}
        else if(s.endsWith("in")){scale=72;s=s.substring(0,s.length()-2);}
        else if(s.endsWith("pt")){scale=1;s=s.substring(0,s.length()-2);}
        else return Double.NaN;
        try {double n=Double.parseDouble(s)*scale;return n>=0&&n<=5000&&Double.isFinite(n)?n:Double.NaN;} catch(Exception e){return Double.NaN;}
    }
    static Map<String,double[]> odsColumnLengths(ZipFile z) throws Exception {
        Document doc=xml(read(z,"content.xml"));Map<String,Double> styles=new HashMap<>();
        NodeList all=doc.getElementsByTagNameNS(STYLE,"style");
        for(int i=0;i<all.getLength();i++) {Element e=(Element)all.item(i);if(!"table-column".equals(e.getAttributeNS(STYLE,"family")))continue;
            Element p=first(e,STYLE,"table-column-properties");if(p==null)continue;double n=odsLength(p.getAttributeNS(STYLE,"column-width"));
            if(Double.isFinite(n))styles.put(e.getAttributeNS(STYLE,"name"),n);
        }
        Map<String,double[]> out=new HashMap<>();NodeList tables=doc.getElementsByTagNameNS(TABLE,"table");
        for(int i=0;i<tables.getLength();i++){Element t=(Element)tables.item(i);if(!(t.getParentNode() instanceof Element p) || !"spreadsheet".equals(p.getLocalName()))continue;
            double[] lengths=new double[16385];Arrays.fill(lengths,Double.NaN);int col=1;
            int direct=0;
            for(Node n=t.getFirstChild();n!=null;n=n.getNextSibling())if(n instanceof Element e&&TABLE.equals(e.getNamespaceURI())&&"table-column".equals(e.getLocalName())){
                direct++;
                int repeat=number(e.getAttributeNS(TABLE,"number-columns-repeated"),16384);if(repeat==0)repeat=1;
                double v=styles.getOrDefault(e.getAttributeNS(TABLE,"style-name"),Double.NaN);
                for(int j=0;j<repeat&&col<=16384;j++,col++)lengths[col]=v;
            }
            // Nested column groups or an incomplete range are not safely
            // comparable to XLSX defaults; leave the converter output alone.
            if(direct!=t.getElementsByTagNameNS(TABLE,"table-column").getLength() || !Double.isFinite(lengths[16384]))return Map.of();
            out.put(t.getAttributeNS(TABLE,"name"),lengths);
        } return out;
    }
    static byte[] preserveStyles(ZipFile z,DefaultFont desired) throws Exception {
        Document d=xml(read(z,"xl/styles.xml")); Element root=d.getDocumentElement(),fonts=first(root,XL,"fonts");
        if(fonts==null)return null;List<Element> entries=children(fonts,XL,"font");if(entries.isEmpty())return null;
        Element initial=entries.get(0);Element name=first(initial,XL,"name"),size=first(initial,XL,"sz");if(name==null||size==null)return null;
        int normal=0;Element styles=first(root,XL,"cellStyles");if(styles!=null)for(Element s:children(styles,XL,"cellStyle"))if("0".equals(s.getAttribute("builtinId"))||"Normal".equals(s.getAttribute("name"))){normal=number(s.getAttribute("xfId"),65535);break;}
        Element named=first(root,XL,"cellStyleXfs");if(named==null)return null;List<Element> namedList=children(named,XL,"xf");
        if(normal>=namedList.size() || !isZeroFont(namedList.get(normal)))return null;
        int previousIndex=entries.size();fonts.appendChild(initial.cloneNode(true));fonts.setAttribute("count",Integer.toString(previousIndex+1));
        name.setAttribute("val",desired.name());size.setAttribute("val",Double.toString(desired.size()));
        for(Element scheme:new ArrayList<>(children(initial,XL,"scheme")))initial.removeChild(scheme);
        Element xfs=first(root,XL,"cellXfs");List<Element> cellXfs=xfs==null?List.of():children(xfs,XL,"xf");
        for(int i=0;i<cellXfs.size();i++){Element xf=cellXfs.get(i);if(!isZeroFont(xf))continue;
            // The first cell XF is the fallback for empty, unstyled cells.
            // It must inherit the restored Normal font, not the old fallback.
            if(i==0 && number(xf.getAttribute("xfId"),65535)==normal)continue;
            String apply=xf.getAttribute("applyFont");boolean inherits="0".equals(apply)||"false".equalsIgnoreCase(apply);
            if(!inherits || number(xf.getAttribute("xfId"),65535)==normal){xf.setAttribute("fontId",Integer.toString(previousIndex));xf.setAttribute("applyFont","1");}
        }
        // Keep existing non-Normal named styles using their old font.
        for(int i=0;i<namedList.size();i++){Element xf=namedList.get(i);if(i!=normal&&isZeroFont(xf))xf.setAttribute("fontId",Integer.toString(previousIndex));}
        return bytes(d);
    }
    static boolean isZeroFont(Element xf){String id=xf.getAttribute("fontId");return id.isEmpty()||"0".equals(id);}
    static boolean usableColumns(ZipFile z,List<Sheet> sheets,Map<String,double[]> all,DefaultFont font) throws Exception {
        if(all.size()!=sheets.size())return false;
        for(Sheet s:sheets){double[] values=all.get(s.name());if(values==null||!validWidth(values[16384],font))return false;
            Document d=xml(read(z,s.path()));if(first(d.getDocumentElement(),XL,"sheetFormatPr")==null)return false;
            Element cols=first(d.getDocumentElement(),XL,"cols");
            if(!validWidth(implicitColumnLength(cols,values),font))return false;
            if(cols==null)continue;
            for(Element col:children(cols,XL,"col")){int min=number(col.getAttribute("min"),16384),max=number(col.getAttribute("max"),16384);if(min<1||max<min)return false;
                for(int i=min;i<=max;i++)if(!validWidth(values[i],font))return false;
            }
        }return true;
    }
    static boolean validWidth(double value,DefaultFont font){return Double.isFinite(value)&&value>=0&&value/font.digit()<=255;}
    static double implicitColumnLength(Element cols,double[] lengths) {
        boolean[] covered=new boolean[16385];
        if(cols!=null)for(Element col:children(cols,XL,"col")){int min=number(col.getAttribute("min"),16384),max=number(col.getAttribute("max"),16384);if(min<1||max<min)return Double.NaN;for(int i=min;i<=max;i++)covered[i]=true;}
        double value=Double.NaN;
        for(int i=1;i<=16384;i++)if(!covered[i]){if(!Double.isFinite(lengths[i]))return Double.NaN;if(!Double.isFinite(value))value=lengths[i];else if(Math.abs(value-lengths[i])>0.03)return Double.NaN;}
        return Double.isFinite(value)?value:lengths[16384];
    }
    static byte[] applyColumnLengths(byte[] input,double[] lengths,DefaultFont font) throws Exception {
        Document d=xml(input);Element format=first(d.getDocumentElement(),XL,"sheetFormatPr"),cols=first(d.getDocumentElement(),XL,"cols");
        double defaultLength=implicitColumnLength(cols,lengths);
        if(format!=null&&validWidth(defaultLength,font))format.setAttribute("defaultColWidth",Double.toString(Math.round(defaultLength/font.digit()*256.0)/256.0));
        if(cols==null)return bytes(d);
        for(Element col:new ArrayList<>(children(cols,XL,"col"))) {
            int min=number(col.getAttribute("min"),16384),max=number(col.getAttribute("max"),16384);if(min<1||max<min)continue;
            // Preserve all output attributes, splitting a range only where its
            // actual ODS widths differ; absent ODS measurements remain untouched.
            int start=min;String last=null;List<Element> parts=new ArrayList<>();
            for(int i=min;i<=max+1;i++) {
                String width=null;
                if(i<=max && Double.isFinite(lengths[i])) {double n=lengths[i]/font.digit();if(n>=0&&n<=255)width=Double.toString(Math.round(n*256.0)/256.0);}
                if(i==min){last=width;continue;}
                if(i==max+1 || !Objects.equals(last,width)) {Element part=(Element)col.cloneNode(true);part.setAttribute("min",Integer.toString(start));part.setAttribute("max",Integer.toString(i-1));if(last!=null){part.setAttribute("width",last);part.setAttribute("customWidth","1");}parts.add(part);start=i;last=width;}
            }
            for(Element part:parts)cols.insertBefore(part,col);cols.removeChild(col);
        } return bytes(d);
    }
    static byte[] xlsxSheet(ZipFile z,String path,Freeze f) throws Exception {
        Document d=xml(read(z,path));NodeList all=d.getElementsByTagNameNS(XL,"sheetView");if(all.getLength()==0)throw new IOException("missing sheetView");
        Element view=(Element)all.item(0);for(Element old:new ArrayList<>(children(view,XL,"pane")))view.removeChild(old);
        for(Element old:new ArrayList<>(children(view,XL,"selection")))view.removeChild(old);
        String pane=f.x()>0&&f.y()>0?"bottomRight":f.x()>0?"topRight":"bottomLeft";
        Element e=d.createElementNS(XL,"pane");if(f.x()>0)e.setAttribute("xSplit",Integer.toString(f.x()));if(f.y()>0)e.setAttribute("ySplit",Integer.toString(f.y()));
        e.setAttribute("topLeftCell",column(f.x())+(f.y()+1));e.setAttribute("activePane",pane);e.setAttribute("state","frozen");view.insertBefore(e,view.getFirstChild());
        Element selection=d.createElementNS(XL,"selection");selection.setAttribute("pane",pane);selection.setAttribute("activeCell",column(f.x())+(f.y()+1));selection.setAttribute("sqref",column(f.x())+(f.y()+1));view.insertBefore(selection,e.getNextSibling());return bytes(d);
    }
    static void rewrite(Path file,Map<String,byte[]> changes) throws Exception {
        if(changes.isEmpty())return;Path tmp=Files.createTempFile(file.getParent(),"sheet-view-",".zip");boolean done=false;
        try {
        try(ZipFile in=new ZipFile(file.toFile());ZipOutputStream out=new ZipOutputStream(Files.newOutputStream(tmp))){Enumeration<? extends ZipEntry> it=in.entries();Set<String> names=new HashSet<>();
            while(it.hasMoreElements()){ZipEntry old=it.nextElement();if(!names.add(old.getName()))throw new IOException("duplicate ZIP entry");byte[] changed=changes.get(old.getName());ZipEntry next=new ZipEntry(old.getName());next.setTime(old.getTime());
                if(old.getMethod()==ZipEntry.STORED){next.setMethod(ZipEntry.STORED);if(changed==null){next.setSize(old.getSize());next.setCompressedSize(old.getSize());next.setCrc(old.getCrc());}else{CRC32 crc=new CRC32();crc.update(changed);next.setSize(changed.length);next.setCompressedSize(changed.length);next.setCrc(crc.getValue());}}
                out.putNextEntry(next);if(changed!=null)out.write(changed);else try(InputStream src=in.getInputStream(old)){src.transferTo(out);}out.closeEntry();
            }
        }
        Files.move(tmp,file,StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);done=true;
        } finally {if(!done)Files.deleteIfExists(tmp);}
    }
    public static void main(String[] args) throws Exception {
        if(args.length!=4)throw new IllegalArgumentException("source target source-format target-format");
        Path source=Path.of(args[0]),target=Path.of(args[1]);Map<String,Freeze> frozen;
        try(ZipFile in=new ZipFile(source.toFile())) {frozen=args[2].equals("xlsx")?fromXlsx(in):fromOds(in);}
        Map<String,byte[]> changes=new HashMap<>();DefaultFont font=null;Map<String,double[]> columns=Map.of();Map<String,Map<String,String>> sourceFonts=Map.of();
        if(args[2].equals("ods")&&args[3].equals("xlsx")) {
            // Width correction is optional: an unusually large or unfamiliar ODS
            // must still be convertible using the office engine's own output.
            try(ZipFile in=new ZipFile(source.toFile())) {font=odsDefaultFont(in);if(font!=null)columns=odsColumnLengths(in);}
            catch(Exception unsupportedWidthMetadata) {font=null;columns=Map.of();}
            try(ZipFile in=new ZipFile(source.toFile())) {sourceFonts=OdsFontRestorer.sourceFonts(in);}
            catch(Exception unsupportedFontMetadata) {sourceFonts=Map.of();}
        }
        try(ZipFile out=new ZipFile(target.toFile())) {
            if(args[3].equals("ods")){if(!frozen.isEmpty())changes.put("settings.xml",odsSettings(out,frozen));}
            else {
                List<Sheet> outputSheets=sheets(out);
                for(Sheet s:outputSheets) if(frozen.containsKey(s.name()))changes.put(s.path(),xlsxSheet(out,s.path(),frozen.get(s.name())));
                // Width/style adaptation is optional and must be atomic: if any
                // sheet cannot be safely inspected, retain engine output and
                // independent freeze-pane changes rather than fail conversion.
                if(font!=null)try {
                    if(usableColumns(out,outputSheets,columns,font)) {
                        byte[] styles=preserveStyles(out,font);
                        if(styles!=null) {
                            Map<String,byte[]> widthChanges=new HashMap<>();widthChanges.put("xl/styles.xml",styles);
                            for(Sheet s:outputSheets) {byte[] prior=changes.get(s.path());
                                widthChanges.put(s.path(),applyColumnLengths(prior!=null?prior:read(out,s.path()),columns.get(s.name()),font));
                            }
                            changes.putAll(widthChanges);
                        }
                    }
                } catch(Exception unsupportedWidthOutput) { /* keep original export */ }
                if(!sourceFonts.isEmpty())try {changes.putAll(OdsFontRestorer.restore(out,outputSheets,changes,sourceFonts));}
                catch(Exception unsupportedFontOutput) { /* retain converter output and independent view corrections */ }
            }
        }
        rewrite(target,changes);
    }
}
