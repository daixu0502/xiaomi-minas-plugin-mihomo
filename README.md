# 小米智能存储 Mihomo APP 插件

这是为小米智能存储本地插件中心制作的 Mihomo 管理插件。安装后会在手机 APP 的插件列表中显示 **Mihomo**，提供：

- 核心运行状态、版本、端口和局域网开放状态
- 核心启动、停止和重启
- Mihomo 官方 ARM64 内核检查、SHA-256 校验更新和失败回滚
- 仅本机 / 开放局域网访问一键切换、配置校验与失败回滚
- Docker 守护进程代理的一键启用、关闭和状态检查
- Rule / Global / Direct 模式切换
- 策略组节点选择
- 单条节点分享链接或 Clash JSON 导入、更新和删除
- `proxy-providers` 手动更新
- HTTPS Clash 订阅 URL 导入和后续一键更新
- 当前订阅全部节点名称、类型和可用状态展示
- HTTPS URL 导入 `rule-providers`，可选规则行为、格式、匹配动作和下载通道
- `rule-providers` 单个或全部更新
- GeoIP / GeoSite 官方数据更新、SHA-256 校验和三种规则策略预设
- `config.yaml` 在线编辑、核心校验、失败回滚和重启
- 最近 200 行运行日志
- 插件中心启动、网络热插拔启动和 Cron 开机兜底
- 重装或重启时识别并清理遗留的重复 Mihomo 进程
- iOS / Android 安全区和沉浸式状态栏适配，页面支持左右滑动切换

## 安全默认值

- Mihomo 混合代理只监听 `127.0.0.1:7890`
- External Controller 强制监听 `127.0.0.1:9090`
- Controller 使用安装时随机生成的 256 位密钥
- 手机页面不会获得 Controller 密钥；请求由小米已认证的插件 CGI 转发
- 默认不开 TUN，不改系统路由，不接管 NAS 流量

如果需要给局域网设备或 Docker 容器使用，请明确修改 `allow-lan` 和 `bind-address`，并同时评估局域网访问控制。仅把 `allow-lan` 改为 `true` 但仍绑定 `127.0.0.1` 不会对外开放。

## 安装

前提：

1. 已运行此前的 SSH 开启与开机修复脚本。
2. `ssh root@设备IP` 可以免密码密钥登录。
3. 在 WSL/Linux 中有 `ssh`、`scp`、`curl` 或 `wget`、`tar`、`gzip`、`sha256sum`。

在本目录运行：

```sh
cd mihomo-plugin
bash deploy.sh
```

从电脑远程运行且没有提供 IP 时，安装器会先提示输入小米智能存储 IP。未指定插件用户时，安装器会扫描设备上的 `u数字` 用户：只有一个时自动选择，存在多个时在终端显示序号供选择。远程安装和设备本机安装均支持此流程。

也可以把整个 `mihomo-plugin` 目录复制到小米智能存储，然后在设备的 root SSH 终端内直接运行同一条命令。脚本会识别本机环境并直接安装，不会再 SSH 连接自己。

脚本不包含默认设备 IP。也可以在命令中显式指定设备与插件用户，跳过对应的输入和扫描选择：

```sh
bash deploy.sh 192.168.31.100 u123456789
```

部署脚本会从 Mihomo 官方 GitHub Release 下载 ARM64 核心并校验固定 SHA-256，再上传到设备。不会重启设备。

如果 GitHub 下载较慢，也可以自行把下面的原始 `.gz` 文件放到 `mihomo-plugin/.cache/`。脚本仍会先校验 SHA-256，校验不符时不会安装。

当前固定版本：

- Mihomo `v1.19.31`
- 文件 `mihomo-linux-arm64-v1.19.31.gz`
- SHA-256 `9e0f11afbf38426b8bd88fdc594678f8161c57eccb4e1b77acb12b493904f1d4`

安装完成后刷新小米智能存储 APP 的插件列表。若页面仍未出现，可完全退出 APP 后重新打开。

## 配置

首次启动使用安全的直连配置。打开 APP → Mihomo → 配置，将自己的 Mihomo/Clash Meta YAML 粘贴进去，点击“校验并保存”。

也可以在“订阅”页面输入 HTTPS Clash 订阅 URL。插件会只提取订阅中的节点，生成本地 `APP-SUBSCRIPTION` 提供者和 `PROXY` 策略组；原配置首次导入时备份为 `config.before-subscription.yaml`。完整 URL 保存在权限为 `0600` 的 `subscription.url`，APP 只显示来源域名。

“订阅”页面还可以导入单条 `ss://`、`vmess://`、`vless://`、`trojan://`、`hysteria2://`/`hy2://`、`tuic://` 分享链接，或单个 Clash JSON 节点。手动节点保存在本地 `APP-MANUAL` provider 中，并出现在 `PROXY` 策略组供直接选择。节点名称相同时再次导入会更新原节点。

单节点导入和删除位于“订阅”页面。该页面还会显示当前订阅返回的全部节点；规则提供者 URL 导入会写入 `rule-providers`，并在最终 `MATCH` 规则前增加对应的 `RULE-SET`。

同一页面可从 `MetaCubeX/meta-rules-dat` 更新 `GeoIP.dat` 与 `GeoSite.dat`。请求只通过本机 `127.0.0.1:7890` 代理访问 GitHub 官方仓库，不使用第三方镜像；两个文件都必须通过 GitHub Release 的 SHA-256 校验才会替换旧文件。可选规则策略为：

- 国内及局域网直连，其他流量走 `PROXY`
- 仅局域网直连，其他流量走 `PROXY`
- 全部直连

应用策略会把运行模式写为 `rule`，启用 `geodata-mode` 和 `memconservative` 加载器，并替换顶层 `rules` 段。原配置首次应用时另存为 `config.before-geodata-policy.yaml`；校验或重启失败时自动恢复。

“概览”页面可检查 MetaCubeX 官方最新稳定版内核并一键更新。更新器仅接受官方 ARM64 Release 地址和 GitHub 提供的 SHA-256，替换前还会检查架构、版本并用当前配置测试；若新内核启动失败会恢复旧内核。

“概览”页面可以为 `docker.service` 一键设置 `http://127.0.0.1:7890` 代理，用于镜像拉取和构建。启用或关闭时会重启 Docker；这不会自动设置容器内部的代理环境变量。插件只授予 CGI 用户调用专用助手的 `status`、`enable`、`disable` 三个固定动作，卸载时会先移除 Docker 代理，再删除对应的 sudoers 规则和助手。

“概览”页面还可在“仅本机访问”和“开放局域网”之间切换。开放局域网会把混合代理绑定到 `0.0.0.0:7890`，不会开放 External Controller；请只在可信局域网使用。

安装器会保留已存在的：

- `/home/u123456789/plugin/mihomo/etc/config.yaml`
- `/home/u123456789/plugin/mihomo/etc/api.secret`

因此再次运行 `deploy.sh` 可用于修复或升级插件外壳，不会覆盖现有配置。
如果此前已在 APP 内把 Mihomo 内核更新到比安装包更高的版本，安装器也会保留较新的内核，避免降级。

## 验证

```sh
ssh root@设备IP 'plugincenter -u u123456789 -p mihomo info'
ssh root@设备IP 'PLUG_USER=u123456789 PLUG_HOME_DIR=/home/u123456789/plugin/mihomo PLUG_SRC_DIR=/nas/pool0/u123456789/plugin/pluginsrc/mihomo /home/u123456789/plugin/mihomo/scripts/control status'
ssh root@设备IP 'tail -n 100 /home/u123456789/plugin/mihomo/var/mihomo.log'
```

## 卸载

```sh
bash uninstall.sh
```

从电脑远程运行且没有提供 IP 时，卸载器会先提示输入小米智能存储 IP。未指定插件用户时，卸载器只扫描已经安装 Mihomo 的用户；多个结果会让你选择删除哪一个。也可以显式运行 `bash uninstall.sh 192.168.31.100 u123456789`。

`uninstall.sh` 同样支持在小米智能存储的 root SSH 终端内直接运行；检测到本机环境后不会 SSH 连接自己。

卸载会停止 Mihomo，移除 APP 清单条目、开机任务、图标、UI、程序文件及新增的节点管理脚本。配置、订阅信息、手动节点与 API 密钥会备份到：

```text
/home/u123456789/plugin/.reserve/mihomo
```

## 与官方插件的关系

本项目只复用了设备公开可见的本地插件目录、`control` 生命周期和 APP `frontend` 配置协议。没有复制迅雷、百度网盘的二进制、前端代码、数据库、令牌或其他私有内容。

项目下载的 Mihomo 核心来自 MetaCubeX/mihomo，遵循 MIT License。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
