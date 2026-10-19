#!/usr/bin/env bash
# lib/i18n.sh — the interface language: English, or Simplified Chinese.
#
# Sourced by lib/ui.sh, so every caller that has the renderer has this too.
#
# English is the source text and the default, and in English every lookup
# returns its input untouched — the plain rendering stays byte for byte what it
# always was. Translation happens at the rendering layer: lib/ui.sh and
# lib/prompt.sh pass each message, label and hint through _t on the way out,
# so the rest of the code keeps writing plain English and never knows.
#
# A run starts in English unless VIBE_INIT_LANG names Chinese (zh, zh_CN,
# zh-CN, ...). Shift+L in any selector flips it for the rest of the run; nothing
# is remembered afterwards.
#
# The selectors run inside $(...), so a flip made there is invisible to the
# shell that will print the next line. The entrypoint therefore points
# UI_LANG_FILE at a file in a private run directory, a flip writes it, and every
# lookup reads it back — a builtin read, no fork. Unset (the tests, or a run
# with no terminal to press a key in), the language simply stays put.
#
# Messages built with a value in them ("copied <path>") are matched by regex,
# capturing the value. A sentence the code prints over several info lines is
# translated whole on its first line, and the continuation lines are marked to
# be skipped, so the Chinese reads as one sentence rather than three fragments.
#
# Compatible with macOS Bash 3.2: no associative arrays, so the catalog is a
# case statement plus an ordered list of regexes.

UI_LANG="en"
case "${VIBE_INIT_LANG:-}" in
  zh|zh_*|zh-*) UI_LANG="zh" ;;
esac
UI_LANG_FILE="${UI_LANG_FILE:-}"

# _t's results, as globals rather than stdout: the selector translates every
# row on every keypress, and a fork per lookup would be felt.
UI_T=""
UI_T_SKIP=0

# Pick up a flip made in a subshell.
_ui_lang_sync() {
  if [[ -n "${UI_LANG_FILE}" && -f "${UI_LANG_FILE}" ]]; then
    IFS= read -r UI_LANG < "${UI_LANG_FILE}" || true
  fi
  return 0
}

# Flip the language for the rest of the run.
ui_lang_toggle() {
  _ui_lang_sync
  if [[ "${UI_LANG}" == "zh" ]]; then
    UI_LANG="en"
  else
    UI_LANG="zh"
  fi
  if [[ -n "${UI_LANG_FILE}" ]]; then
    printf '%s\n' "${UI_LANG}" > "${UI_LANG_FILE}" 2>/dev/null || true
  fi
  return 0
}

# Is the interface currently in Chinese?
ui_lang_is_zh() {
  _ui_lang_sync
  [[ "${UI_LANG}" == "zh" ]]
}

# Translate one string into UI_T. UI_T_SKIP=1 means "print nothing": the line
# is the tail of a sentence already printed whole.
_t() {
  UI_T="$1"
  UI_T_SKIP=0
  _ui_lang_sync
  [[ "${UI_LANG}" == "zh" && -n "$1" ]] || return 0
  _i18n_zh "$1"
  return 0
}

# Display width of a string, into UI_WIDTH: a CJK character takes two columns.
# Counted on the UTF-8 bytes under LC_ALL=C (local to this function, which Bash
# 3.2 restores on return), so the answer does not depend on the user's locale:
# lead bytes E3-E9 and EF open the CJK and full-width ranges (two columns);
# every other multi-byte character — the dashes, arrows and ticks the tool
# prints — takes one.
UI_WIDTH=0
_ui_width() {
  local LC_ALL=C
  local s="$1" t=""
  local bytes=0 n2=0 n3=0 n4=0 wide=0

  bytes="${#s}"
  t="${s//[^$'\xc0'-$'\xdf']/}"; n2="${#t}"
  t="${s//[^$'\xe0'-$'\xef']/}"; n3="${#t}"
  t="${s//[^$'\xf0'-$'\xf7']/}"; n4="${#t}"
  t="${s//[^$'\xe3'-$'\xe9'$'\xef']/}"; wide="${#t}"
  UI_WIDTH=$(( bytes - n2 - 2 * n3 - 3 * n4 + wide + n4 ))
}

# Match the string being translated against a regex; captures in BASH_REMATCH.
_I18N_S=""
_i18n_m() {
  [[ "${_I18N_S}" =~ $1 ]]
}

# "3 new, 1 to review" -> "3 个新增，1 个待审阅". Returns 1 when the string is
# not such a list, so the caller can keep looking.
_i18n_counts() {
  local s="$1" out="" part="" rest=""

  rest="${s}, "
  while [[ -n "${rest}" ]]; do
    part="${rest%%, *}"
    rest="${rest#*, }"
    case "${part}" in
      *" new")        part="${part% new} 个新增" ;;
      *" to refresh") part="${part% to refresh} 个待刷新" ;;
      *" to review")  part="${part% to review} 个待审阅" ;;
      *" to convert") part="${part% to convert} 个待转换" ;;
      *) return 1 ;;
    esac
    [[ "${part%% *}" =~ ^[0-9]+$ ]] || return 1
    out="${out:+${out}，}${part}"
  done
  UI_T="${out}"
}

_i18n_zh() {
  # Reset here, not only in _t: the flattened-label rule recurses, and a miss
  # must read back as the input, not as whatever the outer lookup left behind.
  UI_T="$1"
  _I18N_S="$1"

  case "$1" in
    # --- frame and prompts ---------------------------------------------------
    "project orchestrator") UI_T="项目编排" ;;
    "AI agent setup for a new project") UI_T="为新项目配置 AI agent" ;;
    "Yes") UI_T="是" ;;
    "No") UI_T="否" ;;
    "Back") UI_T="返回" ;;
    "Exit") UI_T="退出" ;;
    "on") UI_T="开" ;;
    "off") UI_T="关" ;;
    "please choose one of the listed options") UI_T="请从列出的选项中选择" ;;

    # --- diagnostics card ----------------------------------------------------
    "Project environment") UI_T="项目环境" ;;
    "Git repo") UI_T="Git 仓库" ;;
    "Platforms") UI_T="平台" ;;
    "Test checklist") UI_T="测试清单" ;;
    "Format upgrade") UI_T="格式升级" ;;
    "Layout") UI_T="布局" ;;
    "single") UI_T="单一仓库" ;;
    "hub") UI_T="hub" ;;
    "member") UI_T="hub 成员" ;;
    "inside a hub; --apply --layout member joins it") UI_T="位于 hub 之内；用 --apply --layout member 加入" ;;
    "This folder looks like a category of independent repositories, not a project.")
      UI_T="这个文件夹看起来是一组独立仓库的分类目录，而不是项目。请改为进入其中某个仓库运行 vibe-init --apply。" ;;
    "Run vibe-init --apply inside one of them instead.") UI_T_SKIP=1 ;;
    "Sync this folder as a project anyway?") UI_T="仍要把这个文件夹当作项目同步？" ;;
    "refusing to sync a category folder") UI_T="拒绝同步分类目录" ;;
    "no AGENTS.md here; the layout is recorded, but its block is not added")
      UI_T="这里没有 AGENTS.md；已记录布局，但没有添加对应的块" ;;
    "Not initialized") UI_T="未初始化" ;;
    "Not configured") UI_T="未配置" ;;
    "None") UI_T="无" ;;
    "Disabled") UI_T="未启用" ;;
    "Not included") UI_T="未包含" ;;
    "Missing") UI_T="缺失" ;;
    "Initialized") UI_T="已初始化" ;;
    "Active") UI_T="已启用" ;;
    "Paused") UI_T="已暂停" ;;
    "CLI not installed") UI_T="CLI 未安装" ;;
    "Modern") UI_T="新格式" ;;
    "Legacy") UI_T="旧格式" ;;
    "unknown") UI_T="未知" ;;
    "restore it from Trellis management") UI_T="可在 Trellis 管理中恢复" ;;
    "<TAG> format") UI_T="<TAG> 格式" ;;
    "pre-<TAG> format") UI_T="pre-<TAG> 格式" ;;
    "project not tracked yet") UI_T="项目尚未被记录" ;;
    "sync, have your agent convert, then sync again to merge")
      UI_T="先同步，让 agent 转换格式，再同步一次完成合并" ;;

    # --- the dashboard menu --------------------------------------------------
    "What would you like to do?") UI_T="要做什么？" ;;
    "Sync template files") UI_T="同步模板文件" ;;
    "templates") UI_T="模板" ;;
    "Trellis management") UI_T="Trellis 管理" ;;
    "platforms, update, pause, uninstall") UI_T="平台、更新、暂停、卸载" ;;
    "Toggle CC-Workflow") UI_T="开关 CC-Workflow" ;;
    "Toggle test checklist") UI_T="开关测试清单" ;;
    "Toggle Trellis block") UI_T="开关 Trellis 块" ;;
    "in AGENTS.md") UI_T="在 AGENTS.md 中" ;;
    "Sync everything and exit") UI_T="全部同步后退出" ;;
    "templates + Trellis, then exits") UI_T="模板 + Trellis，然后退出" ;;
    "not installed") UI_T="未安装" ;;
    "paused") UI_T="已暂停" ;;
    "not initialized") UI_T="未初始化" ;;
    "Trellis update only") UI_T="仅更新 Trellis" ;;
    "nothing to do") UI_T="无事可做" ;;
    "everything up to date") UI_T="全部已是最新" ;;
    "All sync tasks finished.") UI_T="所有同步任务已完成。" ;;

    # --- template sync -------------------------------------------------------
    "not in this set") UI_T="不在本模板集中" ;;
    "up to date") UI_T="已是最新" ;;
    "already exists — will refresh") UI_T="已存在 — 将刷新" ;;
    "already exists — needs review") UI_T="已存在 — 需要审阅" ;;
    "already exists — needs format conversion") UI_T="已存在 — 需要格式转换" ;;
    "Which files?") UI_T="要同步哪些文件？" ;;
    "Copy all of these files?") UI_T="复制以上全部文件？" ;;
    "Enter numbers to copy (e.g. 1 3), or 'all'") UI_T="输入要复制的编号（如 1 3），或 'all'" ;;
    "please enter one or more valid numbers") UI_T="请输入一个或多个有效编号" ;;
    "please answer o, t, or s") UI_T="请输入 o、t 或 s" ;;
    "Copying anyway would place a fresh copy of each template beside")
      UI_T="强制复制会在已与模板一致的文件旁各放一份新的模板副本。如果你认为计划判断有误，选“是”。" ;;
    "files that already match it. Say yes if the plan has it wrong.") UI_T_SKIP=1 ;;
    "Copy the templates anyway?") UI_T="仍然复制模板？" ;;
    "no files selected; nothing to apply") UI_T="未选择文件；无需同步" ;;
    "Everything is up to date — nothing to sync.") UI_T="全部已是最新 — 无需同步。" ;;
    "copy the prompt between the lines below and give it to your AI agent:")
      UI_T="复制下面两条分隔线之间的提示词，交给你的 AI agent：" ;;
    "suggested prompt for your AI agent") UI_T="给 AI agent 的建议提示词" ;;
    "1 of them is in the old pre-<TAG> format; copy the prompt between the")
      UI_T="其中 1 个是旧的 pre-<TAG> 格式；复制下面分隔线之间的提示词来转换它：" ;;
    "lines below to convert it:") UI_T_SKIP=1 ;;
    "between the lines below to convert them:") UI_T_SKIP=1 ;;
    "once the conversion is explicitly acknowledged, run")
      UI_T="显式确认转换完成后，再运行一次 vibe-init --apply：那次同步会把新的块与模板比对，并打印合并内容用的提示词。" ;;
    "vibe-init --apply again: that sync compares the new blocks with the") UI_T_SKIP=1 ;;
    "templates and prints the prompt for merging their content.") UI_T_SKIP=1 ;;
    "Sync result") UI_T="同步结果" ;;
    "created") UI_T="已创建" ;;
    "refreshed") UI_T="已刷新" ;;
    "needs review") UI_T="需要审阅" ;;
    "needs format conversion") UI_T="需要格式转换" ;;
    "your edits, template unchanged") UI_T="你的修改，模板未变" ;;
    "whole file") UI_T="整个文件" ;;
    "differs from the template") UI_T="与模板不同" ;;

    # --- CC-Workflow, checklist and Trellis-block toggles --------------------
    "CC-Workflow is currently ENABLED.") UI_T="CC-Workflow 当前已启用。" ;;
    "Disable CC-Workflow and archive the workflow file?") UI_T="停用 CC-Workflow 并归档工作流文件？" ;;
    "Removed the CC-Workflow block from CLAUDE.md.") UI_T="已从 CLAUDE.md 移除 CC-Workflow 块。" ;;
    "CLAUDE.md still mentions CC-Cowork-Workflow.md, but carries no")
      UI_T="CLAUDE.md 仍提到 CC-Cowork-Workflow.md，但没有可移除的 <FEATURE id=\"cc-workflow\"> 块（旧格式）。" ;;
    "<FEATURE id=\"cc-workflow\"> block to remove (pre-block format).") UI_T_SKIP=1 ;;
    "Delete that section by hand, or the file will point at an archived document:")
      UI_T="请手动删除这一节，否则它会指向一个已归档的文档：" ;;
    "CC-Workflow is currently DISABLED.") UI_T="CC-Workflow 当前未启用。" ;;
    "Enable CC-Workflow and reference it from CLAUDE.md?") UI_T="启用 CC-Workflow 并在 CLAUDE.md 中引用它？" ;;
    "Kept your existing codex-run.md; the tool's copy is beside it as codex-run.md.template.")
      UI_T="保留了你现有的 codex-run.md；工具的版本放在旁边的 codex-run.md.template。" ;;
    "The workflow document will point at an agent this project does not have.")
      UI_T="工作流文档将指向一个本项目没有的 agent。" ;;
    "Restart Claude Code once before calling codex-run — agent definitions load at session start.")
      UI_T="调用 codex-run 前请先重启一次 Claude Code — agent 定义在会话启动时加载。" ;;
    "The test checklist is currently INCLUDED.") UI_T="测试清单当前已包含。" ;;
    "Remove it and archive the file?") UI_T="移除并归档该文件？" ;;
    "The test checklist is currently NOT INCLUDED.") UI_T="测试清单当前未包含。" ;;
    "Add the manual test checklist to this project?") UI_T="为本项目添加手动测试清单？" ;;
    "Kept your existing checklist; the tool's copy is beside it as .template.")
      UI_T="保留了你现有的测试清单；工具的版本放在旁边的 .template。" ;;
    "Added Test/templates-test-checklist.html.") UI_T="已添加 Test/templates-test-checklist.html。" ;;
    "AGENTS.md still tells agents to follow Trellis.") UI_T="AGENTS.md 仍在要求 agent 遵循 Trellis。" ;;
    "Remove the Trellis integration block from AGENTS.md?") UI_T="从 AGENTS.md 移除 Trellis 集成块？" ;;
    "CC-Cowork-Workflow.md still describes the Trellis co-work loop. Toggle")
      UI_T="CC-Cowork-Workflow.md 仍在描述 Trellis 协作流程。把 CC-Workflow 关闭再打开，即可切换为普通版本。" ;;
    "CC-Workflow off and on again to switch it to the plain variant.") UI_T_SKIP=1 ;;
    "Add the Trellis integration block back to AGENTS.md?") UI_T="把 Trellis 集成块加回 AGENTS.md？" ;;
    "Removed the Trellis integration block from AGENTS.md.") UI_T="已从 AGENTS.md 移除 Trellis 集成块。" ;;
    "Could not remove the block; AGENTS.md was left untouched.") UI_T="无法移除该块；AGENTS.md 未被改动。" ;;
    "Added the Trellis integration block to AGENTS.md.") UI_T="已将 Trellis 集成块添加到 AGENTS.md。" ;;
    "Could not append the block; AGENTS.md was left untouched.") UI_T="无法追加该块；AGENTS.md 未被改动。" ;;
    "No AGENTS.md in this project yet — sync the template files first.")
      UI_T="本项目还没有 AGENTS.md — 请先同步模板文件。" ;;
    "AGENTS.md currently carries the Trellis integration block.") UI_T="AGENTS.md 当前包含 Trellis 集成块。" ;;
    "This only edits AGENTS.md; Trellis itself stays set up. To take it out")
      UI_T="这里只修改 AGENTS.md，Trellis 本身仍保持安装。要把它从项目中移除，请在 Trellis 管理中暂停或卸载。" ;;
    "of the project, pause or uninstall it from Trellis management.") UI_T_SKIP=1 ;;
    "Remove it from AGENTS.md?") UI_T="从 AGENTS.md 中移除？" ;;
    "AGENTS.md has no Trellis integration block.") UI_T="AGENTS.md 中没有 Trellis 集成块。" ;;
    "Add it to AGENTS.md?") UI_T="添加到 AGENTS.md？" ;;

    # --- Trellis management --------------------------------------------------
    "Trellis is paused in this project.") UI_T="本项目的 Trellis 已暂停。" ;;
    "Trellis is not initialized in this project.") UI_T="本项目尚未初始化 Trellis。" ;;
    "Restore Trellis") UI_T="恢复 Trellis" ;;
    "Initialize Trellis") UI_T="初始化 Trellis" ;;
    "Restore a paused Trellis") UI_T="恢复已暂停的 Trellis" ;;
    "Trellis is restored.") UI_T="Trellis 已恢复。" ;;
    "Add an AI platform") UI_T="添加 AI 平台" ;;
    "Update the project") UI_T="更新项目" ;;
    "Upgrade the Trellis CLI") UI_T="升级 Trellis CLI" ;;
    "Pause Trellis") UI_T="暂停 Trellis" ;;
    "Uninstall Trellis") UI_T="卸载 Trellis" ;;
    "trellis ablate, restorable") UI_T="trellis ablate，可恢复" ;;
    "trellis uninstall, deletes .trellis/") UI_T="trellis uninstall，会删除 .trellis/" ;;
    "Which platform?") UI_T="哪个平台？" ;;
    "Trellis is paused. Restore it from Trellis management.") UI_T="Trellis 已暂停。可在 Trellis 管理中恢复。" ;;
    "Trellis is uninstalled from this project.") UI_T="已从本项目卸载 Trellis。" ;;
    "Trellis CLI is not installed.") UI_T="Trellis CLI 未安装。" ;;
    "and ask about the files you have edited.") UI_T_SKIP=1 ;;
    "Run 'trellis update' anyway?") UI_T="仍然运行 'trellis update'？" ;;
    "Pausing moves every Trellis file out of the project and keeps a recovery")
      UI_T="暂停会把所有 Trellis 文件移出项目，并在本机 ~/.trellis 中保留一份恢复副本；恢复时会把任务、规格、日志和记忆原样带回。" ;;
    "copy in ~/.trellis on this machine; Restore brings back tasks, specs,") UI_T_SKIP=1 ;;
    "journals and memory exactly as they are now.") UI_T_SKIP=1 ;;
    "The tasks, specs, journals and memory under .trellis/ are not all committed.")
      UI_T=".trellis/ 下的任务、规格、日志和记忆并未全部提交。" ;;
    "Uninstalling deletes them permanently. To keep them, pause Trellis instead,")
      UI_T="卸载会永久删除它们。要保留，请改为暂停 Trellis，或先提交 .trellis/。" ;;
    "or commit .trellis/ first.") UI_T_SKIP=1 ;;
    "Uninstall and delete them anyway?") UI_T="仍要卸载并删除它们？" ;;
    "npm not found. Cannot upgrade Trellis.") UI_T="未找到 npm，无法升级 Trellis。" ;;
    "Upgrading Trellis CLI (npm install -g @mindfoldhq/trellis)...")
      UI_T="正在升级 Trellis CLI（npm install -g @mindfoldhq/trellis）..." ;;

    # --- upgrade controls ----------------------------------------------------
    "Upgrades") UI_T="升级" ;;
    "Upgrade controls") UI_T="升级控制" ;;
    "reviews, pause, ownership") UI_T="审阅、暂停、归属" ;;
    "Upgrade reviews") UI_T="升级审阅" ;;
    "Review pending updates") UI_T="审阅待处理的更新" ;;
    "merge or keep project rules") UI_T="合并或保留项目规则" ;;
    "Pause project upgrades") UI_T="暂停项目升级" ;;
    "until resumed") UI_T="直到恢复" ;;
    "Resume project upgrades") UI_T="恢复项目升级" ;;
    "check on next sync") UI_T="下次同步时检查" ;;
    "Let project own a file or block") UI_T="让项目自管某个文件或块" ;;
    "stop following templates") UI_T="不再跟随模板" ;;
    "Follow templates again") UI_T="重新跟随模板" ;;
    "file or block") UI_T="文件或块" ;;
    "Choose ownership scope") UI_T="选择归属范围" ;;
    "Choose reviewed file") UI_T="选择已审阅的文件" ;;
    "Merge reviewed and complete") UI_T="已审阅，合并完成" ;;
    "Keep project version this time") UI_T="本次保留项目版本" ;;
    "Format conversion complete") UI_T="格式转换已完成" ;;
    "Defer this update") UI_T="暂缓这次更新" ;;
    "Confirm your review decision") UI_T="确认审阅结论" ;;
    "Sync partially complete: reviews still pending.") UI_T="同步部分完成：仍有待审阅项。" ;;
    "Project upgrades remain paused.") UI_T="项目升级仍处于暂停状态。" ;;
    "Project upgrades are paused") UI_T="项目升级已暂停" ;;
    "Project upgrades are paused; use --apply --resume-updates")
      UI_T="项目升级已暂停；用 --apply --resume-updates 恢复" ;;
    "to keep the project version this time, use --resolution keep instead")
      UI_T="如本次要保留项目版本，改用 --resolution keep" ;;
    "project-managed or paused") UI_T="由项目自管或已暂停" ;;
    "awaiting explicit acknowledgement") UI_T="等待显式确认" ;;
    "invalid block structure; repair before merge") UI_T="块结构无效；合并前先修复" ;;
    "local deletion") UI_T="本地已删除" ;;
    "locally deleted file, upstream changed") UI_T="本地已删除，上游有变化" ;;
    "kept project version") UI_T="保留了项目版本" ;;
    "another upgrade holds .vibe-init/lock; after an interrupted run, verify it stopped before removing the lock")
      UI_T="另一个升级进程持有 .vibe-init/lock；如果上次运行被中断，先确认它已停止再删除锁" ;;
    "confirm converted first, then sync again to review content") UI_T="先确认 converted，再同步一次审阅内容" ;;
    "files changed after this upgrade; inspect before/ and recover manually")
      UI_T="本次升级后文件又有改动；请检查 before/ 并手动恢复" ;;
    "invalid backup ID") UI_T="备份 ID 无效" ;;
    "invalid block scope") UI_T="块范围无效" ;;
    "invalid or missing managed blocks") UI_T="受管块无效或缺失" ;;
    "no completed snapshot; inspect the before/ directory for manual recovery")
      UI_T="没有完整的快照；请检查 before/ 目录手动恢复" ;;
    "pending template changed; refusing acknowledgement") UI_T="待审阅的模板已被改动；拒绝确认" ;;
    "project file changed since review; inspect it again") UI_T="审阅后项目文件又有改动；请重新检查" ;;
    "refusing symlinks in upgrade state") UI_T="升级状态中不允许符号链接" ;;
    "repair malformed or duplicate block markers before acknowledgement")
      UI_T="确认前先修复格式错误或重复的块标记" ;;
    "resolution must be merged, keep, or converted") UI_T="resolution 只能是 merged、keep 或 converted" ;;
    "this file has no managed blocks") UI_T="该文件没有受管块" ;;
    "this review is not a format conversion") UI_T="该审阅不是格式转换" ;;
    "unknown or already resolved review") UI_T="审阅不存在或已确认" ;;
    "unresolved conflict markers") UI_T="存在未解决的冲突标记" ;;
    "upgrade state is not a directory") UI_T="升级状态不是目录" ;;
    "dry-run: keep manifest, policy and base trackable; ignore local upgrade artifacts")
      UI_T="dry-run：manifest、policy 和 base 保持可提交；忽略本地升级产物" ;;

    # --- scaffold ------------------------------------------------------------
    "Node.js was not found. Trellis requires Node.js 18+.") UI_T="未找到 Node.js。Trellis 需要 Node.js 18+。" ;;
    "python3 was not found. Trellis requires Python 3.9+.") UI_T="未找到 python3。Trellis 需要 Python 3.9+。" ;;
    "npm was not found. It is required only if Trellis is not already installed.")
      UI_T="未找到 npm。仅在尚未安装 Trellis 时需要它。" ;;
    "installing Trellis with npm install -g @mindfoldhq/trellis")
      UI_T="正在通过 npm install -g @mindfoldhq/trellis 安装 Trellis" ;;
    "Claude Code only") UI_T="仅 Claude Code" ;;
    "No platform flags") UI_T="不传平台参数" ;;
    "Something else") UI_T="其他" ;;
    "type the flags yourself") UI_T="自己输入参数" ;;
    "Trellis platforms") UI_T="Trellis 平台" ;;
    "Trellis platform flags") UI_T="Trellis 平台参数" ;;
    "trellis exists, but trellis --version did not return a version.")
      UI_T="trellis 命令存在，但 trellis --version 没有返回版本号。" ;;
    "Reinstall the Trellis installer with npm install -g @mindfoldhq/trellis?")
      UI_T="用 npm install -g @mindfoldhq/trellis 重新安装 Trellis？" ;;
    "skipping Trellis initialization because the existing trellis command is not reporting a version.")
      UI_T="跳过 Trellis 初始化：现有的 trellis 命令没有报告版本号。" ;;
    "trellis command was not found.") UI_T="未找到 trellis 命令。" ;;
    "Install the Trellis installer with npm install -g @mindfoldhq/trellis?")
      UI_T="用 npm install -g @mindfoldhq/trellis 安装 Trellis？" ;;
    "skipping Trellis initialization because Trellis is not installed.")
      UI_T="跳过 Trellis 初始化：Trellis 未安装。" ;;
    "Trellis developer name") UI_T="Trellis 开发者名称" ;;
    "no Trellis platform flags will be passed") UI_T="不会传递 Trellis 平台参数" ;;
    "skip git init (per --git no)") UI_T="跳过 git init（--git no）" ;;
    "Initialize a git repository?") UI_T="初始化 git 仓库？" ;;
    "skip git init") UI_T="跳过 git init" ;;
    "git was not found; skipping git init") UI_T="未找到 git；跳过 git init" ;;
    "Service / backend") UI_T="服务 / 后端" ;;
    "APIs, datastores, long-running") UI_T="API、数据存储、长期运行" ;;
    "Tool / script") UI_T="工具 / 脚本" ;;
    "small CLIs, utilities") UI_T="小型 CLI、实用工具" ;;
    "Decide later") UI_T="稍后决定" ;;
    "keep both, let the project's AI resolve it") UI_T="两者都保留，让项目的 AI 决定" ;;
    "What kind of project is this?") UI_T="这是什么类型的项目？" ;;
    "Include CC-Cowork-Workflow (Claude Code external executor co-work)?")
      UI_T="包含 CC-Cowork-Workflow（Claude Code 外部执行器协作）？" ;;
    "Include the manual test checklist (Test/templates-test-checklist.html)?")
      UI_T="包含手动测试清单（Test/templates-test-checklist.html）？" ;;
    "Current directory is not empty. Project folder name") UI_T="当前目录不为空。项目文件夹名称" ;;
    "Install and initialize Trellis for this project?") UI_T="为本项目安装并初始化 Trellis？" ;;
    "AGENTS.md keeps every profile block for the project's AI to resolve")
      UI_T="AGENTS.md 保留所有 profile 块，交由项目的 AI 决定" ;;
    "next: edit AGENTS.md with real project guidance") UI_T="下一步：在 AGENTS.md 中写入真实的项目指引" ;;
    "the hub's .gitignore and docs/tasks/ changed; commit them in the hub")
      UI_T="hub 的 .gitignore 和 docs/tasks/ 已更改；请在 hub 中提交" ;;
    "What kind of repository is this?") UI_T="这是什么类型的仓库？" ;;
    "Single repository") UI_T="单一仓库" ;;
    "one project, one git repository") UI_T="一个项目，一个 git 仓库" ;;
    "Hub") UI_T="Hub" ;;
    "documents only; plans the repositories nested inside it") UI_T="只放文档；规划嵌在其中的各个仓库" ;;
    "AGENTS.md assembled for a hub: the hub rules, no profile") UI_T="AGENTS.md 已按 hub 组装：带 hub 规则，不带 profile" ;;
    "next: describe the project in AGENTS.md and docs/wiki/overview.md")
      UI_T="下一步：在 AGENTS.md 和 docs/wiki/overview.md 中描述这个项目" ;;

    *) _i18n_zh_pattern ;;
  esac
  return 0
}

# Messages with a value in them. Order matters where two patterns overlap: the
# specific dry-run forms come before the generic one.
_i18n_zh_pattern() {
  local m=""

  # --- frame and prompts -----------------------------------------------------
  if _i18n_m '^done  (.*)$'; then UI_T="完成  ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^([0-9]+) of ([0-9]+) selected$'; then
    UI_T="已选 ${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; return
  fi

  # --- diagnostics card ------------------------------------------------------
  if _i18n_m '^([0-9]+) nested repositories not ignored$'; then UI_T="${BASH_REMATCH[1]} 个嵌套仓库未被忽略"; return; fi
  if _i18n_m '^of (/.*)$'; then UI_T="属于 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m "^not ignored by the hub's git: (.*) \(add (.*) to \.gitignore\)$"; then
    UI_T="hub 的 git 没有忽略 ${BASH_REMATCH[1]}（请把 ${BASH_REMATCH[2]} 加入 .gitignore）"; return
  fi
  if _i18n_m '^detached at (.*)$'; then UI_T="游离于 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^Project v(.*) / CLI v(.*)$'; then
    UI_T="项目 v${BASH_REMATCH[1]} / CLI v${BASH_REMATCH[2]}"; return
  fi
  if _i18n_m '^CLI v(.*) ready$'; then UI_T="CLI v${BASH_REMATCH[1]} 可用"; return; fi

  # --- the dashboard menu ----------------------------------------------------
  if _i18n_m '^v([^ ,]*), current$'; then UI_T="v${BASH_REMATCH[1]}，已是最新"; return; fi
  # Sync's reveal: "<version>, <summary>", the version optionally "vA -> vB".
  if _i18n_m '^(v[^ ,]*( -> v[^ ,]*)?), (.*)$'; then
    m="${BASH_REMATCH[1]}"
    if [[ "${BASH_REMATCH[3]}" == "everything up to date" ]]; then
      UI_T="${m}，全部已是最新"; return
    fi
    if _i18n_counts "${BASH_REMATCH[3]}"; then UI_T="${m}，${UI_T}"; return; fi
    UI_T="${_I18N_S}"
  fi
  if _i18n_counts "${_I18N_S}"; then return; fi
  if _i18n_m '^applying template set: (.*)$'; then UI_T="应用模板集：${BASH_REMATCH[1]}"; return; fi

  # --- template sync ---------------------------------------------------------
  if _i18n_m '^(.*) exists — \[o\]verwrite / \[t\]emplate / \[s\]kip\?$'; then
    UI_T="${BASH_REMATCH[1]} 已存在 — [o] 覆盖 / [t] 写 .template / [s] 跳过？"; return
  fi
  if _i18n_m '^skip (.*): not present in template dir$'; then
    UI_T="跳过 ${BASH_REMATCH[1]}：模板目录中没有该文件"; return
  fi
  if _i18n_m '^skip (.*): (.*) exists \(kept\)$'; then
    UI_T="跳过 ${BASH_REMATCH[1]}：${BASH_REMATCH[2]} 已存在（保留）"; return
  fi
  if _i18n_m '^skip (.*): not part of this template set \((.*)\)$'; then
    UI_T="跳过 ${BASH_REMATCH[1]}：不属于本模板集（${BASH_REMATCH[2]}）"; return
  fi
  if _i18n_m '^skip existing (.*)$'; then UI_T="跳过已存在的 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^refreshing (.*) \(left over from an unfinished merge\)$'; then
    UI_T="刷新 ${BASH_REMATCH[1]}（上次合并未完成时留下的）"; return
  fi
  if _i18n_m '^copied (.*)$'; then UI_T="已复制 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^created (.*)$'; then UI_T="已创建 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^refreshed (.*) in (.*)$'; then
    UI_T="已刷新 ${BASH_REMATCH[2]} 中的 ${BASH_REMATCH[1]}"; return
  fi
  if _i18n_m '^added (<[A-Z_]+.*>) to (.*)$'; then
    UI_T="已向 ${BASH_REMATCH[2]} 添加 ${BASH_REMATCH[1]}"; return
  fi
  if _i18n_m '^could not add (<[A-Z_]+.*>) to (.*)$'; then
    UI_T="无法向 ${BASH_REMATCH[2]} 添加 ${BASH_REMATCH[1]}"; return
  fi
  if _i18n_m '^could not refresh (.*) in (.*)$'; then
    UI_T="无法刷新 ${BASH_REMATCH[2]} 中的 ${BASH_REMATCH[1]}"; return
  fi
  if _i18n_m '^Template files \((.*)\)$'; then UI_T="模板文件（${BASH_REMATCH[1]}）"; return; fi
  if _i18n_m '^already exists -> (.*)$'; then UI_T="已存在 -> ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^new -> creates (.*)$'; then UI_T="新增 -> 创建 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^creates (.*)$'; then UI_T="创建 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^([0-9]+) blocks?$'; then UI_T="${BASH_REMATCH[1]} 个块"; return; fi
  if _i18n_m '^invalid selection: (.*)$'; then UI_T="无效的选择：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^([0-9]+) files? (was|were) written as <name>\.template beside an existing file\.$'; then
    UI_T="已在 ${BASH_REMATCH[1]} 个现有文件旁写入 <name>.template。"; return
  fi
  if _i18n_m '^([0-9]+) of them are in the old pre-<TAG> format; copy the prompt$'; then
    UI_T="其中 ${BASH_REMATCH[1]} 个是旧的 pre-<TAG> 格式；复制下面分隔线之间的提示词来转换它们："; return
  fi

  # --- toggles ---------------------------------------------------------------
  if _i18n_m '^Archived the workflow file as (.*)$'; then UI_T="已将工作流文件归档为 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^Archived the delegation subagent as (.*)$'; then UI_T="已将委派子 agent 归档为 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^Archived the checklist as (.*)$'; then UI_T="已将测试清单归档为 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^CC-Workflow template not found: (.*)$'; then UI_T="找不到 CC-Workflow 模板：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^CC-Workflow subagent template not found: (.*)$'; then UI_T="找不到 CC-Workflow 子 agent 模板：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^Delegation subagent template not found: (.*)$'; then UI_T="找不到委派子 agent 模板：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^(Test|test) checklist template not found: (.*)$'; then UI_T="找不到测试清单模板：${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^Trellis integration block not found: (.*)$'; then UI_T="找不到 Trellis 集成块：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^CC-Workflow enabled \((.*) variant\) and referenced from CLAUDE\.md\.$'; then
    UI_T="CC-Workflow 已启用（${BASH_REMATCH[1]} 版本），并已在 CLAUDE.md 中引用。"; return
  fi

  # --- Trellis ---------------------------------------------------------------
  if _i18n_m '^Adding platform (.*) via Trellis\.\.\.$'; then UI_T="正在通过 Trellis 添加平台 ${BASH_REMATCH[1]}..."; return; fi
  if _i18n_m '^Trellis is already at v(.*); an update would only re-scan$'; then
    UI_T="Trellis 已是 v${BASH_REMATCH[1]}；更新只会重新扫描，并询问你改过的文件。"; return
  fi
  if _i18n_m '^Updating Trellis configuration in (.*)\.\.\.$'; then UI_T="正在更新 ${BASH_REMATCH[1]} 中的 Trellis 配置..."; return; fi
  if _i18n_m '^installed Trellis: (.*)$'; then UI_T="已安装 Trellis：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^found Trellis: (.*)$'; then UI_T="找到 Trellis：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^initializing Trellis in (.*)$'; then UI_T="正在 ${BASH_REMATCH[1]} 中初始化 Trellis"; return; fi
  if _i18n_m '^using Trellis developer name from \$DEVELOPER_NAME: (.*) \(override with --developer-name\)$'; then
    UI_T="使用 \$DEVELOPER_NAME 中的 Trellis 开发者名称：${BASH_REMATCH[1]}（可用 --developer-name 覆盖）"; return
  fi
  if _i18n_m '^Node\.js (.*) found\. Trellis requires Node\.js 18\+\.$'; then
    UI_T="找到 Node.js ${BASH_REMATCH[1]}。Trellis 需要 Node.js 18+。"; return
  fi
  if _i18n_m '^trellis did not create (.*); skipping deny-rule merge$'; then
    UI_T="trellis 没有创建 ${BASH_REMATCH[1]}；跳过 deny 规则合并"; return
  fi
  if _i18n_m '^python3 not found; skipping deny-rule merge into (.*)$'; then
    UI_T="未找到 python3；跳过向 ${BASH_REMATCH[1]} 合并 deny 规则"; return
  fi
  if _i18n_m '^merged secret-deny rules into (.*)$'; then UI_T="已将密钥 deny 规则合并进 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^failed to merge deny rules into (.*)$'; then UI_T="向 ${BASH_REMATCH[1]} 合并 deny 规则失败"; return; fi

  # --- upgrade controls ------------------------------------------------------
  if _i18n_m '^last tool v(.*); ([0-9]+) pending review\(s\)$'; then
    UI_T="上次运行 v${BASH_REMATCH[1]}；${BASH_REMATCH[2]} 个待审阅"; return
  fi
  if _i18n_m '^([0-9]+) pending review\(s\); deleting \.template files does not resolve them\.$'; then
    UI_T="${BASH_REMATCH[1]} 个待审阅；删除 .template 文件不会完成审阅。"; return
  fi
  if _i18n_m '^target: (.*), merge; upstream: (.*)$'; then UI_T="目标：${BASH_REMATCH[1]}，内容合并；上游：${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^target: (.*), convert; upstream: (.*)$'; then UI_T="目标：${BASH_REMATCH[1]}，格式转换；上游：${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^current fingerprint: (.*)$'; then UI_T="当前指纹：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^reviewed fingerprint: (.*)$'; then UI_T="已审阅的指纹：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^resolve after review: (.*)$'; then UI_T="审阅后确认：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^old upstream file \(block bases may be newer\): (.*)$'; then
    UI_T="旧的上游文件（块的基线可能更新）：${BASH_REMATCH[1]}"; return
  fi
  if _i18n_m '^old upstream (<.*>): (.*)$'; then UI_T="旧的上游 ${BASH_REMATCH[1]}：${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^Review this file and its frozen template before acknowledging: (.*)$'; then
    UI_T="确认前先审阅该文件及其冻结的模板：${BASH_REMATCH[1]}"; return
  fi
  if _i18n_m '^resolved (.*): (.*); run --apply to check for later updates$'; then
    UI_T="已确认 ${BASH_REMATCH[1]}：${BASH_REMATCH[2]}；运行 --apply 检查后续更新"; return
  fi
  if _i18n_m '^recovery snapshot: (.*)$'; then UI_T="恢复快照：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^restored (.*)$'; then UI_T="已恢复 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^(pause-updates|resume-updates): saved; no template files changed$'; then
    UI_T="${BASH_REMATCH[1]}：已保存；没有改动模板文件"; return
  fi
  if _i18n_m '^(self-manage|follow): (.*); pending reviews still require explicit acknowledgement$'; then
    UI_T="${BASH_REMATCH[1]}：${BASH_REMATCH[2]}；待审阅项仍需显式确认"; return
  fi
  if _i18n_m '^corrupt upstream base object: (.*)$'; then UI_T="上游基线对象已损坏：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^hand-out is not a regular file: (.*)$'; then UI_T=".template 不是普通文件：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^invalid upstream block structure: (.*)$'; then UI_T="上游块结构无效：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^managed path is not a regular file: (.*)$'; then UI_T="受管路径不是普通文件：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^refusing symlink: (.*)$'; then UI_T="拒绝符号链接：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^unknown block: (.*)$'; then UI_T="未知的块：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^unknown managed file: (.*)$'; then UI_T="未知的受管文件：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^unsupported state schema: (.*); use a newer vibe-init$'; then
    UI_T="不支持的状态 schema：${BASH_REMATCH[1]}；请使用更新版本的 vibe-init"; return
  fi

  # --- git, state, scaffold --------------------------------------------------
  if _i18n_m '^skip git init: (.*) is already a git repository$'; then
    UI_T="跳过 git init：${BASH_REMATCH[1]} 已经是 git 仓库"; return
  fi
  if _i18n_m '^initializing git repository in (.*)$'; then UI_T="正在 ${BASH_REMATCH[1]} 中初始化 git 仓库"; return; fi
  if _i18n_m "^note: (.*) is not a git repository; run 'git init' yourself if you want version control \(--apply does not\)$"; then
    UI_T="提示：${BASH_REMATCH[1]} 不是 git 仓库；如需版本控制请自行运行 'git init'（--apply 不会运行）"; return
  fi
  if _i18n_m '^added (.*) to \.gitignore$'; then UI_T="已将 ${BASH_REMATCH[1]} 加入 .gitignore"; return; fi
  if _i18n_m '^added (.*) to (.*)$'; then UI_T="已将 ${BASH_REMATCH[1]} 加入 ${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^inside the hub (.*): setting this up as one of its repositories$'; then
    UI_T="位于 hub ${BASH_REMATCH[1]} 之内：按它的成员仓库初始化"; return
  fi
  if _i18n_m '^(.*) exists without the hub exclusion; add this entry by hand:$'; then
    UI_T="${BASH_REMATCH[1]} 已存在，但没有排除 hub 的规则；请手动加入这一项："; return
  fi
  if _i18n_m '^could not keep the handed-out template for (.*)$'; then UI_T="无法保留 ${BASH_REMATCH[1]} 的模板副本"; return; fi
  if _i18n_m '^could not create (.*); skipping state record$'; then UI_T="无法创建 ${BASH_REMATCH[1]}；跳过状态记录"; return; fi
  if _i18n_m '^template set: (.*)$'; then UI_T="模板集：${BASH_REMATCH[1]}"; return; fi
  if _i18n_m "^AGENTS\.md assembled with the '(.*)' profile$"; then UI_T="AGENTS.md 已按 '${BASH_REMATCH[1]}' profile 组装"; return; fi
  if _i18n_m '^(.*): template not found at (.*); writing a minimal fallback stub$'; then
    UI_T="${BASH_REMATCH[1]}：在 ${BASH_REMATCH[2]} 找不到模板；写入最小占位内容"; return
  fi
  if _i18n_m '^template (common dir|blocks dir|blocks) not found(:| under) (.*); falling back to built-in placeholders$'; then
    UI_T="找不到模板目录：${BASH_REMATCH[3]}；改用内置占位内容"; return
  fi

  # --- dry-run ---------------------------------------------------------------
  if _i18n_m '^dry-run: copy (.*) -> (.*)$'; then UI_T="dry-run：复制 ${BASH_REMATCH[1]} -> ${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^dry-run: mv (.*) -> (.*)$'; then UI_T="dry-run：移动 ${BASH_REMATCH[1]} -> ${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^dry-run: remove retired (.*) from (.*)$'; then UI_T="dry-run：从 ${BASH_REMATCH[2]} 移除已退役的 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^dry-run: resolve (.*) as (.*)$'; then UI_T="dry-run：把 ${BASH_REMATCH[1]} 确认为 ${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^dry-run: restore (.*)$'; then UI_T="dry-run：恢复 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^dry-run: set (.*) to (.*)$'; then UI_T="dry-run：把 ${BASH_REMATCH[1]} 设为 ${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^dry-run: refresh (.*) in (.*)$'; then UI_T="dry-run：刷新 ${BASH_REMATCH[2]} 中的 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^dry-run: remove the CC-Workflow block from (.*)$'; then UI_T="dry-run：从 ${BASH_REMATCH[1]} 移除 CC-Workflow 块"; return; fi
  if _i18n_m '^dry-run: reference the CC-Workflow block from (.*)$'; then UI_T="dry-run：在 ${BASH_REMATCH[1]} 中引用 CC-Workflow 块"; return; fi
  if _i18n_m '^dry-run: remove (<INTEGRATION .*>) from (.*)$'; then UI_T="dry-run：从 ${BASH_REMATCH[2]} 移除 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^dry-run: append (<INTEGRATION .*>) to (.*)$'; then UI_T="dry-run：向 ${BASH_REMATCH[2]} 追加 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^dry-run: record ([0-9]+) content hashes in (.*)$'; then
    UI_T="dry-run：在 ${BASH_REMATCH[2]} 中记录 ${BASH_REMATCH[1]} 个内容哈希"; return
  fi
  if _i18n_m '^dry-run: merge permissions\.deny from the template set into (.*)$'; then
    UI_T="dry-run：把模板集的 permissions.deny 合并进 ${BASH_REMATCH[1]}"; return
  fi
  if _i18n_m '^dry-run: add (.*) to (.*)$'; then UI_T="dry-run：将 ${BASH_REMATCH[1]} 加入 ${BASH_REMATCH[2]}"; return; fi
  if _i18n_m '^dry-run: write (.*)$'; then UI_T="dry-run：写入 ${BASH_REMATCH[1]}"; return; fi
  if _i18n_m '^dry-run:(.*)$'; then UI_T="dry-run：${BASH_REMATCH[1]# }"; return; fi

  # A flattened sync label, "<word> (<detail>)": translate the halves, but only
  # when the word is one this catalog knows, so a platform list with its own
  # parenthesised note is not mangled.
  if _i18n_m '^(.+) \(([^()]*)\)$'; then
    m="${BASH_REMATCH[1]}"
    local detail="${BASH_REMATCH[2]}" word_zh=""
    _i18n_zh "${m}"
    if [[ "${UI_T}" != "${m}" ]]; then
      word_zh="${UI_T}"
      _i18n_zh "${detail}"
      UI_T="${word_zh}（${UI_T}）"
      return
    fi
    UI_T="${m} (${detail})"
  fi
  return 0
}
