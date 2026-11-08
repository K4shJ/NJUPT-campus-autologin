# 校园网自动登录（通用 Dr.COM）

Windows 校园网自动登录脚本，支持两类常见的 Dr.COM 认证门户：

| 门户类型 | 认证接口 | 典型场景 |
| --- | --- | --- |
| 南邮新版 | `GET /eportal/portal/login`（JSONP） | 南京邮电大学 `p.njupt.edu.cn` |
| 通用 Dr.COM | `POST /InterFace.do?method=login` | 湖北工业大学 `http://1.1.1.1/` 等旧版门户 |

两类门户虽然都是 Dr.COM，但接口、参数、密码加密方式不同。本项目内置两套适配器，可自动识别，也可以在设置页手动指定。

## 功能

- **开机自动登录**：登录 Windows 后 15 秒检查一次，未在线就自动认证
- **只运行一次**：不做定时轮询，不会在游戏过程中反复弹窗
- **完全静默**：计划任务通过 `wscript` 隐藏启动，不闪命令行窗口
- **可视化设置页**：本地网页填写账号、密码、认证方式、认证页地址
- **双门户适配**：
  - 南邮新版：处理 `rcn`、`account_prefix`、运营商后缀
  - 通用 Dr.COM：解析门户页面、服务名、`passwordEncrypt` 和 RSA 公钥
- **密码加密保存**：Windows DPAPI，只有当前 Windows 用户能解密
- **失败兜底**：登录失败自动打开认证页
- **可卸载**：一条命令删除计划任务、快捷方式和安装目录

## 快速开始

### 1. 下载

```powershell
git clone https://github.com/K4shJ/NJUPT-campus-autologin.git
cd NJUPT-campus-autologin
```

或直接下载 ZIP 解压。

### 2. 安装

双击 `安装.cmd`，按提示输入学号和密码。

也可以在 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Account "你的学号" -Suffix "@cmcc"
```

安装脚本会：

1. 把脚本和设置页复制到 `%LOCALAPPDATA%\CampusAutoLogin`
2. 用 DPAPI 加密保存密码到 `cred.xml`
3. 注册计划任务 `NJUPT-CampusAutoLogin`（只在登录 Windows 时运行一次）
4. 创建桌面快捷方式
5. 立即运行一次并显示结果

> 任务名沿用 `NJUPT-CampusAutoLogin`，是为了兼容旧版本；其他学校也可以直接使用。

### 3. 打开设置页

双击桌面的 **“校园网设置”**，或运行：

```powershell
wscript.exe "$env:LOCALAPPDATA\CampusAutoLogin\打开设置.vbs"
```

设置页支持：

- 认证方式：自动识别 / 南邮 Dr.COM / 通用 Dr.COM
- 学号 / 账号
- 密码（留空表示不修改）
- 南邮运营商：校园网 / 中国移动 `@cmcc` / 中国电信 `@njxy`
- 通用 Dr.COM 认证页地址（默认 `http://1.1.1.1/`）
- 通用 Dr.COM 服务名（可留空）
- “保存并测试”：保存后立即执行一次登录并显示结果

设置页只监听 `127.0.0.1`，账号密码不会上传。

## 南邮怎么填

| 字段 | 值 |
| --- | --- |
| 认证方式 | 自动识别（或南邮 Dr.COM） |
| 账号 | 学号（不含后缀） |
| 密码 | 校园网密码 |
| 运营商 | 中国移动 `@cmcc`（按需选择） |

脚本会请求 `p.njupt.edu.cn`，自动处理 `rcn`、`account_prefix` 和运营商后缀。

## 湖北工业大学 / 通用 Dr.COM 怎么填

湖北工大认证页是 `http://1.1.1.1/`，登录页使用 `login_bch.js` / `AuthInterFace.js`，提交到 `/InterFace.do?method=login`。

| 字段 | 值 |
| --- | --- |
| 认证方式 | 通用 Dr.COM |
| 认证页地址 | `http://1.1.1.1/` |
| 账号 | 学号 |
| 密码 | 校园网密码 |
| 服务名 | 先留空；提示服务不对时再填门户下拉框里的名称 |

说明：

- 页面里如果 `passwordEncrypt=true`，脚本会读取 `publicKeyExponent` / `publicKeyModulus`，用 RSA 加密密码后再提交
- 如果学校门户不是 `1.1.1.1`，把浏览器打开认证页时地址栏里的地址填进去
- 如果门户有验证码、短信验证、二维码登录，本脚本无法自动完成

其他 Dr.COM 学校，优先试“自动识别”；失败后改成“通用 Dr.COM”并填认证页地址。

## 计划任务

| 项目 | 值 |
| --- | --- |
| 任务名 | `NJUPT-CampusAutoLogin` |
| 触发 | 登录 Windows 后 15 秒，**仅一次** |
| 运行方式 | `wscript.exe` 隐藏启动 PowerShell，不闪窗口 |
| 运行身份 | 当前用户，普通权限（不需要管理员） |
| 已在线时 | 约 1 秒退出 |
| 定时检查 | 无 |

网络中途断开后，双击“校园网立即登录”手动重连，或重新登录 Windows。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `campus_autologin.ps1` | 主脚本：识别门户、检测在线、提交认证 |
| `install.ps1` | 安装：复制文件、加密密码、注册计划任务 |
| `uninstall.ps1` | 卸载 |
| `settings.html` | 设置页前端 |
| `settings_server.ps1` | 设置页本地服务（只监听 127.0.0.1） |
| `打开设置.vbs` | 启动设置页 |
| `run_hidden.vbs` | 计划任务用的隐藏启动器 |
| `安装.cmd` | 一键安装入口 |
| `立即登录.cmd` | 手动登录入口 |

安装后生成（不会提交到仓库）：

- `settings.ini`：认证方式、账号、运营商、认证页地址
- `cred.xml`：DPAPI 加密的密码
- `autologin.log`：运行日志

## 配置

推荐用设置页修改。也可以手动编辑：

```
%LOCALAPPDATA%\CampusAutoLogin\settings.ini
```

```ini
Mode=auto                 # auto / njupt / drcom
PortalUrl=                # 通用 Dr.COM 认证页，留空默认 http://1.1.1.1/
Service=                  # 通用 Dr.COM 服务名，可留空
Account=你的学号
Suffix=@cmcc              # 南邮：移动 @cmcc / 电信 @njxy / 校园网留空
```

## 日志

```
%LOCALAPPDATA%\CampusAutoLogin\autologin.log
```

常见日志：

- `识别为南邮新版门户` / `识别为通用 Dr.COM 门户`：适配器选择
- `已在线，无需登录`：正常
- `登录返回：认证出现异常`：多数是账号已在别的设备在线
- `无法打开通用 Dr.COM 认证页`：不在该校园网，或地址填错
- `门户启用了密码加密，但页面里没有找到 RSA 公钥`：认证页结构变了
- `用户名或密码错误`：账号/密码不对，或服务名选错

## 原理

### 南邮新版

1. `GET /eportal/portal/page/loadConfig` 获取页面配置和一次性 `rcn`
2. `GET /eportal/portal/online_list` 查询当前 IP/MAC 是否在线
3. 未在线时 `GET /eportal/portal/login` 提交账号密码

### 通用 Dr.COM

1. 打开认证页，解析 `passwordEncrypt`、`publicKeyExponent`、`publicKeyModulus`、`prefixValue`、`net_access_type` 和 URL 里的 `queryString`
2. `POST /InterFace.do?method=pageInfo` 查询是否已在线
3. 未在线时 `POST /InterFace.do?method=login` 提交：
   `userId`、`password`、`service`、`queryString`、`passwordEncrypt`
4. 如果门户启用密码加密，按门户 JS 的算法做原始 RSA：
   反转 `密码>MAC`，按 `chunkSize = 2 * floor((bitLen-1)/16)` 分块，零填充，`ModPow`，输出十六进制

## 限制

- 只支持“账号 + 密码”登录；验证码、短信、二维码、CAS 单点登录不支持
- 通用适配器依赖认证页的字段结构；学校改版后可能需要更新
- 门户如果是 HTTP，密码是否加密取决于学校是否开启 `passwordEncrypt`
- 需要 Windows 10/11 + PowerShell 5.1；设置页需要 Chrome 或 Edge

## 安全说明

- 仓库里**不包含** `cred.xml`、`settings.ini` 和日志
- 密码用 Windows DPAPI 加密，换电脑或换 Windows 用户都无法解密
- 设置页的本地服务只监听 `127.0.0.1`，并使用随机会话令牌
- 脚本只访问配置的认证门户地址

## 免责声明

本项目仅供学习交流，使用前请自行评估风险。请遵守学校网络使用规定，不要用于违规用途。

## License

MIT
