param(
    [string]$InputDir = (Join-Path $PSScriptRoot "..\output\chunks"),
    [string]$OutputDir = (Join-Path $PSScriptRoot "..\output\audio"),
    [string]$BaseUrl = "http://127.0.0.1:9549",
    [string]$Voice = "zh-CN-YunjianNeural",
    [string]$Rate = "0%",
    [string]$Pitch = "0Hz",
    [string]$Volume = "0%",
    [string]$ManifestPath = (Join-Path $PSScriptRoot "..\output\audio_manifest.csv"),
    [string]$FailuresPath = (Join-Path $PSScriptRoot "..\output\audio_failures.csv"),
    [string]$StatePath = (Join-Path $PSScriptRoot "..\output\audio_state.json"),
    [switch]$RetryFailed,
    [string]$StartFrom,
    [switch]$Overwrite,
    [ValidateRange(1, 3)]
    [int]$FileConcurrency = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
    # Some hosts do not allow changing console encodings; continue with defaults.
}
$script:OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Get-KeyedMap {
    param(
        [object[]]$Rows,
        [string]$KeyName
    )

    $map = @{}
    foreach ($row in $Rows) {
        $key = [string]$row.$KeyName
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }
        $map[$key] = $row
    }
    return $map
}

function Save-State {
    param(
        [string]$Path,
        [hashtable]$State
    )
    $json = $State | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Update-ProgressDisplay {
    param(
        [string]$Activity,
        [hashtable]$State,
        [int]$PendingCount,
        [switch]$Completed
    )

    $processed = [int]$State.completed + [int]$State.failed + [int]$State.skipped
    $total = [Math]::Max([int]$State.total, 1)
    $percent = [Math]::Min([int][Math]::Floor(($processed * 100.0) / $total), 100)
    $status = "已处理 $processed/$($State.total) | 成功 $($State.completed) | 失败 $($State.failed) | 跳过 $($State.skipped) | 运行中 $($State.running) | 待处理 $PendingCount"
    if (-not [string]::IsNullOrWhiteSpace([string]$State.last_finished_file)) {
        $status = "$status | 最新: $($State.last_finished_file) [$($State.last_status)]"
    }

    Write-Progress -Id 1 -Activity $Activity -Status $status -PercentComplete $percent -Completed:$Completed
}

if (-not (Test-Path -LiteralPath $InputDir)) {
    throw "Input directory not found: $InputDir"
}

$resolvedInputDir = [System.IO.Path]::GetFullPath($InputDir)
$resolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedFailuresPath = [System.IO.Path]::GetFullPath($FailuresPath)
$resolvedStatePath = [System.IO.Path]::GetFullPath($StatePath)

foreach ($dir in @(
    $resolvedOutputDir,
    (Split-Path -Parent $resolvedManifestPath),
    (Split-Path -Parent $resolvedFailuresPath),
    (Split-Path -Parent $resolvedStatePath)
)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$allFiles = @(Get-ChildItem -LiteralPath $resolvedInputDir -File -Filter *.txt | Sort-Object Name)
if (-not $allFiles) {
    throw "No txt files found under: $resolvedInputDir"
}

$targetFiles = @($allFiles)

if ($RetryFailed) {
    if (-not (Test-Path -LiteralPath $resolvedFailuresPath)) {
        throw "RetryFailed enabled but failures file not found: $resolvedFailuresPath"
    }
    $failedRows = Import-Csv -LiteralPath $resolvedFailuresPath
    $failedNames = @{}
    foreach ($row in $failedRows) {
        $name = [System.IO.Path]::GetFileName([string]$row.source_txt)
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $failedNames[$name] = $true
        }
    }
    $targetFiles = @($allFiles | Where-Object { $failedNames.ContainsKey($_.Name) })
}

if (-not [string]::IsNullOrWhiteSpace($StartFrom)) {
    $startIndex = -1
    for ($i = 0; $i -lt $targetFiles.Count; $i++) {
        if ($targetFiles[$i].Name.StartsWith($StartFrom)) {
            $startIndex = $i
            break
        }
    }
    if ($startIndex -lt 0) {
        throw "StartFrom prefix not found in target files: $StartFrom"
    }
    $targetFiles = @($targetFiles[$startIndex..($targetFiles.Count - 1)])
}

if (-not $targetFiles) {
    Write-Output "No target files to process."
    exit 0
}

$manifestRows = @()
if (Test-Path -LiteralPath $resolvedManifestPath) {
    $manifestRows = Import-Csv -LiteralPath $resolvedManifestPath
}
$manifestMap = Get-KeyedMap -Rows $manifestRows -KeyName "source_txt"

$failureRows = @()
if (Test-Path -LiteralPath $resolvedFailuresPath) {
    $failureRows = Import-Csv -LiteralPath $resolvedFailuresPath
}
$failureMap = Get-KeyedMap -Rows $failureRows -KeyName "source_txt"

$completedCount = 0
$failedCount = 0
$skippedCount = 0

$state = @{
    started_at = [DateTime]::UtcNow.ToString("o")
    updated_at = [DateTime]::UtcNow.ToString("o")
    input_dir = $resolvedInputDir
    output_dir = $resolvedOutputDir
    retry_failed = [bool]$RetryFailed
    start_from = $StartFrom
    total = $targetFiles.Count
    completed = 0
    failed = 0
    skipped = 0
    running = 0
    last_finished_file = ""
    last_status = ""
}
Save-State -Path $resolvedStatePath -State $state

$workerScript = {
    param(
        [string]$SourcePath,
        [string]$OutputPath,
        [string]$BaseUrl,
        [string]$Voice,
        [string]$Rate,
        [string]$Pitch,
        [string]$Volume
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"
    Add-Type -AssemblyName System.Net.Http

    $startTime = [DateTime]::UtcNow
    $tempOutput = $OutputPath + ".tmp"

    try {
        [string]$text = Get-Content -LiteralPath $SourcePath -Encoding UTF8 -Raw
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw "Input text is empty."
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

        if (Test-Path -LiteralPath $tempOutput) {
            Remove-Item -LiteralPath $tempOutput -Force
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
                    $fileStream = [System.IO.File]::Open($tempOutput, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
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

                if (Test-Path -LiteralPath $OutputPath) {
                    Remove-Item -LiteralPath $OutputPath -Force
                }
                Move-Item -LiteralPath $tempOutput -Destination $OutputPath -Force
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
                Invoke-WebRequest -Method Get -Uri $downloadUrl -OutFile $OutputPath
            }
        }
        finally {
            $httpClient.Dispose()
        }

        [PSCustomObject]@{
            source_txt = $SourcePath
            audio_file = $OutputPath
            voice = $Voice
            rate = $Rate
            pitch = $Pitch
            volume = $Volume
            status = "success"
            started_at = $startTime.ToString("o")
            finished_at = [DateTime]::UtcNow.ToString("o")
            error = ""
        }
    }
    catch {
        $err = $_.Exception.Message
        if (Test-Path -LiteralPath $tempOutput) {
            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
        }
        [PSCustomObject]@{
            source_txt = $SourcePath
            audio_file = $OutputPath
            voice = $Voice
            rate = $Rate
            pitch = $Pitch
            volume = $Volume
            status = "failed"
            started_at = $startTime.ToString("o")
            finished_at = [DateTime]::UtcNow.ToString("o")
            error = $err
        }
    }
}

$queue = New-Object System.Collections.Generic.Queue[object]
foreach ($file in $targetFiles) {
    $sourcePath = $file.FullName
    $targetName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) + ".mp3"
    $outputPath = Join-Path $resolvedOutputDir $targetName

    $outputExists = Test-Path -LiteralPath $outputPath

    if (-not $Overwrite -and $outputExists) {
        $skippedCount++
        $row = [PSCustomObject]@{
            source_txt = $sourcePath
            audio_file = $outputPath
            voice = $Voice
            rate = $Rate
            pitch = $Pitch
            volume = $Volume
            status = "skipped"
            started_at = [DateTime]::UtcNow.ToString("o")
            finished_at = [DateTime]::UtcNow.ToString("o")
            error = ""
        }
        $manifestMap[$sourcePath] = $row
        if ($failureMap.ContainsKey($sourcePath)) {
            $failureMap.Remove($sourcePath)
        }
        continue
    }

    $queue.Enqueue([PSCustomObject]@{
        FileName = $file.Name
        SourcePath = $sourcePath
        OutputPath = $outputPath
    })
}

$state.completed = $completedCount
$state.failed = $failedCount
$state.skipped = $skippedCount
$state.running = 0
$state.updated_at = [DateTime]::UtcNow.ToString("o")
Save-State -Path $resolvedStatePath -State $state
Update-ProgressDisplay -Activity "EasyVoice 批量生成 MP3" -State $state -PendingCount $queue.Count

$runningJobs = @()

try {
    while ($queue.Count -gt 0 -or $runningJobs.Count -gt 0) {
        while ($queue.Count -gt 0 -and $runningJobs.Count -lt $FileConcurrency) {
            $item = $queue.Dequeue()
            $job = Start-Job -ScriptBlock $workerScript -ArgumentList @(
                $item.SourcePath,
                $item.OutputPath,
                $BaseUrl,
                $Voice,
                $Rate,
                $Pitch,
                $Volume
            )
            $runningJobs += [PSCustomObject]@{
                Job = $job
                FileName = $item.FileName
                SourcePath = $item.SourcePath
            }
        }

        $state.running = $runningJobs.Count
        $state.updated_at = [DateTime]::UtcNow.ToString("o")
        Save-State -Path $resolvedStatePath -State $state
        Update-ProgressDisplay -Activity "EasyVoice 批量生成 MP3" -State $state -PendingCount $queue.Count

        if ($runningJobs.Count -eq 0) {
            continue
        }

        $completedJob = Wait-Job -Job ($runningJobs | ForEach-Object { $_.Job }) -Any
        $entry = $runningJobs | Where-Object { $_.Job.Id -eq $completedJob.Id } | Select-Object -First 1

        $resultRow = $null
        try {
            $jobResult = Receive-Job -Job $completedJob -ErrorAction Stop
            $resultRow = @($jobResult | Select-Object -Last 1)[0]
            if ($null -eq $resultRow) {
                throw "Worker returned no result."
            }
        }
        catch {
            $resultRow = [PSCustomObject]@{
                source_txt = $entry.SourcePath
                audio_file = ""
                voice = $Voice
                rate = $Rate
                pitch = $Pitch
                volume = $Volume
                status = "failed"
                started_at = [DateTime]::UtcNow.ToString("o")
                finished_at = [DateTime]::UtcNow.ToString("o")
                error = $_.Exception.Message
            }
        }
        finally {
            Remove-Job -Job $completedJob -Force
        }

        $runningJobs = @($runningJobs | Where-Object { $_.Job.Id -ne $completedJob.Id })

        if ([string]$resultRow.status -eq "success") {
            $completedCount++
            if ($failureMap.ContainsKey([string]$resultRow.source_txt)) {
                $failureMap.Remove([string]$resultRow.source_txt)
            }
        }
        elseif ([string]$resultRow.status -eq "skipped") {
            $skippedCount++
        }
        else {
            $failedCount++
            $failureMap[[string]$resultRow.source_txt] = [PSCustomObject]@{
                source_txt = [string]$resultRow.source_txt
                audio_file = [string]$resultRow.audio_file
                voice = [string]$resultRow.voice
                rate = [string]$resultRow.rate
                pitch = [string]$resultRow.pitch
                volume = [string]$resultRow.volume
                failed_at = [DateTime]::UtcNow.ToString("o")
                error = [string]$resultRow.error
            }
        }

        $manifestMap[[string]$resultRow.source_txt] = $resultRow

        $state.completed = $completedCount
        $state.failed = $failedCount
        $state.skipped = $skippedCount
        $state.running = $runningJobs.Count
        $state.last_finished_file = $entry.FileName
        $state.last_status = [string]$resultRow.status
        $state.updated_at = [DateTime]::UtcNow.ToString("o")
        Save-State -Path $resolvedStatePath -State $state
        Update-ProgressDisplay -Activity "EasyVoice 批量生成 MP3" -State $state -PendingCount $queue.Count
    }
}
finally {
    foreach ($entry in $runningJobs) {
        if ($entry.Job.State -eq "Running") {
            Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
    }
}

$state.completed = $completedCount
$state.failed = $failedCount
$state.skipped = $skippedCount
$state.running = 0
$state.last_finished_file = ""
$state.last_status = "done"
$state.updated_at = [DateTime]::UtcNow.ToString("o")
Save-State -Path $resolvedStatePath -State $state
Update-ProgressDisplay -Activity "EasyVoice 批量生成 MP3" -State $state -PendingCount 0 -Completed

$manifestMap.Values |
    Sort-Object source_txt |
    Export-Csv -LiteralPath $resolvedManifestPath -NoTypeInformation -Encoding UTF8

if ($failureMap.Count -gt 0) {
    $failureMap.Values |
        Sort-Object source_txt |
        Export-Csv -LiteralPath $resolvedFailuresPath -NoTypeInformation -Encoding UTF8
}
else {
    Set-Content -LiteralPath $resolvedFailuresPath -Encoding UTF8 -Value "source_txt,audio_file,voice,rate,pitch,volume,failed_at,error"
}

[PSCustomObject]@{
    InputDir = $resolvedInputDir
    OutputDir = $resolvedOutputDir
    BaseUrl = $BaseUrl
    Voice = $Voice
    Rate = $Rate
    Pitch = $Pitch
    Volume = $Volume
    FileConcurrency = $FileConcurrency
    TotalTargets = $targetFiles.Count
    Completed = $completedCount
    Failed = $failedCount
    Skipped = $skippedCount
    Manifest = $resolvedManifestPath
    Failures = $resolvedFailuresPath
    State = $resolvedStatePath
} | Format-List | Out-String | Write-Output
