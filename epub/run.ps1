param(
    [Parameter(Mandatory=$true)][string]$Epub,
    [string]$Sections,
    [string]$Voice = 'zh-CN-XiaoxiaoNeural',
    [string]$Rate = '-15%',
    [string]$Out = '',
    [int]$Preview = 0,
    [ValidateRange(1, 3)][int]$Concurrency = 3,
    [switch]$RetryFailed
)
$ErrorActionPreference = 'Stop'
$runtime = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $runtime)) {
    throw '请先按 README.md 安装项目独立环境。'
}
$epubPath = (Resolve-Path -LiteralPath $Epub).Path
$entry = Join-Path $PSScriptRoot 'epub_audio.py'
if (-not $Sections) {
    & $runtime $entry $epubPath --list
} else {
    if (-not $Out) { $Out = Join-Path $PSScriptRoot 'audio' }
    $extra = @()
    if ($RetryFailed) { $extra += '--retry-failed' }
    & $runtime $entry $epubPath --sections $Sections --voice $Voice "--rate=$Rate" --out $Out --preview $Preview --concurrency $Concurrency @extra
}
if ($LASTEXITCODE -ne 0) { throw '转换未完成，请查看上面的错误信息。已完成片段可续跑。' }
