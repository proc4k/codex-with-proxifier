#!/usr/bin/env bash
# codex-net-doctor.sh — Codex / ChatGPT 连不上时的自检脚本（macOS + Proxifier）
#
# 用途：Codex 升级或网络变化后，快速判断"Proxifier 的配置是否还适用"。
# 只读：不修改任何配置、不重启任何进程。
#
# 用法：
#   ./codex-net-doctor.sh                      # 完整检查（默认脱敏输出）
#   ./codex-net-doctor.sh --quiet              # 只输出失败/警告项
#   ./codex-net-doctor.sh --no-redact          # 显示完整 IP / profile 名（仅本地排查时用）
#   ./codex-net-doctor.sh --profile x.ppx      # 检查指定的 profile（可用 Proxifier Export 导出的文件）
#
# 退出码：0 = 全部通过；1 = 有失败项；2 = 只有警告
set -u

QUIET=0
REDACT=1
PROFILE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --redact) REDACT=1 ;;
    --no-redact) REDACT=0 ;;
    --profile) shift; PROFILE_OVERRIDE="${1:-}" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 64 ;;
  esac
  shift
done

PROFILE_DIR="$HOME/Library/Containers/com.initex.proxifier.v3.macos/Data/Profiles"
PREFS_PLIST="$HOME/Library/Containers/com.initex.proxifier.v3.macos/Data/Library/Preferences/com.initex.proxifier.v3.macos.plist"
APP="/Applications/ChatGPT.app"
STATE_DIR="$HOME/.cache/codex-net-doctor"
STATE_FILE="$STATE_DIR/last-good-version"
DOH_IPS="1.1.1.1|1.0.0.1|8.8.8.8|8.8.4.4|9.9.9.9|149.112.112.112"
PROBE_HOSTS="openai.com chatgpt.com auth.openai.com api.openai.com cdn.oaistatic.com ab.chatgpt.com www.chatgpt.com"

pass=0; fail=0; warn=0
declare -a HINTS
hint() { HINTS+=("$1"); }

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; N=''
fi
ok()   { pass=$((pass+1)); [ $QUIET -eq 1 ] || printf "  ${G}✓${N} %s\n" "$*"; }
bad()  { fail=$((fail+1)); printf "  ${R}✗${N} %s\n" "$*"; }
note() { warn=$((warn+1)); printf "  ${Y}!${N} %s\n" "$*"; }
sec()  { [ $QUIET -eq 1 ] && return 0; printf "\n${B}== %s ==${N}\n" "$*"; }

# 不带任何代理环境变量、并禁用 curl 自带代理的调用
curl_direct() { env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
                  curl -s --noproxy '*' "$@"; }
ipv4_of() { host "$1" 2>/dev/null | awk '/has address/{print $4; exit}'; }
is_fake_ip() { printf '%s' "$1" | grep -Eq '^0\.0\.[0-9]+\.[0-9]+$'; }
http_code() { curl_direct -m 10 -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null; }

# 输出脱敏：fake-IP（0.0.x.x）本身不含个人信息，保留以便判断；
# 其余真实 IP 与 profile 名默认打码，--no-redact 可关闭。
redact_ip() {
  [ "$REDACT" -eq 0 ] && { printf '%s' "$1"; return; }
  case "$1" in
    0.0.*) printf '%s' "$1" ;;
    "")    printf '<无>' ;;
    *)     printf '<redacted>' ;;
  esac
}
redact_name() { if [ "$REDACT" -eq 0 ]; then printf '%s' "$1"; else printf '<redacted>'; fi; }
[ "$REDACT" -eq 1 ] && [ "$QUIET" -eq 0 ] && printf "${B}提示：输出已脱敏（--no-redact 显示完整 IP）${N}\n"

sec "1. 进程"
if pgrep -f "Proxifier.app/Contents/MacOS/Proxifier" >/dev/null 2>&1; then
  ok "Proxifier 在运行"
else
  bad "Proxifier 没有运行"; hint "启动 Proxifier 后重试；或检查它是否被系统扩展拦住了"
fi

APP_PID=$(pgrep -f "$APP/Contents/MacOS/ChatGPT" | head -1)
if [ -n "$APP_PID" ]; then
  APP_ARGS=$(ps -o command= -p "$APP_PID" 2>/dev/null)
  ok "ChatGPT/Codex 在运行（pid ${APP_PID}）"
  case "$APP_ARGS" in
    *--proxy-server*)
      note "App 启动参数里带了 --proxy-server（双通道模式，Proxifier 域名规则对它不参与）"
      hint "想完全交给 Proxifier，可去掉启动脚本里的 --proxy-server 与 *_PROXY 环境变量"
      ;;
  esac
else
  note "ChatGPT/Codex 未运行（不影响其余检查）"
fi

sec "2. Proxifier 配置"
ACTIVE=""
if [ -n "$PROFILE_OVERRIDE" ]; then
  if [ -r "$PROFILE_OVERRIDE" ]; then
    PPX="$PROFILE_OVERRIDE"; ok "使用指定 profile：$(redact_name "$(basename "$PPX")")"
  else
    bad "指定的 profile 不可读：$PROFILE_OVERRIDE"
  fi
fi
if [ -r "$PREFS_PLIST" ] && [ -z "$PROFILE_OVERRIDE" ]; then
  ACTIVE=$(defaults read "$PREFS_PLIST" SettingsActiveProfile 2>/dev/null | tr -d '"')
fi
PPX="${PPX:-}"
if [ -z "$PPX" ]; then
  if [ -n "$ACTIVE" ] && [ -r "$PROFILE_DIR/$ACTIVE.ppx" ]; then
    PPX="$PROFILE_DIR/$ACTIVE.ppx"
    ok "当前 profile：$(redact_name "$ACTIVE")"
  else
    # 读不到偏好时退化为取最新的 .ppx
    PPX=$(ls -t "$PROFILE_DIR"/*.ppx 2>/dev/null | head -1)
    if [ -n "$PPX" ]; then
      note "读不到 SettingsActiveProfile（可能需要完全磁盘访问权限），按最新文件判断：$(redact_name "$(basename "$PPX")")"
    else
      bad "找不到 Proxifier profile（${PROFILE_DIR}）"
      hint "给终端/编辑器授予「完全磁盘访问权限」，或用 Proxifier 的 File → Export 导出后检查"
    fi
  fi
fi

PROXY_HOST=""; PROXY_PORT=""
RULE_OK=0; DEFAULT_IDX=99; OPENAI_IDX=99
if [ -n "${PPX:-}" ] && [ -r "$PPX" ]; then
  PARSED=$(python3 - "$PPX" <<'PY' 2>/dev/null
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
o = r.find('Options'); res = o.find('Resolve')
def en(el):
    return el.get('enabled') if el is not None else '?'
print('VIAPROXY=' + en(res.find('ViaProxy')))
print('AUTO=' + en(res.find('AutoModeDetection')))
print('LOCALFIRST=' + en(res.find('ViaProxy/TryLocalDnsFirst')))
print('UDP443=' + en(o.find('BlockUDP443')))
rules = r.find('RuleList').findall('Rule') if r.find('RuleList') is not None else []
for i, ru in enumerate(rules):
    print('RULE%d|%s|%s|%s|%s' % (i, ru.findtext('Name') or '', (ru.find('Action').get('type') if ru.find('Action') is not None else '?'), ru.findtext('Targets') or '', ru.findtext('Applications') or ''))
pl = r.find('ProxyList')
if pl is not None:
    for px in pl.findall('Proxy'):
        print('PROXY|%s|%s|%s|%s' % (px.get('id'), px.get('type'), px.findtext('Address') or '', px.findtext('Port') or ''))
PY
)
  VIAPROXY=$(printf '%s\n' "$PARSED" | sed -n 's/^VIAPROXY=//p')
  AUTO=$(printf '%s\n' "$PARSED" | sed -n 's/^AUTO=//p')
  UDP443=$(printf '%s\n' "$PARSED" | sed -n 's/^UDP443=//p')

  [ "$VIAPROXY" = "true" ] && ok "域名解析走代理（ViaProxy=on）" || { bad "ViaProxy 没开（当前=${VIAPROXY:-未知}）"; hint "Proxifier → Profile → Name Resolution 选 Resolve host names through proxy"; }
  [ "$AUTO" = "false" ] && ok "自动 DNS 探测已关闭" || note "AutoModeDetection=${AUTO:-未知}，建议关闭以避免判断漂移"

  # 解析规则与代理
  while IFS= read -r line; do
    case "$line" in
      PROXY\|*)
        IFS='|' read -r _ _ ptype paddr pport <<< "$line"
        if [ "$ptype" = "SOCKS5" ] && [ -z "$PROXY_PORT" ]; then PROXY_HOST="$paddr"; PROXY_PORT="$pport"; fi
        ;;
      RULE*)
        IFS='|' read -r idx name action targets apps <<< "$line"
        num=${idx#RULE}
        if [ "$action" = "Direct" ] && { [ "$name" = "Default" ] || { [ -z "$targets" ] && [ -z "$apps" ]; }; }; then
          [ "$num" -lt "$DEFAULT_IDX" ] && DEFAULT_IDX=$num
        fi
        case "$targets" in
          *chatgpt.com*|*openai.com*)
            if [ "$action" = "Proxy" ] && [ "$num" -lt "$OPENAI_IDX" ]; then
              OPENAI_IDX=$num; RULE_OK=1
            fi
            ;;
        esac
        ;;
    esac
  done <<< "$PARSED"

  if [ "$RULE_OK" -eq 1 ]; then
    if [ "$OPENAI_IDX" -lt "$DEFAULT_IDX" ]; then
      ok "OpenAI 域名规则存在，且在 Default 之前（第 $((OPENAI_IDX+1)) 条）"
    else
      bad "OpenAI 规则在 Default 之后，永远不会命中"
      hint "把 OpenAI 规则拖到 Default 规则上面"
    fi
  else
    bad "没有覆盖 openai.com / chatgpt.com 的代理规则"
    hint "新增规则：Targets = openai.com; *.openai.com; chatgpt.com; *.chatgpt.com; *.oaistatic.com; *.oaiusercontent.com"
  fi

  if [ "$UDP443" = "true" ]; then ok "BlockUDP443 已开启（避免 QUIC 卡住）"; else note "BlockUDP443 未开启，Chromium 可能尝试 HTTP/3"; fi

  if [ -n "$PROXY_PORT" ]; then
    ok "代理配置：SOCKS5 $PROXY_HOST:$PROXY_PORT"
  else
    bad "profile 里没有 SOCKS5 代理条目"
    hint "Proxy Servers 里添加 SOCKS5 127.0.0.1:1234"
  fi
fi

sec "3. 本地代理可用性"
PROXY_PORT=${PROXY_PORT:-1234}
if nc -z -G 2 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1; then
  ok "127.0.0.1:$PROXY_PORT 在监听"
else
  bad "127.0.0.1:$PROXY_PORT 没在监听"
  hint "检查本地代理客户端（mihomo / sing-box / v2ray 等）是否在跑"
fi
TRACE_PROXY=$(curl -s -m 15 -x "socks5h://127.0.0.1:$PROXY_PORT" https://chatgpt.com/cdn-cgi/trace 2>/dev/null)
P_IP=$(printf '%s\n' "$TRACE_PROXY" | sed -n 's/^ip=//p')
P_LOC=$(printf '%s\n' "$TRACE_PROXY" | sed -n 's/^loc=//p')
if [ -n "$P_LOC" ] && [ "$P_LOC" != "CN" ]; then
  ok "经代理解析可达：ip=$(redact_ip "$P_IP") loc=$P_LOC"
else
  bad "经代理访问 chatgpt.com 失败（loc=${P_LOC:-无响应}）"
  hint "先确认代理本身能出网，再看 Proxifier"
fi

sec "4. 系统层（不带任何环境变量）"
DNS_IP=$(ipv4_of chatgpt.com)
if [ -z "$DNS_IP" ]; then
  bad "chatgpt.com 解析失败"
  hint "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
elif is_fake_ip "$DNS_IP"; then
  ok "chatgpt.com -> $(redact_ip "$DNS_IP")（Proxifier fake-IP，DNS 已被接管）"
else
  bad "chatgpt.com -> $(redact_ip "$DNS_IP")（真实/污染 IP，未被 fake-IP 接管）"
  hint "先刷新 DNS 缓存：sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
fi

FRESH_IP=$(ipv4_of "probe-$RANDOM.chatgpt.com")
if is_fake_ip "$FRESH_IP"; then
  ok "未缓存的新域名也被接管（probe -> $(redact_ip "$FRESH_IP")）"
else
  note "新域名没拿到 fake-IP（probe -> $(redact_ip "${FRESH_IP:-}")），DNS 接管可能失效"
fi

TRACE=$(curl_direct -m 15 https://chatgpt.com/cdn-cgi/trace 2>/dev/null)
S_IP=$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')
S_LOC=$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')
if [ -n "$S_LOC" ] && [ "$S_LOC" != "CN" ]; then
  ok "系统层访问 chatgpt.com 走代理：ip=$(redact_ip "$S_IP") loc=$S_LOC"
else
  bad "系统层访问 chatgpt.com 没走代理（loc=${S_LOC:-无响应}）"
  hint "检查 OpenAI 规则顺序、fake-IP 是否生效；必要时刷新 DNS 缓存"
fi

CODE=$(http_code api.openai.com)
if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
  ok "api.openai.com 可达（HTTP ${CODE}）"
else
  bad "api.openai.com 不可达"
fi

# 规则外的域名应保持直连（防止误伤国内站点）
CN_IP=$(ipv4_of www.baidu.com)
if [ -n "$CN_IP" ] && ! is_fake_ip "$CN_IP"; then
  ok "规则外域名仍走本地解析（www.baidu.com -> $(redact_ip "$CN_IP")）"
else
  note "www.baidu.com -> $(redact_ip "${CN_IP:-}")，国内域名可能被代理接管了"
fi

sec "5. DoH 检测（应用是否绕过系统解析）"
DOH_HIT=0
for pid in $(pgrep -f "$APP|Codex Framework|CodexCLI" 2>/dev/null); do
  HIT=$(lsof -nP -i TCP -a -p "$pid" 2>/dev/null | grep -E -- "->($DOH_IPS):443" | head -2)
  if [ -n "$HIT" ]; then
    DOH_HIT=1
    note "pid $pid 连到了 DoH 服务商：$(printf '%s\n' "$HIT" | sed -n 's/.*->//p' | tr '\n' ' ')"
  fi
done
if [ "$DOH_HIT" -eq 0 ]; then
  ok "未发现 Codex/ChatGPT 连接已知 DoH 服务商"
else
  bad "检测到 DoH 连接，域名规则可能失效"
  hint "关掉应用的 Secure DNS，或改用 TUN 模式（sing-box / Mihomo fake-IP）"
fi

sec "6. 域名覆盖抽查"
for h in $PROBE_HOSTS; do
  c=$(http_code "$h")
  if [ -n "$c" ] && [ "$c" != "000" ]; then
    ok "${h}（HTTP ${c}）"
  else
    bad "$h 不可达（000）"
  fi
done

sec "7. 版本与路径（升级后重点看这里）"
VER=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null)
if [ -n "$VER" ]; then
  ok "ChatGPT 版本：$VER"
else
  note "读不到 $APP 的版本"
fi
if [ -x "$APP/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" ]; then
  ok "codex CLI 路径存在"
else
  bad "codex CLI 路径不存在：$APP/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  hint "应用结构可能变了；检查 Rules 里引用的应用路径，或改用按域名规则"
fi
mkdir -p "$STATE_DIR" 2>/dev/null
if [ -f "$STATE_FILE" ] && [ -n "$VER" ]; then
  OLD_VER=$(cat "$STATE_FILE" 2>/dev/null)
  [ "$OLD_VER" != "$VER" ] && note "版本变化：$OLD_VER -> ${VER}（配置可能需要在下面重测）"
fi

# 记录"最后一次全部通过"的版本
if [ "$fail" -eq 0 ] && [ -n "$VER" ]; then
  printf '%s' "$VER" > "$STATE_FILE" 2>/dev/null
fi

printf "\n${B}== 结果 ==${N}\n"
printf "  通过 %d / 失败 %d / 警告 %d\n" "$pass" "$fail" "$warn"

if [ "${#HINTS[@]}" -gt 0 ]; then
  printf "\n${Y}建议：${N}\n"
  printf '  - %s\n' "${HINTS[@]}"
fi

if [ "$fail" -gt 0 ]; then
  printf "\n${R}结论：当前配置不适用于 Codex 的连接路径，按上面建议处理。${N}\n"
  exit 1
elif [ "$warn" -gt 0 ]; then
  printf "\n${Y}结论：基本可用，但有警告项。${N}\n"
  exit 2
else
  printf "\n${G}结论：Proxifier 配置仍然适用，Codex 应能正常连接。${N}\n"
  exit 0
fi
