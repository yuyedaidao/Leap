# Leap 官方插件模板生成器

安装 Leap 即可搜索“创建插件模板”，无需另行安装。生成器随应用更新，设置中标记“官方内置”，不能卸载或被同 ID 本地插件覆盖。

## 使用

1. 搜索“创建插件模板”，选择或新建一个空目录。
2. 填写插件名称、版本和运行时，配置一个或多个命令。
3. 按需展开“搜索与匹配”和“高级设置”。
4. 生成后 Finder 打开目录，在 Leap 设置 → 本地插件中安装生成结果。

生成器不会自动安装新插件。非空目录（含隐藏文件）拒绝生成；失败只回滚本次创建且未被替换的文件，不清空所选目录。Finder 打开失败只重试打开，不重复生成。

## 参数

- 运行时：JavaScript、Python、Shell。JS/Python 支持直接执行、持续输入列表、自定义网页，并允许同插件混合三种命令；Shell 仅支持直接执行，可选择前台或后台。
- 命令：ID、标题、关键词（每行一个）、多条文本或正则匹配规则。匹配长度范围 1 至 10000，默认 1 至 1000；正则长度最多 1000 字符，写入前通过 macOS Foundation 校验，与宿主 NSRegularExpression 保持一致。
- 列表强制启用顶部输入；网页可切换顶部输入，并配置占位文本。直接执行不配置交互输入。
- 网页默认 800 × 600，最低 400 × 300；当前生成器创建内嵌网页，宽度跟随启动器；默认宽度仅用于独立窗口。内嵌网页默认高度包含宿主操作栏；独立窗口默认高度为网页内容高度，不包含系统标题栏。尺寸按可用屏幕裁剪。独立窗口可拖动调整大小，重新打开恢复默认尺寸。要使用独立窗口，手动省略网页命令的 mode、presentation、input，同时保留 webEntry 和 webWindow。
- 最低宿主版本默认 1.2.0；当前生成模板均要求该版本，因此当前只能填写 1.2.0。
- 可选生成默认 icon.png，直接安装有效；生成后可替换为自己的 PNG。入口名固定为 main.js/main.py/main.zsh，网页固定为 index.html。

插件 ID 默认 `com.leap.plugin.<目录名>`，非 ASCII 字母、数字、点、下划线、短横线逐码点转为 `u<十六进制>`，例如“测试”为 `u6d4bu8bd5`。不同位置同名目录默认 ID 相同，需手动修改以安装为不同插件；插件 ID 不允许连续 `..`，不能使用官方保留的 `com.padding.leap.template-generator`。

首个命令默认 `<插件ID>.run`，新增命令依次使用未占用的 `.run2`、`.run3`，删除不重排已有命令默认 ID。标题默认插件名称，后续命令增加序号。默认值作为占位提示，不覆盖手动输入。

## 脚本调用与开发

生成请求业务数据支持 `commands` 数组；每项包含 `id`、`title`、`interaction`（action/list/web）、`executionMode`（foreground/background）、`input`、`keywords`、`matches`。`minimumHostVersion`、`includeIcon` 为插件级参数。未传 commands 时兼容旧的 commandID/commandTitle/interaction 或 withUI；传入空数组报错。

脚本按命令 ID 和协议方法分派，未知命令返回错误。列表查询不产生副作用。网页接收 onEnter/onInputChange/onSubmit，并在 onExit 清理监听。日志写标准错误，不污染协议输出。

目录选择、打开授权只属于当前网页会话，不是脚本文件系统沙箱。生成结果和原有用户文件的保护规则不变。开发指南见 [插件开发指南](../../../../Docs/PluginDevelopment.md)。

测试（仓库根目录）：`Resources/Leap/Runtimes/node-24.21.0/bin/node --test Tests/PluginTemplateGenerator/*.test.js`。
