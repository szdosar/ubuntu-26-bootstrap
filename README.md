# Ubuntu 26.04 桌面一键配置

这是为 `szdosar` 的 Ubuntu 26.04 LTS 桌面环境准备的可重复执行配置脚本。

## 完成的配置

- 安装微软 YaHei Regular、Bold、Light，并设为 GNOME 界面与文档字体。
- 保留 Ubuntu Sans Mono 作为等宽字体，保留 Noto Color Emoji。
- 安装 IBus Rime、固定版本的雾凇拼音，并保留 LibPinyin 作为备用。
- 安装并关联固定版本的 ONLYOFFICE Desktop Editors；不修改 PDF 默认程序。
- 安装 MPV，退出时保存播放位置，下次自动续播。
- 安装 GitHub CLI，设置 Git 提交身份，并完成 GitHub 浏览器授权。
- 安装 OpenSSH Server，启用 Ubuntu 的 SSH socket。

## 一键运行

在登录 Ubuntu GNOME 桌面后的普通用户终端中运行，不要在脚本前加 `sudo`：

```bash
git clone https://github.com/szdosar/ubuntu-26-bootstrap.git
cd ubuntu-26-bootstrap

./setup-ubuntu-26.04.sh --dry-run
./setup-ubuntu-26.04.sh
```

脚本会自行请求一次管理员权限。首次运行时，它会打开 GitHub 设备/浏览器登录，
随后从 `szdosar/private-font-assets` 的私有 Release 下载字体。用于登录的 GitHub
账号必须拥有该私有仓库的读取权限。

## 字体的离线模式

字体没有放在本公开仓库中。需要避免 GitHub 登录或离线安装时，可以准备以下文件：

```text
/path/to/YaHeiExport/msyh.ttc
/path/to/YaHeiExport/msyhbd.ttc
/path/to/YaHeiExport/msyhl.ttc
```

然后运行：

```bash
./setup-ubuntu-26.04.sh --font-dir /path/to/YaHeiExport --skip-gh-login
```

脚本会检查 TTC 文件签名和字体族，Windows WOF 占位文件不能通过检查。微软雅黑为
微软商业字体；私有字体仓库仅用于保存仓库所有者从其获许可的 Windows 系统导出的
个人副本，不应改为公开仓库或转发 Release 资源。

## 参数

```text
--font-dir PATH       使用本地字体目录，不从私有 GitHub Release 下载
--git-name NAME       设置全局 Git 作者名称
--git-email EMAIL     设置全局 Git 作者邮箱
--skip-fonts          跳过字体配置
--skip-rime           跳过 Rime 和雾凇拼音
--skip-onlyoffice     跳过 ONLYOFFICE
--skip-gh-login       不主动发起 GitHub 登录
--skip-ssh            跳过 OpenSSH Server
--dry-run             只检查环境和安装计划，不进行修改
```

`--skip-gh-login` 与私有字体下载同时使用时，系统必须已经登录 GitHub CLI；否则请
同时使用 `--font-dir`。

## 备份与安全

任何实际修改之前，脚本都会把相关配置和状态备份到：

```text
~/.local/state/ubuntu-system/backups/bootstrap-日期时间/
```

备份包括 GNOME 设置、输入法数据、MPV 配置、文件关联、Git 身份、SSH 配置和防火墙
状态。GitHub 令牌、SSH 私钥和 SSH 私有主机密钥不会进入备份。

下载的字体、雾凇拼音和 ONLYOFFICE 均校验固定 SHA-256。脚本拒绝覆盖来源不明的
Rime 目录，并可安全重复运行。UFW 原本未启用时，脚本不会擅自启用它；如果 UFW
已经启用，则会加入 OpenSSH 规则。

运行完成后建议注销再登录一次。确认 SSH 密钥登录正常后，可以再单独关闭 SSH
密码登录；此步骤没有自动执行，以免首次配置时把用户锁在设备外。

## 版本维护

ONLYOFFICE、雾凇拼音或私有字体 Release 更新时，应同时更新脚本中的版本号和
SHA-256，并先通过：

```bash
bash -n setup-ubuntu-26.04.sh
shellcheck setup-ubuntu-26.04.sh
./setup-ubuntu-26.04.sh --dry-run
```

## License

本仓库中的脚本和文档使用 MIT License。字体不包含在本仓库及该许可证中。
