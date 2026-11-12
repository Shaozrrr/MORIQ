import java.io.*;
import java.util.*;
import java.util.zip.*;
import org.w3c.dom.*;

/** Experimental, conservative ODS cell font-name restoration. */
final class OdsFontRestorer {
    private static final String S=SheetViewPreserver.STYLE, T=SheetViewPreserver.TABLE, X=SheetViewPreserver.XL;
    private static final String FO=SheetViewPreserver.FO, SVG="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0";
    private static final String TEXT="urn:oasis:names:tc:opendocument:xmlns:text:1.0";
    private record Style(String parent,String font) {}
    private static int count(Element e,String name,int max) throws IOException {
        String value=e.getAttributeNS(T,name); if(value.isEmpty())return 1;
        try {int n=Integer.parseInt(value);if(n>0&&n<=max)return n;}catch(NumberFormatException ignored){}
        throw new IOException("invalid repeat");
    }
    private static String unquote(String s) {return s.trim().replaceAll("^['\"]|['\"]$","");}
    private static String resolve(String key,Map<String,Style> styles,Map<String,String> faces) throws IOException {
        Set<String> visited=new HashSet<>();
        while(!key.isEmpty()) {
            if(!visited.add(key))throw new IOException("style cycle");
            Style s=styles.get(key);if(s==null)throw new IOException("unknown cell style");
            if(!s.font().isEmpty())return faces.getOrDefault(s.font(),s.font());
            key=s.parent();
        }
        return "";
    }
    static Map<String,Map<String,String>> sourceFonts(ZipFile in) throws Exception {
        Document stylesDoc=SheetViewPreserver.xml(SheetViewPreserver.read(in,"styles.xml"));
        Document content=SheetViewPreserver.xml(SheetViewPreserver.read(in,"content.xml"));
        Map<String,String> faces=new HashMap<>();Map<String,Style> styles=new HashMap<>();
        for(Document doc:List.of(stylesDoc,content)) {
            NodeList fontFaces=doc.getElementsByTagNameNS(S,"font-face");
            for(int i=0;i<fontFaces.getLength();i++) {Element e=(Element)fontFaces.item(i);String name=e.getAttributeNS(S,"name"), family=unquote(e.getAttributeNS(SVG,"font-family"));if(!name.isEmpty()&&!family.isEmpty()) {String prior=faces.putIfAbsent(name,family);if(prior!=null&&!prior.equals(family))throw new IOException("ambiguous font face");}}
            NodeList list=doc.getElementsByTagNameNS(S,"style");
            for(int i=0;i<list.getLength();i++) {Element e=(Element)list.item(i);if(!"table-cell".equals(e.getAttributeNS(S,"family")))continue;
                Element p=SheetViewPreserver.first(e,S,"text-properties");String font="";
                if(p!=null){font=unquote(p.getAttributeNS(FO,"font-family"));if(font.isEmpty())font=p.getAttributeNS(S,"font-name").trim();}
                String name=e.getAttributeNS(S,"name");Style value=new Style(e.getAttributeNS(S,"parent-style-name"),font), prior=styles.putIfAbsent(name,value);
                if(prior!=null&&!prior.equals(value))throw new IOException("ambiguous cell style");
            }
        }
        if(!styles.containsKey("Default"))return Map.of();
        Map<String,Map<String,String>> result=new HashMap<>();NodeList tables=content.getElementsByTagNameNS(T,"table");
        int used=0;
        for(int ti=0;ti<tables.getLength();ti++) {Element table=(Element)tables.item(ti);
            if(!(table.getParentNode() instanceof Element parent)||!"spreadsheet".equals(parent.getLocalName()))continue;
            String[] defaults=new String[16385];Arrays.fill(defaults,"Default");int col=1;
            for(Node n=table.getFirstChild();n!=null;n=n.getNextSibling())if(n instanceof Element e && T.equals(e.getNamespaceURI()) && "table-column".equals(e.getLocalName())) {
                int repeated=count(e,"number-columns-repeated",16384);String style=e.getAttributeNS(T,"default-cell-style-name");if(style.isEmpty())style="Default";
                for(int k=0;k<repeated&&col<=16384;k++)defaults[col++]=style;
            }
            if(SheetViewPreserver.children(table,T,"table-column").size()!=table.getElementsByTagNameNS(T,"table-column").getLength())throw new IOException("nested column groups");
            if(SheetViewPreserver.children(table,T,"table-row").size()!=table.getElementsByTagNameNS(T,"table-row").getLength())throw new IOException("nested row groups");
            Map<String,String> cells=new HashMap<>();int row=1;
            for(Element re:SheetViewPreserver.children(table,T,"table-row")) {
                int repeatRows=count(re,"number-rows-repeated",1048576);int column=1;
                String rowStyle=re.getAttributeNS(T,"default-cell-style-name");
                for(Node n=re.getFirstChild();n!=null;n=n.getNextSibling())if(n instanceof Element ce && T.equals(ce.getNamespaceURI()) && ("table-cell".equals(ce.getLocalName())||"covered-table-cell".equals(ce.getLocalName()))) {
                    int repeatCols=count(ce,"number-columns-repeated",16384);
                    // Empty cells may carry explicit formatting for future input.
                    boolean populated=ce.hasAttributeNS("urn:oasis:names:tc:opendocument:xmlns:office:1.0","value-type") || ce.hasAttributeNS(T,"formula") || ce.hasAttributeNS(T,"style-name");
                    // Preserve the office engine's rich-text runs untouched while
                    // still repairing independent ordinary cells in this workbook.
                    if(populated && ce.getElementsByTagNameNS(TEXT,"span").getLength()==0) {
                        if((long)repeatCols*repeatRows+used>100000)throw new IOException("too many populated cells");
                        for(int y=0;y<repeatRows;y++)for(int x=0;x<repeatCols;x++) {
                            int c=column+x,r=row+y;if(c>16384||r>1048576)throw new IOException("cell outside XLSX bounds");
                            String style=ce.getAttributeNS(T,"style-name");if(style.isEmpty())style=rowStyle;if(style.isEmpty())style=defaults[c];
                            String font=resolve(style,styles,faces);if(!font.isEmpty())cells.put(SheetViewPreserver.column(c-1)+r,font);
                            used++;
                        }
                    }
                    column+=repeatCols;
                }
                row+=repeatRows;
            }
            result.put(table.getAttributeNS(T,"name"),cells);
        }
        return result;
    }
    static Map<String,byte[]> restore(ZipFile out,List<SheetViewPreserver.Sheet> sheets,Map<String,byte[]> existing,Map<String,Map<String,String>> desired) throws Exception {
        if(desired.size()!=sheets.size())return Map.of();
        byte[] styleBytes=existing.getOrDefault("xl/styles.xml",SheetViewPreserver.read(out,"xl/styles.xml"));
        Document styles=SheetViewPreserver.xml(styleBytes);Element root=styles.getDocumentElement();
        Element fonts=SheetViewPreserver.first(root,X,"fonts"), xfs=SheetViewPreserver.first(root,X,"cellXfs");if(fonts==null||xfs==null)return Map.of();
        List<Element> fontList=SheetViewPreserver.children(fonts,X,"font"),xfList=SheetViewPreserver.children(xfs,X,"xf");
        Map<String,Integer> fontCache=new HashMap<>(),xfCache=new HashMap<>();Map<String,byte[]> changes=new HashMap<>();boolean changed=false;
        for(SheetViewPreserver.Sheet sheet:sheets) {
            Map<String,String> values=desired.get(sheet.name());if(values==null)return Map.of();
            byte[] sheetBytes=existing.getOrDefault(sheet.path(),SheetViewPreserver.read(out,sheet.path()));Document doc=SheetViewPreserver.xml(sheetBytes);NodeList cs=doc.getElementsByTagNameNS(X,"c");boolean sheetChanged=false;
            for(int i=0;i<cs.getLength();i++) {Element cell=(Element)cs.item(i);String wanted=values.get(cell.getAttribute("r"));if(wanted==null)continue;
                int xi=SheetViewPreserver.number(cell.getAttribute("s"),65535);if(xi>=xfList.size())throw new IOException("invalid style");Element xf=xfList.get(xi);
                int fi=SheetViewPreserver.number(xf.getAttribute("fontId"),65535);if(fi>=fontList.size())throw new IOException("invalid font");Element font=fontList.get(fi), name=SheetViewPreserver.first(font,X,"name");if(name==null)throw new IOException("font without name");
                if(wanted.equals(name.getAttribute("val")))continue;
                String fk=fi+"\0"+wanted;Integer newFont=fontCache.get(fk);
                if(newFont==null){if(fontList.size()>=64000)throw new IOException("font limit");Element copy=(Element)font.cloneNode(true);SheetViewPreserver.first(copy,X,"name").setAttribute("val",wanted);for(Element scheme:new ArrayList<>(SheetViewPreserver.children(copy,X,"scheme")))copy.removeChild(scheme);newFont=fontList.size();fontList.add(copy);fonts.appendChild(copy);fontCache.put(fk,newFont);}
                String xk=xi+":"+newFont;Integer newXf=xfCache.get(xk);
                if(newXf==null){if(xfList.size()>=64000)throw new IOException("cell style limit");Element copy=(Element)xf.cloneNode(true);copy.setAttribute("fontId",newFont.toString());copy.setAttribute("applyFont","1");newXf=xfList.size();xfList.add(copy);xfs.appendChild(copy);xfCache.put(xk,newXf);}
                cell.setAttribute("s",newXf.toString());sheetChanged=true;changed=true;
            }
            if(sheetChanged)changes.put(sheet.path(),SheetViewPreserver.bytes(doc));
        }
        if(changed){fonts.setAttribute("count",Integer.toString(fontList.size()));xfs.setAttribute("count",Integer.toString(xfList.size()));changes.put("xl/styles.xml",SheetViewPreserver.bytes(styles));}
        return changes;
    }
}
