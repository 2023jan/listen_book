# 本地听书：EPUB 在线语音与 TXT / EasyVoice

## EPUB → MP3（新增）

无需 Docker、付费 API Key 或本地语音模型。使用 Python 提取 EPUB，调用 Edge 在线语音，默认晓晓女声、语速 -15%。

- 同章片段 1～3 路并发，默认 3；按原文顺序合并。
- 哈希缓存、失败续跑、失败清单、完整 MP3 解码检查。
- 独立入口与安装说明：[epub/README.md](epub/README.md)。
- 设计对比：[epub/COMPARISON.md](epub/COMPARISON.md)。
- 验证记录：[epub/VALIDATION.md](epub/VALIDATION.md)。

以下保留原有 TXT / EasyVoice 使用说明。

## 本地 TXT 听书（EasyVoice 批量版）

这个项目用于把超长小说 TXT 切分后，批量调用本地 EasyVoice Docker 服务生成 MP3。

默认约定：
- 切分时尽量把每段调到 `20000` 字左右，减少文件数量
- 批量生成时使用长文本接口 `POST /api/v1/tts/createStream`
- 默认男声为 `zh-CN-YunjianNeural`

## 1. 切分 TXT

在项目根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\split_novel.ps1
```

可选参数示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\split_novel.ps1 `
  -InputPath ".\《凡人修仙传》.txt" `
  -OutputDir ".\output\chunks" `
  -MinChars 20000
```

推荐值：
- `20000`：默认值，文件数量和稳定性比较平衡
- `30000`：可选，进一步减少文件数量
- `50000`：不建议默认使用，失败重试成本更高

输出：
- `output/chunks/*.txt`：切分后的文本
- `output/manifest.csv`：切分清单

## 2. 启动 EasyVoice Docker

```powershell
git clone https://github.com/cosin2077/easyVoice.git
cd .\easyVoice
docker compose up -d
```

默认访问地址：
- `http://127.0.0.1:9549`

## 3. 单文件接口验证

脚本：
- `tools/easyvoice_single.ps1`

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\easyvoice_single.ps1 `
  -InputFile ".\output\chunks\0001_第1-3章_5999字.txt"
```

可选参数：
- `-OutputFile`：输出 MP3 路径，默认 `output/audio/<同名>.mp3`
- `-BaseUrl`：EasyVoice 地址，默认 `http://127.0.0.1:9549`
- `-Voice`：默认 `zh-CN-YunjianNeural`
- `-Rate`：默认 `0%`
- `-Pitch`：默认 `0Hz`
- `-Volume`：默认 `0%`

## 4. 批量生成 MP3

脚本：
- `tools/easyvoice_batch.ps1`

运行前建议先切换到 UTF-8 代码页，避免 PowerShell 控制台中文乱码：

```powershell
chcp 65001
```

默认行为：
- 输入目录：`output/chunks`
- 输出目录：`output/audio`
- 文件并发：`-FileConcurrency 3`，范围 `1..3`
- 已有输出文件时默认跳过，不会重复生成
- 运行时会显示进度条

直接执行默认批量命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\easyvoice_batch.ps1
```

分片执行命令示例。

`part1`：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\easyvoice_batch.ps1 `
  -InputDir ".\output\chunks\part1" `
  -OutputDir ".\output\audio_part1" `
  -ManifestPath ".\output\audio_manifest_part1.csv" `
  -FailuresPath ".\output\audio_failures_part1.csv" `
  -StatePath ".\output\audio_state_part1.json" `
  -FileConcurrency 3 `
  -Voice "zh-CN-YunjianNeural" `
  -Rate "0%" `
  -Pitch "0Hz" `
  -Volume "0%"
```

`part2`：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\easyvoice_batch.ps1 `
  -InputDir ".\output\chunks\part2" `
  -OutputDir ".\output\audio_part2" `
  -ManifestPath ".\output\audio_manifest_part2.csv" `
  -FailuresPath ".\output\audio_failures_part2.csv" `
  -StatePath ".\output\audio_state_part2.json" `
  -FileConcurrency 3 `
  -Voice "zh-CN-YunjianNeural" `
  -Rate "0%" `
  -Pitch "0Hz" `
  -Volume "0%"
```

`part3`：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\easyvoice_batch.ps1 `
  -InputDir ".\output\chunks\part3" `
  -OutputDir ".\output\audio_part3" `
  -ManifestPath ".\output\audio_manifest_part3.csv" `
  -FailuresPath ".\output\audio_failures_part3.csv" `
  -StatePath ".\output\audio_state_part3.json" `
  -FileConcurrency 3 `
  -Voice "zh-CN-YunjianNeural" `
  -Rate "0%" `
  -Pitch "0Hz" `
  -Volume "0%"
```

`part4`：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\easyvoice_batch.ps1 `
  -InputDir ".\output\chunks\part4" `
  -OutputDir ".\output\audio_part4" `
  -ManifestPath ".\output\audio_manifest_part4.csv" `
  -FailuresPath ".\output\audio_failures_part4.csv" `
  -StatePath ".\output\audio_state_part4.json" `
  -FileConcurrency 3 `
  -Voice "zh-CN-YunjianNeural" `
  -Rate "0%" `
  -Pitch "0Hz" `
  -Volume "0%"
```

常用参数说明：
- `-FileConcurrency`：单分片内并发数，范围 `1..3`
- `-RetryFailed`：只重跑失败项，基于对应分片的 `failures` 文件
- `-StartFrom`：从指定前缀开始继续跑，例如 `0200_`
- `-Overwrite`：即使已有输出文件也重新生成

运行过程中会写入：
- `audio_manifest_*.csv`：整体执行清单，状态包括 `success`、`failed`、`skipped`
- `audio_failures_*.csv`：失败清单
- `audio_state_*.json`：最新进度状态，包含 `running`

建议每个分片使用独立的输入、输出、清单和状态文件，例如 `part1`、`part2`、`part3`、`part4` 分开写，避免冲突。

## 5. 接口说明

- 短文本接口：`POST /api/v1/tts/generate`
  - `text` 超过 200 字会失败
- 长文本接口：`POST /api/v1/tts/createStream`
  - 返回类型为音频流，`application/octet-stream`
  - 批量脚本固定使用这个接口

## 6. 常见问题

- 中文乱码：输入 TXT 请使用 `UTF-8`
- 文件太多：优先提高 `-MinChars`，推荐先试 `20000`
- 中断后续跑：使用 `-StartFrom` 或 `-RetryFailed`
- 想调整音色：修改 `-Voice`
- 想更快：优先按分片目录运行，分片内用 `-FileConcurrency 3`
