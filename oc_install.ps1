$ErrorActionPreference = "Stop"

$CONTAINER_NAME = "oc_" + (-join ((97..122 + 48..57) | Get-Random -Count 8 | ForEach-Object {[char]$_}))
$DEFAULT_PORT = 18789
$DEFAULT_CONFIG_DIR = Join-Path $HOME ".openclaw"
$MIRROR_PREFIX = "dockerpull.org"

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

function Detect-OS {
    if ($IsWindows) {
        return "windows"
    }
    Fail "不支持的操作系统"
}

function Test-Cmd($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Detect-Engine {
    if (Test-Cmd "podman") { return "podman" }
    if (Test-Cmd "docker") { return "docker" }
    Fail "未检测到 podman 或 docker，请先安装。"
}

function Detect-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    switch -Regex ($arch) {
        "AMD64|x86_64" { return "amd64" }
        "ARM64" { return "arm64" }
        default { Fail "不支持的处理器架构: $arch" }
    }
}

function New-RandomToken {
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".ToCharArray()
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Image-ExistsLocal($engine, $image) {
    & $engine image inspect $image *> $null
    return ($LASTEXITCODE -eq 0)
}

function Pull-ImageWithFallback($engine, $image) {
    $mirrorImage = "$MIRROR_PREFIX/$image"

    if (Image-ExistsLocal $engine $image) {
        Log "本地已存在镜像，无需拉取: $image"
        return
    }

    Log "开始拉取官方镜像: $image"
    & $engine pull $image
    if ($LASTEXITCODE -eq 0) {
        Log "官方镜像拉取成功"
        return
    }

    Warn "官方镜像拉取失败，尝试代理镜像: $mirrorImage"
    & $engine pull $mirrorImage
    if ($LASTEXITCODE -eq 0) {
        Log "代理镜像拉取成功，打标签为原始镜像"
        & $engine tag $mirrorImage $image | Out-Null
        return
    }

    Fail "镜像拉取失败。官方源和代理源均不可用。"
}

function Get-RunningContainersByImage($engine, $image) {
    $result = & $engine ps --filter "ancestor=$image" --format "{{.ID}}" 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($result | Where-Object { $_ -and $_.Trim() -ne "" })
}

function Test-PortInUse($port) {
    try {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop
        return ($null -ne $conn)
    } catch {
        return $false
    }
}

function Ask-DeleteContainer($engine, $cid) {
    Write-Host ""
    Warn "检测到目标镜像已有运行中容器: $cid"
    Write-Host "请选择后续操作："
    Write-Host "  d = 删除该容器并继续部署"
    Write-Host "  i = 忽略该容器，继续安装"
    Write-Host "  q = 退出安装"

    while ($true) {
        $ans = Read-Host "请选择操作 [d/i/q]"
        if ([string]::IsNullOrWhiteSpace($ans)) {
            $ans = "q"
        }

        switch -Regex ($ans) {
            "^[Dd]$" {
                Log "删除容器: $cid"
                & $engine rm -f $cid | Out-Null
                return
            }
            "^[Ii]$" {
                Log "忽略现有容器，继续安装。"
                return
            }
            "^[Qq]$" {
                Log "退出安装。"
                exit 0
            }
            default {
                Warn "请输入 d / i / q"
            }
        }
    }
}

function Validate-ExistingRunningContainer($engine, $image) {
    $cids = Get-RunningContainersByImage $engine $image
    if ($cids.Count -eq 0) { return }

    foreach ($cid in $cids) {
        Ask-DeleteContainer $engine $cid
    }
}

function Ask-Port {
    while ($true) {
        $port = Read-Host "请输入端口 [默认: $DEFAULT_PORT]"
        if ([string]::IsNullOrWhiteSpace($port)) {
            $port = $DEFAULT_PORT
        }

        if ($port -notmatch '^\d+$') {
            Warn "端口必须是数字"
            continue
        }

        $portNum = [int]$port
        if ($portNum -lt 1 -or $portNum -gt 65535) {
            Warn "端口范围必须在 1-65535"
            continue
        }

        return $portNum
    }
}

function Ask-ConfigDir {
    while ($true) {
        $inputDir = Read-Host "请输入配置目录 [默认: $DEFAULT_CONFIG_DIR]"
        if ([string]::IsNullOrWhiteSpace($inputDir)) {
            $inputDir = $DEFAULT_CONFIG_DIR
        }

        $configDir = Expand-PathEx $inputDir

        if ((Test-Path $configDir) -and -not (Test-Path $configDir -PathType Container)) {
            Warn "指定路径存在但不是目录: $configDir"
            continue
        }

        if (Test-Path $configDir -PathType Container) {
            while ($true) {
                $confirm = Read-Host "目录已存在: $configDir，是否继续使用该目录? [Y/n]"
                if ([string]::IsNullOrWhiteSpace($confirm)) {
                    $confirm = "Y"
                }

                switch -Regex ($confirm) {
                    "^[Yy]$" { return $configDir }
                    "^[Nn]$" { break }
                    default { Warn "请输入 y 或 n" }
                }
            }
            continue
        }

        return $configDir
    }
}

$OS = Detect-OS
$ENGINE = Detect-Engine
$ARCH = Detect-Arch

if ($ARCH -eq "amd64") {
    $IMAGE = "ghcr.io/openclaw/openclaw:main-slim-amd64"
} else {
    $IMAGE = "ghcr.io/openclaw/openclaw:main-slim-arm64"
}

Log "检测到操作系统: $OS"
Log "检测到容器引擎: $ENGINE"
Log "检测到处理器架构: $ARCH"
Log "目标镜像: $IMAGE"

Pull-ImageWithFallback $ENGINE $IMAGE
Validate-ExistingRunningContainer $ENGINE $IMAGE

$PORT = Ask-Port

if (Test-PortInUse $PORT) {
    Fail "宿主机端口已被占用: $PORT"
}

$CONFIG_DIR = Ask-ConfigDir
$WORKSPACE_DIR = Join-Path $CONFIG_DIR "workspace"

New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $WORKSPACE_DIR | Out-Null

$TOKEN = Read-Host "请输入 Token [留空自动生成]"
if ([string]::IsNullOrWhiteSpace($TOKEN)) {
    $TOKEN = New-RandomToken
}

$CONFIG_JSON = Join-Path $CONFIG_DIR "openclaw.json"
$HAD_CONFIG_JSON = Test-Path $CONFIG_JSON

Log "配置如下:"
Write-Host "  OS            : $OS"
Write-Host "  Engine        : $ENGINE"
Write-Host "  Arch          : $ARCH"
Write-Host "  Port          : $PORT"
Write-Host "  Config Dir    : $CONFIG_DIR"
Write-Host "  Workspace Dir : $WORKSPACE_DIR"
Write-Host "  Image         : $IMAGE"
Write-Host "  Container     : $CONTAINER_NAME"
Write-Host "  Token         : 将刷新为新值"

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

Log "启动 OpenClaw 容器..."
& $ENGINE @runArgs | Out-Null

Log "容器已启动，等待服务初始化..."
Start-Sleep -Seconds 3

if ($HAD_CONFIG_JSON) {
    Log "检测到已有 openclaw.json，强制刷新 Token..."
    & $ENGINE exec $CONTAINER_NAME sh -lc "openclaw config set gateway.auth.mode token" | Out-Null
    & $ENGINE exec $CONTAINER_NAME sh -lc "openclaw config set gateway.auth.token '$TOKEN'" | Out-Null

    Log "重启容器使新 Token 生效..."
    & $ENGINE restart $CONTAINER_NAME | Out-Null
    Start-Sleep -Seconds 3
}

Log "执行 openclaw status 检查状态..."
& $ENGINE exec $CONTAINER_NAME sh -lc "openclaw status" | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "OpenClaw 启动成功"

    $dashboardOutput = & $ENGINE exec $CONTAINER_NAME sh -lc "NO_COLOR=1 openclaw dashboard --no-open 2>/dev/null"
    $loginLine = $dashboardOutput | Select-String "^Dashboard URL:"
    if ($loginLine) {
        $LOGIN_URL = ($loginLine -replace "^Dashboard URL:\s*", "").Trim()
        Write-Host "访问地址: $LOGIN_URL"
    } else {
        Warn "无法自动获取访问地址，请执行:"
        Write-Host "  $ENGINE exec $CONTAINER_NAME openclaw dashboard --no-open"
    }

    Write-Host "配置目录: $CONFIG_DIR"
    Write-Host "工作目录: $WORKSPACE_DIR"
}
else {
    Warn "状态检查失败，输出最近日志："
    & $ENGINE logs --tail 10 $CONTAINER_NAME
    exit 1
}
