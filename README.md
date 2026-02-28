# OpenClaw 迁移指南

本目录提供一套可重复执行的迁移方案，用于迁移以下内容：

- skills（workspace 内的技能与脚本）
- 定时任务（cron）
- 存储记忆（`MEMORY.md`、`memory/` 及 memory 索引相关文件）
- 插件与主配置（`openclaw.json`、`extensions/` 等）

文件：

- `migrate-openclaw.sh`：迁移脚本

---

## 1) 快速开始

在源机器导出：

```bash
cd openclaw-migration
chmod +x migrate-openclaw.sh
./migrate-openclaw.sh export
```

可选：包含会话历史（`agents/`）

```bash
./migrate-openclaw.sh export ./openclaw-backup.tar.gz --include-agents
```

把导出的 `tar.gz` 复制到目标机器后导入：

```bash
cd openclaw-migration
chmod +x migrate-openclaw.sh
./migrate-openclaw.sh import ./openclaw-backup.tar.gz --overwrite
./migrate-openclaw.sh verify
```

---

## 2) 脚本做了什么

### export

- 尝试停止 `openclaw gateway`（避免迁移时文件仍被写入）
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
- 可选包含：`agents/`（通过 `--include-agents`）

### import

- 停止 `openclaw gateway`
- 解压备份到 `~/.openclaw/`
- 启动 `openclaw gateway`

### verify

- 检查 `openclaw status`
- 检查 `openclaw plugins list`
- 检查 `openclaw cron list`
- 检查 workspace 关键记忆文件是否存在

---

## 3) 推荐迁移流程

1. **源机器导出**：执行 `export`
2. **传输备份包**：通过 `scp`/网盘/U 盘
3. **目标机器导入**：执行 `import --overwrite`
4. **完整验收**：执行 `verify`
5. **业务验收**：
   - 手动触发一个 cron：`openclaw cron run <job-id>`
   - 检查消息渠道（钉钉/Discord）是否真实可达

---

## 4) 注意事项

- 备份包含敏感信息（例如渠道凭据、API Key），请妥善保存。
- 跨机器迁移时，如果用户名或路径不同，需检查 `openclaw.json` 中的绝对路径。
- 若目标机 Node/OpenClaw 环境不同，建议先安装同版本，再导入备份。
- 如导入后服务异常，优先运行：

```bash
openclaw doctor
openclaw status
```

---

## 5) 命令帮助

```bash
./migrate-openclaw.sh --help
```
