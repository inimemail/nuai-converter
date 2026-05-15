#!/usr/bin/env bash

set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

APP_NAME="NUAI Converter"
DEFAULT_INSTALL_PATH="/opt/nuai-converter"
ENV_RECORD_FILE="/etc/nuai_converter_env"

CONTAINER_NAME="nuai-converter"
SERVICE_NAME="nuai-web"
IMAGE_NAME="nuai-converter-local:latest"
SOURCE_DIR_NAME="source"
SOURCE_REPO_URL="${SOURCE_REPO_URL:-}"
SOURCE_REPO_BRANCH="${SOURCE_REPO_BRANCH:-main}"
DEFAULT_WEB_PORT="${DEFAULT_WEB_PORT:-41739}"

CRON_TAG_BEGIN="# NUAI_CONVERTER_BACKUP_BEGIN"
CRON_TAG_END="# NUAI_CONVERTER_BACKUP_END"
BACKUP_LOG="/var/log/nuai_converter_backup.log"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少依赖: $1"
}

get_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"
    else
        return 1
    fi
}

find_free_port() {
    local start="$1"
    local p="$start"
    while [[ "$p" -le 65535 ]]; do
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
        p=$((p + 1))
    done
    return 1
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        die "未检测到 Docker Compose，请先安装 docker compose 或 docker-compose"
    fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || true
}

get_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
}

find_project_root() {
    if [[ -n "${PROJECT_ROOT:-}" && -f "${PROJECT_ROOT}/Dockerfile" && -f "${PROJECT_ROOT}/docs/index.html" ]]; then
        cd "$PROJECT_ROOT" >/dev/null 2>&1 && pwd
        return 0
    fi

    local script_dir
    script_dir="$(get_script_dir)"
    if [[ -f "${script_dir}/Dockerfile" && -f "${script_dir}/docs/index.html" ]]; then
        echo "$script_dir"
        return 0
    fi

    if [[ -f "${PWD}/Dockerfile" && -f "${PWD}/docs/index.html" ]]; then
        pwd
        return 0
    fi

    return 1
}

sync_project_source() {
    local workdir="$1"
    local dest="${workdir}/${SOURCE_DIR_NAME}"
    local project_root=""

    if project_root="$(find_project_root)"; then
        mkdir -p "$dest"
        info "同步当前源码到 ${dest} ..."
        tar \
            --exclude='./.git' \
            --exclude='./node_modules' \
            --exclude='./dist' \
            --exclude='./build' \
            --exclude='./coverage' \
            --exclude='./.env' \
            --exclude='./.env.*' \
            --exclude='./backups' \
            --exclude='./*.session.json' \
            --exclude='./session*.json' \
            --exclude='./sessions*.json' \
            --exclude='./token*.json' \
            --exclude='./tokens*.json' \
            --exclude='./auth*.json' \
            --exclude='./credentials*.json' \
            -cf - -C "$project_root" . | tar -xf - -C "$dest"

        cp "${BASH_SOURCE[0]}" "${workdir}/deploy.sh" 2>/dev/null || true
        chmod +x "${workdir}/deploy.sh" 2>/dev/null || true
        return 0
    fi

    if [[ -d "${dest}/.git" ]]; then
        [[ -n "$SOURCE_REPO_URL" ]] || die "未设置 SOURCE_REPO_URL，无法从 git 更新源码"
        require_cmd git
        info "从 ${SOURCE_REPO_URL} (${SOURCE_REPO_BRANCH}) 更新源码 ..."
        git -C "$dest" fetch --depth 1 origin "$SOURCE_REPO_BRANCH" || return 1
        git -C "$dest" checkout -f FETCH_HEAD || return 1
        cp "${BASH_SOURCE[0]}" "${workdir}/deploy.sh" 2>/dev/null || true
        chmod +x "${workdir}/deploy.sh" 2>/dev/null || true
        return 0
    fi

    if [[ -f "${dest}/Dockerfile" && -f "${dest}/docs/index.html" ]]; then
        warn "未找到当前源码目录，继续使用已有源码: ${dest}"
        return 0
    fi

    if [[ -n "$SOURCE_REPO_URL" ]]; then
        require_cmd git
        info "克隆 ${SOURCE_REPO_URL} (${SOURCE_REPO_BRANCH}) 到 ${dest} ..."
        mkdir -p "$workdir"
        rm -rf "$dest"
        git clone --depth 1 --branch "$SOURCE_REPO_BRANCH" "$SOURCE_REPO_URL" "$dest" || return 1
        cp "${BASH_SOURCE[0]}" "${workdir}/deploy.sh" 2>/dev/null || true
        chmod +x "${workdir}/deploy.sh" 2>/dev/null || true
        return 0
    fi

    die "未找到项目源码。请在项目根目录执行本脚本，或设置 PROJECT_ROOT=/path/to/project"
}

read_env_value() {
    local file="$1"
    local key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

create_env_file() {
    local workdir="$1"
    local host_port="$2"

    cat > "${workdir}/.env" <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
EOF
    chmod 600 "${workdir}/.env"
}

create_compose_file() {
    local workdir="$1"

    cat > "${workdir}/docker-compose.yml" <<EOF
services:
  ${SERVICE_NAME}:
    build:
      context: ./${SOURCE_DIR_NAME}
      dockerfile: Dockerfile
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "\${PORT}:80"
    environment:
      - TZ=\${TZ}
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
EOF
}

show_access() {
    local workdir="$1"
    local env_file="${workdir}/.env"
    local host_port
    host_port="$(read_env_value "$env_file" PORT)"
    host_port="${host_port:-$DEFAULT_WEB_PORT}"

    echo ""
    echo "=================================================="
    echo -e "\033[32m${APP_NAME} 已就绪\033[0m"
    echo "--------------------------------------------------"
    echo -e "访问地址: \033[36mhttp://$(get_local_ip):${host_port}\033[0m"
    echo -e "安装目录: \033[33m${workdir}\033[0m"
    echo -e "源码目录: \033[33m${workdir}/${SOURCE_DIR_NAME}\033[0m"
    echo -e "环境文件: \033[33m${workdir}/.env\033[0m"
    echo "--------------------------------------------------"
    echo "端口映射: ${host_port} -> 80"
    echo "修改端口: 编辑 ${workdir}/.env 的 PORT 后执行重启"
    echo "=================================================="
    echo ""
}

wait_app_ready() {
    local workdir="$1"
    local host_port
    host_port="$(read_env_value "${workdir}/.env" PORT)"
    host_port="${host_port:-$DEFAULT_WEB_PORT}"

    info "等待 ${APP_NAME} 启动 ..."
    for _ in $(seq 1 40); do
        if docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${CONTAINER_NAME} .*Up"; then
            if command -v curl >/dev/null 2>&1; then
                curl -fsS "http://127.0.0.1:${host_port}/" >/dev/null 2>&1 && return 0
            else
                return 0
            fi
        fi
        sleep 2
    done

    warn "${APP_NAME} 可能未正常启动，最近日志如下:"
    docker logs --tail=100 "$CONTAINER_NAME" 2>/dev/null || true
    return 1
}

deploy_service() {
    info "开始部署 ${APP_NAME}"

    require_cmd docker
    require_cmd awk
    require_cmd tar

    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"

    read -r -p "安装目录 [默认: ${DEFAULT_INSTALL_PATH}]: " input_path
    local install_path="${input_path:-$DEFAULT_INSTALL_PATH}"

    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        if [[ -f "${install_path}/docker-compose.yml" ]]; then
            err "安装目录已存在部署数据: ${install_path}"
            err "请选择其他目录，或先执行卸载"
            return
        fi
        warn "目录已存在但不是完整部署，将继续复用: ${install_path}"
    fi

    read -r -p "Web 端口 [默认: ${DEFAULT_WEB_PORT}]: " input_port
    local host_port="${input_port:-$DEFAULT_WEB_PORT}"
    valid_port "$host_port" || die "端口无效，必须是 1-65535"

    if port_in_use "$host_port"; then
        local old_port="$host_port"
        host_port="$(find_free_port "$host_port")" || die "未找到可用端口"
        warn "端口 ${old_port} 已被占用，自动改用 ${host_port}"
    fi

    mkdir -p "$install_path" "${install_path}/backups"
    cd "$install_path" || return
    echo "$install_path" > "$ENV_RECORD_FILE"

    create_env_file "$install_path" "$host_port"
    sync_project_source "$install_path"
    create_compose_file "$install_path"

    info "构建镜像并启动容器 ..."
    $dc_cmd build || die "镜像构建失败"
    $dc_cmd up -d || die "容器启动失败"

    wait_app_ready "$install_path" || true
    show_access "$install_path"
}

upgrade_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未检测到部署环境，请先执行部署"; return; }

    local dc_cmd
    dc_cmd="$(docker_compose_cmd)"

    cd "$workdir" || return
    [[ -f "${workdir}/.env" ]] || create_env_file "$workdir" "$DEFAULT_WEB_PORT"

    sync_project_source "$workdir"
    create_compose_file "$workdir"

    info "重新构建并升级服务 ..."
    $dc_cmd build || die "镜像构建失败"
    $dc_cmd up -d || die "服务启动失败"

    wait_app_ready "$workdir" || true
    show_access "$workdir"
}

stop_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未检测到部署环境"; return; }

    cd "$workdir" || return
    $(docker_compose_cmd) stop
    info "服务已停止"
}

restart_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未检测到部署环境"; return; }

    cd "$workdir" || return
    $(docker_compose_cmd) restart
    wait_app_ready "$workdir" || true
    show_access "$workdir"
}

show_logs() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未检测到部署环境"; return; }

    cd "$workdir" || return
    $(docker_compose_cmd) logs --tail=120
}

do_backup() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未检测到部署环境"; return; }

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    local temp_dir="${backup_dir}/tmp_${timestamp}"
    local backup_file="${backup_dir}/nuai_converter_backup_${timestamp}.tar.gz"

    mkdir -p "$temp_dir"
    cp "${workdir}/docker-compose.yml" "${temp_dir}/" 2>/dev/null || true
    cp "${workdir}/.env" "${temp_dir}/" 2>/dev/null || true
    cp "${workdir}/deploy.sh" "${temp_dir}/deploy.sh" 2>/dev/null || true
    [[ -d "${workdir}/${SOURCE_DIR_NAME}" ]] && cp -a "${workdir}/${SOURCE_DIR_NAME}" "${temp_dir}/${SOURCE_DIR_NAME}"

    tar -czf "$backup_file" -C "$temp_dir" .
    rm -rf "$temp_dir"

    find "$backup_dir" -maxdepth 1 -name 'nuai_converter_backup_*.tar.gz' -type f \
        | sort -r \
        | awk 'NR>5' \
        | xargs -r rm -f

    info "备份完成: ${backup_file}"
}

restore_backup() {
    local workdir
    workdir="$(get_workdir)"

    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    local default_backup
    default_backup="$(ls -t "${search_dir}"/nuai_converter_backup_*.tar.gz 2>/dev/null | head -n 1 || true)"

    read -r -p "备份文件路径 [回车使用默认: ${default_backup}]: " backup_path
    local path="${backup_path:-$default_backup}"
    [[ -f "$path" ]] || { err "未找到有效备份文件"; return; }

    read -r -p "恢复到目录 [默认: ${DEFAULT_INSTALL_PATH}]: " target_dir
    local wd="${target_dir:-$DEFAULT_INSTALL_PATH}"
    [[ -n "$wd" && "$wd" != "/" ]] || die "恢复目录不安全"

    if [[ -d "$wd" ]]; then
        read -r -p "目标目录已存在，是否覆盖? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return
        cd "$wd" 2>/dev/null && $(docker_compose_cmd) down 2>/dev/null || true
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        rm -rf "$wd"
    fi

    mkdir -p "$wd"
    tar -xzf "$path" -C "$wd" || die "备份解压失败"
    mkdir -p "${wd}/backups"
    cp "$path" "${wd}/backups/$(basename "$path")" 2>/dev/null || true
    echo "$wd" > "$ENV_RECORD_FILE"

    [[ -f "${wd}/.env" ]] || create_env_file "$wd" "$DEFAULT_WEB_PORT"
    [[ -f "${wd}/docker-compose.yml" ]] || create_compose_file "$wd"
    [[ -d "${wd}/${SOURCE_DIR_NAME}" ]] || sync_project_source "$wd"

    cd "$wd" || return
    $(docker_compose_cmd) build || die "镜像构建失败"
    $(docker_compose_cmd) up -d || die "容器启动失败"

    wait_app_ready "$wd" || true
    show_access "$wd"
}

setup_auto_backup() {
    require_cmd crontab

    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未检测到部署环境"; return; }

    local cron_script="${workdir}/cron_backup.sh"
    local script_path="${workdir}/deploy.sh"

    echo "1) 每隔固定分钟备份"
    echo "2) 每天固定时间备份"
    echo "3) 删除当前定时备份任务"
    read -r -p "请选择 [1/2/3]: " cron_type

    local cron_spec=""
    case "$cron_type" in
        1)
            read -r -p "备份间隔分钟数 [例如 30]: " min_interval
            [[ "$min_interval" =~ ^[0-9]+$ && "$min_interval" -ge 1 && "$min_interval" -le 1440 ]] || { err "分钟数无效"; return; }
            cron_spec="*/${min_interval} * * * *"
        ;;
        2)
            read -r -p "每天备份时间 HH:MM [例如 04:30]: " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ && "$hour" -le 23 && "$minute" -le 59 ]] || { err "时间格式无效"; return; }
            cron_spec="${minute} ${hour} * * *"
        ;;
        3)
            crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true
            rm -f "$cron_script"
            info "定时备份任务已删除"
            return
        ;;
        *)
            err "无效选择"
            return
        ;;
    esac

    cat > "$cron_script" <<EOF
#!/usr/bin/env bash
bash "$script_path" run-backup >> "$BACKUP_LOG" 2>&1
EOF
    chmod +x "$cron_script"

    (
        crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"
        echo "$CRON_TAG_BEGIN"
        echo "${cron_spec} bash ${cron_script}"
        echo "$CRON_TAG_END"
    ) | crontab -

    info "定时备份任务已写入"
}

uninstall_service() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && workdir="$DEFAULT_INSTALL_PATH"

    echo -e "\033[31m警告：这会删除容器和本地部署目录: ${workdir}\033[0m"
    read -r -p "确认完全卸载? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return
    [[ -n "$workdir" && "$workdir" != "/" ]] || die "卸载目录不安全"

    if [[ -d "$workdir" ]]; then
        cd "$workdir" 2>/dev/null && $(docker_compose_cmd) down 2>/dev/null || true
    fi

    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    rm -rf "$workdir"
    rm -f "$ENV_RECORD_FILE"
    crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true

    info "卸载完成"
}

change_port() {
    local workdir
    workdir="$(get_workdir)"
    [[ -z "$workdir" ]] && { err "未检测到部署环境"; return; }

    read -r -p "请输入新端口: " new_port
    valid_port "$new_port" || { err "端口无效"; return; }
    if port_in_use "$new_port"; then
        err "端口 ${new_port} 已被占用"
        return
    fi

    create_env_file "$workdir" "$new_port"
    restart_service
}

main_menu() {
    clear
    echo "==================================================="
    echo "              ${APP_NAME} 一键部署管理"
    echo "==================================================="
    local wd
    wd="$(get_workdir)"
    echo -e "部署路径: \033[36m${wd:-未部署}\033[0m"
    echo "默认端口: ${DEFAULT_WEB_PORT}"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 修改端口"
    echo "  9) 查看日志"
    echo " 10) 完全卸载"
    echo "  0) 退出"
    echo "==================================================="
    read -r -p "请输入操作序号 [0-10]: " choice

    case "$choice" in
        1) deploy_service ;;
        2) upgrade_service ;;
        3) stop_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) change_port ;;
        9) show_logs ;;
        10) uninstall_service ;;
        0) info "已退出"; exit 0 ;;
        *) warn "无效选择，请重新输入" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then
        die "请使用 root 权限执行，例如: sudo bash deploy.sh"
    fi

    while true; do
        main_menu
        echo ""
        read -r -p "按回车返回主菜单..."
    done
fi
