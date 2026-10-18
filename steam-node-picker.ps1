#Requires -Version 5.1
<#
    steam-node-picker.ps1  —  Steam 下载 CDN 节点优选

    原理（全部基于实测结论）：
      1. Valve 的 GetServersForSteamPipe 接口【匿名可用】，能列出任意 cell 的候选节点。
      2. 但接口里的 load 字段对 CDN 类型恒为假值(50)，API 不告诉你谁快 —— 必须实测。
      3. 节点没有公开测速文件（/speedtest/ 302→403），无凭证时无法直接灌流量。
         所以真实吞吐只从 Steam 自己的 content_log.txt 里"白嫖"：
         stats: (CDN, 29) host: N Bytes, T sec (R Mbps)   ← Steam 亲测值，最可靠。
      4. 低延迟 NOT= 高速度（社区工具 HypoMux 也明确写了"不以低 ping 代替下载速度"），
         所以延迟只作为辅助参考，不参与最终排序。

    为什么不做成 Steam 界面插件：
      节点选择发生在 steamclient.dll 原生的 SteamPipe 层，界面插件（Millennium / SFP）
      只能画 UI，拿不到也改不了底层选路。所以做成外部脚本 —— 但效果一样：
      下载前先出对照表，把慢节点屏蔽掉，再让 Steam 去挑。

    一键部署（推荐，全程只弹一次 UAC）：
      双击  一键部署自动注入.cmd
        -> 提权一次，装好 3 个计划任务并立刻启动值守，之后不再需要任何操作。
      想还原：把同一个 .cmd 拖到命令行后面加 /uninstall，同样只弹一次 UAC。

    手动试验：
      .\steam-node-picker.ps1                            # 体检：候选池 + 历史真实速率 + 延迟
      .\steam-node-picker.ps1 -Days 30                   # 只看最近 30 天的真实速率
      .\steam-node-picker.ps1 -MinMbps 200               # 把"及格线"提到 200Mbps
      .\steam-node-picker.ps1 -Ban xz.pphimalayanrt.com  # 立即屏蔽指定节点（逗号可分隔多个，需管理员）
      .\steam-node-picker.ps1 -ApplyBlock                # 自动屏蔽所有判为慢的节点（需管理员）
      .\steam-node-picker.ps1 -Watch                     # 前台值守，Ctrl+C 停（看它干活用这个）
      .\steam-node-picker.ps1 -Undo                      # 一键完全还原 hosts

    改完 hosts 后：去 Steam 里暂停下载 3 秒再继续，它会重建候选池并跳过被屏蔽的节点。

    两个必须知道的坑：
      1. 本文件必须以 UTF-8 with BOM 保存。编辑器另存一次就可能丢 BOM，
         那样 PowerShell 5.1 会按 ANSI 读中文，直接语法报错。
      2. 本机策略 CurrentUser=RemoteSigned，而 PowerShell 把 F: 盘当"非本地"，
         脚本放在 F: 直接运行会被 "not digitally signed" 拦下（C: 就正常）。
         所以一律用 -ExecutionPolicy Bypass 启动；-InstallAuto 也会自动把脚本
         复制到 %ProgramData%\SteamNodePicker\ 再从那里注册任务，摆脱 F: 依赖。
#>
[CmdletBinding()]
param(
    [string]   $SteamPath   = 'D:\steam',
    [int]      $CellId      = 33,      # 167 只有 3 个国内节点；33 有 13 个（含东京）
    [int]      $Days        = 90,      # 统计最近多少天的日志
    [double]   $MinMbps     = 50,      # 低于此速率的节点会被判为"慢节点"
    [int]      $LatencyN    = 6,       # 每个节点 TCP 连接延迟采样次数
    [switch]   $ApplyBlock,
    [switch]   $Undo,
    [switch]   $Watch,                 # 常驻值守：盯 content_log，发现当前节点变慢就自动拉黑
    [int]      $PollSec     = 60,      # 值守轮询间隔（秒）
    [int]      $StrikeLimit = 2,       # 连续几次低速采样后才拉黑（防抖）
    [string]   $WatchLog    = '',      # 值守日志；留空 = %LOCALAPPDATA%\SteamNodePicker\watch.log
    [switch]   $InstallAuto,           # 一次性注册全部计划任务（只需授权这一次，详见 -InstallAuto 说明）
    [switch]   $RemoveAuto,            # 删除上面注册的计划任务
    [switch]   $Status,                # 只读体检：计划任务 + hosts 黑洞 + 值守日志，不需要管理员
    [switch]   $KickWatch,             # 重启值守任务（部署完立刻让它上岗，不用等下次登录）
    [string[]] $Ban         = @(),     # 立即屏蔽指定节点，例: -Ban xz.pphimalayanrt.com
    [string]   $HostsPath   = ''       # 仅用于测试；留空则用系统 hosts
)

$ErrorActionPreference = 'Stop'
$HostsFile = if ($HostsPath) { $HostsPath } else { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
$MarkBegin = '# === Steam Node Picker BEGIN ==='
$MarkEnd   = '# === Steam Node Picker END ==='
$LogFile   = Join-Path $SteamPath 'logs\content_log.txt'

function Write-Head($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 候选池
function Get-NodePool {
    param([int[]]$Cells, [string[]]$Extra = @())
    $pool  = @{}
    $cache = Join-Path $PSScriptRoot 'steam-node-pool.json'
    foreach ($c in $Cells) {
        $url = "https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?cell_id=$c&max_servers=64&launcher=0"
        $ok = $false
        foreach ($attempt in 1..3) {
            try {
                $r = Invoke-RestMethod -Uri $url -TimeoutSec 15 -ErrorAction Stop
                foreach ($s in $r.response.servers) {
                    if (-not $pool.ContainsKey($s.host)) {
                        $pool[$s.host] = [pscustomobject]@{
                            Host = $s.host; Type = $s.type; Cell = $c
                            Priority = $s.priority_class; WeightedLoad = $s.weighted_load
                            Https = $s.https_support; Source = 'API'
                        }
                    }
                }
                $ok = $true; break
            } catch { Start-Sleep -Milliseconds (500 * $attempt) }
        }
        if (-not $ok) { Write-Warning "cell $c 查询失败（已重试 3 次）" }
    }
    if ($pool.Count) {
        try { $pool.Values | ConvertTo-Json -Depth 4 | Set-Content -Path $cache -Encoding UTF8 } catch {}
    } elseif (Test-Path $cache) {
        Write-Warning '接口不可用，改用上次成功缓存的候选池'
        try {
            $pool = @{}
            (Get-Content $cache -Raw | ConvertFrom-Json) | ForEach-Object { $pool[$_.Host] = $_ }
        } catch { $pool = @{} }
    }

    # 兜底：把日志里出现过的节点也拉进来一起测。Valve 接口偶尔限流/超时，
    # 有这一层，工具在任何时候都能给出"延迟 + 历史真实速率"对照表。
    foreach ($h in $Extra) {
        if ($h -and -not $pool.ContainsKey($h)) {
            $pool[$h] = [pscustomobject]@{
                Host = $h; Type = 'Log'; Cell = 0; Priority = 0
                WeightedLoad = 0; Https = 'unknown'; Source = 'Log'
            }
        }
    }
    if ($pool.Count) { $pool.Values | Sort-Object Source, Type, Host }
}

# ---------------------------------------------------------------- 真实速率（日志白嫖）
function Get-RealSpeed {
    param([string]$Path, [int]$Days)
    if (-not (Test-Path $Path)) { Write-Warning "找不到日志 $Path"; return @() }
    $since = (Get-Date).AddDays(-$Days)
    $rx = '^\[(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] stats: \((?<type>\w+), (?<id>\d+)\) (?<host>[^:]+): (?<bytes>\d+) Bytes, (?<sec>\d+) sec \((?<mbps>[\d.]+) Mbps\)'
    $samples = New-Object System.Collections.Generic.List[object]
    # Steam 正持有该日志，必须以 FileShare.ReadWrite 打开才能读
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs)
    $lines = $sr.ReadToEnd() -split "`r?`n"
    $sr.Close(); $fs.Close()
    foreach ($line in $lines) {
        if ($line -notmatch 'stats: \(CDN') { continue }
        $m = [regex]::Match($line, $rx)
        if (-not $m.Success) { continue }
        $ts = [datetime]::ParseExact($m.Groups['ts'].Value, 'yyyy-MM-dd HH:mm:ss', $null)
        if ($ts -lt $since) { continue }
        $samples.Add([pscustomobject]@{
            Time   = $ts
            Host   = $m.Groups['host'].Value
            MB     = [math]::Round([double]$m.Groups['bytes'].Value / 1MB, 1)
            Sec    = [int]$m.Groups['sec'].Value
            Mbps   = [double]$m.Groups['mbps'].Value
        })
    }
    $samples
}

function Group-RealSpeed($samples) {
    $cut7 = (Get-Date).AddDays(-7)
    $samples | Group-Object Host | ForEach-Object {
        $g    = $_.Group
        $rec  = @($g | Where-Object { $_.Time -ge $cut7 })
        [pscustomobject]@{
            Host     = $_.Name
            Samples  = $g.Count
            AvgMbps  = [math]::Round(($g | Measure-Object Mbps -Average).Average, 1)
            Last7    = if ($rec.Count) { [math]::Round(($rec | Measure-Object Mbps -Average).Average, 1) } else { $null }
            MaxMbps  = [math]::Round(($g | Measure-Object Mbps -Maximum).Maximum, 1)
            LastSeen = ($g | Sort-Object Time | Select-Object -Last 1).Time
        }
    } | Sort-Object { if ($_.Last7 -ne $null) { -$_.Last7 } else { 0 } }
}

# ---------------------------------------------------------------- 延迟（仅参考）
function Test-NodeLatency {
    param($Nodes, [int]$ProbeCount)
    # 注意: PowerShell 变量名不区分大小写, 参数绝不能叫 $N —— 会和 foreach($n ...) 撞名变成 [int] 强转
    foreach ($node in $Nodes) {
      try {
        $h = $node.Host
        # CDN 节点 https=unavailable -> 只开 80；SteamCache 节点 https=mandatory -> 只开 443
        $port = if ($node.Https -eq 'mandatory') { 443 } else { 80 }
        $addrs = @()
        try { $addrs = (Resolve-DnsName $h -Type A -ErrorAction Stop | Where-Object IPAddress).IPAddress } catch {}
        if (-not $addrs) { [pscustomobject]@{ Host=$h; Port=$port; Addr='(解析失败)'; MinMs=$null; AvgMs=$null; Fail=$ProbeCount }; continue }
        $addr = @($addrs)[0]
        $times = @(); $fail = 0
        for ($i = 0; $i -lt $ProbeCount; $i++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $tcp.BeginConnect($addr, $port, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(3000)) { $tcp.EndConnect($ar); $times += $sw.Elapsed.TotalMilliseconds }
                else { $fail++ }
            } catch { $fail++ } finally { $tcp.Close() }
        }
        [pscustomobject]@{
            Host  = $h; Port = $port; Addr = $addr
            MinMs = if ($times) { [math]::Round(($times | Measure-Object -Minimum).Minimum, 1) } else { $null }
            AvgMs = if ($times) { [math]::Round(($times | Measure-Object -Average).Average, 1) } else { $null }
            Fail  = $fail
        }
      } catch {
        Write-Host "  [跳过] $($node.Host): $($_.Exception.Message)" -ForegroundColor DarkGray
      }
    }
}

# ---------------------------------------------------------------- hosts 黑洞
function Get-MarkedBlock {
    if (-not (Test-Path $HostsFile)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($HostsFile)
    $in = $false; $out = @()
    foreach ($l in $lines) {
        if ($l -eq $MarkBegin) { $in = $true;  continue }
        if ($l -eq $MarkEnd)   { $in = $false; continue }
        if (-not $in) { continue }
        $t = $l.Trim()
        # 必须跳过空行和注释行，否则 "# 连接被立即拒绝 -> ..." 会被当成主机名
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -ge 2 -and $parts[0] -match '^\d+\.\d+\.\d+\.\d+$') { $out += $parts[1] }
    }
    $out
}

function Remove-Block {
    if (-not (Test-Path $HostsFile)) { return }
    $lines = [System.IO.File]::ReadAllLines($HostsFile)
    $kept = @(); $in = $false
    foreach ($l in $lines) {
        if ($l -eq $MarkBegin) { $in = $true;  continue }
        if ($l -eq $MarkEnd)   { $in = $false; continue }
        if (-not $in) { $kept += $l }
    }
    while ($kept.Count -and -not $kept[-1].Trim()) { $kept = $kept[0..($kept.Count-2)] }
    [System.IO.File]::WriteAllLines($HostsFile, $kept, [System.Text.UTF8Encoding]::new($false))
    try { & ipconfig.exe /flushdns | Out-Null } catch {}
}

# ---------------------------------------------------------------- 自动值守
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 调 schtasks.exe。注意：全局 $ErrorActionPreference='Stop' 会把原生命令的 stderr
# 当成终止性错误直接退出脚本，所以这里必须临时降级成 Continue。
function Invoke-Schtasks([string[]]$Cmd) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & schtasks.exe @Cmd 2>&1 | Out-Null } catch {}
    finally { $ErrorActionPreference = $old }
    return ($LASTEXITCODE -eq 0)
}

function Remove-ScheduledTask([string]$Name) {
    # 返回值刻意做成字符串而不是布尔：'任务不存在' 和 '任务存在但没权限删'
    # 是完全不同的两件事，早先都用 $false 表示，结果没提权时会谎报"不存在"。
    $exists = $false
    try { $exists = [bool](Get-ScheduledTask -TaskName $Name -ErrorAction Stop) } catch { $exists = $false }
    if (-not $exists) { return 'missing' }
    try { Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue } catch {}
    $why = ''
    try {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop | Out-Null
        return 'removed'
    } catch { $why = $_.Exception.Message }
    if (Invoke-Schtasks @('/delete', '/tn', $Name, '/f')) { return 'removed' }
    # 删不掉：多半是当初用"最高权限"注册的，现在普通权限动不了它
    return ('denied: ' + $why)
}

# 值守日志。计划任务跑的时候窗口是隐藏的，所有动作只能靠这个文件留痕。
function Write-Log([string]$Path, [string]$Text) {
    if (-not $Path) { return }
    try {
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $Path -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8
    } catch {}
}

# 值守统一出口：既写日志，也打印（$WatchLogPath 由脚本作用域提供）
function Say([string]$Text, [string]$Color) {
    Write-Log -Path $WatchLogPath -Text $Text
    Write-Host ("  " + $Text) -ForegroundColor $Color
}

# 只读日志尾部 256KB，取最后一条 stats: 行 = Steam 此刻正在用的节点 + 它的实时速度
function Get-LastStat {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len  = $fs.Length
        $take = [Math]::Min(262144, $len)
        if ($take -le 0) { return $null }
        [void]$fs.Seek($len - $take, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $take
        [void]$fs.Read($buf, 0, $take)
        $txt = [System.Text.Encoding]::UTF8.GetString($buf)
    } finally { $fs.Close() }
    $rx   = '^\[(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] stats: \((?<type>\w+), (?<id>\d+)\) (?<host>[^:]+): (?<bytes>\d+) Bytes, (?<sec>\d+) sec \((?<mbps>[\d.]+) Mbps\)'
    $last = $null
    foreach ($line in ($txt -split "`r?`n")) {
        $m = [regex]::Match($line, $rx)
        if ($m.Success) {
            $last = [pscustomobject]@{
                Time = [datetime]$m.Groups['ts'].Value
                Host = $m.Groups['host'].Value
                Mbps = [double]$m.Groups['mbps'].Value
                Sec  = [int]$m.Groups['sec'].Value
            }
        }
    }
    $last
}

function Set-Block([string[]]$Hosts) {
    $lines = if (Test-Path $HostsFile) { [System.IO.File]::ReadAllLines($HostsFile) } else { @() }
    # 先移除旧块
    $kept = @(); $in = $false
    foreach ($l in $lines) {
        if ($l -eq $MarkBegin) { $in = $true;  continue }
        if ($l -eq $MarkEnd)   { $in = $false; continue }
        if (-not $in) { $kept += $l }
    }
    while ($kept.Count -and -not $kept[-1].Trim()) { $kept = $kept[0..($kept.Count-2)] }

    $bak = "$HostsFile.steam-nodepicker.bak"
    if ((Test-Path $HostsFile) -and -not (Test-Path $bak)) { Copy-Item $HostsFile $bak -Force }
    $body = @($kept) + @('', $MarkBegin)
    if ($Hosts -and $Hosts.Count) {
        $body += "# 由 steam-node-picker.ps1 生成于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $body += $Hosts | Sort-Object -Unique | ForEach-Object { "127.0.0.1`t$_" }
        $body += '# 连接被立即拒绝 -> Steam 快速失败并换到下一个候选节点'
    } else {
        $body += '# (空：未屏蔽任何节点)'
    }
    $body += $MarkEnd
    [System.IO.File]::WriteAllLines($HostsFile, $body, [System.Text.UTF8Encoding]::new($false))

    try { & ipconfig.exe /flushdns | Out-Null } catch {}
}

# ================================================================ MAIN
if ($Undo) {
    $id    = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin -and -not $HostsPath) { Write-Warning '改 hosts 需要管理员权限，请用管理员身份重开 PowerShell。'; return }
    Remove-Block
    Write-Host '已完全移除节点屏蔽块，hosts 恢复原样（备份仍在 hosts.steam-nodepicker.bak）。' -ForegroundColor Green
    return
}

if ($Ban.Count) {
    $id    = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin -and -not $HostsPath) { Write-Warning '写 hosts 需要管理员权限，请用管理员身份重开 PowerShell。'; return }
    # 支持 -Ban "a","b" 也支持 -Ban "a,b"（powershell.exe -File 传参会把数组并成一个逗号串）
    $banList = @($Ban | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $need = @($banList + @(Get-MarkedBlock)) | Sort-Object -Unique
    Set-Block $need
    Write-Host ''
    Write-Host ("  已屏蔽: " + ($need -join ', ')) -ForegroundColor Green
    Write-Host '  现在去 Steam 里【暂停下载 3 秒再继续】，它会重建候选池并跳过被屏蔽的节点。' -ForegroundColor Cyan
    Write-Host '  还原：.\steam-node-picker.ps1 -Undo' -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------- 自动注入（计划任务）
$TaskName = 'SteamNodePicker'

if ($Status) {
    # 纯只读体检，刻意不碰 hosts、不要求管理员 —— "它到底在不在跑"是最高频的疑问。
    Write-Host ''
    Write-Host '=== Steam 节点优选：当前状态 ===' -ForegroundColor Cyan

    Write-Host ''
    Write-Host '[ 计划任务 ]' -ForegroundColor White
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
               Where-Object { $_.TaskName -like "$TaskName*" })
    if ($tasks.Count -eq 0) {
        Write-Host '  （无）还没部署，或已被 -RemoveAuto 清掉' -ForegroundColor DarkGray
    } else {
        foreach ($t in $tasks) {
            $info = $null
            try { $info = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch {}
            # 计划任务没跑过时 LastRunTime 是 1999-11-30 这个哨兵值，别当真实时间显示
            $last = if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) {
                        '{0:yyyy-MM-dd HH:mm:ss} (结果 {1})' -f $info.LastRunTime, $info.LastTaskResult
                    } else { '从未运行' }
            Write-Host ('  - {0,-26} [{1}]' -f $t.TaskName, $t.State) -ForegroundColor Green
            Write-Host ('      上次运行：{0}' -f $last) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '[ hosts 黑洞 ]' -ForegroundColor White
    $block = Get-MarkedBlock
    if ($block.Count -eq 0) {
        Write-Host '  （空）hosts 干净，Steam 可以自由选择全部候选节点' -ForegroundColor DarkGray
    } else {
        foreach ($h in $block) { Write-Host ("  已屏蔽 " + $h) -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host '[ 值守日志 ]' -ForegroundColor White
    $wl = if ($WatchLog) { $WatchLog } else { Join-Path $env:LOCALAPPDATA 'SteamNodePicker\watch.log' }
    if (Test-Path $wl) {
        Write-Host ("  {0}" -f $wl) -ForegroundColor DarkGray
        Get-Content $wl -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        Write-Host ("  （还没产生）{0}" -f $wl) -ForegroundColor DarkGray
    }
    Write-Host ''
    return
}

if ($KickWatch) {
    # 部署完让值守立刻上岗：停掉可能还在跑着的旧实例，再按新脚本重新拉起。
    # 不这样做的话，老进程会一直用改之前的脚本跑到下次登录，改了配置也不生效。
    $wName = "$TaskName-Watch"
    if (-not (Get-ScheduledTask -TaskName $wName -ErrorAction SilentlyContinue)) {
        Write-Host '  值守任务还没注册，跳过后台启动（下次登录会自动跑）。' -ForegroundColor DarkGray
        return
    }
    try { Stop-ScheduledTask -TaskName $wName -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 500
    try {
        Start-ScheduledTask -TaskName $wName -ErrorAction Stop
        Write-Host '  值守已启动，正在后台静默盯着 Steam 下载。' -ForegroundColor Green
    } catch {
        Write-Host ("  值守未能立刻启动（{0}），它会在下次登录时自动运行。" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    return
}

if ($RemoveAuto) {
    Write-Host ''
    Write-Host '  卸载计划任务（同样只需这一次授权）' -ForegroundColor Cyan
    $nRemoved = 0; $nDenied = 0
    foreach ($n in @("$TaskName-Boot", "$TaskName-Refresh", "$TaskName-Watch",
                     "$TaskName-Watcher", $TaskName)) {
        $r = Remove-ScheduledTask $n
        if ($r -eq 'removed')   { Write-Host ("    [OK]   {0,-26} 已删除" -f $n) -ForegroundColor Green; $nRemoved++ }
        elseif ($r -eq 'missing') { Write-Host ("    [--]   {0,-26} 不存在（本来就没装）" -f $n) -ForegroundColor DarkGray }
        else {
            $nDenied++
            Write-Host ("    [!!]   {0,-26} 删不掉：{1}" -f $n, ($r -replace '^denied:\s*','')) -ForegroundColor Yellow
        }
    }
    if ($nDenied -gt 0) {
        Write-Host ''
        Write-Host ("  有 {0} 个任务存在但拒绝访问 —— 它们当初是按'最高权限'注册的，必须提权才能删。" -f $nDenied) -ForegroundColor Yellow
        Write-Host '  解决：用管理员身份重跑一次本脚本的 -RemoveAuto。' -ForegroundColor Yellow
    }

    # 顺手清掉 InstallAuto 复制过来的那份副本
    $destDir = Join-Path $env:ProgramData 'SteamNodePicker'
    if (Test-Path $destDir) {
        try {
            Remove-Item $destDir -Recurse -Force -ErrorAction Stop
            Write-Host ("    [OK]   {0} 已清理" -f $destDir) -ForegroundColor Green
        } catch {
            Write-Host ("    [--]   {0} 没清掉（正被占用或权限不足）" -f $destDir) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '  注意：hosts 里的黑洞还在。要一并还原请再跑一次 -Undo。' -ForegroundColor DarkGray
    return
}

if ($InstallAuto) {
    if (-not (Test-Admin)) { Write-Warning '注册计划任务需要管理员权限。双击 一键部署自动注入.cmd 会自动提权，弹一次 UAC 就够。'; return }

    $ps   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $self = $MyInvocation.MyCommand.Path
    $here = if ($self) { Split-Path $self -Parent } else { $PSScriptRoot }

    # 先把脚本复制到本机固定位置，再注册任务。两个实打实的理由：
    #   1. 脚本现在放在 F: 盘。要是哪天盘符变了/盘拔了，任务就全废；ProgramData 永远在。
    #   2. 本机 CurrentUser=RemoteSigned，而 PowerShell 把 F: 当非本地盘，直接运行会被
    #      "not digitally signed" 拦下（实测：F: 拦、C: 放行）。装到 C: 就没这回事。
    #      （任务里仍然保留 -ExecutionPolicy Bypass 兜底。）
    $destDir = Join-Path $env:ProgramData 'SteamNodePicker'
    try { if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null } } catch {}
    $dest = Join-Path $destDir 'steam-node-picker.ps1'
    if ($self -and ($self -ne $dest)) {
        Copy-Item -LiteralPath $self -Destination $dest -Force
        Write-Host ("  已安装到本机固定位置：{0}" -f $dest) -ForegroundColor DarkGray
    }
    $here = Split-Path $dest -Parent

    # 任务要跑在"真正在用 Steam 的那个人"名下。提权时若换了账号，$env:USERNAME 会是管理员，
    # 所以优先问系统：当前控制台登录的是谁。
    $who = $null
    try { $who = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { $who = $null }
    if (-not $who) { $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name }

    # 用 ScheduledTasks 的 cmdlet 而不是 schtasks.exe：
    # 参数走对象模型直接进任务定义，不经过命令行，路径里有 ! 、空格、中文都不会被吃掉。
    $base = @{
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        StartWhenAvailable         = $true
        MultipleInstances          = 'IgnoreNew'
    }
    $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Highest

    $trigLogon = New-ScheduledTaskTrigger -AtLogOn
    $trigEvery = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                     -RepetitionInterval (New-TimeSpan -Minutes 30) `
                     -RepetitionDuration (New-TimeSpan -Days 3650)

    $TaskSpecs = @(
        [pscustomobject]@{ Name = "$TaskName-Boot";    Args = '-ApplyBlock';        Trigger = $trigLogon; Watch = $false
                           Desc = '开机即把已知慢节点写进 hosts（下载前就已生效）' }
        [pscustomobject]@{ Name = "$TaskName-Refresh"; Args = '-ApplyBlock';        Trigger = $trigEvery; Watch = $false
                           Desc = '每 30 分钟重算黑名单，已恢复的节点自动放出' }
        [pscustomobject]@{ Name = "$TaskName-Watch";   Args = '-Watch -PollSec 20'; Trigger = $trigLogon; Watch = $true
                           Desc = '常驻值守，慢节点一冒头就自动拉黑（事件驱动）' }
    )

    # 清掉旧版本用过的任务名，免得老任务和新任务同时跑（两个都写 hosts 会互相打架）
    foreach ($legacy in @($TaskName, "$TaskName-Watcher")) {
        $r = Remove-ScheduledTask $legacy
        if ($r -eq 'removed') { Write-Host ("  已清理旧版任务：{0}" -f $legacy) -ForegroundColor DarkGray }
    }

    Write-Host ''
    Write-Host '  用最高权限注册计划任务 —— 授权这一次，之后全部静默运行，不会再弹 UAC。' -ForegroundColor Cyan
    Write-Host ("  运行身份：{0}（最高权限 / 仅登录时）" -f $who) -ForegroundColor DarkGray
    Write-Host ''
    $okA = $true
    foreach ($t in $TaskSpecs) {
        try {
            $act = New-ScheduledTaskAction -Execute $ps -WorkingDirectory $here `
                       -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest`" {0} -MinMbps {1}" -f $t.Args, $MinMbps)
            if ($t.Watch) {
                # 值守要一直活着：不限时长，挂了自动重启
                $set = New-ScheduledTaskSettingsSet @base -ExecutionTimeLimit ([TimeSpan]::Zero) `
                           -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
            } else {
                # 扫描类任务别赖着不走
                $set = New-ScheduledTaskSettingsSet @base -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            }
            Register-ScheduledTask -TaskName $t.Name -Action $act -Trigger $t.Trigger `
                -Settings $set -Principal $principal -Force -ErrorAction Stop | Out-Null
            Write-Host ("    [OK]   {0,-26} {1}" -f $t.Name, $t.Desc) -ForegroundColor Green
        } catch {
            $okA = $false
            Write-Host ("    [失败] {0,-26} {1}" -f $t.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host ''
    if ($okA) {
        Write-Host '  装好了。从现在起全自动，零点击零弹窗：' -ForegroundColor Green
        Write-Host '    开机    -> -Boot   立刻把已知慢节点打进 hosts 黑洞（下载开始前就已生效）' -ForegroundColor White
        Write-Host '    下载期间 -> -Watch  盯 content_log，慢节点一冒头就自动拉黑（事件驱动，几乎不吃 CPU）' -ForegroundColor White
        Write-Host '    每 30 分 -> -Refresh 用新样本重算黑名单，已恢复的节点会被自动放出来' -ForegroundColor White
        $lg = if ($WatchLog) { $WatchLog } else { Join-Path $env:LOCALAPPDATA 'SteamNodePicker\watch.log' }
        Write-Host ("  值守日志：{0}" -f $lg) -ForegroundColor DarkGray
        Write-Host '  卸载：再跑一次 -RemoveAuto（同样只需一次授权）' -ForegroundColor DarkGray
    }
    return
}

# 值守模式跳过下面一整段联网扫描：网络卡住时更需要立刻开始盯日志，不能干等重试。
if (-not $Watch) {
    # 先读日志（后面选路要用）：Steam 自己记录的每个节点的真实速率
    $samples = Get-RealSpeed -Path $LogFile -Days $Days
    $stats   = if ($samples -and $samples.Count) { Group-RealSpeed $samples } else { @() }

    Write-Head "1. 候选池 (cell $CellId$(if($CellId -ne 167){' / 对比 167'}))"
    $cells = if ($CellId -eq 167) { @(167) } else { @($CellId, 167) }
    $pool = @(Get-NodePool -Cells $cells -Extra @($stats.Host))
    if (-not $pool) { Write-Host '  候选池为空。' -ForegroundColor Yellow }
    else {
        $pool | Format-Table Host, Source, Type, Cell, Priority, WeightedLoad -AutoSize | Out-String | Write-Host
        $nApi = @($pool | Where-Object Source -eq 'API').Count
        $nLog = @($pool | Where-Object Source -eq 'Log').Count
        Write-Host ("  共 {0} 个节点：Valve 接口 {1} 个，日志兜底 {2} 个（Source=Log 表示接口没返回、仅历史见过）" -f $pool.Count, $nApi, $nLog) -ForegroundColor DarkGray
    }

    Write-Head "2. 真实速率排行（来源：Steam 自己的 content_log.txt，最近 $Days 天）"
    if (-not $samples -or $samples.Count -eq 0) {
        Write-Host '  暂无统计样本。Steam 大约每 5 分钟写一次 stats 行，下载跑一会儿再来看。' -ForegroundColor Yellow
    } else {
        $stats | Format-Table Host, Samples, AvgMbps, Last7, MaxMbps, LastSeen -AutoSize | Out-String | Write-Host
        Write-Host ("  总样本 {0} 条，覆盖 {1} 个节点。Last7 = 最近 7 天均值（判定用这个）" -f $samples.Count, $stats.Count)
    }

    Write-Head "3. TCP 连接延迟（仅供参考，低延迟 != 高速度）"
    if ($pool) {
        Test-NodeLatency -Nodes $pool -ProbeCount $LatencyN |
            Sort-Object { if ($_.AvgMs -eq $null) { 9999 } else { $_.AvgMs } } |
            Format-Table Host, Port, Addr, MinMs, AvgMs, Fail -AutoSize | Out-String | Write-Host
    }

    Write-Head "4. 结论"
    # 只对"当前候选池里 Steam 真的会选的节点"下判断；历史节点（akamai/fastly 等）已经不在池里，管不着
    $liveHosts   = @($pool | Where-Object { $_.Source -ne 'Log' } | ForEach-Object { $_.Host })
    $poolStats   = @($stats | Where-Object { $liveHosts -contains $_.Host })
    $good = @(); $bad = @()
    foreach ($s in $poolStats) {
        $v = if ($s.Last7 -ne $null) { $s.Last7 } else { $s.AvgMbps }
        if ($v -ge $MinMbps) { $good += $s.Host } else { $bad += $s.Host }
    }
    if (-not $liveHosts.Count) {
        Write-Host '  这一轮没拿到 Valve 的候选池（接口超时/限流），无法判断 Steam 会选谁。' -ForegroundColor Yellow
        Write-Host '  但下面的延迟和历史速率依然有效，可直接用 -Ban 手工屏蔽已知的慢节点。' -ForegroundColor DarkGray
    }
    if ($poolStats.Count -eq 0) {
        Write-Host '  候选池里的节点还没有实测样本 —— 先让 Steam 下载几分钟（约 5 分钟写一次 stats），再跑一次本脚本。' -ForegroundColor Yellow
    } else {
        Write-Host ("  达标 (>= $MinMbps Mbps): " + $(if($good){$good -join ', '}else{'(无)'})) -ForegroundColor Green
        Write-Host ("  拖后腿 (<  $MinMbps Mbps): " + $(if($bad){$bad -join ', '}else{'(无)'}))  -ForegroundColor Red
        Write-Host ''
        if ($bad.Count -and $good.Count) {
            Write-Host '  建议：把"拖后腿"的节点打进 hosts 黑洞，Steam 就只能从快的里面挑：' -ForegroundColor Cyan
            Write-Host ("      .\steam-node-picker.ps1 -Ban " + ($bad -join ',')) -ForegroundColor White
            Write-Host '      或者自动判定：.\steam-node-picker.ps1 -ApplyBlock   （需管理员）' -ForegroundColor White
            Write-Host '  想还原随时执行：.\steam-node-picker.ps1 -Undo' -ForegroundColor White
        } elseif ($bad.Count -eq $poolStats.Count) {
            Write-Host '  所有候选节点都慢 —— 问题多半不在节点，检查下载区域/代理。' -ForegroundColor Yellow
        }
    }

    if ($ApplyBlock) {
        if ($bad.Count -eq 0) { Write-Host '没有需要屏蔽的节点。' -ForegroundColor Green; return }
        if ($good.Count -eq 0) { Write-Warning '候选池里没有快的节点，全屏蔽会让 Steam 无节点可用，已中止。'; return }
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin -and -not $HostsPath) { Write-Warning "写 hosts 需要管理员权限，请用管理员身份重开 PowerShell。"; return }

        # 只屏蔽当前候选池里的慢节点；顺手清掉之前屏蔽过但已不在池里的陈旧条目
        $target = @($bad)
        Set-Block $target
        Write-Host ''
        Write-Host ("  已屏蔽: " + ($target -join ', ')) -ForegroundColor Green
        Write-Host ("  备份:   $HostsFile.steam-nodepicker.bak") -ForegroundColor DarkGray
        Write-Host '  现在去 Steam 里【暂停下载 3 秒再继续】，让它重建候选池。' -ForegroundColor Cyan
        Write-Host '  生效后重新跑一次本脚本（不加参数）确认速度是否改善；不满意就 -Undo。' -ForegroundColor DarkGray
    }

}

# ---------------------------------------------------------------- 常驻值守（下载一开始就自动接管）
if ($Watch) {
    $admin  = Test-Admin
    $banned = @(Get-MarkedBlock)
    $WatchLogPath = if ($WatchLog) { $WatchLog } else { Join-Path $env:LOCALAPPDATA 'SteamNodePicker\watch.log' }

    # 事件驱动：Steam 一写 content_log 就立刻醒；没在下载时 CPU 为 0。
    # WaitForChanged 带超时，既是"立刻响应"也是"兜底轮询"。
    $fsw = $null
    try {
        $fsw = New-Object System.IO.FileSystemWatcher
        $fsw.Path         = Split-Path $LogFile -Parent
        $fsw.Filter       = Split-Path $LogFile -Leaf
        $fsw.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
    } catch { $fsw = $null }

    Write-Head '自动值守模式'
    Say ("阈值 {0} Mbps，连续 {1} 次不达标才拉黑；唤醒方式: {2}" -f $MinMbps, $StrikeLimit, $(if ($fsw) { '日志一变动就醒（事件驱动）' } else { "每 $PollSec 秒轮询" })) 'Cyan'
    Say ("hosts 写权限: " + $(if ($admin) { '有（已提权）—— 可自动拉黑' } else { '无 —— 只能记账，请用管理员运行或装计划任务' })) $(if ($admin) { 'Green' } else { 'Yellow' })
    Say ("值守日志: $WatchLogPath") 'DarkGray'
    Say '按 Ctrl+C 停止。' 'DarkGray'

    $miss = @{}; $notified = @{}
    $lastNormalKey = ''; $lastNormalAt = (Get-Date).AddYears(-1)
    while ($true) {
        # ---- 等下一次日志变动（或超时）----
        if ($fsw) {
            try {
                $r = $fsw.WaitForChanged([System.IO.WatcherChangeTypes]::All, [int]($PollSec * 1000))
                if (-not $r.TimedOut) { Start-Sleep -Milliseconds 900 }   # 等 Steam 把这行写完
            } catch { $fsw = $null }
        } else {
            Start-Sleep -Seconds $PollSec
        }

        # ---- 看当前节点快不快 ----
        try {
            $s = Get-LastStat -Path $LogFile
            if (-not $s) {
                if (-not $notified['__idle']) { Say '读不到 stats 行（Steam 没在下载？）' 'DarkGray'; $notified['__idle'] = $true }
            } elseif (((Get-Date) - $s.Time).TotalMinutes -gt 10) {
                if (-not $notified['__idle']) { Say ("日志已 {0:N0} 分钟没更新，Steam 大概没在下载。" -f ((Get-Date) - $s.Time).TotalMinutes) 'DarkGray'; $notified['__idle'] = $true }
            } elseif ($s.Mbps -lt $MinMbps) {
                $notified['__idle'] = $false
                $c = [int]$(if ($miss.ContainsKey($s.Host)) { $miss[$s.Host] } else { 0 })
                if ($c -lt $StrikeLimit) {
                    $c++; $miss[$s.Host] = $c
                    Say ("{0} 只有 {1} Mbps（第 {2}/{3} 次）" -f $s.Host, $s.Mbps, $c, $StrikeLimit) 'Yellow'
                }
                if ($c -ge $StrikeLimit -and $banned -notcontains $s.Host) {
                    if ($admin) {
                        $banned = @(@($banned) + $s.Host | Where-Object { $_ } | Sort-Object -Unique)
                        Set-Block $banned
                        Say ("已把 {0} 打进 hosts 黑洞 —— Steam 新建连接时会换节点（若没换，暂停 3 秒再继续）。" -f $s.Host) 'Red'
                    } else {
                        Say ("慢节点 {0} 已到阈值，但没有管理员权限写 hosts，只能记账。" -f $s.Host) 'Red'
                    }
                }
            } else {
                $notified['__idle'] = $false
                $key = "{0}|{1:N0}" -f $s.Host, $s.Mbps
                if ($key -ne $lastNormalKey -or ((Get-Date) - $lastNormalAt).TotalMinutes -ge 10) {
                    Say ("{0}: {1} Mbps 正常" -f $s.Host, $s.Mbps) 'Green'
                    $lastNormalKey = $key; $lastNormalAt = Get-Date
                }
                if ($notified.ContainsKey($s.Host)) { $notified.Remove($s.Host) | Out-Null }
                if ($miss.ContainsKey($s.Host))     { $miss.Remove($s.Host) | Out-Null }
            }
        } catch {
            Say ("本轮检查出错：{0}" -f $_.Exception.Message) 'DarkGray'
        }
    }
}
