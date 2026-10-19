import AppKit
import ImageIO

func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    print("")
}

let args = CommandLine.arguments
if args.count >= 4, ["--apply-draft", "--rename-book", "--update-information"].contains(args[1]) {
    do {
        let book = try BookArchive(url: URL(fileURLWithPath: args[2]))
        if args[1] == "--apply-draft" {
            let draft = try JSONDecoder().decode(BookEditDraft.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            let backups = try book.saveEdits(draft, backup: args.contains("--backup"), preserveDates: !args.contains("--update-dates"), writeInfo: !args.contains("--contents-only"))
            try emit(["saved": true, "backups": backups.map(\.path), "location": book.editingLocation])
        } else if args[1] == "--update-information" {
            let change = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
            let path = try book.updateInformation(stem: change["stem"] as? String ?? book.url.deletingPathExtension().lastPathComponent, metadata: change["metadata"] as? [String: String], backup: args.contains("--backup"), preserveDates: !args.contains("--update-dates"))
            try emit(["path": path.path])
        } else { try emit(["path": try book.renamedURL(stem: args[3], preserveDates: !args.contains("--update-dates")).path]) }
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if args.count >= 3,["--batch-propose","--batch-apply","--batch-merge"].contains(args[1]) {
    do {
        if args[1] == "--batch-propose" {
            let urls = try BatchNaming.discover(URL(fileURLWithPath:args[2]),recursive:args.contains("--recursive"))
            var rows: [[String:Any]] = []
            for url in urls {
                do {
                    let proposal = try autoreleasepool { try BatchNaming.analyse(url,ocr:!args.contains("--no-ocr")) }
                    let data = try JSONSerialization.jsonObject(with:JSONEncoder().encode(proposal)) as! [String:Any]
                    rows.append(["path":url.path,"proposal":data,"candidates":proposal.candidates,"reviewReasons":proposal.reviewReasons])
                } catch { rows.append(["path":url.path,"error":error.localizedDescription]) }
            }
            try emit(["books":rows,"count":urls.count]); exit(0)
        }
        if args[1] == "--batch-merge" {
            let input = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[2]))) as! [String:Any]
            let evidence = try JSONDecoder().decode([NamingEvidence].self,from:JSONSerialization.data(withJSONObject:input["evidence"] ?? []))
            let proposal = BatchNaming.merge(original:input["original"] as? [String:String] ?? [:],evidence:evidence)
            try emit(["metadata":proposal.metadata,"candidates":proposal.candidates,"reviewReasons":proposal.reviewReasons]); exit(0)
        }
        let input = try JSONDecoder().decode([BatchNameRequest].self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
        let errors = BatchNaming.preflight(input)
        guard errors.isEmpty else { try emit(["saved":false,"errors":errors.map { ["row":$0.key,"error":$0.value] }]); exit(1) }
        var outcomes: [BatchNameOutcome] = []
        for request in input {
            do { let url = try BatchNaming.apply(request,backup:args.contains("--backup"),preserveDates:!args.contains("--update-dates")); outcomes.append(BatchNameOutcome(original:request.path,destination:url.path,error:nil)) }
            catch { outcomes.append(BatchNameOutcome(original:request.path,destination:nil,error:error.localizedDescription)) }
        }
        try FileHandle.standardOutput.write(contentsOf:JSONEncoder().encode(outcomes)); print(""); exit(outcomes.allSatisfy{$0.error == nil} ? 0 : 1)
    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if args.count >= 3, args[1] == "--page-audit" || args[1] == "--correct-pages" || args[1] == "--plan-pages" {
    do {
        let book = try BookArchive(url:URL(fileURLWithPath:args[2]))
        if args[1] == "--page-audit" {
            let extraFile = args.dropFirst(3).first(where:{ !$0.hasPrefix("--") })
            let extra: [InspectionTarget] = try extraFile.map { try JSONDecoder().decode([InspectionTarget].self,from:Data(contentsOf:URL(fileURLWithPath:$0))) } ?? []
            var findings = args.contains("--ocr") ? try PageInspection.scan(book,extra:extra) : PageInspection.structural(book)
            if let option = args.first(where:{$0.hasPrefix("--current-page=")}),let physical = Int(option.dropFirst("--current-page=".count)),book.pages.indices.contains(physical-1) {
                findings += try PageInspection.currentPage(book,index:physical-1,image:book.pageImage(at:physical-1))
            }
            try FileHandle.standardOutput.write(contentsOf:JSONEncoder().encode(findings)); print("")
        } else {
            guard args.count > 3 else { throw ReaderFailure("缺少修改列表。") }
            let changes = try JSONDecoder().decode([PageCorrection].self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
            let plan = try PageCorrectionPlan(book:book,changes:changes)
            if args[1] == "--correct-pages" { _ = try book.correctPages(changes,backup:args.contains("--backup"),preserveDates:!args.contains("--update-dates")) }
            try emit(["renames":plan.renames,"saved":args[1] == "--correct-pages"])
        }; exit(0)
    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if args.count >= 3, args[1] == "--ocr-metadata" || args[1] == "--extract-metadata" {
    do {
        if args[1] == "--extract-metadata" { let analysis = BibliographicExtraction.analyse(try String(contentsOfFile:args[2],encoding:.utf8)); try emit(["metadata":analysis.values,"evidence":try JSONSerialization.jsonObject(with:JSONEncoder().encode(analysis.evidence)),"notes":analysis.notes]) }
        else {
            let book = try BookArchive(url: URL(fileURLWithPath: args[2]))
            let result = try CopyrightMetadata.recognize(book: book, currentPage: args.count > 3 ? (Int(args[3]) ?? 1) - 1 : nil)
            try emit(["metadata": result.values, "filled": BookMetadata.filling(book.metadata, with: result.values), "text": result.text, "pages": result.pages,"evidence":try JSONSerialization.jsonObject(with:JSONEncoder().encode(result.evidence)),"notes":result.notes])
        }
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if args.count == 4, args[1] == "--decode-page" {
    do { try PageDecoder.decodedData(Data(contentsOf: URL(fileURLWithPath: args[2]))).write(to: URL(fileURLWithPath: args[3])); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if args.count == 5, args[1] == "--render-page" {
    do {
        let book = try BookArchive(url: URL(fileURLWithPath: args[2]))
        let image = try book.pageImage(at: (Int(args[3]) ?? 1) - 1)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ReaderFailure("PNG 输出失败。") }
        try png.write(to: URL(fileURLWithPath: args[4])); exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if args.count == 5, args[1] == "--resolve-page" {
    do {
        let book = try BookArchive(url:URL(fileURLWithPath:args[2])), group = Int(args[3]) ?? 5
        let map = PageAddressing(book), token = group == -1 ? "@" + args[4] : args[4]
        let physical = try map.resolve(token,defaultGroup:group), page = book.pages[physical - 1]
        try emit(["physical":physical,"file":page.name,"group":page.key.group,"number":page.number,"token":map.token(physical),"range":map.range(in:page.key.group)]); exit(0)
    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if args.count == 3, args[1] == "--export-contents-text" {
    do {
        let book = try BookArchive(url: URL(fileURLWithPath: args[2]))
        let text = ContentsTextCodec.text(BookEditDraft(book: book).chapters, book: book)
        FileHandle.standardOutput.write(Data(text.utf8)); exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if args.count >= 4, args[1] == "--parse-contents-text" {
    do {
        let book = try BookArchive(url: URL(fileURLWithPath: args[2]))
        let text = try String(contentsOfFile: args[3], encoding: .utf8), base = args.count > 4 ? Int(args[4]) ?? 1 : 1
        let chapters = try ContentsTextCodec.chapters(text, book: book, base: base, defaultGroup: args.count > 5 ? Int(args[5]) ?? 5 : 5, allowUnresolved: args.contains("--draft"))
        var draft = BookEditDraft(book: book); draft.chapters = chapters
        if !args.contains("--draft") { _ = try draft.validated(for: book) }
        try emit(["unresolvedTargets":chapters.map { $0.unresolvedTarget as Any? ?? NSNull() }, "chapters": chapters.map { ["title": $0.title, "page": $0.page, "level": $0.level] }, "metadata": book.metadata,
                  "text": ContentsTextCodec.text(chapters, book: book, base: base), "split": ContentsTextCodec.splitTrailingNumbers(text)])
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if args.count >= 8, args[1] == "--ocr-region" {
    do {
        let book = try BookArchive(url: URL(fileURLWithPath: args[2])), page = (Int(args[3]) ?? 1)-1
        guard (0..<book.pages.count).contains(page), let x=Double(args[4]),let y=Double(args[5]),let width=Double(args[6]),let height=Double(args[7]) else { throw ReaderFailure("框选参数无效。") }
        let image = try book.pageImage(at: page), cropped = try RegionGeometry.crop(image,rect: CGRect(x: x,y: y,width: width,height: height))
        let text = try ContentsRegionRecognizer.recognize(cropped)
        try emit(["text":text,"contentsText":ContentsOCRText.prepare(text),"width":cropped.width,"height":cropped.height]); exit(0)
    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if args.count == 2, args[1] == "--region-model-tests" {
    var checks: [String] = []
    func check(_ value: Bool,_ title: String) throws { guard value else { throw ReaderFailure(title) }; checks.append(title) }
    do {
        let image = CGRect(x: 50,y: 30,width: 800,height: 1000)
        let rect = RegionGeometry.normalized(CGPoint(x: 250,y: 430),CGPoint(x: 650,y: 830),in: image)
        try check(rect == CGRect(x: 0.25,y: 0.4,width: 0.5,height: 0.4),"视图框选换算为从页面左上角开始的归一化坐标")
        try check(RegionGeometry.normalized(CGPoint(x: 650,y: 830),CGPoint(x: 250,y: 430),in: image)==rect,"反方向拖动得到相同识别范围")
        try check(RegionGeometry.normalized(CGPoint(x: 40,y: 10),CGPoint(x: 950,y: 1200),in: image)==CGRect(x: 0,y: 0,width: 1,height: 1),"超出图像的拖动裁在图像边界")
        try check(try RegionGeometry.pixels(rect!,width: 1600,height: 2000)==CGRect(x: 400,y: 800,width: 800,height: 800),"缩放视图范围映射到原图像素，不识别区域外内容")
        do { _ = try RegionGeometry.pixels(CGRect(x: 0,y: 0,width: 0.001,height: 0.001),width: 100,height: 100); throw ReaderFailure("tiny accepted") } catch let error as ReaderFailure where error.message != "tiny accepted" { checks.append("极小或无效范围拒绝识别") }
        try check(ContentsOCRText.prepare("第一章……12\n第二章 . . . 25\n第三章   36\n第四章 /74")=="第一章\t12\n第二章\t25\n第三章\t36\n第四章\t74","目录点线及空格页码分离，不推测目录层级")
        try check(ContentsOCRText.prepare("\t子项\t@15\n分组标题")=="\t子项\t@15\n分组标题","已有TAB、无跳转分组与物理页定位保持")
        let old = "已有目录\t1\n结尾目录\t2"
        let (value,range) = ContentsOCRText.inserting("识别目录\t3",into: old,at: 0)
        try check((old as NSString).replacingCharacters(in: range,with: value)=="识别目录\t3\n"+old,"识别结果插在光标所在行前，不覆盖选区或旧目录")
        let (tail,end) = ContentsOCRText.inserting("识别目录\t3",into: old,at: (old as NSString).length)
        try check((old as NSString).replacingCharacters(in: end,with: tail)==old+"\n识别目录\t3","识别结果追加到末尾时保留原目录且正确分行")
        let (middle,location) = ContentsOCRText.inserting("新项\t3",into: old,at: 2)
        try check((old as NSString).replacingCharacters(in: location,with: middle)=="已有目录\t1\n新项\t3\n结尾目录\t2","光标在行内时插在该行之后，不切断已有标题")
        let fragments = [ContentsRegionRecognizer.Line(text: "12",box: CGRect(x: 0.9,y: 0.8,width: 0.04,height: 0.03)),.init(text: "第一章",box: CGRect(x: 0.05,y: 0.8,width: 0.4,height: 0.04)),.init(text: "25",box: CGRect(x: 0.9,y: 0.6,width: 0.04,height: 0.03)),.init(text: "第二章",box: CGRect(x: 0.05,y: 0.6,width: 0.4,height: 0.04))]
        try check(ContentsRegionRecognizer.assemble(fragments)=="第一章\t12\n第二章\t25","同一行单独识别的右侧页码与标题拼接，不混合相邻行")
        try emit(["passed": checks.count,"checks": checks]); exit(0)
    } catch { fputs("REGION_MODEL_FAILED \(error.localizedDescription)\n",stderr); exit(1) }
}
if args.count == 2, args[1] == "--editing-model-tests" {
    var checks: [String] = []
    func check(_ condition: Bool, _ text: String) throws { guard condition else { throw ReaderFailure(text) }; checks.append(text) }
    do {
        try check(BookMetadata.date("2026年3月") == "2026.03" && BookMetadata.date("2026-12") == "2026.12" && BookMetadata.date("2026.03.01") == "2026.03", "出版年月规范化，丢弃日而非月份")
        try check(BookMetadata.date("2026") == "2026" && BookMetadata.date("2026.13") == "2026.13", "只有年份不猜月份，非法月份不自动修正")
        let values = ["书名": "示例书", "作者": "甲", "出版社": "出版社", "出版日期": "2026.03", "SS号": "12345678", "丛书名": "研究丛书"]
        try check(try FilenameTemplate.render(FilenameTemplate.presets[0], metadata: values) == "示例书_甲_出版社_2026.03_12345678", "常用命名格式保留出版月份")
        try check(try FilenameTemplate.render("【{丛书名}】{书名}（{年份}）_{ISBN}_{SS号}", metadata: values) == "【研究丛书】示例书（2026）_12345678", "自定义字段顺序、固定文字、兼容年份和空字段处理")
        try check(try FilenameTemplate.render("【{丛书名}】{书名}_{SS号}", metadata: ["书名": "含/斜:线"]) == "含－斜－线", "缺失丛书省略空括号、字段非法字符清理")
        for format in ["{未知}", "{书名", "../{书名}"] {
            do { _ = try FilenameTemplate.render(format, metadata: values); throw ReaderFailure("错误模板被接受") } catch let e as ReaderFailure where e.message != "错误模板被接受" { checks.append("非法命名格式拒绝：" + format) }
        }
        let text = "图书在版编目(CIP)数据\n示例书 / 张三著. — 北京 : 示例出版社, 2026.3\n(学术研究丛书)\nISBN 978-0-306-40615-7\n2026年3月第1版\n268页\nSS号: 12345678\nDXID: 000123456789\n内容提要: 这是一段摘要"
        let extracted = CopyrightMetadata.extract(text)
        try check(extracted["书名"] == "示例书" && extracted["作者"] == "张三著", "版权页CIP书名与作者提取")
        try check(extracted["出版日期"] == "2026.03" && extracted["出版社"] == "示例出版社" && extracted["丛书名"] == "学术研究丛书", "版权页出版年月、出版社和丛书提取")
        try check(extracted["页数"] == "268" && extracted["SS号"] == "12345678" && extracted["DX号"] == "000123456789" && extracted["摘要"] == "这是一段摘要", "版权页页数、编号和摘要提取")
        try check(CopyrightMetadata.validISBN("9780306406157") && !CopyrightMetadata.validISBN("9780306406158") && CopyrightMetadata.validISBN("0306406152"), "ISBN十位和十三位校验，拒绝误识别校验码")
        let filled = BookMetadata.filling(["书名": "已有标题", "作者": " ", "自定义": "保留"], with: extracted)
        try check(filled["书名"] == "已有标题" && filled["作者"] == "张三著" && filled["自定义"] == "保留", "识别只补空缺，不覆盖已有元数据和自定义字段")
        func chapter(_ title: String, _ level: Int) -> BookEditDraft.Chapter { .init(title: title, page: 1, level: level) }
        let tree = [chapter("A", 0), chapter("A1", 1), chapter("B", 0), chapter("B1", 1), chapter("C", 0), chapter("D", 0)]
        let lowered = try ContentsOperations.apply(.indent, chapters: tree, selected: IndexSet([2, 4]))
        try check(lowered.chapters.map(\.level) == [0,1,1,2,1,0] && lowered.selection == IndexSet([2,4]), "多选降级保留各自子树及选区")
        let raised = try ContentsOperations.apply(.outdent, chapters: lowered.chapters, selected: lowered.selection)
        try check(raised.chapters.map(\.title) == tree.map(\.title) && raised.chapters.map(\.level) == tree.map(\.level), "多选升级保留其他兄弟的父级且顺序稳定")
        let both = try ContentsOperations.apply(.indent, chapters: tree, selected: IndexSet([2,3]))
        try check(both.chapters.map(\.level) == [0,1,1,2,0,0], "父子同时选择时只移动一次")
        let moved = try ContentsOperations.apply(.up, chapters: tree, selected: IndexSet([2,4]))
        try check(moved.chapters.map(\.title) == ["B","B1","C","A","A1","D"], "连续多项上移时子树完整并保持选中顺序")
        let back = try ContentsOperations.apply(.down, chapters: moved.chapters, selected: moved.selection)
        try check(back.chapters.map(\.title) == tree.map(\.title), "多项下移恢复原顺序")
        let deleted = try ContentsOperations.apply(.delete, chapters: tree, selected: IndexSet([0,1,4]))
        try check(deleted.chapters.map(\.title) == ["B","B1","D"], "删除多项及后代，重叠选择不重复删除")
        do { _ = try ContentsOperations.apply(.indent, chapters: tree, selected: IndexSet([0,2])); throw ReaderFailure("首项降级被接受") } catch let error as ReaderFailure where error.message != "首项降级被接受" { checks.append("包含同级首项的无效批量调整整批拒绝") }
        let suite = "UVZReaderLab.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        try check(!settings.backups && settings.restoreSession && settings.rememberPosition && settings.metadataOCR, "设置初始值：备份关闭，恢复和版权页补齐开启")
        settings.set(true, "backups"); settings.set(3, "displayMode"); settings.set(true, "rightToLeft"); settings.set(false, "coverAlone")
        try check(settings.backups && settings.readingState.doublePages && settings.readingState.continuous && settings.readingState.rightToLeft && !settings.readingState.coverAlone, "设置持久化并驱动新书阅读默认值")
        try emit(["passed": checks.count, "checks": checks]); exit(0)
    } catch { fputs("EDITING_MODEL_FAILED \(error.localizedDescription)\n", stderr); exit(1) }
}
if args.count == 2, args[1] == "--model-tests" {
    func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        if !condition() { fputs("MODEL_TEST_FAILED \(description)\n", stderr); exit(1) }
    }
    var options = ReadingState(); options.fit = 1; options.page = 0; options.doublePages = true; options.coverAlone = false
    let sizes = Array(repeating: CGSize(width: 1000, height: 1500), count: 12), viewport = CGSize(width: 800, height: 600)
    let spread = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(spread.frames.count == 2 && spread.frames[0]!.minX < spread.frames[1]!.minX, "双页并排")
    options.fit = 0
    let fitted = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(fitted.size.width <= viewport.width + 0.001, "双页适宽不产生额外横向滚动")
    options.fit = 1
    options.rightToLeft = true
    let rtl = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(rtl.frames[0]!.minX > rtl.frames[1]!.minX, "右至左页序")
    options.continuous = true; options.doublePages = false; options.fit = 0
    let continuous = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(continuous.frames.count == 12 && continuous.frames[0]!.maxY < continuous.frames[1]!.minY, "连续模式页面不重叠")
    let y = continuous.frames[5]!.minY + continuous.frames[5]!.height * 0.4
    check(continuous.page(at: y) == 5 && abs(continuous.fraction(page: 5, y: y) - 0.4) < 0.001, "连续页定位与页内进度")
    let saved = try! JSONEncoder().encode(options)
    let restored = try! JSONDecoder().decode(ReadingState.self, from: saved)
    check(restored.continuous && restored.rightToLeft && restored.page == 0, "阅读选项恢复")
    let legacy = try! JSONDecoder().decode(ReadingState.self, from: Data("{\"page\":14,\"rotation\":1,\"crop\":0.05,\"bookmarks\":[4]}".utf8))
    check(legacy.page == 14 && legacy.rotation == 1 && !legacy.continuous, "旧版状态迁移，不沿用收藏式书签")
    let context = CGContext(data: nil, width: 100, height: 200, bitsPerComponent: 8, bytesPerRow: 400,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
    let white = context.makeImage()!
    let rotated = try! PageImageFactory.prepare(white, rotation: 1, crop: 0, invert: false)
    check(rotated.width == 200 && rotated.height == 100, "旋转后的像素尺寸")
    let cropped = try! PageImageFactory.prepare(white, rotation: 1, crop: 0.1, invert: false)
    check(cropped.width == 160 && cropped.height == 80, "裁边和旋转组合")
    let inverted = try! PageImageFactory.prepare(white, rotation: 0, crop: 0, invert: true)
    context.draw(inverted, in: CGRect(x: 0, y: 0, width: 100, height: 200))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    check(Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2]) <= 3, "白色页面反色成为黑色")
    options = ReadingState(); options.doublePages = true; options.coverAlone = true; options.fit = 0
    var covered = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(Set(covered.frames.keys) == [0], "封面独立单页")
    check(ReadingLayout.destination(from: 0, direction: 1, count: 12, state: options) == 1, "封面前进一页进入首组")
    check(ReadingLayout.destination(from: 1, direction: -1, count: 12, state: options) == 0, "首组返回封面")
    options.page = 2
    covered = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(Set(covered.frames.keys) == [1, 2], "任意跳转仍保持稳定配对")
    check(ReadingLayout.destination(from: 2, direction: 1, count: 12, state: options) == 3, "组内页前进不跳漏")
    options.rightToLeft = true
    covered = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(covered.frames[1]!.minX > covered.frames[2]!.minX, "封面选项与右至左配套")
    options.continuous = true
    covered = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(covered.frames.count == 12 && covered.frames[1]!.minY == covered.frames[2]!.minY && covered.frames[0]!.maxY < covered.frames[1]!.minY, "双页连续保持封面单页")
    check(covered.page(at: covered.frames[1]!.minY) == 1, "双页连续以逻辑首项定位")
    check(covered.size.width <= viewport.width + 0.001, "双页连续适宽")
    options.page = 11; options.continuous = false
    covered = ReadingLayout.make(sizes: sizes, viewport: viewport, state: options)
    check(Set(covered.frames.keys) == [11] && ReadingLayout.destination(from: 11, direction: 1, count: 12, state: options) == 11, "末页单页且不越界")
    let migrated = try! JSONDecoder().decode(ReadingState.self, from: Data("{\"page\":1}".utf8))
    check(migrated.coverAlone && migrated.wheelTurnsPages, "旧状态迁移到首页单独与滚轮设置")
    let current = try! JSONDecoder().decode(ReadingState.self, from: JSONEncoder().encode(options))
    check(current.coverAlone && current.doublePages && current.rightToLeft, "配套选项保存恢复")
    options.coverAlone = false; options.page = 11
    check(ReadingLayout.destination(from: 11, direction: 1, count: 12, state: options) == 11, "配对末页继续前进不回跳")
    check(ReadingLayout.spread(containing: 11, count: 12, state: options) == [10, 11], "关闭首页独立时偶数组稳定")
    try! emit(["passed": 24]); exit(0)
}
if args.count >= 3, args[1] == "--inspect" || args[1] == "--verify" || args[1] == "--sample-verify" {
    do {
        let book = try BookArchive(url: URL(fileURLWithPath: args[2]))
        var report: [String: Any] = ["title": book.title, "metadata": book.metadata, "filenameSuggestion": FilenameDraft(book: book).name(style: 0),
            "pageCount": book.pages.count, "hasElectronicContents": book.hasElectronicContents,
            "chapters": book.chapters.map { ["title": $0.title, "page": $0.pageIndex + 1, "level": $0.level] },
            "contentsNotice": book.contentsNotice as Any? ?? NSNull(),
            "fallbackNavigation": navigationNodes(for: book, includePages: false).map(\.title),
            "pages": book.pages.enumerated().map { ["index": $0.offset + 1, "file": $0.element.name, "group": $0.element.key.group, "number": $0.element.number] }]
        if args[1] == "--verify" || args[1] == "--sample-verify" {
            let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            var passed = 0, failures: [[String: Any]] = []
            let indices: [Int]
            if args[1] == "--sample-verify" {
                indices = Array(Set((0..<min(12, book.pages.count)).map { $0 * (book.pages.count - 1) / max(1, min(12, book.pages.count) - 1) })).sorted()
            } else { indices = Array(book.pages.indices) }
            report["checkedIndices"] = indices.map { $0 + 1 }
            for i in indices {
                autoreleasepool {
                    do {
                        let image = try book.pageImage(at: i)
                        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
                        passed += 1
                    } catch { failures.append(["index": i + 1, "file": book.pages[i].name, "error": error.localizedDescription]) }
                }
            }
            report["renderedPages"] = passed
            report["failures"] = failures
            try emit(report)
            exit(failures.isEmpty ? 0 : 1)
        }
        try emit(report)
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
if args.count >= 4, args[1] == "--smoke-test" || args[1] == "--editor-ui-test" || args[1] == "--metadata-ui-test" || args[1] == "--region-ui-test" || args[1] == "--paging-ui-test" || args[1] == "--repair-ui-test" {
    delegate.repairTest = args[1] == "--repair-ui-test"
    delegate.pagingTest = args[1] == "--paging-ui-test"
    delegate.editorTest = args[1] == "--editor-ui-test"
    delegate.metadataTest = args[1] == "--metadata-ui-test"
    delegate.regionTest = args[1] == "--region-ui-test"
    delegate.initialURL = URL(fileURLWithPath: args[2])
    delegate.smokeOutput = URL(fileURLWithPath: args[3])
} else if args.count == 4,args[1] == "--batch-ui-test" {
    delegate.batchTest = true; delegate.batchFolderURL = URL(fileURLWithPath:args[2]); delegate.smokeOutput = URL(fileURLWithPath:args[3])
} else if args.count == 3,args[1] == "--identity-ui-test" {
    delegate.identityTest = true; delegate.smokeOutput = URL(fileURLWithPath:args[2])
} else if args.count >= 2, !args[1].hasPrefix("-") {
    delegate.initialURL = URL(fileURLWithPath: args[1])
}
app.setActivationPolicy(delegate.smokeOutput == nil || delegate.identityTest ? .regular : .accessory)
AppIdentity.installIcon()
app.delegate = delegate
app.run()
