$ErrorActionPreference = "Stop"

function Log($msg) {
    Write-Host "[INFO] $msg"
}

function Warn($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Fail($msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

function New-RandomName {
    $chars = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
    $bytes = New-Object byte[] 8
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return "oc_" + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

function New-RandomToken {
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".ToCharArray()
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

$CONTAINER_NAME = New-RandomName
$DEFAULT_PORT = 18789
$DEFAULT_CONFIG_DIR = Join-Path $HOME ".openclaw"
$MIRROR_PREFIX = "dockerpull.org"

function Expand-PathEx($path) {
    if ($path -eq "~") {
        return $HOME
    }
    elseif ($path.StartsWith("~/") -or $path.StartsWith("~\")) {
        return Join-Path $HOME $path.Substring(2)
    }
    else {
        return $path
    }
}

function Test-Cmd($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Detect-Engine {
    if (Test-Cmd "podman") {
        return "podman"
    }
    elseif (Test-Cmd "docker") {
        return "docker"
    }
    else {
        Fail "podman or docker not found"
    }
}

function Detect-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -match "AMD64|x86_64") {
        return "amd64"
    }
    elseif ($arch -match "ARM64") {
        return "arm64"
    }
    else {
        Fail "unsupported architecture: $arch"
    }
}

function Image-ExistsLocal($engine, $image) {
    try {
        $oldPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"

        & $engine image inspect $image 1>$null 2>$null
        $code = $LASTEXITCODE

        $ErrorActionPreference = $oldPref
        return ($code -eq 0)
    }
    catch {
        $ErrorActionPreference = $oldPref
        return $false
    }
}

function Pull-ImageWithFallback($engine, $image) {
    $mirrorImage = "$MIRROR_PREFIX/$image"

    if (Image-ExistsLocal $engine $image) {
        Log "Image already exists locally: $image"
        return
    }

    Log "Pulling official image: $image"
    & $engine pull $image
    if ($LASTEXITCODE -eq 0) {
        Log "Official image pulled successfully"
        return
    }

    Warn "Official pull failed, trying mirror: $mirrorImage"
    & $engine pull $mirrorImage
    if ($LASTEXITCODE -eq 0) {
        Log "Mirror image pulled successfully, tagging original image"
        & $engine tag $mirrorImage $image | Out-Null
        return
    }

    Fail "Image pull failed"
}

function Get-RunningContainersByImage($engine, $image) {
    $result = & $engine ps --filter "ancestor=$image" --format "{{.ID}}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }
    return @($result | Where-Object { $_ -and $_.Trim() -ne "" })
}

function Test-PortInUse($port) {
    try {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop
        return ($null -ne $conn)
    }
    catch {
        return $false
    }
}

function Ask-DeleteContainer($engine, $cid) {
    Write-Host ""
    Warn "Running container found for target image: $cid"
    Write-Host "Choose an action:"
    Write-Host "  d = delete this container and continue"
    Write-Host "  i = ignore this container and continue"
    Write-Host "  q = quit installer"

    while ($true) {
        $ans = Read-Host "Select [d/i/q]"
        if ([string]::IsNullOrWhiteSpace($ans)) {
            $ans = "q"
        }

        if ($ans -match '^[Dd]$') {
            Log "Deleting container: $cid"
            & $engine rm -f $cid | Out-Null
            return
        }
        elseif ($ans -match '^[Ii]$') {
            Log "Ignoring existing container"
            return
        }
        elseif ($ans -match '^[Qq]$') {
            Log "Quit installer"
            exit 0
        }
        else {
            Warn "Please enter d / i / q"
        }
    }
}

function Validate-ExistingRunningContainer($engine, $image) {
    $cids = Get-RunningContainersByImage $engine $image
    if ($cids.Count -eq 0) {
        return
    }

    foreach ($cid in $cids) {
        Ask-DeleteContainer $engine $cid
    }
}

function Ask-Port {
    while ($true) {
        $port = Read-Host "Enter port [default: $DEFAULT_PORT]"
        if ([string]::IsNullOrWhiteSpace($port)) {
            $port = $DEFAULT_PORT
        }

        if ($port -notmatch '^\d+$') {
            Warn "Port must be numeric"
            continue
        }

        $portNum = [int]$port
        if ($portNum -lt 1 -or $portNum -gt 65535) {
            Warn "Port must be between 1 and 65535"
            continue
        }

        return $portNum
    }
}

function Ask-ConfigDir {
    while ($true) {
        $inputDir = Read-Host "Enter config dir [default: $DEFAULT_CONFIG_DIR]"
        if ([string]::IsNullOrWhiteSpace($inputDir)) {
            $inputDir = $DEFAULT_CONFIG_DIR
        }

        $configDir = Expand-PathEx $inputDir

        if ((Test-Path $configDir) -and -not (Test-Path $configDir -PathType Container)) {
            Warn "Path exists but is not a directory: $configDir"
            continue
        }

        if (Test-Path $configDir -PathType Container) {
            while ($true) {
                $confirm = Read-Host "Directory exists: $configDir. Continue using it? [Y/n]"
                if ([string]::IsNullOrWhiteSpace($confirm)) {
                    $confirm = "Y"
                }

                if ($confirm -match '^[Yy]$') {
                    return $configDir
                }
                elseif ($confirm -match '^[Nn]$') {
                    break
                }
                else {
                    Warn "Please enter y or n"
                }
            }
            continue
        }

        return $configDir
    }
}

$ENGINE = Detect-Engine
$ARCH = Detect-Arch

if ($ARCH -eq "amd64") {
    $IMAGE = "ghcr.io/openclaw/openclaw:main-slim-amd64"
}
else {
    $IMAGE = "ghcr.io/openclaw/openclaw:main-slim-arm64"
}

Log "OS: windows"
Log "Engine: $ENGINE"
Log "Arch: $ARCH"
Log "Image: $IMAGE"

Pull-ImageWithFallback $ENGINE $IMAGE
Validate-ExistingRunningContainer $ENGINE $IMAGE

$PORT = Ask-Port

if (Test-PortInUse $PORT) {
    Fail "Port already in use: $PORT"
}

$CONFIG_DIR = Ask-ConfigDir
$WORKSPACE_DIR = Join-Path $CONFIG_DIR "workspace"

New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $WORKSPACE_DIR | Out-Null

$TOKEN = Read-Host "Enter token [leave empty to auto-generate]"
if ([string]::IsNullOrWhiteSpace($TOKEN)) {
    $TOKEN = New-RandomToken
}

$CONFIG_JSON = Join-Path $CONFIG_DIR "openclaw.json"
$HAD_CONFIG_JSON = Test-Path $CONFIG_JSON

Log "Configuration:"
Write-Host "  Engine        : $ENGINE"
Write-Host "  Arch          : $ARCH"
Write-Host "  Port          : $PORT"
Write-Host "  Config Dir    : $CONFIG_DIR"
Write-Host "  Workspace Dir : $WORKSPACE_DIR"
Write-Host "  Image         : $IMAGE"
Write-Host "  Container     : $CONTAINER_NAME"
Write-Host "  Token         : will be refreshed"

$runArgs = @(
    "run", "-d",
    "--name", $CONTAINER_NAME,
    "--restart", "unless-stopped",
    "--user", "1000:1000",
    "--cap-drop", "ALL",
    "--security-opt", "no-new-privileges:true",
    "--read-only",
    "--tmpfs", "/tmp:size=256m,mode=1777",
    "-e", "TZ=Asia/Shanghai",
    "-e", "OPENCLAW_TOKEN=$TOKEN",
    "-p", "127.0.0.1:$PORT`:18789",
    "-v", "${CONFIG_DIR}:/home/node/.openclaw:rw",
    "-v", "${WORKSPACE_DIR}:/home/node/.openclaw/workspace:rw",
    "--memory", "4g",
    "--cpus", "2",
    "--pids-limit", "512",
    $IMAGE
)

Log "Starting container..."
& $ENGINE @runArgs | Out-Null

Log "Waiting for initialization..."
Start-Sleep -Seconds 3

if ($HAD_CONFIG_JSON) {
    Log "Existing openclaw.json found, refreshing token..."
    & $ENGINE exec $CONTAINER_NAME sh -lc "openclaw config set gateway.auth.mode token" | Out-Null
    & $ENGINE exec $CONTAINER_NAME sh -lc "openclaw config set gateway.auth.token '$TOKEN'" | Out-Null

    Log "Restarting container to apply token..."
    & $ENGINE restart $CONTAINER_NAME | Out-Null
    Start-Sleep -Seconds 3
}

Log "Checking OpenClaw status..."
& $ENGINE exec $CONTAINER_NAME sh -lc "openclaw status" | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "OpenClaw started successfully"

    $dashboardOutput = & $ENGINE exec $CONTAINER_NAME sh -lc "NO_COLOR=1 openclaw dashboard --no-open 2>/dev/null"
    $loginLine = $dashboardOutput | Select-String "^Dashboard URL:"
    if ($loginLine) {
        $LOGIN_URL = ($loginLine -replace "^Dashboard URL:\s*", "").Trim()
        Write-Host "Access URL: $LOGIN_URL"
    }
    else {
        Warn "Could not get access URL automatically"
        Write-Host "Run manually:"
        Write-Host "  $ENGINE exec $CONTAINER_NAME openclaw dashboard --no-open"
    }

    Write-Host "Config Dir: $CONFIG_DIR"
    Write-Host "Workspace Dir: $WORKSPACE_DIR"
}
else {
    Warn "Status check failed, recent logs:"
    & $ENGINE logs --tail 10 $CONTAINER_NAME
    exit 1
}
