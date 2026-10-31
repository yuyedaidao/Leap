/* 浏览器和 Node 共用校验规则，避免页面校验与实际写入条件不一致。 */
(function (root) {
  'use strict';
  function defaults(input) {
    const directory = typeof input.directory === 'string' ? input.directory.trim().replace(/\/+$/, '') : '';
    const basename = directory.split('/').pop() || '';
    // 按 Unicode 码点转码，包含 emoji 的目录也能得到稳定、合法的标识。
    const suffix = Array.from(basename, character => /^[A-Za-z0-9._-]$/.test(character)
      ? character : `u${character.codePointAt(0).toString(16)}`).join('');
    const id = typeof input.id === 'string' && input.id.trim() ? input.id.trim()
      : suffix ? `com.leap.plugin.${suffix}` : '';
    return { id, commandID: id ? `${id}.run` : '',
      commandTitle: typeof input.name === 'string' ? input.name.trim() : '' };
  }
  function text(value, label) {
    if (typeof value !== 'string' || value.includes('\0')) throw new Error(`${label}必须是有效文本。`);
    return value.trim();
  }
  function integer(value, fallback, label) {
    if (value == null || value === '') return fallback;
    if (!/^[0-9]+$/.test(String(value)) || !Number.isSafeInteger(Number(value))) {
      throw new Error(`${label}必须是整数。`);
    }
    return Number(value);
  }
  function validateCommand(command, data, index) {
    if (!command || typeof command !== 'object' || Array.isArray(command)) throw new Error('命令配置无效。');
    const id = text(command.id ?? '', '命令 ID') || `${data.id}.run${index ? index + 1 : ''}`;
    const title = text(command.title ?? '', '命令标题') || `${data.name}${index ? ` ${index + 1}` : ''}`;
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) throw new Error('命令 ID 仅支持字母、数字、点、下划线和短横线。');
    const interaction = command.interaction ?? (data.runtime === 'shell' ? 'action' : 'web');
    if (!['action', 'list', 'web'].includes(interaction)) throw new Error('命令交互方式无效。');
    if (data.runtime === 'shell' && interaction !== 'action') throw new Error('Shell 插件仅支持直接执行。');
    const executionMode = command.executionMode ?? 'foreground';
    if (!['foreground', 'background'].includes(executionMode) ||
        (executionMode === 'background' && (data.runtime !== 'shell' || interaction !== 'action'))) {
      throw new Error('仅 Shell 直接执行命令支持后台执行。');
    }
    const result = { id, title, interaction, executionMode };
    if (command.input != null && (typeof command.input !== 'object' || Array.isArray(command.input))) {
      throw new Error('输入配置无效。');
    }
    if (interaction === 'action') {
      if (command.input != null) throw new Error('直接执行命令不能配置顶部输入。');
    } else {
      const enabled = command.input?.enabled ?? (interaction === 'list');
      if (typeof enabled !== 'boolean' || (interaction === 'list' && !enabled)) throw new Error('列表必须启用输入。');
      result.input = { enabled };
      const placeholder = text(command.input?.placeholder ?? (interaction === 'list' ? '输入文本进行大小写转换…' : ''), '输入占位文本');
      if (enabled && placeholder) result.input.placeholder = placeholder;
    }
    if (command.keywords != null) {
      if (!Array.isArray(command.keywords)) throw new Error('关键词必须是数组。');
      const keywords = command.keywords.map(value => text(value, '关键词'));
      if (keywords.some(value => !value)) throw new Error('关键词不能为空。');
      if (keywords.length) result.keywords = [...new Set(keywords)];
    }
    if (command.matches != null) {
      if (!Array.isArray(command.matches)) throw new Error('匹配规则必须是数组。');
      result.matches = command.matches.map(rule => {
        if (!rule || typeof rule !== 'object' || !['text', 'regex'].includes(rule.type)) throw new Error('匹配类型无效。');
        const minLength = integer(rule.minLength, 1, '最小长度');
        const maxLength = integer(rule.maxLength, 1000, '最大长度');
        if (minLength < 1 || maxLength < minLength || maxLength > 10000) throw new Error('匹配长度须满足 1 ≤ 最小长度 ≤ 最大长度 ≤ 10000。');
        const match = { type: rule.type, minLength, maxLength };
        if (rule.type === 'text') {
          if (rule.pattern != null) throw new Error('文本匹配不能配置正则表达式。');
        } else {
          match.pattern = text(rule.pattern, '正则表达式');
          if (!match.pattern || match.pattern.length > 1000) throw new Error('正则表达式必须为 1 至 1000 个字符。');
          // ICU 正则支持 (?i) 等 JavaScript 不支持的语法，由写入端使用 Foundation 校验。
        }
        return match;
      });
      if (!result.matches.length) delete result.matches;
    }
    return result;
  }
  function validate(input) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('表单数据无效。');
    const data = {};
    for (const [key, label] of Object.entries({
      directory: '目录', name: '插件名称', version: '版本', runtime: '类型',
    })) {
      if (typeof input[key] !== 'string' || !input[key].trim()) throw new Error(`请填写${label}。`);
      data[key] = input[key].trim();
      if (data[key].includes('\0')) throw new Error(`${label}包含无效字符。`);
    }
    if (!data.directory.startsWith('/') || data.directory.split('/').some(part => ['.', '..'].includes(part))) {
      throw new Error('请选择有效的绝对目录路径，不能包含 . 或 ..。');
    }
    data.directory = data.directory.replace(/\/+$/, '');
    if (!data.directory) throw new Error('不能使用根目录生成插件。');
    const fallback = defaults({ ...input, directory: data.directory });
    for (const key of ['id', 'commandID', 'commandTitle']) {
      const value = key === 'id' || input.commands == null ? input[key] : undefined;
      if (value != null && typeof value !== 'string') throw new Error('高级设置必须是文本。');
      data[key] = value?.trim() || fallback[key];
      if (data[key].includes('\0')) throw new Error('高级设置包含无效字符。');
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(data.id) || data.id.includes('..')) throw new Error('插件 ID 仅支持字母、数字、点、下划线和短横线，不能包含连续的 ..。');
    if (data.id === 'com.padding.leap.template-generator') throw new Error('该插件 ID 为内置插件保留，请使用其他 ID。');
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(data.commandID)) throw new Error('命令 ID 仅支持字母、数字、点、下划线和短横线。');
    if (!/^\d+\.\d+\.\d+$/.test(data.version)) throw new Error('版本应为三段数字，例如 1.0.0。');
    if (!['javascript', 'python', 'shell'].includes(data.runtime)) throw new Error('不支持的插件类型。');
    const hostVersion = input.minimumHostVersion == null ? '' : text(input.minimumHostVersion, '最低宿主版本');
    if (hostVersion && !/^\d+\.\d+\.\d+$/.test(hostVersion)) {
      throw new Error('最低宿主版本应为三段数字，例如 0.0.1；留空表示不限制。');
    }
    data.minimumHostVersion = hostVersion || undefined;
    if (input.includeIcon != null && typeof input.includeIcon !== 'boolean') throw new Error('图标选项无效。');
    data.includeIcon = input.includeIcon ?? false;
    let commands = input.commands;
    if (commands == null) {
      if (input.interaction == null && typeof input.withUI !== 'boolean') throw new Error('网页 UI 选项无效。');
      commands = [{ id: data.commandID, title: data.commandTitle,
        interaction: input.interaction ?? (input.withUI ? 'web' : 'action') }];
    }
    if (!Array.isArray(commands) || !commands.length) throw new Error('至少需要一个命令。');
    data.commands = commands.map((command, index) => validateCommand(command, data, index));
    if (new Set(data.commands.map(command => command.id)).size !== data.commands.length) {
      throw new Error('命令 ID 不能重复。');
    }
    data.interaction = data.commands[0].interaction;
    data.withUI = data.commands.some(command => command.interaction === 'web');
    if (data.withUI) {
      for (const [key, minimum, label] of [['width', 400, '默认宽度'], ['height', 300, '默认高度']]) {
        const value = input[key];
        // 表单提供字符串，脚本调用也允许整数；拒绝小数、科学计数法和空值。
        if (!/^[0-9]+$/.test(String(value)) || !Number.isSafeInteger(Number(value)) || Number(value) < minimum) {
          throw new Error(`${label}必须是至少 ${minimum} 的整数。`);
        }
        data[key] = Number(value);
      }
    }
    return data;
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = { validate, defaults };
  else root.templateValidation = Object.freeze({ validate, defaults });
})(globalThis);
