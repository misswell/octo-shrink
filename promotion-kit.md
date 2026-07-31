# 章小压 OctoShrink 推广包

这份文档用于发布、投稿和社交媒体推广。所有文案都基于当前仓库功能：本地图片压缩、批量处理、Tauri 2 + Rust、内置 7 个压缩工具、支持压缩前后对比和原图恢复。

## 一句话介绍

章小压 OctoShrink 是一个免费开源、本地运行的图片压缩工具。拖入图片或文件夹，它会在电脑上批量压缩，不上传图片，并支持压缩前后滑动对比。

## 短介绍

章小压 OctoShrink 是一个免费开源的桌面图片压缩工具，支持 PNG、JPG、GIF、WebP、BMP，能输出 WebP、AVIF、JPEG XL 等格式。它基于 Tauri 2 + Rust 构建，内置 pngquant、oxipng、mozjpeg、gifsicle、cwebp、cjxl、avifenc，不需要用户额外安装命令行工具。适合博客作者、前端开发者、设计师、运营和独立开发者批量处理图片。

## 核心卖点

- 本地运行，图片不上云，断网也能用
- 免费开源，MIT 协议
- 支持拖拽图片和文件夹，自动批量处理
- 内置 7 个常用压缩工具，开箱即用
- 支持 WebP、AVIF、JPEG XL 等现代格式输出
- 支持压缩前后滑动对比
- 覆盖原文件前自动备份，可恢复原图
- Tauri 2 + Rust 构建，macOS 应用约 18MB

## 推荐发布顺序

1. 先更新 GitHub README，确保仓库首页能承接流量
2. 发布中文博客文章，使用 `blog.md`
3. 发 V2EX「分享创造」
4. 发掘金技术文章，重点讲 Tauri + Rust + 工具链打包
5. 投稿少数派，重点讲本地压缩、隐私和效率
6. 准备英文版后发 Product Hunt、Reddit、Hacker News

## V2EX 文案

标题：

```text
我做了一个 18MB 的开源本地图片压缩工具：章小压 OctoShrink
```

正文：

```text
最近做了一个小工具：章小压 OctoShrink。

它是一个免费开源、本地运行的图片压缩工具。主要解决几个痛点：

- 在线压缩要上传图片，处理证件照、合同截图、客户素材时不放心
- 命令行工具效果好，但安装和参数对很多人来说麻烦
- 桌面软件有些比较重，或者批量处理和对比体验不够顺手

章小压支持拖入图片或整个文件夹，自动批量压缩 PNG、JPG、GIF、WebP、BMP，也可以输出 WebP、AVIF、JPEG XL。

技术上用 Tauri 2 + Rust 做后端，内置了 pngquant、oxipng、mozjpeg、gifsicle、cwebp、cjxl、avifenc。用户下载安装后就能用，不需要自己装 Homebrew 或配置命令行工具。

几个功能：

- 本地运行，图片不上云
- 批量拖拽，递归处理文件夹
- 压缩前后滑动对比
- 覆盖原文件前自动备份，可一键恢复
- 如果压缩后没有变小，不会替换原图
- MIT 开源

GitHub:
https://github.com/misswell/octo-shrink

欢迎试用，也欢迎提 Issue / PR。
```

标签：

```text
分享创造, macOS, Windows, Linux, Tauri, Rust, 图片压缩
```

## 掘金文章角度

标题备选：

```text
用 Tauri + Rust 做了一个 18MB 的本地图片压缩工具
```

```text
我把 7 个图片压缩 CLI 工具打包进了一个 Tauri 桌面应用
```

文章结构：

```text
1. 为什么做：在线工具隐私、命令行门槛、桌面工具体积
2. 产品形态：拖拽、批量、对比、恢复
3. 技术架构：Tauri 2 + Rust + 原生 HTML/CSS/JS
4. 压缩引擎：pngquant、oxipng、mozjpeg、gifsicle、cwebp、cjxl、avifenc
5. 打包细节：macOS .app 内置 bin/lib，DYLD_FALLBACK_LIBRARY_PATH
6. 跨平台细节：Windows 路径、静默执行、备份恢复
7. GitHub 地址和下载
```

## 少数派投稿角度

标题备选：

```text
章小压：让图片压缩回到本地的一款轻量开源工具
```

导语：

```text
图片压缩本来应该是一件很轻的事：打开应用，拖入图片，得到更小的文件。章小压 OctoShrink 是一个免费开源、本地运行的图片压缩工具，适合处理博客配图、产品截图、设计稿和日常素材。
```

重点：

```text
少讲底层实现，多讲使用场景：隐私、本地、批量、对比、恢复。
```

## Product Hunt 文案

Name:

```text
OctoShrink
```

Tagline:

```text
Open-source local image compressor for desktop
```

Description:

```text
OctoShrink is a free, open-source desktop app for local image compression. Drop in images or folders, compress them on your machine, compare before and after, and export to formats like WebP, AVIF, and JPEG XL. Built with Tauri 2 and Rust.
```

First comment:

```text
Hi Product Hunt,

I built OctoShrink because I wanted image compression to feel simple without sending private images to a remote server.

It runs locally, supports batch folders, includes common compression tools out of the box, and lets you compare the original and compressed image before deciding whether the result is good enough.

It is built with Tauri 2 + Rust and released as an MIT open-source project.

I would love feedback from designers, developers, bloggers, and anyone who handles lots of screenshots or website images.
```

Topics:

```text
Open Source, Developer Tools, Design Tools, Productivity, Mac, Windows, Linux
```

## Reddit 文案

Subreddits:

```text
r/opensource
r/webdev
r/rust
r/macapps
r/SideProject
```

Post:

```text
I built OctoShrink, a free open-source desktop app for local image compression.

The idea is simple: drop in images or folders, compress everything on your machine, and compare the original vs compressed result before exporting. No image upload, no external service, no CLI setup for the user.

It supports PNG, JPG, GIF, WebP, BMP and can output WebP, AVIF, JPEG XL, JPEG, and PNG. The app bundles tools like pngquant, oxipng, mozjpeg, gifsicle, cwebp, cjxl, and avifenc.

Built with Tauri 2 + Rust.

GitHub:
https://github.com/misswell/octo-shrink

Feedback is very welcome.
```

## GitHub Release 文案

标题：

```text
OctoShrink 2.1.12
```

正文：

```text
OctoShrink is a free open-source local image compressor built with Tauri 2 and Rust.

Highlights:

- Compress PNG, JPG, GIF, WebP, and BMP locally
- Export to WebP, AVIF, JPEG XL, JPEG, and PNG
- Batch process images and folders
- Compare original and compressed images visually
- Restore originals when using replace mode
- Built-in compression tools, no extra CLI setup required

Download the installer for your platform below.
```

## 社交媒体短文案

中文：

```text
做了一个免费开源的本地图片压缩工具：章小压 OctoShrink。

拖入图片或文件夹，它会在电脑上批量压缩，不上传图片。支持 PNG/JPG/GIF/WebP/BMP，也能输出 WebP、AVIF、JPEG XL。Tauri + Rust，内置压缩工具，开箱即用。

GitHub: https://github.com/misswell/octo-shrink
```

英文：

```text
I built OctoShrink, a free open-source desktop app for local image compression.

Drop in images or folders, compress them on your machine, compare before/after, and export to WebP, AVIF, or JPEG XL.

Built with Tauri + Rust.

GitHub: https://github.com/misswell/octo-shrink
```

## 截图使用建议

- `assets/banner.png`：博客头图、社交媒体配图、GitHub README 首图
- `assets/screenshot-light.png`：产品主界面
- `assets/screenshot-dark.png`：暗黑模式展示
- `assets/compare.png`：重点展示压缩前后对比功能
- `assets/icon.png`：头像、Product Hunt 图标、帖子缩略图

## 发布前检查清单

- GitHub Releases 里有当前版本安装包
- README 首屏能看到截图、下载地址和核心卖点
- Release 页面说明 macOS 未签名时的打开方式
- 博客文章中图片路径在发布平台可访问
- Product Hunt 需要准备 Logo、Gallery 图片和英文描述
- Reddit / Hacker News 发帖时避免过度营销，重点讲开源和实现细节
- V2EX 发帖后及时回复反馈，收集 bug 和安装问题
