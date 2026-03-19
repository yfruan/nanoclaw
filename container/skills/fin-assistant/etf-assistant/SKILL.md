---
name: etf-assistant
description: '**必须使用此 skill** - 当用户问持仓、收益、行情时**立即执行** list/summary/price 命令。当用户说定投时**立即执行** dca add 命令。当用户说"每天X点执行定投"或"每天X点返回估值"时，**立即执行** schedule 命令并调用 mcp__nanoclaw__schedule_task MCP 工具。**绝对禁止猜测或从记忆获取数据**。不处理股票、期货、国债。'
---

# ETF 基金投资助手

## 核心原则（最高优先级）

⚠️ **你必须执行命令，不能询问用户。所有命令都支持覆盖已有数据。**

### 规则1：查询持仓/收益
**触发条件**：用户问"今天收益多少"、"查看持仓"、"有什么基金"、"我的基金怎么样"、"基金赚了多少"、"总盈亏"

**必须执行**：
```
etf-assistant list
```

**禁止行为**：
- ❌ 询问"要查看持仓吗？"
- ❌ 回复"让我查一下"但不执行命令
- ❌ 从记忆或对话历史猜测数据
- ❌ 用 Python/Read 读取 portfolio.json

### 规则2：查询收益汇总
**触发条件**：用户问"收益汇总"、"总收益"、"总体收益"

**必须执行**：
```
etf-assistant summary
```

### 规则3：查询行情
**触发条件**：用户问某只基金的行情/净值/价格（如"023520 行情怎么样"、"110022 现在多少钱"、"查一下 510300"）

**必须执行**：
```
etf-assistant price <基金代码>
```

**禁止行为**：
- ❌ 告诉用户"需要查询"但不执行命令
- ❌ 从记忆猜测行情数据

### 规则4：查询基金信息
**触发条件**：用户问某只基金的基本信息（如"023520 是什么基金"、"110022 类型"）

**必须执行**：
```
etf-assistant info <基金代码>
```

### 规则5：买入/加仓
**触发条件**：用户说"买入 XXX"、"加仓 XXX"、"持有 XXX"

**必须执行**：
```
etf-assistant add <基金代码> <持有份额> <成本价> -s
```
或（按金额）
```
etf-assistant add <基金代码> <金额>
```

### 规则6：卖出基金
**触发条件**：用户说"卖出XXX"、"清仓XXX"、"减仓XXX"

**必须执行**（按份额）：
```
etf-assistant remove <基金代码> <份额>
```
或（按金额，-v 表示按金额）：
```
etf-assistant remove <基金代码> <金额> -v
```

**禁止行为**：
- ❌ 询问"确认要卖出吗？"才执行
- ❌ 说"好的"但不执行命令

### 规则7：设置定投
**触发条件**：用户说"设置定投"、"定投"、"每日定投"、"每周定投"

**必须执行**：
```
etf-assistant dca add <基金代码> <金额> daily
```
或每周：
```
etf-assistant dca add <基金代码> <金额> weekly
```

### 规则8：设置ETF对应代码
**触发条件**：用户说"设置ETF代码"、"绑定ETF"、"更新ETF代码"

**必须执行**：
```
etf-assistant update-etf <基金代码> <ETF代码>
```
示例：`etf-assistant update-etf 023520 160000`

### 规则9：创建定时任务（自动执行定投）
**触发条件**：用户说"每天X点执行定投"（X可以是8、9、10等）、"设置定时定投"、"自动定投"

**执行步骤**（必须按顺序执行）：

**第1步：运行命令**
- 默认（9点）：`etf-assistant dca schedule`
- 自定义时间：`etf-assistant dca schedule <小时>`

例如用户说"每天8点执行定投"，运行：
```bash
etf-assistant dca schedule 8
```

**第2步：检测 MCP 标记并调用工具**
当命令输出包含 `__NANOCLAW_SCHEDULE_TASK__` 时，**必须立即**调用 MCP 工具：

1. 提取参数：
   - `prompt=` 后面的内容 → prompt 参数
   - `schedule_type=` 后面的内容 → schedule_type 参数
   - `schedule_value=` 后面的内容 → schedule_value 参数
   - `context_mode=` 后面的内容 → context_mode 参数

2. 调用工具 `mcp__nanoclaw__schedule_task`，传入上述4个参数

**第3步：验证结果**
- 如果 MCP 返回类似 "Task task-xxx scheduled: cron - 0 9 * * 1-5"，说明成功
- 如果没有返回 task ID，说明失败，需要重试

**示例**：
```
命令输出:
__NANOCLAW_SCHEDULE_TASK__
prompt=etf-assistant dca check
schedule_type=cron
schedule_value=0 9 * * 1-5
context_mode=isolated

调用 MCP:
mcp__nanoclaw__schedule_task(
  prompt="etf-assistant dca check",
  schedule_type="cron",
  schedule_value="0 9 * * 1-5",
  context_mode="isolated"
)
```

**严重禁止**：
- ❌ **绝对禁止**自己编造回复
- ❌ **绝对禁止**只说"好的"但不执行命令和 MCP
- ❌ **绝对禁止**忽略 MCP 标记

### 规则10：创建自定义定时任务
**触发条件**：用户说"每天X点返回估值"、"每天X点返回收益"、"每天X点查看持仓"

**执行步骤**：

**第1步：识别时间和操作**
- 从用户消息中提取数字（如"13点"→13）
- "返回估值"、"收益汇总" → summary
- "查看持仓" → list

**第2步：运行命令**
```bash
etf-assistant schedule custom <时间> <操作>
```

例如：
```bash
etf-assistant schedule custom 13 summary   # 每天13点收益汇总
etf-assistant schedule custom 22 list      # 每天22点持仓检查
```

**第3步：检测 MCP 标记并调用工具**
与规则10相同，检测 `__NANOCLAW_SCHEDULE_TASK__` 并调用 `mcp__nanoclaw__schedule_task`

### 规则11：查看/取消DCA计划
**触发条件**：用户说"查看定投"、"定投列表"、"取消定投"（注意：这是DCA计划，不是定时任务）

**必须执行**（查看）：
```
etf-assistant dca list
```
**必须执行**（取消）：
```
etf-assistant dca remove <基金代码>
```

### 规则12：取消定时任务
**触发条件**：用户说"取消定时任务"、"删除定时任务"、"取消8点定投"、"取消13点估值"

**注意**：这与规则12不同。规则12只删除 DCA 计划数据，不删除定时任务。

**执行步骤**：

**第1步：获取任务列表**
调用 MCP 工具获取当前定时任务：
```
mcp__nanoclaw__list_tasks
```

**第2步：匹配要取消的任务**
从返回的任务列表中找到匹配的任务：
- "取消8点定投" → 找 prompt 包含 "dca check" 或时间包含 "8" 的任务
- "取消13点估值" → 找 prompt 包含 "summary" 且时间包含 "13" 的任务

**第3步：取消任务**
调用 MCP 工具取消任务：
```
mcp__nanoclaw__cancel_task(task_id="任务ID")
```

**示例**：
```
用户: 取消8点定投定时任务

你: (调用 mcp__nanoclaw__list_tasks)
返回: [{"id":"task-xxx","prompt":"etf-assistant dca check","schedule_value":"0 8 * * 1-5"}]

你: (调用 mcp__nanoclaw__cancel_task(task_id="task-xxx"))
返回: Task task-xxx cancellation requested.

你: 已取消 8:00 的定时任务
```

### 规则13：命令执行失败
**触发条件**：命令执行失败（网络超时、基金代码不存在、参数错误等）

**处理方式**：
- **询问用户**，告诉用户具体错误信息
- **禁止**自己猜测或尝试修复
- 示例：网络超时 → "抱歉，查询超时，请稍后重试或换个基金代码"

---

## 流程示例

### 查询持仓
```
用户: 今天收益多少
你: $ etf-assistant list
输出: [持仓列表]
你: 您的基金今天...
```

### 查询行情
```
用户: 023520 行情怎么样
你: $ etf-assistant price 023520
输出: [行情数据]
你: 023520 当前价格...
```

### 卖出基金
```
用户: 卖出 023520 100份
你: $ etf-assistant remove 023520 100
输出: 已卖出 023520: 100份
```

---

## 意图识别表

| 用户意图 | 必须执行的命令 | 说明 |
|----------|----------------|------|
| 查询持仓/收益 | `etf-assistant list` | 禁止猜测 |
| 收益汇总 | `etf-assistant summary` | 总体收益 |
| 买入/加仓 | `etf-assistant add <code> <份额> <成本> -s` | -s 覆盖已有 |
| 卖出/清仓 | `etf-assistant remove <code> <份额>` 或 `<金额> -v` | 禁止询问 |
| 查询行情 | `etf-assistant price <code>` | 禁止猜测 |
| 查询基金信息 | `etf-assistant info <code>` | 基金类型等 |
| 设置定投 | `etf-assistant dca add <code> <金额> daily/weekly` | |
| 查看定投列表 | `etf-assistant dca list` | |
| 取消定投 | `etf-assistant dca remove <code>` | 删除DCA计划数据 |
| 取消定时任务 | MCP list_tasks + cancel_task | 删除IPC定时任务 |
| 创建定时任务 | `etf-assistant dca schedule` → **必须调用 MCP** | 每天自动执行 |
| 设置ETF代码 | `etf-assistant update-etf <code> <etf_code>` | 绑定ETF联接对应的ETF |
| 对比ETF | `etf-assistant compare <code1> <code2>` | |
| 计算定投收益 | `etf-assistant calc <code> <金额> <年限>` | |

---

## 严重错误（绝对禁止）

1. ❌ 询问用户"要添加吗？"、"确认吗？"
2. ❌ 从对话历史/记忆猜测数据
3. ❌ 用 Python/Read 读取 portfolio.json
4. ❌ 回复"让我查一下"但不执行命令
5. ❌ 说"需要查询行情"但不执行 price 命令
6. ❌ 命令失败时自己猜测或尝试修复
