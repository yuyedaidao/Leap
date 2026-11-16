'use strict';
const path = require('node:path');

const MAXIMUM_RECORDS = 1000;

// 宿主历史的内存副本；null 表示还没拉取过。
let records = null;

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
      detail: `${record.text.length} 个字符`,
    };
  }
  if (record.type === 'files' && Array.isArray(record.files) && record.files.every(value => typeof value === 'string')) {
    const names = record.files.map(value => path.basename(value));
    return {
      title: names.length > 1 ? `${names[0]} 等 ${names.length} 个文件` : (names[0] || '文件'),
      detail: `${record.files.length} 个文件`,
    };
  }
  if (record.type === 'image' && typeof record.imagePath === 'string') {
    return { title: '图片', detail: '图片' };
  }
  return null;
}

function searchable(record) {
  if (record.type === 'text') return record.text || '';
  if (record.type === 'files') return (record.files || []).join('\n');
  return '图片 image';
}

// 宿主已按新到旧返回全部记录，这里只做内存过滤与原生列表 100 项上限。
function historyItems(records, query = '', now = Date.now()) {
  const keyword = query.trim().toLowerCase();
  const items = [];
  for (const record of records) {
    const value = content(record);
    if (!value || typeof record.id !== 'string' || !record.id) continue;
    if (keyword && !`${value.title}\n${searchable(record)}`.toLowerCase().includes(keyword)) continue;
    items.push({
      id: record.id,
      title: value.title || '无标题',
      description: `${value.detail} · ${timeDescription(timestamp(record), now)}`,
      ...(record.type === 'image' && typeof record.imagePath === 'string' ? { imagePath: record.imagePath } : {}),
    });
    if (items.length >= 100) break;
  }
  return items;
}

async function history() {
  if (records === null) records = await leap.clipboard.history();
  return records;
}

function title(text) {
  return text.trim() ? '搜索剪切板' : '剪切板历史';
}

if (typeof leap !== 'undefined') {
  // 只在弹出时拉一次全量历史，此后逐字查询都在内存完成。
  leap.onInputChange(async ({ text, setList }) => {
    setList(historyItems(await history(), text, Date.now()), { title: title(text) });
  });
  // 宿主推送新记录：更新内存副本，宿主随即重跑当前查询让列表立刻出现新条目。
  leap.clipboard.onAppend(record => {
    if (!records) return;
    // 宿主按内容 hash 去重，插件副本也必须一致，否则会出现两条相同内容。
    const rest = records.filter(item => item.id !== record.id && item.hash !== record.hash);
    records = [record, ...rest].slice(0, MAXIMUM_RECORDS);
  });
  leap.onSelect(async ({ item }) => {
    const cached = records?.find(record => record.id === item.id);
    const record = cached ?? (await leap.clipboard.search(item.id, { limit: 5 })).find(value => value.id === item.id);
    if (!record) throw new Error('这条剪切板历史已不存在。');
    if (record.type === 'text' && typeof record.text === 'string') {
      await leap.hideMainWindowPasteText(record.text);
    } else if (record.type === 'files' && Array.isArray(record.files) && record.files.length) {
      await leap.hideMainWindowPasteFile(record.files);
    } else if (record.type === 'image' && typeof record.imagePath === 'string') {
      await leap.hideMainWindowPasteImage(record.imagePath);
    } else { throw new Error('剪切板历史内容无效。'); }
  });
}

module.exports = { historyItems };
