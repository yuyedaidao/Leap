leap.onInvoke(({ commandID }) => {
  if (commandID !== 'host-api.run') throw new Error('未知命令。');
  leap.log('系统 API 示例入口被调用。');
  return '网页与入口均可使用 leap 系统 API。';
});
