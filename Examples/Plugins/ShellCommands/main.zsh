#!/bin/zsh

# Leap 固定提供当前命令 ID；脚本可用它在一个入口中分派多个预定义操作。
case "$LEAP_COMMAND_ID" in
  shell.foreground)
    print "前台 Shell 命令已执行"
    ;;
  shell.background)
    print "后台 Shell 命令已启动"
    ;;
  *)
    print -u2 "未知命令：$LEAP_COMMAND_ID"
    exit 1
    ;;
esac
