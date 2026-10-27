import Foundation
import PDFKit

@_silgen_name("lab_inflate_zlib") private func outlineInflate(_ source:UnsafePointer<UInt8>,_ count:Int,_ output:UnsafeMutablePointer<UInt8>,_ capacity:Int)->Int

/// ISO 32000-1, 7.5.5/7.5.7/7.5.8 and 12.3.3: append catalog, Info and
/// outline revisions. Page objects, content streams, fonts and images are never rewritten.
enum NativePDFOutline {
    struct Ref:Hashable {
        let number:Int,generation:Int
        var text:String {"\(number) \(generation) R"}
    }
    enum Entry {case free,direct(Int,Int),compressed(Int,Int)}
    struct Object {let value:Data;let stream:Data?}
    typealias Scanner=PDFInformationRevision.Scanner
    static func failure(_ detail:String)->ReaderFailure {ReaderFailure("PDF目录保存失败："+detail+"。未替换原文件。")}
    static func integer(_ data:Data?)->Int? {data.flatMap {Int(String(decoding:$0,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))}}
    static func ref(_ data:Data?)throws->Ref {
        guard let data else {throw failure("缺少对象引用")};var s=Scanner(data:data,at:0)
        guard let n=Int(s.token()),let g=Int(s.token()),n>0,g>=0,g<=65535,s.token()=="R" else {throw failure("对象引用无效")}
        return Ref(number:n,generation:g)
    }
    static func dict(_ data:Data)throws->[String:Data] {var s=Scanner(data:data,at:0);return try s.dictionary().mapValues {Data(data[$0])}}
    static func decodedName(_ raw:String)->String {
        let bytes=Array(raw.utf8);var out:[UInt8]=[],i=0
        while i<bytes.count {
            if bytes[i]==35,i+2<bytes.count,let value=UInt8(String(decoding:bytes[i+1...i+2],as:UTF8.self),radix:16) {out.append(value);i += 3}
            else {out.append(bytes[i]);i += 1}
        }
        return String(decoding:out,as:UTF8.self)
    }
    static func vector(_ data:Data)throws->[Int] {
        var s=Scanner(data:data,at:0);s.space();guard s.at<data.count,data[s.at]==91 else {throw failure("索引数组无效")};s.at += 1
        var result:[Int]=[]
        while true {s.space();guard s.at<data.count else {throw failure("索引数组被截断")};if data[s.at]==93 {return result}
            guard let n=Int(s.token()),n>=0,result.count<2_000_000 else {throw failure("索引数组超限")};result.append(n)}
    }
    final class Source {
        let data:Data,lastXref:Int
        var entries:[Int:Entry]=[:],trailer:[String:Data]=[:],size=0
        var usesXrefStreams=false
        private var cache:[Ref:Object]=[:],loading=Set<Ref>(),objectStreams:[Int:(Data,[Int:(Int,Int)])]=[:]
        init(_ url:URL)throws {
            data=try Data(contentsOf:url,options:.mappedIfSafe)
            guard let marker=data.range(of:Data("startxref".utf8),options:.backwards,in:max(0,data.count-65536)..<data.count) else {throw failure("找不到交叉引用")}
            var s=Scanner(data:data,at:marker.upperBound);guard let at=Int(s.token()),at>=0,at<data.count else {throw failure("交叉引用位置无效")};lastXref=at
            var next:Int?=at,seen=Set<Int>()
            for _ in 0..<1024 {
                guard let offset=next else {break};guard seen.insert(offset).inserted else {throw failure("交叉引用链循环")}
                var (local,values)=try xref(offset)
                if let hybrid=integer(values["XRefStm"]),!seen.contains(hybrid) {
                    seen.insert(hybrid);let (extra,_)=try xref(hybrid);local.merge(extra){_,new in new}
                }
                for (n,entry) in local where entries[n]==nil {entries[n]=entry}
                for (key,value) in values where trailer[key]==nil {trailer[key]=value}
                guard let n=integer(values["Size"]),n>0,n<1_000_000_000 else {throw failure("对象计数无效")};size=max(size,n)
                next=integer(values["Prev"])
                if values["Prev"] != nil && next==nil {throw failure("交叉引用链位置无效")}
            }
            guard next==nil,trailer["Encrypt"]==nil else {throw failure("交叉引用链过长或文档已加密")}
        }
        private func direct(_ at:Int,expected:Ref? = nil,resolveLength:Bool = true)throws->Object {
            guard at>=0,at<data.count else {throw failure("对象位置越界")};var s=Scanner(data:data,at:at)
            guard let n=Int(s.token()),let g=Int(s.token()),s.token()=="obj",expected.map({$0.number==n && $0.generation==g}) ?? true else {throw failure("对象头部不匹配")}
            let range=try s.value(),value=Data(data[range]);let end=s.at
            if s.token() != "stream" {return Object(value:value,stream:nil)}
            let fields=try dict(value);var length=integer(fields["Length"])
            if length==nil,resolveLength,let target=try? ref(fields["Length"]) {length=integer(try object(target).value)}
            guard let length,length>=0,length<=128*1024*1024 else {throw failure("对象流长度无效或超过限制")}
            if s.at<data.count,data[s.at]==13 {s.at += 1;if s.at<data.count,data[s.at]==10 {s.at += 1}}
            else if s.at<data.count,data[s.at]==10 {s.at += 1}
            else {throw failure("对象流缺少换行")}
            guard s.at>=end,length<=data.count-s.at else {throw failure("对象流被截断")}
            return Object(value:value,stream:Data(data[s.at..<s.at+length]))
        }
        private func xref(_ at:Int)throws->([Int:Entry],[String:Data]) {
            guard at>=0,at<data.count else {throw failure("交叉引用越界")};var s=Scanner(data:data,at:at);var result:[Int:Entry]=[:]
            if s.token()=="xref" {
                while true {
                    let first=s.token();if first=="trailer" {break}
                    guard let start=Int(first),let count=Int(s.token()),start>=0,start<1_000_000_000,count>=0,count<=1_000_000,result.count+count<=1_000_000 else {throw failure("交叉引用表无效或超限")}
                    for i in 0..<count {
                        guard let offset=Int(s.token()),let generation=Int(s.token()),offset>=0,generation>=0,generation<=65535 else {throw failure("交叉引用表项无效")}
                        let flag=s.token();guard flag=="n" || flag=="f" else {throw failure("交叉引用标记无效")}
                        result[start+i]=flag=="n" ? .direct(offset,generation):.free
                    }
                }
                let values=try s.dictionary().mapValues {Data(data[$0])};return(result,values)
            }
            usesXrefStreams=true
            let object=try direct(at,resolveLength:false),values=try dict(object.value)
            guard let w=values["W"],let count=integer(values["Size"]),count>0,count<=1_000_000 else {throw failure("交叉引用流头无效")}
            let widths=try vector(w);guard widths.count==3,widths.allSatisfy({$0<=8}),widths.reduce(0,+)>0 else {throw failure("交叉引用流字段宽度无效")}
            let indices=try values["Index"].map(vector) ?? [0,count]
            guard indices.count%2==0 else {throw failure("交叉引用分段无效")}
            let bytes=try decoded(object),stride=widths.reduce(0,+);var cursor=0,total=0
            func read(_ n:Int)throws->Int {
                guard n<=bytes.count-cursor else {throw failure("交叉引用流被截断")};var value:UInt64=0
                for _ in 0..<n {guard value<=UInt64(Int.max)>>8 else {throw failure("交叉引用整数溢出")};value=(value<<8)|UInt64(bytes[cursor]);cursor += 1}
                guard value<=Int.max else {throw failure("交叉引用整数溢出")};return Int(value)
            }
            for pair in stridePairs(indices) {
                let (start,n)=pair;guard start>=0,n>=0,start<count,n<=count-start,total+n<=1_000_000,n<=(bytes.count-cursor)/stride else {throw failure("交叉引用分段越界")};total += n
                for i in 0..<n {
                    let type=widths[0]==0 ? 1:try read(widths[0]),a=try read(widths[1]),b=try read(widths[2])
                    switch type {case 0:result[start+i] = .free;case 1:result[start+i] = .direct(a,b);case 2:result[start+i] = .compressed(a,b);default:result[start+i] = .free}
                }
            }
            return(result,values)
        }
        private func stridePairs(_ values:[Int])->[(Int,Int)] {Swift.stride(from:0,to:values.count,by:2).map {(values[$0],values[$0+1])}}
        func object(_ reference:Ref)throws->Object {
            if let cached=cache[reference] {return cached}
            guard loading.insert(reference).inserted,loading.count<64 else {throw failure("对象引用循环")};defer {loading.remove(reference)}
            guard let entry=entries[reference.number] else {throw failure("对象未列入交叉引用")}
            let result:Object
            switch entry {
            case .free:throw failure("对象已释放")
            case .direct(let at,let generation):guard generation==reference.generation else {throw failure("对象代数不匹配")};result=try direct(at,expected:reference)
            case .compressed(let stream,let index):
                guard reference.generation==0 else {throw failure("压缩对象代数无效")}
                if objectStreams[stream]==nil {
                    let container=try object(Ref(number:stream,generation:0)),fields=try dict(container.value),bytes=try decoded(container)
                    guard let n=integer(fields["N"]),let first=integer(fields["First"]),n>0,n<=100000,first>=0,first<=bytes.count else {throw failure("压缩对象目录无效")}
                    var s=Scanner(data:bytes,at:0),offsets:[Int:(Int,Int)]=[:]
                    for i in 0..<n {guard let number=Int(s.token()),let offset=Int(s.token()),number>0,offset>=0,offset<bytes.count-first else {throw failure("压缩对象偏移无效")};offsets[number]=(first+offset,i)}
                    guard s.at<=first else {throw failure("压缩对象头部重叠")};objectStreams[stream]=(bytes,offsets)
                }
                let (bytes,offsets)=objectStreams[stream]!
                guard let (at,actual)=offsets[reference.number],actual==index else {throw failure("压缩对象索引不匹配")}
                var scanner=Scanner(data:bytes,at:at);let range=try scanner.value();result=Object(value:Data(bytes[range]),stream:nil)
            }
            cache[reference]=result;return result
        }
        private func decoded(_ object:Object)throws->Data {
            guard var bytes=object.stream else {throw failure("对象缺少数据流")};let fields=try dict(object.value)
            var filters:[String]=[]
            if let data=fields["Filter"] {
                var s=Scanner(data:data,at:0);s.space()
                if s.at<data.count,data[s.at]==91 {s.at += 1;while true {s.space();guard s.at<data.count else {throw failure("压缩过滤器数组被截断")};if data[s.at]==93 {break};let range=try s.value();filters.append(String(decoding:data[range],as:UTF8.self))}}
                else {filters=[String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)]}
            }
            var parameters:[Data?]=Array(repeating:nil,count:filters.count)
            if let parms=fields["DecodeParms"],!filters.isEmpty {
                var s=Scanner(data:parms,at:0);s.space()
                if s.at<parms.count,parms[s.at]==91 {s.at += 1;for i in filters.indices {let range=try s.value();parameters[i]=Data(parms[range])}}
                else {parameters[0]=parms}
            }
            for (index,filter) in filters.enumerated() {
                switch filter {
                case "/FlateDecode","/Fl":
                    guard !bytes.isEmpty else {throw failure("压缩对象流为空")}
                    var found:Data?
                    for capacity in [64,128,256,512,1024,2048,4096,8192,16384,32768,65536,131072].map({$0*1024}) {
                        var result=Data(count:capacity)
                        let count=result.withUnsafeMutableBytes {dst in bytes.withUnsafeBytes {src in outlineInflate(src.baseAddress!.assumingMemoryBound(to:UInt8.self),bytes.count,dst.baseAddress!.assumingMemoryBound(to:UInt8.self),capacity)}}
                        if count>=0 {result.count=count;found=result;break}
                    }
                    guard let result=found else {throw failure("压缩对象解压失败或过大")};bytes=result
                case "/ASCIIHexDecode","/AHx":
                    var result=Data(),high:Int?
                    for byte in bytes {
                        if byte==62 {break};if [UInt8(0),9,10,12,13,32].contains(byte) {continue}
                        let digit:Int
                        switch byte {case 48...57:digit=Int(byte-48);case 65...70:digit=Int(byte-65)+10;case 97...102:digit=Int(byte-97)+10;default:throw failure("十六进制对象流无效")}
                        if let value=high {result.append(UInt8(value*16+digit));high=nil}else{high=digit}
                    }
                    if let high {result.append(UInt8(high*16))};bytes=result
                default:throw failure("暂不支持此对象流压缩过滤器")
                }
                if let parameter=parameters[index],String(decoding:parameter,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines) != "null" {
                    let p=try dict(parameter),predictor=integer(p["Predictor"]) ?? 1
                    if predictor != 1 {bytes=try undoPredictor(bytes,predictor:predictor,columns:integer(p["Columns"]) ?? 1,colors:integer(p["Colors"]) ?? 1,bits:integer(p["BitsPerComponent"]) ?? 8)}
                }
            }
            return bytes
        }
        private func undoPredictor(_ bytes:Data,predictor:Int,columns:Int,colors:Int,bits:Int)throws->Data {
            guard columns>0,columns<=1_000_000,colors>0,colors<=4,bits==8 else {throw failure("对象流预测参数不支持")}
            let row=columns*colors,bpp=colors
            if predictor==2 {
                guard bytes.count%row==0 else {throw failure("对象流行长度无效")};var out=bytes
                for start in Swift.stride(from:0,to:out.count,by:row) {for x in bpp..<row {out[start+x]=out[start+x]&+out[start+x-bpp]}}
                return out
            }
            guard (10...15).contains(predictor),bytes.count%(row+1)==0 else {throw failure("对象流预测行无效")}
            var out=Data(),previous=[UInt8](repeating:0,count:row)
            for start in Swift.stride(from:0,to:bytes.count,by:row+1) {
                let filter=bytes[start];guard filter<=4 else {throw failure("对象流预测过滤器无效")};var line=[UInt8](bytes[start+1..<start+1+row])
                for x in 0..<row {
                    let a=x>=bpp ? Int(line[x-bpp]):0,b=Int(previous[x]),c=x>=bpp ? Int(previous[x-bpp]):0
                    let value:Int
                    switch filter {case 0:value=0;case 1:value=a;case 2:value=b;case 3:value=(a+b)/2;default:
                        let p=a+b-c,pa=abs(p-a),pb=abs(p-b),pc=abs(p-c);value=pa<=pb && pa<=pc ? a:(pb<=pc ? b:c)
                    }
                    line[x]=line[x]&+UInt8(value)
                }
                out.append(contentsOf:line);previous=line
            }
            return out
        }
        func pageReferences(_ catalog:[String:Data])throws->[Ref] {
            var pages:[Ref]=[],active=Set<Ref>()
            func visit(_ reference:Ref,_ depth:Int)throws {
                guard depth<128,active.insert(reference).inserted,pages.count<=100000 else {throw failure("页面树循环或超限")};defer {active.remove(reference)}
                let fields=try dict(object(reference).value)
                if fields["Type"]==Data("/Page".utf8) {pages.append(reference);return}
                guard let kids=fields["Kids"] else {throw failure("页面树缺少子项")};var s=Scanner(data:kids,at:0);s.space()
                guard s.at<kids.count,kids[s.at]==91 else {throw failure("页面子项不是数组")};s.at += 1
                while true {s.space();guard s.at<kids.count else {throw failure("页面子项被截断")};if kids[s.at]==93 {break};let range=try s.value();try visit(ref(Data(kids[range])),depth+1)}
            }
            try visit(ref(catalog["Pages"]),0);return pages
        }
    }
    static func write(_ chapters:[BookChapter],attributes:[AnyHashable:Any],from source:URL,to target:URL)throws {
        guard source.standardizedFileURL != target.standardizedFileURL else {throw failure("临时目标与原文件相同")}
        let pdf=try Source(source),root=try ref(pdf.trailer["Root"]);var catalog=try dict(pdf.object(root).value)
        let pages=try pdf.pageReferences(catalog)
        guard !pages.isEmpty,chapters.count<=50000,chapters.allSatisfy({$0.pageIndex>=(-1) && $0.pageIndex<pages.count && $0.level>=0 && $0.level<=32}) else {throw failure("目录目标或层级无效")}
        let info=pdf.size,outlines=info+1,nodeStart=info+2,newSize=nodeStart+chapters.count
        var children=[Int:[Int]](),parents=[Int](),stack=[Int]()
        for (i,chapter) in chapters.enumerated() {
            while stack.count>chapter.level {stack.removeLast()}
            guard stack.count==chapter.level else {throw failure("目录层级跳跃")}
            let parent=stack.last ?? -1;parents.append(parent);children[parent,default:[]].append(i);stack.append(i)
        }
        var descendants=[Int](repeating:0,count:chapters.count)
        for i in chapters.indices.reversed() {descendants[i]=children[i,default:[]].reduce(0){$0+1+descendants[$1]}}
        func reference(_ i:Int)->String {"\(i<0 ? outlines:nodeStart+i) 0 R"}
        var revision=Data("\n".utf8),locations:[(Int,Int,Int)]=[]
        func append(_ number:Int,_ generation:Int = 0,_ value:Data)throws {
            let offset=pdf.data.count+revision.count;guard offset<10_000_000_000 else {throw failure("文件过大")}
            locations.append((number,generation,offset));revision.append(Data("\(number) \(generation) obj\n".utf8));revision.append(value);revision.append(Data("\nendobj\n".utf8))
        }
        // Keep unedited Info values as PDF objects (names, dates, references,
        // arrays, etc.). PDFKit exposes names such as Trapped as plain strings.
        let managed=Set(NativeDocumentMetadata.mapping.values).union([NativeDocumentMetadata.key])
        var infoFields:[String:Data]=[:]
        if let old=pdf.trailer["Info"],old != Data("null".utf8) {
            infoFields=try dict(old.starts(with:Data("<<".utf8)) ? old:pdf.object(ref(old)).value)
        }
        infoFields=infoFields.filter {!managed.contains(decodedName($0.key))}
        for (key,value) in attributes {
            let name=(key.base as? PDFDocumentAttribute)?.rawValue ?? String(describing:key)
            if managed.contains(name) {infoFields[name]=Data(try PDFInformationRevision.encoded(value).utf8)}
        }
        var infoData=Data("<<\n".utf8)
        for key in infoFields.keys.sorted() {infoData.append(Data(("/"+key+" ").utf8));infoData.append(infoFields[key]!);infoData.append(10)}
        infoData.append(Data(">>".utf8));try append(info,0,infoData)
        catalog=catalog.filter {decodedName($0.key) != "Outlines"}
        catalog["Outlines"]=Data("\(outlines) 0 R".utf8)
        var rootData=Data("<<\n".utf8)
        for key in catalog.keys.sorted() {rootData.append(Data(("/"+key+" ").utf8));rootData.append(catalog[key]!);rootData.append(10)}
        rootData.append(Data(">>".utf8));try append(root.number,root.generation,rootData)
        func branch(_ i:Int)->String {
            guard let list=children[i],let first=list.first,let last=list.last else {return ""}
            return " /First \(reference(first)) /Last \(reference(last)) /Count \(i<0 ? chapters.count:descendants[i])"
        }
        try append(outlines,0,Data(("<< /Type /Outlines"+branch(-1)+" >>").utf8))
        for (i,chapter) in chapters.enumerated() {
            let siblings=children[parents[i]]!,position=siblings.firstIndex(of:i)!
            var text="<< /Title "+PDFInformationRevision.pdfString(chapter.title)+" /Parent "+reference(parents[i])+branch(i)
            if position>0 {text += " /Prev "+reference(siblings[position-1])}
            if position+1<siblings.count {text += " /Next "+reference(siblings[position+1])}
            if chapter.pageIndex>=0 {text += " /Dest [\(pages[chapter.pageIndex].text) /Fit]"}
            try append(nodeStart+i,0,Data((text+" >>").utf8))
        }
        let xref=pdf.data.count+revision.count
        if pdf.usesXrefStreams {
            // Consolidate the resolved cross-reference entries in this revision.
            // Quartz does not reliably follow chains mixing tables and streams.
            let xrefObject=newSize
            var resolved:[Int:(Int,Int,Int)]=[:]
            for (number,entry) in pdf.entries {
                switch entry {
                case .free:resolved[number]=(0,0,65535)
                case .direct(let offset,let generation):resolved[number]=(1,offset,generation)
                case .compressed(let stream,let index):resolved[number]=(2,stream,index)
                }
            }
            for (number,generation,offset) in locations+[(xrefObject,0,xref)] {resolved[number]=(1,offset,generation)}
            resolved[0]=(0,0,65535)
            let records=resolved.map {($0.key,$0.value.0,$0.value.1,$0.value.2)}.sorted {$0.0<$1.0}
            var bytes=Data(),index:[Int]=[],i=0
            while i<records.count {
                var j=i+1;while j<records.count && records[j].0==records[j-1].0+1 {j += 1}
                index += [records[i].0,j-i]
                for entry in records[i..<j] {
                    bytes.append(UInt8(entry.1));let offset=UInt64(entry.2)
                    for shift in Swift.stride(from:56,through:0,by:-8) {bytes.append(UInt8(truncatingIfNeeded:offset>>shift))}
                    for shift in Swift.stride(from:24,through:0,by:-8) {bytes.append(UInt8(truncatingIfNeeded:entry.3>>shift))}
                };i=j
            }
            var header=Data("<< /Type /XRef /Size \(xrefObject+1) /Root \(root.text) /Info \(info) 0 R /W [1 8 4] /Index [".utf8)
            header.append(Data(index.map(String.init).joined(separator:" ").utf8));header.append(Data("]".utf8))
            if let id=pdf.trailer["ID"] {header.append(Data(" /ID ".utf8));header.append(id)}
            header.append(Data(" /Length \(bytes.count) >>\nstream\n".utf8));header.append(bytes);header.append(Data("\nendstream".utf8))
            try append(xrefObject,0,header)
            revision.append(Data("startxref\n\(xref)\n%%EOF\n".utf8))
        } else {
        revision.append(Data("xref\n".utf8));let sorted=locations.sorted {$0.0<$1.0};var i=0
        while i<sorted.count {
            var j=i+1;while j<sorted.count && sorted[j].0==sorted[j-1].0+1 {j += 1}
            revision.append(Data("\(sorted[i].0) \(j-i)\n".utf8))
            for entry in sorted[i..<j] {revision.append(Data(String(format:"%010lld %05d n \n",Int64(entry.2),entry.1).utf8))};i=j
        }
        revision.append(Data("trailer\n<< /Size \(newSize) /Root \(root.text) /Info \(info) 0 R /Prev \(pdf.lastXref)".utf8))
        if let id=pdf.trailer["ID"] {revision.append(Data(" /ID ".utf8));revision.append(id)}
        revision.append(Data(" >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        }
        guard FileManager.default.createFile(atPath:target.path,contents:nil) else {throw failure("无法创建临时结果")}
        let handle=try FileHandle(forWritingTo:target);defer {try? handle.close()}
        try handle.write(contentsOf:pdf.data);try handle.write(contentsOf:revision);try handle.synchronize()
    }
}
