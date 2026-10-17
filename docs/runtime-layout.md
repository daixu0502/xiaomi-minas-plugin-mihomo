# 插件缓存、安装包与部署整理（2026-10-17）

## 目录约定

源码来自本 Windows 工作区，不使用旧 WSL 副本。代码部署后重新生成 INFO 摘要和注册信息，并调用原厂 `plugin.sh verify`。

| 内容 | 位置 |
| --- | --- |
| Docker 空间统计、异步操作显示状态 | `dockermanager/tmp/cache/` |
| 控制中心磁盘扫描、服务、日志大小等显示缓存 | `nascenter/tmp/cache/` |
| 计划任务输出日志 | `taskcenter/tmp/cache/log-<记录ID>.json` |
| Mihomo PID、普通日志、更新任务/锁、下载校验暂存 | `mihomo/tmp/runtime/` |
| Docker Hub 出口探测结果 | `mihomo/tmp/cache/` |
| 文件快传 PID、服务日志 | `quickshare/tmp/runtime/` |
| 下载中心 PID、普通日志、版本探测、更新任务/锁、DHT 路由缓存 | `downloadcenter/tmp/runtime/` |
| qB 自带日志、GeoDB、Qt 缓存 | `downloadcenter/tmp/runtime/`，原 profile 的日志/GeoDB 使用链接 |

`<插件>/tmp` 是固件创建的链接，实际指向 `/nas/pool0/<用户>/plugin/plugintmp/<插件>/`。运行代码通过链接访问，不写死用户和存储池。先检查链接、挂载及所属用户，再创建子目录；空缓存可以重建，存储池不可用时不回退到源码目录。

共有组件 1.1.3 通过先降权的子进程读写用户缓存。缓存不用于授权、命令执行或可信路径。root 不沿用户可替换路径写文件。显示缓存不可用时尽量继续实时诊断；任务日志缓存失败不会把已执行任务误记为运行中。

## 必须保留的例外

- 配置、端口分配、secret、订阅与 Geo 策略、已更新内核保留 `etc/var`。
- 分享记录、下载数据库、BT 元数据、断点/会话、qB 配置与 `BT_backup` 必须持久保存，不能因官方缓存清空丢失。
- Mihomo 的 `cache.db` 同时保存节点选择等 profile 状态，并由原生核心的数据目录管理，保留其数据目录。
- qB 自身配置锁需要与 profile 配置相邻；分享记录锁需要稳定地保护持久记录，不能当独立缓存删除。
- root 代码、授权登记、调度命令/重试状态、跨插件事务锁和 Mihomo 系统代理锁保留受保护目录。代理锁从 `/run` 归入 `modules/mihomo/proxy.lock`，不是用户缓存。
- SSH 恢复公钥、主机密钥、临时生成的私钥下载包、恢复安全记录与独立开机恢复服务必须 root 保护，而且开机恢复不能依赖用户数据盘是否挂载。
- 上传文件、配置、内核等最终替换时，在目标目录短暂创建同文件系统暂存，避免跨磁盘 rename 失败或半写入；完整写入、fsync 后才替换。
- root 安装器的验证暂存和失败恢复材料不能放进用户可修改的缓存。成功的定向部署删除自己的 staging；失败不盲删恢复现场。

## 安装包与入口

- 五个提权插件仅含共有组件和自身 `common/modules/<插件>/`；不再带 `payload/system/` 重复代码。
- Docker Manager 合并为原厂要求的唯一 `ui/dockermanager.cgi`，电脑、手机和 `/dev/fd` 入口均检查。
- 不提权的下载中心、文件快传只带普通运行工具，不带公共权限组件。
- 安装入口复用同一缓存迁移逻辑；更新保留配置和内核，迁移遇到重复目标拒绝覆盖。
- Mihomo 卸载检查 JSON `.ok`；组件撤销成功前不移除插件登记。共有 remove 在最后一个用户引用移除时也清理 packages 版本登记。
- 删除通用卸载模板里与本插件无关的分支；仅保留本插件真正需要的旧版兼容清理。

## 本轮部署入口

1. `sync-plugin-runtime.py`、`sync-privileged-component.py`：同步普通工具、共有代码和摘要。
2. `build_plugin_packages.py`、本地回归：构建并核对七个安装包。
3. `prepare-privileged-deploy.py`：从明确 Git 基线和版本计划生成代码差异；包括新文件、删除文件，不打包内核和用户配置。
4. `run-runtime-deploy.py check`：上传 root 临时目录，校验传输摘要，检查源码、版本、挂载、空闲任务。
5. `run-runtime-deploy.py deploy`：持锁、停原本运行的三个插件服务、迁移缓存、替换代码/组件、恢复服务、原厂校验；失败恢复代码及迁移文件。
6. `run-runtime-deploy.py cleanup`：成功验收后删除本次精确临时目录。

`deploy-privileged-layout.py`、`deploy-privileged-state.py` 等旧版定向脚本仅为历史记录或支持函数来源，不能当成当前通用部署入口。

GitHub 分发只包含必要源码、安装器、许可和 Markdown；测试代码取消跟踪但保留本地，不重写历史。原有未跟踪的个人工具和文档资源不混入发布。
