$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$htmlPath = Join-Path $PSScriptRoot 'index.html'
if (-not (Test-Path $htmlPath)) {
    Write-Host "Erreur : index.html introuvable dans $PSScriptRoot" -ForegroundColor Red
    Read-Host "Appuyez sur Entree pour quitter"
    exit 1
}

function Find-Exe($names, $extraPaths) {
    foreach ($n in $names) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }
    }
    foreach ($p in $extraPaths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return ''
}

$ffprobePath = Find-Exe @('ffprobe.exe', 'ffprobe') @(
    (Join-Path $PSScriptRoot 'ffprobe.exe'),
    'C:\ffmpeg\bin\ffprobe.exe',
    "$env:ProgramFiles\ffmpeg\bin\ffprobe.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffprobe.exe"
)

$vlcPath = Find-Exe @('vlc.exe') @(
    "$env:ProgramFiles\VideoLAN\VLC\vlc.exe",
    "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe"
)
$mpvPath = Find-Exe @('mpv.exe') @(
    (Join-Path $PSScriptRoot 'mpv.exe'),
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\mpv.exe",
    'C:\mpv\mpv.exe'
)

$playerPath = if ($vlcPath) { $vlcPath } elseif ($mpvPath) { $mpvPath } else { '' }
$playerName = if ($vlcPath) { 'VLC' } elseif ($mpvPath) { 'MPV' } else { '' }

$listener = $null
$port = 8787
for ($p = 8787; $p -le 8795; $p++) {
    $tryListener = New-Object System.Net.HttpListener
    $tryListener.Prefixes.Add("http://127.0.0.1:$p/")
    try {
        $tryListener.Start()
        $listener = $tryListener
        $port = $p
        break
    } catch {
        try { $tryListener.Close() } catch {}
    }
}

if (-not $listener) {
    Write-Host "Impossible d'ouvrir un port local (8787-8795)." -ForegroundColor Red
    Read-Host "Appuyez sur Entree pour quitter"
    exit 1
}

$appUrl = "http://127.0.0.1:$port/"

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $true
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$httpClient = New-Object System.Net.Http.HttpClient($handler)
$httpClient.Timeout = [TimeSpan]::FromSeconds(30)

$pool = [RunspaceFactory]::CreateRunspacePool(1, 16)
$pool.Open()

$workerScript = {
    param($ctx, $htmlPath, $httpClient, $ffprobePath, $playerPath, $playerName)
    $req = $ctx.Request
    $res = $ctx.Response

    function Send-Json($resObj, $statusCode, $jsonText) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonText)
        $resObj.StatusCode = $statusCode
        $resObj.ContentType = 'application/json; charset=utf-8'
        $resObj.AddHeader('Access-Control-Allow-Origin', '*')
        $resObj.ContentLength64 = $bytes.Length
        $resObj.OutputStream.Write($bytes, 0, $bytes.Length)
        $resObj.Close()
    }

    function Get-UrlParam($rawQuery) {
        if ($rawQuery -match '[?&]url=([^&]+)') {
            return [Uri]::UnescapeDataString($matches[1])
        }
        return ''
    }

    try {
        $path = $req.Url.AbsolutePath

        if ($req.HttpMethod -eq 'OPTIONS') {
            $res.StatusCode = 204
            $res.AddHeader('Access-Control-Allow-Origin', '*')
            $res.AddHeader('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
            $res.AddHeader('Access-Control-Allow-Headers', '*')
            $res.Close()
            return
        }

        if ($path -eq '/' -or $path -eq '/index.html') {
            $bytes = [System.IO.File]::ReadAllBytes($htmlPath)
            $res.StatusCode = 200
            $res.ContentType = 'text/html; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.Close()
            return
        }

        if ($path -eq '/proxy-status') {
            $hasFfprobe = if ($ffprobePath) { 'true' } else { 'false' }
            $hasPlayer = if ($playerPath) { 'true' } else { 'false' }
            $pNameEsc = ($playerName -replace '"', '')
            Send-Json $res 200 "{`"ok`":true,`"mode`":`"windows-local`",`"ffprobe`":$hasFfprobe,`"player`":$hasPlayer,`"playerName`":`"$pNameEsc`"}"
            return
        }

        if ($path -eq '/launch-player') {
            $targetUrl = Get-UrlParam $req.Url.Query
            if (-not $playerPath -or -not ($targetUrl -match '^(https?|rtmp|rtsp|udp|rtp|mms|srt)://') -or ($targetUrl -match '[\r\n"]')) {
                Send-Json $res 400 '{"ok":false}'
                return
            }
            Start-Process -FilePath $playerPath -ArgumentList @($targetUrl)
            $pNameEsc = ($playerName -replace '"', '')
            Send-Json $res 200 "{`"ok`":true,`"playerName`":`"$pNameEsc`"}"
            return
        }

        if ($path -eq '/probe-ffprobe') {
            $targetUrl = Get-UrlParam $req.Url.Query
            if (-not $ffprobePath -or -not ($targetUrl -match '^(https?|rtmp|rtsp|udp|rtp|mms|srt)://') -or ($targetUrl -match '[\r\n"]')) {
                Send-Json $res 400 '{"ok":false,"detail":"invalid"}'
                return
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $ffprobePath
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true

            $escapedUrl = $targetUrl.Replace('"', '\"')
            $ua = 'VLC/3.0.20 LibVLC/3.0.20'
            if ($targetUrl -match '^https?://') {
                $psi.Arguments = "-v error -user_agent `"$ua`" -rw_timeout 4000000 -show_entries stream=codec_type,codec_name,width,height -of json `"$escapedUrl`""
            } else {
                $psi.Arguments = "-v error -rw_timeout 4000000 -show_entries stream=codec_type,codec_name,width,height -of json `"$escapedUrl`""
            }

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()

            $exited = $proc.WaitForExit(5000)
            if (-not $exited) {
                try { $proc.Kill() } catch {}
                $proc.Dispose()
                Send-Json $res 200 '{"ok":false,"timeout":true,"detail":"Timeout 5s"}'
                return
            }

            $stdout = $outTask.GetAwaiter().GetResult()
            $exitCode = $proc.ExitCode
            $proc.Dispose()

            if ($exitCode -eq 0 -and $stdout) {
                try {
                    $parsed = $stdout | ConvertFrom-Json
                    if ($parsed -and $parsed.streams -and $parsed.streams.Count -gt 0) {
                        $vid = $parsed.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
                        $aud = $parsed.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
                        $detail = ''
                        if ($vid) {
                            $dims = if ($vid.width -and $vid.height) { "$($vid.width)x$($vid.height)" } else { '' }
                            $codec = if ($vid.codec_name) { "$($vid.codec_name)" } else { '' }
                            $detail = ("$dims $codec").Trim()
                        } elseif ($aud) {
                            $detail = "audio $($aud.codec_name)"
                        }
                        $detailEsc = $detail.Replace('\', '\\').Replace('"', '\"')
                        Send-Json $res 200 "{`"ok`":true,`"detail`":`"$detailEsc`"}"
                        return
                    }
                } catch {}
            }

            Send-Json $res 200 '{"ok":false,"timeout":false,"detail":"FFprobe"}'
            return
        }

        if ($path -eq '/proxy') {
            $targetUrl = Get-UrlParam $req.Url.Query
            if (-not ($targetUrl -match '^https?://')) {
                $res.StatusCode = 400
                $res.AddHeader('Access-Control-Allow-Origin', '*')
                $res.Close()
                return
            }

            $isProbe = $req.Url.Query -match '[?&]probe=1(&|$)'
            $method = if ($req.HttpMethod -eq 'HEAD') { [System.Net.Http.HttpMethod]::Head } else { [System.Net.Http.HttpMethod]::Get }
            $timeoutMs = if ($isProbe) { 4500 } else { 25000 }
            $completion = [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead

            $userAgents = @(
                'VLC/3.0.20 LibVLC/3.0.20',
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36'
            )

            $upstreamRes = $null
            $cts = New-Object System.Threading.CancellationTokenSource($timeoutMs)

            try {
                for ($attempt = 0; $attempt -lt $userAgents.Length; $attempt++) {
                    $uReq = New-Object System.Net.Http.HttpRequestMessage($method, $targetUrl)
                    $uReq.Headers.TryAddWithoutValidation('User-Agent', $userAgents[$attempt]) | Out-Null
                    $uReq.Headers.TryAddWithoutValidation('Accept', '*/*') | Out-Null
                    $rangeHeader = $req.Headers['Range']
                    if ($rangeHeader -and -not $isProbe) {
                        $uReq.Headers.TryAddWithoutValidation('Range', $rangeHeader) | Out-Null
                    }

                    $candidate = $httpClient.SendAsync($uReq, $completion, $cts.Token).GetAwaiter().GetResult()
                    $uReq.Dispose()

                    $code = [int]$candidate.StatusCode
                    if (($code -eq 400 -or $code -eq 403) -and $attempt -eq 0) {
                        $candidate.Dispose()
                        continue
                    }
                    $upstreamRes = $candidate
                    break
                }

                $res.StatusCode = [int]$upstreamRes.StatusCode
                $res.AddHeader('Access-Control-Allow-Origin', '*')
                $res.AddHeader('Access-Control-Expose-Headers', '*')
                if ($upstreamRes.Content.Headers.ContentType) {
                    $res.ContentType = $upstreamRes.Content.Headers.ContentType.ToString()
                }

                if ($method -ne [System.Net.Http.HttpMethod]::Head -and -not $isProbe) {
                    $stream = $upstreamRes.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    try { $stream.CopyTo($res.OutputStream) } catch {} finally { $stream.Dispose() }
                }
                $upstreamRes.Dispose()
                $res.Close()
            } finally {
                if ($upstreamRes) { try { $upstreamRes.Dispose() } catch {} }
                $cts.Dispose()
            }
            return
        }

        $res.StatusCode = 404
        $res.Close()
    } catch {
        try {
            $res.StatusCode = 502
            $res.AddHeader('Access-Control-Allow-Origin', '*')
            $res.Close()
        } catch {}
    }
}

$bravePaths = @(
    "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe",
    "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
    "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe"
)
$operaPaths = @(
    "$env:LOCALAPPDATA\Programs\Opera\opera.exe",
    "$env:LOCALAPPDATA\Programs\Opera GX\opera.exe",
    "$env:ProgramFiles\Opera\opera.exe",
    "${env:ProgramFiles(x86)}\Opera\opera.exe"
)

$launched = $false
foreach ($bp in $bravePaths) {
    if ($bp -and (Test-Path $bp)) {
        Start-Process -FilePath $bp -ArgumentList "--app=$appUrl"
        $launched = $true
        Write-Host "Ouvert dans Brave : $appUrl" -ForegroundColor Green
        break
    }
}
if (-not $launched) {
    foreach ($op in $operaPaths) {
        if ($op -and (Test-Path $op)) {
            Start-Process -FilePath $op -ArgumentList $appUrl
            $launched = $true
            Write-Host "Ouvert dans Opera : $appUrl" -ForegroundColor Green
            break
        }
    }
}
if (-not $launched) {
    Start-Process $appUrl
    Write-Host "Ouvert dans votre navigateur par defaut : $appUrl" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "M3U Studio est actif (Mode Windows multi-thread sans CORS) sur $appUrl" -ForegroundColor Cyan
Write-Host (" - FFprobe : " + $(if ($ffprobePath) { "Detecte ($ffprobePath)" } else { "Non detecte (mode HTTP actif)" })) -ForegroundColor Gray
Write-Host (" - Lecteur : " + $(if ($playerPath) { "$playerName ($playerPath)" } else { "Non detecte (export .m3u actif)" })) -ForegroundColor Gray
Write-Host "Laissez cette fenetre ouverte pendant l'utilisation, puis fermez-la pour arreter." -ForegroundColor Gray

$jobs = New-Object System.Collections.ArrayList
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
            if ($jobs[$i].Handle.IsCompleted) {
                try { $jobs[$i].PS.EndInvoke($jobs[$i].Handle) } catch {}
                $jobs[$i].PS.Dispose()
                $jobs.RemoveAt($i)
            }
        }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript).AddArgument($ctx).AddArgument($htmlPath).AddArgument($httpClient).AddArgument($ffprobePath).AddArgument($playerPath).AddArgument($playerName)
        $handle = $ps.BeginInvoke()
        [void]$jobs.Add([PSCustomObject]@{ PS = $ps; Handle = $handle })
    }
} finally {
    try { $listener.Stop() } catch {}
    try { $pool.Close(); $pool.Dispose() } catch {}
    try { $httpClient.Dispose() } catch {}
}