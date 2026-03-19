# OpenClaw 迁移指南（增强版）

本目录提供一套可重复执行的迁移方案，用于迁移以下内容：

- 官方 OpenClaw 备份归档（优先）
- skills（workspace 内的技能与脚本）
- 定时任务（cron）
- 存储记忆（`MEMORY.md`、`memory/` 及 memory 索引相关文件）
- 插件与主配置（`openclaw.json`、`extensions/` 等）
- 插件清单与完整性校验（`plugin-manifest.txt` + verify 阶段插件检查）
- 可选附加：`agents/` 会话历史

文件：

- `migrate-openclaw.sh`：迁移脚本（默认优先调用官方 `openclaw backup create`）

---

## 1) 设计原则

这版脚本的定位是：

- **备份创建**：优先用官方 `openclaw backup create`
- **迁移增强**：补充 `agents/`、插件清单、导入流程、迁移验收
- **迁移验收**：补做运行态检查（channels / cron / plugins / workspace / skills）

也就是说：

- 官方命令负责“**标准备份**”
- 本脚本负责“**迁移流程与验收**”

并且这一版额外做了 3 个 P1 加固：

1. **更稳地识别官方备份产物**：优先解析命令输出里的 archive 路径，不再只靠“目录里最新文件”猜测。
2. **导入先落临时目录**：先解压、识别 archive 结构，再复制到目标位置。
3. **覆盖导入可回滚**：`--overwrite` 不再直接删 `~/.openclaw`，而是先改名保留旧目录。

---

## 2) 快速开始

### 方式 A：推荐，默认官方备份流程

在源机器导出：

```bash
cd openclaw-migration
chmod +x migrate-openclaw.sh
./migrate-openclaw.sh export
```

导出并包含 `agents/`：

```bash
./migrate-openclaw.sh export ./openclaw-backup.tar.gz --include-agents
```

只备份配置：

```bash
./migrate-openclaw.sh export ./openclaw-config-only.tar.gz --only-config
```

不包含 workspace：

```bash
./migrate-openclaw.sh export ./openclaw-lite.tar.gz --no-include-workspace
```

校验已有备份：

```bash
./migrate-openclaw.sh backup-verify ./openclaw-backup.tar.gz
```

把导出的 `tar.gz` 复制到目标机器后导入：

```bash
cd openclaw-migration
chmod +x migrate-openclaw.sh
./migrate-openclaw.sh import ./openclaw-backup.tar.gz --overwrite
./migrate-openclaw.sh verify
```

### 方式 B：兼容旧流程，使用脚本内置旧导出器

```bash
./migrate-openclaw.sh export ./openclaw-backup.tar.gz --legacy-export --include-agents
```

仅当你明确要沿用旧的自定义打包逻辑时才建议用它。

---

## 3) 脚本做了什么

### export（默认）

- 调用官方：`openclaw backup create`
- 默认追加官方 `verify` 校验（可用 `--skip-verify` 关闭）
- 优先从官方命令输出中解析生成的 archive 路径
- 若无法直接解析，只在“候选文件唯一”时才回退使用目录扫描；若有多个候选则直接报错，避免误判
- 若指定 `--include-agents`：
  - 在官方备份基础上补充 `agents/`
  - 写入 `plugin-manifest.txt`
  - 再做一次官方 `backup verify`
- 支持透传官方常用意图：
  - `--only-config`
  - `--no-include-workspace`

### export --legacy-export

- 使用旧版自定义打包逻辑
- 从 `~/.openclaw/` 收集关键目录并打包
- 默认包含：
  - `openclaw.json` / `openclaw.json.bak`
  - `workspace/`
  - `cron/`
  - `extensions/`
  - `memory/`
  - `credentials/`
  - `identity/`
  - `devices/`
- 可选包含：`agents/`
- 自动生成 `plugin-manifest.txt`

### import

- 停止 `openclaw gateway`
- **先解压到临时目录**
- 识别 archive 中的 `.openclaw` 根目录
- 将内容复制到 `~/.openclaw/`
- 自动做一次 `openclaw config validate`
- 启动 `openclaw gateway`
- 若使用 `--overwrite`：
  - 旧的 `~/.openclaw` 会先被改名为 `~/.openclaw.pre-import-时间戳`
  - 便于导入后验证失败时快速回滚

### verify

- 检查 `openclaw status`
- 检查 `openclaw channels status --probe`
- 检查 `openclaw cron list`
- 检查 `openclaw skills check`
- 检查 `openclaw plugins list`
- 插件一致性校验：对比 `plugins.entries` 与 `extensions/` 是否有缺失
- 检查 workspace 关键文件是否存在（`MEMORY.md`、`memory/`、`skills/`）

### backup-verify

- 调用官方：`openclaw backup verify <archive>`
- 用于对现有归档做标准校验

---

## 4) 推荐迁移流程

1. **源机器导出**：执行 `export`
2. **传输备份包**：通过 `scp` / 网盘 / U 盘
3. **目标机器导入**：执行 `import --overwrite`
4. **标准校验**：执行 `backup-verify`
5. **运行验收**：执行 `verify`
6. **业务验收**：
   - 手动触发一个 cron：`openclaw cron run <job-id>`
   - 检查消息渠道（钉钉 / Discord / 飞书）是否真实可达
7. **确认稳定后**：
   - 手动清理旧目录 `~/.openclaw.pre-import-*`

---

## 5) 注意事项

- 备份包含敏感信息（例如渠道凭据、API Key），请妥善保存。
- 跨机器迁移时，如果用户名或路径不同，需检查 `openclaw.json` 中的绝对路径。
- 若目标机 Node / OpenClaw 环境不同，建议先安装同版本，再导入备份。
- 如导入后服务异常，优先运行：

```bash
openclaw doctor
openclaw status
```

- `--overwrite` 现在不会直接删除已有 `~/.openclaw`，但你仍应在导入前确认目标机无需保留并行运行的旧状态。

---

## 6) 命令帮助

```bash
./migrate-openclaw.sh --help
```
