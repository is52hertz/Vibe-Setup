# 升级机制：合并审查交接

## 位置与提交

- 升级分支：`feat/reliable-upgrades`。
- 当前 worktree：`/Users/is52hertz/Project/old/dev-tools/Vibe-Setup-upgrade`。
- 已通过 `git worktree move` 从临时目录搬迁，Git 元数据已更新。
- 实现提交：`d2ecb66 feat(upgrade): make template upgrades explicit and recoverable`。
- 开发基点：`454be8a`，包含当时已经提交的 CC-Workflow subagent 功能。
- 原工作区：同级 `Vibe-Setup`，开发分支为 `feat/cc-workflow-codex-subagent`；本轮观察到 HEAD 为 `c5ead32`。这是快照，合并前重新检查。
- 尚未合并、rebase 或推送。不要覆盖、暂存或清理原工作区的并行改动。

## 用户意图与实现

用户希望旧项目能够持续升级，同时保留项目定制的 AGENTS.md；明确区分暂缓、本次保留、自主管理。

实现沿用 `--apply`，版本升为 `1.2.0`，不增加运行依赖，兼容系统 Bash 3.2。

1. schema 2 保留文件／区块 hash，并在 `.vibe-init/base/<hash>` 保存上游模板原文。基线不能用合并后的项目定制内容替代。
2. 修复空记录刷新清空历史基线的问题；无变化刷新不反复修改 manifest 时间戳。
3. 待办保存固定的上游提案；后续版本不能覆盖尚未处理的提案。删除 `.template` 不再表示完成。
4. 显式确认绑定待办 ID 和当前项目文件指纹，支持 `merged`、`keep`、`converted`。
5. 支持项目暂停／恢复、文件或区块自管／重新跟随。PRODUCT、PROJECT_PHASE 默认由项目维护。
6. 保留本地文件删除；上游再次变化时生成待办。未被本地修改的非可选上游区块可安全退役，修改过的需审阅。
7. manifest、policy、base 可随项目提交；pending、backups、lock 保持本地忽略。迁移旧工具写入的精确 `.vibe-init/` 忽略规则，不擅自改其他全局或自定义规则。
8. 增加项目锁、路径检查、升级前快照和拒绝覆盖后续编辑的回退。
9. schema 1 保留历史 hash；不能恢复的上游原文不猜测。未知未来 schema 拒绝写入。旧无区块文件先确认格式转换，再处理内容。

## 操作入口

在测试项目目录执行本 worktree 的 `vibe-init.sh`，不要误用尚未合并的原入口。

```bash
/Users/is52hertz/Project/old/dev-tools/Vibe-Setup-upgrade/vibe-init.sh --apply
```

以下均为该脚本参数；交互面板的 Upgrade controls 提供对应操作：

```text
--apply --pending
--apply --resolve ID --expect HASH --resolution merged
--apply --resolve ID --expect HASH --resolution keep
--apply --resolve ID --expect HASH --resolution converted
--apply --pause-updates
--apply --resume-updates
--apply --self-manage AGENTS.md:CORE_RULES
--apply --follow AGENTS.md:CORE_RULES
--apply --rollback BACKUP_ID
```

- ID 和 HASH 从审阅后的 `--pending` 输出获取，不能拿旧指纹确认新编辑。
- `keep` 仅接受本次差异；上游以后再次变化仍提示。
- 暂缓就是保留未解决待办，不推进基线。
- 自管不隐式关闭已有待办，需另行确认。整文件自管优先于区块策略。
- 恢复只解除暂停，下一次普通 `--apply` 才同步。

## 主要代码

| 文件 | 审查重点 |
| --- | --- |
| `lib/upgrade.sh` | 策略、确认协议、指纹、锁、快照、回退、交互控制 |
| `lib/state.sh` | schema 迁移、空刷新修复、上游内容保存、忽略规则、固定待办 |
| `lib/sync.sh` | 自管优先于整文件快进、本地删除、上游区块退役、待办阻止继续写入 |
| `lib/apply.sh` | 面板接入、待办提示、状态措辞、同步快照 |
| `vibe-init.sh` | 参数校验、版本、入口、锁生命周期与退出清理 |
| `test/upgrades.sh` | 连续跨版本、确认、自管、暂停、迁移、回退及真实 CLI 流程 |
| `README.md`、`AGENTS.md` | 已更新的行为约定和使用边界 |

## 并行分支交叉点：不能整文件选一边

交接时原分支已在基点后新增：

- `d42c68d`：CC-Workflow 根据任务退出唤醒，替代轮询等待。保留该分支的工作流模板、agent 定义和对应测试。
- `c5ead32`：同样修复空刷新丢失基线，使用 `FILENAME == ARGV[1]`。合并时保留修复一次，同时保留双方不同的回归断言，尤其是空刷新仍能更新 Trellis 状态头。
- `c5ead32` 还保护既有 `codex-run.md` 不被启用功能覆盖，并通过 `archive_disabled` 避免重复禁用覆盖历史归档。这些保护必须保留，不能因采用升级分支的 `lib/apply.sh` 丢失。
- 该分支的启用功能路径可能直接产生 `codex-run.md.template`；审查它与升级分支显式 pending 协议的衔接，不能默认所有同名 hand-out 都已注册待办。

观察到原工作区仍有未提交内容：

- `lib/apply.sh`、`lib/block_engine.sh`、`lib/state.sh`、`vibe-init.sh` 修改。
- 测试清单从 `templates/common/Test/templates-test-checklist.html` 暂存移动到 `templates/blocks/features/test-checklist/checklist.html`。
- 未跟踪 `.claude/`。

不要将这些视为本升级任务的改动。等待所属 Agent 提交或明确交接后再集成。测试清单可选化可能影响模板组装、`TEMPLATE_FILES`、缺失来源判断及快照清单，需结合最终实现审查，不要机械恢复旧路径。

## 验证证据

实现提交前，在 macOS 系统 Bash 3.2 下：

- `./test/run.sh`：CLI 133 项、库测试 223 项、升级生命周期 80 项，共 436 项通过。
- Bash 语法检查和 `git diff --check` 通过。
- 在独立临时副本中破坏空刷新、确认指纹、暂停、自管、固定提案、回退保护六类行为，新增测试均报错；未在正式 worktree 留下变异。
- 提交前完整测试日志：`/tmp/vibe-upgrade-verified.log`，临时文件可能被系统清理。
- 搬迁后完整复测亦通过（436 项），日志为 `/tmp/vibe-upgrade-relocated-tests.log`，末尾为 `ALL SUITES PASSED`。

合并后的测试数量可能增加，不要为匹配 436 而删除并行分支测试。

## 明确边界与审查重点

- 不承诺自动判断规则语义，也不验证任意配置格式（包括 JSON）；显式确认表示操作者已审阅。
- `--on-exists overwrite` 仍是旧式显式覆盖入口，不能当作普通安全升级命令。
- 暂停针对模板同步，不替代用户明确执行的 Trellis 生命周期操作。
- 可选区块缺失可能是用户退出或模板组合变化，不自动重启或删除集成。
- 文件改名、文件退役、歧义区块改名需要未来发布编写明确迁移，不做相似文本猜测。
- 基线和策略只有随项目提交／备份后才能跨机器保留；进行中的待办及恢复快照仍是本地数据。
- 自动回退只用于存在完成指纹且没有后续修改的快照。强制终止留下的不完整快照需人工检查 `before/`，不能盲目恢复。
- 恢复覆盖模板升级、确认和策略操作，不覆盖 Trellis 生命周期及功能开关的归档流程。
- 锁必须保持到进程退出；`prepare_template_set` 清理临时模板时不能释放锁。
- 显示的版本表示最后运行的工具版本，不表示全部待办已经完成。

## 建议合并流程

1. 重新读取两边 AGENTS.md、分支 HEAD、工作区状态和最终 diff；上述交叉点只是交接时快照。
2. 等并行改动稳定后，在干净的集成分支／worktree 中合并 `feat/reliable-upgrades`；不要在原工作区覆盖未提交内容。
3. 逐项审查 state/apply/入口及测试清单接入，保留两边安全修复、功能和测试，更新文档到合并后的真实状态。
4. 运行 `./test/run.sh`，补充跨功能测试：启用 CC-Workflow 但已有自定义 agent、重复禁用归档、可选测试清单开关、暂停期间同步，以及这些操作后的显式待办确认。
5. 在临时旧项目验证一次定制规则升级、keep 后重复运行、下个版本再次提醒和回退。不要拿真实旧仓库直接试错。
6. 验证后提交集成结果；未经用户请求不推送，不删除历史 feat 分支。
