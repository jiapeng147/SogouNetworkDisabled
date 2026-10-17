# SogouNetworkDisabled

Windows 一键禁止搜狗输入法联网工具。

它会为搜狗输入法及其已发现的可执行组件创建 Windows 防火墙入站/出站阻止规则，并运行一个 SYSTEM 高权限后台监控任务。监控任务会检查搜狗进程的 TCP 连接，包括 VPN 打开后常见的本机代理连接，例如 `127.0.0.1:7890`；发现连接后只终止对应的搜狗网络组件，不会终止 VPN 代理程序或其他软件。

## 一键安装

1. 下载或复制整个仓库目录到 Windows 电脑。
2. 双击 `Start-SogouNetworkBlock.cmd`。
3. 在 UAC 窗口中允许管理员权限。

CMD 文件使用自身所在目录定位 PowerShell 脚本，不依赖固定盘符、用户名或当前命令行目录。把整个目录复制到 U 盘、桌面或其他磁盘后仍可启动。

## 查看状态

双击 `Status-SogouNetworkBlock.cmd`，或在管理员 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SogouNetworkBlock.ps1 -Mode Status
```

正常状态应包括：

- `ScheduledTask : Running`
- `ManagedRuleCount` 大于 0
- `ActiveSogouConnections : None`

## 卸载

双击 `Uninstall-SogouNetworkBlock.cmd`。卸载会删除本工具创建的防火墙规则和计划任务，并尝试恢复安装前保存的 Windows 防火墙配置文件状态。它不会删除搜狗输入法文件。

## 工作方式

- 自动扫描常见搜狗安装目录、注册表卸载项、搜狗服务和当前进程路径。
- 对发现的每个 `.exe` 创建入站和出站阻止规则。
- 计划任务名称为 `Sogou Network Block - Reapply Firewall Rules`。
- 计划任务以 `SYSTEM` 高权限在开机和登录时启动，并保持监控。
- 监控间隔约为 750 毫秒，搜狗组件被自动重启后也会再次处理。

## 影响范围

搜狗云输入、在线皮肤、广告、云同步、网页渲染和相关在线扩展可能无法使用；本地输入功能通常不受影响。为了确保 VPN 本地代理也不能绕过限制，发现搜狗进程建立 TCP 连接时会终止该搜狗进程。

## 环境要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1（系统自带）
- 管理员权限
- Windows Defender Firewall 服务和 NetSecurity PowerShell 模块可用

本项目不包含任何 GitHub Token、代理配置或用户隐私信息。
