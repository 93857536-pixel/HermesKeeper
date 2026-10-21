# HermesKeeper

菜单栏小工具：**hermes agent 在跑任务时不让 Mac 睡觉（合盖也不睡），任务结束 5 分钟后如果没人操作就自动熄屏睡眠。**

## 为什么需要它

笔记本合盖默认就是睡眠，会把正在跑的 hermes 任务（长构建、cron、批量处理）直接掐断。
`caffeinate` 之类只能防「空闲睡眠」，**挡不住合盖睡眠**——只有 `pmset -a disablesleep`
这一条路。HermesKeeper 做的就是：按 hermes 的真实忙闲状态，自动开关这个开关。

## 判定逻辑（实测过的信号）

| 信号 | 来源 | 说明 |
|---|---|---|
| 正在干活 | `~/.hermes/state.db` 的 mtime | hermes 每个回合/工具调用都会写库，是最可靠的「正在工作」信号 |
| 进行中任务数 | `~/.hermes/gateway_state.json` → `active_agents` | 只在回合边界写入，作为辅助 |
| gateway 是否活着 | 同文件的 `pid` + `kill(pid,0)` | 进程没了就一律按「不忙」处理 |
| 合盖 | IOKit `AppleClamshellState == Yes` | 只读，无需 root |
| 有人在用 | IOKit `HIDIdleTime`（纳秒） | 键盘/触控板有输入就算「人在」 |

状态机：

```
hermes 忙            → SleepDisabled=1   硬阻止睡眠（合盖也醒着，任务继续跑）
忙完 < 5 分钟        → SleepDisabled=1   宽限期，继续保活
宽限期内有人操作      → SleepDisabled=0   交回系统默认睡眠策略
宽限过期 + 无人操作   → SleepDisabled=0 + pmset sleepnow   自动熄屏睡眠
一直空闲              → SleepDisabled=0   系统自己管
```

「有人在用」= 最近 60 秒有键鼠输入 **或** 盖子开着。所以：
- 合盖用外接键盘 → 算人在，不强制睡眠
- 盖子打开 → 不强制睡眠（系统自己熄灭屏幕）
- **合盖且 5 分钟没人碰 → 自动睡眠**（就是你提的规则）

## 安装

本仓库提供 GitHub Release 中的预构建 dmg（macOS 13+，ad-hoc 签名）。
首次打开若被 Gatekeeper 拦截：右键 → 打开，或 `sudo xattr -dr com.apple.quarantine /Applications/HermesKeeper.app`。

从源码构建：

```bash
git clone https://github.com/93857536-pixel/HermesKeeper
cd HermesKeeper
bash build_app.sh                 # 产物: dist/HermesKeeper.app
sudo cp -R dist/HermesKeeper.app /Applications/
open /Applications/HermesKeeper.app
```

启动 / 停止：

```bash
open /Applications/HermesKeeper.app
osascript -e 'tell application "HermesKeeper" to quit'   # 退出会自动把 SleepDisabled 复位为 0
```

## 菜单栏

图标随状态变化：`bolt.fill`(保活中) / `timer`(宽限倒计时) / `moon.zzz`(空闲)

- 立即保持唤醒 / 解除睡眠阻止 / 立即睡眠
- 任务结束后 5 分钟无操作自动熄屏（默认开，可关）
- hermes 空闲时也强制睡眠（默认关）
- 登录时启动（写/删 LaunchAgent）
- 设置…（查看当前参数）

## 配置

`~/Library/Application Support/HermesKeeper/config.json`

```json
{
  "graceSeconds": 300,            // 任务结束后宽限多少秒（默认 5 分钟）
  "pollInterval": 10,             // 轮询间隔秒
  "userPresenceWindow": 60,       // 多少秒内有键鼠输入算「人在」
  "autoSleepOnGraceExpiry": true, // 宽限过后自动熄屏
  "forceSleepWhenIdle": false,    // hermes 空闲也强制睡（默认关）
  "hermesHome": null              // null = ~/.hermes
}
```

改完重启 app 生效。

## 依赖与安全

- 需要 root 权限执行 `sudo pmset`。app 一律用 `sudo -n pmset ...` 调用（无密码环境下成功；若你的 sudo 需要输密码，则会快速失败并跳过该操作，不会卡住界面）。想完整使用，请在 `/etc/sudoers.d/` 为你的用户加一条 pmset 的 NOPASSWD 规则，例如：
  `你的用户名 ALL=(root) NOPASSWD: /usr/bin/pmset`
- **退出 app 时一定会把 SleepDisabled 复位为 0**，避免留下「永不睡眠」的坑。
- 启动时会做一次「状态对账」：残留的 disablesleep=1 若 hermes 不忙就释放，busy 就补上。

## 日志

`~/Library/Logs/HermesKeeper.log`（自动截断到 ~200KB）

## 自测（不用真的睡眠）

```bash
# 造一个假的 hermes 目录，dry-run 跑一遍状态机
mkdir -p /tmp/hk/.hermes && touch /tmp/hk/.hermes/state.db
echo '{"pid":1,"gateway_state":"running","active_agents":0}' > /tmp/hk/.hermes/gateway_state.json
HERMES_KEEPER_HOME=/tmp/hk/.hermes HERMES_KEEPER_GRACE=8 \
HERMES_KEEPER_POLL=2 HERMES_KEEPER_ACTIVITY=4 HERMES_KEEPER_DRYRUN=1 \
./.build/release/HermesKeeper --selftest 18
```

`HERMES_KEEPER_DRYRUN=1` 只打日志，不碰真实电源状态。

## 已知限制

- 合盖 + 电池 + 没有任何外接设备时，`disablesleep` 仍会让机器保持全速运行直到电池耗尽——这是需求本身的性质，不是 bug。需要长时间合盖跑任务时建议插电。
- `disablesleep` 是机器级开关（不是 per-app 断言），所以 app 运行期间它被占用；退出即释放。
- ad-hoc 签名（无 Apple 开发者证书）；如系统提示「无法验证」，右键 → 打开即可。
