'use strict';
leap.onInputChange(({ text, setList }) => {
  setList(text ? [
    { id: 'upper', title: text.toUpperCase(), description: '转换为大写' },
    { id: 'lower', title: text.toLowerCase(), description: '转换为小写' },
  ] : []);
});
leap.onSelect(({ item }) => item.title);
