import Foundation

@main struct SnapshotChecks {
    static func main() throws {
        let zip = URL(fileURLWithPath:CommandLine.arguments[1]), folder = URL(fileURLWithPath:CommandLine.arguments[2])
        let source = try BookArchive(url:zip), old = try Data(contentsOf:zip)
        let changed = old + Data([0x00]); try changed.write(to:zip)
        do { _ = try source.correctPages([PageCorrection(page:1,group:5,number:441)]); throw ReaderFailure("stale archive accepted") }
        catch let error as ReaderFailure where !error.message.contains("stale archive accepted") {}
        guard try Data(contentsOf:zip) == changed else { throw ReaderFailure("external archive change overwritten") }
        let loose = try BookArchive(url:folder), info = folder.appendingPathComponent("BookInfo.dat")
        let external = Data("书名=外部编辑".utf8); try external.write(to:info)
        do { _ = try loose.correctPages([PageCorrection(page:1,group:5,number:441)]); throw ReaderFailure("stale info accepted") }
        catch let error as ReaderFailure where !error.message.contains("stale info accepted") {}
        guard try Data(contentsOf:info) == external else { throw ReaderFailure("external info overwritten") }
        print("{\"passed\":2,\"checks\":[\"旧快照发现外部ZIP修改，拒绝覆盖\",\"PDG文件夹信息被外部修改，拒绝覆盖\"]}")
    }
}
