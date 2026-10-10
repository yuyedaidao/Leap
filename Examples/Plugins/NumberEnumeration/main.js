'use strict';

leap.onInputChange(({ text, setList }) => {
  const value = text.trim();
  if (value && !/^[0-9]{1,1000}$/.test(value)) {
    throw new Error('请输入最多 1000 位的非负整数。');
  }
  // 按字符计算，避免长整数丢失精度；余数作为列表长度。
  let remainder = 0;
  for (const digit of value) { remainder = (remainder + Number(digit)) % 10; }
  setList(Array.from({ length: remainder }, (_, index) => ({
    id: String(index), title: `标题 ${index}`, description: `输入：${value || '0'}`,
  })), { title: `共${remainder}个结果` });
});
leap.onSelect(async ({ item }) => {
  // 等待宿主确认复制成功；失败由 SDK 传给列表反馈，避免误报成功。
  await leap.copyText(item.title);
  return `已复制：${item.title}`;
});
