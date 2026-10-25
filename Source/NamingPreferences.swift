import Foundation

struct SavedNamingTemplate: Codable, Equatable {
    var id: String
    var name: String
    var pattern: String
}
struct NamingStyle: Equatable {
    let id: String, title: String
    let pattern: String?
}
/// Shared by single-book and batch naming. Library mutations persist immediately.
enum NamingPreferences {
    static let automatic = "automatic"
    static func library(_ defaults: UserDefaults = .standard) -> [SavedNamingTemplate] {
        if let data = defaults.data(forKey:"settings.namingTemplates"),let values = try? JSONDecoder().decode([SavedNamingTemplate].self,from:data) { return values }
        if let old = defaults.string(forKey:"settings.customTemplate"),!FilenameTemplate.presets.contains(old),!old.isEmpty {
            let values = [SavedNamingTemplate(id:UUID().uuidString,name:"已保存的自定义格式",pattern:old)]
            defaults.set(try? JSONEncoder().encode(values),forKey:"settings.namingTemplates"); return values
        }
        return []
    }
    static func styles(_ defaults: UserDefaults = .standard) -> [NamingStyle] {
        [NamingStyle(id:automatic,title:"自动（有丛书名时包含）",pattern:nil),NamingStyle(id:"plain",title:"不含丛书名",pattern:FilenameTemplate.presets[0]),NamingStyle(id:"series",title:"含丛书名",pattern:FilenameTemplate.presets[1])]+library(defaults).map { NamingStyle(id:$0.id,title:$0.name,pattern:$0.pattern) }
    }
    static func pattern(_ id: String, metadata: [String:String], defaults: UserDefaults = .standard) -> String {
        let style = styles(defaults).first { $0.id == id }
        return style?.pattern ?? FilenameTemplate.presets[metadata["丛书名",default:""].trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? 0 : 1]
    }
    static func preferred(_ defaults: UserDefaults = .standard) -> String {
        let id = defaults.string(forKey:"settings.namingStyle") ?? automatic
        return styles(defaults).contains(where:{$0.id == id}) ? id : automatic
    }
    @discardableResult static func save(id: String? = nil,name: String,pattern: String,defaults: UserDefaults = .standard) throws -> String {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=80 else { throw ReaderFailure("请填写格式名称（最多80字）。") }
        _ = try FilenameTemplate.render(pattern,metadata:Dictionary(uniqueKeysWithValues:BookMetadata.fields.map { ($0,"示例") }))
        var values = library(defaults)
        guard !values.contains(where:{$0.name == name && $0.id != id}) else { throw ReaderFailure("已有同名格式，请修改名称或选中原格式后更新。") }
        let key = id ?? UUID().uuidString,value = SavedNamingTemplate(id:key,name:name,pattern:pattern)
        if let index = values.firstIndex(where:{$0.id == key}) { values[index] = value } else { values.append(value) }
        defaults.set(try JSONEncoder().encode(values),forKey:"settings.namingTemplates")
        NotificationCenter.default.post(name:AppSettings.changed,object:"namingTemplates"); return key
    }
    static func delete(_ id: String,defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(library(defaults).filter {$0.id != id}),forKey:"settings.namingTemplates")
        if defaults.string(forKey:"settings.namingStyle") == id { defaults.removeObject(forKey:"settings.namingStyle") }
        NotificationCenter.default.post(name:AppSettings.changed,object:"namingTemplates")
    }
}
