'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { validate } = require('./validation');
const { filesFor } = require('./templates');
const { spawnSync } = require('node:child_process');

function generate(input, fileSystem = fs) {
  const data = validate(input);
  const patterns = data.commands.flatMap(command => (command.matches ?? [])
    .filter(rule => rule.type === 'regex').map(rule => rule.pattern));
  if (patterns.length) {
    // 使用 macOS Foundation，与宿主一致；批量校验在任何写入之前完成。
    const check = spawnSync('/usr/bin/osascript', ['-l', 'JavaScript', '-e',
      "ObjC.import('Foundation'); function run(argv) { for (var i = 0; i < argv.length; i++) { " +
      "var error = Ref(); if ($.NSRegularExpression.regularExpressionWithPatternOptionsError(argv[i], 0, error).isNil()) " +
      "throw Error('正则表达式无效'); } return 'ok'; }", '--', ...patterns],
    { encoding: 'utf8', timeout: 1500 });
    if (check.error) throw new Error('无法校验正则表达式，请稍后重试。');
    if (check.status !== 0 || check.stdout.trim() !== 'ok') throw new Error('正则表达式无效。');
  }
  const destination = fileSystem.realpathSync(data.directory);
  if (!fileSystem.statSync(destination).isDirectory()) throw new Error('保存位置不是目录。');
  fileSystem.accessSync(destination, fs.constants.W_OK);
  if (fileSystem.readdirSync(destination).length) throw new Error('请选择空目录，目录中不能包含文件、子目录或隐藏文件。');
  const files = filesFor(data);
  const created = [];
  try {
    for (const [name, contents] of Object.entries(files)) {
      const target = path.join(destination, name);
      // 检查空目录后仍使用独占创建，防止并发文件或符号链接被覆盖。
      const descriptor = fileSystem.openSync(target, 'wx');
      try {
        const identity = fileSystem.fstatSync(descriptor);
        created.push({ target, dev: identity.dev, ino: identity.ino });
        fileSystem.writeFileSync(descriptor, contents, { encoding: 'utf8' });
      } finally { fileSystem.closeSync(descriptor); }
    }
  } catch (error) {
    for (const file of created.reverse()) {
      try {
        const identity = fileSystem.lstatSync(file.target);
        // 只回滚本次创建的文件；用户替换的文件和整个所选目录都必须保留。
        if (identity.dev === file.dev && identity.ino === file.ino) fileSystem.unlinkSync(file.target);
      } catch (cleanupError) {
        if (cleanupError.code !== 'ENOENT') console.error('清理未完成的模板文件失败：', cleanupError.message);
      }
    }
    throw error;
  }
  return { directory: destination, files: Object.keys(files) };
}

function errorMessage(error) {
  if (error.code === 'EEXIST') return '目录中出现同名文件，请重新选择空目录。';
  if (['EACCES', 'EPERM', 'EROFS'].includes(error.code)) return '没有权限写入保存目录，请选择其他位置。';
  if (error.code === 'ENOENT') return '保存目录不存在，请重新选择。';
  return error.message || '生成插件失败。';
}

if (typeof leap !== 'undefined') {
  leap.onInvoke(({ commandID, query }) => {
    if (commandID !== 'template.generate') throw new Error('未知模板命令。');
    try { return JSON.stringify(generate(JSON.parse(query))); }
    catch (error) { throw new Error(errorMessage(error)); }
  });
}
module.exports = { generate };
