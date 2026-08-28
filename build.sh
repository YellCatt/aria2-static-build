#!/bin/bash -e

# aria2 静态交叉编译脚本（通用版）
# 支持多种架构: x86_64, aarch64, arm, mipsel 等
# 支持多种 SSL: OpenSSL / LibreSSL / Wintls (Windows)
#
# 在 GitHub Actions 中由 workflow 传入环境变量：
#   CROSS_HOST, OPENSSL_COMPILER, TARGET_HOST, USE_LIBRESSL
#   DEP_ZLIB_NG_TAG, DEP_ZLIB_TAG, DEP_XZ_TAG, DEP_OPENSSL_TAG,
#   DEP_LIBRESSL_TAG, DEP_LIBXML2_TAG, DEP_SQLITE_TAG,
#   DEP_CARES_TAG, DEP_LIBSSH2_TAG
#
# 本地独立运行时可设置默认值：
#   docker run --rm -v `pwd`:/build abcfy2/muslcc-toolchain-ubuntu:x86_64-linux-musl /build/build.sh

set -o pipefail

# ============ 固定配置 ============
export CROSS_HOST="${CROSS_HOST:-mipsel-linux-musleabi}"
export OPENSSL_COMPILER="${OPENSSL_COMPILER:-linux-mips32}"
export CROSS_ROOT="${CROSS_ROOT:-/cross_root}"
export USE_ZLIB_NG="${USE_ZLIB_NG:-1}"
export USE_LIBRESSL="${USE_LIBRESSL:-0}"
export TARGET_HOST="${TARGET_HOST:-linux}"
export USE_CHINA_MIRROR="${USE_CHINA_MIRROR:-0}"

# ============ 日志函数 ============
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /tmp/build.log
}
log_info()  { log "【信息】$1"; }
log_ok()    { log "【成功】✓ $1"; }
log_warn()  { log "【警告】⚠ $1"; }
log_error() { log "【错误】✗ $1"; }
log_step()  { log "【步骤】$1"; }
log_var()   { log "【变量】$1 = [$2]"; }

# ============ 重试函数 ============
retry() {
  log_step "进入 retry 函数，命令: [$*]"
  try=5
  sleep_time=30
  for i in $(seq ${try}); do
    log_info "retry 第 ${i}/${try} 次执行: [$*]"
    if "$@"; then
      log_ok "retry 成功 (第 ${i} 次): [$*]"
      return 0
    else
      log_warn "retry 失败 (第 ${i} 次): [$*]，${sleep_time} 秒后重试..."
      sleep ${sleep_time}
    fi
  done
  log_error "retry 已达到最大重试次数 (${try})，命令: [$*]"
  return 1
}

# ============ 环境准备 ============
source /etc/os-release
export DEBIAN_FRONTEND=noninteractive

# 中国镜像
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  cat >/etc/apt/sources.list <<EOF
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
fi

# 保留 deb 包缓存
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

log_step "========== 安装构建依赖 =========="
apt update
apt install -y g++ make libtool jq pkgconf file tcl autoconf automake autopoint patch wget qemu-user-static

# ============ 交叉编译环境变量 ============
export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LDFLAGS="-L${CROSS_PREFIX}/lib -s -static --static"

SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"
DOWNLOADS_DIR="${SELF_DIR}/downloads"
mkdir -p "${DOWNLOADS_DIR}"

if [ x"${USE_ZLIB_NG}" = x1 ]; then
  ZLIB=zlib-ng
else
  ZLIB=zlib
fi

echo "## Build Info - ${CROSS_HOST}" >"${BUILD_INFO}"
echo "Building using these dependencies:" >>"${BUILD_INFO}"

log_step "========================================"
log_step "  ${CROSS_HOST} 交叉编译环境初始化"
log_step "========================================"
log_var "CROSS_HOST" "${CROSS_HOST}"
log_var "CROSS_ROOT" "${CROSS_ROOT}"
log_var "CROSS_PREFIX" "${CROSS_PREFIX}"
log_var "OPENSSL_COMPILER" "${OPENSSL_COMPILER}"
log_var "USE_ZLIB_NG" "${USE_ZLIB_NG}"
log_var "USE_LIBRESSL" "${USE_LIBRESSL}"
log_var "TARGET_HOST" "${TARGET_HOST}"
log_var "USE_CHINA_MIRROR" "${USE_CHINA_MIRROR}"
log_var "SELF_DIR" "${SELF_DIR}"
log_var "BUILD_INFO" "${BUILD_INFO}"

# ============ 准备工具链 ============
prepare_toolchain() {
  log_step "========== 准备 musl 交叉编译工具链 =========="
  mkdir -p "${CROSS_ROOT}"

  local tgz="${DOWNLOADS_DIR}/${CROSS_HOST}-cross.tgz"
  # 检查缓存是否过期（30天）
  if [ -f "${tgz}" ]; then
    local cached_ts current_ts
    cached_ts="$(stat -c '%Y' "${tgz}")"
    current_ts="$(date +%s)"
    if [ "$((current_ts - cached_ts))" -gt 2592000 ]; then
      log_warn "工具链缓存已过期（超过30天），检查远程哈希..."
      local SHA512SUMS
      SHA512SUMS="$(retry wget -T30 -O- --compression=auto https://musl.cc/SHA512SUMS)"
      if echo "${SHA512SUMS}" | grep "${CROSS_HOST}-cross.tgz" | head -1 | sha512sum -c; then
        touch "${tgz}"
        log_ok "工具链哈希校验通过，继续使用缓存"
      else
        log_warn "工具链哈希不匹配，删除缓存重新下载"
        rm -f "${tgz}"
      fi
    else
      log_info "工具链缓存未过期，直接使用"
    fi
  fi

  if [ ! -f "${tgz}" ]; then
    log_info "下载工具链: https://musl.cc/${CROSS_HOST}-cross.tgz"
    rm -f "${tgz}.part"
    retry wget -c -T 30 --no-use-server-timestamps -O "${tgz}.part" "https://musl.cc/${CROSS_HOST}-cross.tgz"
    mv -fv "${tgz}.part" "${tgz}"
  fi

  log_info "解压工具链到 ${CROSS_ROOT}..."
  tar -zxf "${tgz}" --transform='s|^\./||S' --strip-components=1 -C "${CROSS_ROOT}"
  log_ok "工具链准备完成"
  log_var "工具链 gcc 版本" "$(${CROSS_HOST}-gcc --version 2>/dev/null | head -1 || echo '未知')"
}

# ============ 准备 zlib/zlib-ng ============
prepare_zlib() {
  log_step "========== 准备 ${ZLIB} =========="
  if [ x"${USE_ZLIB_NG}" = x"1" ]; then
    log_info "使用 zlib-ng（高性能替代版）"
    local tag="${DEP_ZLIB_NG_TAG:-}"
    if [ -z "${tag}" ]; then
      local _api_resp
      _api_resp="$(retry wget -qO- --compression=auto https://api.github.com/repos/zlib-ng/zlib-ng/releases)"
      tag="$(echo "${_api_resp}" | jq -r '.[0].tag_name')"
    fi
    log_var "zlib-ng 版本" "${tag}"

    local url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${tag}.tar.gz"
    [ x"${USE_CHINA_MIRROR}" = x1 ] && url="https://ghproxy.com/${url}"

    local f="${DOWNLOADS_DIR}/zlib-ng-${tag}.tar.gz"
    if [ ! -f "${f}" ]; then
      retry wget -c -T 10 -O "${f}.part" "${url}"
      mv -fv "${f}.part" "${f}"
    fi

    mkdir -p "/usr/src/zlib-ng-${tag}"
    log_info "解压 zlib-ng-${tag}.tar.gz..."
    tar -zxf "${f}" --strip-components=1 -C "/usr/src/zlib-ng-${tag}"
    cd "/usr/src/zlib-ng-${tag}"
    log_ok "进入源码目录: $(pwd)"

    log_info "配置: CHOST=${CROSS_HOST} --prefix=${CROSS_PREFIX} --static --zlib-compat"
    CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static --zlib-compat
    log_info "编译 (jobs=$(nproc))..."
    make -j$(nproc)
    log_info "安装..."
    make install

    local ver
    ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
    log_ok "zlib-ng 安装完成: ${ver}"
    echo "- zlib-ng: ${ver}, source: ${url:-cached}" >>"${BUILD_INFO}"
  else
    log_info "使用原版 zlib"
    local tag="${DEP_ZLIB_TAG:-}"
    if [ -z "${tag}" ]; then
      local _api_resp
      _api_resp="$(retry wget -qO- --compression=auto https://api.github.com/repos/madler/zlib/releases)"
      tag="$(echo "${_api_resp}" | jq -r '.[0].tag_name')"
    fi
    log_var "zlib 版本" "${tag}"

    local url="https://github.com/madler/zlib/archive/refs/tags/${tag}.tar.gz"
    local f="${DOWNLOADS_DIR}/zlib-${tag}.tar.gz"
    if [ ! -f "${f}" ]; then
      retry wget -c -T 10 -O "${f}.part" "${url}"
      mv -fv "${f}.part" "${f}"
    fi

    mkdir -p "/usr/src/zlib-${tag}"
    log_info "解压 zlib-${tag}.tar.gz..."
    tar -zxf "${f}" --strip-components=1 -C "/usr/src/zlib-${tag}"
    cd "/usr/src/zlib-${tag}"
    log_ok "进入源码目录: $(pwd)"

    log_info "配置: CHOST=${CROSS_HOST} --prefix=${CROSS_PREFIX} --static"
    CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static
    log_info "编译 (jobs=$(nproc))..."
    make -j$(nproc)
    log_info "安装..."
    make install

    local ver
    ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
    log_ok "zlib 安装完成: ${ver}"
    echo "- zlib: ${ver}, source: ${url:-cached}" >>"${BUILD_INFO}"
  fi
}

# ============ 准备 xz ============
prepare_xz() {
  log_step "========== 准备 xz =========="
  local tag="${DEP_XZ_TAG:-5.8.0}"
  log_var "xz 版本" "${tag}"

  local url="https://tukaani.org/xz/xz-${tag}.tar.xz"
  local alt_url="https://github.com/tukaani-project/xz/releases/download/v${tag}/xz-${tag}.tar.xz"
  local f="${DOWNLOADS_DIR}/xz-${tag}.tar.xz"

  if [ ! -f "${f}" ]; then
    retry wget -c -T 10 -O "${f}.part" "${url}" || retry wget -c -T 10 -O "${f}.part" "${alt_url}"
    mv -fv "${f}.part" "${f}"
  fi

  mkdir -p "/usr/src/xz-${tag}"
  log_info "解压 xz-${tag}.tar.xz..."
  tar -Jxf "${f}" --strip-components=1 -C "/usr/src/xz-${tag}"
  cd "/usr/src/xz-${tag}"
  log_ok "进入源码目录: $(pwd)"

  log_info "配置: --host=${CROSS_HOST} --prefix=${CROSS_PREFIX}"
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" \
    --enable-silent-rules --enable-static --disable-shared
  log_info "编译 (jobs=$(nproc))..."
  make -j$(nproc)
  log_info "安装..."
  make install

  local ver
  ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/liblzma.pc")"
  log_ok "xz 安装完成: ${ver}"
  echo "- xz: ${ver}, source: ${url}" >>"${BUILD_INFO}"
}

# ============ 准备 SSL (OpenSSL / LibreSSL) ============
prepare_ssl() {
  if [ x"${TARGET_HOST}" = x"win" ]; then
    log_info "Windows 目标使用 Wintls，跳过 SSL 构建"
    return 0
  fi

  if [ x"${USE_LIBRESSL}" = x"1" ]; then
    log_step "========== 准备 LibreSSL =========="
    local tag="${DEP_LIBRESSL_TAG:-}"
    if [ -z "${tag}" ]; then
      local _api_resp
      _api_resp="$(retry wget -qO- --compression=auto https://api.github.com/repos/libressl/libressl/releases)"
      tag="$(echo "${_api_resp}" | jq -r '.[0].tag_name')"
    fi
    log_var "LibreSSL 版本" "${tag}"

    local url="https://github.com/libressl/libressl/archive/refs/tags/${tag}.tar.gz"
    local f="${DOWNLOADS_DIR}/libressl-${tag}.tar.gz"
    if [ ! -f "${f}" ]; then
      retry wget -c -T 10 -O "${f}.part" "${url}"
      mv -fv "${f}.part" "${f}"
    fi

    mkdir -p "/usr/src/libressl-${tag}"
    log_info "解压 libressl-${tag}.tar.gz..."
    tar -zxf "${f}" --strip-components=1 -C "/usr/src/libressl-${tag}"
    cd "/usr/src/libressl-${tag}"
    log_ok "进入源码目录: $(pwd)"

    if [ ! -f "./configure" ]; then
      log_info "未找到 configure，执行 ./autogen.sh ..."
      ./autogen.sh
    fi

    log_info "配置: --host=${CROSS_HOST} --prefix=${CROSS_PREFIX}"
    ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" \
      --enable-silent-rules --enable-static --disable-shared --with-openssldir=/etc/ssl
    log_info "编译 (jobs=$(nproc))..."
    make -j$(nproc)
    log_info "安装..."
    make install_sw

    local ver
    ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/openssl.pc")"
    log_ok "LibreSSL 安装完成: ${ver}"
    echo "- libressl: ${ver}, source: ${url:-cached}" >>"${BUILD_INFO}"
  else
    log_step "========== 准备 OpenSSL =========="
    local tag="${DEP_OPENSSL_TAG:-}"
    if [ -z "${tag}" ]; then
      local _api_resp
      _api_resp="$(retry wget -qO- --compression=auto https://api.github.com/repos/openssl/openssl/releases)"
      tag="$(echo "${_api_resp}" | jq -r '.[0].tag_name')"
    fi
    local ver="${tag#openssl-}"
    log_var "OpenSSL tag" "${tag}"
    log_var "OpenSSL 版本号" "${ver}"

    local url="https://github.com/openssl/openssl/archive/refs/tags/${tag}.tar.gz"
    [ x"${USE_CHINA_MIRROR}" = x1 ] && url="https://ghproxy.com/${url}"

    local f="${DOWNLOADS_DIR}/openssl-${ver}.tar.gz"
    if [ ! -f "${f}" ]; then
      retry wget -c -T 10 -O "${f}.part" "${url}"
      mv -fv "${f}.part" "${f}"
    fi

    mkdir -p "/usr/src/openssl-${ver}"
    log_info "解压 openssl-${ver}.tar.gz..."
    tar -zxf "${f}" --strip-components=1 -C "/usr/src/openssl-${ver}"
    cd "/usr/src/openssl-${ver}"
    log_ok "进入源码目录: $(pwd)"

    log_info "配置: ${OPENSSL_COMPILER} --prefix=${CROSS_PREFIX}"
    ./Configure -static --cross-compile-prefix="${CROSS_HOST}-" --prefix="${CROSS_PREFIX}" \
      "${OPENSSL_COMPILER}" --openssldir=/etc/ssl
    log_info "编译 (jobs=$(nproc))..."
    make -j$(nproc)
    log_info "安装..."
    make install_sw

    local installed_ver
    installed_ver="$(grep Version: "${CROSS_PREFIX}"/lib*/pkgconfig/openssl.pc)"
    log_ok "OpenSSL 安装完成: ${installed_ver}"
    echo "- openssl: ${installed_ver}, source: ${url:-cached}" >>"${BUILD_INFO}"
  fi
}

# ============ 准备 libxml2 ============
prepare_libxml2() {
  log_step "========== 准备 libxml2 =========="
  local tag="${DEP_LIBXML2_TAG:-}"
  if [ -z "${tag}" ]; then
    local _api_resp
    _api_resp="$(retry wget -qO- --compression=auto https://api.github.com/repos/GNOME/libxml2/releases)"
    tag="$(echo "${_api_resp}" | jq -r '.[0].tag_name')"
  fi
  log_var "libxml2 版本" "${tag}"

  local url="https://github.com/GNOME/libxml2/archive/refs/tags/${tag}.tar.gz"
  local f="${DOWNLOADS_DIR}/libxml2-${tag}.tar.gz"
  if [ ! -f "${f}" ]; then
    retry wget -c -O "${f}.part" "${url}"
    mv -fv "${f}.part" "${f}"
  fi

  mkdir -p "/usr/src/libxml2-${tag}"
  log_info "解压 libxml2-${tag}.tar.gz..."
  tar -zxf "${f}" --strip-components=1 -C "/usr/src/libxml2-${tag}"
  cd "/usr/src/libxml2-${tag}"
  log_ok "进入源码目录: $(pwd)"

  log_info "配置: --host=${CROSS_HOST} --prefix=${CROSS_PREFIX}"
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" \
    --enable-silent-rules --without-python --without-icu --enable-static --disable-shared
  log_info "编译 (jobs=$(nproc))..."
  make -j$(nproc)
  log_info "安装..."
  make install

  local ver
  ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/"libxml-*.pc)"
  log_ok "libxml2 安装完成: ${ver}"
  echo "- libxml2: ${ver}, source: ${url:-cached}" >>"${BUILD_INFO}"
}

# ============ 准备 sqlite ============
prepare_sqlite() {
  log_step "========== 准备 sqlite =========="
  local tag="${DEP_SQLITE_TAG:-}"
  if [ -z "${tag}" ]; then
    local _api_resp
    _api_resp="$(retry wget -qO- --compression=auto https://api.github.com/repos/sqlite/sqlite/releases)"
    tag="$(echo "${_api_resp}" | jq -r '.[0].tag_name')"
  fi
  log_var "sqlite 版本" "${tag}"

  local url="https://github.com/sqlite/sqlite/archive/refs/tags/${tag}.tar.gz"
  [ x"${USE_CHINA_MIRROR}" = x1 ] && url="https://ghproxy.com/${url}"

  local f="${DOWNLOADS_DIR}/sqlite-${tag}.tar.gz"
  if [ ! -f "${f}" ]; then
    retry wget -c -T 10 -O "${f}.part" "${url}"
    mv -fv "${f}.part" "${f}"
  fi

  mkdir -p "/usr/src/sqlite-${tag}"
  log_info "解压 sqlite-${tag}.tar.gz..."
  tar -zxf "${f}" --strip-components=1 -C "/usr/src/sqlite-${tag}"
  cd "/usr/src/sqlite-${tag}"
  log_ok "进入源码目录: $(pwd)"

  log_info "配置: --host=${CROSS_HOST} --prefix=${CROSS_PREFIX}"
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" \
    --enable-static --disable-shared
  log_info "编译 (jobs=$(nproc))..."
  make -j$(nproc)
  log_info "安装..."
  make install

  local ver
  ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/"sqlite*.pc)"
  log_ok "sqlite 安装完成: ${ver}"
  echo "- sqlite: ${ver}, source: ${url:-cached}" >>"${BUILD_INFO}"
}

# ============ 准备 c-ares ============
prepare_c_ares() {
  log_step "========== 准备 c-ares =========="
  local tag="${DEP_CARES_TAG:-}"
  if [ -z "${tag}" ]; then
    local _api_resp
    _api_resp="$(retry wget -qO- --compression=auto https://api.github.com/repos/c-ares/c-ares/releases)"
    tag="$(echo "${_api_resp}" | jq -r '.[0].tag_name')"
  fi
  log_var "c-ares 版本" "${tag}"

  local url="https://github.com/c-ares/c-ares/archive/refs/tags/${tag}.tar.gz"
  local f="${DOWNLOADS_DIR}/c-ares-${tag}.tar.gz"
  if [ ! -f "${f}" ]; then
    retry wget -c -T 10 -O "${f}.part" "${url}"
    mv -fv "${f}.part" "${f}"
  fi

  mkdir -p "/usr/src/c-ares-${tag}"
  log_info "解压 c-ares-${tag}.tar.gz..."
  tar -zxf "${f}" --strip-components=1 -C "/usr/src/c-ares-${tag}"
  cd "/usr/src/c-ares-${tag}"
  log_ok "进入源码目录: $(pwd)"

  if [ ! -f "./configure" ]; then
    log_info "未找到 configure，执行 autoreconf -i..."
    autoreconf -i
  fi

  log_info "配置: --host=${CROSS_HOST} --prefix=${CROSS_PREFIX}"
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" \
    --enable-static --disable-shared --enable-silent-rules --disable-tests
  log_info "编译 (jobs=$(nproc))..."
  make -j$(nproc)
  log_info "安装..."
  make install

  local ver
  ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/libcares.pc")"
  log_ok "c-ares 安装完成: ${ver}"
  echo "- c-ares: ${ver}, source: ${url:-cached}" >>"${BUILD_INFO}"
}

# ============ 准备 libssh2 ============
prepare_libssh2() {
  log_step "========== 准备 libssh2 =========="
  local tag="${DEP_LIBSSH2_TAG:-}"
  if [ -z "${tag}" ]; then
    local _api_resp
    _api_resp="$(retry wget -qO- --compression=auto https://api.github.com/repos/libssh2/libssh2/releases)"
    tag="$(echo "${_api_resp}" | jq -r '.[0].tag_name')"
  fi
  log_var "libssh2 版本" "${tag}"

  local url="https://github.com/libssh2/libssh2/archive/refs/tags/${tag}.tar.gz"
  local f="${DOWNLOADS_DIR}/libssh2-${tag}.tar.gz"
  if [ ! -f "${f}" ]; then
    retry wget -c -T 10 -O "${f}.part" "${url}"
    mv -fv "${f}.part" "${f}"
  fi

  mkdir -p "/usr/src/libssh2-${tag}"
  log_info "解压 libssh2-${tag}.tar.gz..."
  tar -zxf "${f}" --strip-components=1 -C "/usr/src/libssh2-${tag}"
  cd "/usr/src/libssh2-${tag}"
  log_ok "进入源码目录: $(pwd)"

  log_info "配置: --host=${CROSS_HOST} --prefix=${CROSS_PREFIX}"
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" \
    --enable-static --disable-shared --enable-silent-rules
  log_info "编译 (jobs=$(nproc))..."
  make -j$(nproc)
  log_info "安装..."
  make install

  local ver
  ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/libssh2.pc")"
  log_ok "libssh2 安装完成: ${ver}"
  echo "- libssh2: ${ver}, source: ${url:-cached}" >>"${BUILD_INFO}"
}

# ============ 构建 aria2 ============
build_aria2() {
  log_step "========== 构建 aria2 =========="
  log_var "ARIA2_VER" "${ARIA2_VER:-(未设置，使用 master)}"

  local tag url f
  if [ -n "${ARIA2_VER}" ]; then
    tag="${ARIA2_VER}"
    url="https://github.com/aria2/aria2/releases/download/release-${ARIA2_VER}/aria2-${ARIA2_VER}.tar.gz"
  else
    tag="master"
    url="https://github.com/aria2/aria2/archive/master.tar.gz"
    # master 缓存每天检查一次
    if [ -f "${DOWNLOADS_DIR}/aria2-${tag}.tar.gz" ]; then
      local cached_ts current_ts
      cached_ts="$(stat -c '%Y' "${DOWNLOADS_DIR}/aria2-${tag}.tar.gz")"
      current_ts="$(date +%s)"
      if [ "$((current_ts - cached_ts))" -gt 86400 ]; then
        log_warn "aria2 master 缓存已过期（超过1天），删除重新下载"
        rm -f "${DOWNLOADS_DIR}/aria2-${tag}.tar.gz"
      fi
    fi
  fi
  [ x"${USE_CHINA_MIRROR}" = x1 ] && url="https://ghproxy.com/${url}"
  log_var "aria2 下载地址" "${url}"

  f="${DOWNLOADS_DIR}/aria2-${tag}.tar.gz"
  if [ ! -f "${f}" ]; then
    retry wget -c -T 10 -O "${f}.part" "${url}"
    mv -fv "${f}.part" "${f}"
  fi

  mkdir -p "/usr/src/aria2-${tag}"
  log_info "解压 aria2-${tag}.tar.gz..."
  tar -zxf "${f}" --strip-components=1 -C "/usr/src/aria2-${tag}"
  cd "/usr/src/aria2-${tag}"
  log_ok "进入源码目录: $(pwd)"

  if [ ! -f ./configure ]; then
    log_info "未找到 configure，执行 autoreconf -i..."
    autoreconf -i
  fi

  log_info "配置: --host=${CROSS_HOST} --prefix=${CROSS_PREFIX} ARIA2_STATIC=yes"
  ./configure --build=x86_64-linux-gnu --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" \
    --enable-static --disable-shared --enable-silent-rules ARIA2_STATIC=yes
  log_info "编译 (jobs=$(nproc))..."
  make -j$(nproc)
  log_info "安装..."
  make install

  log_ok "aria2 构建完成"
  echo "- aria2: source: ${url:-cached}" >>"${BUILD_INFO}"
  echo >>"${BUILD_INFO}"
}

# ============ 获取构建信息 ============
get_build_info() {
  log_step "========== 获取构建信息 =========="

  echo "============= ARIA2 VER INFO ==================="
  local ARIA2_VER_INFO
  local qemu_bin=""
  local arch_name="${CROSS_HOST%%-*}"
  case "${CROSS_HOST}" in
    mipsel-*)  qemu_bin="qemu-mipsel-static" ;;
    mips-*)    qemu_bin="qemu-mips-static" ;;
    arm-*)     qemu_bin="qemu-arm-static" ;;
    aarch64-*) qemu_bin="qemu-aarch64-static" ;;
    x86_64-*)  qemu_bin="qemu-x86_64-static" ;;
    i686-*)    qemu_bin="qemu-i386-static" ;;
  esac

  if [ -n "${qemu_bin}" ] && command -v "${qemu_bin}" >/dev/null 2>&1; then
    ARIA2_VER_INFO="$("${qemu_bin}" "${CROSS_PREFIX}/bin/aria2c"* --version 2>/dev/null)"
  fi
  if [ -z "${ARIA2_VER_INFO}" ]; then
    log_warn "qemu 运行 aria2 获取版本信息失败，尝试直接读取二进制..."
    ARIA2_VER_INFO="$(${CROSS_HOST}-strings "${CROSS_PREFIX}/bin/aria2c"* 2>/dev/null | grep -m1 'aria2 version' || echo '无法获取版本')"
  else
    log_ok "成功获取 aria2 版本信息"
  fi
  echo "${ARIA2_VER_INFO}"
  echo "================================================"

  echo "aria2 version info:" >>"${BUILD_INFO}"
  echo '```txt' >>"${BUILD_INFO}"
  echo "${ARIA2_VER_INFO}" >>"${BUILD_INFO}"
  echo '```' >>"${BUILD_INFO}"
  log_ok "构建信息已写入 ${BUILD_INFO}"
}

# ============ 测试构建 ============
test_build() {
  log_step "========== 测试 aria2 下载功能 =========="
  local qemu_bin=""
  case "${CROSS_HOST}" in
    mipsel-*)  qemu_bin="qemu-mipsel-static" ;;
    mips-*)    qemu_bin="qemu-mips-static" ;;
    arm-*)     qemu_bin="qemu-arm-static" ;;
    aarch64-*) qemu_bin="qemu-aarch64-static" ;;
    x86_64-*)  qemu_bin="qemu-x86_64-static" ;;
    i686-*)    qemu_bin="qemu-i386-static" ;;
  esac
  if [ -n "${qemu_bin}" ] && command -v "${qemu_bin}" >/dev/null 2>&1; then
    log_info "使用 ${qemu_bin} 运行测试..."
    if "${qemu_bin}" "${CROSS_PREFIX}/bin/aria2c"* --http-accept-gzip=true https://github.com/ -d /tmp -o test; then
      log_ok "aria2 下载测试成功"
    else
      log_warn "aria2 下载测试失败（可能是网络或 qemu 问题，不影响产物）"
    fi
  else
    log_info "跳过 qemu 测试（未找到对应 qemu 二进制: ${qemu_bin}）"
  fi
}

# ============ 主流程 ============
prepare_toolchain
prepare_zlib
prepare_xz
prepare_ssl
prepare_libxml2
prepare_sqlite
prepare_c_ares
prepare_libssh2
build_aria2

get_build_info
test_build

log_step "========== 复制构建产物到输出目录 =========="
  local arch_name="${CROSS_HOST%%-*}"
  local output_name="aria2c-${arch_name}"
  log_info "复制 ${CROSS_PREFIX}/bin/aria2c → ${SELF_DIR}/${output_name}"
  cp -fv "${CROSS_PREFIX}/bin/aria2c" "${SELF_DIR}/${output_name}"
  log_ok "构建产物已复制到 ${SELF_DIR}/${output_name}"

  log_step "========================================"
  log_ok "  ${CROSS_HOST} 构建全部完成"
  log_step "========================================"