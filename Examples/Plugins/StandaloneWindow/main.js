leap.onInvoke(({ commandID }) => {
  if (commandID !== 'standalone-window.run') {
    leap.log(`未知命令：${commandID}`);
    throw new Error('未知命令。');
  }
  leap.log('独立窗口示例：收到网页调用。');
  return '你好，这是独立窗口中的脚本返回结果！';
});
