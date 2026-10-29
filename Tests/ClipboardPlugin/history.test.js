'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { historyItems } = require('../../Resources/Leap/OfficialPlugins/Clipboard/main');
const { session } = require('../PluginSDK/session.cjs');
const path = require('node:path');

const now = Date.parse('2026-01-01T12:00:00Z');

test('历史按时间倒序、搜索全文并限制原生列表为 100 项', () => {
  const records = [
    { _id: '1', type: 'text', text: '旧内容', timestamp: now - 60_000 },
    { _id: '2', type: 'text', text: '最新\n内容', timestamp: now - 1000 },
    { _id: '3', type: 'files', files: ['/tmp/报告.txt', '/tmp/数据.csv'], timestamp: now - 2000 },
    { _id: '4', type: 'image', imagePath: '4/image.png', timestamp: now - 3000 },
  ];
  assert.deepEqual(historyItems(records, '', now).map(item => item.id), ['2', '3', '4', '1']);
  const withRoot = historyItems(records, '', now, '/support');
  assert.equal(withRoot.find(item => item.id === '4').imagePath, path.join('/support', 'ClipboardHistory', '4/image.png'));
  assert.equal(withRoot.find(item => item.id === '2').imagePath, undefined);
  assert.equal(historyItems(records, '最新', now)[0].title, '最新 内容');
  assert.equal(historyItems(records, '报告', now)[0].title, '报告.txt 等 2 个文件');
  assert.equal(historyItems(records, 'image', now)[0].title, '图片');
  assert.equal(historyItems(records, '不存在', now).length, 0);
  const many = Array.from({ length: 105 }, (_, index) => ({
    _id: String(index), type: 'text', text: String(index), timestamp: index,
  }));
  assert.equal(historyItems(many, '', now).length, 100);
  assert.equal(historyItems(many, '', now)[0].id, '104');
});

test('真实插件会话读取数据库并按类型调用对应粘贴接口', async t => {
  const records = [
    { _id: 'text', type: 'text', text: '文本', timestamp: 3 },
    { _id: 'files', type: 'files', files: ['/tmp/a.txt'], timestamp: 2 },
    { _id: 'image', type: 'image', imagePath: 'image/hash.png', timestamp: 1 },
  ];
  const calls = [];
  const plugin = session(path.resolve('Resources/Leap/OfficialPlugins/Clipboard/main.js'), 'clipboard.history',
    'javascript', async (method, params) => {
      calls.push({ method, params });
      if (method === 'dbAllDocs') return records;
      if (method === 'dbGet') return records.find(record => record._id === params.id) ?? null;
      if (method === 'getPath') return '/support';
      return true;
    });
  t.after(() => plugin.close());
  const input = await plugin.call('input');
  assert.deepEqual(input.items.map(item => item.id), ['text', 'files', 'image']);
  assert.equal(input.items.find(item => item.id === 'image').imagePath, path.join('/support', 'ClipboardHistory', 'image/hash.png'));
  for (const id of ['text', 'files', 'image']) await plugin.call('select', '', id);
  assert.deepEqual(calls.filter(call => call.method.startsWith('hideMainWindow')).map(call => [call.method, call.params]), [
    ['hideMainWindowPasteText', { text: '文本' }],
    ['hideMainWindowPasteFile', { filePath: ['/tmp/a.txt'] }],
    ['hideMainWindowPasteImage', { image: path.join('/support', 'ClipboardHistory', 'image/hash.png') }],
  ]);
});

test('无效记录不会进入列表，长文本标题被截断', () => {
  const records = [
    { _id: 'bad', type: 'files', files: [null] },
    { _id: 'missing', type: 'text' },
    { _id: 'long', type: 'text', text: '中'.repeat(90), timestamp: now },
  ];
  const items = historyItems(records, '', now);
  assert.equal(items.length, 1);
  assert.equal(items[0].title.length, 81);
  assert.ok(items[0].title.endsWith('…'));
});
