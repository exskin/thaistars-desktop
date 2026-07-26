# -*- coding: utf-8 -*-
"""
Claude Code hook 调用它来更新桌宠状态。
用法（由 hooks 自动调用）：  python3 pet_status.py <event>

<event> 取值对应 Claude Code 的 hook 事件名，映射到桌宠状态：
  userpromptsubmit -> thinking   (你刚发了消息，她开始想)
  pretooluse       -> working    (正在调某个工具，读 stdin 拿工具名)
  posttooluse      -> thinking   (工具跑完，继续想下一步)
  notification     -> waiting    (需要你回话/授权)
  stop             -> done       (这一轮答完了)
  subagentstop      -> done      (子任务结束)

  真正的 idle（发呆）不是任何 hook 事件触发的，是桌宠那边看 ts 判断：
  超过 STALE_SEC（目前 10 分钟）没有新事件，才会从 done/其他状态退回 idle。

状态文件是多专案结构：{"projects": {"<项目名>": {"status","tool","ts"}, ...}}
项目名取自 hook payload 里的 cwd 目录名（同一目录下多个会话会互相覆盖，这是已知简化）。

设计原则：绝不报错、绝不卡住 Claude Code —— 出任何问题都静默 exit 0。
"""

import json
import os
import sys
import time

STATUS_FILE = os.path.expanduser("~/.claude/claude_pet_status.json")

EVENT_TO_STATUS = {
    "userpromptsubmit": "thinking",
    "pretooluse": "working",
    "posttooluse": "thinking",
    "notification": "waiting",
    "permissionrequest": "waiting",  # 弹 allow 询问的专属事件（Notification 在桌面版不一定触发）
    "stop": "done",
    "subagentstop": "done",  # 子任务结束≠主线还在忙，若接着真有动作会被后续事件覆盖
}


def main():
    event = (sys.argv[1] if len(sys.argv) > 1 else "").lower()
    status = EVENT_TO_STATUS.get(event, "idle")

    payload = {}
    try:
        raw = sys.stdin.read()
        if raw.strip():
            payload = json.loads(raw)
    except Exception:
        payload = {}

    tool = payload.get("tool_name", "") if event == "pretooluse" else ""
    cwd = payload.get("cwd") or os.getcwd()
    project = os.path.basename(str(cwd).rstrip("/")) or "unknown"

    try:
        with open(STATUS_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
    if not isinstance(data, dict) or "projects" not in data or not isinstance(data.get("projects"), dict):
        data = {"projects": {}}

    data["projects"][project] = {"status": status, "tool": tool, "ts": time.time()}

    try:
        tmp = STATUS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp, STATUS_FILE)  # 原子写入
    except Exception:
        pass  # 写不了也不能影响 Claude Code

    # 调试日志：记录每次事件，排查哪些 hook 有/没触发
    try:
        with open(os.path.expanduser("~/.claude/pet_events.log"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {event} -> {status} [{project}]\n")
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)  # 永远成功退出，绝不阻塞
