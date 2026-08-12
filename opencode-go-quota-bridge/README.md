# OpenCode Go 额度本地同步桥

这个扩展只在 `https://opencode.ai/workspace/*/go` 页面运行，从页面已经显示的 5 小时、周、月额度读取数字，发送到本机 `127.0.0.1:45731`。它不读取 Cookie、密码或 API Key，也不会把数据发送到第三方。

使用方式：

1. 先启动桌面浮窗的 OpenCode Go 项目启动器，它会启动本地桥接服务。
2. 在 Chrome 打开并保持登录官方 OpenCode Go 页面。
3. 打开 `chrome://extensions`，开启“开发者模式”，选择“加载已解压的扩展程序”。
4. 选择当前目录下的这个 `opencode-go-quota-bridge` 文件夹。

页面保持打开时，扩展每 60 秒尝试同步一次；Chrome 对后台标签页的定时器可能延后，关闭页面后，浮窗会继续显示最后一次同步结果，并在过期后标记为页面快照。
