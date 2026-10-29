# Go 媒体内容探测检查点

Go 增加基于 [mimetype v1.4.16](https://github.com/gabriel-vasile/mimetype/tree/v1.4.16) 的有界文件内容探测组件，读取至多 4096 字节。14 组共同字节样例同时运行 Nuxt 的 `file-type` 和 Go 探测器，覆盖 PNG/APNG、GIF、JPEG、PDF、gzip、7z、ZIP、构造的 DOCX、ELF、Windows 可执行文件、WebP、WAV 与普通文本；对已发现的可执行文件类型命名差异做显式映射。

前缀达到 4096 字节时，ZIP 以及不能在前缀中判定是否为 APNG 的 PNG 暂时返回错误，不能冒充已确定的类型。此策略会拒绝正常大 ZIP/Office 文件，是待补齐的限制。短样例通过不等于所有格式、损坏文件、压缩包内部内容或欺骗性文件都与 Nuxt 一致；库识别可能存在其他差异，检测也不是恶意文件扫描。该组件尚未接入上传路由，Rust 实际探测、图片/音视频元数据、流式容器检查及真实跨端验收仍待实现。

Go 全量测试、vet 和 Linux 交叉编译通过；另以实际 multipart 暂存文件验证伪装的 `.txt` PNG 优先按内容选为 PNG。Nuxt 实际探测器通过共同字节样例，公共需求和 OpenAPI 副本检查通过。
