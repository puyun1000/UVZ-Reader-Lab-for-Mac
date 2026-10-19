# UVZ Reader Lab

参考互联网上多个APP而开发的MacOS 电子书阅读和管理器，当前版本 **0.11.0（2026-10-18）**。

支持 UVZ/ZIP、PDF、DjVu、TIFF 和部分 PDG；提供目录编辑、本机 OCR、书籍信息核对、CIP 提取、批量命名建议，以及 UVZ 的 Quick Look 封面预览。批量命名需人工确认。复杂扫描页仍需核对识别结果。

## 项目缘起与致谢

**阿虚开发的 macOS「UVZ阅读器」是本项目开发的基础和首要参考。** 感谢阿虚制作并持续更新这款应用；UVZ Reader Lab 从它的阅读体验与功能出发，按本项目的需求独立实现。据项目维护者反馈，阿虚的应用已更新至 0.2.1；本项目早期研究记录对应较早的 0.1.9 版，尚未对 0.2.1 做逐项兼容性验证。由于未找到可核实的作者发布页面，这里暂不附下载链接。

也感谢**老马（马健）**开发的 Windows 工具：[UnicornViewer、PdgCntEditor、PdgRenamer、PdgThumbViewer](https://www.cnblogs.com/stronghorse/) 等。它们的作者说明帮助本项目理解 PDG 页面分类、目录编辑与阅读导航；具体参考范围见[设计参考记录](ReferenceDesign.md)。本项目没有打包阿虚或老马的应用程序、代码及界面资源。实际改编或随包使用的第三方代码和工具另见[第三方声明](ThirdPartyNotices.txt)。

## 系统要求与安装

- Apple Silicon（arm64），macOS 14 或更新版本；未覆盖所有系统版本实机测试。
- 在本仓库 Releases 下载对应版本的 DMG，打开后将 `UVZ Reader Lab.app` 复制到“应用程序”。
- 当前成品使用 ad-hoc 签名，未完成 Apple 公证；macOS 可能阻止首次打开，可在确认下载来源后使用系统“隐私与安全性”中的允许打开操作。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools（`xcode-select --install`）、macOS SDK、系统 zsh、make 和 C/C++/Swift 编译器。

```sh
/bin/zsh build.sh
```

脚本从仓库附带的 DjVuLibre 3.5.30 源码构建辅助工具，再编译 Swift/AppKit 阅读器及两个 Quick Look 扩展，输出 `UVZ Reader Lab.app` 与 `UVZ Reader Lab.zip`。应用本身不需要 Python。构建脚本在生成目录中写入产物，不应在未备份的发行目录上运行。

功能检查另需 Python 3、Pillow 与 pypdf，可在独立虚拟环境中执行：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-test.txt
.venv/bin/python Tests/test_archive.py
.venv/bin/python Tests/test_bibliographic.py
.venv/bin/python Tests/test_batch_naming.py
```

更多检查见 `Tests/`。Quick Look 系统检查要求扩展已安装并注册；`test_corpus.py` 要求自行提供图书目录，仓库不附私人图书。

## 说明与许可

完整操作说明见 [用户指南](Resources/UserGuide.md)，[版本说明](Resources/ReleaseNotes.md)，以及 [原始详细说明](Docs/OriginalUserGuide.md)。不支持 ZIP64、加密/分卷 ZIP、密码 PDF、EPUB 和部分历史 PDG 编码。

PDG 解码部分改编自 [100apps/pdg_decoder](https://github.com/100apps/pdg_decoder)，保留 MIT 许可。独立进程 `ddjvu`、`djvused` 来自 DjVuLibre，适用 GPL-2.0-or-later；完整对应源码、许可与构建脚本位于 `ThirdParty/DjVuLibre/`，并随应用分发。详见 [第三方声明](ThirdPartyNotices.txt)。本次归档未为其余原创代码另行指定开源许可，仓库保持私有。

归档过程仅补充文档与忽略规则，未改变应用功能。该目录未发现既有 Git 历史，首次归档建立初始提交。
