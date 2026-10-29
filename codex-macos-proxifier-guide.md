# 让 Codex / ChatGPT 桌面版在 macOS 上稳定走本地 SOCKS5

> 场景：Mac 上已经有一个可用的本地 SOCKS5 代理（例如监听 `127.0.0.1:1234`，出口在境外），
> 但 `Codex.app` / `ChatGPT.app` 直接启动连不上；不想给每个 App 单独加 `--proxy-server` 或环境变量。
>
> 目标：用 Proxifier 做**按域名分流**，Codex 直接双击启动即可用。
>
> 验证环境：Proxifier 3.15 (macOS)，本地代理 SOCKS5 `127.0.0.1:1234`。2026-10 实测通过。

---

## 一、为什么"配了 Proxifier 反而连不上"

这是最常见的三个坑，按出现概率排序：

### 1. DNS 污染 + 本地解析（最主要）

`chatgpt.com` 在污染网络里会被解析到一堆假地址，例如：

```text
chatgpt.com has address 157.240.1.9        # Facebook 网段
chatgpt.com has address 173.236.182.137
chatgpt.com has address 199.16.156.75
```

如果 Proxifier 在**本地**解析域名，再把解析出的 IP 交给代理去连，代理连的就是 `157.240.1.9` 这种假 IP，
TLS 握手必然失败 —— 表现就是"配了代理反而连不上"。

而 Chromium 系应用（ChatGPT.app）如果自己带 `--proxy-server=socks5://...`，是把**域名**交给代理远程解析的
（socks5h 语义），所以它反而能用。这就是"显式代理能用、Proxifier 不能用"的根因。

### 2. 规则没覆盖 OpenAI 域名

很多人的 Proxifier 规则只写了 GitHub / Google，Codex 的请求命不中任何规则，落到 `Default = Direct`，
于是直连失败。

### 3. QUIC / UDP 443

ChatGPT.app 是 Chromium 内核，会先尝试 HTTP/3（UDP 443）。Proxifier 代理的是 TCP，UDP 包要么直连泄露、
要么卡住等超时。

### 4. 缓存残留（配好之后仍失败时看这条）

即使打开了"通过代理解析域名"，系统 DNS 缓存里**旧的污染记录**仍会让某些域名（尤其裸域）绕过 Proxifier。
必须刷新 DNS 缓存，见第四节。

---

## 二、原理：Proxifier 的 fake-IP 机制

Proxifier 对**它能拦截到的 DNS 查询**返回一个 fake-IP（实测形如 `0.0.168.x`、`0.0.171.x`），
应用去连这个 fake-IP 时，Proxifier 反查出原始域名，再按**域名规则**把连接交给 SOCKS5，由代理解析真实地址。

因此有两个硬性条件：

1. 规则必须按**域名**写（`chatgpt.com`、`*.openai.com` …），不要指望 IP 规则；
2. DNS 查询必须真的被 Proxifier 看到。已经被系统缓存成假 IP 的域名，它看不到查询，也就匹配不上 →
   表现为"新域名能过、裸域怎么都不行"。这就是要刷缓存的原因。

---

## 三、具体改动（Proxifier 3.15 macOS）

### 3.1 找到当前生效的 profile

Proxifier 是沙盒 App，配置在它自己的容器里：

```text
~/Library/Containers/com.initex.proxifier.v3.macos/Data/Profiles/
```

当前生效的 profile 名记录在偏好设置里：

```sh
defaults read ~/Library/Containers/com.initex.proxifier.v3.macos/Data/Library/Preferences/com.initex.proxifier.v3.macos.plist SettingsActiveProfile
```

读取这个目录需要给终端 / 编辑器"完全磁盘访问权限"（系统设置 → 隐私与安全性 → 完全磁盘访问权限）。
不想授权也没关系，直接用 Proxifier 菜单 **File → Export…** 导出、**File → Import** 导入即可。

### 3.2 备份

```sh
cp ~/Library/Containers/com.initex.proxifier.v3.macos/Data/Profiles/<当前 profile>.ppx ~/<当前 profile>.ppx.bak
```

### 3.3 退出 Proxifier 再改文件（重要）

**Proxifier 退出时会把内存里的配置写回文件**。如果它运行时你改文件，退出时会被覆盖。
顺序必须是：退出 App → 改文件 → 再启动。

### 3.4 修改内容

下面三项是关键，其余保持原样：

```xml
<!-- 1) 打开"通过代理解析域名"，关闭自动探测 -->
<Resolve>
    <AutoModeDetection enabled="false"/>
    <ViaProxy enabled="true">
        <TryLocalDnsFirst enabled="false"/>
    </ViaProxy>
    ...
</Resolve>

<!-- 2) 屏蔽 UDP 443，逼 Chromium 回落到 TCP -->
<BlockUDP443 enabled="true"/>

<!-- 3) 新增 OpenAI 规则，放在 Default 之前 -->
<Rule enabled="true">
    <Name>OpenAI</Name>
    <Targets>openai.com; *.openai.com; chatgpt.com; *.chatgpt.com; *.oaistatic.com; *.oaiusercontent.com; *.openai.org</Targets>
    <Action type="Proxy">100</Action>
</Rule>
```

代理本身（`<Proxy id="100" type="SOCKS5">` + `127.0.0.1:1234`）通常已经有了，没有就补上。

### 3.5 规则顺序（第一条匹配即生效）

| # | 规则 | 条件 | 动作 | 作用 |
|---|------|------|------|------|
| 1 | proxy-client | 应用 = 你的代理客户端进程（mihomo / sing-box / v2ray 等） | Direct | **防环**，代理自己连服务器的流量不能再被代理 |
| 2 | Localhost | `localhost; 127.0.0.1; ::1; %ComputerName%;*.local` | Direct | 本机回环 / 内网服务 |
| 3 | lan | `192.168.*.*; 10.*.*.*; 172.16.*.*` | Direct | 局域网 |
| 4 | OpenAI | 见上面的 Targets | Proxy | 关键规则 |
| 5 | Default | Any | Direct | 其余直连 |

注意：如果规则 4 只写了 `chatgpt.com`，`ab.chatgpt.com`、`auth.openai.com` 这些子域要另外覆盖，
建议像上面一样用通配。

### 3.6 启动并刷新 DNS 缓存

```sh
# 启动 Proxifier 后执行（需要管理员密码）
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

---

## 四、验证（不用启动 Codex）

```sh
# 1) 域名应变成 Proxifier 的 fake-IP（0.0.x.x），而不是 157.240.x / 173.236.x 这类假地址
host chatgpt.com

# 2) 期望 loc=US，ip 是你的代理出口 IP
curl -s https://chatgpt.com/cdn-cgi/trace | grep -E "^(ip|loc)="

# 3) 期望 401（说明链路通，只是没鉴权），而不是 000 超时
curl -s -o /dev/null -w "%{http_code}\n" https://api.openai.com/v1/models

# 4) 规则外的域名应仍然是本地直连（不误伤）
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E "^(ip|loc)="
```

补充：

- `host` 返回 `0.0.x.x` 说明 DNS 已被 Proxifier 接管；
- `dig` 在 Proxifier 接管 DNS 后可能报 `malformed message packet`，这是正常现象，用 `host` / `curl` 验证即可；
- `chatgpt.com/` 根路径对 curl 返回 403 是 Cloudflare 的 bot 拦截，不代表代理失败，
  以 `/cdn-cgi/trace` 的结果为准。

---

## 五、然后就可以不要启动脚本了

之前为了能用，很多人会在启动脚本里写：

```sh
export HTTP_PROXY=http://127.0.0.1:1234
export HTTPS_PROXY=http://127.0.0.1:1234
open -a 'Codex' --args --proxy-server="socks5://127.0.0.1:1234"
```

Proxifier 的域名规则生效后，**这一步可以省掉**：应用直接连 `chatgpt.com` 域名，Proxifier 用 fake-IP
接管并按规则交给 SOCKS5。实测去掉 `--proxy-server` 和三个环境变量后，ChatGPT.app 直接启动可用。

如果想"双保险"，保留脚本也可以：此时 App 只连 `127.0.0.1:1234`（命中 Localhost 规则直连），
Proxifier 的域名规则对它不参与 —— 相当于两条独立通道。

建议额外加 `--disable-quic`，避免 App 尝试 UDP 443（Proxifier 已开 `BlockUDP443`，双保险）：

```sh
open -a 'Codex' --args --disable-quic
```

---

## 六、常见问题

**Q1：规则都加了，`chatgpt.com` 还是超时，但 `www.chatgpt.com` 正常？**
系统 DNS 缓存里有旧污染记录。执行第四节的 `dscacheutil -flushcache` + `killall -HUP mDNSResponder`。
新域名能过、裸域不能过，基本就是这个原因。

**Q2：Proxifier 一退出，规则就丢了/被改回去了？**
它退出时回写配置。编辑 profile 前先退出 App；或者用 Export / Import 方式。

**Q3：某些 App 还是不走代理？**
如果它自己实现 DoH、或硬编码 IP、或用 UDP 协议，按域名的规则可能失效。这类情况建议直接上
TUN 模式（sing-box / Mihomo 的 fake-IP + 透明代理），在 IP 层接管，兼容性最好。

**Q4：能不能把这个配置发给别人？**
可以。用 **File → Export…** 导出 `.ppx`（注意里面可能含代理服务器地址和密码），对方 **File → Import** 导入后
再改成本机代理地址即可。Proxifier 的 profile 是 XML，也可以直接改文本。

**Q5：为什么会话内 `dig` 报 malformed？**
Proxifier 接管 53 端口后返回的是自己的合成应答，`dig` 解析不了，不影响实际使用。

---

## 七、回退

```sh
# 先退出 Proxifier
cp ~/<当前 profile>.ppx.bak ~/Library/Containers/com.initex.proxifier.v3.macos/Data/Profiles/<当前 profile>.ppx
# 再启动 Proxifier
```

或者把 OpenAI 规则删掉、`BlockUDP443` 和 `ViaProxy` 关回去。

---

## 八、自检脚本（升级后先跑这个）

配套脚本 `codex-net-doctor.sh` 只读、不改配置，用来判断"现在的 Proxifier 配置还适不适用"。

```sh
chmod +x codex-net-doctor.sh
./codex-net-doctor.sh                # 完整检查（默认脱敏）
./codex-net-doctor.sh --quiet        # 只输出失败/警告
./codex-net-doctor.sh --no-redact    # 显示完整 IP / profile 名（仅本地排查用）
./codex-net-doctor.sh --profile ~/Desktop/some.ppx   # 检查导出的 profile（导入前预检）
```

**输出默认脱敏**：代理出口 IP、本机解析到的真实 IP、当前 profile 名都会打码成
`<redacted>`，但保留判断所需的信息（`loc=US`、`fake-IP`、HTTP 状态码等）。
fake-IP（`0.0.x.x`）本身不含个人信息，保持原样显示。想把输出贴到 issue 里时用默认模式即可；
`--no-redact` 才会输出完整值。

它会检查七件事：

1. Proxifier / ChatGPT 进程是否在跑，App 是否还带着 `--proxy-server`（双通道）；
2. 当前 profile 的 `ViaProxy`、`AutoModeDetection`、`BlockUDP443`、是否有 OpenAI 规则且在 `Default` 之前；
3. 本地 SOCKS5 端口是否监听、经代理能否访问 `chatgpt.com` 并拿到境外出口；
4. **系统层**（不带任何代理环境变量）`chatgpt.com` 是否解析成 fake-IP、能否走代理、规则外域名是否仍直连；
5. 应用是否连了已知 DoH 服务商（`1.1.1.1:443`、`8.8.8.8:443` 等）；
6. 一批 OpenAI 域名的实际可达性；
7. App 版本与 `codex` 可执行文件路径是否还在（升级后最容易变的部分），并记录"最后一次全部通过"的版本。

退出码：`0` 全部通过、`1` 有失败项、`2` 只有警告。失败时会给出对应修复建议。

> 说明：脚本需要读取 Proxifier 的 profile 文件，若终端没有「完全磁盘访问权限」，
> 会退化为按最新的 `.ppx` 判断，并提示用 Export 导出后配合 `--profile` 检查。

---

## 附：最小可用 profile 片段（脱敏）

```xml
<ProxifierProfile version="101" platform="MacOSX" product_id="2" product_minver="200">
    <Options>
        <Resolve>
            <AutoModeDetection enabled="false"/>
            <ViaProxy enabled="true">
                <TryLocalDnsFirst enabled="false"/>
            </ViaProxy>
        </Resolve>
        <BlockUDP443 enabled="true"/>
        <ConnectionLoopDetection enabled="true"/>
        <ProcessServices enabled="true"/>
        <ProcessOtherUsers enabled="true"/>
    </Options>
    <ProxyList>
        <Proxy id="100" type="SOCKS5">
            <Address>127.0.0.1</Address>
            <Port>1234</Port>
            <Options>0</Options>
        </Proxy>
    </ProxyList>
    <ChainList/>
    <RuleList>
        <Rule enabled="true">
            <Name>proxy-client direct</Name>
            <Applications>mihomo</Applications>
            <Action type="Direct"/>
        </Rule>
        <Rule enabled="true">
            <Name>Localhost</Name>
            <Targets>localhost; 127.0.0.1; ::1; %ComputerName%;*.local</Targets>
            <Action type="Direct"/>
        </Rule>
        <Rule enabled="true">
            <Name>OpenAI</Name>
            <Targets>openai.com; *.openai.com; chatgpt.com; *.chatgpt.com; *.oaistatic.com; *.oaiusercontent.com; *.openai.org</Targets>
            <Action type="Proxy">100</Action>
        </Rule>
        <Rule enabled="true">
            <Name>Default</Name>
            <Action type="Direct"/>
        </Rule>
    </RuleList>
</ProxifierProfile>
```
