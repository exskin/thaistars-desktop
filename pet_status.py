# -*- coding: utf-8 -*-
"""
Claude Code hook 調用它來更新桌寵狀態。
用法（由 hooks 自動調用）：  python3 pet_status.py <event>

<event> 取值對應 Claude Code 的 hook 事件名，映射到桌寵狀態：
  userpromptsubmit -> thinking   (你剛發了消息，她開始想)
  pretooluse       -> working    (正在調某個工具，讀 stdin 拿工具名)
  posttooluse      -> thinking   (工具跑完，繼續想下一步)
  notification     -> waiting    (需要你回話/授權)
  stop             -> done       (這一輪答完了)
  subagentstop      -> done      (子任務結束)

  真正的 idle（發呆）不是任何 hook 事件觸發的，是桌寵那邊看 ts 判斷：
  超過 STALE_SEC（目前 10 分鐘）沒有新事件，纔會從 done/其他狀態退回 idle。

狀態文件是多專案結構：{"projects": {"<項目名>": {"status","tool","ts"}, ...}}
項目名取自 hook payload 裏的 cwd 目錄名（同一目錄下多個會話會互相覆蓋，這是已知簡化）。

設計原則：絕不報錯、絕不卡住 Claude Code —— 出任何問題都靜默 exit 0。
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
    "permissionrequest": "waiting",  # 彈 allow 詢問的專屬事件（Notification 在桌面版不一定觸發）
    "stop": "done",
    "subagentstop": "done",  # 子任務結束≠主線還在忙，若接着真有動作會被後續事件覆蓋
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
        os.replace(tmp, STATUS_FILE)  # 原子寫入
    except Exception:
        pass  # 寫不了也不能影響 Claude Code

    # 調試日誌：記錄每次事件，排查哪些 hook 有/沒觸發
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
    sys.exit(0)  # 永遠成功退出，絕不阻塞
