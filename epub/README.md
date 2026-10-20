# EPUB 睡前听书：本地项目

在 Windows 本地提取 EPUB，调用 Edge 免费在线语音，输出可复制到 iPhone 的 MP3。不需要付费账号、API Key 或本地语音模型。正文会发送到在线语音服务；这是第三方客户端，不承诺服务永久免费或一直可用。

## 并发版更新

借鉴同仓库 `tools/easyvoice_batch.ps1` 的有界并发、状态记录和失败重试设计：

- 默认 `--concurrency 3`，允许 1～3。同一章内并发生成片段，章节依次处理，因此请求总数不会随章节数量倍增。
- 完成顺序不影响播放顺序，始终按原文的片段序号合并。
- 每个片段自动重试最多 4 次，失败片段写入 `.cache/<哈希>/state.json`；其他片段继续完成。
- 某章失败后继续处理后续章节，`failures.json` 记录失败章；存在失败时程序退出码为 1。
- `--retry-failed` 在 `--sections` 选定范围内只处理同一本 EPUB 的失败章；成功后自动移出失败清单。
- 完整音频旁的 JSON 保存正文与声音设置的缓存键及 MP3 哈希；两者匹配才跳过，不能只因同名文件存在就跳过。
- 同一输出目录有操作系统文件锁，避免两个进程同时写缓存和清单；进程退出后自动释放。
- 默认仍为晓晓女声、语速 -15%。已有正文缓存可继续复用。

```powershell
# 默认 3 路；服务不稳定时可降为 1
.\.venv\Scripts\python.exe .\epub_audio.py '你的书.epub' --sections 6,7 --concurrency 3 --out '.\audio'

# 只重试失败章，并复用这些章中已经成功的片段
.\.venv\Scripts\python.exe .\epub_audio.py '你的书.epub' --sections 6,7 --retry-failed --out '.\audio'

# PowerShell 简化入口
.\run.ps1 -Epub '你的书.epub' -Sections '6,7' -Concurrency 3
```

## 本机直接使用

在本目录打开 PowerShell。本次交付的本机目录已经安装独立 Python 环境；从 GitHub 下载的源码需要先执行下方安装步骤。FFmpeg 需要在 PATH 中。

```powershell
# 先查看章节。编号是 EPUB 阅读顺序中的文档编号，可能包含版权页、序言。
.\.venv\Scripts\python.exe .\epub_audio.py 'D:\GoogleDownLoad\万历十五年（经典版） (黄仁宇) (Z-Library).epub' --list

# 本书第一、二章对应文档 6、7。默认晓晓女声，语速 -15%。
.\.venv\Scripts\python.exe .\epub_audio.py 'D:\GoogleDownLoad\万历十五年（经典版） (黄仁宇) (Z-Library).epub' --sections 6,7 --out '..\万历十五年'

# 列出在线服务当前提供的中文音色
.\.venv\Scripts\python.exe .\epub_audio.py --voices

# 用选定音色试读前 200 字（更换为你的 EPUB 路径和文档编号）
.\.venv\Scripts\python.exe .\epub_audio.py '你的书.epub' --sections 6 --voice zh-CN-XiaoxiaoNeural --rate=-20% --preview 200 --out '.\试听'
```

更换音色时建议先生成试听，正式导出用不同的 `--out` 目录，避免覆盖之前的声音版本。

## 新电脑安装

需要 Python 3.11+、FFmpeg（包含 ffprobe，加入 PATH）和网络：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

## 输出与续跑

- 每个选定文档导出 TXT 和 MP3，report.json 记录字符数、片段数、音色和时长。
- `.cache` 保存成功片段，以正文和音色参数的哈希隔离；失败后原命令重跑即可续传。
- 每段验证音频时长，最终 MP3 用 FFmpeg 完整解码检查；失败不会替换已有最终音频。
- 默认跳过明确标识的注释、注释编号、图注。`--keep-notes` 保留它们；`--extract-only` 只导出文字。
- 不做摘要或改写，正文按原文朗读。

## 第一版边界

支持无 DRM、UTF-8 的 EPUB 2/3，按 OPF spine 的 HTML 文档划分。一个章节跨多个 HTML 时会生成多个文件；整本书只有一个 HTML 时不会自动按目录锚点切章，需要后续适配。不会把内部文档序号误当作书中章号，请先 --list 核对。本次《万历十五年》第一、二章各对应一个 HTML，已核对。

PDF、OCR、手机 APP、云端部署均不包含在第一版。音频由 AI 合成，古人姓名、多音字与特殊纪年可能需要人工试听校正。iPhone 播放和熄屏行为尚未实机验证。

在线语音项目来源：https://github.com/rany2/edge-tts

## 测试

```powershell
.\.venv\Scripts\python.exe -m unittest -v
```

自动测试不联网，通过模拟乱序响应、连接失败和产物损坏验证执行逻辑。真实在线语音测试应另行运行短试听；解码通过不等于人工校对发音。
