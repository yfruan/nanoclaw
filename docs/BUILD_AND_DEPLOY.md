# NanoClaw 构建与部署指南

本文档记录 NanoClaw 的构建、部署和网络配置步骤。

## 目录

1. [环境要求](#环境要求)
2. [构建容器镜像](#构建容器镜像)
3. [网络配置](#网络配置)
4. [配置环境变量](#配置环境变量)
5. [启动服务](#启动服务)
6. [故障排查](#故障排查)

---

## 环境要求

- macOS (Apple Silicon)
- Node.js 22+
- Apple Container 或 Docker

---

## 构建容器镜像

### 方法一：使用 Docker（推荐国内用户）

```bash
# 1. 构建镜像
docker build -t nanoclaw-agent:latest ./container/

# 2. 导出为 tar
docker save -o /tmp/nanoclaw-agent-latest.tar nanoclaw-agent:latest

# 3. 导入到 Apple Container
container image load -i /tmp/nanoclaw-agent-latest.tar
```

### 方法二：直接使用 Apple Container

```bash
# 需要先预拉取基础镜像（解决网络问题）
docker pull node:22-slim
docker save -o /tmp/node-22-slim.tar node:22-slim
container image load -i /tmp/node-22-slim.tar

# 然后构建
./container/build.sh
```

### 镜像版本说明

| 版本 | 标签 | 说明 |
|------|------|------|
| 最新稳定版 | `nanoclaw-agent:latest` | 包含 IPv4 DNS 优先配置 |

> **注意**：2026-02-13 之后的构建版本已包含 `NODE_OPTIONS=--dns-result-order=ipv4first`，支持容器访问外网。

---

## 网络配置

### Apple Container NAT 设置

容器默认无法访问外网，需要配置 NAT：

```bash
# 1. 启用 IP 转发
sudo sysctl -w net.inet.ip.forwarding=1

# 2. 配置 NAT（en0 替换为你的网络接口）
echo "nat on en0 from 192.168.64.0/24 to any -> (en0)" | sudo pfctl -ef -
```

### 持久化配置

**IP 转发** - 添加到 `/etc/sysctl.conf`:
```
net.inet.ip.forwarding=1
```

**NAT 规则** - 添加到 `/etc/pf.conf`:
```
nat on en0 from 192.168.64.0/24 to any -> (en0)
```

### IPv4 DNS 优先

在 `container/Dockerfile` 中添加：
```dockerfile
ENV NODE_OPTIONS=--dns-result-order=ipv4first
```

这是必需的，因为默认 DNS 返回 IPv6 地址，但 NAT 只支持 IPv4。

---

## 配置环境变量

编辑 `.env` 文件：

```bash
# 消息通道
MESSENGER=feishu          # 或 whatsapp, telegram
ASSISTANT_NAME=awu        # 触发词

# Feishu 配置（如果使用 Feishu）
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=xxx

# API 配置（支持 MiniMax）
ANTHROPIC_API_KEY=sk-api-xxx
ANTHROPIC_BASE_URL=https://api.minimaxi.com/anthropic
```

### 容器环境变量

NanoClaw 会自动将以下变量注入到容器中：
- `ANTHROPIC_API_KEY`
- `ANTHROPIC_BASE_URL`

---

## 启动服务

```bash
# 构建项目
npm run build

# 启动服务
launchctl load ~/Library/LaunchAgents/com.nanoclaw.plist

# 查看日志
tail -f logs/nanoclaw.log
```

---

## 故障排查

### 容器无法联网

1. 检查 IP 转发：`sysctl net.inet.ip.forwarding`（应为 1）
2. 检查 NAT 规则：`sudo pfctl -s nat`
3. 验证 DNS 解析：
   ```bash
   container run --rm --entrypoint /bin/sh nanoclaw-agent:latest -c "curl -s https://api.minimaxi.com -o /dev/null -w '%{http_code}'"
   ```

### 天气查询失败

如果返回 "抱歉，由于网络限制"，需要：
1. 确认使用了 `nanoclaw-agent:latest`（2026-02-13 之后的版本）
2. 检查 `NODE_OPTIONS=--dns-result-order=ipv4first` 是否设置：
   ```bash
   container run --rm --entrypoint /bin/sh nanoclaw-agent:latest -c "printenv NODE_OPTIONS"
   ```

### 镜像问题

如果镜像标签混乱，可以强制重建：
```bash
# 清理旧容器
container prune

# 重新构建（使用新标签）
docker build -t nanoclaw-agent:v4 ./container/
docker save -o /tmp/nanoclaw-agent-v4.tar nanoclaw-agent:v4
container image load -i /tmp/nanoclaw-agent-v4.tar

# 更新 config.ts 使用新标签
# CONTAINER_IMAGE = 'nanoclaw-agent:v4'
```

---

## 常用命令

```bash
# 查看运行中的容器
container ls

# 查看服务状态
launchctl list | grep nanoclaw

# 重启服务
launchctl unload ~/Library/LaunchAgents/com.nanoclaw.plist
launchctl load ~/Library/LaunchAgents/com.nanoclaw.plist

# 测试容器网络
container run --rm --entrypoint /bin/sh nanoclaw-agent:latest -c "curl -s https://wttr.in/Shanghai"
```
