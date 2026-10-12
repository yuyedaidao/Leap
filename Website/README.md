# Leap 官网

独立于 Tuist 的中文静态网站。使用 Node.js 22.12+、Astro 7 和 TypeScript；建议使用 Node.js 24 LTS。网站不需要后端。

## 本地开发

```sh
cd Website
npm ci
npm run dev
```

默认地址 `http://127.0.0.1:4321`。依赖缓存权限异常时，可指定 `--cache /private/tmp/leap-website-npm`，不要修改系统缓存权限。

```sh
npm run check
npm test
npm run build
npm run preview
```

`build` 输出 `dist/` 并检查内部路由、锚点与资源。未配置正式域名时，预览禁止搜索引擎索引。开发者页面由 `Docs/PluginDevelopment.md` 自动生成；示例随同次构建复制，直接编辑仓库文档即可。

## 发布配置

`release.json` 为下载信息唯一来源。安装包未通过正式验收时保持 `downloadURL`、`sizeBytes`、`sha256` 为 `null`。有下载链接时，大小与哈希必须同时填写。版本须与应用一致。

正式环境配置：

- `SITE_URL`：已备案的正式 HTTPS 站点根地址。
- `ICP_NUMBER`：已取得的备案号，页面自动链接到工信部备案查询。

```sh
npm run build:production
```

正式构建缺少下载信息、域名或备案号会失败。配置校验只能检查格式，不能代替备案核验、签名检查或下载实测。备案前仅进行本地预览，不能把普通 `build` 用作公开上线的绕过路径。

完整发布和回滚步骤见 [官网发布手册](../Docs/WebsiteRelease.md)。

## 素材

`public/media/` 使用正式 App 图标和隔离数据目录中的真实应用画面。视频仅在用户点击后播放；不自动播放、不嵌入外站播放器。拍摄过程与验收记录见 [官网验证记录](../Docs/WebsiteValidation.md)。
