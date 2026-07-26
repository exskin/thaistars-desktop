#!/bin/bash
# 双击启动桌宠（原生版）。输出写进 pet.log 方便排错。
cd "$(dirname "$0")"
# 先关掉已在跑的旧实例
pkill -f "宠物本体" 2>/dev/null
pkill -f "Python.*pet.py" 2>/dev/null
echo "=== Started / 已啟動 $(date) ===" > pet.log
./宠物本体 "$(pwd)" >> pet.log 2>&1 &
sleep 1
echo "Desktop pet launched. Drag to move, right-click to quit."
echo "桌寵已啟動。按住可拖動，右鍵退出。"
