# Code Wiki - Roblox 游戏脚本项目

## 项目概述

本项目包含两个 Roblox Lua 脚本，主要功能是游戏界面翻译（汉化）和游戏功能增强。项目运行于 Roblox 游戏环境中。

## 项目结构

```
/workspace/
├── utcm.lua          # Crazy Multiverse Timeline 翻译脚本
├── the rake.lua      # The Rake 游戏脚本
└── .git/             # Git 版本控制
```

## 模块职责

### 1. utcm.lua - 疯狂多元宇宙时间线翻译器

**功能**: 为 "Crazy Multiverse Timeline" 游戏提供界面汉化功能。

**核心组件**:

| 组件 | 职责 |
|------|------|
| `Translations` | 中英文映射表，包含44条翻译规则 |
| `TextClasses` | 支持的文本对象类型（TextLabel, TextButton, TextBox） |

**关键函数**:

| 函数 | 说明 |
|------|------|
| `isTextObject(obj)` | 检测对象是否为文本对象 |
| `translateText(text)` | 翻译单个文本字符串，支持精确匹配和模糊匹配 |
| `translateObject(obj)` | 翻译单个对象的文本内容 |
| `scanContainer(container)` | 扫描容器内所有后代对象并翻译 |
| `listenContainer(container)` | 监听容器新增后代并即时翻译 |
| `setupFallbackTranslation()` | 设置备用翻译引擎（扫描+监听模式） |
| `setupHookTranslation()` | 设置Hook翻译引擎（元表劫持，未启用） |
| `setupTranslationEngine()` | 初始化翻译引擎 |

**翻译机制**:
- 精确匹配：直接查找 `Translations` 表
- 模糊匹配：遍历所有键，检测文本中是否包含英文关键词进行替换
- 定时扫描：每3秒全量扫描 `CoreGui` 和 `PlayerGui`

---

### 2. the rake.lua - The Rake 游戏脚本

**功能**: 为 "The Rake" 游戏提供功能增强、界面翻译和游戏辅助。

**核心组件**:

| 组件 | 职责 |
|------|------|
| `Translations` | 中英文映射表，包含191条翻译规则 |
| `TextClasses` | 支持的文本对象类型（TextLabel, TextButton, TextBox） |

**关键函数**:

| 函数 | 说明 |
|------|------|
| `isTextObject(obj)` | 检测对象是否为文本对象 |
| `translateText(text)` | 翻译单个文本字符串 |
| `translateObject(obj)` | 翻译单个对象的文本内容 |
| `scanContainer(container)` | 扫描容器内所有后代对象并翻译 |
| `listenContainer(container)` | 监听容器新增后代并即时翻译 |
| `setupFallbackTranslation()` | 设置备用翻译引擎 |
| `setupHookTranslation()` | 设置Hook翻译引擎（元表劫持，未启用） |
| `setupTranslationEngine()` | 初始化翻译引擎 |

**游戏功能** (通过远程脚本加载):
- ESP 透视功能（玩家、废品、空投、陷阱、信号枪）
- Killaura 自动战斗
- 无限耐力、夜视、无坠落伤害
- 主题定制系统
- 急救包自动使用
- 手电筒自定义
- UI 缩放和布局调整

---

## 核心模块共享设计

两个脚本采用相似的架构设计，共享以下通用模式：

### 翻译引擎架构

```
┌─────────────────────────────────────────┐
│         setupTranslationEngine()        │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│     setupFallbackTranslation()          │
│  ┌─────────────────────────────────┐    │
│  │ scanContainer() - 初始全量扫描   │    │
│  │ listenContainer() - 增量监听    │    │
│  │ 定时任务 - 每3秒全量扫描         │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

### 文本翻译流程

```
文本输入 → 类型检查 → 精确匹配查找
                      ↓ 未命中
                   模糊匹配遍历
                      ↓ 未命中
                    返回原文本
```

### Hook 模式（未启用）

通过修改 `game` 的元表 `__newindex`，拦截文本对象属性赋值并自动翻译。

---

## 依赖关系

### 外部依赖

| 依赖 | 来源 | 用途 |
|------|------|------|
| Roblox API | `game:GetService()` | 访问 CoreGui、Players 等服务 |
| 网络脚本 | `game:HttpGet()` | 加载远程 Lua 脚本 |

### 远程脚本

**utcm.lua**:
```
https://raw.githubusercontent.com/ILOVETHECOFFEEOFANDYANDLEYLEY/crazy-multiverse-timeline/main/no
```

**the rake.lua**:
```
https://rawscripts.net/raw/The-Rake-REMASTERED-Project-The-Rake-33649
```

---

## 运行方式

### 环境要求

- Roblox 游戏客户端（支持 Lua 5.1/ Luau）
- 支持 loadstring 和 game:HttpGet 的执行环境

### 执行方式

```lua
-- 方式1: loadstring 加载
loadstring(game:HttpGet("脚本URL"))()

-- 方式2: 直接执行脚本文件
-- 在 Roblox Studio 或游戏客户端中运行 Lua 文件
```

### 运行流程

1. 脚本初始化 `Translations` 和 `TextClasses`
2. 调用 `setupTranslationEngine()` 启动翻译系统
3. 定时扫描 + 实时监听双模式并行的翻译更新
4. 通过 `pcall` 加载远程脚本
5. 远程脚本执行游戏功能注入

---

## 配置说明

### 翻译表格式

```lua
Translations = {
    ["英文原文"] = "中文翻译",
    -- ...
}
```

### 支持的文本对象

- `TextLabel` - 文本标签
- `TextButton` - 文本按钮
- `TextBox` - 文本输入框

---

## 注意事项

1. **Hook 模式未启用**: `setupHookTranslation()` 函数存在但未被调用，当前仅使用纯扫描模式
2. **远程脚本依赖**: 两个脚本都依赖外部网络脚本加载，存在单点故障风险
3. **定时扫描开销**: 每3秒全量扫描可能影响性能
4. **翻译覆盖**: 模糊匹配可能产生意外的文本替换

---

## 安全考虑

- 所有网络请求使用 `pcall` 封装，防止脚本加载失败导致主流程中断
- 元表操作使用 `setreadonly` 保护，防止意外修改
- 文本翻译使用 `pcall` 封装，防止单个对象翻译失败
