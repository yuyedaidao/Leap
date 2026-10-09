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
    id: String(index), title: `标题 ${index}`,
  })));
});
leap.onSelect(({ item }) => `已选择：${item.title}`);
