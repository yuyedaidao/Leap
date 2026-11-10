// 字节数组转换为 Data URL，避免 JSON 将其变成数字字典。
(function (root) {
  function create(host) {
    const invoke = (method, params) => {
      try { return Promise.resolve(host(method, params)); }
      catch (error) { return Promise.reject(error); }
    };
    const image = value => {
      if (value instanceof Uint8Array) {
        if (!value.byteLength || value.byteLength > 16 * 1024 * 1024) throw new TypeError('图片必须为 1 字节至 16MB。');
        let encoded;
        if (typeof Buffer !== 'undefined') encoded = Buffer.from(value).toString('base64');
        else {
          const parts = [];
          for (let i = 0; i < value.length; i += 8192) parts.push(String.fromCharCode(...value.subarray(i, i + 8192)));
          encoded = btoa(parts.join(''));
        }
        return 'data:application/octet-stream;base64,' + encoded;
      }
      if (typeof value !== 'string' || !value) throw new TypeError('图片必须为路径、Data URL 或 Uint8Array。');
      return value;
    };
    const single = (method, field, value) => {
      try {
        if (field === 'image') value = image(value);
        else if (field === 'filePath' && method.endsWith('File')) {
          if (typeof value !== 'string' && !Array.isArray(value)) throw new TypeError('文件路径必须为字符串或数组。');
          if (Array.isArray(value) && (!value.length || value.some(path => typeof path !== 'string' || !path))) throw new TypeError('文件路径数组不能为空且只能包含路径字符串。');
        } else if (typeof value !== 'string') throw new TypeError('参数必须为字符串。');
        return invoke(method, { [field]: value });
      } catch (error) { return Promise.reject(error); }
    };
    const dbID = value => {
      if (typeof value !== 'string' || !value) throw new TypeError('数据库文档 _id 必须为非空字符串。');
      return value;
    };
    return {
      db: {
        put: doc => {
          if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return Promise.reject(new TypeError('数据库文档必须为对象。'));
          try { dbID(doc._id); } catch (error) { return Promise.reject(error); }
          return invoke('dbPut', { doc });
        },
        get: id => {
          try { return invoke('dbGet', { id: dbID(id) }); } catch (error) { return Promise.reject(error); }
        },
        remove: (id, rev) => {
          try {
            if (typeof rev !== 'string' || !rev) throw new TypeError('数据库文档 _rev 必须为非空字符串。');
            return invoke('dbRemove', { id: dbID(id), rev });
          } catch (error) { return Promise.reject(error); }
        },
        allDocs: () => invoke('dbAllDocs', {}),
      },
      showLoading: () => invoke('showLoading', {}),
      hideLoading: () => invoke('hideLoading', {}),
      copyText: value => single('copyText', 'text', value),
      copyFile: value => single('copyFile', 'filePath', value),
      copyImage: value => single('copyImage', 'image', value),
      hideMainWindowPasteText: value => single('hideMainWindowPasteText', 'text', value),
      hideMainWindowPasteFile: value => single('hideMainWindowPasteFile', 'filePath', value),
      hideMainWindowPasteImage: value => single('hideMainWindowPasteImage', 'image', value),
      hideMainWindowTypeString: value => single('hideMainWindowTypeString', 'text', value),
      shellOpenPath: value => single('shellOpenPath', 'fullPath', value),
      shellTrashItem: value => single('shellTrashItem', 'fullPath', value),
      shellShowItemInFolder: value => single('shellShowItemInFolder', 'fullPath', value),
      shellOpenExternal: value => single('shellOpenExternal', 'url', value),
      getPath: value => single('getPath', 'name', value),
      getFileIcon: value => single('getFileIcon', 'filePath', value),
      getCopyedFiles: () => invoke('getCopyedFiles', {}),
      shellBeep: () => invoke('shellBeep', {}),
      getNativeId: () => invoke('getNativeId', {}),
      getAppName: () => invoke('getAppName', {}),
      getAppVersion: () => invoke('getAppVersion', {}),
      readCurrentFolderPath: () => invoke('readCurrentFolderPath', {}),
      readCurrentBrowserUrl: () => invoke('readCurrentBrowserUrl', {}),
      isDev: () => invoke('isDev', {}),
      isMacOS: () => invoke('isMacOS', {}),
      isWindows: () => invoke('isWindows', {}),
      isLinux: () => invoke('isLinux', {}),
      showNotification: (body, clickFeatureCode) => {
        if (typeof body !== 'string' || !body || (clickFeatureCode !== undefined && typeof clickFeatureCode !== 'string')) return Promise.reject(new TypeError('通知正文及命令 ID 必须为字符串。'));
        return invoke('showNotification', { body, ...(clickFeatureCode !== undefined ? { clickFeatureCode } : {}) });
      },
      simulateKeyboardTap: (key, ...modifiers) => {
        if (typeof key !== 'string' || !key || modifiers.some(value => typeof value !== 'string')) return Promise.reject(new TypeError('按键和修饰键必须为字符串。'));
        return invoke('simulateKeyboardTap', { key, modifiers });
      },
      runPlugin: (pluginID, commandID, query = '') => {
        if (typeof pluginID !== 'string' || !pluginID || typeof commandID !== 'string' || !commandID || typeof query !== 'string') {
          return Promise.reject(new TypeError('插件 ID、命令 ID 必须为非空字符串，参数必须为字符串。'));
        }
        return invoke('runPlugin', { pluginID, commandID, query });
      },
    };
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = create;
  else (typeof window === 'object' ? window : root).__leapCreateHostSDK = create;
})(globalThis);
