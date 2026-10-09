(() => {
  'use strict';
  const context = window.__leapContext;
  delete window.__leapContext;
  const listeners = { enter: new Set(), input: new Set(), submit: new Set(), exit: new Set() };
  let active = true;
  let inputController = new AbortController();
  const deliver = (callback, value) => {
    try { Promise.resolve(callback(value)).catch(error => console.error(error)); }
    catch (error) { console.error(error); }
  };
  const subscribe = (event, callback) => {
    if (typeof callback !== 'function') throw new TypeError('监听器必须是函数。');
    if (event === 'input' && listeners.input.size) throw new Error('input 只能注册一个处理器。');
    listeners[event].add(callback);
    if (event === 'enter' && context) queueMicrotask(() => {
      if (active && listeners.enter.has(callback)) deliver(callback, { ...context, signal: inputController.signal });
    });
    return () => listeners[event].delete(callback);
  };
  const call = (handler, params) => {
    if (!active) return Promise.reject(new Error('插件会话已退出。'));
    return window.webkit.messageHandlers[handler].postMessage(params);
  };
  const host = (method, params = {}) => call('leapHost', { method, params });
  window.__leapDispatch = (event, value) => {
    if (!active || !listeners[event]) return;
    if (event === 'input') {
      inputController.abort();
      inputController = new AbortController();
      if (context) context.query = value;
      value = { commandID: context?.commandID, text: value, signal: inputController.signal,
        setList: () => { throw new Error('网页使用自己的界面，setList 仅适用于原生列表。'); } };
    }
    if (event === 'exit') { active = false; inputController.abort(); }
    for (const callback of listeners[event]) deliver(callback, value);
    if (!active) for (const callbacks of Object.values(listeners)) callbacks.clear();
  };
  Object.defineProperty(window, 'leap', { configurable: false, writable: false, value: Object.freeze({
    invoke: (commandID, query = '') => {
      if (typeof commandID !== 'string' || typeof query !== 'string') return Promise.reject(new TypeError('命令和参数必须是字符串。'));
      return call('leapInvoke', { commandID, query });
    },
    chooseDirectory: () => call('leapDirectory', { action: 'choose' }),
    openDirectory: path => call('leapDirectory', { action: 'open', path }),
    copyText: text => {
      if (typeof text !== 'string') return Promise.reject(new TypeError('复制内容必须是字符串。'));
      return host('copyText', { text });
    },
    outPlugin: () => host('outPlugin'),
    hideMainWindow: () => host('hideMainWindow'),
    onEnter: callback => subscribe('enter', callback),
    onInputChange: callback => subscribe('input', callback),
    onSubmit: callback => subscribe('submit', callback),
    onExit: callback => subscribe('exit', callback),
    log: (...values) => console.log(...values),
  }) });
})();
