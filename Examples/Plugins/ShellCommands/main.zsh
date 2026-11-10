#!/bin/zsh

# Leap 固定提供当前命令 ID；多条命令共用一个入口，按 ID 分派到各自的分支。
# 每个分支就是那条命令的脚本，改分支里的内容即可。
case "$LEAP_COMMAND_ID" in
  # 前台 Shell 示例
  shell.foreground)
    print "前台 Shell 命令已执行"
    ;;
  # 后台 Shell 示例
  shell.background)
    print "后台 Shell 命令已启动"
    ;;
  *)
    print -u2 "未知命令：$LEAP_COMMAND_ID"
    exit 1
    ;;
esac
