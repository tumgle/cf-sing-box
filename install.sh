#!/bin/bash
# Cloudflared Tunnel 优选
# 协议: Vmess/Vless + WebSocket
# 多客户端订阅输出: Sing-box / Clash-Meta / V2RayN
# 用法: bash vmess_ws.sh

export LANG=en_US.UTF-8
red=$'[0;31m'; green=$'[0;32m'; yellow=$'[0;33m'; blue=$'[0;36m'; bblue=$'[0;34m'; plain=$'[0m'
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue(){ echo -e "\033[36m\033[01m$1\033[0m"; }
bblue(){ echo -e "\033[34m\033[01m$1\033[0m"; }
readp(){ read -p "$(yellow "$1")" $2 < /dev/tty; }
get_ip(){ [[ -n "$server_ip" ]] || server_ip=$(curl -s4m5 icanhazip.com -k || curl -s6m5 icanhazip.com -k); }
urlencode(){
  local str="${1}" out="" c i
  for ((i=0; i<${#str}; i++)); do
    c="${str:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  echo "$out"
}
protocol_label(){
  case "$1" in
    vless) echo "VLESS" ;;
    *) echo "VMESS" ;;
  esac
}
build_share_link(){
  local proto="$1" ps="$2" server="$3" port="$4" uuid_val="$5" host_val="$6" path_val="$7" tls_flag="$8" sni_val="$9"
  if [[ "$proto" == "vless" ]]; then
    local security="none" extra=""
    [[ "$tls_flag" == "true" || "$tls_flag" == "tls" ]] && security="tls"
    [[ -n "$sni_val" ]] && extra="${extra}&sni=$(urlencode "$sni_val")"
    echo "vless://${uuid_val}@${server}:${port}?encryption=none&security=${security}&type=ws&host=$(urlencode "$host_val")&path=$(urlencode "$path_val")${extra}&fp=chrome#$(urlencode "$ps")"
  else
    local vmess_json='{"v":"2","ps":"'"${ps}"'","add":"'"${server}"'","port":"'"${port}"'","id":"'"${uuid_val}"'","aid":"0","net":"ws","type":"none","host":"'"${host_val}"'","path":"'"${path_val}"'","tls":"'"${tls_flag}"'","sni":"'"${sni_val}"'","fp":"chrome"}'
    echo "vmess://$(echo -n "$vmess_json" | base64 -w0)"
  fi
}

[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

INSTALL_DIR="/etc/s-box"
CONFIG_FILE="${INSTALL_DIR}/sb.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SUB_DIR="${INSTALL_DIR}/sub"
NODE_DIR="${INSTALL_DIR}/nodes"
mkdir -p "$SUB_DIR" "$NODE_DIR"

# 默认值
DEFAULT_CDN="saas.sin.fan"
DEFAULT_SUB_PORT=8788

# ==================== 节点配置与元数据 ====================
node_meta_file(){ echo "${NODE_DIR}/${1}.conf"; }
has_node(){ [[ -f "$(node_meta_file "$1")" ]]; }
has_any_node(){ has_node vmess || has_node vless; }
is_argo_active(){ systemctl is-active argo &>/dev/null && [[ -f /etc/s-box/sbargoym.log ]]; }
clear_argo_state(){
  systemctl stop argo 2>/dev/null || true
  systemctl disable argo 2>/dev/null || true
  rm -f /etc/systemd/system/argo.service
  rm -f /etc/systemd/system/multi-user.target.wants/argo.service
  rm -f /etc/s-box/sbargoym.log /etc/s-box/sbargotoken.log /etc/s-box/cfvmadd_argo.txt
  systemctl daemon-reload &>/dev/null || true
}

get_saved_cdn_defaults(){
  if [[ -f "${INSTALL_DIR}/cdndomain.txt" ]]; then
    DEFAULT_NODE_CDN_DOMAIN=$(cat "${INSTALL_DIR}/cdndomain.txt")
  else
    DEFAULT_NODE_CDN_DOMAIN="$DEFAULT_CDN"
  fi
  if [[ -f "${INSTALL_DIR}/cdnhost.txt" ]]; then
    DEFAULT_NODE_CDN_HOST=$(cat "${INSTALL_DIR}/cdnhost.txt")
  else
    DEFAULT_NODE_CDN_HOST="$DEFAULT_NODE_CDN_DOMAIN"
  fi
}

validate_port(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

is_port_used(){
  local requested="$1" ignore_proto="${2:-}" current_port="" proto
  [[ -n "$ignore_proto" ]] && load_node_meta "$ignore_proto" 2>/dev/null && current_port="$NODE_PORT"

  for proto in vmess vless; do
    [[ "$proto" == "$ignore_proto" ]] && continue
    if load_node_meta "$proto" 2>/dev/null && [[ "$NODE_PORT" == "$requested" ]]; then
      return 0
    fi
  done

  if ss -tunlp 2>/dev/null | grep -qw "$requested"; then
    [[ -n "$current_port" && "$requested" == "$current_port" ]] && return 1
    return 0
  fi
  return 1
}

save_node_meta(){
  local proto="$1" listen_port="$2" uuid_val="$3" ws_path_val="$4" cdn_domain_val="$5" cdn_host_val="$6"
  mkdir -p "$INSTALL_DIR" "$SUB_DIR" "$NODE_DIR"
  cat > "$(node_meta_file "$proto")" << EOF
PROTOCOL=${proto}
PORT=${listen_port}
UUID=${uuid_val}
WS_PATH=${ws_path_val}
CDN_DOMAIN=${cdn_domain_val}
CDN_HOST=${cdn_host_val}
EOF
}

load_node_meta(){
  local proto="$1" file
  file="$(node_meta_file "$proto")"
  [[ -f "$file" ]] || return 1
  unset PROTOCOL PORT UUID WS_PATH
  # shellcheck disable=SC1090
  source "$file"
  get_saved_cdn_defaults
  [[ -n "${PROTOCOL:-}" && -n "${PORT:-}" && -n "${UUID:-}" && -n "${WS_PATH:-}" ]] || return 1
  NODE_PROTOCOL="$PROTOCOL"
  NODE_PORT="$PORT"
  NODE_UUID="$UUID"
  NODE_WS_PATH="$WS_PATH"
  NODE_CDN_DOMAIN="${CDN_DOMAIN:-$DEFAULT_NODE_CDN_DOMAIN}"
  NODE_CDN_HOST="${CDN_HOST:-$DEFAULT_NODE_CDN_HOST}"
  return 0
}

list_protocols(){
  local items=()
  has_node vmess && items+=(vmess)
  has_node vless && items+=(vless)
  printf '%s\n' "${items[@]}"
}

migrate_legacy_config(){
  has_any_node && return 0
  [[ -f "$CONFIG_FILE" ]] || return 0

  local legacy_proto legacy_port legacy_uuid legacy_path
  legacy_proto=$(jq -r '.inbounds[]? | select(.type=="vmess" or .type=="vless") | .type' "$CONFIG_FILE" 2>/dev/null | head -n 1)
  [[ -z "$legacy_proto" || "$legacy_proto" == "null" ]] && return 0
  legacy_port=$(jq -r ".inbounds[]? | select(.type==\"${legacy_proto}\") | .listen_port" "$CONFIG_FILE" 2>/dev/null | head -n 1)
  legacy_uuid=$(jq -r ".inbounds[]? | select(.type==\"${legacy_proto}\") | .users[0].uuid" "$CONFIG_FILE" 2>/dev/null | head -n 1)
  legacy_path=$(jq -r ".inbounds[]? | select(.type==\"${legacy_proto}\") | .transport.path" "$CONFIG_FILE" 2>/dev/null | head -n 1)
  [[ -z "$legacy_port" || "$legacy_port" == "null" || -z "$legacy_uuid" || "$legacy_uuid" == "null" || -z "$legacy_path" || "$legacy_path" == "null" ]] && return 0
  get_saved_cdn_defaults
  save_node_meta "$legacy_proto" "$legacy_port" "$legacy_uuid" "$legacy_path" "$DEFAULT_NODE_CDN_DOMAIN" "$DEFAULT_NODE_CDN_HOST"
}

# ==================== 读取当前配置 ====================
read_config(){
  migrate_legacy_config >/dev/null 2>&1 || true
  local proto
  for proto in vmess vless; do
    if load_node_meta "$proto"; then
      protocol="$NODE_PROTOCOL"
      port="$NODE_PORT"
      uuid="$NODE_UUID"
      ws_path="$NODE_WS_PATH"
      return 0
    fi
  done
  return 1
}

build_inbound_json(){
  local proto="$1" listen_port="$2" uuid_val="$3" ws_path_val="$4" user_block
  if [[ "$proto" == "vless" ]]; then
    user_block='{"uuid": "'"${uuid_val}"'"}'
  else
    user_block='{"uuid": "'"${uuid_val}"'", "alterId": 0}'
  fi

  cat << EOF
{
  "type": "${proto}",
  "tag": "${proto}-ws",
  "listen": "::",
  "listen_port": ${listen_port},
  "users": [${user_block}],
  "transport": {
    "type": "ws",
    "path": "${ws_path_val}",
    "max_early_data": 2048,
    "early_data_header_name": "Sec-WebSocket-Protocol"
  }
}
EOF
}

render_main_config(){
  local proto inbound_json="" first=true
  migrate_legacy_config >/dev/null 2>&1 || true

  for proto in vmess vless; do
    if load_node_meta "$proto"; then
      if $first; then
        first=false
      else
        inbound_json+=","
        inbound_json+=$'\n'
      fi
      inbound_json+="$(build_inbound_json "$NODE_PROTOCOL" "$NODE_PORT" "$NODE_UUID" "$NODE_WS_PATH")"
    fi
  done

  if $first; then
    cat > "$CONFIG_FILE" << 'EOF'
{
  "log": {"disabled": false, "level": "info", "timestamp": true},
  "inbounds": [{"type": "mixed", "listen": "::", "listen_port": 18080}],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
    return 0
  fi

  cat > "$CONFIG_FILE" << EOF
{
  "log": {"disabled": false, "level": "info", "timestamp": true},
  "inbounds": [
${inbound_json}
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
}

write_node_config(){
  local proto="$1" listen_port="$2" uuid_val="$3" ws_path_val="$4" cdn_domain_val="${5:-}" cdn_host_val="${6:-}"
  mkdir -p "$INSTALL_DIR" "$SUB_DIR" "$NODE_DIR"
  get_saved_cdn_defaults
  [[ -z "$cdn_domain_val" ]] && cdn_domain_val="$DEFAULT_NODE_CDN_DOMAIN"
  [[ -z "$cdn_host_val" ]] && cdn_host_val="$DEFAULT_NODE_CDN_HOST"
  save_node_meta "$proto" "$listen_port" "$uuid_val" "$ws_path_val" "$cdn_domain_val" "$cdn_host_val"
  render_main_config
}

write_service_file(){
  local desc="sing-box WS Service"
  if has_node vmess && has_node vless; then
    desc="sing-box VMESS/VLESS-WS Service"
  elif has_node vless; then
    desc="sing-box VLESS-WS Service"
  elif has_node vmess; then
    desc="sing-box VMESS-WS Service"
  fi
  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=${desc}
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${INSTALL_DIR}/sing-box run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
}

get_cdn_config(){
  get_saved_cdn_defaults
  cdn_domain="$DEFAULT_NODE_CDN_DOMAIN"
  cdn_host="$DEFAULT_NODE_CDN_HOST"
  # 客户端下发默认 TLS（CF 端 443）
  tls_val="tls"
  cdn_tls="true"
  cdn_sni="$cdn_host"
}

get_sub_port(){
  if [[ -f "${INSTALL_DIR}/subport.txt" ]]; then
    sub_port=$(cat "${INSTALL_DIR}/subport.txt")
  else
    sub_port="${DEFAULT_SUB_PORT}"
  fi
  get_ip

  # 优先用 HTTPS 域名
  if [[ -f "${INSTALL_DIR}/subdomain.txt" ]]; then
    sub_domain=$(cat "${INSTALL_DIR}/subdomain.txt")
    sub_url="https://${sub_domain}"
  else
    sub_url="http://${server_ip}:${sub_port}"
  fi
}

select_protocol(){
  local protocols=()
  has_node vmess && protocols+=(vmess)
  has_node vless && protocols+=(vless)
  case "${#protocols[@]}" in
    0) return 1 ;;
    1) echo "${protocols[0]}"; return 0 ;;
  esac

  echo "" > /dev/tty
  green "1: VMESS" > /dev/tty
  green "2: VLESS" > /dev/tty
  green "0: 返回" > /dev/tty
  readp "请选择要操作的节点协议: " proto_menu
  case "$proto_menu" in
    1|vmess|VMESS) echo "vmess" ;;
    2|vless|VLESS) echo "vless" ;;
    *) return 1 ;;
  esac
}

# ==================== 生成订阅文件 ====================
generate_sub(){
  migrate_legacy_config >/dev/null 2>&1 || true
  has_any_node || return 1
  get_cdn_config
  get_sub_port
  get_ip

  mkdir -p "$SUB_DIR"

  # CF Tunnel
  has_argo=false
  argogd=""
  vmadd_argo=""
  if is_argo_active; then
    has_argo=true
    argogd=$(cat /etc/s-box/sbargoym.log 2>/dev/null)
    if [[ -f /etc/s-box/cfvmadd_argo.txt ]]; then
      vmadd_argo=$(cat /etc/s-box/cfvmadd_argo.txt)
    fi
  fi

  # 客户端下发统一使用节点自己的 Host 作为 SNI
  if $has_argo; then
    node_addr="$vmadd_argo"
    node_tls="true"
    node_sni="$cdn_host"
  else
    node_host="$cdn_host"
    node_addr="$cdn_domain"
    node_tls="false"
    node_sni=""
  fi
  node_port=443

  local proto share_link node_name tag node_addr_local node_host_local node_sni_local node_domain_local
  local -a share_links clash_names singbox_names
  local clash_proxy_lines="" singbox_outbounds=""
  local first_outbound=true

  for proto in vmess vless; do
    load_node_meta "$proto" || continue
    node_domain_local="$NODE_CDN_DOMAIN"
    node_host_local="$NODE_CDN_HOST"
    node_name="${proto}-${node_host}"
    tag="${proto}-${node_host}"
    if $has_argo; then
      node_addr_local="${vmadd_argo:-$node_domain_local}"
      node_sni_local="$node_host_local"
    else
      node_addr_local="$node_domain_local"
      node_sni_local="$node_host_local"
    fi
    node_name="${proto}-${node_host_local}"
    tag="${proto}-${node_host_local}"
    share_link="$(build_share_link "$proto" "$node_name" "$node_addr_local" "$node_port" "$NODE_UUID" "$node_host_local" "$NODE_WS_PATH" "$node_tls" "$node_sni_local")"
    share_links+=("$share_link")
    clash_names+=("$node_name")
    singbox_names+=("$tag")

    if [[ "$proto" == "vless" ]]; then
      clash_proxy_lines+="    - { name: \"${node_name}\", type: vless, server: \"${node_addr_local}\", port: 443, uuid: \"${NODE_UUID}\", tls: true, servername: \"${node_sni_local}\", network: ws, ws-opts: { path: \"${NODE_WS_PATH}\", headers: { Host: \"${node_host_local}\" } } }"$'\n'
      current_outbound=$(cat <<EOF
    {
      "type": "vless",
      "tag": "${tag}",
      "server": "${node_addr_local}",
      "server_port": 443,
      "uuid": "${NODE_UUID}",
      "transport": {
        "type": "ws",
        "path": "${NODE_WS_PATH}",
        "headers": {"Host": "${node_host_local}"},
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {
        "enabled": true,
        "server_name": "${node_sni_local}",
        "insecure": false,
        "utls": {"enabled": true, "fingerprint": "chrome"}
      }
    }
EOF
)
    else
      clash_proxy_lines+="    - { name: \"${node_name}\", type: vmess, server: \"${node_addr_local}\", port: 443, uuid: \"${NODE_UUID}\", alterId: 0, cipher: auto, tls: true, servername: \"${node_sni_local}\", network: ws, ws-opts: { path: \"${NODE_WS_PATH}\", headers: { Host: \"${node_host_local}\" } } }"$'\n'
      current_outbound=$(cat <<EOF
    {
      "type": "vmess",
      "tag": "${tag}",
      "server": "${node_addr_local}",
      "server_port": 443,
      "uuid": "${NODE_UUID}",
      "security": "auto",
      "alter_id": 0,
      "transport": {
        "type": "ws",
        "path": "${NODE_WS_PATH}",
        "headers": {"Host": "${node_host_local}"},
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {
        "enabled": true,
        "server_name": "${node_sni_local}",
        "insecure": false,
        "utls": {"enabled": true, "fingerprint": "chrome"}
      }
    }
EOF
)
    fi

    if $first_outbound; then
      singbox_outbounds+="$current_outbound"
      first_outbound=false
    else
      singbox_outbounds+=","$'\n'"$current_outbound"
    fi
  done

  [[ ${#share_links[@]} -gt 0 ]] || return 1

  local share_payload clash_names_yaml singbox_names_json
  share_payload="$(printf '%s\n' "${share_links[@]}")"
  printf '%s' "$share_payload" | base64 -w0 > "${SUB_DIR}/base64.txt"
  printf '%s' "$share_payload" > "${SUB_DIR}/links.txt"

  clash_names_yaml=$(printf '"%s", ' "${clash_names[@]}")
  clash_names_yaml="${clash_names_yaml%, }"
  singbox_names_json=$(printf '"%s", ' "${singbox_names[@]}")
  singbox_names_json="${singbox_names_json%, }"

  # Clash-Meta 完整配置（含 DNS 和路由规则）
  cat > "${SUB_DIR}/clash.yaml" << YAMLEOF
mixed-port: 7890
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
external-controller: 127.0.0.1:9090
dns:
  enable: true
  ipv6: false
  default-nameserver: ["223.5.5.5", "119.29.29.29", "114.114.114.114"]
  enhanced-mode: fake-ip
  fake-ip-range: 187.18.0.1/16
  use-hosts: true
  respect-rules: true
  proxy-server-nameserver: ["223.5.5.5", "119.29.29.29"]
  nameserver: ["223.5.5.5", "114.114.114.114"]
  fallback: ["1.1.1.1", "8.8.8.8"]
  fallback-filter:
    geoip: true
    geoip-code: CN
    geosite: [gfw]

proxies:
${clash_proxy_lines}proxy-groups:
    - { name: CDN, type: select, proxies: [自动选择, 故障转移, ${clash_names_yaml}] }
    - { name: 自动选择, type: url-test, proxies: [${clash_names_yaml}], url: "http://www.gstatic.com/generate_204", interval: 86400 }
    - { name: 故障转移, type: fallback, proxies: [${clash_names_yaml}], url: "http://www.gstatic.com/generate_204", interval: 7200 }
rules:
  - IP-CIDR,1.1.1.1/32,CDN,no-resolve
  - IP-CIDR,8.8.8.8/32,CDN,no-resolve
  - DOMAIN-SUFFIX,services.googleapis.cn,CDN
  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,CDN
  - DOMAIN,developer.apple.com,CDN
  - DOMAIN-SUFFIX,digicert.com,CDN
  - DOMAIN,ocsp.apple.com,CDN
  - DOMAIN-SUFFIX,apple-dns.net,CDN
  - DOMAIN,testflight.apple.com,CDN
  - DOMAIN-SUFFIX,apps.apple.com,CDN
  - DOMAIN-SUFFIX,blobstore.apple.com,CDN
  - DOMAIN,cvws.icloud-content.com,CDN
  - DOMAIN-SUFFIX,mzstatic.com,DIRECT
  - DOMAIN-SUFFIX,icloud.com,DIRECT
  - DOMAIN-SUFFIX,icloud-content.com,DIRECT
  - DOMAIN-SUFFIX,me.com,DIRECT
  - DOMAIN-SUFFIX,aaplimg.com,DIRECT
  - DOMAIN-SUFFIX,cdn-apple.com,DIRECT
  - DOMAIN-SUFFIX,apple.com,DIRECT
  - DOMAIN-SUFFIX,apple-cloudkit.com,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,cn.bing.com,DIRECT
  - DOMAIN-SUFFIX,weibo.com,DIRECT
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,tmall.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,126.com,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,iqiyi.com,DIRECT
  - DOMAIN-SUFFIX,microsoft.com,DIRECT
  - DOMAIN-SUFFIX,office.com,DIRECT
  - DOMAIN-SUFFIX,tencent.com,DIRECT
  - DOMAIN-SUFFIX,netease.com,DIRECT
  - DOMAIN-SUFFIX,youku.com,DIRECT
  - DOMAIN-SUFFIX,xiami.com,DIRECT
  - DOMAIN-SUFFIX,ele.me,DIRECT
  - DOMAIN-SUFFIX,meituan.com,DIRECT
  - DOMAIN-SUFFIX,douban.com,DIRECT
  - DOMAIN-SUFFIX,sinaapp.com,DIRECT
  - DOMAIN-SUFFIX,xunlei.com,DIRECT
  - DOMAIN-SUFFIX,kuaishou.com,DIRECT
  - DOMAIN-SUFFIX,sohu.com,DIRECT
  - DOMAIN-SUFFIX,sogou.com,DIRECT
  - DOMAIN-KEYWORD,baidu,DIRECT
  - DOMAIN-KEYWORD,taobao,DIRECT
  - DOMAIN-KEYWORD,alipay,DIRECT
  - DOMAIN-KEYWORD,alicdn,DIRECT
  - DOMAIN-KEYWORD,microsoft,DIRECT
  - DOMAIN-SUFFIX,google.com,CDN
  - DOMAIN-SUFFIX,youtube.com,CDN
  - DOMAIN-SUFFIX,googlevideo.com,CDN
  - DOMAIN-SUFFIX,ytimg.com,CDN
  - DOMAIN-SUFFIX,youtu.be,CDN
  - DOMAIN-SUFFIX,googleapis.com,CDN
  - DOMAIN-SUFFIX,twitter.com,CDN
  - DOMAIN-SUFFIX,x.com,CDN
  - DOMAIN-SUFFIX,t.co,CDN
  - DOMAIN-KEYWORD,twitter,CDN
  - DOMAIN-SUFFIX,facebook.com,CDN
  - DOMAIN-SUFFIX,fb.me,CDN
  - DOMAIN-SUFFIX,fbcdn.net,CDN
  - DOMAIN-KEYWORD,facebook,CDN
  - DOMAIN-SUFFIX,instagram.com,CDN
  - DOMAIN-KEYWORD,instagram,CDN
  - DOMAIN-SUFFIX,telegram.org,CDN
  - DOMAIN-SUFFIX,t.me,CDN
  - DOMAIN-SUFFIX,telegra.ph,CDN
  - DOMAIN-SUFFIX,whatsapp.com,CDN
  - DOMAIN-KEYWORD,whatsapp,CDN
  - DOMAIN-SUFFIX,tiktok.com,CDN
  - DOMAIN-SUFFIX,openai.com,CDN
  - DOMAIN-SUFFIX,ai.com,CDN
  - DOMAIN-SUFFIX,netflix.com,CDN
  - DOMAIN-SUFFIX,nflxvideo.com,CDN
  - DOMAIN-SUFFIX,spotify.com,CDN
  - DOMAIN-SUFFIX,reddit.com,CDN
  - DOMAIN-KEYWORD,reddit,CDN
  - DOMAIN-SUFFIX,pinterest.com,CDN
  - DOMAIN-SUFFIX,medium.com,CDN
  - DOMAIN-SUFFIX,github.com,CDN
  - DOMAIN-KEYWORD,github,CDN
  - DOMAIN-SUFFIX,docker.com,CDN
  - DOMAIN-SUFFIX,twitch.tv,CDN
  - IP-CIDR,91.108.4.0/22,CDN,no-resolve
  - IP-CIDR,91.108.8.0/21,CDN,no-resolve
  - IP-CIDR,91.108.16.0/22,CDN,no-resolve
  - IP-CIDR,91.108.56.0/22,CDN,no-resolve
  - IP-CIDR,149.154.160.0/20,CDN,no-resolve
  - IP-CIDR6,2001:67c:4e8::/48,CDN,no-resolve
  - IP-CIDR6,2001:b28:f23f::/48,CDN,no-resolve
  - DOMAIN-SUFFIX,cn,DIRECT
  - DOMAIN-KEYWORD,-cn,DIRECT
  - GEOIP,CN,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - DOMAIN-SUFFIX,local,DIRECT
  - MATCH,CDN
YAMLEOF

  # Sing-box 完整配置（模板 + 节点）
  cat > "${SUB_DIR}/singbox.json" << SBEOF
{
  "dns": {
    "servers": [
      {"type": "local", "tag": "local"},
      {"type": "udp", "tag": "remote", "server": "1.1.1.1"},
      {"type": "udp", "tag": "cn", "server": "223.5.5.5"}
    ],
    "rules": [{"rule_set": ["geosite-cn"], "action": "route", "server": "cn"}],
    "final": "remote"
  },
  "inbounds": [
    {"tag": "tun-in", "type": "tun", "address": ["172.19.0.1/30", "2001:0470:f9da:fdfa::1/64"], "auto_route": true, "mtu": 9000, "stack": "system", "strict_route": true, "route_exclude_address_set": ["geoip-cn"]},
    {"tag": "socks-in", "type": "socks", "listen": "127.0.0.1", "listen_port": 2333},
    {"tag": "mixed-in", "type": "mixed", "listen": "127.0.0.1", "listen_port": 2334}
  ],
  "outbounds": [
    {"tag": "DIRECT", "type": "direct"},
    {"tag": "节点选择", "type": "selector", "interrupt_exist_connections": true, "outbounds": ["自动选择", ${singbox_names_json}]},
    {"tag": "自动选择", "type": "urltest", "url": "https://www.gstatic.com/generate_204", "interval": "10m", "tolerance": 50, "outbounds": [${singbox_names_json}]},
${singbox_outbounds}
  ],
  "route": {
    "rules": [
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"rule_set": ["category-ads-all"], "action": "reject", "method": "default", "no_drop": false},
      {"ip_is_private": true, "action": "route", "outbound": "DIRECT"},
      {"clash_mode": "关闭代理", "action": "route", "outbound": "DIRECT"},
      {"clash_mode": "全局代理", "action": "route", "outbound": "节点选择"},
      {"rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "DIRECT"}
    ],
    "auto_detect_interface": true,
    "final": "节点选择",
    "default_domain_resolver": {"server": "remote"},
    "rule_set": [
      {"tag": "geosite-geolocation-!cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs", "download_detour": "节点选择"},
      {"tag": "geoip-cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/srs/cn.srs", "download_detour": "节点选择"},
      {"tag": "geosite-cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", "download_detour": "节点选择"},
      {"tag": "category-ads-all", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs", "download_detour": "节点选择"}
    ]
  },
  "experimental": {"cache_file": {"enabled": true}, "clash_api": {"default_mode": "海外代理", "external_controller": "127.0.0.1:9090", "secret": ""}}
}
SBEOF

  # mihomo.yaml 作为 clash.yaml 的别名
  cp "${SUB_DIR}/clash.yaml" "${SUB_DIR}/mihomo.yaml"
  cp "${SUB_DIR}/singbox.json" "${SUB_DIR}/outbounds.json"

  green "订阅文件已更新"
}

# ==================== 安装 Caddy ====================
install_caddy(){
  if command -v caddy &>/dev/null; then
    green "Caddy 已安装: $(caddy version 2>/dev/null | awk '{print $2}')"
    return
  fi
  green "安装 Caddy..."
  # 自动检测架构
  local arch=$(uname -m)
  case $arch in
    x86_64) local plat="amd64" ;;
    aarch64) local plat="arm64" ;;
    armv7l) local plat="armv7" ;;
    *) red "不支持的架构: $arch" && return 1 ;;
  esac
  # 从 GitHub 下载
  local latest=$(curl -sfL --max-time 10 "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v\(.*\)".*/\1/')
  [[ -z "$latest" ]] && latest="2.11.2"
  local url="https://github.com/caddyserver/caddy/releases/download/v${latest}/caddy_${latest}_linux_${plat}.tar.gz"
  green "下载 Caddy v${latest} (${plat})..."
  curl -sfL --max-time 60 --retry 2 -o /tmp/caddy.tar.gz "$url"
  if [[ -f /tmp/caddy.tar.gz ]]; then
    rm -f /tmp/caddy_extracted 2>/dev/null
    tar xzf /tmp/caddy.tar.gz -C /tmp/ 2>/dev/null
    # Find the binary (might be in a subdirectory)
    local caddy_bin=$(find /tmp -name "caddy" -type f 2>/dev/null | head -1)
    if [[ -n "$caddy_bin" ]]; then
      mv "$caddy_bin" /usr/local/bin/caddy
      chmod +x /usr/local/bin/caddy
      rm -rf /tmp/caddy* 2>/dev/null
      if command -v caddy &>/dev/null; then
        green "Caddy 安装完成: $(caddy version 2>/dev/null | awk '{print $2}')"
        return 0
      fi
    fi
  fi
  red "Caddy 安装失败"
  return 1
}

# ==================== 配置 Caddy HTTPS ====================
setup_caddy_sub(){
  migrate_legacy_config >/dev/null 2>&1 || true
  if ! has_any_node; then red "未找到节点配置"; return; fi
  get_sub_port
  install_caddy || return

  local existing_domain=""
  [[ -f "${INSTALL_DIR}/subdomain.txt" ]] && existing_domain=$(cat "${INSTALL_DIR}/subdomain.txt")
  if [[ -n "$existing_domain" ]]; then
    green "当前订阅域名: ${existing_domain}"
  fi

  echo ""
  readp "输入订阅服务域名（用于自动 HTTPS 证书）: " sub_domain
  [[ -z "$sub_domain" ]] && red "域名不能为空" && return

  mkdir -p /etc/caddy

  cat > /etc/caddy/Caddyfile << EOF
${sub_domain} {
    root * /etc/s-box/sub
    file_server

    @clash expression \`{query.type} in ['clash','mihomo']\`
    @sb expression \`{query.type} in ['singbox','sb']\`
    @ua_clash header_regexp User-Agent "(?i)(clash|meta|mihomo|stash|verge)"
    @ua_sb header_regexp User-Agent "(?i)(sing-box|singbox|sfa|sfi|sfw|hiddify)"

    handle @clash {
        rewrite * /clash.yaml
    }
    handle @sb {
        rewrite * /singbox.json
    }
    handle @ua_clash {
        rewrite * /clash.yaml
    }
    handle @ua_sb {
        rewrite * /singbox.json
    }
    handle {
        rewrite * /base64.txt
    }

    encode gzip
    header Access-Control-Allow-Origin *
}
EOF

  cat > /etc/systemd/system/caddy.service << SVCEOF
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable caddy &>/dev/null
  systemctl restart caddy
  sleep 5

  if systemctl is-active caddy &>/dev/null; then
    green "Caddy 已启动"
    sub_url="https://${sub_domain}"
    echo "$sub_domain" > "${INSTALL_DIR}/subdomain.txt"
    echo "${sub_port}" > "${INSTALL_DIR}/subport.txt"
  else
    red "Caddy 启动失败，请查看日志: journalctl -u caddy -f"
    red "可能是域名未正确解析到服务器IP，请确认 DNS 设置"
    return
  fi
}

# ==================== 重载 Caddy 订阅服务 ====================
reload_sub(){
  if systemctl is-active caddy &>/dev/null; then
    systemctl reload caddy &>/dev/null
    green "订阅已重载"
  fi
}

# ==================== 1. 安装 sing-box ====================
install_singbox(){
  migrate_legacy_config >/dev/null 2>&1 || true
  if has_any_node && systemctl is-active sing-box &>/dev/null; then
    green "sing-box 已安装并运行中"
    return
  fi
  green "安装 sing-box 内核..."
  mkdir -p "$INSTALL_DIR"
  local cpu cpu_name
  cpu=$(uname -m)
  case $cpu in
    x86_64) cpu_name="amd64" ;;
    aarch64) cpu_name="arm64" ;;
    armv7l) cpu_name="armv7" ;;
    *) red "不支持的架构: $cpu" && return ;;
  esac

  local sbcore
  sbcore=$(curl -Ls --max-time 10 "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -n 1)
  [[ -z "$sbcore" ]] && sbcore="1.11.8"

  local sbname="sing-box-${sbcore}-linux-${cpu_name}"
  curl -L -o "${INSTALL_DIR}/sing-box.tar.gz" -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbname}.tar.gz"
  if [[ -f "${INSTALL_DIR}/sing-box.tar.gz" ]]; then
    tar xzf "${INSTALL_DIR}/sing-box.tar.gz" -C "$INSTALL_DIR"
    mv "${INSTALL_DIR}/${sbname}/sing-box" "${INSTALL_DIR}/"
    rm -rf "${INSTALL_DIR}"/{sing-box.tar.gz,"${sbname}"}
    chmod +x "${INSTALL_DIR}/sing-box"
    green "sing-box v$(${INSTALL_DIR}/sing-box version 2>/dev/null | awk '/version/{print $NF}') 安装完成"
    
    [[ ! -f "$CONFIG_FILE" ]] && render_main_config
    write_service_file
    systemctl daemon-reload
    systemctl enable sing-box &>/dev/null
    systemctl start sing-box
    sleep 2
    if systemctl is-active sing-box &>/dev/null; then
      green "sing-box 服务已启动 ✅"
    else
      yellow "sing-box 服务已安装但未启动，请设置节点后启动"
    fi
  else
    red "下载 sing-box 失败" && return
  fi
}

cloudflared_install(){
  if [[ -f /etc/s-box/cloudflared ]]; then
    green "cloudflared 已安装"
    return
  fi
  yellow "正在安装 cloudflared..."
  local cpu
  case $(uname -m) in
    x86_64) cpu="amd64" ;;
    aarch64) cpu="arm64" ;;
    *) red "不支持的架构: $(uname -m)" && return 1 ;;
  esac
  curl -L -o /etc/s-box/cloudflared -# --retry 2 \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}"
  if [[ -f /etc/s-box/cloudflared ]]; then
    chmod +x /etc/s-box/cloudflared
    green "cloudflared 安装完成"
  else
    red "cloudflared 下载失败" && return 1
  fi
}

# ==================== 2/10. 设置 vmess/vless 节点 ====================
setup_node_common(){
  local proto="${1:-vmess}"
  local proto_label old_port="" proto_cdn_domain="" proto_cdn_host=""
  proto_label=$(protocol_label "$proto")
  install_singbox || return

  get_ip
  [[ -z "$server_ip" ]] && red "无法获取服务器IP" && return

  if load_node_meta "$proto" 2>/dev/null; then
    old_port="$NODE_PORT"
    proto_cdn_domain="$NODE_CDN_DOMAIN"
    proto_cdn_host="$NODE_CDN_HOST"
    yellow "已存在 ${proto_label}-WS 节点，本次操作会重建该协议节点"
  fi

  readp "设置 ${proto_label}-WS 端口（回车随机10000-65535）: " port
  if [[ -z "$port" ]]; then
    port=$(shuf -i 10000-65535 -n 1)
    until ! is_port_used "$port" "$proto"; do
      port=$(shuf -i 10000-65535 -n 1)
    done
    blue "随机端口: $port"
  else
    validate_port "$port" || { red "端口必须在 1-65535 之间"; return; }
    is_port_used "$port" "$proto" && [[ "$port" != "$old_port" ]] && { red "端口 $port 已被占用"; return; }
    blue "端口: $port"
  fi
  echo ""

  yellow "是否安装 CF Tunnel？[y/n]"
  readp "请选择: " use_argo
  echo ""

  has_argo=false
  if [[ "$use_argo" == [yY] ]]; then
    cloudflared_install || return
    existing_token=""
    existing_domain=""
    [[ -f /etc/s-box/sbargotoken.log ]] && existing_token=$(cat /etc/s-box/sbargotoken.log 2>/dev/null)
    [[ -f /etc/s-box/sbargoym.log ]] && existing_domain=$(cat /etc/s-box/sbargoym.log 2>/dev/null)
    if [[ -n "$existing_token" && -n "$existing_domain" ]]; then
      green "当前 CF Tunnel 域名: ${existing_domain}"
      green "当前 CF Tunnel Token: ${existing_token}"
      echo
      readp "是否重新配置？[y/n]: " recon_argo
      if [[ "$recon_argo" != [yY] ]]; then
        has_argo=true
        argogd="$existing_domain"
        argotoken="$existing_token"
      fi
    fi
    if ! $has_argo; then
      green "请进入 Cloudflare Zero Trust -> 网络 -> 连接器 创建固定隧道"
      readp "输入 CF Tunnel Token: " argotoken
      readp "输入 CF Tunnel 域名: " argodomain
      [[ -z "$argotoken" ]] && red "Token 不能为空" && return
      [[ -z "$argodomain" ]] && red "域名不能为空" && return

      ps -ef | grep "cloudflared.*run" | awk '{print $2}' | xargs kill -9 2>/dev/null

      cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare CF Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/s-box/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token ${argotoken}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload && systemctl enable argo && systemctl start argo
      sleep 5
      if systemctl is-active argo &>/dev/null; then
        green "CF Tunnel 服务已启动"
        has_argo=true
        argogd="$argodomain"
        echo "$argodomain" > /etc/s-box/sbargoym.log
        echo "$argotoken" > /etc/s-box/sbargotoken.log
      else
        red "CF Tunnel 服务启动失败，跳过"
      fi
    fi
  else
    clear_argo_state
  fi

  # CDN 配置
  get_saved_cdn_defaults
  [[ -z "$proto_cdn_domain" ]] && proto_cdn_domain="$DEFAULT_NODE_CDN_DOMAIN"
  [[ -z "$proto_cdn_host" ]] && proto_cdn_host="$DEFAULT_NODE_CDN_HOST"
  last_cdn="$proto_cdn_domain"
  readp "输入优选域名或IP（回车默认 ${last_cdn}）: " cdn_domain
  [[ -z "$cdn_domain" ]] && cdn_domain="$last_cdn"
  blue "优选域名/IP: $cdn_domain"
  echo ""

  # 启用 CF Tunnel 时，Tunnel 域名只用于链路复用提示；客户端下发仍使用你输入的 Host
  if $has_argo; then
    blue "CF Tunnel 域名: $argogd"
    readp "设置 Host 伪装域名（必填）: " cdn_host
    [[ -z "$cdn_host" ]] && red "域名不能为空" && return
    blue "Host / SNI: $cdn_host"
    echo ""
  else
    readp "设置 Host 伪装域名（必填）: " cdn_host
    [[ -z "$cdn_host" ]] && red "域名不能为空" && return
    blue "Host 伪装: $cdn_host"
    echo ""
  fi

  # 服务端 sing-box 不配置 TLS（CF tunnel 处理加密）
  # 客户端下发默认 TLS（CF 端 443 HTTPS）
  tls_val="tls"; cdn_tls="true"; cdn_sni="$cdn_host"

  # 生成 UUID 和路径
  uuid=$("${INSTALL_DIR}/sing-box" generate uuid)
  ws_path="/${uuid:0:16}-ws"

  write_node_config "$proto" "$port" "$uuid" "$ws_path" "$cdn_domain" "$cdn_host"
  write_service_file

  systemctl daemon-reload && systemctl enable sing-box &>/dev/null
  systemctl restart sing-box && sleep 2
  if systemctl is-active sing-box &>/dev/null; then
    green "sing-box 服务运行正常 ✅"
  else
    red "sing-box 服务启动失败"
    systemctl status sing-box
    return
  fi
  echo ""

  # 保存配置
  echo "$cdn_domain" > "${INSTALL_DIR}/cdndomain.txt"
  echo "$cdn_host" > "${INSTALL_DIR}/cdnhost.txt"
  echo "${sub_port:-${DEFAULT_SUB_PORT}}" > "${INSTALL_DIR}/subport.txt"

  # 生成订阅并重载 Caddy
  generate_sub
  reload_sub

  echo ""
  green "${proto_label}-WS 节点配置完成 ✅"
}

setup_node(){
  setup_node_common vmess
}

setup_vless_node(){
  setup_node_common vless
}

# ==================== 3. 节点修改 ====================
modify_node(){
  migrate_legacy_config >/dev/null 2>&1 || true
  if ! has_any_node; then red "未找到节点配置，请先设置节点"; sleep 2; return; fi
  get_cdn_config
  local selected_proto proto_label
  selected_proto="$(select_protocol)" || return
  load_node_meta "$selected_proto" || { red "读取节点失败"; return; }
  protocol="$NODE_PROTOCOL"; port="$NODE_PORT"; uuid="$NODE_UUID"; ws_path="$NODE_WS_PATH"; cdn_domain="$NODE_CDN_DOMAIN"; cdn_host="$NODE_CDN_HOST"
  proto_label=$(protocol_label "$protocol")

  echo ""
  bblue "╭──────────────────────────────────────────────╮"
  bblue "│  当前配置"
  bblue "╰──────────────────────────────────────────────╯"
  echo "  协议: $proto_label"
  echo "  端口: $port"
  echo "  优选: $cdn_domain"
  echo "  Host: $cdn_host"
  echo ""

  green "1: 修改端口"
  green "2: 修改优选域名/IP"
  green "3: 修改 Host"
  green "4: 切换协议（vmess/vless）"
  green "5: 删除节点"
  green "0: 返回"
  echo ""
  readp "请选择: " smenu

  case "$smenu" in
    1)
      readp "输入新端口: " new_port
      [[ -z "$new_port" ]] && yellow "端口不能为空" && return
      validate_port "$new_port" || { red "端口必须在 1-65535 之间"; return; }
      is_port_used "$new_port" "$protocol" && [[ "$new_port" != "$port" ]] && { red "端口 $new_port 已被占用"; return; }
      write_node_config "$protocol" "$new_port" "$uuid" "$ws_path" "$cdn_domain" "$cdn_host"
      write_service_file
      port="$new_port"
      green "端口已更新: $new_port"
      ;;
    2)
      readp "输入新优选域名/IP: " new_cdn
      [[ -z "$new_cdn" ]] && yellow "不能为空" && return
      write_node_config "$protocol" "$port" "$uuid" "$ws_path" "$new_cdn" "$cdn_host"
      echo "$new_cdn" > "${INSTALL_DIR}/cdndomain.txt"
      cdn_domain="$new_cdn"
      green "优选已更新: $new_cdn"
      ;;
    3)
      readp "输入新 Host 伪装域名: " new_host
      [[ -z "$new_host" ]] && yellow "不能为空" && return
      write_node_config "$protocol" "$port" "$uuid" "$ws_path" "$cdn_domain" "$new_host"
      echo "$new_host" > "${INSTALL_DIR}/cdnhost.txt"
      cdn_host="$new_host"
      green "Host 已更新: $new_host"
      ;;
    4)
      if [[ "$protocol" == "vless" ]]; then
        new_proto="vmess"
      else
        new_proto="vless"
      fi
      new_proto_label=$(protocol_label "$new_proto")
      if has_node "$new_proto"; then
        red "${new_proto_label} 节点已存在，当前脚本支持双节点共存，请直接使用对应菜单维护"
        return
      fi
      yellow "当前协议: $proto_label -> 将切换为: $new_proto_label"
      readp "确认切换？[y/n]: " switch_confirm
      [[ "$switch_confirm" != [yY] ]] && return
      rm -f "$(node_meta_file "$protocol")"
      write_node_config "$new_proto" "$port" "$uuid" "$ws_path" "$cdn_domain" "$cdn_host"
      write_service_file
      protocol="$new_proto"
      proto_label="$new_proto_label"
      green "协议已切换为: $new_proto_label"
      ;;
    5)
      yellow "确认删除以下节点？"
      echo "  协议: $proto_label"
      echo "  端口: $port"
      echo "  Host: $cdn_host"
      readp "确认？[y/n]: " del_confirm
      if [[ "$del_confirm" == [yY] ]]; then
        rm -f "$(node_meta_file "$protocol")"
        if has_any_node; then
          render_main_config
          write_service_file
          systemctl daemon-reload &>/dev/null
          systemctl restart sing-box 2>/dev/null || true
          generate_sub 2>/dev/null || true
          reload_sub
          green "${proto_label} 节点已删除，其他节点已保留"
        else
          systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null
          rm -f "$SERVICE_FILE"
          rm -f "$CONFIG_FILE"
          rm -f "${INSTALL_DIR}/cdndomain.txt" \
                "${INSTALL_DIR}/cdnhost.txt" \
                "${INSTALL_DIR}/subport.txt" \
                "${INSTALL_DIR}/subdomain.txt"
          clear_argo_state
          render_main_config
          systemctl daemon-reload &>/dev/null
          rm -rf "${INSTALL_DIR}/sub"
          mkdir -p "${SUB_DIR}"
          rm -f "${SUB_DIR}/base64.txt" \
                "${SUB_DIR}/links.txt" \
                "${SUB_DIR}/clash.yaml" \
                "${SUB_DIR}/mihomo.yaml" \
                "${SUB_DIR}/singbox.json" \
                "${SUB_DIR}/outbounds.json"
          green "节点已删除"
        fi
      fi
      return
      ;;
    0) return ;;
    *) yellow "输入错误" && return ;;
  esac

  echo ""
  systemctl restart sing-box && sleep 2
  if systemctl is-active sing-box &>/dev/null; then
    generate_sub
    reload_sub
    green "已更新并同步订阅 ✅"
  else
    red "服务重启失败"
    systemctl status sing-box
  fi
}

# ==================== 4. 查看节点 ====================
show_node(){
  migrate_legacy_config >/dev/null 2>&1 || true
  if ! has_any_node; then red "未找到节点配置"; sleep 2; return; fi
  get_cdn_config
  local proto proto_label node_link

  echo ""
  for proto in vmess vless; do
    load_node_meta "$proto" || continue
    proto_label=$(protocol_label "$proto")
    local show_cdn_domain show_cdn_host show_server show_sni
    show_cdn_domain="$NODE_CDN_DOMAIN"
    show_cdn_host="$NODE_CDN_HOST"
    if is_argo_active; then
      show_sni="$show_cdn_host"
      show_server="${show_cdn_domain}"
    else
      show_server="$show_cdn_domain"
      show_sni="$show_cdn_host"
    fi
    bblue "╭──────────────────────────────────────────────╮"
    bblue "│  ${proto_label} 节点信息"
    bblue "╰──────────────────────────────────────────────╯"
    echo "  协议:    $proto_label"
    echo "  端口:    $NODE_PORT"
    echo "  UUID:    $NODE_UUID"
    echo "  Path:    $NODE_WS_PATH"
    echo "  优选:    $show_cdn_domain"
    echo "  Host:    $show_cdn_host"
    [[ -n "$show_sni" ]] && echo "  SNI:     $show_sni"
    echo ""

    node_link="$(build_share_link "$proto" "${proto}-cdn_${show_cdn_domain}" "$show_server" "443" "$NODE_UUID" "$show_cdn_host" "$NODE_WS_PATH" "$tls_val" "$show_sni")"
    green "${proto_label} 分享链接:"
    echo -e "${yellow}${node_link}${plain}"
    echo ""
  done
}

# ==================== 5. 查看订阅链接 ====================
show_sub(){
  migrate_legacy_config >/dev/null 2>&1 || true
  if ! has_any_node; then red "未找到节点配置"; sleep 2; return; fi
  get_sub_port

  # 确保订阅文件存在
  generate_sub 2>/dev/null

  echo ""
  bblue "╭──────────────────────────────────────────────╮"
  bblue "│  在线订阅链接 (直接导入客户端)"
  bblue "╰──────────────────────────────────────────────╯"
  echo "  通用订阅:  ${yellow}${sub_url}${plain}"
  echo "  Base64:    ${yellow}${sub_url}?type=base64${plain}"
  echo "  Clash:     ${yellow}${sub_url}?type=clash${plain}"
  echo "  Sing-box:  ${yellow}${sub_url}?type=singbox${plain}"
  echo ""

  bblue "╭──────────────────────────────────────────────╮"
  bblue "│  本地订阅文件"
  bblue "╰──────────────────────────────────────────────╯"
  echo "  Base64:   ${yellow}${SUB_DIR}/base64.txt${plain}"
  echo "  原始链接: ${yellow}${SUB_DIR}/links.txt${plain}"
  echo "  Mihomo:   ${yellow}${SUB_DIR}/mihomo.yaml${plain}"
  echo "  Singbox:  ${yellow}${SUB_DIR}/singbox.json${plain}"
  echo ""

  yellow "订阅服务: Caddy 静态分发（无需 Python）"
  echo ""
}

# ==================== 6. 查看状态 ====================
show_status(){
  echo ""
  bblue "╭──────────────────────────────────────────────╮"
  bblue "│  服务状态"
  bblue "╰──────────────────────────────────────────────╯"
  echo ""
  if systemctl is-active sing-box &>/dev/null; then
    green "  sing-box: 运行中 ✅"
  elif [[ -f "$CONFIG_FILE" ]]; then
    yellow "  sing-box: 已安装，未运行"
  else
    red "  sing-box: 未安装"
  fi
  echo ""
  if command -v "${INSTALL_DIR}/sing-box" &>/dev/null; then
    blue "  版本: $(${INSTALL_DIR}/sing-box version 2>/dev/null | awk '/version/{print $NF}')"
  fi
  echo ""

  migrate_legacy_config >/dev/null 2>&1 || true
  local protocols=()
  has_node vmess && protocols+=("VMESS")
  has_node vless && protocols+=("VLESS")
  if [[ ${#protocols[@]} -gt 0 ]]; then
    blue "  已配置节点: ${protocols[*]}"
  else
    yellow "  已配置节点: 无"
  fi
  echo ""

  if systemctl is-active caddy &>/dev/null; then
    green "  订阅服务: Caddy 运行中"
  else
    yellow "  订阅服务: Caddy 未运行（需配置 HTTPS 域名）"
  fi
  echo ""
}

# ==================== 7. 重启服务 ====================
restart_service(){
  migrate_legacy_config >/dev/null 2>&1 || true
  if ! has_any_node; then red "未找到 sing-box 配置"; sleep 2; return; fi
  systemctl restart sing-box && sleep 2
  if systemctl is-active sing-box &>/dev/null; then
    green "sing-box 服务已重启 ✅"
  else
    red "服务重启失败"
    systemctl status sing-box
  fi
}

# ==================== 8. 卸载 ====================
uninstall(){
  yellow "确认卸载 sing-box 和所有配置？此操作不可逆！"
  readp "确认？[y/n]: " confirm
  [[ "$confirm" != [yY] ]] && return

  # 停止 CF Tunnel 服务
  systemctl stop argo 2>/dev/null; systemctl disable argo 2>/dev/null
  rm -f /etc/systemd/system/argo.service
  rm -f /etc/systemd/system/multi-user.target.wants/argo.service
  rm -f /etc/s-box/cloudflared /usr/local/bin/cloudflared /usr/bin/cloudflared 2>/dev/null
  rm -f /etc/s-box/sbargoym.log /etc/s-box/sbargotoken.log 2>/dev/null
  green "CF Tunnel 已卸载"

  # 卸载 Caddy
  systemctl stop caddy 2>/dev/null; systemctl disable caddy 2>/dev/null
  rm -f /etc/systemd/system/caddy.service 2>/dev/null
  rm -f /usr/local/bin/caddy /usr/bin/caddy 2>/dev/null
  rm -rf /etc/caddy 2>/dev/null
  green "Caddy 已卸载"

  # 卸载 sing-box
  systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null
  rm -f "$SERVICE_FILE"
  rm -rf "$INSTALL_DIR"
  rm -rf "$NODE_DIR"

  # 删除快捷方式别名
  if grep -q "alias s=" ~/.bashrc 2>/dev/null; then
    sed -i '/alias s=/d' ~/.bashrc
    green "快捷方式 's' 已删除"
  fi
  green "所有配置已清理"

  systemctl daemon-reload &>/dev/null

  green "sing-box 和所有配置已卸载 ✅"
}

# ==================== 主菜单 ====================
main_menu(){
  clear
  local has_core=false
  local has_node=false
  [[ -f "${INSTALL_DIR}/sing-box" ]] && has_core=true
  migrate_legacy_config >/dev/null 2>&1 || true
  has_any_node && has_node=true

  echo ""
  green "╭──────────────────────────────────────────────╮"
  green "│  Cloudflared Tunnel 优选"
  green "│  协议: Vmess / Vless + WebSocket"
  green "╰──────────────────────────────────────────────╯"
  echo ""
  green "1: 安装 sing-box"
  green "2: 设置 vmess 节点"
  green "3: 设置 vless 节点"
  green "4: 节点修改"
  green "5: 查看节点"
  green "6: 查看订阅链接"
  green "7: 查看状态"
  green "8: 重启服务"
  green "9: 卸载"
  green "10: 配置 HTTPS 订阅（Caddy）"
  green "0: 退出"
  echo ""
  if $has_node; then
    green "  状态: 已配置"
  elif $has_core; then
    yellow "  状态: 核心已安装，请设置节点"
  else
    red "  状态: 未安装"
  fi
  echo ""
  readp "请选择功能【0-10】: " menu

  case "$menu" in
    1) install_singbox ;;
    2) setup_node ;;
    3) setup_vless_node ;;
    4) modify_node ;;
    5) show_node ;;
    6) show_sub ;;
    7) show_status ;;
    8) restart_service ;;
    9) uninstall ;;
    10) setup_caddy_sub ;;
    0) exit 0 ;;
    *) yellow "输入错误" ;;
  esac

  [[ "$menu" != "0" ]] && {
    echo ""
    yellow "按回车键返回主菜单..."
    read
    main_menu
  }
}

main_menu
