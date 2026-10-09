'use strict';
const commandID = "text.convert";
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  let request;
  try {
    request = JSON.parse(input.trim());
    if (request?.jsonrpc !== '2.0' || typeof request.id !== 'string' ||
        request.params?.commandID !== commandID || typeof request.params.query !== 'string') {
      throw new Error('请求参数无效。');
    }
    const query = request.params.query;
    const conversions = { upper: query.toUpperCase(), lower: query.toLowerCase() };
    let result;
    // 查询只生成候选；选择后才执行条目动作，不在输入变化时产生副作用。
    if (request.method === 'leap.query') {
      result = JSON.stringify({ items: query ? [
        { id: 'upper', title: conversions.upper, description: '转换为大写' },
        { id: 'lower', title: conversions.lower, description: '转换为小写' },
      ] : [] });
    } else if (request.method === 'leap.select' && Object.hasOwn(conversions, request.params.itemID)) {
      result = conversions[request.params.itemID];
    } else { throw new Error('未知请求或条目。'); }
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\n');
  } catch (error) {
    console.error(error.message);
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request?.id ?? null,
      error: { code: -32602, message: error.message } }) + '\n');
  }
});
