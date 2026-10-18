# Deadlock Camera Fix

[English](README.md) | 简体中文

用一个 PowerShell 脚本修复 Deadlock 皮肤 mod 中已知的摄像机兼容性问题。

`AutoFix.ps1` 会查找 Steam 游戏目录，将已安装 mod 的 VPK 与当前原版游戏文件比较，修复能够识别的旧版镜头挂点和大厅相机设置。安装前会备份原包，并校验修复结果。

脚本可以独立运行，AI agent 为可选用法，不需要 Node.js、CMD 启动器或其他辅助脚本。本项目为非官方工具，与 Valve 和皮肤作者没有隶属关系。

## 运行要求

- Windows x64，以及本地 Steam 版 Deadlock。
- 能够读取游戏文件、写入 mod 目录的权限。
- 首次下载运行环境和解析库时需要联网，之后复用缓存。
- 足够的磁盘空间，用于提取模型、备份原 mod 和生成修复包。

可以从 Windows 自带的 PowerShell 5.1 启动。必要时，脚本会下载便携版 PowerShell 7.6.7，在 .NET 10 上重新执行同一个脚本。解析库从 GitHub/NuGet 下载，并检查固定 SHA256。不需要管理员安装，也不永久修改 PATH。

## 快速开始

1. 打开 [AutoFix.ps1](AutoFix.ps1)，使用 GitHub 的 **Download raw file** 下载；也可以下载整个仓库 ZIP 后解压。确认扩展名为 `.ps1`，不是 `.ps1.txt`。
2. 在 `AutoFix.ps1` 所在目录打开 PowerShell。脚本不需要放在游戏目录内。
3. 先扫描已安装的 mod：

   ```powershell
   .\AutoFix.ps1 -Mode Scan
   ```

4. 需要修复时，退出 Deadlock，让 Mod Manager 保持空闲，然后运行：

   ```powershell
   .\AutoFix.ps1
   ```

5. 查看控制台结果。安装完成后启动游戏，检查大厅、移动、蹲下、瞄准、技能、死亡和复活。

不带参数运行时，默认执行 **Repair**，可能替换支持修复的 mod 包。只想检查时，请使用 **Scan**。

如果下载的脚本被阻止运行，先检查文件内容，再解除锁定：

```powershell
Unblock-File -LiteralPath .\AutoFix.ps1
```

如果个人管理的电脑仍因执行策略无法运行，可使用下面的命令，仅为这次 PowerShell 进程采用 RemoteSigned 策略：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\AutoFix.ps1 -Mode Scan
```

## 使用方法

### 选择运行模式

| 模式 | 行为 |
| --- | --- |
| `Scan` | 检测并分类相机问题，不修改游戏文件。 |
| `Prepare` | 备份原包、生成并校验修复包，不安装。 |
| `Repair` | 准备支持处理的修复包，游戏关闭时安装。这是默认模式。 |
| `Install` | 根据已有修复记录安装准备好的包，需要 `-BatchReport`。 |
| `Restore` | 根据修复记录恢复原 mod 包，需要 `-BatchReport`。 |

```powershell
# 只检查。
.\AutoFix.ps1 -Mode Scan

# 生成修复包，保留当前已安装的 mod 不变。
.\AutoFix.ps1 -Mode Prepare

# 准备并安装支持处理的修复。
.\AutoFix.ps1 -Mode Repair
```

游戏运行时，Repair 仍可准备修复包，但会标记为 `pending-game-exit`。退出游戏后再用 Install 安装。脚本不会替你关闭游戏。

### 指定游戏或 mod

如果自动检测未找到游戏，或找到了多个安装目录，请指定 **Deadlock 根目录**，不要指定它下面的 `game` 或 `addons`：

```powershell
.\AutoFix.ps1 -Mode Scan -GamePath 'E:\SteamLibrary\steamapps\common\Deadlock'
```

只处理指定包时，使用它当前在 `game\citadel\addons` 内的实际文件名：

```powershell
.\AutoFix.ps1 -Mode Scan -Vpk 'pak09_dir.vpk'
.\AutoFix.ps1 -Mode Prepare -Vpk @('pak03_dir.vpk', 'pak09_dir.vpk')
```

这里的编号只是示例，不固定对应某个英雄。Mod Manager 安装或重新排序后，包编号可能变化。脚本读取其本地清单和状态来显示 ID、名称，扫描仍以实际符合条件的 VPK 文件为准。

### 安装修复包或恢复原包

生成修复包后，控制台会输出 **Repair record:**，后面是 `batch-report.json` 的路径。使用该次运行给出的实际路径：

```powershell
.\AutoFix.ps1 -Mode Install -BatchReport 'C:\path\to\batch-report.json'
.\AutoFix.ps1 -Mode Restore -BatchReport 'C:\path\to\batch-report.json'
```

这两个操作都要求游戏已关闭。Restore 会恢复该次修复之前的 mod 包，皮肤本身仍然保留，并不是卸载 mod。安装和恢复期间，请让 Mod Manager 保持空闲。

如果准备修复后，目标包被更新、移动或重新编号，脚本会拒绝覆盖不符合预期的文件。请重新扫描当前安装，不要修改哈希或强行把旧记录用于另一个包。

## 脚本运行流程

1. **检查环境。** 选择兼容的 PowerShell/.NET 运行环境，加载缓存中的解析库，缺少依赖时下载并校验。
2. **查找 Deadlock。** 读取 Steam 注册表和库目录，或使用 `-GamePath`，定位当前原版包及主要 addons 目录。
3. **列出 mod 包。** 检查 `game\citadel\addons` 中的 `pakNN_dir.vpk`；有 Mod Manager 信息时，读取名称用于显示。
4. **匹配模型。** 查找支持的英雄模型路径，与当前原版模型对应。可识别的同目录备用模型名会映射到基础模型，无法匹配的自定义模型跳过。
5. **判断相机状态。** 识别已知的旧坐标轴特征、支持处理的镜头挂点缺失，以及下文说明的特定大厅绑定问题。不熟悉的差异留待人工检查。
6. **修改工作副本。** Prepare/Repair 模式下，将支持的原版镜头挂点和大厅设置写入提取出的模型副本；满足条件时适配大厅相机绑定。
7. **校验并重新打包。** 重新读取修复模型，检查必要相机引用和非相机数据保留情况，备份原 mod 并生成修复 VPK，验证 CRC 和未修改资源。
8. **按模式安装。** Prepare 到此停止；Repair 仅在游戏关闭且目标哈希仍符合记录时安装。先暂存替换文件，完成替换后再次检查 SHA256。
9. **显示结果并清理。** 正常完成时，Scan 和未生成修复包的运行不保留日志、报告或提取出的模型。已生成修复包的运行保留备份、修复包及 Install/Restore 所需记录。

Install/Restore 直接使用已有包和记录，不重新执行模型比较与修复流程。

## 结果说明

| 状态 | 含义 |
| --- | --- |
| `outdated` | 检测到能够识别的相机问题；Scan 不会修改它。 |
| `camera-matches` | 检查的游戏内镜头挂点与当前原版一致，且无需进行脚本支持的大厅修复；不代表完整兼容性测试通过。 |
| `prepared` | 修复包已准备并校验，尚未安装。 |
| `pending-game-exit` | Repair 已生成包，但需要退出游戏才能安装。 |
| `installed` / `restored` | 已完成文件替换和哈希校验。 |
| `unsupported` | 必要相机骨骼缺失，且不满足支持的适配条件，跳过该包。 |
| `unsupported-archive` | 不重写带签名或分卷的 mod 包。 |
| `review-needed` | 相机数据存在差异，但不符合已知修复特征。 |
| `no-hero-model` / `no-supported-camera-model` | 未找到支持的镜头模型，例如音效包或仅修改贴图的换色包。 |
| `failed` | 查看控制台错误；其他包独立处理。 |

## 文件存放与备份

默认位置为 `%LOCALAPPDATA%\deadlock-camera-fix`：

| 位置 | 内容 |
| --- | --- |
| `powershell-7.6.7` | 需要时下载的便携运行环境。 |
| `tools` | 模型和 VPK 解析库。 |
| `repairs\batch-…` | 修复包、原包备份、模型副本和修复记录。正常完成后，仅有需要保留的修复时才留下该批次目录。 |

脚本不会每次运行都保存日志。随修复包保留的 JSON 用于定位文件、验证哈希和恢复原包。仍需 Install 或 Restore 时，请保留整个修复目录。历史运行已生成的记录不会自动删除。

进阶参数：

| 参数 | 用途 |
| --- | --- |
| `-CacheRoot` | 更改缓存根目录。 |
| `-ToolRoot` | 更改解析库目录。 |
| `-OutputRoot` | 更改修复包及备份目录，请放在 addons 之外。 |
| `-ForcePortableRuntime` | 强制使用便携 PowerShell。 |

## 修复范围与限制

本工具处理能够识别的兼容性问题，不保证修复所有相机异常。它不会调整镜头偏好、输入设置、Mod Manager 配置或加载顺序，也不会重建缺失的动画骨架。

对于已知的 `portrait_camera_attach` 大厅问题，只有原版 `attachWorld` 是 `root_motion` 的无位移、无旋转子节点、两边根骨骼绑定变换一致且缩放为 1、相机只有一个权重为 1 的普通骨骼绑定时，才允许将缺失的 `attachWorld` 重新绑定到 `root_motion`。修复记录的 `remappedBones` 会记录转换。其他必要骨骼缺失仍不支持。以前修补过的模型即使游戏内镜头已一致，残留同类无效大厅引用也能被识别。

当前只扫描主要 addons 目录及支持的内嵌英雄模型，不覆盖自定义挂载、溢出 addon 目录或任意自定义模型路径。支持读取原版分卷包，不重新打包带签名或分卷的 mod 包。

文件校验（包括大厅绑定姿态的变换检查）不能证明动画或实际游戏效果正常。安装后请进游戏测试。Mod Manager 更新、重装可能覆盖修复，游戏更新也可能改变兼容性，发生这些变化后应重新扫描。

脚本使用 ValveResourceFormat 及其解析依赖。下载的第三方库遵循各自许可证，分发文件不包含游戏或皮肤资源。
