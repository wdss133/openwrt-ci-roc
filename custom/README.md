# IPQ807X 定制编译说明

本目录是**定制配置区**，主线代码一个字都不用改。

## 目录约定

| 路径 | 说明 |
| --- | --- |
| `custom/packages.seed` | 定制软件包清单，加包/删包只改这个文件 |
| `scripts/custom/roc-customize.sh` | 定制执行脚本（拉第三方源、换主题、删 Aurora） |
| `.github/workflows/Custom-IPQ807X-Daily.yml` | 每天北京时间 21:00 自动同步上游 + 编译 IPQ807X |

## 每天自动做什么

1. `Sync-Upstream`：从 `laipeng668/openwrt-ci-roc`（上游主线）拉取最新代码合并进本仓库 master；
2. `Fetch Custom Overlay`：拉取 `custom-ipq807x` 分支上的 `custom/` 目录，覆盖默认清单；
3. `Build`：克隆 `laipeng668/openwrt-6.x@25.12-nss` → 跑主线 `Roc-script.sh` → 跑 `roc-customize.sh` → 编译 qualcommax/ipq807x；
4. `Release`：发布到 tag `IPQ807X-Custom`。

## 想加包 / 删包

编辑本分支的 `custom/packages.seed`，保存即可，下一次定时编译自动生效：

```
CONFIG_PACKAGE_xxx=y              # 选中
# CONFIG_PACKAGE_xxx is not set   # 取消
```

改完不用碰 `configs/General.config`，脚本会在 CI 里把 seed 合并进去（工作区副本，不提交，所以永远不会和上游冲突）。

## 当前定制内容

- 内核模块 `kmod-tun`（ZeroTier / EasyTier 依赖）
- 默认主题 `luci-theme-argon` + `luci-app-argon-config`，Aurora 主题及其配置插件已删除
- EasyTier（`easytier-noweb` + `luci-app-easytier`）
- ZeroTier（`zerotier` + `luci-app-zerotier`）
- ddns-go（`ddns-go` + `luci-app-ddns-go`）
- iStore（`luci-app-store`）

EasyTier 默认用 `noweb`（下载官方预编译二进制，几分钟完成）。要完整源码版：手动触发 workflow 时选 `easytier_variant=full`，或把 seed 里的 `easytier-noweb` 换成 `easytier`。

## 常见问题

- **编译报"缺失 xxx"警告**：多是上游改了包名或依赖不满足，编译不会中断，去 `.config` 里确认实际包名再改 seed。
- **上游同步冲突**：本仓库只在 master 上"新增"自有文件，理论上不会冲突；真冲突时 workflow 保留本仓库版本并给出 warning。
- **不需要其他平台的编译**：到 Settings → Actions 里把 `Trigger-All-Workflows` 等 workflow 禁用即可，不用删文件。
