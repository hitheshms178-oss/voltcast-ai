param(
    [int]$Port = 8787
)

$ErrorActionPreference = "Stop"
$PublicRoot = Join-Path $PSScriptRoot "public"

function Send-HttpResponse {
    param(
        [System.IO.Stream] $Stream,
        [int] $StatusCode,
        [string] $ContentType,
        [byte[]] $Body
    )

    $reasonMap = @{
        200 = "OK"
        204 = "No Content"
        400 = "Bad Request"
        403 = "Forbidden"
        404 = "Not Found"
        405 = "Method Not Allowed"
        500 = "Internal Server Error"
    }
    $reason = if ($reasonMap.ContainsKey($StatusCode)) { $reasonMap[$StatusCode] } else { "OK" }
    $headers = @(
        "HTTP/1.1 $StatusCode $reason",
        "Content-Type: $ContentType",
        "Content-Length: $($Body.Length)",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Headers: Content-Type",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Connection: close",
        "",
        ""
    ) -join "`r`n"

    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
}

function New-JsonResponse {
    param([System.IO.Stream] $Stream, $Payload, [int] $StatusCode = 200)
    $json = $Payload | ConvertTo-Json -Depth 12
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-HttpResponse $Stream $StatusCode "application/json; charset=utf-8" $buffer
}

function New-TextResponse {
    param([System.IO.Stream] $Stream, [string] $Text, [string] $ContentType = "text/plain; charset=utf-8", [int] $StatusCode = 200)
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Send-HttpResponse $Stream $StatusCode $ContentType $buffer
}

function Get-RequestBody {
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Get-ContentType {
    param([string] $Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { "text/html; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".js" { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".png" { "image/png" }
        ".jpg" { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        default { "application/octet-stream" }
    }
}

function Clamp-Number {
    param([double] $Value, [double] $Min, [double] $Max)
    return [Math]::Max($Min, [Math]::Min($Max, $Value))
}

function Get-GridStress {
    param([int] $Hour)
    $morning = 28 * [Math]::Exp(-[Math]::Pow(($Hour - 8) / 2.4, 2))
    $evening = 58 * [Math]::Exp(-[Math]::Pow(($Hour - 19) / 2.7, 2))
    return [Math]::Round((Clamp-Number (28 + $morning + $evening) 12 96), 1)
}

function Get-WindScore {
    param([double] $WindSpeed)
    if ($WindSpeed -lt 3) {
        return [Math]::Round((Clamp-Number ($WindSpeed * 12) 0 40), 1)
    }
    if ($WindSpeed -le 12) {
        return [Math]::Round((Clamp-Number (42 + (($WindSpeed - 3) / 9) * 58) 0 100), 1)
    }
    return [Math]::Round((Clamp-Number (100 - (($WindSpeed - 12) * 5)) 45 100), 1)
}

function New-ForecastPoint {
    param(
        [int] $Hour,
        [double] $Radiation,
        [double] $CloudCover,
        [double] $WindSpeed,
        [double] $Temperature,
        [string] $Source
    )
    $solarScore = Clamp-Number (($Radiation / 820) * 100 * (1 - (($CloudCover * 0.25) / 100))) 0 100
    $windScore = Get-WindScore $WindSpeed
    $renewableScore = Clamp-Number (($solarScore * 0.72) + ($windScore * 0.28)) 0 100
    $gridStress = Get-GridStress $Hour
    $tariff = Clamp-Number (4.8 + ($gridStress * 0.045) - ($renewableScore * 0.018)) 3.8 10.8

    return [pscustomobject]@{
        hour = $Hour
        label = "{0:00}:00" -f $Hour
        solarScore = [Math]::Round($solarScore, 1)
        windScore = [Math]::Round($windScore, 1)
        renewableScore = [Math]::Round($renewableScore, 1)
        gridStress = [Math]::Round($gridStress, 1)
        tariff = [Math]::Round($tariff, 2)
        cloudCover = [Math]::Round((Clamp-Number $CloudCover 0 100), 1)
        windSpeed = [Math]::Round($WindSpeed, 1)
        temperature = [Math]::Round($Temperature, 1)
        source = $Source
    }
}

function New-SyntheticForecast {
    param([string] $Profile = "mixed")
    $profileKey = if ([string]::IsNullOrWhiteSpace($Profile)) { "mixed" } else { $Profile.ToLowerInvariant() }

    switch ($profileKey) {
        "clear" { $cloudBase = 16; $windBase = 4.2; $tempBase = 31 }
        "cloudy" { $cloudBase = 62; $windBase = 5.4; $tempBase = 27 }
        "windy" { $cloudBase = 36; $windBase = 9.4; $tempBase = 28 }
        default { $cloudBase = 34; $windBase = 6.1; $tempBase = 30 }
    }

    $points = New-Object System.Collections.Generic.List[object]
    for ($hour = 0; $hour -lt 24; $hour++) {
        $sunAngle = if ($hour -ge 6 -and $hour -le 18) { [Math]::Sin((($hour - 6) / 12) * [Math]::PI) } else { 0 }
        $cloudWave = (12 * [Math]::Sin(($hour + 2) * 0.77)) + (8 * [Math]::Cos($hour * 0.41))
        $cloud = Clamp-Number ($cloudBase + $cloudWave) 4 92
        $radiation = [Math]::Max(0, 850 * $sunAngle * (1 - ($cloud / 150)))
        $wind = Clamp-Number ($windBase + (1.4 * [Math]::Sin($hour * 0.56)) + (0.9 * [Math]::Cos(($hour + 3) * 0.33))) 1.2 16
        $temperature = $tempBase + (4.2 * [Math]::Sin((($hour - 8) / 24) * 2 * [Math]::PI))
        $points.Add((New-ForecastPoint $hour $radiation $cloud $wind $temperature "demo"))
    }
    return $points
}

function Get-LiveForecast {
    param([double] $Latitude, [double] $Longitude)
    $uri = "https://api.open-meteo.com/v1/forecast?latitude=$Latitude&longitude=$Longitude&hourly=shortwave_radiation,cloud_cover,wind_speed_10m,temperature_2m&forecast_days=2&timezone=auto"
    $weather = Invoke-RestMethod -Uri $uri -TimeoutSec 8
    $times = @($weather.hourly.time)
    $radiation = @($weather.hourly.shortwave_radiation)
    $clouds = @($weather.hourly.cloud_cover)
    $winds = @($weather.hourly.wind_speed_10m)
    $temps = @($weather.hourly.temperature_2m)
    $points = New-Object System.Collections.Generic.List[object]
    $now = Get-Date
    $startIndex = 0

    for ($i = 0; $i -lt $times.Count; $i++) {
        $time = [DateTime]::Parse($times[$i])
        if ($time -ge $now.AddHours(-1)) {
            $startIndex = $i
            break
        }
    }

    for ($offset = 0; $offset -lt 24; $offset++) {
        $idx = [Math]::Min($startIndex + $offset, $times.Count - 1)
        $time = [DateTime]::Parse($times[$idx])
        $points.Add((New-ForecastPoint $time.Hour ([double]$radiation[$idx]) ([double]$clouds[$idx]) ([double]$winds[$idx]) ([double]$temps[$idx]) "open-meteo"))
    }
    return $points
}

function Get-Forecast {
    param($Payload)
    $source = if ($Payload -and $Payload.weatherSource) { [string]$Payload.weatherSource } else { "demo" }
    $profile = if ($Payload -and $Payload.weatherProfile) { [string]$Payload.weatherProfile } else { "mixed" }
    $latitude = if ($Payload -and $Payload.location -and $Payload.location.latitude) { [double]$Payload.location.latitude } else { 13.0827 }
    $longitude = if ($Payload -and $Payload.location -and $Payload.location.longitude) { [double]$Payload.location.longitude } else { 80.2707 }

    if ($source -eq "live") {
        try {
            return Get-LiveForecast $latitude $longitude
        }
        catch {
            $fallback = New-SyntheticForecast $profile
            foreach ($point in $fallback) {
                $point.source = "demo-fallback"
            }
            return $fallback
        }
    }
    return New-SyntheticForecast $profile
}

function New-EmptyCurve {
    $curve = New-Object 'double[]' 24
    for ($i = 0; $i -lt 24; $i++) {
        $curve[$i] = 0
    }
    return $curve
}

function Add-LoadToCurve {
    param($Curve, [double] $PowerKw, [int] $StartHour, [int] $Slots)
    for ($i = 0; $i -lt $Slots; $i++) {
        $idx = $StartHour + $i
        if ($idx -ge 0 -and $idx -lt 24) {
            $Curve[$idx] += $PowerKw
        }
    }
}

function Get-AverageForWindow {
    param($Items, [int] $StartHour, [int] $Slots, [string] $Field)
    $sum = 0.0
    for ($i = 0; $i -lt $Slots; $i++) {
        $sum += [double]$Items[$StartHour + $i].$Field
    }
    return $sum / $Slots
}

function Measure-Curve {
    param($Curve, $Forecast)
    $energy = 0.0
    $renewableEnergy = 0.0
    $gridEnergy = 0.0
    $cost = 0.0
    $peak = 0.0

    for ($i = 0; $i -lt 24; $i++) {
        $kw = [double]$Curve[$i]
        $renewableRatio = ([double]$Forecast[$i].renewableScore) / 100
        $energy += $kw
        $renewableEnergy += $kw * $renewableRatio
        $gridEnergy += $kw * (1 - $renewableRatio)
        $cost += $kw * ([double]$Forecast[$i].tariff)
        $peak = [Math]::Max($peak, $kw)
    }

    $renewableShare = if ($energy -gt 0) { ($renewableEnergy / $energy) * 100 } else { 0 }
    return [pscustomobject]@{
        energyKwh = [Math]::Round($energy, 2)
        renewableEnergyKwh = [Math]::Round($renewableEnergy, 2)
        gridEnergyKwh = [Math]::Round($gridEnergy, 2)
        renewableShare = [Math]::Round($renewableShare, 1)
        cost = [Math]::Round($cost, 2)
        peakKw = [Math]::Round($peak, 2)
    }
}

function Convert-CurveToSeries {
    param($Curve, $Forecast)
    $series = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt 24; $i++) {
        $kw = [Math]::Round([double]$Curve[$i], 2)
        $series.Add([pscustomobject]@{
            hour = $i
            label = "{0:00}:00" -f $i
            kw = $kw
            gridKw = [Math]::Round(($kw * (1 - (([double]$Forecast[$i].renewableScore) / 100))), 2)
        })
    }
    return $series
}

function Optimize-Loads {
    param($Payload)
    $forecast = @(Get-Forecast $Payload)
    $rawLoads = if ($Payload -and $Payload.loads) { @($Payload.loads) } else { @() }

    if ($rawLoads.Count -eq 0) {
        $rawLoads = @(
            [pscustomobject]@{ id = "ev"; name = "EV charger"; powerKw = 3.3; durationHours = 3; earliestHour = 10; deadlineHour = 22; preferredStartHour = 19 },
            [pscustomobject]@{ id = "washer"; name = "Washing machine"; powerKw = 1.0; durationHours = 2; earliestHour = 8; deadlineHour = 20; preferredStartHour = 18 },
            [pscustomobject]@{ id = "pump"; name = "Water pump"; powerKw = 1.5; durationHours = 1; earliestHour = 6; deadlineHour = 18; preferredStartHour = 7 }
        )
    }

    $baselineCurve = New-EmptyCurve
    $optimizedCurve = New-EmptyCurve
    $occupied = New-EmptyCurve
    $schedules = New-Object System.Collections.Generic.List[object]
    $loads = New-Object System.Collections.Generic.List[object]

    foreach ($load in $rawLoads) {
        $name = if ($load.name) { [string]$load.name } else { "Flexible load" }
        $id = if ($load.id) { [string]$load.id } else { ("load-" + $loads.Count) }
        $powerKw = Clamp-Number ([double]$load.powerKw) 0.1 25
        $durationHours = Clamp-Number ([double]$load.durationHours) 0.5 12
        $slots = [Math]::Max(1, [Math]::Ceiling($durationHours))
        $earliest = [int](Clamp-Number ([double]$load.earliestHour) 0 23)
        $deadline = [int](Clamp-Number ([double]$load.deadlineHour) 1 24)
        $preferred = [int](Clamp-Number ([double]$load.preferredStartHour) 0 23)

        if ($deadline -le $earliest) {
            $deadline = 24
        }
        if (($deadline - $earliest) -lt $slots) {
            $earliest = [Math]::Max(0, $deadline - $slots)
        }

        $normalized = [pscustomobject]@{
            id = $id
            name = $name
            powerKw = [Math]::Round($powerKw, 2)
            durationHours = [Math]::Round($durationHours, 2)
            slots = $slots
            earliestHour = $earliest
            deadlineHour = $deadline
            preferredStartHour = $preferred
            energyKwh = [Math]::Round(($powerKw * $durationHours), 2)
        }
        $loads.Add($normalized)
        Add-LoadToCurve $baselineCurve $powerKw ([Math]::Min($preferred, 24 - $slots)) $slots
    }

    $orderedLoads = @($loads | Sort-Object -Property @{ Expression = { -([double]$_.energyKwh) } })

    foreach ($load in $orderedLoads) {
        $bestStart = $load.earliestHour
        $bestScore = -999999.0
        $latestStart = [Math]::Min(24 - $load.slots, $load.deadlineHour - $load.slots)
        $latestStart = [Math]::Max($load.earliestHour, $latestStart)

        for ($start = $load.earliestHour; $start -le $latestStart; $start++) {
            $renewable = Get-AverageForWindow $forecast $start $load.slots "renewableScore"
            $stress = Get-AverageForWindow $forecast $start $load.slots "gridStress"
            $tariff = Get-AverageForWindow $forecast $start $load.slots "tariff"
            $occupiedWindow = @($occupied | ForEach-Object { [pscustomobject]@{ value = $_ } })
            $overlap = Get-AverageForWindow $occupiedWindow $start $load.slots "value"
            $middayBonus = if ($start -ge 10 -and $start -le 15) { 6 } else { 0 }
            $deadlineSlack = [Math]::Max(0, $load.deadlineHour - ($start + $load.slots))
            $score = ($renewable * 0.58) + ((100 - $stress) * 0.24) + ((10.8 - $tariff) * 6.5) + $middayBonus + ($deadlineSlack * 0.2) - ($overlap * 8.5)

            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestStart = $start
            }
        }

        Add-LoadToCurve $optimizedCurve $load.powerKw $bestStart $load.slots
        Add-LoadToCurve $occupied $load.powerKw $bestStart $load.slots
        $avgRenewable = Get-AverageForWindow $forecast $bestStart $load.slots "renewableScore"
        $avgStress = Get-AverageForWindow $forecast $bestStart $load.slots "gridStress"
        $avgTariff = Get-AverageForWindow $forecast $bestStart $load.slots "tariff"

        $schedules.Add([pscustomobject]@{
            id = $load.id
            name = $load.name
            powerKw = $load.powerKw
            durationHours = $load.durationHours
            energyKwh = $load.energyKwh
            startHour = $bestStart
            endHour = [Math]::Min(24, $bestStart + $load.slots)
            startLabel = "{0:00}:00" -f $bestStart
            endLabel = "{0:00}:00" -f ([Math]::Min(24, $bestStart + $load.slots))
            renewableShare = [Math]::Round($avgRenewable, 1)
            gridStress = [Math]::Round($avgStress, 1)
            tariff = [Math]::Round($avgTariff, 2)
            reason = "Best window balances renewable availability, lower grid stress, and tariff."
        })
    }

    $baseline = Measure-Curve $baselineCurve $forecast
    $optimized = Measure-Curve $optimizedCurve $forecast
    $gridSaved = [Math]::Max(0, $baseline.gridEnergyKwh - $optimized.gridEnergyKwh)
    $costSaved = [Math]::Max(0, $baseline.cost - $optimized.cost)
    $peakDrop = [Math]::Max(0, $baseline.peakKw - $optimized.peakKw)
    $locationName = if ($Payload -and $Payload.location -and $Payload.location.name) { [string]$Payload.location.name } else { "Demo site" }

    return [pscustomobject]@{
        app = "VoltCast"
        location = $locationName
        generatedAt = (Get-Date).ToString("s")
        forecastSource = if ($forecast.Count -gt 0) { $forecast[0].source } else { "demo" }
        forecast = $forecast
        schedules = $schedules
        baselineCurve = Convert-CurveToSeries $baselineCurve $forecast
        optimizedCurve = Convert-CurveToSeries $optimizedCurve $forecast
        metrics = [pscustomobject]@{
            totalEnergyKwh = $optimized.energyKwh
            gridEnergyBeforeKwh = $baseline.gridEnergyKwh
            gridEnergyAfterKwh = $optimized.gridEnergyKwh
            gridEnergySavedKwh = [Math]::Round($gridSaved, 2)
            renewableShareBefore = $baseline.renewableShare
            renewableShareAfter = $optimized.renewableShare
            costBefore = $baseline.cost
            costAfter = $optimized.cost
            costSaved = [Math]::Round($costSaved, 2)
            peakBeforeKw = $baseline.peakKw
            peakAfterKw = $optimized.peakKw
            peakDropKw = [Math]::Round($peakDrop, 2)
            carbonAvoidedKg = [Math]::Round(($gridSaved * 0.72), 2)
        }
        notes = @(
            "Loads are scheduled within each appliance window.",
            "Renewable score combines predicted solar radiation and wind speed.",
            "Grid stress is modeled with morning and evening peak demand."
        )
    }
}

function Send-StaticFile {
    param([System.IO.Stream] $Stream, [string] $RequestPath)
    $relativePath = [Uri]::UnescapeDataString($RequestPath.TrimStart("/"))
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        $relativePath = "index.html"
    }

    $combined = Join-Path $PublicRoot $relativePath
    $fullPath = [System.IO.Path]::GetFullPath($combined)
    $rootPath = [System.IO.Path]::GetFullPath($PublicRoot)

    if (-not $fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        New-TextResponse $Stream "Forbidden" "text/plain; charset=utf-8" 403
        return
    }
    if (-not [System.IO.File]::Exists($fullPath)) {
        New-TextResponse $Stream "Not found" "text/plain; charset=utf-8" 404
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    Send-HttpResponse $Stream 200 (Get-ContentType $fullPath) $bytes
}

function Read-HttpRequest {
    param([System.Net.Sockets.TcpClient] $Client)

    $stream = $Client.GetStream()
    $buffer = New-Object byte[] 8192
    $memory = New-Object System.IO.MemoryStream
    $headerEnd = -1
    $contentLength = 0

    while ($true) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            break
        }

        $memory.Write($buffer, 0, $read)
        $bytes = $memory.ToArray()
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $headerEnd = $text.IndexOf("`r`n`r`n")

        if ($headerEnd -ge 0) {
            $headerText = $text.Substring(0, $headerEnd)
            $lengthMatch = [regex]::Match($headerText, "(?im)^Content-Length:\s*(\d+)")
            if ($lengthMatch.Success) {
                $contentLength = [int]$lengthMatch.Groups[1].Value
            }
            if ($memory.Length -ge ($headerEnd + 4 + $contentLength)) {
                break
            }
        }
    }

    if ($headerEnd -lt 0) {
        return $null
    }

    $allBytes = $memory.ToArray()
    $requestText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
    $lines = $requestText -split "`r`n"
    $parts = $lines[0] -split " "
    $body = ""

    if ($contentLength -gt 0) {
        $body = [System.Text.Encoding]::UTF8.GetString($allBytes, $headerEnd + 4, $contentLength)
    }

    $target = if ($parts.Count -gt 1) { $parts[1] } else { "/" }
    $uri = [Uri]::new("http://localhost$target")

    return [pscustomobject]@{
        Method = if ($parts.Count -gt 0) { $parts[0] } else { "GET" }
        Path = $uri.AbsolutePath
        Query = $uri.Query
        Body = $body
        Stream = $stream
    }
}

function Get-QueryValue {
    param([string] $Query, [string] $Name)

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return $null
    }

    foreach ($part in ($Query.TrimStart("?") -split "&")) {
        $kv = $part -split "=", 2
        if ($kv.Count -eq 2 -and [Uri]::UnescapeDataString($kv[0]) -eq $Name) {
            return [Uri]::UnescapeDataString($kv[1])
        }
    }

    return $null
}

function Invoke-Route {
    param($Request)

    $stream = $Request.Stream
    if ($Request.Method -eq "OPTIONS") {
        New-TextResponse $stream "" "text/plain; charset=utf-8" 204
    }
    elseif ($Request.Path -eq "/api/health") {
        New-JsonResponse $stream ([pscustomobject]@{
            ok = $true
            app = "VoltCast"
            endpoints = @("/api/health", "/api/forecast", "/api/optimize")
        })
    }
    elseif ($Request.Path -eq "/api/forecast" -and $Request.Method -eq "GET") {
        $profile = Get-QueryValue $Request.Query "profile"
        $payload = [pscustomobject]@{
            weatherSource = "demo"
            weatherProfile = if ($profile) { $profile } else { "mixed" }
        }
        New-JsonResponse $stream ([pscustomobject]@{ forecast = @(Get-Forecast $payload) })
    }
    elseif ($Request.Path -eq "/api/optimize" -and $Request.Method -eq "POST") {
        $payload = if ([string]::IsNullOrWhiteSpace($Request.Body)) { [pscustomobject]@{} } else { $Request.Body | ConvertFrom-Json }
        New-JsonResponse $stream (Optimize-Loads $payload)
    }
    elseif ($Request.Method -eq "GET") {
        Send-StaticFile $stream $Request.Path
    }
    else {
        New-JsonResponse $stream ([pscustomobject]@{ error = "Method not allowed" }) 405
    }
}

if (-not [System.IO.Directory]::Exists($PublicRoot)) {
    throw "Missing public directory: $PublicRoot"
}

$tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)

try {
    $tcpListener.Start()
}
catch {
    Write-Host "Unable to start VoltCast on http://localhost:$Port/"
    Write-Host $_.Exception.Message
    Write-Host "Try another port: powershell -ExecutionPolicy Bypass -File .\server.ps1 -Port 8790"
    exit 1
}

Write-Host "VoltCast is running at http://localhost:$Port/"
Write-Host "Press Ctrl+C to stop."

try {
    while ($true) {
        $client = $tcpListener.AcceptTcpClient()
        try {
            $request = Read-HttpRequest $client
            if ($null -eq $request) {
                continue
            }

            try {
                Invoke-Route $request
            }
            catch {
                New-JsonResponse $request.Stream ([pscustomobject]@{
                    error = "VoltCast API error"
                    detail = $_.Exception.Message
                }) 500
            }
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $tcpListener.Stop()
}

exit 0

if (-not [System.IO.Directory]::Exists($PublicRoot)) {
    throw "Missing public directory: $PublicRoot"
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
}
catch {
    Write-Host "Unable to start VoltCast on $prefix"
    Write-Host $_.Exception.Message
    Write-Host "Try another port: powershell -ExecutionPolicy Bypass -File .\server.ps1 -Port 8790"
    exit 1
}

Write-Host "VoltCast is running at $prefix"
Write-Host "Press Ctrl+C to stop."

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
        $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

        try {
            if ($request.HttpMethod -eq "OPTIONS") {
                New-TextResponse $response "" "text/plain; charset=utf-8" 204
            }
            elseif ($request.Url.AbsolutePath -eq "/api/health") {
                New-JsonResponse $response ([pscustomobject]@{
                    ok = $true
                    app = "VoltCast"
                    endpoints = @("/api/health", "/api/forecast", "/api/optimize")
                })
            }
            elseif ($request.Url.AbsolutePath -eq "/api/forecast" -and $request.HttpMethod -eq "GET") {
                $profile = $request.QueryString["profile"]
                $payload = [pscustomobject]@{
                    weatherSource = "demo"
                    weatherProfile = if ($profile) { $profile } else { "mixed" }
                }
                New-JsonResponse $response ([pscustomobject]@{ forecast = @(Get-Forecast $payload) })
            }
            elseif ($request.Url.AbsolutePath -eq "/api/optimize" -and $request.HttpMethod -eq "POST") {
                $body = Get-RequestBody $request
                $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
                New-JsonResponse $response (Optimize-Loads $payload)
            }
            elseif ($request.HttpMethod -eq "GET") {
                Send-StaticFile $response $request.Url.AbsolutePath
            }
            else {
                New-JsonResponse $response ([pscustomobject]@{ error = "Method not allowed" }) 405
            }
        }
        catch {
            New-JsonResponse $response ([pscustomobject]@{
                error = "VoltCast API error"
                detail = $_.Exception.Message
            }) 500
        }
        finally {
            $response.OutputStream.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
