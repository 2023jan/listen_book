param(
    [string]$InputPath,
    [string]$OutputDir = (Join-Path $PSScriptRoot "..\output\chunks"),
    [int]$MinChars = 20000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($MinChars -le 0) {
    throw "MinChars must be greater than 0."
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Convert-ChineseNumberToInt {
    param([Parameter(Mandatory = $true)][string]$Text)

    $digits = @{
        ([char]0x3007) = 0
        ([char]0x25CB) = 0
        ([char]0x96F6) = 0
        ([char]0x4E00) = 1
        ([char]0x4E8C) = 2
        ([char]0x4E24) = 2
        ([char]0x4E09) = 3
        ([char]0x56DB) = 4
        ([char]0x4E94) = 5
        ([char]0x516D) = 6
        ([char]0x4E03) = 7
        ([char]0x516B) = 8
        ([char]0x4E5D) = 9
    }

    $unitChars = @{
        ([char]0x5341) = 10
        ([char]0x767E) = 100
        ([char]0x5343) = 1000
        ([char]0x4E07) = 10000
    }

    $chars = $Text.ToCharArray()
    if ($chars.Count -eq 0) {
        return $null
    }

    $allPlainDigits = $true
    foreach ($ch in $chars) {
        if (-not $digits.ContainsKey($ch)) {
            $allPlainDigits = $false
            break
        }
    }

    if ($allPlainDigits) {
        $plainDigits = foreach ($ch in $chars) { $digits[$ch] }
        return [int](-join $plainDigits)
    }

    $total = 0
    $section = 0
    $number = 0

    foreach ($ch in $chars) {
        if ($digits.ContainsKey($ch)) {
            $number = $digits[$ch]
            continue
        }

        if (-not $unitChars.ContainsKey($ch)) {
            return $null
        }

        $unit = $unitChars[$ch]
        if ($unit -eq 10000) {
            $section = ($section + $(if ($number -eq 0) { 1 } else { $number })) * $unit
            $total += $section
            $section = 0
            $number = 0
            continue
        }

        $section += $(if ($number -eq 0) { 1 } else { $number }) * $unit
        $number = 0
    }

    return $total + $section + $number
}

function Get-ChapterNumberFromHeader {
    param([Parameter(Mandatory = $true)][string]$Header)

    $trimmed = $Header.Trim()
    if (-not $trimmed.StartsWith('===') -or -not $trimmed.EndsWith('===')) {
        return $null
    }

    $charDi = [char]0x7B2C
    $charZhang = [char]0x7AE0
    $validNumberChars = @(
        [char]0x3007, [char]0x25CB, [char]0x96F6, [char]0x4E00, [char]0x4E8C, [char]0x4E24,
        [char]0x4E09, [char]0x56DB, [char]0x4E94, [char]0x516D, [char]0x4E03, [char]0x516B,
        [char]0x4E5D, [char]0x5341, [char]0x767E, [char]0x5343, [char]0x4E07
    )

    $inner = $trimmed.Substring(3, $trimmed.Length - 6)
    if ([string]::IsNullOrWhiteSpace($inner) -or $inner[0] -ne $charDi) {
        return $null
    }

    $numberChars = New-Object System.Collections.Generic.List[char]
    $separatorIndex = -1
    for ($i = 1; $i -lt $inner.Length; $i++) {
        $ch = $inner[$i]
        if ($ch -eq $charZhang -or [char]::IsWhiteSpace($ch)) {
            $separatorIndex = $i
            break
        }

        if (-not ($ch -match '\d') -and -not $validNumberChars.Contains($ch)) {
            return $null
        }

        $numberChars.Add($ch)
    }

    if ($numberChars.Count -eq 0 -or $separatorIndex -lt 0) {
        return $null
    }

    $titleText = $inner.Substring($separatorIndex + 1).Trim()
    if ([string]::IsNullOrWhiteSpace($titleText)) {
        return $null
    }

    $numberText = -join $numberChars
    if ($numberText -match '^\d+$') {
        return [int]$numberText
    }

    return Convert-ChineseNumberToInt -Text $numberText
}

function Get-DefaultInputPath {
    param([string]$RootPath)

    $txtFiles = Get-ChildItem -LiteralPath $RootPath -File -Filter *.txt | Sort-Object Length -Descending
    if (-not $txtFiles) {
        throw "No .txt file found in repo root: $RootPath"
    }
    return $txtFiles[0].FullName
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Get-DefaultInputPath -RootPath $repoRoot
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input file not found: $InputPath"
}

$resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
$resolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$resolvedOutputRoot = Split-Path -Parent $resolvedOutputDir
$manifestPath = Join-Path $resolvedOutputRoot "manifest.csv"

if (-not (Test-Path -LiteralPath $resolvedOutputDir)) {
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $resolvedOutputRoot)) {
    New-Item -ItemType Directory -Path $resolvedOutputRoot -Force | Out-Null
}

# Ensure deterministic output.
Get-ChildItem -LiteralPath $resolvedOutputDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

$lines = Get-Content -LiteralPath $resolvedInputPath -Encoding UTF8

# Keep only lines that can be parsed into a real chapter number.
$chapterHeaders = @()
$charDi = [char]0x7B2C
$charZhang = [char]0x7AE0
$charZi = [char]0x5B57
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i].Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt 80) {
        continue
    }

    $chapterNumber = Get-ChapterNumberFromHeader -Header $line
    if ($null -ne $chapterNumber) {
        $chapterHeaders += [PSCustomObject]@{
            LineIndex = $i
            Header = $line
            ChapterNumber = $chapterNumber
        }
    }
}

if ($chapterHeaders.Count -eq 0) {
    throw "No chapter headers found."
}

$chapters = @()
for ($j = 0; $j -lt $chapterHeaders.Count; $j++) {
    $start = $chapterHeaders[$j].LineIndex
    $end = if ($j -lt $chapterHeaders.Count - 1) { $chapterHeaders[$j + 1].LineIndex - 1 } else { $lines.Count - 1 }
    $header = $chapterHeaders[$j].Header
    $chapterNumber = $chapterHeaders[$j].ChapterNumber
    $chapterBody = if ($start + 1 -le $end) {
        ($lines[($start + 1)..$end] -join "`r`n").Trim()
    }
    else {
        ""
    }
    $charCount = (($chapterBody -replace '\s', '')).Length

    $chapters += [PSCustomObject]@{
        ChapterNumber = $chapterNumber
        Header = $header
        Body = $chapterBody
        CharCount = $charCount
    }
}

$chunks = @()
$cursor = 0
$chunkIndex = 1

while ($cursor -lt $chapters.Count) {
    $startChapter = $chapters[$cursor].ChapterNumber
    $firstHeader = $chapters[$cursor].Header
    $collected = @()
    $collectedChars = 0

    while ($cursor -lt $chapters.Count -and $collectedChars -lt $MinChars) {
        $collected += $chapters[$cursor]
        $collectedChars += $chapters[$cursor].CharCount
        $cursor++
    }

    if ($collected.Count -eq 0) {
        break
    }

    $endChapter = $collected[$collected.Count - 1].ChapterNumber
    $chunkName = "{0:D4}_{1}{2}-{3}{4}_{5}{6}.txt" -f $chunkIndex, $charDi, $startChapter, $endChapter, $charZhang, $collectedChars, $charZi
    $chunkPath = Join-Path $resolvedOutputDir $chunkName

    $parts = @()
    for ($k = 0; $k -lt $collected.Count; $k++) {
        $parts += $collected[$k].Header
        $parts += $collected[$k].Body
        if ($k -lt $collected.Count - 1) {
            $parts += ""
        }
    }
    $chunkText = $parts -join "`r`n"
    Set-Content -LiteralPath $chunkPath -Value $chunkText -Encoding UTF8

    $chunks += [PSCustomObject]@{
        chunk_index = $chunkIndex
        start_chapter = $startChapter
        end_chapter = $endChapter
        char_count = $collectedChars
        title = $firstHeader
        file_name = $chunkName
    }

    $chunkIndex++
}

$chunks | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8

[PSCustomObject]@{
    InputPath = $resolvedInputPath
    TotalChapters = $chapters.Count
    ChunksGenerated = $chunks.Count
    OutputDir = $resolvedOutputDir
    Manifest = $manifestPath
    MinChars = $MinChars
} | Format-List | Out-String | Write-Output
