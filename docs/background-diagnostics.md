# iOS 后台问题诊断

安装包含诊断入口的构建后，按平常方式播放和锁屏。首次发现封面、歌词或缓存异常时：

1. 记下大致时间，不重启、不清缓存。
2. 打开一次缓存管理，让日志记录扫描停在哪一步。
3. 返回设置 → 诊断日志 → 标记刚刚出现的问题。
4. 点击导出诊断日志，在 iPhone 分享面板选择“存储到文件”，再把文件传到电脑分析。

iOS 导出使用原生分享面板，并在应用临时目录中准备文件，不经过 `file_picker.saveFile`。如果仍然保存失败，点击“复制日志”，粘贴到备忘录或聊天；也可以通过“查看日志”选取文本。失败后这两个入口会保留导出前的日志快照及导出错误，不要求重新复现。

日志为逐行 JSON 文本，时间使用 UTC。`session` 区分启动会话，`elapsedMs` 表示会话内经过时间。
同一操作的 `.begin`、`.end`、`.error` 使用相同 `operation`；超过 15 秒未完成会出现 `.waiting`，只记录，不取消原操作。
播放位置每分钟记录一次；歌词行变更和系统封面发布也会记录。没有新位置记录不能单独证明进程挂起。

日志不记录歌曲名、歌词正文、请求头或完整封面 URL；封面源使用哈希标识，错误中的 HTTP URL 和常见凭据字段会被过滤。
日志目录位于 Application Support 的 `bilimusic_diagnostics`，当前文件超过 2 MiB 后轮换为一个历史文件。
最多保留 2000 条内存记录。持久化失败或等待时，导出会在最多 3 秒的磁盘读取等待后使用内存记录。
启动不等待日志目录；不修改原播放、网络请求或缓存重试行为。

Release 工作流会把源码提交和 Flutter 版本写入日志。手动构建可提供 `GIT_REVISION`、`BILIMUSIC_FLUTTER_VERSION`、`APP_VERSION` 三个 `--dart-define`。`FLUTTER_VERSION` 是框架保留名称，不可作为自定义构建参数。
需要在 CI 或有 Flutter SDK 的电脑上运行 `flutter analyze` 和 `flutter test test/diagnostic_log_test.dart test/diagnostics_page_test.dart`，并完成 iOS 原生编译，再在 iOS 18.5 实机验证分享面板、取消和保存失败后的复制入口。
