# UVZ阅读器 0.3.0 解码机制与本项目扩展

## 1. 检查基线

2026-10-26检查用户已安装的阿虚UVZ阅读器0.3.0（build30）：应用包的许可文件明确写明解码核心改编自100apps/pdg_decoder，固定提交aa6f00258534e537f1be06223fb4aee2772e3546，且“No Windows binaries are included”。主程序为原生Mach-O；可见pdg_decode/pdg_free入口、TIFF、JPEG、JPEG2000和DjVu解码实现。应用包没有Windows DLL，也没有公开Swift/C++源码。不能将其表述为直接内置老马的Windows解码器。

上游：https://github.com/100apps/pdg_decoder/tree/aa6f00258534e537f1be06223fb4aee2772e3546 。上游README说明Python实现来自对DLL机制的研究，仍有兼容范围限制。本项目早期已使用同一提交的部分算法；本次是扩展已有原生实现，没有复制参考应用的机器码、界面或资源。

## 2. 实现路径

1. 保留原有00H—05H、11H—1CH与未加密文本PDG路径。
2. 新增V1的56字节头、尺寸字段及0/4/5预处理；拒绝不支持的旧版文本页。
3. 新增10H尺寸归一化、28H、AAH/ABH/ACH、56/57字节预处理。系列A算法依据上述MIT许可Python实现重新翻译为C++，使用固定宽度无符号计算和原有尺寸/操作限额。
4. 解码后的内嵌DjVu保留DjVu字节，图像通过既有独立DjVuLibre工具以原始像素尺寸读取。JPEG2000交给系统ImageIO。无需附带参考应用的libtiff/OpenJPEG/libjpeg，也无需安装Windows。
5. 主阅读器、转换和Quick Look共用PageDecoder。两个Quick Look扩展各自附带ddjvu，以便独立运行；相应GPL源码、许可证和构建方式继续随包提供。

## 3. 格式常量的来源与复核

PDGSeriesTables.h仅包含算法所需的数值表，没有DLL代码。PDGSeries.h是上游Python的原生翻译，保留100apps的MIT许可。上游Python的_load_pdgthumb_tables按PE节映射从其仓库提供的PdgThumbViewer_Ext_x64.dll读取以下互操作常量：

| RVA | 长度 | 用途 |
| --- | ---: | --- |
| 0x00C28F50 | 8 | 主种子字 |
| 0x00C28F60 | 16 | 轮次旋转表 |
| 0x00C28F70 | 2048 | 密钥置换表 |
| 0x00C286CF | 2052 | 替换/置换常量 |

该上游DLL SHA-256为78c5762dccdc339c3e72c656191869c57026e596a6ccdbef7e422c37bb1bbabc。本项目不分发或加载它，也不将上游的MIT许可扩张为对老马全部Windows软件的授权。独立读取PE常量的可复核脚本为scripts/extract-pdg-series-tables.py；需要自行提供对应上游文件，脚本核对哈希后才读取固定范围。

## 4. 验证与边界

Tests/test_decoder_extended.py生成小型图像及编码容器，验证V1三种预处理、AA/AB/AC及公共预处理、10H尺寸、28H、JP2和原始J2K、异常输入拒绝，以及ZIP阅读与PDF转换。系列A编码夹具使用固定上游Python函数形成独立参考。32个上游真实PDG样本另作本地验证，解包成功；其中JPEG/DjVu负载与上游处理结果逐字节一致。真实扫描样本不随源码或发行包发布。

这些证据不代表与原版解码器完全等价。28H和V1主要由生成夹具覆盖；复杂TIFF/JPEG2000仍受系统ImageIO支持范围约束；6xH、损坏/过期页、部分分层或文本编码不在兼容承诺内。没有加入设备绑定、密码或许可绕过。
