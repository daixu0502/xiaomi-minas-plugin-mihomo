# 小米智能存储 Mihomo 插件

在小米智能存储 APP 内管理 Mihomo，当前插件版本为 `1.7.0`。

## 功能

- 启动、停止和重启 Mihomo 核心
- 导入及更新 Clash 订阅、单条节点和规则提供者
- 选择策略组节点，切换 Rule、Global、Direct 模式
- 更新 Mihomo ARM64 核心、GeoIP 和 GeoSite
- 编辑并校验 `config.yaml`，失败时自动回滚
- 切换仅本机访问或开放局域网访问
- 一键为 Docker 守护进程启用或关闭代理
- 查看运行日志、核心版本和端口状态
- 支持 Android、iOS 安全区和小米风格网页交互

## 多用户端口

每位插件用户会自动获得独立端口：

- 混合代理：`7890-7989`
- External Controller：`9090-9189`

端口保存在各用户的 `plugin/mihomo/etc/ports.env` 中，升级后保持不变。多个普通代理实例可以同时运行；TUN 会修改设备全局路由，同一时间只应由一个用户启用。Docker 守护进程也是全局服务，同一时间只能使用一个用户的 Mihomo 代理。

## 安装

从电脑的 WSL/Linux 运行：

```sh
cd mihomo-plugin
bash deploy.sh
```

安装器会提示输入设备 IP，并扫描设备用户。也可以直接指定：

```sh
bash deploy.sh 192.168.31.100 u123456789
```

在小米智能存储 root SSH 终端内运行：

```sh
cd /home/rootx/mihomo-plugin
bash deploy.sh u123456789
```

安装器从 MetaCubeX 官方 Release 获取 ARM64 核心并校验 SHA-256。`.cache` 保存已验证的下载文件，重复安装时可以避免再次下载。

## 重要文件

```text
/home/u123456789/plugin/mihomo/etc/config.yaml
/home/u123456789/plugin/mihomo/etc/api.secret
/home/u123456789/plugin/mihomo/etc/ports.env
/home/u123456789/plugin/mihomo/var/mihomo.log
```

重装会保留配置、API 密钥、订阅信息和已分配端口。APP 内更新过的较新核心也不会被安装包降级。

## 卸载

```sh
bash uninstall.sh
```

也可以指定设备与用户：

```sh
bash uninstall.sh 192.168.31.100 u123456789
```

设备本机运行时可使用：

```sh
bash uninstall.sh u123456789
```

卸载只移除所选用户的插件、进程、授权和开机任务。配置、订阅、节点与 API 密钥会保存在：

```text
/home/u123456789/plugin/.reserve/mihomo
```

第三方核心许可见 `THIRD_PARTY_NOTICES.md`。
