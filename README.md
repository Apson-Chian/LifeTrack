# LifeTrack

LifeTrack 是一款基于 SwiftUI 的私人生活轨迹工具，用于在本机记录运动、地点、停留、照片轨迹和旅行。它不提供社交、账号或实时位置共享，也不依赖网络 AI。

## 当前已实现

### 轨迹记录与可靠性

- Core Location 前台与后台轨迹记录
- When In Use 前台记录与按需升级 Always 权限
- 锁屏/后台权限不足提示、拒绝授权后的系统设置入口
- Core Motion 活动识别与手动活动类型
- 按活动方式调整的智能、省电、精细三种采样策略
- GPS 漂移、精度异常和不合理位移过滤
- SwiftData 保存错误日志与关键操作失败提示
- App 异常退出后的 ActiveSession 恢复、多个活跃会话修复与超时会话自动关闭
- 停留状态恢复，并在轨迹结束时重新计算 StayRecord

### 历史与数据质量

- 历史轨迹地图、距离、时长、配速/均速与停留时间线
- 轨迹质量卡：总点数、有效点、异常点比例、最长中断、平均/最大精度、原始/有效距离和质量等级
- GPX 单条导出、系统分享，以及从“文件”导入
- GPX 导入来源标记和指纹去重
- backupVersion 版本化 JSON 完整本地备份与合并恢复
- 备份包含轨迹、定位点、地点、停留、每日摘要、必要的照片分析缓存、时间线、Journey 和已确认旅行归档；不包含系统相册原图

### 地点、照片与旅行

- 自定义地点、分类、半径、收藏和校园地点
- 实时地点识别与基于完整轨迹的停留重建
- PhotoKit 元数据读取与本地 Vision 照片分类缓存
- 照片轨迹、智能旅行相册和 TravelTimeline
- 自动 Journey：把时间连续的多个 ActivitySession 和 StayRecord 组合为一次出行
- 本地旅行建议：结合照片 GPS、轨迹、停留和日常区域距离识别明显旅行
- 旅行建议不会自动保存；用户确认后才创建归档，并可修改名称和起止日期
- 高德地图目的地导航跳转

## 权限说明

- “使用 App 时”定位：支持前台记录；进入后台或锁屏后可能中断。
- “始终允许”定位：仅在用户主动请求后台持续记录时申请，用于进行中轨迹的后台更新。
- 运动与健身：用于辅助判断步行、跑步、骑行、驾车和静止；不可用时仍可按 GPS 速度推断。
- 照片：只读取用户授权照片的时间、位置和小尺寸分析图像；Vision 分析在本机完成。如果照片仅存储在 iCloud，系统可能下载缩略图用于本地分析。

iOS 决定实际的后台执行和定位调度。即使已授予 Always 权限，用户强制退出 App、关闭系统定位、开启飞行模式或系统资源策略仍可能停止定位；LifeTrack 会在下一次启动时修复未正常结束的数据。

## 数据与隐私

- 核心数据使用 SwiftData 存储在设备本地。
- 不上传 GPS、照片或分析结果，不使用服务器账号系统。
- GPX 导入不会修改原文件；GPX 导出不会修改原轨迹。
- 备份恢复采用 ID、稳定键和来源指纹进行合并，避免重复导入。
- iCloud 同步尚未启用；当前推荐定期导出本地备份。

## 技术栈

- Swift 5、SwiftUI
- SwiftData
- Core Location、Core Motion
- MapKit、PhotoKit、Vision
- iOS 17+

## 项目结构

```text
LifeTrack
├── App
├── Models
├── Services
├── Utilities
├── Views
└── Resources
```

Service 负责定位、轨迹分析、停留检测、GPX、备份、Journey 和旅行建议；SwiftUI View 只负责展示和用户操作。

## AI 助手（agnes-ai）

LifeTrack 可接入免费的 agnes-ai（OpenAI 兼容网关 `https://apihub.agnes-ai.com/v1`），把本机记录的生活/学习轨迹变成可阅读的洞察。

- 在“设置 → AI 助手”中开启并填写 API Key（仅存于本机 Keychain）。
- “助手”标签页可一键生成：今日回顾、本周复盘、学娱平衡、旅行手记。
- 实现为一个**本地工具调用 Agent**：模型只通过工具读取本机 SwiftData 中的受限文字/数值数据（活动、停留、课表、学习停留、旅行归档），再生成自然语言总结。
- **隐私红线**：Agent 工具不读取照片库或 `PhotoAnalysisRecord`。原图、缩略图、路径、标识符、位置元数据、本机分析标签和照片统计均不会交给 AI；Agnes 客户端消息结构也只携带 `String` 文本。

## 构建

在 Xcode 中打开 `LifeTrack.xcodeproj`，选择 LifeTrack scheme 和有效的开发团队后构建。命令行无签名模拟器构建示例：

```sh
xcodebuild -project LifeTrack.xcodeproj \
  -scheme LifeTrack \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## 当前限制

- iOS 不保证 App 被用户强制退出后继续接收普通位置更新。
- 无 GPS、无照片位置或权限受限时，旅行建议的完整度会降低。
- Journey 和旅行建议使用稳定、保守的本地规则，不使用在线地图语义或 AI API，因此需要用户最终确认旅行归档。
- 当前没有 iCloud 同步、服务器账号、社交、排行榜、聊天或实时共享位置。

## 开源协议

MIT License
