# 南邮校园网开机自动登录

南京邮电大学校园网（Dr.COM 哆点认证）Windows 自动登录脚本。登录 Windows 后自动联网，不用再手动选择“校园网 / 中国移动 / 中国电信”。

> 适用于南邮 `p.njupt.edu.cn` 认证门户。其他学校如果也是 Dr.COM 门户，可以参考修改。

## 功能

- **开机自动登录**：登录 Windows 后 15 秒检查一次，未在线就自动认证
- **只运行一次**：不做定时轮询，不会在游戏过程中反复弹窗
- **完全静默**：计划任务通过 `wscript` 隐藏启动，不闪命令行窗口
- **可视化设置页**：本地网页填写学号、密码、运营商，保存即可
- **运营商可选**：中国移动 `@cmcc`、中国电信 `@njxy`、校园网（无后缀）
- **密码加密保存**：使用 Windows DPAPI，只有当前 Windows 用户能解密
- **失败兜底**：登录失败会自动打开认证页，方便手动登录
- **可卸载**：一条命令删除计划任务、快捷方式和安装目录

## 快速开始

### 1. 下载

```powershell
git clone https://github.com/K4shJ/NJUPT-campus-autologin.git
cd NJUPT-campus-autologin
```

或者直接下载 ZIP 解压。

### 2. 安装

双击 `安装.cmd`，按提示输入：

- 学号（不含 `@cmcc`）
- 校园网密码

也可以直接在 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Account "你的学号" -Suffix "@cmcc"
```

中国电信把 `@cmcc` 换成 `@njxy`；校园网传空字符串：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Account "你的学号" -Suffix "@njxy"
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Account "你的学号" -Suffix ""
```

安装脚本会：

1. 把脚本和设置页复制到 `%LOCALAPPDATA%\CampusAutoLogin`
2. 用 DPAPI 加密保存密码到 `cred.xml`
3. 注册计划任务 `NJUPT-CampusAutoLogin`（只在登录 Windows 时运行一次）
4. 创建桌面快捷方式
5. 立即运行一次并显示结果

### 3. 打开设置页

双击桌面的 **“校园网设置”**，或运行：

```powershell
wscript.exe "$env:LOCALAPPDATA\CampusAutoLogin\打开设置.vbs"
```

设置页支持：

- 修改学号 / 账号
- 修改密码（留空表示不修改）
- 切换校园网 / 中国移动 / 中国电信
- “保存并测试”：保存后立即执行一次登录并显示结果

设置页只监听 `127.0.0.1`，账号密码不会上传。

## 计划任务

| 项目 | 值 |
| --- | --- |
| 任务名 | `NJUPT-CampusAutoLogin` |
| 触发 | 登录 Windows 后 15 秒，**仅一次** |
| 运行方式 | `wscript.exe` 隐藏启动 PowerShell，不闪窗口 |
| 运行身份 | 当前用户，普通权限（不需要管理员） |
| 已在线时 | 约 1 秒退出 |
| 电池 | 允许在电池供电时运行 |

没有“每 5 分钟检查”的定时器；网络断开后需要手动双击“校园网立即登录”，或重新登录 Windows。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `campus_autologin.ps1` | 主脚本：检测在线状态、提交认证 |
| `install.ps1` | 安装：复制文件、加密密码、注册计划任务 |
| `uninstall.ps1` | 卸载：删除计划任务、快捷方式、安装目录 |
| `settings.html` | 设置页前端 |
| `settings_server.ps1` | 设置页本地服务（只监听 127.0.0.1） |
| `打开设置.vbs` | 启动设置页 |
| `run_hidden.vbs` | 计划任务用的隐藏启动器 |
| `安装.cmd` | 一键安装入口 |
| `立即登录.cmd` | 手动登录入口 |

安装后还会生成（不会提交到仓库）：

- `settings.ini`：账号和运营商
- `cred.xml`：DPAPI 加密的密码
- `autologin.log`：运行日志

## 配置

推荐用设置页修改。也可以手动编辑：

```
%LOCALAPPDATA%\CampusAutoLogin\settings.ini
```

```ini
Account=你的学号
Suffix=@cmcc      # 中国移动；电信 @njxy；校园网留空
```

保存后下次登录生效。

## 日志

```
%LOCALAPPDATA%\CampusAutoLogin\autologin.log
```

常见日志：

- `已在线（10.x.x.x，账号 xxx@cmcc），无需登录。`：正常
- `检测到未在线，正在登录...`：正在认证
- `登录返回：认证出现异常`：多数是账号已经在别的设备在线，脚本会再查一次在线状态
- `无法连接校园网认证网关`：当前不在校园网，或代理/VPN 拦截了内网请求

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

或直接删除计划任务：

```powershell
Unregister-ScheduledTask -TaskName "NJUPT-CampusAutoLogin" -Confirm:$false
```

## 安全说明

- 仓库里**不包含** `cred.xml`、`settings.ini` 和日志
- 密码用 Windows DPAPI 加密，换电脑或换 Windows 用户都无法解密
- 安装脚本和设置页都不保存明文密码；没有可用凭据时会提示输入
- 设置页的本地服务只监听 `127.0.0.1`，并使用随机会话令牌
- 脚本只访问 `p.njupt.edu.cn` 的认证接口

## 原理

南邮门户的认证流程大致是：

1. `GET /eportal/portal/page/loadConfig` 获取页面配置和一次性 `rcn`
2. `GET /eportal/portal/online_list` 查询当前 IP/MAC 是否在线
3. 未在线时 `GET /eportal/portal/login` 提交账号密码完成认证

脚本复刻了网页版的请求参数，包括 `user_account` 的 `,0,` 前缀、运营商后缀和 `rcn`，因此和浏览器手动登录等价。

## 代理 / VPN 提示

脚本已经显式禁用系统代理，但如果你使用 Clash 等工具的 **TUN 模式**，仍可能接管校园网流量。建议把以下地址设为直连：

- `p.njupt.edu.cn`
- `10.0.0.0/8`

## 免责声明

本项目仅供学习交流，使用前请自行评估风险。请遵守学校网络使用规定，不要用于违规用途。

## License

MIT
