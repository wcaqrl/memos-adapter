# Memos 懒猫应用适配器

本仓库为上游 [Memos](https://github.com/usememos/memos) 生成并提交懒猫微服官方应用 `cloud.lazycat.app.memos`。Memos 源代码和容器镜像由上游维护；本仓库保存兼容现有应用的数据挂载、LPK 配置、自动更新规则及提交状态。

## 自动更新流程

GitHub Actions 每天检查上游最高的稳定 `vX.Y.Z` 标签。发现新版后，先用当前商店基线 `0.26.2` 的真实 SQLite 数据目录进行升级测试；测试成功后，`lazycat-action` 固定 `linux/amd64` 镜像摘要、转存到懒猫官方仓库、更新 Manifest 和版本、构建并检查 LPK，然后使用本仓库的开发者 PAT 提交官方应用商店审核。

推送适配配置只执行 dry-run。正式更新可以在 **Actions → Update Memos for LazyCat → Run workflow** 中取消勾选 dry-run，或等待每日定时任务。

## 数据兼容约束

现有 `0.26.2` 应用将 `/lzcapp/var/db/memos` 绑定到容器 `/var/opt/memos`。此路径保存 SQLite 数据库及本地附件，后续版本不得改名，否则已有用户升级后会看到一个空实例。

Memos 启动时自动迁移数据库，迁移后的数据库不支持直接交给旧版本程序降级。升级前应备份整个 `/lzcapp/var/db/memos`；发生问题时应恢复备份后再运行旧镜像。

## GitHub 设置

在本仓库的 Actions secrets 中设置 `LZC_API_TOKEN`。开发者账号还必须是应用 `cloud.lazycat.app.memos` 的协作者。可选设置 `LZC_API_HOST`；未设置时使用生产应用商店地址。

仓库 Actions 权限需要允许写入 Contents。正式流程会提交更新后的 `package.yml`、`lzc-manifest.yml` 和 `.lazycat-action.lock.yml`，以便下次从已提交版本继续比较。

更新日志使用目标稳定标签对应的 GitHub Release 正文，不会把两个版本之间的全部 Git 提交直接作为审核日志。

## 本地检查

```bash
lazycat-action run --operation check --config lazycat-action.yml --dry-run
./scripts/test-upgrade.sh
lzc-cli project build
```
