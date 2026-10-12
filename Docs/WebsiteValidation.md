# 官网实现与验证记录

日期：2026-10-10。变更：`add-official-website`。当前为本地开发预览，尚未完成素材和发行上线，不可作为正式网站发布。

## 已完成验证

- `npm install` 和随后 `npm ci --cache /private/tmp/leap-website-npm` 成功，锁文件可复现；Astro 7.3.8、@astrojs/check 0.9.10、TypeScript 6.0.3。当前 check 的 peerDependencies 仅支持 TypeScript 5/6，因此采用最新兼容版本，未强行忽略依赖冲突升级到 TypeScript 7。
- `npm run check`：无错误、警告或提示。
- `npm test`：5 项通过，覆盖版本一致性、预览与正式下载状态、URL、大小、哈希、域名及备案配置。
- `python3 -m unittest discover -s Tests/Release -v`：5 项通过，覆盖发布输入、证书缺失、输出目录、嵌套签名及公证拒绝。
- `npm run build:production`：按预期失败，指出当前缺少下载地址、文件大小、SHA256、正式站点域名与备案号，未绕过门禁。
- Astro 静态生成成功，输出首页、指南、开发者、隐私、404、robots 和 sitemap；随后的资源检查发现缺失素材，所以 **`npm run build` 整体仍失败**。
- 官网 HTTP 首页、指南、开发者与隐私路由返回 200；开发者文档正文复用成功，仓库示例与 SDK 验证记录链接均映射到构建副本。站内链接检查只报告未拍摄的图片和视频。
- 内置浏览器中验证桌面及 390 × 844 移动视口，首页、指南、开发者页面无横向溢出；下载按钮保持禁用，视频无 autoplay，FAQ 可展开，指南与开发者导航正常。
- 当前 macOS 应用 `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -derivedDataPath /private/tmp/leap-website-build` 成功。网站未改动应用源代码或 Tuist 配置。
- OpenSpec 严格验证通过；`git diff --check` 通过。

## 当前阻塞

原生应用拍摄过程中 Mac 锁定，截图接口要求用户手动解锁。已通过现有 `PluginInstaller` 将仓库 TextConvert、NumberEnumeration 示例安装到 `/private/tmp/leap-website-capture/Support`；此隔离目录不使用日常插件、信任记录或最近使用数据。最终拍摄必须使用这一目录。

以下资源尚未生成，校验保持失败，不能用示意图假装真实界面：

- `Website/public/media/search.png`
- `Website/public/media/text-convert.png`
- `Website/public/media/demo-poster.png`
- `Website/public/media/demo.mp4`（约 15 秒真实操作，点击播放）

本机未发现 Developer ID Application 证书，不能完成正式签名公证。当前也未取得域名、备案号及 EdgeOne/COS 部署配置，尚未执行云端发布。

## 解锁后继续

1. 以 `-leap-testing-support-directory /private/tmp/leap-website-capture/Support` 启动最新 Debug 构建，拍摄应用搜索和文本转换。素材只含公开应用名及示例文本，不含私人记录。
2. 录制约 15 秒真实操作；截取静态 poster，压缩为本地 MP4，确认没有自动播放。
3. 补齐资源后重新执行 `npm run check`、`npm test`、`npm run build`，检查浏览器实际画面与视频播放。
4. 完成桌面 Chrome、WebKit/Safari 和移动宽度的最终视觉、焦点与播放验收。
5. 按 WebsiteRelease.md 准备发行凭据、正式安装验收、备案和云端上线，并逐项完成剩余 OpenSpec 任务。

尚未检查：真实 Developer ID 签名后的 Node/Python、Gatekeeper、全新机器安装、Chrome 最终素材展示、大陆网络下载与回滚。
