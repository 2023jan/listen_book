param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,
    [string]$OutputFile,
    [string]$BaseUrl = "http://127.0.0.1:9549",
    [string]$Voice = "zh-CN-YunjianNeural",
    [string]$Rate = "0%",
    [string]$Pitch = "0Hz",
    [string]$Volume = "0%"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

if (-not (Test-Path -LiteralPath $InputFile)) {
    throw "Input file not found: $InputFile"
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$outputDirDefault = Join-Path $repoRoot "output\audio"
if (-not (Test-Path -LiteralPath $outputDirDefault)) {
    New-Item -ItemType Directory -Path $outputDirDefault -Force | Out-Null
}

$resolvedInput = (Resolve-Path -LiteralPath $InputFile).Path
$inputNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $outputDirDefault ($inputNameNoExt + ".mp3")
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputFile)
$resolvedOutputDir = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $resolvedOutputDir)) {
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
}

[string]$text = Get-Content -LiteralPath $resolvedInput -Encoding UTF8 -Raw
if ([string]::IsNullOrWhiteSpace($text)) {
    throw "Input text is empty: $resolvedInput"
}

$payload = @{
    text = $text
    voice = $Voice
    rate = $Rate
    pitch = $Pitch
    volume = $Volume
}

$json = $payload | ConvertTo-Json -Compress -Depth 5
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$bodyBytes = $utf8NoBom.GetBytes($json)

$apiUrl = "$BaseUrl/api/v1/tts/createStream"
$tmpOutput = $resolvedOutput + ".tmp"

if (Test-Path -LiteralPath $tmpOutput) {
    Remove-Item -LiteralPath $tmpOutput -Force
}

$httpClient = New-Object System.Net.Http.HttpClient
try {
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $apiUrl)
    $content = New-Object System.Net.Http.ByteArrayContent(,$bodyBytes)
    $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/json")
    $content.Headers.ContentType.CharSet = "utf-8"
    $request.Content = $content

    $response = $httpClient.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    if (-not $response.IsSuccessStatusCode) {
        $errorText = $response.Content.ReadAsStringAsync().Result
        throw "HTTP $([int]$response.StatusCode): $errorText"
    }

    $ttsType = ""
    if ($response.Headers.Contains("x-generate-tts-type")) {
        $ttsType = ($response.Headers.GetValues("x-generate-tts-type") | Select-Object -First 1)
    }
    $contentType = [string]$response.Content.Headers.ContentType
    $isStream = $ttsType -eq "stream" -or $contentType -like "application/octet-stream*"

    if ($isStream) {
        $stream = $response.Content.ReadAsStreamAsync().Result
        try {
            $fileStream = [System.IO.File]::Open($tmpOutput, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $stream.CopyTo($fileStream)
            }
            finally {
                $fileStream.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $resolvedOutput) {
            Remove-Item -LiteralPath $resolvedOutput -Force
        }
        Move-Item -LiteralPath $tmpOutput -Destination $resolvedOutput -Force
    }
    else {
        $raw = $response.Content.ReadAsStringAsync().Result
        $jsonResponse = $raw | ConvertFrom-Json
        if (-not $jsonResponse.success -or -not $jsonResponse.data.audio) {
            throw "Unexpected createStream response: $raw"
        }

        $audioPath = [string]$jsonResponse.data.audio
        if ($audioPath.StartsWith("/")) {
            $downloadUrl = "$BaseUrl$audioPath"
        }
        else {
            $downloadUrl = "$BaseUrl/$audioPath"
        }
        Invoke-WebRequest -Method Get -Uri $downloadUrl -OutFile $resolvedOutput
    }
}
finally {
    $httpClient.Dispose()
}

[PSCustomObject]@{
    InputFile = $resolvedInput
    OutputFile = $resolvedOutput
    Voice = $Voice
    Rate = $Rate
    Pitch = $Pitch
    Volume = $Volume
    FileSizeBytes = (Get-Item -LiteralPath $resolvedOutput).Length
} | Format-List | Out-String | Write-Output
