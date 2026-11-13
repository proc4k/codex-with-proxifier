# Codex × Proxifier 分流配置与自检工具（macOS / Windows）

让 **Codex / ChatGPT 桌面版**通过代理稳定工作：不依赖启动脚本、
不用给每个 App 单独加 `--proxy-server` 或环境变量，由 Proxifier 在网络层按**域名**分流。

仓库分平台两套：

| 平台 | 指南 | 自检 | 一键配置 |
|---|---|---|---|
| macOS（Proxifier 3.15） | [`codex-macos-proxifier-guide.md`](codex-macos-proxifier-guide.md) | [`codex-net-doctor.sh`](codex-net-doctor.sh) | 手改 profile（见指南） |
| Windows（Proxifier 4.x） | [`codex-windows-proxifier-guide.md`](codex-windows-proxifier-guide.md) | [`codex-net-doctor.ps1`](codex-net-doctor.ps1) | [`codex-apply-proxifier.ps1`](codex-apply-proxifier.ps1) |

两个平台解决的问题一样：**DNS 污染下按域名分流**——域名交给代理解析，规则外的流量保持直连。
配置文件格式、路径和验证命令不同，务必看对应平台的指南。

## 适用场景

- 已有一个可用的代理（本地 SOCKS5，例如 `127.0.0.1:7890`；或局域网里的混合端口），出口在境外；
- Codex / ChatGPT 直接启动连不上（DNS 污染、域名未覆盖、QUIC 卡住等）；
- 希望按域名分流，而不是全局代理或给每个 App 写启动脚本。

## 快速开始（Windows）

```powershell
# 1) 退出 Proxifier，然后生成并启用配置（端口换成你的）
./codex-apply-proxifier.ps1 -ProxyAddress 127.0.0.1 -ProxyPort 7890

# 2) 刷 DNS
ipconfig /flushdns

# 3) 自检
./codex-net-doctor.ps1
```

首次运行如提示"禁止运行脚本"：

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-apply-proxifier.ps1 -ProxyPort 7890
powershell -ExecutionPolicy Bypass -File .\codex-net-doctor.ps1
```

脚本会：备份旧 profile → 继承你已有的自定义规则 → 写入 `%APPDATA%\Proxifier4\Profiles\Codex.ppx`
（DNS 走代理、OpenAI 域名走 SOCKS5、屏蔽 QUIC、其余直连）→ 设为活动 profile 并启动 Proxifier。

## 快速开始（macOS）

1. 按 [指南](codex-macos-proxifier-guide.md) 配置 Proxifier：
   - 代理：SOCKS5 `127.0.0.1:1234`（换成你自己的端口）；
   - Name Resolution：`Resolve host names through proxy`；
   - 规则顺序：代理客户端 / localhost / 内网 → Direct，OpenAI 域名 → Proxy，Default → Direct；
   - 改完执行 `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`。
2. 跑自检：

```sh
chmod +x codex-net-doctor.sh
./codex-net-doctor.sh
```

## 自检脚本

macOS：

```sh
./codex-net-doctor.sh                # 完整检查（默认脱敏）
./codex-net-doctor.sh --quiet        # 只输出失败/警告
./codex-net-doctor.sh --no-redact    # 显示完整 IP / profile 名（仅本地排查用）
./codex-net-doctor.sh --profile x.ppx # 检查导出的 profile（导入前预检）
```

Windows：

```powershell
./codex-net-doctor.ps1                # 完整检查（默认脱敏）
./codex-net-doctor.ps1 -Quiet         # 只输出失败/警告
./codex-net-doctor.ps1 -NoRedact      # 显示完整 IP / profile 名（仅本地排查用）
./codex-net-doctor.ps1 -Profile x.ppx # 检查导出的 profile（导入前预检）
```

退出码：`0` 全部通过、`1` 有失败项、`2` 只有警告。

**输出默认脱敏**：代理出口 IP、本机解析到的真实 IP、当前 profile 名都会显示为
`<redacted>`，但保留 `loc=US`、fake-IP、HTTP 状态码这些判断信息。直接贴 issue
不会泄露你的出口或所在地；需要完整值时才加 `-NoRedact` / `--no-redact`。

脚本只读，不改配置、不重启进程；唯一写入是"最后一次全部通过"的版本记录
（macOS `~/.cache/codex-net-doctor/`，Windows `%LOCALAPPDATA%\codex-net-doctor\`）。

## 依赖

- **Windows**：Windows 10/11、PowerShell 5.1+、`curl.exe`（系统自带）、Proxifier 4.x；
- **macOS**：macOS（在 macOS 26 + Proxifier 3.15 上验证）、`bash`、`curl`、`host`、`lsof`、
  `nc`、`plutil`、`python3`；
- [Proxifier](https://www.proxifier.com/)（商业软件，需自行购买）。

## 安全与隐私

- **不要**把真实的 Proxifier `.ppx` 导出文件提交到仓库或公开——里面包含代理服务器地址、端口，
  可能还有密码；
- 分享脚本输出时用默认模式（已脱敏）；截图前也检查一下是否带出了 IP；
- 文档中的端口 `7890`/`1234`、进程名 `mihomo` 均为示例，请替换为自己的配置。

## 免责声明

- 本项目为个人经验整理，与 OpenAI、Initex（Proxifier）均无关联，非官方文档；
- 仅供**已合法拥有可用代理**的用户做网络配置排错参考；请遵守所在地法律法规以及
  OpenAI、Proxifier 的服务条款，风险自负；
- 配置修改前请自行备份，因使用本仓库内容造成的任何损失，作者不承担责任。

## License

[MIT](LICENSE)
