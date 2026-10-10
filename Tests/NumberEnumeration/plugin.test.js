'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { session } = require('../PluginSDK/session.cjs');
const entry = path.resolve(__dirname, '../../Examples/Plugins/NumberEnumeration/main.js');

test('余数决定条目数，枚举从零开始且不包含余数', async t => {
  const plugin = session(entry, 'number.enumerate');
  t.after(() => plugin.close());
  for (const [query, length] of [['123', 6], ['9', 9], ['19', 0], ['0', 0], ['', 0],
    ['   ', 0], ['0012', 3], [' 123\n', 6], ['9'.repeat(999), 1], ['9'.repeat(1000), 0]]) {
    const result = await plugin.call('input', query);
    assert.equal(result.error, undefined);
    assert.deepEqual(result.items, Array.from({ length }, (_, index) => ({
      id: String(index), title: `标题 ${index}`, description: `输入：${query.trim() || '0'}`,
    })));
    assert.equal(result.value.title, `共${length}个结果`);
  }
});

test('非法输入可恢复，选择由 SDK 校验当前条目', async t => {
  const plugin = session(entry, 'number.enumerate');
  t.after(() => plugin.close());
  for (const query of ['-1', '+1', '1.2', '1e3', '12a', '1 2', '１２３', '1'.repeat(1001)]) {
    assert.match((await plugin.call('input', query)).error, /非负整数/);
  }
  await plugin.call('input', '123');
  assert.equal((await plugin.call('select', '123', '5')).value, '已复制：标题 5');
  assert.match((await plugin.call('select', '123', '6')).error, /失效/);
  await plugin.call('input', '1');
  assert.match((await plugin.call('select', '1', '5')).error, /失效/);
});

test('协议边界拒绝未知方法和无效参数', async t => {
  const plugin = session(entry, 'number.enumerate');
  t.after(() => plugin.close());
  assert.match((await plugin.call('unknown', '123')).error, /未知/);
  assert.match((await plugin.call('input', 123)).error, /参数/);
});


test('选择复制标题，复制失败反馈错误且可以重试', async t => {
  const calls = [];
  let fail = false;
  const plugin = session(entry, 'number.enumerate', 'javascript', async (method, params) => {
    calls.push({ method, params });
    if (fail) throw new Error('剪贴板不可用');
    return true;
  });
  t.after(() => plugin.close());
  await plugin.call('input', '123');
  assert.equal((await plugin.call('select', '123', '5')).value, '已复制：标题 5');
  assert.deepEqual(calls, [{ method: 'copyText', params: { text: '标题 5' } }]);
  fail = true;
  assert.match((await plugin.call('select', '123', '1')).error, /剪贴板不可用/);
  fail = false;
  assert.equal((await plugin.call('select', '123', '1')).value, '已复制：标题 1');
  const count = calls.length;
  assert.match((await plugin.call('select', '123', '6')).error, /失效/);
  assert.equal(calls.length, count);
});
