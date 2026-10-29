'use strict';
const path = require('node:path');

function timestamp(record) {
  return typeof record.timestamp === 'number' && Number.isFinite(record.timestamp) ? record.timestamp : 0;
}

function timeDescription(value, now = Date.now()) {
  const elapsed = Math.max(0, now - value);
  if (elapsed < 60_000) return '刚刚';
  if (elapsed < 3_600_000) return `${Math.floor(elapsed / 60_000)} 分钟前`;
  if (elapsed < 86_400_000) return `${Math.floor(elapsed / 3_600_000)} 小时前`;
  return `${Math.floor(elapsed / 86_400_000)} 天前`;
}

function content(record) {
  if (record.type === 'text' && typeof record.text === 'string') {
    const singleLine = record.text.replace(/\s+/g, ' ').trim();
    return {
      title: singleLine.length > 80 ? `${singleLine.slice(0, 80)}…` : singleLine,
      searchable: record.text,
      detail: `${record.text.length} 个字符`,
    };
  }
  if (record.type === 'files' && Array.isArray(record.files) && record.files.every(value => typeof value === 'string')) {
    const names = record.files.map(value => path.basename(value));
    return {
      title: names.length > 1 ? `${names[0]} 等 ${names.length} 个文件` : (names[0] || '文件'),
      searchable: record.files.join('\n'),
      detail: `${record.files.length} 个文件`,
    };
  }
  if (record.type === 'image' && typeof record.imagePath === 'string') {
    return { title: '图片', searchable: '图片 image', detail: '图片' };
  }
  return null;
}

function historyItems(records, query = '', now = Date.now(), root) {
  const keyword = query.trim().toLowerCase();
  return records.map(record => ({ record, content: content(record) }))
    .filter(item => item.content && typeof item.record._id === 'string' && item.record._id)
    .filter(item => !keyword || `${item.content.title}\n${item.content.searchable}`.toLowerCase().includes(keyword))
    .sort((left, right) => timestamp(right.record) - timestamp(left.record)
      || right.record._id.localeCompare(left.record._id))
    .slice(0, 100)
    .map(({ record, content: value }) => {
      const item = {
        id: record._id,
        title: value.title || '无标题',
        description: `${value.detail} · ${timeDescription(timestamp(record), now)}`,
      };
      if (record.type === 'image' && typeof record.imagePath === 'string' && typeof root === 'string') {
        item.imagePath = path.join(root, 'ClipboardHistory', record.imagePath);
      }
      return item;
    });
}

if (typeof leap !== 'undefined') {
  leap.onInputChange(async ({ text, setList }) => {
    const root = await leap.getPath('userData');
    setList(historyItems(await leap.db.allDocs(), text, Date.now(), root), { title: text.trim() ? '搜索剪切板' : '剪切板历史' });
  });
  leap.onSelect(async ({ item }) => {
    const record = await leap.db.get(item.id);
    if (!record) throw new Error('这条剪切板历史已不存在。');
    if (record.type === 'text' && typeof record.text === 'string') {
      await leap.hideMainWindowPasteText(record.text);
    } else if (record.type === 'files' && Array.isArray(record.files) && record.files.length) {
      await leap.hideMainWindowPasteFile(record.files);
    } else if (record.type === 'image' && typeof record.imagePath === 'string') {
      const root = await leap.getPath('userData');
      await leap.hideMainWindowPasteImage(path.join(root, 'ClipboardHistory', record.imagePath));
    } else { throw new Error('剪切板历史内容无效。'); }
  });
}

module.exports = { historyItems };
