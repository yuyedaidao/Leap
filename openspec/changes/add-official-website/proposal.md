## Why

Leap 缺少面向中文用户的产品介绍、安装指南与可信下载入口。建立轻量官网，同时补齐首个公开版本的发布流程，避免展示无法下载或未经验证的安装包。

## What Changes

- 新增独立 `Website/` Astro 静态网站，简体中文首页、使用指南、开发者入口、隐私说明与 404。
- 使用正式图标、真实应用截图与本地演示视频，采用浅色简洁视觉及可访问的响应式布局。
- 统一版本、系统要求、下载地址、大小和 SHA256；无安装包时展示下载尚未开放，生产构建强制校验。
- 复用插件开发文档，增加 Apple Silicon 发布包签名、公证、校验与 EdgeOne Pages/COS 部署说明。
- 备案完成后上线；域名、云服务和 Developer ID 凭据由用户提供，缺失时交付本地可预览成果并保留待办。

## Capabilities

### New Capabilities
- `official-website`: 产品介绍、用户和开发者文档、隐私声明、静态资源与公开下载的发布门禁。

### Modified Capabilities
无。

## Impact

新增 Website、发布脚本和文档、OpenSpec 变更。网站与 Tuist/macOS 应用独立构建；不增加账号、后端、遥测或插件市场。公开发行仅支持 macOS 26+ 与 Apple Silicon。
