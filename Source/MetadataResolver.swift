import Foundation

struct MetadataSelection {
    var values: [String:String]
    var explanations: [String:String]
    var uncertain: Set<String>
}
/// Select evidence by explicit bibliography and agreement, never by how much text OCR returned.
enum MetadataResolver {
    static let storedSources: Set<String> = ["BookInfo.dat","文档信息","当前信息"]
    static func credible(_ e: NamingEvidence) -> Bool { !e.inferred && ["CIP著录","出版信息","书名页","封面"].contains(e.source) }
    static func usable(_ key: String,_ value: String) -> Bool {
        let value = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.count<=2000 else { return false }
        if key == "ISBN" { return CopyrightMetadata.validISBN(value.filter {$0.isNumber || $0 == "X" || $0 == "x"}.uppercased()) }
        if key == "出版日期" { return BookMetadata.date(value).range(of:"^[12][0-9]{3}(?:\\.(?:0[1-9]|1[0-2]))?$",options:.regularExpression) != nil }
        if key == "SS号" { return value.range(of:"^[0-9]{8}$",options:.regularExpression) != nil }
        if key == "DX号" { return value.range(of:"^[0-9]{6,20}$",options:.regularExpression) != nil }
        if key == "页数" { return value.range(of:"^[1-9][0-9]{0,5}$",options:.regularExpression) != nil }
        if key == "作者" { return value.count<=200 && !["责任编辑","责任校对","封面设计","装帧设计","版式设计","印刷厂"].contains(where:{value.contains($0)}) }
        return true
    }
    static func weight(_ e: NamingEvidence) -> Double {
        if e.inferred { return e.source == "文件名" ? 0.6 : 0.7 }
        switch e.source { case "CIP著录": return 5; case "出版信息": return 4.5; case "书名页": return 3.5; case "封面": return 2.5; default:return 2 }
    }
    static func select(original: [String:String],evidence: [NamingEvidence],locked: Set<String> = []) -> MetadataSelection {
        var values = BookMetadata.canonical(original), explanations: [String:String] = [:], uncertain = Set<String>()
        for key in BookMetadata.fields {
            let old = values[key,default:""].trimmingCharacters(in:.whitespacesAndNewlines)
            if locked.contains(key) { explanations[key] = "保留手工修改"; continue }
            var entries = evidence.filter { $0.field == key && usable(key,$0.value) }
            if !old.isEmpty,usable(key,old),!entries.contains(where:{BatchNaming.equivalent(key,$0.value,old)}) { entries.append(NamingEvidence(field:key,value:old,source:"当前信息",page:nil,inferred:false)) }
            var groups: [[NamingEvidence]] = []
            for e in entries {
                if let index = groups.firstIndex(where:{BatchNaming.equivalent(key,$0[0].value,e.value)}) { groups[index].append(e) } else { groups.append([e]) }
            }
            func distinct(_ group: [NamingEvidence]) -> [NamingEvidence] {
                var seen = Set<String>()
                return group.sorted { weight($0)>weight($1) }.filter { seen.insert($0.source+":"+($0.page.map(String.init) ?? "")).inserted }
            }
            func score(_ group: [NamingEvidence]) -> Double { distinct(group).reduce(0) {$0+weight($1)} }
            groups.sort { let a = score($0),b = score($1); return a != b ? a>b : $0[0].value<$1[0].value }
            guard let best = groups.first else { if !old.isEmpty { uncertain.insert(key); explanations[key] = "原值格式待核对" }; continue }
            let support = distinct(best), explicit = support.filter(credible), originalGroup = groups.first { $0.contains { BatchNaming.equivalent(key,$0.value,old) } }
            let trustedOriginal = entries.contains { $0.field == key && storedSources.contains($0.source) && BatchNaming.equivalent(key,$0.value,old) }
            let alternativeCredible = groups.dropFirst().contains { $0.contains(where:credible) }
            var preferred = best.sorted { a,b in
                if key == "出版日期",a.value.count != b.value.count { return a.value.count>b.value.count }
                return weight(a)>weight(b)
            }[0].value
            if key == "出版日期" { preferred = BookMetadata.date(preferred) }
            let agrees = !old.isEmpty && BatchNaming.equivalent(key,old,preferred)
            let originalScore = originalGroup.map(score) ?? 0
            let canReplace = old.isEmpty || !usable(key,old) || agrees || (!explicit.isEmpty && (!trustedOriginal || (explicit.count>=2 && score(best)>=originalScore+3)))
            if canReplace {
                // Keep existing spelling and author-role style when equivalent; enrich a year with a known month.
                if agrees && !(key == "出版日期" && old.count == 4 && preferred.count == 7) { preferred = old }
                values[key] = preferred
                let sourceNames = Array(Set(explicit.map(\.source))).sorted().joined(separator:"、")
                explanations[key] = preferred == old ? (sourceNames.isEmpty ? "保留原有信息" : "与"+sourceNames+"一致") : (sourceNames.isEmpty ? "版面推测，需核对" : "采用"+sourceNames+(explicit.count>=2 ? "的共同结果" : "的明确著录"))
                if explicit.isEmpty && support.allSatisfy(\.inferred) { uncertain.insert(key) }
                if alternativeCredible { uncertain.insert(key); explanations[key]! += "；仍有不同著录" }
            } else { uncertain.insert(key); explanations[key] = "证据不足以替换原值，请核对来源" }
        }
        let normalized = TitleNormalization.apply(values,locked:locked)
        values = normalized.values
        for (key,reason) in normalized.reasons { explanations[key] = (explanations[key].map {$0+"；"} ?? "")+reason }
        if normalized.ambiguous { uncertain.insert("书名"); explanations["书名"] = (explanations["书名"] ?? "")+"；书名空格可能分隔合订作品或并列短语，保留待核对" }
        return MetadataSelection(values:values,explanations:explanations,uncertain:uncertain)
    }
}
