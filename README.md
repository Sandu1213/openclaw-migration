# OpenClaw Migration Helper v2

面向 **OpenClaw 新版本** 的迁移辅助脚本。

脚本文件：
- `migrate-openclaw.sh`

这份 v2 的核心原则很简单：

- **导出与备份校验，完全依赖官方 `openclaw backup` 流程**
- **脚本自身负责导入编排、回滚保护、迁移后验证**
- **不再 repack 官方备份包，不再假设自定义 archive 结构**

---

## 为什么要有 v2？

旧版增强脚本的思路是：

1. 调用官方 `openclaw backup create`
2. 解包
3. 往里面再补 `agents/`、`plugin-manifest.txt` 等额外内容
4. 重新打包

这个思路在较新的 OpenClaw 版本里风险越来越高，原因是：

- 官方 backup 的 archive 结构已经演进
- `~/.openclaw` 本身已经被官方 backup 覆盖
- 二次 repack 很容易把内容塞到错误路径
- 自定义补丁层会增加“包能生成，但恢复结构不一致”的隐患

所以 v2 改成：

- **export：官方 backup 原样输出**
- **import：只负责恢复官方包中的 `.openclaw` 内容**
- **verify：重点检查迁移后的运行状态**

一句话：**少做聪明事，尽量站在官方机制上。**

---

## 功能概览

支持的命令：

- `export`
- `export-lite`
- `import`
- `verify`
- `backup-verify`
- `snapshot-manifest`

---

## 命令说明

## 1) export

通过官方 `openclaw backup create` 创建备份包。

### 用法

```bash
bash openclaw-migration/migrate-openclaw.sh export
```

或指定输出路径：

```bash
bash openclaw-migration/migrate-openclaw.sh export ./my-backup.tar.gz
```

### 可选参数

- `--no-include-workspace`
  - 透传给官方 backup，排除 workspace
- `--only-config`
  - 只备份配置文件
- `--skip-verify`
  - 导出后不自动执行官方 `backup verify`

### 示例

```bash
bash openclaw-migration/migrate-openclaw.sh export
bash openclaw-migration/migrate-openclaw.sh export ./backup.tar.gz --skip-verify
bash openclaw-migration/migrate-openclaw.sh export ./backup.tar.gz --no-include-workspace
bash openclaw-migration/migrate-openclaw.sh export ./config-only.tar.gz --only-config
```

---

## 2) export-lite

创建一份**更适合日常迁移 / 留档**的轻量备份包。

和 `export` 不同，`export-lite` 不走官方整包 backup，而是直接对 `~/.openclaw` 做精简打包，默认排除那些通常可再生成、但非常占空间的内容。

### 用法

```bash
bash openclaw-migration/migrate-openclaw.sh export-lite
```

或指定输出路径：

```bash
bash openclaw-migration/migrate-openclaw.sh export-lite ./openclaw-backup-lite.tar.gz
```

### 默认排除项

- `~/.openclaw/browser`
- `~/.openclaw/logs`
- `~/.openclaw/media`
- `~/.openclaw/workspace/.venv-scrapling`
- `~/.openclaw/workspace/tmp`
- `~/.openclaw/workspace/runs`
- `~/.openclaw/workspace/downloads`
- `~/.openclaw/workspace/.git`
- `~/.openclaw/extensions/*/node_modules`
- `~/.openclaw/extensions/*/.turbo`
- `~/.openclaw/extensions/*/dist`
- `~/.openclaw/extensions/*/coverage`
- `~/.openclaw/extensions/.openclaw-install-backups`

### 适合什么场景

适合：

- 想保留主要配置、workspace 文本内容、扩展源码骨架
- 想明显减小备份体积
- 接受迁移后对部分依赖 / 缓存重新生成

不适合：

- 你希望目标机尽量“一拷贝就和原机一模一样”
- 你不想重新安装扩展依赖
- 你明确要保留浏览器缓存、媒体、运行时产物

### 和 `export` 的区别

- `export`：更接近**完整状态快照**，适合灾备 / 保守迁移
- `export-lite`：更接近**精简迁移包**，适合日常备份 / 快速迁移

---

## 3) import

从备份包中恢复 `~/.openclaw`。

### 用法

```bash
bash openclaw-migration/migrate-openclaw.sh import <archive_path>
```

如果目标机上已经有现成的 `~/.openclaw`，可以加：

```bash
bash openclaw-migration/migrate-openclaw.sh import <archive_path> --overwrite
```

### 行为说明

导入时会执行这些动作：

1. 先跑官方 `openclaw backup verify`
2. 停掉 gateway
3. 解压备份包
4. 自动定位官方 backup 里的 `.openclaw` 根目录
5. 若指定 `--overwrite`，会把旧的 `~/.openclaw` 挪到：
   - `~/.openclaw.pre-import-时间戳`
6. 拷贝恢复后的 `.openclaw`
7. 跑一次 `openclaw config validate`
8. 尝试启动 gateway

### 注意

- **不加 `--overwrite` 时，如果目标机已有 `~/.openclaw`，脚本会直接退出**
- `--overwrite` 不是直接删旧目录，而是**搬走留档，便于回滚**

---

## 4) verify

这是 v2 里最有价值的部分之一：它不是只验证“包有没有坏”，而是检查**迁移后的 OpenClaw 能不能正常工作**。

### 用法

```bash
bash openclaw-migration/migrate-openclaw.sh verify
```

也可以在 verify 之前顺手校验某个 archive：

```bash
bash openclaw-migration/migrate-openclaw.sh verify ./backup.tar.gz
```

### 默认检查项

- `openclaw --version`
- `openclaw status`
- `openclaw config validate`
- `openclaw channels status --probe`
- `openclaw cron list`
- `openclaw skills check`
- `openclaw plugins list`
- plugin layout 检查
- workspace 基本结构检查

### verify 的定位

请把它理解为：

- **archive integrity**：由 `backup verify` 负责
- **runtime health**：由 `verify` 负责

两者不是一回事。

---

## 5) backup-verify

纯官方包校验。

### 用法

```bash
bash openclaw-migration/migrate-openclaw.sh backup-verify ./backup.tar.gz
```

适合：

- 只想确认包结构和 manifest 没问题
- 还没准备导入
- 想在源机和目标机都跑一次校验

---

## 6) snapshot-manifest

生成当前本机 OpenClaw 状态的轻量快照，便于迁移前后比对。

### 用法

```bash
bash openclaw-migration/migrate-openclaw.sh snapshot-manifest
```

也可以指定输出文件：

```bash
bash openclaw-migration/migrate-openclaw.sh snapshot-manifest ./before-migration.txt
```

### 快照包含什么

- 当前 `openclaw --version`
- `~/.openclaw` 顶层目录结构
- `openclaw.json` 中的 `plugins.entries`
- `extensions/` 下已有扩展目录

### 适合的使用时机

- 源机导出前：记录一份
- 目标机导入后：再记录一份
- 对比是否少了插件、目录、关键状态

---

## 推荐迁移流程

下面是我更推荐的 v2 使用顺序。

## 阶段 A：源机导出

### 1. 先做状态快照

```bash
bash openclaw-migration/migrate-openclaw.sh snapshot-manifest ./source-before.txt
```

### 2. 导出备份

完整备份：

```bash
bash openclaw-migration/migrate-openclaw.sh export ./openclaw-backup.tar.gz
```

轻量备份：

```bash
bash openclaw-migration/migrate-openclaw.sh export-lite ./openclaw-backup-lite.tar.gz
```

### 3. 再手动确认一下包可读

```bash
bash openclaw-migration/migrate-openclaw.sh backup-verify ./openclaw-backup.tar.gz
```

---

## 阶段 B：目标机导入

### 1. 如有旧状态，先决定是否保留

如果目标机原本已有 OpenClaw 状态，推荐使用：

```bash
bash openclaw-migration/migrate-openclaw.sh import ./openclaw-backup.tar.gz --overwrite
```

这样旧目录不会被直接删掉，而是被挪到：

- `~/.openclaw.pre-import-时间戳`

### 2. 导入完成后跑验证

```bash
bash openclaw-migration/migrate-openclaw.sh verify ./openclaw-backup.tar.gz
```

### 3. 再输出一份目标机快照

```bash
bash openclaw-migration/migrate-openclaw.sh snapshot-manifest ./target-after.txt
```

---

## 阶段 C：人工抽检

脚本做完后，建议你再人工看以下几项：

- Discord / Feishu / DingTalk 等渠道是否正常
- cron 任务数量与旧机是否一致
- 关键 skills 是否 ready
- 外部路径是否仍然正确（例如 Obsidian 路径）
- 第三方插件是否存在版本兼容问题

---

## 推荐的最小命令集合

如果你只想记住最常用的一套，记这 4 条就够了：

```bash
# 源机
bash openclaw-migration/migrate-openclaw.sh export ./openclaw-backup.tar.gz

# 目标机
bash openclaw-migration/migrate-openclaw.sh import ./openclaw-backup.tar.gz --overwrite

# 迁移后验证
bash openclaw-migration/migrate-openclaw.sh verify ./openclaw-backup.tar.gz

# 迁移前后快照
bash openclaw-migration/migrate-openclaw.sh snapshot-manifest
```

---

## 设计取舍说明

## 为什么不再单独补 `agents/`？

因为新版官方 backup 已经覆盖整个 `~/.openclaw`，继续手工补一层：

- 价值下降
- 风险上升

尤其当官方 archive 内部目录结构调整后，手工补丁最容易把内容塞错地方。

---

## 为什么还要保留自定义 import？

因为官方 backup 负责的是：

- 生成包
- 校验包

但迁移时你通常还想要：

- 导入前停 gateway
- `--overwrite` 但保留回滚目录
- 导入后自动 `config validate`
- 自动启动 gateway
- 迁移后做一组运行态检查

这部分脚本化依然很有价值。

---

## 为什么要有 `verify` 而不是只靠 `backup verify`？

因为：

- `backup verify` 只能说明**包结构没坏**
- 不能说明**你的渠道、插件、cron、skills 都能跑**

而实际迁移最容易踩坑的，偏偏是运行态问题。

---

## 常见注意事项

## 1. `verify` 失败，不一定是迁移包坏了

有时是这些原因：

- 插件版本和当前 OpenClaw CLI 不兼容
- 某个 channel token 过期
- 目标机缺少系统依赖
- 某些路径在新机器上不存在

所以要区分：

- **archive 问题** → 看 `backup-verify`
- **运行态问题** → 看 `verify`

---

## 2. 目标机不要双机同时跑 cron

迁移切换时，要注意不要让旧机和新机同时发：

- RSS
- 提醒
- 机器人消息

建议：

- 新机验证通过后，再正式切流
- 切流后停掉旧机相关服务

---

## 3. 外部依赖不属于 backup 范围

OpenClaw backup 主要覆盖的是状态目录，不等于系统层全量迁移。

你仍然要自己确认：

- Node / npm
- Python / pip 依赖
- ffmpeg / yt-dlp
- Homebrew 安装项
- launchd / service 状态

---

## 4. workspace 路径没问题，不代表外部绝对路径没问题

比如你的脚本里如果写死了：

- Obsidian 路径
- 下载目录
- 本地磁盘挂载路径

这些迁移后都要单独复查。

---

## FAQ

## Q1. 我还需要旧版那种 plugin manifest 吗？

通常不需要作为 backup 包的一部分强塞进去。

如果你喜欢保留对照信息，用：

```bash
bash openclaw-migration/migrate-openclaw.sh snapshot-manifest
```

更安全，也更清晰。

---

## Q2. 这个脚本会不会删除我旧的 `~/.openclaw`？

默认不会。

只有你显式传入 `--overwrite` 时，它才会把旧目录搬走；而且是改名保留，不是直接删掉。

---

## Q3. 为什么 export 会把官方输出文件再 rename？

因为官方 backup 常按时间戳自动命名。

这个脚本允许你指定目标文件名；如果指定了，就会在官方生成后改成你想要的路径，便于统一管理。

---

## Q4. 我可以只用官方 `openclaw backup create/verify`，完全不用这个脚本吗？

可以。

如果你只需要：

- 生成备份
- 校验备份

那官方命令就够了。

这份脚本的意义主要在于：

- 导入编排
- 覆盖时保留回滚
- 迁移后验证
- 快照对比

---

## 建议

如果是新机器迁移，我建议至少做这三件事：

1. `export`
2. `import --overwrite`
3. `verify`

如果你想更稳，再加上迁移前后的：

4. `snapshot-manifest`

---

## 源机 / 目标机操作速查卡

下面这版是偏实战的“照抄就能跑”版本。

## 源机（旧机器）

### 1. 进入工作目录

```bash
cd /Users/ips/.openclaw/workspace
```

### 2. 先记录当前状态

```bash
bash openclaw-migration/migrate-openclaw.sh snapshot-manifest ./source-before.txt
```

### 3. 导出备份

```bash
bash openclaw-migration/migrate-openclaw.sh export ./openclaw-backup.tar.gz
```

### 4. 再校验一次备份包

```bash
bash openclaw-migration/migrate-openclaw.sh backup-verify ./openclaw-backup.tar.gz
```

### 5. 把这些文件带到目标机

至少带走：

- `openclaw-backup.tar.gz`
- `openclaw-migration/migrate-openclaw.sh`
- `openclaw-migration/README.md`
- `source-before.txt`（可选，但推荐）

---

## 目标机（新机器）

### 1. 进入工作目录

```bash
cd /Users/ips/.openclaw/workspace
```

### 2. 如果目标机已有旧状态，先决定是否覆盖

如果你确认要用源机状态覆盖当前机器：

```bash
bash openclaw-migration/migrate-openclaw.sh import ./openclaw-backup.tar.gz --overwrite
```

如果目标机还没有 `~/.openclaw`，则可直接：

```bash
bash openclaw-migration/migrate-openclaw.sh import ./openclaw-backup.tar.gz
```

### 3. 导入后立即做验证

```bash
bash openclaw-migration/migrate-openclaw.sh verify ./openclaw-backup.tar.gz
```

### 4. 记录目标机迁移后的状态

```bash
bash openclaw-migration/migrate-openclaw.sh snapshot-manifest ./target-after.txt
```

---

## 迁移后人工抽检速查

建议至少手动看这几项：

```bash
openclaw status
openclaw channels status --probe
openclaw cron list
openclaw skills check
openclaw plugins list
```

同时人工确认：

- Discord / Feishu / DingTalk 是否正常
- 关键 cron 是否还在
- Obsidian 等外部路径是否正确
- 第三方插件是否有版本兼容问题

---

## 最短执行版（只记这几条）

### 源机

```bash
cd /Users/ips/.openclaw/workspace
bash openclaw-migration/migrate-openclaw.sh export ./openclaw-backup.tar.gz
```

### 目标机

```bash
cd /Users/ips/.openclaw/workspace
bash openclaw-migration/migrate-openclaw.sh import ./openclaw-backup.tar.gz --overwrite
bash openclaw-migration/migrate-openclaw.sh verify ./openclaw-backup.tar.gz
```

---

## 一句话总结

**v2 不再尝试“增强官方备份包”，而是改为“信任官方备份包 + 强化迁移落地与验证”。**

这通常会比“自己重新打包一层”更稳，也更不容易随着 OpenClaw 版本升级而悄悄失效。
