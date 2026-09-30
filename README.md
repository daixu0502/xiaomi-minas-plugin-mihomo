# 小米智能存储 Mihomo 插件

在手机 APP 和电脑客户端中管理 Mihomo 代理。当前插件版本：`1.7.20`。

## 本版界面更新

统一六插件的页头位置、状态卡片、统计信息顺序、圆角、间距和刷新按钮。电脑客户端随窗口使用全部可用宽度，手机页头显示当前插件名称，浅色使用雾灰背景，手机深色使用中性炭灰。样式限定在插件内部，不修改客户端全局字体；保留原有配置和功能。

## 功能

- 启动、停止和重启核心，切换运行模式及策略节点。
- 导入、更新订阅、单条节点和规则提供者。
- 更新 Mihomo 核心、GeoIP、GeoSite，编辑并校验配置。
- 切换本机或局域网访问，为 Docker 守护进程设置代理。

## 安装包结构

每个插件目录可单独复制和使用，只需要一个操作入口：

- `manage.sh`：包含环境识别、用户选择、安装、卸载、传输和清理逻辑。
- `payload/`：安装所需的网页、服务、图标及权限助手。
- `README.md`：使用说明；Mihomo 另附第三方许可说明。

旧的 `deploy.sh`、`uninstall.sh`、`remote-*.sh` 及公共辅助脚本已合并到 `manage.sh`。需要在 NAS 上执行的内部脚本由它临时生成，用完自动清理，不需要另外下载或保留多个入口脚本。

首次使用可以直接打开菜单：

```bash
bash manage.sh
```

菜单中选择“安装 / 更新”或“卸载”。命令行和自动化则明确指定 `install` 或 `uninstall`。

## 运行环境

- **NAS 本机**：自动识别小米插件配置和 `plugincenter`，使用 root 直接执行，无需填写 IP。
- **WSL / Linux**：自动通过 root SSH 连接设备；未填写 IP 时交互询问。支持密钥或交互式密码认证。
- NAS 存储池必须已经正常挂载，目标用户已在小米客户端初始化。
- 非交互运行需要可用的 SSH 密钥；扫描到多个用户时必须明确选择。
- 源码中不保存真实设备地址、账户或订阅信息。下面 IP 和用户 ID 均为示例。

## 安装与更新

在插件目录内运行：

```bash
bash manage.sh install
```

统一执行五步：识别环境 → 扫描用户 → 显示计划并预检查 → 逐用户执行 → 汇总结果。

交互列表显示已安装/未安装状态，可以输入单个序号、逗号分隔的多个序号（如 `1,3`）或 `all`。只有一个用户时自动选择。

WSL / Linux 指定 NAS 和多个用户：

```bash
bash manage.sh install --ip 192.168.31.100 --users u123456789,u987654321
```

NAS 本机指定多个用户：

```bash
bash manage.sh install --users u123456789,u987654321
```

安装给全部符合条件的用户：

```bash
# WSL / Linux
bash manage.sh install --ip 192.168.31.100 --all-users
# NAS 本机
bash manage.sh install --all-users
```

兼容原来的位置参数：

```bash
bash manage.sh install 192.168.31.100 u123456789
# NAS 本机
bash manage.sh install u123456789
```

重复安装保留现有配置，并更新插件文件。批量执行中某个用户失败时，继续处理后续用户；最后显示成功和失败列表，有失败时返回非零退出码。已成功用户不自动回滚；请解决错误后只重试失败用户。

## 卸载

```bash
bash manage.sh uninstall
```

卸载列表只显示已安装该插件的用户，同样支持单选、多选和全部选择。执行前会显示范围并要求输入 `yes`。

```bash
# WSL / Linux，卸载所选用户
bash manage.sh uninstall --ip 192.168.31.100 --users u123456789,u987654321
# NAS 本机，卸载全部已安装用户
bash manage.sh uninstall --all-users
```

自动化卸载必须明确使用 `--yes`：

```bash
bash manage.sh uninstall --ip 192.168.31.100 --users u123456789 --yes
```

卸载前先停止所选用户的插件，并将存在的 `etc/`、`var/`、`INFO` 和插件清单备份到：

```text
/home/<用户>/plugin/.reserve/mihomo/<时间>-<进程号>/
```

备份不会自动恢复。重新安装后，如需恢复配置，应先停止插件并按需恢复相关数据；备份可能含密钥，请妥善保管。

卸载会停止该用户的代理；若 Docker 正使用此代理，会撤销它并重启 Docker。其他用户插件和普通文件保留。其他用户仍在使用时，共享图标和权限助手会保留。

## 只查看，不执行

```bash
# 扫描用户；NAS 本机运行时省略 --ip
bash manage.sh install --ip 192.168.31.100 --list-users
bash manage.sh uninstall --ip 192.168.31.100 --list-users

# 核对计划及用户存储池，不下载、不安装、不卸载
bash manage.sh install --ip 192.168.31.100 --all-users --dry-run
bash manage.sh uninstall --ip 192.168.31.100 --all-users --dry-run

bash manage.sh install --help
bash manage.sh uninstall --help
```

## 本插件说明

每位用户分别分配混合代理端口 `7890–7989` 和控制端口 `9090–9189`，端口保存在 `etc/ports.env`，重装优先沿用。TUN 和 Docker 守护进程代理影响整台设备，不能由多个用户同时接管。

安装器下载 MetaCubeX 官方 `v1.19.31` ARM64 核心并校验 SHA-256。同批安装只下载一次，已在 APP 中升级的较新核心会保留。`.cache/` 可删除，下次安装会重新下载。

运行配置位于 `/home/<用户>/plugin/mihomo/etc/`；日志位于 `var/mihomo.log`。第三方核心许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 常见问题

- **SSH 连接失败**：先确认能执行 `ssh root@设备IP`。非交互环境不会等待密码输入；连接失败会明确报错，不会被当成“没有用户”。
- **存储池未挂载**：先在客户端确认硬盘和存储池恢复正常，再重试。脚本不会在未挂载的空目录里安装。
- **找不到用户**：先在小米客户端初始化该用户，再用 `--list-users` 检查；用户必须存在于扫描列表。
- **NAS 本机提示需要 root**：切换到 root 后运行。不要在本机命令里传设备 IP。
- **缺少文件或命令**：使用完整安装包，并根据错误安装或恢复必要依赖。
- **安装后仍显示旧页面**：完全关闭并重新打开手机 APP 或电脑客户端中的插件。
- **批量操作部分失败**：依据最后的结果列表重试失败用户；错误前可能已写入该用户的部分文件，请保留日志。
- **暂存清理失败**：脚本会显示 NAS 上的具体暂存路径；确认没有安装任务使用它后再手动清理。

安装包不包含设备运行配置、订阅凭据、私有账户、日志或安装备份。自动生成的 `.cache/`、`__pycache__/`、临时压缩包和 `*.tmp` 不需要随安装包分发。
