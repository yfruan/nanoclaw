---
name: skill-tester
description: 通用测试框架 - 在 Apple Container 内运行端到端测试，支持 MCP 工具调用
---

# Skill Tester - 端到端测试框架

在 Apple Container 内运行测试，支持 MCP 工具调用。

## 功能特性

- **容器内测试** - 在 Apple Container 内执行测试
- **MCP 可用** - 可以调用图像识别等 MCP 工具
- **真实 API** - 使用真实东方财富 API 验证功能
- **测试隔离** - 使用独立的 portfolio.test.json
- **测试报告** - 汇总通过/失败数量

## 架构

```
主机 skill-tester
    │
    ├── 1. 启动 Apple Container
    ├── 2. 复制测试用例到容器
    ├── 3. 容器内执行测试
    │       └── 可以调用 MCP 工具
    └── 4. 返回测试结果
```

## 测试用例格式

### 文本命令测试

```json
{
  "name": "etf-price-002610",
  "group": "etf-assistant",
  "command": "etf-assistant price 002610",
  "expect": {
    "contains": "ETF联接"
  },
  "timeout": 30
}
```

### 图像识别测试

```json
{
  "name": "image-fund-002610",
  "group": "etf-assistant",
  "type": "image",
  "image": "tests/images/002610.jpg",
  "recognition": {
    "code": "002610",
    "name": "博时黄金ETF联接A",
    "shares": 15500.27,
    "cost_price": 3.57
  },
  "command": "etf-assistant add {code} {shares} {cost_price} -s",
  "expect": {
    "contains": "已添加持仓"
  }
}
```

## 验证方式

| 验证类型 | 说明 |
|---------|------|
| `contains` | 输出包含指定字符串 |
| `regex` | 输出匹配正则表达式 |
| `exit_code` | 命令退出码 |

## 使用方法

### 列出测试用例

```bash
skill-tester list <skill>
skill-tester list etf-assistant
```

### 运行测试

```bash
# 运行所有测试（启动容器，在容器内执行）
skill-tester run all <skill>
skill-tester run all etf-assistant

# 运行单个测试
skill-tester run <skill> <测试名称>
skill-tester run etf-assistant etf-info-002610
```

## 测试用例位置

```
container/skills/fin-assistant/etf-assistant/
├── SKILL.md
├── etf-assistant.sh
└── tests/
    ├── run.sh           # 容器内测试运行器
    ├── useCase.json    # 测试用例
    ├── image.json       # 图像测试用例
    └── images/
        └── 002610.jpg
```

## 测试隔离

- 生产数据: `groups/fin-assistant/portfolio.json`
- 测试数据: `groups/fin-assistant/portfolio.test.json`

容器内通过环境变量 `PORTFOLIO_FILE` 使用测试数据。

## 示例

### 测试 etf-assistant

```bash
# 列出可用测试
skill-tester list etf-assistant

# 运行所有测试（在容器内）
skill-tester run all etf-assistant
```

### 输出报告

```
========================================
       运行测试: etf-assistant
========================================
启动测试容器...
容器已启动: nanoclaw-test-12345

========================================
         测试报告
========================================
测试模式: 使用 /workspace/group/fin-assistant/portfolio.test.json
Running: etf-info-002610
✓ etf-info-002610 [2s]
Running: etf-price-510300
✓ etf-price-510300 [1s]
...
----------------------------------------
总计: 15 | 通过: 14 | 失败: 1
========================================
停止测试容器...
容器已清理
```

## 图像测试

图像测试需要在 Agent 上下文中运行，因为需要调用 MCP 工具。

```bash
# 在 Agent 中运行图像测试
# 1. 加载 skill-tester
# 2. skill-tester 启动容器
# 3. Agent 调用 MCP 工具识别图像
# 4. Agent 用识别结果执行命令
# 5. 验证结果
```
