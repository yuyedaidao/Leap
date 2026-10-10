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
    const size = value => new TextEncoder().encode(JSON.stringify(value)).byteLength;
    if (size(params) > 24 * 1024 * 1024) return Promise.reject(new Error('插件消息超过 24MB。'));
    return Promise.resolve(window.webkit.messageHandlers[handler].postMessage(params)).then(value => {
      if (size(value) > 24 * 1024 * 1024) throw new Error('插件消息超过 24MB。');
      return value;
    });
  };
  let hostSequence = 0;
  const host = (method, params = {}) => {
    const callID = `web-host-${++hostSequence}`;
    const signal = inputController.signal;
    if (!active || signal.aborted) return Promise.reject(new Error('插件会话已退出或输入已取消。'));
    return new Promise((resolve, reject) => {
      const cleanup = () => { clearTimeout(timer); signal.removeEventListener('abort', cancel); };
      const cancel = () => {
        cleanup();
        // 取消走独立消息，不等待正在处理的宿主请求，防止过期输入继续产生副作用。
        void call('leapHost', { method: '__cancelHostCall', params: { callID } }).catch(() => {});
        reject(new Error(signal.aborted ? '插件输入已取消。' : '宿主调用超时。'));
      };
      const timer = setTimeout(cancel, 60000);
      signal.addEventListener('abort', cancel, { once: true });
      Promise.resolve(call('leapHost', { method, params, callID })).then(
        value => { cleanup(); resolve(value); }, error => { cleanup(); reject(error); }
      );
    });
  };
  const createHostSDK = window.__leapCreateHostSDK;
  delete window.__leapCreateHostSDK;
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
    ...createHostSDK(host),
    outPlugin: () => host('outPlugin'),
    hideMainWindow: () => host('hideMainWindow'),
    onEnter: callback => subscribe('enter', callback),
    onInputChange: callback => subscribe('input', callback),
    onSubmit: callback => subscribe('submit', callback),
    onExit: callback => subscribe('exit', callback),
    log: (...values) => console.log(...values),
  }) });
})();
