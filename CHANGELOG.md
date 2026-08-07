# CHANGELOG

## 7.0.0 (main) + 1.0.0 (AudioSync)

新增：

- AudioSync 声音同步模块（独立补丁包 com.vcamplus.audiosync，不修改任何源码）
  - 拉流直播音频注入：hook AVCaptureAudioDataOutput delegate，替换音频帧
  - 音频源类型：自动(与视频同源) / OBS-HLS (m3u8) / Icecast (MP3/AAC) / 本地文件
  - 自动同源模式：读主包 enabled 索引 → 自动定位当前视频文件 → 提取音轨，
    无需任何音频地址，切换视频自动跟随（视频模式画面+声音同源直推）
  - 同步方式：实时 / 对齐（默认对齐，音画同步，含漂移校正）
  - 音量调节 0-200%，支持音频格式自动转换 (AVAudioConverter)
  - UI：现有菜单运行时注入"声音设置"入口（不重建悬浮窗，不改核心 UI 代码）
  - 测试连接 / 状态显示 / 配置持久化 (audio.conf)
  - 菜单标题运行时重命名：Virtual Camera v7.0 → vcam-iOS-V2
- GitHub Actions 构建：rootless + roothide 双 scheme，主包与补丁包同时出包

修复：

- 无

删除：

- 无

说明：

- 主源码 src/Tweak.xm 零改动；主包构建配置由新增 Makefile.ci 提供（源码路径指向 src/）
- RTMP 音频源暂不支持（需 FFmpeg 解码器，留作可选扩展）
- 拉流(MJPEG)/图片模式：无音轨，自动模式自动失效，回落手机麦克风
