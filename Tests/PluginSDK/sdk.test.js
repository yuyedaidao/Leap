'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const { session } = require('./session.cjs');

function fixture(t, source, hostCall, runtime = 'javascript') {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'LeapSDKTest-'));
  const entry = path.join(directory, runtime === 'python' ? 'main.py' : 'main.js');
  fs.writeFileSync(entry, source);
  const plugin = session(entry, 'test', runtime, hostCall);
  t.after(async () => { await plugin.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  return plugin;
}

test('注入不可替换的 leap、日志隔离、取消订阅和状态复用', async t => {
  const plugin = fixture(t, `
    'use strict';
    console.log('初始化日志');
    let count = 0;
    let enter = 0;
    const remove = leap.onEnter(() => { throw Error('不应执行'); }); remove();
    leap.onEnter(() => enter++);
    leap.onInvoke(() => {
      try { globalThis.leap = {}; } catch {}
      return JSON.stringify({ count: ++count, enter, frozen: Object.isFrozen(leap) });
    });
  `);
  assert.deepEqual(JSON.parse((await plugin.call('invoke')).value), { count: 1, enter: 1, frozen: true });
  assert.deepEqual(JSON.parse((await plugin.call('invoke')).value), { count: 2, enter: 1, frozen: true });
  assert.match(plugin.stderr, /初始化日志/);
});

test('多次列表发布及异步回调，完成后的更新失效', async t => {
  const plugin = fixture(t, `
    let old;
    leap.onInputChange(async ({ text, setList }) => {
      if (old) old([{id:'stale',title:'不应发布'}]);
      setList([{id:'one',title:'第一批'}]);
      await new Promise(resolve => setTimeout(resolve, 5));
      setList([{id:'two',title:text}]);
      old = setList;
    });
  `);
  for (const text of ['first', 'latest']) {
    const result = await plugin.call('input', text);
    assert.equal(result.updates.length, 2);
    assert.equal(result.items[0].title, text);
  }
});

test('取消信号阻止过期列表发布', async t => {
  const plugin = fixture(t, `
    leap.onInputChange(async ({setList,signal}) => {
      await new Promise(resolve => {
        if (signal.aborted) resolve();
        else signal.addEventListener('abort',resolve,{once:true});
      });
      setList([{id:'old',title:'过期'}], {title:'过期标题'});
    });
  `);
  await plugin.call('invoke'); // 无处理器的业务错误不终止会话，且进入已经完成。
  const result = plugin.request('input', 'old');
  // request 在 await ready 后投递；下一事件循环写入取消，使两个消息粘在同一管道也可处理。
  await new Promise(resolve => setImmediate(resolve));
  plugin.send({ type: 'cancel', id: '3' });
  const cancelled = await result;
  assert.deepEqual(cancelled.items, []);
  assert.equal(cancelled.updates.length, 0);
});

test('非法列表返回可读错误，合法输入恢复', async t => {
  const plugin = fixture(t, `
    leap.onInputChange(({text,setList}) => setList(JSON.parse(text)));
  `);
  for (const items of [[{id:'a',title:''}], [{id:'a',title:'1'},{id:'a',title:'2'}],
    Array.from({length:101},(_,i)=>({id:String(i),title:'结果'})), 'invalid']) {
    assert.match((await plugin.call('input', JSON.stringify(items))).error, /列表/);
  }
  assert.equal((await plugin.call('input', '[{"id":"ok","title":"恢复"}]')).items[0].title, '恢复');
});

test('宿主调用支持 Promise，退出先确认再清理', async t => {
  const calls = [];
  const plugin = fixture(t, `
    leap.onInvoke(async ({query}) => String(await leap.copyText(query)));
    leap.onExit(() => leap.log('清理完成'));
  `, async (method, params) => { calls.push([method, params]); return true; });
  assert.equal((await plugin.call('invoke', 'Hello')).value, 'true');
  assert.deepEqual(calls, [['copyText', {text:'Hello'}]]);
  const exit = once(plugin.child, 'exit');
  await plugin.close();
  await exit;
  assert.match(plugin.stderr, /清理完成/);
});

test('输入分段及多消息粘包仍能解析', async t => {
  const plugin = fixture(t, `leap.onInvoke(({query}) => query);`);
  await plugin.call('invoke', 'warm');
  const result = await plugin.request('invoke', '中文😀', undefined, {}, 120);
  assert.equal(result.value, '中文😀');
});

test('Python 列表缓存独立于业务对象且只包含协议字段', async t => {
  const plugin = fixture(t, `
def query(context):
    items = [{'id': 'one', 'title': '原值', 'private': object()}]
    context['setList'](items)
    items[0]['title'] = '修改后'
leap.onInputChange(query)
leap.onSelect(lambda context: context['item']['title'])
`, undefined, 'python');
  const result = await plugin.call('input', 'query');
  assert.deepEqual(result.value, [{id:'one',title:'原值'}]);
  assert.equal((await plugin.call('select', 'query', 'one')).value, '原值');
});

for (const runtime of ['javascript', 'python']) {
  test(`${runtime} 动态列表标题、子标题与旧数组结果兼容`, async t => {
    const source = runtime === 'python' ? `
saved = None
def query(context):
    global saved
    if saved:
        saved([], {'title': '不应发布'})
    items = [{'id': 'one', 'title': '结果', 'description': '子标题'}]
    if context['text'] == 'legacy':
        context['setList'](items)
    else:
        options = {'title': '第一批'}
        context['setList'](items, options)
        options['title'] = '修改后'
        context['setList'](items, {'title': context['text']})
    saved = context['setList']
leap.onInputChange(query)
leap.onSelect(lambda context: context['item']['description'])
` : `
let saved;
leap.onInputChange(({text, setList}) => {
  if (saved) saved([], {title:'不应发布'});
  const items = [{id:'one', title:'结果', description:'子标题'}];
  if (text === 'legacy') setList(items);
  else {
    const options = {title:'第一批'};
    setList(items, options); options.title = '修改后';
    setList(items, {title:text});
  }
  saved = setList;
});
leap.onSelect(({item}) => item.description);`;
    const plugin = fixture(t, source, undefined, runtime);
    const result = await plugin.call('input', '最终标题');
    assert.deepEqual(result.updates.map(value => value.title), ['第一批', '最终标题']);
    assert.deepEqual(result.value, { items: [{id:'one', title:'结果', description:'子标题'}], title:'最终标题' });
    assert.equal((await plugin.call('select', '最终标题', 'one')).value, '子标题');
    const legacy = await plugin.call('input', 'legacy');
    assert.equal(legacy.updates.length, 1);
    assert.ok(Array.isArray(legacy.value));
    const cleared = await plugin.call('input', '');
    assert.equal(cleared.value.title, '');
  });

  test(`${runtime} 非法标题返回中文错误后可以继续发布`, async t => {
    const source = runtime === 'python' ? `
import json
leap.onInputChange(lambda context: context['setList']([], json.loads(context['text'])))
` : `leap.onInputChange(({text,setList}) => setList([], JSON.parse(text)));`;
    const plugin = fixture(t, source, undefined, runtime);
    for (const options of [[], 1, {title:1}, {title:null}]) {
      assert.match((await plugin.call('input', JSON.stringify(options))).error, /标题|选项/);
    }
    assert.deepEqual((await plugin.call('input', '{"title":"恢复"}')).value, {items:[], title:'恢复'});
    assert.ok(Array.isArray((await plugin.call('input', '{}')).value));
  });
}
