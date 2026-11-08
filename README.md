# 南邮校园网开机自动登录

南京邮电大学校园网（Dr.COM 哆点认证）Windows 自动登录脚本。开机登录 Windows 后自动联网，不用再手动选择“校园网 / 中国移动 / 中国电信”。

> 适用于南邮 `p.njupt.edu.cn` 认证门户。其他学校如果也是 Dr.COM 门户，可以参考修改。

## 功能

- **开机自动登录**：登录 Windows 后 15 秒检查一次，未在线就自动认证
- **断线自动重连**：每 5 分钟检查一次，已在线时约 1 秒退出，几乎不占资源
- **运营商可选**：中国移动 `@cmcc`、中国电信 `@njxy`、校园网（无后缀）
- **密码加密保存**：使用 Windows DPAPI，只有当前 Windows 用户能解密
- **失败兜底**：登录失败会自动打开认证页，方便手动登录
- **无窗口运行**：计划任务在后台隐藏执行
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

如果需要中国电信，把 `@cmcc` 换成 `@njxy`；校园网则传空字符串：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Account "你的学号" -Suffix "@njxy"
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Account "你的学号" -Suffix ""
```

安装脚本会：

1. 把主脚本复制到 `%LOCALAPPDATA%\CampusAutoLogin`
2. 用 DPAPI 加密保存密码到 `cred.xml`
3. 注册计划任务 `NJUPT-CampusAutoLogin`
4. 立即运行一次并显示结果

### 3. 手动登录 / 查看状态

安装后桌面会出现 **“校园网立即登录”** 快捷方式，双击即可手动执行一次。

也可以直接运行：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusAutoLogin\campus_autologin.ps1"
```

## 计划任务

| 项目 | 值 |
| --- | --- |
| 任务名 | `NJUPT-CampusAutoLogin` |
| 触发 | 登录 Windows 后 15 秒；之后每 5 分钟 |
| 运行身份 | 当前用户，普通权限（不需要管理员） |
| 已在线时 | 约 1 秒退出 |
| 电池 | 允许在电池供电时运行 |

## 配置

安装后编辑：

```
%LOCALAPPDATA%\CampusAutoLogin\settings.ini
```

```ini
Account=你的学号
Suffix=@cmcc      # 中国移动；电信 @njxy；校园网留空
```

保存后下一次检查生效。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `campus_autologin.ps1` | 主脚本：检测在线状态、提交认证 |
| `install.ps1` | 安装：复制文件、加密密码、注册计划任务 |
| `uninstall.ps1` | 卸载：删除计划任务、快捷方式、安装目录 |
| `安装.cmd` | 一键安装入口 |
| `立即登录.cmd` | 手动登录入口 |
| `settings.ini` | 安装后生成，保存账号和运营商（不会提交到仓库） |
| `cred.xml` | 安装后生成，DPAPI 加密密码（不会提交到仓库） |

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
- 安装脚本不保存明文密码；没有可用凭据时会提示输入
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
