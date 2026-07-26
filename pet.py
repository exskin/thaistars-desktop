# -*- coding: utf-8 -*-
"""
Claude Code 桌寵（玲玲拉茶版）—— 她在桌面循環拉茶，底部氣泡顯示 Claude Code 狀態。

原理：
  Claude Code 的 hooks 把當前狀態寫進 ~/.claude/claude_pet_status.json，
  桌寵每 250ms 讀一次，切換底部氣泡的表情/臺詞/顏色。
  人物動畫本身來自綠幕視頻摳出的 PNG 幀序列（frames/）。

操作：按住拖動挪位置；右鍵 → 退出；Esc 退出。
"""

import json
import os
import time
import tkinter as tk

BASE = os.path.dirname(os.path.abspath(__file__))
FRAMES_DIR = os.path.join(BASE, "frames")
STATUS_FILE = os.path.expanduser("~/.claude/claude_pet_status.json")
POLL_MS = 250
FRAME_MS = 83          # ~12fps
STALE_SEC = 120

STATES = {
    "idle":     {"badge": "😴", "text": "空閒中",   "dot": "#8a8f98"},
    "thinking": {"badge": "🤔", "text": "思考中",   "dot": "#5b8def"},
    "working":  {"badge": "🛠️", "text": "幹活中",   "dot": "#f0a020"},
    "waiting":  {"badge": "🙋", "text": "等你回話!", "dot": "#e0457b"},
    "done":     {"badge": "✨", "text": "搞定啦",   "dot": "#2ec16b"},
    "error":    {"badge": "😵", "text": "出錯了",   "dot": "#e0457b"},
    "boot":     {"badge": "🍵", "text": "待命中",   "dot": "#8a8f98"},
}


class Pet:
    def __init__(self):
        self.root = tk.Tk()
        self.root.overrideredirect(True)
        self.root.wm_attributes("-topmost", True)
        try:
            self.root.wm_attributes("-transparent", True)
        except tk.TclError:
            pass
        self.root.config(bg="systemTransparent")

        # 載入幀序列
        self.frames = []
        for name in sorted(os.listdir(FRAMES_DIR)):
            if name.lower().endswith(".png"):
                self.frames.append(tk.PhotoImage(file=os.path.join(FRAMES_DIR, name)))
        if not self.frames:
            raise SystemExit("frames/ 裏沒有 PNG 幀")
        self.iw = self.frames[0].width()
        self.ih = self.frames[0].height()

        self.BUBBLE_H = 30
        self.W = self.iw
        self.H = self.ih + self.BUBBLE_H
        sw = self.root.winfo_screenwidth()
        self.root.geometry(f"{self.W}x{self.H}+{sw - self.W - 40}+120")

        self.canvas = tk.Canvas(self.root, width=self.W, height=self.H,
                                bg="systemTransparent", highlightthickness=0, bd=0)
        self.canvas.pack()

        # 人物圖（幀動畫）
        self.sprite = self.canvas.create_image(self.W // 2, 0, anchor="n", image=self.frames[0])

        # 底部狀態氣泡
        by = self.ih + 2
        self.bubble = self.canvas.create_rectangle(
            12, by, self.W - 12, by + 24, fill="#20232a", outline="")
        self.dot = self.canvas.create_oval(22, by + 7, 32, by + 17, fill="#8a8f98", outline="")
        self.label = self.canvas.create_text(
            self.W // 2 + 6, by + 12, text="🍵 待命中",
            fill="#f0f2f5", font=("PingFang SC", 11, "bold"))

        # 交互
        self._drag = {"x": 0, "y": 0}
        self.canvas.bind("<Button-1>", self._start_drag)
        self.canvas.bind("<B1-Motion>", self._on_drag)
        self.canvas.bind("<Button-2>", self._menu_popup)
        self.canvas.bind("<Button-3>", self._menu_popup)
        self.root.bind("<Escape>", lambda e: self.root.destroy())
        self.menu = tk.Menu(self.root, tearoff=0)
        self.menu.add_command(label="退出桌寵", command=self.root.destroy)

        self._fi = 0
        self._cur = None
        self.animate()
        self.poll()

    def _start_drag(self, e):
        self._drag["x"], self._drag["y"] = e.x, e.y

    def _on_drag(self, e):
        x = self.root.winfo_x() + (e.x - self._drag["x"])
        y = self.root.winfo_y() + (e.y - self._drag["y"])
        self.root.geometry(f"+{x}+{y}")

    def _menu_popup(self, e):
        try:
            self.menu.tk_popup(e.x_root, e.y_root)
        finally:
            self.menu.grab_release()

    def read_status(self):
        try:
            with open(STATUS_FILE, encoding="utf-8") as f:
                d = json.load(f)
            status = d.get("status", "idle")
            ts = float(d.get("ts", 0))
            if status != "waiting" and (time.time() - ts) > STALE_SEC:
                status = "idle"
            return status if status in STATES else "idle"
        except FileNotFoundError:
            return "boot"
        except Exception:
            return "boot"

    def poll(self):
        status = self.read_status()
        if status != self._cur:
            self._cur = status
            s = STATES[status]
            self.canvas.itemconfig(self.label, text=f"{s['badge']} {s['text']}")
            self.canvas.itemconfig(self.dot, fill=s["dot"])
        self.root.after(POLL_MS, self.poll)

    def animate(self):
        self._fi = (self._fi + 1) % len(self.frames)
        self.canvas.itemconfig(self.sprite, image=self.frames[self._fi])
        self.root.after(FRAME_MS, self.animate)

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    Pet().run()
