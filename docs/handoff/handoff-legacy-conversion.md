# Handoff — Legacy 文件格式转换(复用 .template + Agent 提示词通道)

- **日期**: 2026-09-07
- **仓库**: `/Users/is52hertz/Project/old/dev-tools/Vibe-Setup`
- **分支**: `feat/vibe-init-upgrade`
- **提交**: `cacc5959270e1a85b683aafb21ca0105b85e1a14`(`feat(apply): route legacy pre-<TAG> targets to a format-conversion prompt`)
- **工作树**: 干净(未跟踪的 `.claude/`、`session_handoff.md` 为用户自带文件,与本次改动无关)
- **测试**: `./test/run.sh` 全绿 —— `test/dry-run.sh` 94 条、`test/units.sh` 63 条,0 失败
- **本文档性质**: 供他人 review 的交接文档。用户原始输入在第二节**逐字全量保留**。

---

## 1. 背景

`feat/vibe-init-upgrade` 分支把模板系统从静态目录(`templates/base/`、`templates/trellis/`,在 main 上)重构成了 `<TAG>` 块引擎(`templates/blocks/` + `templates/common/`)。新引擎(`lib/block_engine.sh`)只能编辑**带有 `<TAG>` 标记**的文件,因此凡是旧版脚手架生成的项目文件(纯 Markdown 的 `AGENTS.md`/`CLAUDE.md`,即 "legacy" 格式)永远进不了块机制:诊断只显示一行 "Present (Legacy format)",没有任何后续动作,也没有转换路径。

本次任务即为补上这条路径。

## 2. 用户原始需求(逐字全量保留)

以下为本次会话中用户的全部输入,按时间顺序原样引用,不作任何改写。

**消息 1**(附文件 `.claude/handoff.md`,内容为上一轮会话的交接文档):

> 检查一下这个仓库。这里经历了一次非常大的文件结构改变,似乎没有支持旧文件转换成新文件。
>
> 你先看一眼,然后告诉我你打算怎么解决旧文件转换成新文件的转换方式?

**Agent 回应**: 调研后给出方案一(纯 bash 侧 awk 状态机做无损 re-wrap 迁移,新建 `lib/migrate.sh`),并交互询问转换语义。用户当时选择了「只增强检测与提示:不改文件,只把 Legacy 提示改成带操作指引的文案」。

**消息 2**(用户随后修正了方向,成为本次实施的最终依据):

> 我觉得可以复用之前的升级方法。
>
> 之前代码里写过一个升级方法,它是把新的文件作为一个 template 复制过去,然后给一个 agent 提示词,让负责项目规划的 agent 自己权衡怎么修改。
>
> 我觉得我们也可以参考这种做法。

**Agent 回应**: 采纳该方向,给出方案(复用 `.template` 副本 + 分流后的转换提示词,不建 `lib/migrate.sh`,bash 不做任何格式改写),交互确认。

**用户确认**: 「确认,按这个方案实施」。

**消息 3**: 「继续」(×2,并从 plan 模式切到 act 模式,授权实施)。

**消息 4**(任务完成后的独立问答,与本任务无代码关联):

> 简要介绍一下这个脚本运行方式

(已以纯文字回答,未涉及任何代码改动。)

**消息 5**(当前消息): 要求生成本 handoff 文档,供他人 review,并要求用户输入全量保留。

## 3. 最终方案(经用户确认)

**核心语义**: 脚本自己从不改写用户的旧文件。它做三件事:

1. **识别** legacy:目标文件存在但缺少标记 tag(`AGENTS.md` 看 `<CORE_RULES>`,`CLAUDE.md` 看 `<CLAUDE_BASE>`)即判为 legacy;
2. **照旧走非破坏性同步**:把新格式模板写成 `<name>.template` 放在旁边(既有机制,未改);
3. **提示词分流**:结尾给 AI agent 的提示词按目标文件格式分两段——
   - **普通内容合并**(既有文案,不动):适用于 modern 目标和无块概念的文件(如 `CC-Cowork-Workflow.md`、`settings.json`);
   - **格式转换**(新增):适用于 legacy 对。要求 agent 按 `.template` 里的块结构把旧文件内容**原样**装进对应 `<TAG>...</TAG>` 壳,旧注释锚点(`<!-- PROFILE:x START/END -->`、`<!-- TRELLIS:START/END -->`)视为格式残渣由 tag 取代,内容一字不丢,拿不准的段落列出询问用户,中文提问。

tag 词汇表从材料化的模板集动态读出,不在脚本里硬编码第二份(遵守 "templates/ 是唯一事实源" 的项目铁律)。

## 4. 改动清单(commit `cacc595`,5 files, +196/−28)

### `lib/block_engine.sh`(+19)

- 新增 `file_format <file> <tag_name> [id]`:三态分类 `modern` / `legacy` / `missing`,以 `has_block` 为判定基础。检测逻辑收敛到此一个函数(原诊断区的内联判断已改为调用它)。

### `lib/apply.sh`(+150/−26)

- **`modern_marker_tag <rel>`**:每个受管文件与其 "modern 标记 tag" 的映射(`AGENTS.md→CORE_RULES`、`CLAUDE.md→CLAUDE_BASE`,其余为空 = 无格式概念);
- **`md_tag_vocabulary <file>`**:grep 出一个材料化模板文件里出现的全部开 tag(去掉 id 后缀、排序去重),供转换提示词列举 "新格式里有哪些 tag";空文件/缺文件返回空;
- **`rel_is_legacy <rel>`**:数组成员判断;
- **`APPLIED_LEGACY` 数组**:在 `copy_template_file` 写出 `.template` 时,若真身缺标记 tag 则记入(与既有 `APPLIED_TEMPLATES` 并行);
- **`suggest_template_merges` 重写**:先打印普通合并段(只列非 legacy 对),再打印格式转换段(列 legacy 对 + 每对的新格式 tag 词汇表 + 转换规则文案)。两段可共存(一次 sync 可能同时写出两类文件),也可各自单独出现;
- **诊断卡**:legacy 时显示 `Legacy (pre-<TAG> format)` 并新增一行 `Format upgrade: sync once, then follow the printed agent prompt`(替代原 `Present (Legacy format)`)。

### `test/units.sh`(59→63)

- `file_format` 四条断言:modern / legacy / missing / 带 id 的 tag。

### `test/dry-run.sh`(77→94)

- legacy 目标场景(10 条):写出 `.template`、诊断标记、转换提示词的出现与关键文案(含 tag 词汇表、锚点词汇、"不重写内容" 要求),并断言普通合并提示词**不**出现;
- modern 目标场景(5 条):普通合并提示词出现、转换提示词**不**出现、无 `Format upgrade` 行;
- mixed 场景(3 条):legacy `AGENTS.md` + modern `CLAUDE.md` 一次 run,两段提示词都打印(计数 = 2)。

### `AGENTS.md`(项目快照)

- 更新测试计数(77/59 → 94/63);补记 legacy 转换路径一行;同时纠正了上一份 handoff 中的错误记载——本仓库根部的 `AGENTS.md`/`CLAUDE.md` 当时其实仍是 legacy 格式,并非 Modern。

## 5. 验证

1. **双套件**:`./test/run.sh` 94 + 63 全绿;
2. **变异测试**(每条新断言都被验证过"能失败"):
   - 去掉 `APPLIED_LEGACY` 记入 → 7 条 legacy 断言全红;
   - 打空 `modern_marker_tag` 的 AGENTS.md 映射 → legacy 断言 + mixed 断言全红;
   - 打乱 `file_format` 的 modern 分支 → units 中 2 条 `file_format` 断言红;
   每次变异后还原并复核干净态全绿;
3. **Dogfood**:在仓库自身(`--apply -y`)真实运行——根部两个 legacy 文件正确进入转换提示词(词汇表动态给出 `<CORE_RULES> <METADATA> <PRODUCT> <PROFILE_SETUP> <PROFILE> <PROJECT_PHASE>` 与 `<CLAUDE_BASE> <FEATURE>`),`CC-Cowork-Workflow.md` 正确留在普通合并段,真身文件零改动;验证后清理了全部 `.template` 副本等产物。

## 6. 明确不做(范围边界)

- 不新建 `lib/migrate.sh`,bash 不解析、不改写、不重排任何用户文件;
- `CC-Cowork-Workflow.md`、`.claude/settings.json`、checklist 本身无 tag 概念,不参与格式转换,继续走既有 sync/合并流程;
- 转换的**执行质量**由运行提示词的 AI agent 负责——这是方案的既定取舍(用户选定),不是缺陷;
- "迁移后逐块刷新为最新模板内容"(`replace_block` 路径)是 legacy 文件完成格式转换**之后**自然解锁的能力,本次未叠加。

## 7. Review 指南

- 重点读 `lib/apply.sh` 的 `suggest_template_merges`(提示词分流与措辞)和 `copy_template_file` 尾部的 legacy 记入逻辑;
- 确认转换提示词的约束文案是否符合你对 agent 行为的预期(内容零丢失、锚点清理、拿不准要问、中文提问);
- 复跑:`./test/run.sh`;实操:`cd <有旧 AGENTS.md 的项目> && /path/to/vibe-init.sh --apply`,看诊断行与结尾两段提示词;
- 设计决策(均已验证):tag 词汇表动态读取避免第二份硬编码;两段提示词共存而非互斥;`--on-exists overwrite` 路径不加额外行为。

## 8. 遗留与建议

- 本文档与 `.claude/handoff.md`、`session_handoff.md` 均为未跟踪文件,是否入库/删除由维护者定夺;
- 本仓库自身的 `AGENTS.md`/`CLAUDE.md` 仍是 legacy 格式——可运行 `--apply` 拿到转换提示词后交给 AI agent 完成自举转换,作为该功能的第一个真实消费者;
- 上一份 handoff 中的待办(TTY 实测交互、`<CLAUDE_BASE>` 去留讨论、合并回 main)依然有效。
