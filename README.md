# Codex macOS × Proxifier 分流配置与自检工具

让 **Codex / ChatGPT 桌面版**在 macOS 上通过本地 SOCKS5 代理稳定工作：不依赖启动脚本、
不用给每个 App 单独加 `--proxy-server` 或环境变量，由 Proxifier 在网络层按**域名**分流。

本仓库包含两部分：

| 文件 | 说明 |
|---|---|
| [`codex-macos-proxifier-guide.md`](codex-macos-proxifier-guide.md) | 配置与排错指南：原理、规则、验证、常见坑、回退 |
| [`codex-net-doctor.sh`](codex-net-doctor.sh) | 只读自检脚本：Codex 升级或连不上时，判断当前配置是否仍适用 |

## 适用场景

- macOS，已有一个可用的**本地 SOCKS5 代理**（例如 `127.0.0.1:1234`，客户端不限：mihomo / sing-box / v2ray 等）；
- Codex / ChatGPT 直接启动连不上（DNS 污染、域名未覆盖、QUIC 卡住等）；
- 希望按域名分流，而不是全局代理或给每个 App 写启动脚本。

## 快速开始

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

3. 按输出里的「建议」逐条处理；全部通过后再启动 Codex。

## 自检脚本

```sh
./codex-net-doctor.sh                # 完整检查（默认脱敏）
./codex-net-doctor.sh --quiet        # 只输出失败/警告
./codex-net-doctor.sh --no-redact    # 显示完整 IP / profile 名（仅本地排查用）
./codex-net-doctor.sh --profile x.ppx # 检查导出的 profile（导入前预检）
```

退出码：`0` 全部通过、`1` 有失败项、`2` 只有警告。

**输出默认脱敏**：代理出口 IP、本机解析到的真实 IP、当前 profile 名都会显示为
`<redacted>`，但保留 `loc=US`、`fake-IP`、HTTP 状态码这些判断信息。直接贴 issue
不会泄露你的出口或所在地；需要完整值时才加 `--no-redact`。

脚本只读，不改配置、不重启进程；唯一写入是 `~/.cache/codex-net-doctor/last-good-version`
（记录最后一次全部通过的 App 版本，用于升级后对比）。

## 依赖

- macOS（在 macOS 26 + Proxifier 3.15 上验证）；
- [Proxifier](https://www.proxifier.com/)（商业软件，需自行购买）；
- `bash`、`curl`、`host`、`lsof`、`nc`、`plutil`、`python3`（macOS 自带或随 Xcode CLT 提供）。

## 安全与隐私

- **不要**把真实的 Proxifier `.ppx` 导出文件提交到仓库或公开——里面包含代理服务器地址、端口，可能还有密码；
- 分享脚本输出时用默认模式（已脱敏）；截图前也检查一下是否带出了 IP；
- 文档中的端口 `1234`、进程名 `mihomo` 均为示例，请替换为自己的配置。

## 免责声明

- 本项目为个人经验整理，与 OpenAI、Initex（Proxifier）均无关联，非官方文档；
- 仅供**已合法拥有可用代理**的用户做网络配置排错参考；请遵守所在地法律法规以及
  OpenAI、Proxifier 的服务条款，风险自负；
- 配置修改前请自行备份，因使用本仓库内容造成的任何损失，作者不承担责任。

## License

[MIT](LICENSE)
