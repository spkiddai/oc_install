#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="openclaw"
DEFAULT_PORT="18789"
DEFAULT_CONFIG_DIR="$HOME/.openclaw"
MIRROR_PREFIX="dockerpull.org"

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

expand_path() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    echo "$HOME"
  elif [[ "$path" == "~/"* ]]; then
    echo "$HOME/${path#~/}"
  else
    echo "$path"
  fi
}

detect_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Linux) echo "linux" ;;
    Darwin) echo "macos" ;;
    *) fail "不支持的操作系统: $os" ;;
  esac
}

detect_engine() {
  if command -v podman >/dev/null 2>&1; then
    echo "podman"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    echo "docker"
    return
  fi

  fail "未检测到 podman 或 docker，请先安装。"
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) fail "不支持的处理器架构: $arch" ;;
  esac
}

random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
  fi
}

image_exists_local() {
  local engine="$1"
  local image="$2"
  "$engine" image inspect "$image" >/dev/null 2>&1
}

pull_image_with_fallback() {
  local engine="$1"
  local image="$2"
  local mirror_image="${MIRROR_PREFIX}/${image}"

  if image_exists_local "$engine" "$image"; then
    log "本地已存在镜像，无需拉取: $image"
    return 0
  fi

  log "开始拉取官方镜像: $image"
  if "$engine" pull "$image"; then
    log "官方镜像拉取成功"
    return 0
  fi

  warn "官方镜像拉取失败，尝试代理镜像: $mirror_image"
  if "$engine" pull "$mirror_image"; then
    log "代理镜像拉取成功，打标签为原始镜像"
    "$engine" tag "$mirror_image" "$image"
    return 0
  fi

  fail "镜像拉取失败。官方源和代理源均不可用。"
}

get_running_containers_by_image() {
  local engine="$1"
  local image="$2"
  "$engine" ps --filter "ancestor=${image}" --format '{{.ID}}'
}

port_in_use() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN -Pn >/dev/null 2>&1
    return $?
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -lnt | awk 'NR>1 {print $4}' | grep -Eq "(^|:)$port$"
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)$port$"
    return $?
  fi

  fail "无法检测端口占用，系统缺少 lsof/ss/netstat。"
}

container_uses_host_port() {
  local engine="$1"
  local cid="$2"
  local port="$3"
  local ports

  ports="$("$engine" port "$cid" 2>/dev/null || true)"
  echo "$ports" | grep -Eq "127\.0\.0\.1:${port}$"
}

check_container_runtime() {
  local engine="$1"
  local cid="$2"
  local port="$3"

  local user
  local read_only
  local security_opt

  user="$("$engine" inspect -f '{{.Config.User}}' "$cid" 2>/dev/null || true)"
  read_only="$("$engine" inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$cid" 2>/dev/null || echo "false")"
  security_opt="$("$engine" inspect -f '{{json .HostConfig.SecurityOpt}}' "$cid" 2>/dev/null || true)"

  [[ "$user" == "1000:1000" ]] || return 1
  [[ "$read_only" == "true" ]] || return 1
  [[ "$security_opt" == *"no-new-privileges"* ]] || return 1
  container_uses_host_port "$engine" "$cid" "$port" || return 1

  return 0
}

ask_delete_container() {
  local engine="$1"
  local cid="$2"
  local safe="$3"
  local ans=""
  local prompt=""

  echo
  warn "检测到目标镜像已有运行中容器: $cid"

  if [[ "$safe" == "yes" ]]; then
    echo "容器运行参数基本符合要求，建议保留现有容器。"
    prompt="是否删除该容器并继续部署? [y/N]: "
  else
    echo "容器运行参数不符合预期，建议删除后重建。"
    prompt="是否删除该容器并继续部署? [Y/n]: "
  fi

  while true; do
    printf "%s" "$prompt" >/dev/tty
    read -r ans </dev/tty || true

    if [[ -z "$ans" ]]; then
      if [[ "$safe" == "yes" ]]; then
        log "保留现有容器，脚本退出。"
        exit 0
      else
        ans="Y"
      fi
    fi

    case "$ans" in
      y|Y)
        log "删除容器: $cid"
        "$engine" rm -f "$cid" >/dev/null
        return 0
        ;;
      n|N)
        log "保留现有容器，脚本退出。"
        exit 0
        ;;
      *)
        warn "请输入 y 或 n"
        ;;
    esac
  done
}

validate_existing_running_container() {
  local engine="$1"
  local image="$2"
  local port="$3"
  local cids
  local cid

  cids="$(get_running_containers_by_image "$engine" "$image" || true)"
  [[ -z "$cids" ]] && return 1

  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue

    if check_container_runtime "$engine" "$cid" "$port"; then
      ask_delete_container "$engine" "$cid" "yes"
    else
      ask_delete_container "$engine" "$cid" "no"
    fi
  done <<< "$cids"

  return 1
}

ask_port() {
  local port

  while true; do
    read -r -p "请输入端口 [默认: ${DEFAULT_PORT}]: " port
    port="${port:-$DEFAULT_PORT}"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
      warn "端口必须是数字"
      continue
    fi

    if (( port < 1 || port > 65535 )); then
      warn "端口范围必须在 1-65535"
      continue
    fi

    echo "$port"
    return 0
  done
}

ask_config_dir() {
  local input
  local config_dir
  local default_dir

  default_dir="$(expand_path "$DEFAULT_CONFIG_DIR")"

  while true; do
    if [[ -d "$default_dir" ]]; then
      read -r -p "请输入配置目录 [默认禁用，因 ${default_dir} 已存在，需显式指定]: " input
      if [[ -z "$input" ]]; then
        warn "默认目录已存在，必须显式输入配置目录。若确实要使用默认目录，请手动输入: $DEFAULT_CONFIG_DIR"
        continue
      fi
    else
      read -r -p "请输入配置目录 [默认: ${DEFAULT_CONFIG_DIR}]: " input
      input="${input:-$DEFAULT_CONFIG_DIR}"
    fi

    config_dir="$(expand_path "$input")"

    if [[ -e "$config_dir" && ! -d "$config_dir" ]]; then
      warn "指定路径存在但不是目录: $config_dir"
      continue
    fi

    echo "$config_dir"
    return 0
  done
}

OS="$(detect_os)"
ENGINE="$(detect_engine)"
ARCH="$(detect_arch)"

if [[ "$ARCH" == "amd64" ]]; then
  IMAGE="ghcr.io/openclaw/openclaw:main-slim-amd64"
else
  IMAGE="ghcr.io/openclaw/openclaw:main-slim-arm64"
fi

log "检测到操作系统: $OS"
log "检测到容器引擎: $ENGINE"
log "检测到处理器架构: $ARCH"
log "目标镜像: $IMAGE"

PORT="$(ask_port)"

validate_existing_running_container "$ENGINE" "$IMAGE" "$PORT" || true

if port_in_use "$PORT"; then
  fail "宿主机端口已被占用: $PORT"
fi

pull_image_with_fallback "$ENGINE" "$IMAGE"

CONFIG_DIR="$(ask_config_dir)"
WORKSPACE_DIR="${CONFIG_DIR}/workspace"

mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR"
chmod 700 "$CONFIG_DIR" "$WORKSPACE_DIR"

read -r -p "请输入 Token [留空自动生成]: " TOKEN
TOKEN="${TOKEN:-$(random_token)}"

CONFIG_JSON="${CONFIG_DIR}/openclaw.json"
HAD_CONFIG_JSON="no"
if [[ -f "$CONFIG_JSON" ]]; then
  HAD_CONFIG_JSON="yes"
fi

if "$ENGINE" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  warn "检测到同名容器 ${CONTAINER_NAME}，将删除旧容器后重新创建。"
  "$ENGINE" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

log "配置如下:"
echo "  OS            : $OS"
echo "  Engine        : $ENGINE"
echo "  Arch          : $ARCH"
echo "  Port          : $PORT"
echo "  Config Dir    : $CONFIG_DIR"
echo "  Workspace Dir : $WORKSPACE_DIR"
echo "  Image         : $IMAGE"
echo "  Container     : $CONTAINER_NAME"
echo "  Token         : 将刷新为新值"

RUN_ARGS=(
  -d
  --name "$CONTAINER_NAME"
  --restart unless-stopped
  --user 1000:1000
  --cap-drop ALL
  --security-opt no-new-privileges:true
  --read-only
  --tmpfs /tmp:size=256m,mode=1777
  -e TZ=Asia/Shanghai
  -e OPENCLAW_TOKEN="$TOKEN"
  -p "127.0.0.1:${PORT}:18789"
  -v "${CONFIG_DIR}:/home/node/.openclaw:rw"
  -v "${WORKSPACE_DIR}:/home/node/.openclaw/workspace:rw"
  -v /etc/localtime:/etc/localtime:ro
  --memory 4g
  --cpus 2
  --pids-limit 512
)

log "启动 OpenClaw 容器..."
"$ENGINE" run "${RUN_ARGS[@]}" "$IMAGE" >/dev/null

log "容器已启动，等待服务初始化..."
sleep 3

if [[ "$HAD_CONFIG_JSON" == "yes" ]]; then
  log "检测到已有 openclaw.json，强制刷新 Token..."
  "$ENGINE" exec "$CONTAINER_NAME" sh -lc "openclaw config set gateway.auth.mode token"
  "$ENGINE" exec "$CONTAINER_NAME" sh -lc "openclaw config set gateway.auth.token '$TOKEN'"

  log "重启容器使新 Token 生效..."
  "$ENGINE" restart "$CONTAINER_NAME" >/dev/null
  sleep 3
fi

log "执行 openclaw status 检查状态..."
if "$ENGINE" exec "$CONTAINER_NAME" sh -lc 'openclaw status'; then
  echo
  echo "OpenClaw 启动成功"

  LOGIN_URL="$(
    "$ENGINE" exec "$CONTAINER_NAME" sh -lc \
    "NO_COLOR=1 openclaw dashboard --no-open 2>/dev/null | grep -m1 '^Dashboard URL:' | sed 's/^Dashboard URL: //'"
  )"

  if [[ -n "$LOGIN_URL" ]]; then
    echo "访问地址: ${LOGIN_URL}"
  else
    warn "无法自动获取访问地址，请执行:"
    echo "  $ENGINE exec $CONTAINER_NAME openclaw dashboard --no-open"
  fi

  echo "配置目录: ${CONFIG_DIR}"
  echo "工作目录: ${WORKSPACE_DIR}"

else
  warn "状态检查失败，输出最近日志："
  "$ENGINE" logs --tail 100 "$CONTAINER_NAME" || true
  exit 1
fi
