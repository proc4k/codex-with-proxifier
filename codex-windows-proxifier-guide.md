# 让 Codex / ChatGPT 桌面版在 Windows 上稳定走本地 SOCKS5

> 场景：Windows 上已经有一个可用的代理（本地 SOCKS5 端口，或局域网里的混合端口），
> 但 `Codex.exe` 直接启动连不上（DNS 污染、域名未覆盖、QUIC 卡住等）；
> 不想给每个 App 单独加 `--proxy-server` 或环境变量。
>
> 目标：用 Proxifier 4 (Windows) 做**按域名分流**，Codex 直接双击启动即可用。
>
> 姊妹篇（macOS）：[`codex-macos-proxifier-guide.md`](codex-macos-proxifier-guide.md)

---

## 一、和 macOS 版相比，要改什么

macOS 版指南不能直接照抄：Proxifier 3.15 (macOS) 和 4.x (Windows) 的 profile 格式、
路径、验证命令都不一样。逐项对比如下：

| 项目 | macOS（原指南） | Windows（本指南） |
|---|---|---|
| profile 位置 | `~/Library/Containers/com.initex.proxifier.v3.macos/Data/Profiles/` | `%APPDATA%\Proxifier4\Profiles\`（`C:\Users\<你>\AppData\Roaming\Proxifier4\Profiles`） |
| 活动 profile | `defaults read ... SettingsActiveProfile` | 注册表 `HKCU\Software\Initex\Proxifier\Settings` 的 `ActiveProfile4` |
| profile 根节点 | `version="101" platform="MacOSX"` | `version="102" platform="Windows" product_minver="400"` |
| 通过代理解析域名 | `<ViaProxy enabled="true"><TryLocalDnsFirst enabled="false"/></ViaProxy>` | `<ViaProxy enabled="true" />`＋`<AutoModeDetection enabled="false" />` |
| 排除列表 | 无 | `<ExclusionList OnlyFromListMode="false">%ComputerName%; localhost; *.local</ExclusionList>` |
| 屏蔽 QUIC | `<BlockUDP443 enabled="true"/>` | `<Udp mode="mode_block_443" />`（另有 `mode_block_all` / `mode_bypass`） |
| fake-IP 段 | `0.0.168.x` / `0.0.171.x` 左右 | `127.x.x.x`（每次启动换一段，如 `127.210.0.1`）；IPv6 为 `fd00:696e:6974:6578::/64` |
| 刷 DNS | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` | `ipconfig /flushdns`（必要时管理员） |
| 查 DNS | `host` / `dig`（`dig` 可能报 malformed） | `Resolve-DnsName`（`nslookup` 会绕过缓存，见 Q2） |
| 应用进程名 | `ChatGPT` / `Codex`（macOS App） | `codex.exe`（桌面版），路径带哈希目录，升级会变 |
| 完全磁盘访问 | 需要授权才能读 profile | 不需要，`%APPDATA%` 直接可读 |

其余原理完全一致：**DNS 污染 + 规则没覆盖 + QUIC** 三大坑，以及"按域名规则 + fake-IP 接管"的解法。

---

## 二、原理：Proxifier 4 的 fake-IP

Proxifier 对**它接管的 DNS 查询**返回一个占位 IP（Windows 下实测为 `127.210.0.x`、
`127.206.0.x` 这类，每次启动换一段；IPv6 是 `fd00:696e:6974:6578::/64`）。
应用去连这个假 IP 时，Proxifier 反查出原始域名，再按**域名规则**决定：

- 命中 `Proxy` 规则 → 把**域名**交给 SOCKS5，由代理解析真实地址（socks5h 语义）；
- 命中 `Direct` 规则 → 由 Proxifier 自己向系统 DNS 要真实地址，然后直连。

所以有两个硬性条件：

1. 规则必须按**域名**写（`chatgpt.com`、`*.openai.com` …），IP 规则在 fake-IP 模式下不可靠；
2. DNS 必须真的被 Proxifier 接管（`ViaProxy=on`），否则连接目标只有 IP，域名规则命不中。

Windows 的额外注意点：

- fake-IP 会进 **Windows DNS Client 缓存**（`Get-DnsClientCache` 能看到）。Proxifier 退出后
  缓存里仍是假 IP，应用会连不上——见 Q3；
- `nslookup` 自己发包、绕过缓存，可能显示**真实 IP**；判断是否被接管请用 `Resolve-DnsName`
  或直接看实际连接（见 Q2）。

---

## 三、具体改动（Proxifier 4.x for Windows）

### 3.1 找到当前生效的 profile

```powershell
# 配置文件目录
Get-ChildItem "$env:APPDATA\Proxifier4\Profiles"

# 当前活动 profile（通常就是文件名）
(Get-ItemProperty 'HKCU:\Software\Initex\Proxifier\Settings').ActiveProfile4
```

Proxifier 4 在 Windows 上不做沙盒隔离，`%APPDATA%\Proxifier4\Profiles\<名字>.ppx` 可直接读写；
也可以走 GUI 的 **File → Export / Import**。

### 3.2 备份 + 退出 Proxifier（重要）

**Proxifier 退出时会把内存里的配置写回文件**。运行中改文件，退出时会被覆盖。顺序必须是：
退出 App → 改文件 → 再启动。

```powershell
$dir = "$env:APPDATA\Proxifier4\Profiles"
Copy-Item "$dir\Default.ppx" "$dir\Default.ppx.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Stop-Process -Name Proxifier -Force   # 或者右键托盘图标 → Exit
```

### 3.3 改哪些东西

三项关键（其余保持原样）：

```xml
<!-- 1) DNS 走代理，关闭自动探测；排除本机名 -->
<Resolve>
    <AutoModeDetection enabled="false" />
    <ViaProxy enabled="true" />
    <BlockNonATypes enabled="false" />
    <ExclusionList OnlyFromListMode="false">%ComputerName%; localhost; *.local</ExclusionList>
</Resolve>

<!-- 2) 屏蔽 QUIC（UDP 443），逼 Chromium 回落 TCP -->
<Udp mode="mode_block_443" />

<!-- 3) OpenAI 规则，放在 Default 之前 -->
<Rule enabled="true">
    <Action type="Proxy">100</Action>
    <Targets>openai.com; *.openai.com; chatgpt.com; *.chatgpt.com; *.oaistatic.com; *.oaiusercontent.com; openai.org; *.openai.org</Targets>
    <Name>OpenAI</Name>
</Rule>
```

代理本身（`<Proxy id="100" type="SOCKS5">` + 地址端口）通常已经有了，**先确认端口是活的**：

```powershell
# 把 7890 换成你客户端实际监听的端口
Test-NetConnection 127.0.0.1 -Port 7890
# 能看到 LISTENING 的端口：
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 1080,1081,1086,7890,7891,10808,2080 } |
    Select-Object LocalAddress, LocalPort, OwningProcess
```

### 3.4 直接用脚本生成（推荐）

```powershell
# 先退出 Proxifier；脚本会备份旧 profile、继承你已有的自定义规则、写配置并启动
./codex-apply-proxifier.ps1 -ProxyAddress 127.0.0.1 -ProxyPort 7890

# 想在代理的同时让 Google/GitHub 也走代理：
./codex-apply-proxifier.ps1 -ProxyPort 7890 -IncludeBrowserRule
```

首次运行如提示"禁止运行脚本"，用
`powershell -ExecutionPolicy Bypass -File .\codex-apply-proxifier.ps1 -ProxyPort 7890`。

脚本做四件事：

1. 要求 Proxifier 已退出（`-Force` 会强杀）；
2. 备份同名的旧 profile；
3. 继承当前 profile 里非标准的规则（例如你给某个 App 单独加的代理规则）；
4. 写入 `%APPDATA%\Proxifier4\Profiles\Codex.ppx`，把 `ActiveProfile4` 指过去并启动。

### 3.5 规则顺序（第一条匹配即生效）

| # | 规则 | 条件 | 动作 | 作用 |
|---|------|------|------|------|
| 1 | Localhost and LAN | `localhost; 127.0.0.1; ::1; %ComputerName%; *.local; 192.168.0.0/16; 10.0.0.0/8; 172.16.0.0/12` | Direct | 本机回环 / 内网 / 代理服务器本身，**防环** |
| 2 | proxy client direct | 应用 = mihomo / clash / sing-box / v2ray / xray 等 | Direct | 代理客户端自己连服务器的流量不能再被代理 |
| 3 | OpenAI | 见上面的 Targets | Proxy | 关键规则 |
| 4 | browser（可选） | Google / GitHub / X / YouTube | Proxy | 顺带解决其他站点 |
| 5 | Default | Any | Direct | 其余直连，避免误伤国内站点 |

注意：`*.openai.com` 不一定匹配裸域 `openai.com`，两个都写上；`ab.chatgpt.com`、
`auth.openai.com` 这类子域靠通配覆盖。

### 3.6 启动并刷新 DNS 缓存

```powershell
Start-Process 'C:\Program Files (x86)\Proxifier\Proxifier.exe'
ipconfig /flushdns
```

如果 `ipconfig /flushdns` 提示权限不足，用管理员 PowerShell 再执行一次。

---

## 四、验证（不用启动 Codex）

> PowerShell 5.1 里的 `curl` 是 `Invoke-WebRequest` 的别名，**必须写 `curl.exe`**。

```powershell
# 1) 域名应变成 fake-IP（127.x.x.x），而不是 157.240.x / 173.236.x 这类污染地址
Resolve-DnsName chatgpt.com -Type A

# 2) 系统层（不设任何代理）访问 chatgpt.com，期望 loc=US
curl.exe -s -m 20 --noproxy '*' https://chatgpt.com/cdn-cgi/trace | Select-String '^(ip|loc)='

# 3) 期望 401（链路通，只是没鉴权），而不是 000 超时
curl.exe -s -o NUL -w "%{http_code}`n" -m 20 --noproxy '*' https://api.openai.com/v1/models

# 4) 规则外的域名应仍然直连：出口 IP 必须和代理出口不同
curl.exe -s -m 20 --noproxy '*' https://www.cloudflare.com/cdn-cgi/trace | Select-String '^(ip|loc)='
```

补充：

- 第 2 步返回 `loc=US` 且带出口 IP，说明系统层已经走 Proxifier 的域名规则；
- 第 4 步如果 `www.cloudflare.com` 的出口 IP 和代理出口一样，说明规则过宽（例如 Default 被设成代理）；
- `cdn.oaistatic.com` 返回 404、`openai.com` 返回 403 都是正常的，只判断"不是 000"。

---

## 五、然后就可以不要启动脚本了

Windows 上常见的旧做法是给 Codex 快捷方式加 `--proxy-server`，或全局设置
`HTTP_PROXY`/`HTTPS_PROXY`。Proxifier 的域名规则生效后，这些都可以省掉：

- Codex 直接双击启动，DNS 被接管 → 命中 OpenAI 规则 → 走 SOCKS5；
- 如果想"双保险"，保留 `--proxy-server` 也行：此时 App 只连 `127.0.0.1:端口`，
  命中 Localhost 规则直连，Proxifier 的域名规则不参与，相当于两条独立通道。

但**不要同时开 Windows 系统代理**（设置 → 网络和 Internet → 代理）：那会让同一个请求
先走系统代理、再被 Proxifier 接管，变成双重代理，通常表现为超时或证书错误。

---

## 六、常见问题

**Q1：改完文件，重启 Proxifier 后配置又变回去了？**
它退出时回写配置。编辑 profile 前先退出 App；或者用脚本（脚本会强制要求先退出）。

**Q2：`nslookup chatgpt.com` 显示的是真实 IP，是不是没生效？**
Windows 的 `nslookup` 自己发 DNS 包、不走 DNS Client 缓存，所以可能看到真实地址。
以 `Resolve-DnsName`、`Get-DnsClientCache` 和实际 `curl.exe` 的出口为准。

**Q3：关掉（或重启）Proxifier 后，Codex/浏览器突然都连不上了？**
缓存里还留着上一个 Proxifier 会话的 fake-IP（`127.x.x.x`，每次启动还会换一段），
没有 Proxifier 就没人把它们还原成真实地址：

```powershell
ipconfig /flushdns
# 然后重启 Codex / 浏览器
```

切换 profile、改完端口、重启 Proxifier 之后，也建议顺手 `ipconfig /flushdns` 一次。

**Q4：规则都加了，`chatgpt.com` 还是超时，但 `www.chatgpt.com` 正常？**
典型的旧 DNS 缓存问题：`ipconfig /flushdns`，再重启 Codex。新域名能过、裸域不能过，
基本就是这个原因。

**Q5：代理端口明明在跑，Proxifier 却连不上？**
profile 里端口写错是最常见的故障（例如客户端监听 `1086`，profile 里写着 `1087`）。
`Test-NetConnection 地址 端口` 先确认，再改 profile 的 `<Port>`。

**Q6：只有 HTTP 代理，没有 SOCKS5？**
Proxifier 4 支持 `HTTPS`（HTTP CONNECT）类型，在 GUI 里加即可；`codex-apply-proxifier.ps1`
目前只生成 SOCKS5。注意：明文 `HTTP` 类型只能代理 HTTP，HTTPS 站点会失败。

**Q7：Codex 还是不走代理？**
先看它是否自己实现了 DoH/硬编码 IP：`-NoRedact` 跑自检脚本的第 5 节。
确认是 DoH 的话，关掉应用内置的 Secure DNS，或者改用 TUN 模式（sing-box / Mihomo 的
fake-IP + 透明代理）在 IP 层接管。

**Q8：Proxifier 装了但没接管，驱动服务没起来？**
```powershell
Get-Service ProxifierDrv
```
应为 `Running`。被安全软件拦了就放行；服务模式（所有用户）在 Profile → Advanced 里开。

**Q9：能把这个配置发给别人吗？**
可以。`File → Export Profile` 导出 `.ppx`（可能含代理地址/密码），对方 `File → Import Profile`
再改成本机地址即可。profile 是 XML，也可以直接改文本。

---

## 七、回退

```powershell
# 1) 退出 Proxifier
Stop-Process -Name Proxifier -Force

# 2) 恢复备份（文件名换成你自己的）
$dir = "$env:APPDATA\Proxifier4\Profiles"
Copy-Item "$dir\Default.ppx.bak-20261113-023554" "$dir\Default.ppx" -Force
Set-ItemProperty 'HKCU:\Software\Initex\Proxifier\Settings' -Name ActiveProfile4 -Value 'Default'

# 3) 重新启动并刷 DNS
Start-Process 'C:\Program Files (x86)\Proxifier\Proxifier.exe'
ipconfig /flushdns
```

或者把 OpenAI 规则删掉、`Udp` 改回 `mode_bypass`、`ViaProxy` 关掉。

---

## 八、自检脚本（升级/换网络后先跑这个）

`codex-net-doctor.ps1` 只读、不改配置，用来判断"当前 Proxifier 配置还适不适用"。

```powershell
# 默认输出脱敏：代理出口 IP、真实 IP、profile 名打码；fake-IP 保留
./codex-net-doctor.ps1

# 只输出失败/警告
./codex-net-doctor.ps1 -Quiet

# 显示完整 IP / profile 名（仅本地排查）
./codex-net-doctor.ps1 -NoRedact

# 检查导出的 profile（导入前预检）
./codex-net-doctor.ps1 -Profile "$env:USERPROFILE\Desktop\Codex.ppx"
```

> 首次运行如报"禁止运行脚本"，用：
> `powershell -ExecutionPolicy Bypass -File .\codex-net-doctor.ps1`

退出码：`0` 全部通过、`1` 有失败项、`2` 只有警告。

它会检查七件事：

1. Proxifier / `ProxifierDrv` 驱动 / Codex 进程状态，App 是否还带着 `--proxy-server`；
2. 当前 profile 的 `ViaProxy`、`AutoModeDetection`、`Udp`、OpenAI 规则与 `Default` 的顺序；
3. 代理端口 TCP 可达、SOCKS5 握手、经代理能否拿到境外出口；
4. **系统层**（不带任何代理设置）`chatgpt.com` 是否为 fake-IP、能否走代理，
   规则外域名（Cloudflare）出口是否和代理出口不同；
5. Codex 是否连了已知 DoH 服务商；
6. 一批 OpenAI 域名的实际可达性；
7. Codex 可执行文件路径与版本（Electron 单文件无版本资源时读 `~/.codex/config.toml`），
   并记录"最后一次全部通过"的版本到 `%LOCALAPPDATA%\codex-net-doctor\last-good-version`。

---

## 附：最小可用 profile 片段（脱敏）

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxifierProfile version="102" platform="Windows" product_id="0" product_minver="400">
    <Options>
        <Resolve>
            <AutoModeDetection enabled="false" />
            <ViaProxy enabled="true" />
            <BlockNonATypes enabled="false" />
            <ExclusionList OnlyFromListMode="false">%ComputerName%; localhost; *.local</ExclusionList>
            <DnsUdpMode>0</DnsUdpMode>
        </Resolve>
        <Encryption mode="basic" />
        <ConnectionLoopDetection enabled="true" resolve="true" />
        <Udp mode="mode_block_443" />
        <LeakPreventionMode enabled="false" />
        <ProcessOtherUsers enabled="false" />
        <ProcessServices enabled="false" />
        <HandleDirectConnections enabled="false" />
        <HttpProxiesSupport enabled="false" />
    </Options>
    <ProxyList>
        <Proxy id="100" type="SOCKS5">
            <Options>48</Options>
            <Port>7890</Port>
            <Address>127.0.0.1</Address>
        </Proxy>
    </ProxyList>
    <ChainList />
    <RuleList>
        <Rule enabled="true">
            <Action type="Direct" />
            <Targets>localhost; 127.0.0.1; ::1; %ComputerName%; *.local; 192.168.0.0/16; 10.0.0.0/8; 172.16.0.0/12; 169.254.0.0/16</Targets>
            <Name>Localhost and LAN</Name>
        </Rule>
        <Rule enabled="true">
            <Action type="Direct" />
            <Applications>mihomo.exe; clash*.exe; sing-box.exe; v2ray*.exe; xray.exe; hysteria*.exe; tuic*.exe; socks5.exe</Applications>
            <Name>proxy client direct</Name>
        </Rule>
        <Rule enabled="true">
            <Action type="Proxy">100</Action>
            <Targets>openai.com; *.openai.com; chatgpt.com; *.chatgpt.com; *.oaistatic.com; oaistatic.com; *.oaiusercontent.com; oaiusercontent.com; openai.org; *.openai.org</Targets>
            <Name>OpenAI</Name>
        </Rule>
        <Rule enabled="true">
            <Action type="Direct" />
            <Name>Default</Name>
        </Rule>
    </RuleList>
</ProxifierProfile>
```
