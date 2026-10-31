# UVZ Reader Lab 0.19.1

独立实现的原生macOS扫描图书阅读与整理应用。支持UVZ／ZIP、PDG及PDG文件夹、PDF、DjVu和多页TIFF。适用于Apple芯片Mac、macOS14及以上；当前使用临时签名，未经Apple公证。

**历史版本：[版本历史与下载](Docs/VersionHistory.md) · [每次更新记录](CHANGELOG.md) · [全部发行版](https://github.com/puyun1000/UVZ-Reader-Lab-for-Mac/releases)**。原包、仅源码和仅文字记录分别标明；历史附件长期保留。

## 本版变化

- 目录查找替换使用独立窗口，全文与选区范围明确，支持反复操作及撤销。
- 状态栏显示PDG编码和图像尺寸；右键打开单页图像窗口，导出整页或框选PNG。
- 手工修改批量书目信息后自动勾选人工核对；PDF版权页候选覆盖前10页及末尾10页。
- 发白页面增加对比度候选并择优识别，补充港台出版机构、初版及民国日期。详见[本版验证](Docs/Validation-0.19.0.md)。

阅读器保留单页／双页／连续显示、首页单独、从右至左、裁边、OCR与目录框选识别、独立目录编辑、页面编码校对、图书信息及重命名等功能。

## 安装与使用

安装到“应用程序”后打开一次，以注册Quick Look扩展。选中UVZ按空格预览，可查看后续页；更新后需要关闭旧预览窗口再打开。如系统未启用，在“系统设置 → 通用 → 登录项与扩展 → 快速查看”中选择本应用。

图书信息与命名在阅读窗口或“文件”菜单中，批量规范命名使用⇧⌘B，转换工作台使用⇧⌘K。识别和名称建议只更改草稿，保存／应用后才写文件；批量保存核对信息并改名。功能说明与更新说明统一在“帮助”中。

0.18.0修复DjVu原始像素、JPEG图层及超星照片页的行序和颜色，补齐原始DPI、EXIF方向和损坏图像校验；详见[保真说明](Docs/Raster-Fidelity-0.18.md)。0.17.1修复编辑文字位置、内嵌PDF/DjVu目录、批量书目保存、可调目录栏及长行目录编辑；0.16.0修复无信息字典PDF保存及改名失败，补充旧版PDG、预处理编码、内嵌DjVu与JPEG2000页面支持。机制、来源和边界见[解码扩展说明](Docs/Decoder-0.3.0.md)。

完整使用说明见[UserGuide](Resources/UserGuide.md)，更新记录见[ReleaseNotes](Resources/ReleaseNotes.md)，书目提取结构与限制见[解析说明](Docs/BibliographicExtraction.md)，转换路径与限制见[转换说明](Docs/Conversion.md)，在线服务机制与验证见[研究记录](Docs/OnlineReferences.md)。

## 构建与验证

使用macOS自带命令行开发工具运行 `./build.sh`，输出应用包及应用ZIP；运行时无需Python或Homebrew。DjVuLibre许可与对应源码随包提供。

`Tests/`包含归档与解码、格式、目录、信息保存、页面地址、编码纠正、书目解析及批量改名测试。`--naming-model-tests`验证字段推荐和格式管理；`QuickLook/Tests/PreviewControllerTests.swift`验证多页预览控制器。发布验证结果见[验证摘要](Docs/Validation-0.18.0.md)。

图书信息推荐依赖本机OCR和规则，不能替代人工书目核对。单一冲突来源、书法竖排、模糊扫描、多个丛书／ISBN及多卷合订仍可能无法准确分解。批量执行逐本完成，尚不提供执行后整批撤销。

## 参考与致谢

**网友阿虚开发的 macOS「UVZ阅读器」是本项目开发的基础和首要参考。** 感谢阿虚制作并持续更新这款应用；UVZ Reader Lab 从它的阅读体验与功能出发，按本项目的需求独立实现。用户于2026-10-19提供的版本记录表明，阿虚的应用已更新至 0.2.1；本项目早期研究记录对应较早的 0.1.9 版，后续持续跟进其更新进展。

也感谢网上读书园地的**stronghorse（老马）**开发的系列 Windows 工具：[UnicornViewer、Pdg2Pic、PdgCntEditor、PdgRenamer、PdgThumbViewer](https://www.cnblogs.com/stronghorse/) 等。它们的作者说明帮助本项目理解 PDG 页面分类、目录编辑与阅读导航；具体参考范围见[设计参考记录](ReferenceDesign.md)。本项目没有打包阿虚或老马的应用程序、代码及界面资源。实际改编或随包使用的第三方代码和工具另见[第三方声明](ThirdPartyNotices.txt)。


转换工作台流程参考PDG2PDF for Mac；在线辅助查询参考Wenbin Fan的[读秀工具](https://wbfan.site/duxiu/)。均为独立实现，没有复制这些应用或网站的代码及图像资源。
