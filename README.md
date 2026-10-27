# UVZ Reader Lab 0.17.0

独立实现的原生macOS扫描图书阅读与整理应用。支持UVZ／ZIP、PDG及PDG文件夹、PDF、DjVu和多页TIFF。适用于Apple芯片Mac、macOS14及以上；当前使用临时签名，未经Apple公证。

## 本版变化

- 转换工作台采用上下卡片布局，任务与完整性预览在上，输出设置在下，目标名可换行核对，缩窄窗口时上下滚动。
- 阅读工具栏直接提供宽度、高度、整页适配，以及首页单独、阅读方向和配色；所选配色可设为默认，初始使用原色。
- 统一中文右键菜单，增加常用阅读操作；所选文字可繁简、全半角、大小写和中英文标点转换，编辑可撤销，只读内容转换后复制。
- 功能说明重新分组并增加层级序号。本版源码和安装包同步至[GitHub仓库](https://github.com/puyun1000/UVZ-Reader-Lab-for-Mac)，后续发布按[发布流程](Docs/ReleaseProcess.md)同步。

阅读器保留单页／双页／连续显示、首页单独、从右至左、裁边、OCR与目录框选识别、独立目录编辑、页面编码校对、图书信息及重命名等功能。

## 安装与使用

安装到“应用程序”后打开一次，以注册Quick Look扩展。选中UVZ按空格预览，可查看后续页；更新后需要关闭旧预览窗口再打开。如系统未启用，在“系统设置 → 通用 → 登录项与扩展 → 快速查看”中选择本应用。

图书信息与命名在阅读窗口或“文件”菜单中，批量规范命名使用⇧⌘B，转换工作台使用⇧⌘K。识别和名称建议只更改草稿，保存／应用后才写文件；批量默认只改名。功能说明与更新说明统一在“帮助”中。

0.17.0修复编辑文字位置、内嵌PDF/DjVu目录、批量书目保存、可调目录栏及长行目录编辑；0.16.0修复无信息字典PDF保存及改名失败，补充旧版PDG、预处理编码、内嵌DjVu与JPEG2000页面支持。机制、来源和边界见[解码扩展说明](Docs/Decoder-0.3.0.md)。

完整使用说明见[UserGuide](Resources/UserGuide.md)，更新记录见[ReleaseNotes](Resources/ReleaseNotes.md)，书目提取结构与限制见[解析说明](Docs/BibliographicExtraction.md)，转换路径与限制见[转换说明](Docs/Conversion.md)，在线服务机制与验证见[研究记录](Docs/OnlineReferences.md)。

## 构建与验证

使用macOS自带命令行开发工具运行 `./build.sh`，输出应用包及应用ZIP；运行时无需Python或Homebrew。DjVuLibre许可与对应源码随包提供。

`Tests/`包含归档与解码、格式、目录、信息保存、页面地址、编码纠正、书目解析及批量改名测试。`--naming-model-tests`验证字段推荐和格式管理；`QuickLook/Tests/PreviewControllerTests.swift`验证多页预览控制器。发布验证结果见 `Verification.json`。

图书信息推荐依赖本机OCR和规则，不能替代人工书目核对。单一冲突来源、书法竖排、模糊扫描、多个丛书／ISBN及多卷合订仍可能无法准确分解。批量执行逐本完成，尚不提供执行后整批撤销。

## 参考与致谢

**网友阿虚开发的 macOS「UVZ阅读器」是本项目开发的基础和首要参考。** 感谢阿虚制作并持续更新这款应用；UVZ Reader Lab 从它的阅读体验与功能出发，按本项目的需求独立实现。用户于2026-10-19提供的版本记录表明，阿虚的应用已更新至 0.2.1；本项目早期研究记录对应较早的 0.1.9 版，后续持续跟进其更新进展。

也感谢网上读书园地的**stronghorse（老马）**开发的系列 Windows 工具：[UnicornViewer、PdgCntEditor、PdgRenamer、PdgThumbViewer](https://www.cnblogs.com/stronghorse/) 等。它们的作者说明帮助本项目理解 PDG 页面分类、目录编辑与阅读导航；具体参考范围见[设计参考记录](ReferenceDesign.md)。本项目没有打包阿虚或老马的应用程序、代码及界面资源。实际改编或随包使用的第三方代码和工具另见[第三方声明](ThirdPartyNotices.txt)。


转换工作台流程参考PDG2PDF for Mac；在线辅助查询参考Wenbin Fan的[读秀工具](https://wbfan.site/duxiu/)。均为独立实现，没有复制这些应用或网站的代码及图像资源。
