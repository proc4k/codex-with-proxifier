<#
.SYNOPSIS
    为 Codex / ChatGPT 桌面版生成并启用 Proxifier (Windows v4) 按域名分流配置。

.DESCRIPTION
    生成一个 Proxifier 4 profile（.ppx）：DNS 走代理解析（fake-IP）、
    OpenAI 域名走代理、本机/内网直连、屏蔽 QUIC(UDP 443)、其余直连。

    写入位置：%APPDATA%\Proxifier4\Profiles\<ProfileName>.ppx
    并把 HKCU\Software\Initex\Proxifier\Settings\ActiveProfile4 指到它。

    注意：Proxifier 退出时会把内存里的配置写回文件，所以本脚本要求先退出它
    （或加 -Force 由脚本强制结束进程）。默认会先把旧 profile 自动改名为
    <ProfileName>.ppx.bak-<时间戳>。

.PARAMETER ProxyAddress
    代理服务器地址，默认 127.0.0.1。

.PARAMETER ProxyPort
    代理服务器端口，默认 1080。请换成你本地 SOCKS5 客户端实际监听的端口
    （Clash 常见 7890/7891，v2rayN 常见 10808，sing-box 常见 2080）。

.PARAMETER ProfileName
    生成的 profile 名，默认 Codex。

.PARAMETER IncludeBrowserRule
    额外生成一条 browser 规则（Google / GitHub / X / YouTube 走代理）。
    只做 Codex 时不需要。

.PARAMETER NoMerge
    不从当前生效的 profile 继承自定义规则（默认会继承名称不在标准集合里的规则）。

.PARAMETER NoStart
    只生成配置并设为活动 profile，不启动 Proxifier。

.PARAMETER Force
    Proxifier 正在运行时强制结束它（会丢失它尚未落盘的界面状态，一般不需要）。

.EXAMPLE
    ./codex-apply-proxifier.ps1 -ProxyPort 7890

.EXAMPLE
    ./codex-apply-proxifier.ps1 -ProxyAddress 192.168.10.47 -ProxyPort 1086 -IncludeBrowserRule
#>
[CmdletBinding()]
param(
    [string]$ProxyAddress = '127.0.0.1',

    [ValidateRange(1, 65535)]
    [int]$ProxyPort = 1080,

    [string]$ProfileName = 'Codex',

    [switch]$IncludeBrowserRule,
    [switch]$NoMerge,
    [switch]$NoStart,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Text) { Write-Host "== $Text ==" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [!]  $Text" -ForegroundColor Yellow }

# ---------- 路径 ----------
$exeCandidates = @(
    'C:\Program Files (x86)\Proxifier\Proxifier.exe',
    'C:\Program Files\Proxifier\Proxifier.exe'
)
$Exe = $exeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Exe) {
    throw "找不到 Proxifier.exe，请先安装 Proxifier 4（https://www.proxifier.com/）。"
}

$ProfileDir = Join-Path $env:APPDATA 'Proxifier4\Profiles'
$SettingsKey = 'HKCU:\Software\Initex\Proxifier\Settings'
$TargetPath = Join-Path $ProfileDir "$ProfileName.ppx"

if ($ProfileName -match '[\\/:*?"<>|]') {
    throw "ProfileName 不能包含这些字符：\ / : * ? "" < > |"
}
if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
}

Write-Step '1. 检查 Proxifier 进程'
$proc = Get-Process Proxifier -ErrorAction SilentlyContinue
if ($proc) {
    if (-not $Force) {
        throw "Proxifier 正在运行。请先完全退出它（Proxifier 退出时会把内存里的配置写回文件，运行中改文件会被覆盖），或加 -Force。"
    }
    Write-Warn "Proxifier 正在运行，按 -Force 结束进程（配置在每次修改时已落盘）。"
    $proc | Stop-Process -Force
    Start-Sleep -Milliseconds 800
} else {
    Write-Ok 'Proxifier 未在运行'
}

# ---------- 备份 ----------
Write-Step '2. 备份现有 profile'
if (Test-Path $TargetPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$TargetPath.bak-$stamp"
    Copy-Item -LiteralPath $TargetPath -Destination $bak
    Write-Ok "已备份到 $(Split-Path $bak -Leaf)"
} else {
    Write-Ok '目标 profile 尚不存在，无需备份'
}

# ---------- 继承自定义规则 ----------
Write-Step '3. 读取当前 profile 的自定义规则'
$standardNames = @('Localhost', 'Localhost and LAN', 'proxy client direct', 'OpenAI', 'browser', 'Default')
$mergedRules = New-Object System.Collections.ArrayList
$activeName = $null
try { $activeName = (Get-ItemProperty -Path $SettingsKey -Name ActiveProfile4 -ErrorAction Stop).ActiveProfile4 } catch { }

$mergeSource = $null
if ($activeName -and $activeName -ne $ProfileName) {
    $mergeSource = Join-Path $ProfileDir "$activeName.ppx"
} elseif (Test-Path (Join-Path $ProfileDir 'Default.ppx')) {
    # 重复运行时当前 profile 就是目标文件，退回到 Default.ppx 作为基线
    $mergeSource = Join-Path $ProfileDir 'Default.ppx'
}

if (-not $NoMerge -and $mergeSource -and (Test-Path $mergeSource)) {
    Write-Ok "继承来源：$(Split-Path $mergeSource -Leaf)"
    try {
        [xml]$old = Get-Content -LiteralPath $mergeSource -Raw -Encoding UTF8
        $oldRules = @($old.ProxifierProfile.RuleList.Rule)
        $seen = @{}
        foreach ($r in $oldRules) {
            if (-not $r) { continue }
            if ($standardNames -contains $r.Name) { continue }
            if ($seen.ContainsKey($r.Name)) { continue }
            $actionType = $null
            if ($r.Action) { $actionType = $r.Action.type }
            if ($actionType -eq 'Proxy') {
                $refId = "$($r.Action.InnerText)".Trim()
                if ($refId -ne '100') {
                    Write-Warn "跳过规则 $($r.Name)：引用了本 profile 里不存在的代理 id $refId"
                    continue
                }
            }
            $seen[$r.Name] = $true
            [void]$mergedRules.Add($r)
            Write-Ok "继承规则：$($r.Name)"
        }
    } catch {
        Write-Warn "读取 $mergeSource 失败，忽略继承：$($_.Exception.Message)"
    }
}
if ($mergedRules.Count -eq 0) { Write-Ok '没有需要继承的自定义规则' }

# ---------- 生成 profile ----------
Write-Step '4. 生成 profile'

$esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }

$ruleBlocks = New-Object System.Collections.ArrayList
[void]$ruleBlocks.Add(@"
		<Rule enabled="true">
			<Action type="Direct" />
			<Targets>localhost; 127.0.0.1; ::1; %ComputerName%; *.local; 192.168.0.0/16; 10.0.0.0/8; 172.16.0.0/12; 169.254.0.0/16</Targets>
			<Name>Localhost and LAN</Name>
		</Rule>
"@)
[void]$ruleBlocks.Add(@"
		<Rule enabled="true">
			<Action type="Direct" />
			<Applications>mihomo.exe; clash*.exe; sing-box.exe; v2ray*.exe; xray.exe; hysteria*.exe; tuic*.exe; socks5.exe; flclash*.exe; hiddify*.exe; verge-mihomo.exe</Applications>
			<Name>proxy client direct</Name>
		</Rule>
"@)
[void]$ruleBlocks.Add(@"
		<Rule enabled="true">
			<Action type="Proxy">100</Action>
			<Targets>openai.com; *.openai.com; chatgpt.com; *.chatgpt.com; *.oaistatic.com; oaistatic.com; *.oaiusercontent.com; oaiusercontent.com; openai.org; *.openai.org; *.chatgpt.livekit.cloud</Targets>
			<Name>OpenAI</Name>
		</Rule>
"@)
if ($IncludeBrowserRule) {
    [void]$ruleBlocks.Add(@"
		<Rule enabled="true">
			<Action type="Proxy">100</Action>
			<Targets>*.google.com; *.googleapis.com; *.gstatic.com; *.github.com; *.githubusercontent.com; *.twitter.com; *.x.com; *.youtube.com</Targets>
			<Name>browser</Name>
		</Rule>
"@)
}
foreach ($r in $mergedRules) {
    $xmlRule = $r.OuterXml
    # 统一缩进，保持文件可读
    [void]$ruleBlocks.Add("`t`t" + $xmlRule + "`r`n")
}

$profileXml = @"
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
			<Port>$ProxyPort</Port>
			<Address>$(& $esc $ProxyAddress)</Address>
		</Proxy>
	</ProxyList>
	<ChainList />
	<RuleList>
$($ruleBlocks -join '')
		<Rule enabled="true">
			<Action type="Direct" />
			<Name>Default</Name>
		</Rule>
	</RuleList>
</ProxifierProfile>
"@

# XML 校验：格式错误时抛出
try { [xml]$check = $profileXml } catch { throw "生成的 XML 无效：$($_.Exception.Message)" }
$lastRule = @($check.ProxifierProfile.RuleList.Rule)[-1]
if ("$($lastRule.Name)" -ne 'Default') { throw '内部错误：Default 规则不在最后' }

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($TargetPath, $profileXml, $utf8)
Write-Ok "已写入 $TargetPath"

# ---------- 设为活动 profile ----------
Write-Step '5. 设为活动 profile'
if (-not (Test-Path $SettingsKey)) { New-Item -Path $SettingsKey -Force | Out-Null }
Set-ItemProperty -Path $SettingsKey -Name ActiveProfile4 -Value $ProfileName
Write-Ok "ActiveProfile4 = $ProfileName"

# ---------- 启动 ----------
Write-Step '6. 启动 Proxifier'
if ($NoStart) {
    Write-Warn '按 -NoStart 跳过启动'
} else {
    Start-Process -FilePath $Exe -ArgumentList @("`"$TargetPath`"", 'silent-load')
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        if (Get-Process Proxifier -ErrorAction SilentlyContinue) { break }
    }
    if (Get-Process Proxifier -ErrorAction SilentlyContinue) {
        Write-Ok 'Proxifier 已启动并加载该 profile'
    } else {
        Write-Warn 'Proxifier 未在 6 秒内出现，请手动确认（可能被安全软件拦住了）'
    }
}

Write-Host ''
Write-Host "完成：SOCKS5 $ProxyAddress`:$ProxyPort → profile '$ProfileName'" -ForegroundColor Green
Write-Host '下一步：' -ForegroundColor Green
Write-Host '  1) 刷新 DNS： ipconfig /flushdns'
Write-Host '  2) 自检：     ./codex-net-doctor.ps1'
Write-Host '  3) 启动 Codex 桌面版，确认能登录 / 能对话'
