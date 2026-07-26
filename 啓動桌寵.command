#!/bin/bash
# 雙擊啓動桌寵（原生版）。輸出寫進 pet.log 方便排錯。
cd "$(dirname "$0")"
# 先關掉已在跑的舊實例
pkill -f "寵物本體" 2>/dev/null
pkill -f "Python.*pet.py" 2>/dev/null
echo "=== Started / 已啟動 $(date) ===" > pet.log
./寵物本體 "$(pwd)" >> pet.log 2>&1 &
sleep 1
echo "Desktop pet launched. Drag to move, right-click to quit."
echo "桌寵已啟動。按住可拖動，右鍵退出。"
