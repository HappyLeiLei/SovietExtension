#!/bin/bash

# 如果用户用 sh install.sh 执行，自动切换到 bash
# If user runs this script with sh, re-exec with bash.
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

set -euo pipefail

# ==============================
# SovietExtension installer
# ==============================

APP_NAME="WeChat"
FRAMEWORK_NAME="${FRAMEWORK_NAME:-SovietExtension}"
APP_PATH="/Applications/${APP_NAME}.app"

FORCE=0
RUN_SUDO=0

# 运行时变量，后面会赋值
APP_SHORT_VERSION=""
APP_BUILD_VERSION=""
MATCHED_DISPLAY_VERSION=""
MATCHED_LINE=""
BACKUP_PATH=""
TARGET_ARCH=""
HOST_ARCH=""

die() {
    echo ""
    echo "❌ [ERROR] $*" >&2
    echo ""
    exit 1
}

warn() {
    echo "⚠️  [WARN] $*"
}

ok() {
    echo "✅ [OK] $*"
}

info() {
    echo "👉 [INFO] $*"
}

on_error() {
    local exit_code="$?"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local cmd="${BASH_COMMAND:-unknown}"

    echo ""
    echo "❌ [ERROR] Install failed / 安装失败"
    echo "    Exit Code: ${exit_code}"
    echo "    Line:      ${line_no}"
    echo "    Command:   ${cmd}"
    echo ""

    if echo "${cmd}" | grep -q "insert_dylib"; then
        echo "💡 Hint / 提示："
        echo "    如果你看到 Bad CPU type in executable，通常是 insert_dylib 的架构不匹配。"
        echo "    Apple Silicon 机器需要 arm64 或 universal 的 insert_dylib。"
        echo "    Intel 机器需要 x86_64 或 universal 的 insert_dylib。"
        echo ""
        echo "    你可以执行："
        echo "      file \"${INSERT_DYLIB_PATH:-./insert_dylib}\""
        echo "      uname -m"
        echo ""
    fi

    exit "${exit_code}"
}
trap on_error ERR

usage() {
    cat <<EOF
Usage:
  ./install.sh
  sh install.sh
  ./install.sh --force
  ./install.sh --app=/Applications/WeChat.app

Options:
  --force              Ignore version check and some non-fatal checks / 忽略版本检查和部分非致命检查
  --app=PATH           Specify WeChat.app path / 指定 WeChat.app 路径
  --framework=NAME     Specify framework name, default: SovietExtension / 指定插件名，默认 SovietExtension
  -h, --help           Show help / 显示帮助

Examples:
  ./install.sh
  ./install.sh --force
  ./install.sh --app="/Users/xxx/Applications/WeChat.app"

EOF
}

run_cmd() {
    if [ "${RUN_SUDO}" -eq 1 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

run_cmd_quiet() {
    if [ "${RUN_SUDO}" -eq 1 ]; then
        sudo "$@" >/dev/null 2>&1
    else
        "$@" >/dev/null 2>&1
    fi
}

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=1
            ;;
        --app=*)
            APP_PATH="${arg#--app=}"
            ;;
        --framework=*)
            FRAMEWORK_NAME="${arg#--framework=}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument / 未知参数: ${arg}"
            ;;
    esac
done

APP_PATH="${APP_PATH%/}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MACOS_PATH="${APP_PATH}/Contents/MacOS"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
APP_EXECUTABLE_PATH="${MACOS_PATH}/${APP_NAME}"

PLUGIN_SRC_PATH="${SCRIPT_DIR}/Plugin/${FRAMEWORK_NAME}.framework"
PLUGIN_SRC_BINARY_PATH="${PLUGIN_SRC_PATH}/${FRAMEWORK_NAME}"
FRAMEWORK_DST_PATH="${MACOS_PATH}/${FRAMEWORK_NAME}.framework"
FRAMEWORK_DST_BINARY_PATH="${FRAMEWORK_DST_PATH}/${FRAMEWORK_NAME}"

INSERT_DYLIB_PATH="${SCRIPT_DIR}/insert_dylib"
SUPPORTED_FILE="${SCRIPT_DIR}/supported_versions.txt"

LOAD_DYLIB_PATH="@executable_path/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
STATE_FILE="${MACOS_PATH}/.${FRAMEWORK_NAME}.install_state"

LOG_PATH="/tmp/YMWeChatAntiRevokePatch.log"

read_plist() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Print :${key}" "${INFO_PLIST}" 2>/dev/null || true
}

trim() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_build_token() {
    local value="$1"

    if [ "${value}" = "*" ]; then
        return 0
    fi

    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    return 1
}

command_required() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1 || die "Command not found / 命令不存在: ${cmd}"
}

check_required_commands() {
    info "Check required commands / 检查必要命令..."

    command_required /usr/libexec/PlistBuddy
    command_required cp
    command_required rm
    command_required chmod
    command_required ditto
    command_required xattr
    command_required otool
    command_required codesign
    command_required file
    command_required grep
    command_required sed
    command_required uname
    command_required pkill
    command_required pgrep
    command_required osascript

    ok "Required commands exist / 必要命令存在"
}

check_basic_files() {
    info "Check files / 检查文件..."

    [ -d "${APP_PATH}" ] || die "WeChat.app not found / 找不到 WeChat.app: ${APP_PATH}"
    [ -f "${INFO_PLIST}" ] || die "Info.plist not found / 找不到 Info.plist: ${INFO_PLIST}"
    [ -f "${APP_EXECUTABLE_PATH}" ] || die "WeChat executable not found / 找不到微信主可执行文件: ${APP_EXECUTABLE_PATH}"

    [ -d "${PLUGIN_SRC_PATH}" ] || die "Plugin framework not found / 找不到插件 framework: ${PLUGIN_SRC_PATH}"
    [ -f "${PLUGIN_SRC_BINARY_PATH}" ] || die "Framework binary not found / framework 内找不到同名二进制: ${PLUGIN_SRC_BINARY_PATH}"

    [ -f "${INSERT_DYLIB_PATH}" ] || die "insert_dylib not found / 找不到 insert_dylib: ${INSERT_DYLIB_PATH}"
    [ -f "${SUPPORTED_FILE}" ] || die "supported_versions.txt not found / 找不到版本控制文件: ${SUPPORTED_FILE}"

    ok "Files look good / 文件检查通过"
}

get_archs() {
    local binary_path="$1"
    local archs=""

    if command -v lipo >/dev/null 2>&1; then
        archs="$(lipo -archs "${binary_path}" 2>/dev/null || true)"
    fi

    if [ -n "${archs}" ]; then
        echo "${archs}"
        return 0
    fi

    file "${binary_path}" 2>/dev/null | sed -n 's/.*executable \([^ ]*\).*/\1/p' || true
}

binary_contains_arch() {
    local binary_path="$1"
    local wanted_arch="$2"
    local archs=""

    archs="$(get_archs "${binary_path}")"

    for arch in ${archs}; do
        if [ "${arch}" = "${wanted_arch}" ]; then
            return 0
        fi
    done

    file "${binary_path}" 2>/dev/null | grep -qw "${wanted_arch}" && return 0

    return 1
}

print_binary_arch() {
    local title="$1"
    local path="$2"

    echo "    ${title}:"
    echo "      Path:  ${path}"
    echo "      Archs: $(get_archs "${path}")"
    echo "      File:  $(file "${path}" 2>/dev/null || true)"
}

check_arch_compatibility() {
    HOST_ARCH="$(uname -m)"

    info "Check architecture compatibility / 检查架构兼容性..."

    echo "    Host Arch / 当前机器架构: ${HOST_ARCH}"
    print_binary_arch "WeChat executable / 微信主程序" "${APP_EXECUTABLE_PATH}"
    print_binary_arch "Plugin framework / 插件 framework" "${PLUGIN_SRC_BINARY_PATH}"
    print_binary_arch "insert_dylib" "${INSERT_DYLIB_PATH}"
    echo ""

    # 1. 确定 WeChat 实际可能运行的目标架构
    if binary_contains_arch "${APP_EXECUTABLE_PATH}" "${HOST_ARCH}"; then
        TARGET_ARCH="${HOST_ARCH}"
    elif [ "${HOST_ARCH}" = "arm64" ] && binary_contains_arch "${APP_EXECUTABLE_PATH}" "x86_64"; then
        TARGET_ARCH="x86_64"
        warn "WeChat does not contain arm64, fallback target arch is x86_64 / 当前微信不含 arm64，将按 x86_64 检查插件"
    else
        die "WeChat executable does not support current machine arch / 微信主程序不支持当前机器架构: ${HOST_ARCH}"
    fi

    echo "    Target WeChat Runtime Arch / 预计微信运行架构: ${TARGET_ARCH}"

    # 2. insert_dylib 是安装时要执行的工具，它必须能在当前机器上跑
    if ! binary_contains_arch "${INSERT_DYLIB_PATH}" "${HOST_ARCH}"; then
        if [ "${FORCE}" -eq 1 ]; then
            warn "insert_dylib does not contain ${HOST_ARCH}, but --force is enabled / insert_dylib 不含当前架构，但 --force 已开启"
        else
            die "insert_dylib does not support ${HOST_ARCH}. This may cause 'Bad CPU type in executable'. / insert_dylib 不支持 ${HOST_ARCH}，这通常会导致 Bad CPU type in executable。请替换为 universal 或 ${HOST_ARCH} 版本"
        fi
    fi

    # 3. 插件 framework 必须支持微信运行架构，否则微信启动时会加载失败
    if ! binary_contains_arch "${PLUGIN_SRC_BINARY_PATH}" "${TARGET_ARCH}"; then
        die "Plugin framework does not support target arch ${TARGET_ARCH}. / 插件 framework 不支持微信目标运行架构 ${TARGET_ARCH}。请重新编译为 universal 或包含 ${TARGET_ARCH} 的版本"
    fi

    ok "Architecture compatible / 架构检查通过"
}

check_supported_version() {
    APP_SHORT_VERSION="$(read_plist CFBundleShortVersionString)"
    APP_BUILD_VERSION="$(read_plist CFBundleVersion)"

    [ -n "${APP_SHORT_VERSION}" ] || die "Failed to read CFBundleShortVersionString / 读取微信版本号失败"
    [ -n "${APP_BUILD_VERSION}" ] || die "Failed to read CFBundleVersion / 读取微信 build 号失败"

    MATCHED_DISPLAY_VERSION=""
    MATCHED_LINE=""

    echo ""
    info "Detected WeChat version / 检测到微信版本:"
    echo "    CFBundleShortVersionString: ${APP_SHORT_VERSION}"
    echo "    CFBundleVersion:            ${APP_BUILD_VERSION}"
    echo ""

    while IFS='|' read -r f1 f2 f3 f4 rest || [ -n "${f1:-}" ]; do
        f1="$(trim "${f1:-}")"
        f2="$(trim "${f2:-}")"
        f3="$(trim "${f3:-}")"
        f4="$(trim "${f4:-}")"

        [ -z "${f1}" ] && continue
        [[ "${f1}" == \#* ]] && continue

        local display_version=""
        local short_version=""
        local build_version=""
        local note=""

        # 新格式：
        # DisplayVersion|CFBundleShortVersionString|CFBundleVersion|Note
        #
        # 兼容旧格式：
        # CFBundleShortVersionString|CFBundleVersion|Note
        if [ -n "${f3}" ] && is_build_token "${f3}"; then
            display_version="${f1}"
            short_version="${f2}"
            build_version="${f3}"
            note="${f4}"
        else
            display_version="${f1}"
            short_version="${f1}"
            build_version="${f2}"
            note="${f3}"
        fi

        [ -z "${short_version}" ] && short_version="*"
        [ -z "${build_version}" ] && build_version="*"

        if { [ "${short_version}" = "${APP_SHORT_VERSION}" ] || [ "${short_version}" = "*" ]; } && \
           { [ "${build_version}" = "${APP_BUILD_VERSION}" ] || [ "${build_version}" = "*" ]; }; then
            MATCHED_DISPLAY_VERSION="${display_version}"
            MATCHED_LINE="${display_version}|${short_version}|${build_version}|${note}"
            break
        fi
    done < "${SUPPORTED_FILE}"

    if [ -n "${MATCHED_DISPLAY_VERSION}" ]; then
        ok "Version supported / 版本检查通过"
        echo "    Supported Display Version: ${MATCHED_DISPLAY_VERSION}"
        echo "    Matched Rule:              ${MATCHED_LINE}"
        echo ""

        BACKUP_PATH="${APP_EXECUTABLE_PATH}.backup.${MATCHED_DISPLAY_VERSION}.${APP_BUILD_VERSION}"
        return 0
    fi

    warn "Current WeChat version is not listed in supported_versions.txt / 当前微信版本未在支持列表中"
    echo "    Detected CFBundleShortVersionString: ${APP_SHORT_VERSION}"
    echo "    Detected CFBundleVersion:            ${APP_BUILD_VERSION}"
    echo ""
    echo "    Please add a line like / 请添加类似下面这一行："
    echo "    4.1.9.58|${APP_SHORT_VERSION}|${APP_BUILD_VERSION}|Tested"
    echo ""

    BACKUP_PATH="${APP_EXECUTABLE_PATH}.backup.${APP_SHORT_VERSION}.${APP_BUILD_VERSION}"

    if [ "${FORCE}" -eq 1 ]; then
        warn "Force mode enabled, continue anyway / 已使用 --force，继续安装"
        return 0
    fi

    read -r -p "Continue anyway? 是否仍然继续安装？[y/N] " answer
    case "${answer}" in
        y|Y|yes|YES)
            warn "User confirmed, continue installation / 用户确认继续安装"
            ;;
        *)
            die "Installation cancelled / 用户取消安装"
            ;;
    esac
}

prepare_sudo() {
    RUN_SUDO=0

    if [ ! -w "${MACOS_PATH}" ] || [ ! -w "${APP_EXECUTABLE_PATH}" ]; then
        RUN_SUDO=1
        info "Administrator permission required / 需要管理员权限，准备申请 sudo..."
        sudo -v
        ok "sudo is ready / sudo 权限已准备好"
    else
        ok "No sudo required / 当前用户有写入权限"
    fi
}

quit_wechat() {
    info "Quit WeChat / 退出微信..."

    osascript -e 'tell application "WeChat" to quit' >/dev/null 2>&1 || true
    sleep 1

    pkill -x WeChat >/dev/null 2>&1 || true

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x WeChat >/dev/null 2>&1; then
            ok "WeChat is not running / 微信已退出"
            return 0
        fi
        sleep 0.5
    done

    if pgrep -x WeChat >/dev/null 2>&1; then
        warn "WeChat is still running, force kill / 微信仍在运行，强制结束"
        pkill -9 -x WeChat >/dev/null 2>&1 || true
    fi

    if pgrep -x WeChat >/dev/null 2>&1; then
        die "Failed to quit WeChat / 无法退出微信，请手动退出后重试"
    fi

    ok "WeChat has been killed / 微信已结束"
}

remove_quarantine() {
    info "Remove quarantine attributes / 移除 quarantine 属性..."

    run_cmd xattr -rd com.apple.quarantine "${INSERT_DYLIB_PATH}" >/dev/null 2>&1 || true
    run_cmd xattr -rd com.apple.quarantine "${PLUGIN_SRC_PATH}" >/dev/null 2>&1 || true
    run_cmd xattr -rd com.apple.quarantine "${APP_PATH}" >/dev/null 2>&1 || true

    ok "Quarantine attributes removed / quarantine 属性已处理"
}

is_executable_injected() {
    local executable="$1"

    if [ ! -f "${executable}" ]; then
        return 1
    fi

    otool -l "${executable}" 2>/dev/null | grep -q "${LOAD_DYLIB_PATH}" && return 0
    otool -l "${executable}" 2>/dev/null | grep -q "${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" && return 0

    return 1
}

backup_executable() {
    info "Backup original executable / 备份微信主可执行文件..."

    # 如果备份已经存在，优先使用已有备份，但要确认它不是已经注入过的文件
    if [ -f "${BACKUP_PATH}" ]; then
        if is_executable_injected "${BACKUP_PATH}"; then
            die "Backup already exists but it seems injected / 备份文件已存在，但看起来已经被注入过。为避免重复注入，请删除错误备份后重新安装微信，或换一个干净备份: ${BACKUP_PATH}"
        fi

        ok "Clean backup already exists / 干净备份已存在: ${BACKUP_PATH}"
        return 0
    fi

    # 如果当前主程序已经被注入，但是没有备份，不能把它当作原版备份
    if is_executable_injected "${APP_EXECUTABLE_PATH}"; then
        die "WeChat executable is already injected, but clean backup is missing / 当前微信主程序已经被注入，但没有找到干净备份。请先恢复原版微信，或者重新安装微信后再执行安装"
    fi

    run_cmd cp -p "${APP_EXECUTABLE_PATH}" "${BACKUP_PATH}"

    if is_executable_injected "${BACKUP_PATH}"; then
        die "Created backup seems injected / 刚创建的备份看起来已被注入，停止安装: ${BACKUP_PATH}"
    fi

    ok "Backup created / 已创建备份: ${BACKUP_PATH}"
}

restore_clean_executable() {
    info "Restore clean executable from backup / 从备份恢复干净主程序..."

    [ -f "${BACKUP_PATH}" ] || die "Backup not found / 备份不存在: ${BACKUP_PATH}"

    if is_executable_injected "${BACKUP_PATH}"; then
        die "Backup is not clean / 备份文件不干净，里面已经含有插件注入项: ${BACKUP_PATH}"
    fi

    run_cmd cp -p "${BACKUP_PATH}" "${APP_EXECUTABLE_PATH}"
    run_cmd chmod +x "${APP_EXECUTABLE_PATH}"

    ok "Executable restored / 主程序已恢复为干净版本"
}

copy_framework() {
    info "Copy plugin framework / 拷贝插件 framework..."

    run_cmd rm -rf "${FRAMEWORK_DST_PATH}"
    run_cmd ditto "${PLUGIN_SRC_PATH}" "${FRAMEWORK_DST_PATH}"

    [ -f "${FRAMEWORK_DST_BINARY_PATH}" ] || die "Copied framework binary missing / 拷贝后的 framework 二进制不存在: ${FRAMEWORK_DST_BINARY_PATH}"

    run_cmd chmod +x "${FRAMEWORK_DST_BINARY_PATH}" || true
    run_cmd xattr -rd com.apple.quarantine "${FRAMEWORK_DST_PATH}" >/dev/null 2>&1 || true

    ok "Framework copied / 插件 framework 已拷贝"
}

insert_framework() {
    info "Insert LC_LOAD_DYLIB / 注入 LC_LOAD_DYLIB..."
    echo "    ${LOAD_DYLIB_PATH}"

    run_cmd chmod +x "${INSERT_DYLIB_PATH}"
    run_cmd xattr -rd com.apple.quarantine "${INSERT_DYLIB_PATH}" >/dev/null 2>&1 || true

    local output=""
    local status=0

    set +e
    output="$(run_cmd "${INSERT_DYLIB_PATH}" --all-yes "${LOAD_DYLIB_PATH}" "${BACKUP_PATH}" "${APP_EXECUTABLE_PATH}" 2>&1)"
    status="$?"
    set -e

    if [ -n "${output}" ]; then
        echo "${output}"
    fi

    if [ "${status}" -ne 0 ]; then
        if echo "${output}" | grep -qi "Bad CPU type"; then
            die "insert_dylib failed: Bad CPU type in executable / insert_dylib 架构不匹配。请把 Rely/insert_dylib 换成 universal，或者至少包含当前机器架构 ${HOST_ARCH} 的版本"
        fi

        die "insert_dylib failed with exit code ${status} / insert_dylib 执行失败，退出码 ${status}"
    fi

    run_cmd chmod +x "${APP_EXECUTABLE_PATH}"

    ok "Dylib inserted / 注入完成"
}

sign_app() {
    info "Code sign plugin framework / 签名插件 framework..."
    run_cmd codesign --force --deep --sign - --timestamp=none "${FRAMEWORK_DST_PATH}"

    info "Code sign WeChatAppEx if exists / 如果存在则签名 WeChatAppEx..."
    APP_EX_PATH="${MACOS_PATH}/WeChatAppEx.app"

    if [ -d "${APP_EX_PATH}" ]; then
        run_cmd xattr -rd com.apple.quarantine "${APP_EX_PATH}" >/dev/null 2>&1 || true
        run_cmd codesign --force --deep --sign - --timestamp=none "${APP_EX_PATH}" || true

        WEAPP_PATH="${APP_EX_PATH}/Contents/Frameworks/WeChatAppEx Framework.framework/Versions/C/Helpers/WeApp.app"
        if [ -d "${WEAPP_PATH}" ]; then
            run_cmd codesign --force --deep --sign - --timestamp=none "${WEAPP_PATH}" || true
        fi
    fi

    info "Code sign main WeChat.app / 签名主 WeChat.app..."
    run_cmd codesign --force --deep --sign - --timestamp=none "${APP_PATH}"

    ok "Code sign finished / 签名完成"
}

write_state_file() {
    info "Write install state / 写入安装状态..."

    {
        echo "framework=${FRAMEWORK_NAME}"
        echo "display_version=${MATCHED_DISPLAY_VERSION:-unknown}"
        echo "short_version=${APP_SHORT_VERSION}"
        echo "build_version=${APP_BUILD_VERSION}"
        echo "target_arch=${TARGET_ARCH}"
        echo "host_arch=${HOST_ARCH}"
        echo "backup=${BACKUP_PATH}"
        echo "load_dylib=${LOAD_DYLIB_PATH}"
        echo "installed_at=$(date '+%Y-%m-%d %H:%M:%S')"
    } | run_cmd tee "${STATE_FILE}" >/dev/null

    ok "Install state saved / 安装状态已保存: ${STATE_FILE}"
}

verify_install() {
    info "Verify inserted dylib / 检查注入结果..."

    if is_executable_injected "${APP_EXECUTABLE_PATH}"; then
        ok "LC_LOAD_DYLIB found / 已检测到 ${FRAMEWORK_NAME}"
        otool -l "${APP_EXECUTABLE_PATH}" | grep -A3 "${FRAMEWORK_NAME}" || true
    else
        die "LC_LOAD_DYLIB not found / 未检测到 ${FRAMEWORK_NAME}，注入可能失败"
    fi

    echo ""
    info "Verify copied framework arch / 检查已安装插件架构..."

    if binary_contains_arch "${FRAMEWORK_DST_BINARY_PATH}" "${TARGET_ARCH}"; then
        ok "Installed framework supports ${TARGET_ARCH} / 已安装插件支持 ${TARGET_ARCH}"
    else
        die "Installed framework does not support ${TARGET_ARCH} / 已安装插件不支持 ${TARGET_ARCH}"
    fi

    echo ""
    info "Verify code signature / 检查签名..."

    if codesign -vvv --deep --strict "${APP_PATH}" >/dev/null 2>&1; then
        ok "Code signature verified / 签名验证通过"
    else
        warn "Code signature verification failed, but app may still run for debugging / 签名验证未完全通过，但调试运行不一定受影响"
        echo "    You can run manually / 可手动查看详情："
        echo "      codesign -vvv --deep --strict \"${APP_PATH}\""
    fi
}

print_done() {
    echo ""
    echo "=============================="
    echo "✅ ${FRAMEWORK_NAME} installed successfully"
    echo "✅ ${FRAMEWORK_NAME} 安装完成"
    echo "=============================="
    echo ""
    echo "Detected / 检测信息："
    echo "  WeChat:      ${APP_SHORT_VERSION} (${APP_BUILD_VERSION})"
    echo "  Display:     ${MATCHED_DISPLAY_VERSION:-unknown}"
    echo "  Host Arch:   ${HOST_ARCH}"
    echo "  Target Arch: ${TARGET_ARCH}"
    echo "  Backup:      ${BACKUP_PATH}"
    echo ""
    echo "Run WeChat and watch log / 启动微信并查看日志："
    echo "  rm -f ${LOG_PATH}"
    echo "  open -a WeChat"
    echo "  tail -f ${LOG_PATH}"
    echo ""
    echo "Uninstall / 卸载："
    echo "  ${SCRIPT_DIR}/uninstall.sh"
    echo ""
}

echo "=============================="
echo " Install ${FRAMEWORK_NAME}"
echo "=============================="
echo "APP_PATH=${APP_PATH}"
echo "PLUGIN_SRC_PATH=${PLUGIN_SRC_PATH}"
echo "FRAMEWORK_DST_PATH=${FRAMEWORK_DST_PATH}"
echo "INSERT_DYLIB_PATH=${INSERT_DYLIB_PATH}"
echo "SUPPORTED_FILE=${SUPPORTED_FILE}"
echo "LOAD_DYLIB_PATH=${LOAD_DYLIB_PATH}"
echo ""

check_required_commands
check_basic_files
check_arch_compatibility
check_supported_version
prepare_sudo
quit_wechat
remove_quarantine
backup_executable
restore_clean_executable
copy_framework
insert_framework
sign_app
write_state_file
verify_install
print_done