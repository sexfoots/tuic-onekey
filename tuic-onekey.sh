#!/bin/sh
# ==============================================================================
# tuic-onekey.sh  v3   ——  sing-box 一键安装：TUIC（可选同时开 Hysteria2）
#
# 适用系统 : Alpine(OpenRC) / Debian / Ubuntu / CentOS Stream / Rocky / Alma (systemd)
# 适用架构 : x86_64(amd64) / aarch64(arm64) / armv7 / 386
#
# 用法:
#   sh tuic-onekey.sh                 # 默认端口 23523，自签证书，只装 TUIC
#   sh tuic-onekey.sh 34567           # 指定端口
#   sh tuic-onekey.sh 23523 --hy2     # TUIC + Hysteria2 同时开
#   sh tuic-onekey.sh 23523 --domain v.example.com --acme   # 用真域名 + Let's Encrypt
#   sh tuic-onekey.sh --uuid <UUID> --pass <密码>            # 固定凭据
#   sh tuic-onekey.sh --uninstall     # 卸载（会列清单并二次确认）
#   sh tuic-onekey.sh --help
#
# 设计要点:
#   - 幂等: 重复跑不会换掉已有 UUID/密码；只改端口时才重写配置
#   - 内存自适应: <128M 用 40MiB GOMEMLIMIT，<256M 用 64MiB，更大用 128MiB
#   - 下载走 GitHub，失败自动回退国内加速镜像
#   - 最后打印 TUIC/HY2 链接、base64 订阅、Clash YAML，并存一份到 /etc/sing-box/
# ==============================================================================

PORT=23523        # ← 想写死端口就改这里（改完不用带参数）
PORT_SET=0        # 0=没指定，脚本会交互式问一句；带了参数则置 1
HY2=0
HY2_PORT=
DOMAIN=
USE_ACME=0
UUID_OVERRIDE=
PASS_OVERRIDE=
SNI=
GMEM=
UNINSTALL=0
DIR=/etc/sing-box
CERTDIR=$DIR/tls
ACCT=$DIR/account.env
LOGFILE=/var/log/sing-box.log
VER=${SINGBOX_VER:-1.11.15}

usage() {
  cat <<'HLP'
用法: sh tuic-onekey.sh [端口] [选项]

  --port N          TUIC 端口（也可直接写数字作为第一个参数）
                    不带端口参数时，脚本会交互式问一句；默认 23523
  --hy2             同时开 Hysteria2
  --hy2-port N      Hysteria2 端口，默认 = TUIC 端口 + 1
  --domain D        使用域名作为 SNI（配合 --acme 申请真证书）
  --acme            用 acme.sh 申请 Let's Encrypt 证书（需要 80 端口可达）
  --uuid U          固定 TUIC UUID
  --pass P          固定 TUIC 密码
  --sni S           自定义 SNI，默认取域名，否则 "tuic"
  --mem N           手动指定 GOMEMLIMIT（MiB）
  --uninstall       卸载
  -h, --help        这段帮助
HLP
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      shift; PORT="$1";  PORT_SET=1 ;;
    --hy2)       HY2=1 ;;
    --hy2-port)  shift; HY2_PORT="$1" ;;
    --domain)    shift; DOMAIN="$1" ;;
    --acme)      USE_ACME=1 ;;
    --uuid)      shift; UUID_OVERRIDE="$1" ;;
    --pass)      shift; PASS_OVERRIDE="$1" ;;
    --sni)       shift; SNI="$1" ;;
    --mem)       shift; GMEM="$1" ;;
    --uninstall) UNINSTALL=1 ;;
    --)          shift ;;
    -h|--help)   usage; exit 0 ;;
    [0-9]*)      PORT="$1"; PORT_SET=1 ;;
    *)           echo "未知参数: $1"; usage; exit 1 ;;
  esac
  shift
done

[ "$(id -u)" = "0" ] || { echo "必须用 root 运行"; exit 1; }

# ---------------------------------------------------------------- 卸载
if [ "$UNINSTALL" = "1" ]; then
  echo "即将删除以下内容（请确认路径与大小）:"
  for p in /etc/systemd/system/sing-box.service /etc/init.d/sing-box "$DIR" /usr/local/bin/sing-box; do
    if [ -e "$p" ]; then
      sz=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
      printf "  %-40s %s\n" "$p" "${sz:-?}"
    fi
  done
  echo
  echo "注意: $DIR 内含证书与账号信息，删除后不可恢复。"
  printf "确认卸载? 输入 yes 继续: "
  # 支持 curl | sh 管道执行：此时 stdin 是脚本本身，必须从终端读
  if [ -r /dev/tty ]; then
    read ans < /dev/tty
  else
    echo
    echo "检测不到终端（管道执行），为安全起见不卸载。请下载脚本后本地执行。"
    exit 1
  fi
  [ "$ans" = "yes" ] || { echo "已取消"; exit 0; }

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now sing-box >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service sing-box stop >/dev/null 2>&1 || true
    rc-update del sing-box default >/dev/null 2>&1 || true
    rm -f /etc/init.d/sing-box
  fi
  rm -rf "$DIR"
  rm -f /usr/local/bin/sing-box
  echo "已卸载。"
  exit 0
fi

# ---------------------------------------------------------------- 端口（自定义/交互）
# 没带端口参数时，交互式问一句；管道执行（curl|sh）没有终端则直接用默认值
if [ "$PORT_SET" = "0" ]; then
  echo "当前默认端口: $PORT（面板上给 TUIC 的那个 UDP 端口）"
  if [ -r /dev/tty ]; then
    printf "请输入端口（直接回车沿用 %s）: " "$PORT"
    read pin < /dev/tty 2>/dev/null || pin=""
    if [ -n "$pin" ]; then
      PORT="$pin"
    fi
  fi
fi

case "$PORT" in
  ''|*[!0-9]*) echo "端口必须是纯数字，收到: $PORT"; exit 1 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "端口必须在 1-65535，收到: $PORT"; exit 1
fi
echo "使用端口: $PORT"

# ---------------------------------------------------------------- 依赖
install_pkgs() {
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@" >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$@" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$@" >/dev/null 2>&1 || true
  fi
}

echo "[1/7] 检查依赖"
install_pkgs curl wget openssl tar ca-certificates
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
  echo "缺少 curl/wget，请手动安装后重试"; exit 1; }
command -v openssl >/dev/null 2>&1 || {
  echo "缺少 openssl，请手动安装后重试"; exit 1; }

# ---------------------------------------------------------------- init / 架构
if command -v rc-service >/dev/null 2>&1; then
  INIT=openrc
  RESTART="rc-service sing-box restart"
  STATUS="rc-service sing-box status"
elif command -v systemctl >/dev/null 2>&1; then
  INIT=systemd
  RESTART="systemctl restart sing-box"
  STATUS="systemctl status sing-box"
else
  INIT=none
  RESTART="nohup /usr/local/bin/sing-box run -c $DIR/config.json >/dev/null 2>&1 &"
  STATUS="ps | grep sing-box"
fi

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l|armv7)  ARCH=armv7 ;;
  i386|i686)     ARCH=386 ;;
  *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

# ---------------------------------------------------------------- 下载
fetch() {   # $1=url $2=目标文件
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "$2" "$1" >/dev/null 2>&1 && return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 20 -O "$2" "$1" >/dev/null 2>&1 && return 0
  fi
  return 1
}

if [ ! -x /usr/local/bin/sing-box ]; then
  echo "[2/7] 下载 sing-box ${VER} (linux-${ARCH})"
  URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
  ok=0
  for u in "$URL" "https://ghfast.top/$URL" "https://gh-proxy.com/$URL" "https://ghproxy.net/$URL"; do
    if fetch "$u" /tmp/sb.tgz && tar -tzf /tmp/sb.tgz >/dev/null 2>&1; then ok=1; break; fi
  done
  [ "$ok" = "1" ] || { echo "下载失败：四个源都不通，请手动下载 $URL 后放到 /tmp/sb.tgz 再重跑"; exit 1; }
  tar -xzf /tmp/sb.tgz -C /tmp
  install -m755 "/tmp/sing-box-${VER}-linux-${ARCH}/sing-box" /usr/local/bin/sing-box
  rm -rf "/tmp/sing-box-${VER}-linux-${ARCH}" /tmp/sb.tgz
else
  echo "[2/7] sing-box 已存在，跳过下载"
fi

/usr/local/bin/sing-box version >/dev/null 2>&1 || { echo "sing-box 无法运行，检查架构是否匹配"; exit 1; }

# ---------------------------------------------------------------- 证书
mkdir -p "$CERTDIR"
[ -n "$SNI" ] || { [ -n "$DOMAIN" ] && SNI="$DOMAIN" || SNI=tuic; }

INSECURE=1
if [ "$USE_ACME" = "1" ]; then
  [ -n "$DOMAIN" ] || { echo "--acme 必须配合 --domain 使用"; exit 1; }
  echo "[3/7] 申请 Let's Encrypt 证书 ($DOMAIN)，需要 80 端口可达"
  fetch https://get.acme.sh /tmp/acme.sh && sh /tmp/acme.sh --install --nocron >/dev/null 2>&1
  ACA="/root/.acme.sh/acme.sh"
  if [ -x "$ACA" ]; then
    "$ACA" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    if "$ACA" --issue -d "$DOMAIN" --standalone -k ec-256 --force >/tmp/acme.log 2>&1; then
      "$ACA" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERTDIR/cert.pem" --key-file "$CERTDIR/key.pem" >/dev/null 2>&1
      INSECURE=0
      echo "      证书申请成功"
    else
      echo "      申请失败（80 端口多半不通），回退自签证书；日志 /tmp/acme.log"
    fi
  fi
fi

if [ ! -f "$CERTDIR/cert.pem" ] || [ "$INSECURE" = "1" ]; then
  if [ ! -f "$CERTDIR/cert.pem" ]; then
    echo "[3/7] 生成自签证书 (SNI=$SNI)"
    openssl ecparam -genkey -name prime256v1 -out "$CERTDIR/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$CERTDIR/key.pem" \
      -out "$CERTDIR/cert.pem" -subj "/CN=$SNI" 2>/dev/null
  else
    echo "[3/7] 沿用已有证书"
  fi
  INSECURE=1
fi

# ---------------------------------------------------------------- 账号
echo "[4/7] 准备账号"
[ -f "$ACCT" ] && . "$ACCT"

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}
gen_pass() {
  openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-20
}

TUIC_UUID=${UUID_OVERRIDE:-${TUIC_UUID:-$(gen_uuid)}}
TUIC_PASS=${PASS_OVERRIDE:-${TUIC_PASS:-$(gen_pass)}}
HY2_PASS=${HY2_PASS:-$(gen_pass)}
[ -n "$HY2_PORT" ] || HY2_PORT=$((PORT + 1))

printf 'TUIC_UUID=%s\nTUIC_PASS=%s\nHY2_PASS=%s\nTUIC_PORT=%s\nHY2_PORT=%s\nDOMAIN=%s\n' \
  "$TUIC_UUID" "$TUIC_PASS" "$HY2_PASS" "$PORT" "$HY2_PORT" "${DOMAIN:-}" > "$ACCT"
chmod 600 "$ACCT"

# ---------------------------------------------------------------- 端口检查
for p in $PORT $([ "$HY2" = "1" ] && echo "$HY2_PORT"); do
  if (ss -lunp 2>/dev/null || netstat -lunp 2>/dev/null) | grep -E "[:.]${p}[[:space:]]" | grep -v sing-box | grep -q .; then
    echo "警告: UDP 端口 $p 已被其它进程占用，配置写入后可能起不来"
  fi
done

# ---------------------------------------------------------------- 配置
echo "[5/7] 写配置 (TUIC=${PORT}$([ "$HY2" = "1" ] && echo " / HY2=${HY2_PORT}"))"

TUIC_JSON=$(cat <<EOF
{
  "type": "tuic",
  "tag": "tuic",
  "listen": "::",
  "listen_port": ${PORT},
  "users": [{ "uuid": "${TUIC_UUID}", "password": "${TUIC_PASS}" }],
  "congestion_control": "bbr",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "alpn": ["h3"],
    "certificate_path": "${CERTDIR}/cert.pem",
    "key_path": "${CERTDIR}/key.pem"
  }
}
EOF
)

HY2_JSON=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "hy2",
  "listen": "::",
  "listen_port": ${HY2_PORT},
  "users": [{ "password": "${HY2_PASS}" }],
  "masquerade": "https://www.bing.com",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "alpn": ["h3"],
    "certificate_path": "${CERTDIR}/cert.pem",
    "key_path": "${CERTDIR}/key.pem"
  }
}
EOF
)

[ -f "$DIR/config.json" ] && cp "$DIR/config.json" "$DIR/config.json.bak"
{
  printf '{\n  "log": { "level": "warn", "output": "%s", "timestamp": true },\n  "inbounds": [\n' "${LOGFILE}"
  printf '%s\n' "$TUIC_JSON"
  [ "$HY2" = "1" ] && printf ',\n%s\n' "$HY2_JSON"
  printf '  ],\n  "outbounds": [{ "type": "direct" }]\n}\n'
} > "$DIR/config.json"

/usr/local/bin/sing-box check -c "$DIR/config.json" || {
  echo "配置校验失败，已保留备份 $DIR/config.json.bak"; exit 1; }

# ---------------------------------------------------------------- 服务
echo "[6/7] 装服务 (init=$INIT)"

if [ -z "$GMEM" ]; then
  mem_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
  [ -n "$mem_kb" ] || mem_kb=999999
  if [ "$mem_kb" -lt 131072 ]; then GMEM=40
  elif [ "$mem_kb" -lt 262144 ]; then GMEM=64
  else GMEM=128; fi
fi

if [ "$INIT" = "openrc" ]; then
  cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c ${DIR}/config.json"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
export GOMEMLIMIT="${GMEM}MiB"
export GOGC="40"
output_log="${LOGFILE}"
error_log="${LOGFILE}"
EOF
  chmod +x /etc/init.d/sing-box
  rc-update add sing-box default >/dev/null 2>&1 || true
  rc-service sing-box restart
elif [ "$INIT" = "systemd" ]; then
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c ${DIR}/config.json
Restart=always
RestartSec=3
Environment=GOMEMLIMIT=${GMEM}MiB
Environment=GOGC=40
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
else
  echo "      未识别 init，手动启动: nohup sing-box run -c $DIR/config.json &"
fi

# ---------------------------------------------------------------- 日志轮转
# 按大小轮转（>5M 才切），保留 2 份压缩旧档 → 代理日志最多约 10M
echo "[6.5/7] 配置日志轮转"
install_pkgs logrotate
if command -v logrotate >/dev/null 2>&1; then
  mkdir -p /etc/logrotate.d
  cat > /etc/logrotate.d/sing-box <<EOF
${LOGFILE} {
    size 5M
    rotate 2
    missingok
    notifempty
    copytruncate
    compress
    delaycompress
}
EOF
  # Alpine 的 logrotate 要靠 crond 触发，Debian 系默认已有 cron.daily/logrotate
  if [ "$INIT" = "openrc" ]; then
    mkdir -p /etc/periodic/daily
    ln -sf /usr/bin/logrotate /etc/periodic/daily/logrotate 2>/dev/null || true
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
  fi
  echo "      已写入 /etc/logrotate.d/sing-box (5M x 2)"
else
  echo "      logrotate 装不上，跳过（日志增长很慢，可忽略）"
fi

# ---------------------------------------------------------------- 限制系统日志
if [ "$INIT" = "systemd" ]; then
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-size.conf <<'EOF'
SystemMaxUse=32M
SystemKeepFree=64M
EOF
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  echo "      journald 上限已设为 32M"
fi

sleep 2

# ---------------------------------------------------------------- 结果
PUBIP=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null \
     || curl -s --max-time 6 https://ipv4.icanhazip.com 2>/dev/null \
     || echo "YOUR.PUBLIC.IP")
PUBIP=$(echo "$PUBIP" | tr -d '[:space:]')
[ -n "$PUBIP" ] || PUBIP="YOUR.PUBLIC.IP"

INS=""
INS_H=""
if [ "$INSECURE" = "1" ]; then
  INS="&allow_insecure=1"
  INS_H="&insecure=1"
fi
TUIC_LINK="tuic://${TUIC_UUID}:${TUIC_PASS}@${PUBIP}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI}${INS}#tuic-${PORT}"
HY2_LINK="hysteria2://${HY2_PASS}@${PUBIP}:${HY2_PORT}?sni=${SNI}&alpn=h3${INS_H}#hy2-${HY2_PORT}"

echo "[7/7] 完成"
echo "----------------------------------------"
(ss -lunp 2>/dev/null || netstat -lunp 2>/dev/null) | grep -E "[:.]((${PORT})|(${HY2_PORT}))[[:space:]]" || echo "  未见监听，查 /var/log/sing-box.log"
echo "----------------------------------------"

{
  echo "服务器    : ${PUBIP}   (若你是 NAT 共享 IP，这里是你机器的出口 IP，"
  echo "                          连不通时请换成面板给你的入口 IP)"
  echo "TUIC 端口 : ${PORT}"
  echo "UUID      : ${TUIC_UUID}"
  echo "密码      : ${TUIC_PASS}"
  [ "$HY2" = "1" ] && { echo "HY2 端口  : ${HY2_PORT}"; echo "HY2 密码  : ${HY2_PASS}"; }
  echo "SNI       : ${SNI}"
  echo "证书      : $([ "$INSECURE" = "1" ] && echo '自签（客户端需跳过证书校验）' || echo "Let's Encrypt")"
  echo
  echo "TUIC 链接:"
  echo "$TUIC_LINK"
  if [ "$HY2" = "1" ]; then
    echo
    echo "HY2 链接:"
    echo "$HY2_LINK"
  fi
} | tee "$DIR/client-info.txt"

{
  printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\n\nproxies:\n'
  printf '  - name: tuic-%s\n    type: tuic\n    server: %s\n    port: %s\n    uuid: %s\n    password: %s\n' \
    "$PORT" "$PUBIP" "$PORT" "$TUIC_UUID" "$TUIC_PASS"
  printf '    alpn: [h3]\n    udp-relay-mode: native\n    congestion-controller: bbr\n    skip-cert-verify: true\n'
  if [ "$HY2" = "1" ]; then
    printf '  - name: hy2-%s\n    type: hysteria2\n    server: %s\n    port: %s\n    password: %s\n' \
      "$HY2_PORT" "$PUBIP" "$HY2_PORT" "$HY2_PASS"
    printf '    sni: %s\n    skip-cert-verify: true\n    alpn: [h3]\n' "$SNI"
  fi
  printf '\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies: ['
  printf 'tuic-%s' "$PORT"
  [ "$HY2" = "1" ] && printf ', hy2-%s' "$HY2_PORT"
  printf ', DIRECT]\n\nrules:\n  - GEOIP,CN,DIRECT\n  - MATCH,PROXY\n'
} > "$DIR/clash.yaml"

echo
echo "Clash YAML 已存: $DIR/clash.yaml"
echo "订阅 base64  : $(printf '%s\n%s\n' "$TUIC_LINK" "$([ "$HY2" = "1" ] && echo "$HY2_LINK")" | base64 -w0 2>/dev/null || printf '%s' "$TUIC_LINK" | base64 | tr -d '\n')"
echo
cat <<EOF
常用命令（init=$INIT，内存限制=${GMEM}MiB）
  状态   : ${STATUS}
  重启   : ${RESTART}
  日志   : tail -f /var/log/sing-box.log
  账号   : cat ${ACCT}
  改端口 : sh tuic-onekey.sh <新端口>
  卸载   : sh tuic-onekey.sh --uninstall

提醒
  1) UDP ${PORT}$([ "$HY2" = "1" ] && echo " 和 UDP ${HY2_PORT}") 必须在面板/防火墙放通，否则外面进不来
  2) 自签证书的客户端必须开"跳过证书校验"，否则握手失败
  3) 1G 小盘机器: 定期清日志  : > /var/log/sing-box.log
EOF
