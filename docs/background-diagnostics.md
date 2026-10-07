# iOS 后台问题诊断

## 文件描述符占用定位

iOS 原生 `resources.fd_snapshot` 使用 `getrlimit`、`fcntl(F_GETFD/F_GETPATH)`、`fstat` 和 `getsockopt` 查询现有文件描述符，不打开、复制或关闭被采样的句柄。扫描在 utility 队列执行，最多扫描 32768 个编号；`scanTruncated` 为 true 时，`fdCount` 只能视为已扫描数量。文件正在被其它线程打开/关闭，采样不是原子快照。

启动、切歌、队列追加、前后台切换和既有播放位置回调（每分钟）会触发采样；普通请求至少间隔三秒，同一时间只允许一次扫描。标记问题、手动采样和导出会主动请求采样。没有增加用于维持后台运行的定时器。出现 EMFILE 或数据库打开失败时也会请求采样。

记录 `fdCount`、soft/hard limit、从首次采样起的增量、较上次的分类增量、峰值，以及原生队列长度/位置。分类包括 `audio_cache`、`cover_cache`、`database`、`diagnostic_log`、`socket_network_stream/datagram`、`socket_unix_*`、`pipe`、`library` 和无法确定的类型。

`targets` 最多列出 64 个占用组（按数量排序），每组包含数量和最多八个 FD 编号。文件目标保留原路径 SHA256 的前八字节作为稳定标识，并增加 `path` 和 `filename`，用于识别反复被打开的库或其它文件。路径里的容器 UUID 替换成 `<container>`，最多保留 1024 个字符；保留文件名和目录结构，不读取文件内容。socket 仅按地址族与类型分组，不收集地址、端口、网络内容。同一 target 的 count 不断增大可能提示重复打开同一个文件；这不能直接证明哪个库创建了它。

如果上一版日志已经显示两个固定 target 持续增长，安装包含路径字段的新版本后只需播放一两分钟，再手动采样并复制日志即可识别文件。无需等到句柄耗尽。重新安装后容器路径可能变化，target 哈希也可能变化，应结合路径、分类和数量增长匹配。

统计覆盖当前进程。如果 App 运行于 LiveContainer，则可能同时包含宿主的资源，不能把所有占用都归给播放器。系统音频服务其它进程及 Mach port 不在此统计内。高编号不代表数量多，应查看 `fdCount` 和类型趋势。

复现前可点一次“采集当前资源占用”。故障后标记问题，再复制/导出日志。即使文件导出因 EMFILE 失败，仍可使用复制或查看日志。

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
