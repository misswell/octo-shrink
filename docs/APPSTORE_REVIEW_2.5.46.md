# 2.5.46 审核失败：单文件授权不足以落盘

审核 submission：`bc46677a-3290-43b4-a3d7-2aa6aef8f7fa`。
Apple 在 2026-09-30 使用 M3 MacBook Air / macOS 27.0，报告点击「开始压缩」出现错误。
审核文字没有提供具体错误信息，下面是本机复现到的相符失败，不能据此断言审核输入完全相同。

## 复现与修复验证（2026-10-01）

- 从保留的 `OctoShrink-2.5.46.pkg` 解包，启动 Apple Distribution 签名、开启 App Sandbox 的原版 app；本机 macOS 27.0.1。
- 在全新临时目录放置 PNG，通过「选择文件」仅选该文件，以 Q75 / 智能 / 原格式 / 覆盖压缩。
- 日志：`压缩结果写入失败，原图未被覆盖（Operation not permitted (os error 1)）`。
- 对照：通过「选择文件夹」授权同一目录，然后重试同一文件，成功（285.6 KB → 5.0 KB）。
- 原因：读取单个文件的权限不包含创建同目录临时文件；原子覆盖与后缀模式都需要目录写权限。原有启动授权只覆盖系统转换模式，普通压缩未做目录预检，也未持有目录作用域。
- 2.5.56：`compress_files` / `compress_smart` 共用 `prepare_compression_access`。书签解析成功之后仍实际创建并自动移除探针临时文件，权限不足才请求目录授权；目录与源文件守卫持有到整个批次结束。
- 重新选目录刷新该路径书签，避免此前从单文件授权推导出的弱权限父目录书签一直被复用。Direct 与当前非沙盒 Swift 不增加授权弹窗。
- 2.5.56 签名沙盒 app，新目录仅选单文件：开始后出现目录授权；取消后 SHA-256 不变、队列可再次开始；授权后压缩成功（202.5 KB → 5.0 KB），输出模式仍是覆盖。
- 检查：前端完整测试、Direct 74 项 Rust 测试、App Store 75 项 Rust 测试、Swift 自检、两条 feature cargo check、release cargo check、三版 build_all、build_appstore、codesign 严格校验与 PKG 签名校验通过。

## 待提交的审核说明草稿

We reproduced a compression failure in the signed sandboxed build on macOS 27.0.1. Selecting an individual image granted access to that image, but did not grant the permission needed to create a temporary file in its containing folder for atomic output replacement.

Version 2.5.56 checks output-folder write access before starting either compression mode. When necessary, it asks the user to select the containing folder and retains that authorization until the output transaction completes. Cancelling authorization leaves the original file unchanged. We verified successful compression after selecting an individual PNG and granting folder access, using the signed sandboxed release build.

Please test the updated build once it has been submitted. If the issue persists, please provide the displayed error text or a screenshot, the image format, and the import method used so we can reproduce the exact scenario.
