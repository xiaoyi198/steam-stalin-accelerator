# 基于斯大林算法的 Steam 下载加速

> 名字是玩笑，算法是真货。
>
> **斯大林算法**：不测速、不调参、不协商、不做平滑迁移。
> 谁拖后腿，就直接从候选池里物理清除 —— `hosts` 拉黑，让 Steam 自己"快速失败"换线。

![status](https://img.shields.io/badge/平台-Windows-blue) ![powershell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE) ![license](https://img.shields.io/badge/license-MIT-green)

---

## 它解决的是什么问题

千兆宽带，Steam 下载却只有 5 Mbps？问题通常不在你的线路，而在 **Steam 给你分到了哪个 CDN 节点**。

Steam 下载时会从一批候选内容服务器里挑一个。这个挑选过程有个要命的特征：

- 它对每个节点的**打分基于历史吞吐**，而不是事前测速；
- 换节点是**惰性的** —— 它得先在你身上慢上几分钟，攒够统计样本，才可能切走；
- 有些节点（尤其是某些第三方 CDN）**稳定地慢**，而 Steam 每次开局还是会抽到它。

于是你看到的现象就是：**下载一开始很慢，过几分钟莫名其妙快了**。那不是你运气变好了，是 Steam 自己终于把慢节点淘汰了 —— 代价是你已经白等了几分钟。

这个脚本干的事就一句话：**把"等 Steam 自己反应过来"的那几分钟省掉**，方法是从历史里提前知道哪些节点是坑，开局就把它们物理屏蔽掉。

---

## 核心思路：不测速，蹭 Steam 自己的测量结果

这是整个项目的关键决策，也是最反直觉的地方。

### 为什么不能自己给每个节点测速？

项目立项时认真试过，**此路不通**：

| 尝试 | 结果 |
| --- | --- |
| `IContentServerDirectoryService/GetServersForSteamPipe` | 匿名可用，能拿到候选池，但 `load` 字段对 CDN 恒为 `50` —— 接口压根不告诉你谁快 |
| 节点上的 `/speedtest/` 之类的测速文件 | `302` → `403`，没有公开的测速端点 |
| 直接拉 chunk 路径灌流量 | 国内 CDN 返 `302`，`xz.*` 那类直接 `403` |
| 拿 `auth_key` 换个 host 复用 | 与主机绑定，换 host 立刻 `401`/`302` |
| `GetCDNAuthToken` / `GetManifestRequestCode` | `404` |

结论：**外部无法给每个候选节点灌真实流量测吞吐**。这不是没找对方法，是 Valve 根本没留这个口子。

### 那就蹭现成的

Steam 自己在 `content_log.txt` 里写下了每个节点的**真实平均吞吐**：

```
[2026-10-18 13:34:41] stats: (CDN,29) st.dl.eccdnx.com: 2534884048 Bytes, 32 sec (630.31 Mbps). 2545 Hits / 0 Misses (100 %, 100 % bytes), score 0.6614
```

这是**实测值**，不是估计值 —— Steam 真金白银从那个节点下了 2.5 GB 才写出来的。脚本直接解析这些行，按主机名聚合，得出每个节点的历史真实速率。

代价是它是**后验**的：你得先被某个节点坑过一次，脚本才知道它坑。但对长期使用来说完全够 —— 一个节点今天慢，明天大概率还是慢。

**低延迟 ≠ 高速度**。脚本确实也测 TCP 握手延迟，但只作为参考信息展示，绝不拿它做决策。实测里就有 36 ms 的节点跑 146 Mbps、39 ms 的节点跑 630 Mbps。

---

## 三步走

```
审判  →  处决  →  复查
```

1. **审判** —— 解析 `content_log.txt`（默认最近 90 天），按主机名聚合真实利用率，低于 `-MinMbps`（默认 50）的判为慢节点。
2. **处决** —— 把慢节点写进 `hosts` 指向 `127.0.0.1`。连接瞬间被拒，Steam **快速失败**并切到下一个候选，不再浪费几分钟去"先试一会儿"。
3. **复查** —— 计划任务每 30 分钟重跑一次，已经被 Steam 自己淘汰掉的、或者后来恢复了的节点会被自动放出黑名单。

> **为什么是"钉死 IP"而不是"改配置文件"？**
> Steam 的主节点选择（`CellIDServerOverride` 之类）只能锁候选池，**锁不住池子里挑谁**。而 `hosts` 是在 DNS 层拦截，Steam 无论怎么挑都会撞墙然后换人。改动可见、可审计、可一键还原。

---

## 安装

### 一键部署（推荐）

1. 把 `steam-node-picker.ps1` 和 `一键部署自动注入.cmd` 放在**同一个文件夹**里；
2. **双击 `一键部署自动注入.cmd`**，在 UAC 弹窗点一次「是」。

就这两步。之后全程静默，不会再弹任何窗口。

脚本会做这些事：

- 把自身复制到 `C:\ProgramData\SteamNodePicker\`（**摆脱对原目录的依赖**，原目录在移动盘上也不会失效）；
- 清理旧版本残留的计划任务；
- 注册 3 个计划任务：
  - `SteamNodePicker-Boot` —— 登录时跑一次，把已知慢节点先写进黑洞，**下载开始前就已生效**；
  - `SteamNodePicker-Refresh` —— 每 30 分钟重算黑名单，恢复的节点自动放出；
  - `SteamNodePicker-Watch` —— 常驻值守，慢节点一冒头就拉黑；
- 立刻跑一次扫描并启动值守，不用等下次开机；
- 打印一份落地检查报告。

### 只用手动模式

```powershell
# 体检：候选池 + 历史真实速率 + 延迟（只读，不改任何东西）
.\steam-node-picker.ps1

# 自动屏蔽所有判为慢的节点（需要管理员）
.\steam-node-picker.ps1 -ApplyBlock

# 把及格线提到 200 Mbps
.\steam-node-picker.ps1 -ApplyBlock -MinMbps 200

# 立刻屏蔽指定节点
.\steam-node-picker.ps1 -Ban xz.pphimalayanrt.com

# 前台值守，能看见它干活（Ctrl+C 停）
.\steam-node-picker.ps1 -Watch

# 一键完全还原 hosts
.\steam-node-picker.ps1 -Undo
```

### 卸载

```cmd
一键部署自动注入.cmd /uninstall
```

同样只弹一次 UAC。会删掉全部计划任务、还原 `hosts`、清理安装副本。

### 看状态

```cmd
一键部署自动注入.cmd /status
```

**不需要管理员**，只读。一次看清计划任务状态、上次运行结果、`hosts` 黑洞内容、值守日志末尾。

---

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-SteamPath` | `D:\steam` | Steam 安装目录，用于定位 `logs\content_log.txt` |
| `-CellId` | `33` | 查询候选池的 cell。`167` 只有 3 个国内节点，`33` 有 13 个（含东京） |
| `-Days` | `90` | 统计最近多少天的日志 |
| `-MinMbps` | `50` | 低于此速率判为慢节点 |
| `-LatencyN` | `6` | 每个节点 TCP 连接延迟采样次数 |
| `-PollSec` | `60` | 值守轮询间隔（秒）。`-Watch` 下由文件变动触发，这是兜底周期 |
| `-StrikeLimit` | `2` | 连续几次低速采样才拉黑（防抖） |
| `-WatchLog` | `%LOCALAPPDATA%\SteamNodePicker\watch.log` | 值守日志路径 |
| `-ApplyBlock` / `-Undo` / `-Watch` | | 见上文 |
| `-InstallAuto` / `-RemoveAuto` / `-KickWatch` / `-Status` | | 计划任务相关 |
| `-Ban` | | 立即屏蔽指定节点，逗号可分隔多个 |
| `-HostsPath` | | 仅测试用，指向别处的 hosts 副本 |

---

## 改完 `hosts` 后要做什么

去 Steam 里**暂停下载 3 秒再继续**。Steam 会重建候选池并跳过被屏蔽的节点。

---

## 安全性与可逆性

这个工具确实会修改 `hosts` —— 所以它把"可逆"当成硬要求：

- 只在自己写的标记块里动手：

  ```
  # === Steam Node Picker BEGIN ===
  127.0.0.1	xz.pphimalayanrt.com
  # === Steam Node Picker END ===
  ```

  块外一个字都不碰；
- 首次修改前自动备份到 `hosts.steam-nodepicker.bak`；
- 写完 `ipconfig /flushdns`；
- `-Undo` 真正做到完全还原（不是清空块，是删掉块）；
- `-RemoveAuto` 报告的是**三态**：已删除 / 本来就不存在 / **存在但拒绝访问**（后者会明确告诉你需要提权，不会骗你说"不存在"）。

---

## 已知限制

- **后验**。脚本靠历史数据判断，一个全新的、从没下载过的慢节点，第一次仍然会坑你一次。`-Watch` 值守就是用来把这个窗口压到最短的。
- **只对 Windows 有效**。依赖 Windows 的 `hosts` 路径和计划任务。
- **日本节点延迟高但有带宽**。候选池里的东京 `steamcontent.com` 节点实测延迟 90–290 ms，但历史样本不足时脚本会保守处理。
- **不要拿它做别的**。这不是通用广告拦截器，标记块里只放 Steam 内容节点。

---

## 两个真实的坑（踩过，写下来免得你也踩）

1. **`.ps1` 必须以 UTF-8 with BOM 保存。** 丢了 BOM，PowerShell 5.1 会按 ANSI 读中文，然后报一堆假的「缺少大括号」语法错误 —— 报错位置和真实问题毫无关系，极难查。
2. **`RemoteSigned` 策略 + 非系统盘 = 拒跑。** PowerShell 把 `F:` 这类盘符当"非本地"，脚本放在那儿直接运行会被 `not digitally signed` 拦下，放 `C:` 就正常。所以部署脚本会把自身复制到 `C:\ProgramData\` 再注册任务，命令里也都带 `-ExecutionPolicy Bypass` 兜底。

---

## License

MIT
