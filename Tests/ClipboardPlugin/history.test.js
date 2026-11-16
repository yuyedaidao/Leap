'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { historyItems } = require('../../Resources/Leap/OfficialPlugins/Clipboard/main');
const { session } = require('../PluginSDK/session.cjs');
const path = require('node:path');

const now = Date.parse('2026-01-01T12:00:00Z');

test('宿主已按时间倒序给全量历史，这里只做搜索与 100 项截断', () => {
  const records = [
    { id: '2', type: 'text', text: '最新\n内容', timestamp: now - 1000 },
    { id: '3', type: 'files', files: ['/tmp/报告.txt', '/tmp/数据.csv'], timestamp: now - 2000 },
    { id: '4', type: 'image', imagePath: '/support/clipboard-data/4/image.png', timestamp: now - 3000 },
    { id: '1', type: 'text', text: '旧内容', timestamp: now - 60_000 },
  ];
  assert.deepEqual(historyItems(records, '', now).map(item => item.id), ['2', '3', '4', '1']);
  assert.equal(historyItems(records, '', now).find(item => item.id === '4').imagePath,
    '/support/clipboard-data/4/image.png');
  assert.equal(historyItems(records, '', now).find(item => item.id === '2').imagePath, undefined);
  assert.equal(historyItems(records, '最新', now)[0].title, '最新 内容');
  assert.equal(historyItems(records, '报告', now)[0].title, '报告.txt 等 2 个文件');
  assert.equal(historyItems(records, 'image', now)[0].title, '图片');
  assert.equal(historyItems(records, '不存在', now).length, 0);
  const many = Array.from({ length: 105 }, (_, index) => ({
    id: String(index), type: 'text', text: String(index), timestamp: index,
  }));
  assert.equal(historyItems(many, '', now).length, 100);
  // 顺序由宿主保证（新到旧），这里不再排序，只截断。
  assert.equal(historyItems(many, '', now)[0].id, '0');
});

test('真实插件会话读取宿主历史并按类型调用对应粘贴接口', async t => {
  const records = [
    { id: 'text', type: 'text', text: '文本', timestamp: 3 },
    { id: 'files', type: 'files', files: ['/tmp/a.txt'], timestamp: 2 },
    { id: 'image', type: 'image', imagePath: '/support/clipboard-data/1/hash.png', timestamp: 1 },
  ];
  const calls = [];
  const plugin = session(path.resolve('Resources/Leap/OfficialPlugins/Clipboard/main.js'), 'clipboard.history',
    'javascript', async (method, params) => {
      calls.push({ method, params });
      if (method === 'clipboardHistory') return records;
      if (method === 'clipboardSearch') return records.filter(record => record.id === params.query);
      return true;
    });
  t.after(() => plugin.close());
  const input = await plugin.call('input');
  assert.deepEqual(input.items.map(item => item.id), ['text', 'files', 'image']);
  assert.equal(input.items.find(item => item.id === 'image').imagePath, '/support/clipboard-data/1/hash.png');
  for (const id of ['text', 'files', 'image']) await plugin.call('select', '', id);
  assert.deepEqual(calls.filter(call => call.method.startsWith('hideMainWindow')).map(call => [call.method, call.params]), [
    ['hideMainWindowPasteText', { text: '文本' }],
    ['hideMainWindowPasteFile', { filePath: ['/tmp/a.txt'] }],
    ['hideMainWindowPasteImage', { image: '/support/clipboard-data/1/hash.png' }],
  ]);
  // 全量历史只在第一次查询时拉取，后续逐字过滤全部在内存里完成。
  assert.equal(calls.filter(call => call.method === 'clipboardHistory').length, 1);
});

test('宿主推送新记录后重新查询能立即看到新条目', async t => {
  const calls = [];
  const records = [{ id: 'a', hash: 'ha', type: 'text', text: '旧', timestamp: 1 }];
  const plugin = session(path.resolve('Resources/Leap/OfficialPlugins/Clipboard/main.js'), 'clipboard.history',
    'javascript', async method => {
      calls.push(method);
      if (method === 'clipboardHistory') return records;
      return true;
    });
  t.after(() => plugin.close());
  assert.deepEqual((await plugin.call('input')).items.map(item => item.id), ['a']);
  plugin.send({
    type: 'event', id: 'notify-1', method: 'notify',
    params: { name: 'clipboard.append', payload: { id: 'b', hash: 'hb', type: 'text', text: '新', timestamp: 2 } },
  });
  const refreshed = await plugin.call('input');
  assert.deepEqual(refreshed.items.map(item => item.id), ['b', 'a']);
  assert.equal(calls.filter(method => method === 'clipboardHistory').length, 1);

  // 同内容（同 hash）再次出现时应顶替旧条目，不能两条并存。
  plugin.send({
    type: 'event', id: 'notify-2', method: 'notify',
    params: { name: 'clipboard.append', payload: { id: 'c', hash: 'ha', type: 'text', text: '旧', timestamp: 3 } },
  });
  const deduped = await plugin.call('input');
  assert.deepEqual(deduped.items.map(item => item.id), ['c', 'b']);
});

test('无效记录不会进入列表，长文本标题被截断', () => {
  const records = [
    { id: 'bad', type: 'files', files: [null] },
    { id: 'missing', type: 'text' },
    { id: 'long', type: 'text', text: '中'.repeat(90), timestamp: now },
  ];
  const items = historyItems(records, '', now);
  assert.equal(items.length, 1);
  assert.equal(items[0].title.length, 81);
  assert.ok(items[0].title.endsWith('…'));
});
