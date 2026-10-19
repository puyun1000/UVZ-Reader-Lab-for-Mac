# UVZ Reader Lab 0.11.0 核查记录

验证日期：2026-10-19（Asia/Shanghai）。环境：Apple Silicon / macOS 27.2（26B5112a），Apple Swift 6.4，macOS 27.2 SDK。

- 在无 `.build` 缓存的独立副本中从附带源码构建 DjVuLibre、阅读器和两个 Quick Look 扩展，构建成功。
- 现有 DMG 完整性校验通过；只读挂载后应用通过 `codesign --verify --deep --strict`，版本为 0.11.0、构建 12、arm64、最低 macOS 14.0。
- DMG 内主程序、ddjvu、djvused、预览扩展与缩略图扩展，均与干净构建产物逐字节一致。
- 10 个现有 Python 测试脚本在 DMG 应用和干净构建上分别通过 130 项检查，覆盖压缩包完整性、PDG 解码、PDF/TIFF/DjVu、信息保存、目录、OCR、页面地址/纠正、CIP 与批量命名。
- DMG 应用另通过 57 项内置模型检查，总计 187 项功能检查。应用启动后保持运行，并由验证进程结束本次启动实例。
- 当前源码与内附 DjVuLibre 源码归档使用 Gitleaks 默认规则扫描，未发现命中；额外检查常见私钥/令牌格式、签名材料文件名、个人绝对路径。
- `.gitignore` 排除构建成品、缓存、虚拟环境、日志、密钥材料、旧 Verification.json 和可能包含个人路径/读书样本的界面预览截图。原文件均保留在原项目。

当前成品为 ad-hoc 签名，未公证。验证仅覆盖本机环境；未重新进行系统 Quick Look 扩展注册检查、全部图形界面流程、私人实书库抽样或所有最低系统版本实机检查。OCR 仍需人工核对。此记录不宣称完成穷尽的安全审计。

现有 DMG SHA-256：`ad6076361d63138cd1c060ec514acc9efd4ee4a6bbffa38acea6564a57380ec4`。
