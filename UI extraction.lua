-- Roblox UI 文本提取器 v24（响应式布局 + 圆形最小化 + 动画）
-- 本版改进（在 v23 基础上）：
-- 1. 【真正修复】复制按钮错位 bug：原代码复制按钮定位公式少减了一个按钮宽度，导致复制按钮
--    右侧超出行容器边界，被 Scroll 的 ClipsDescendants 裁掉一部分，看起来"错位/显示不全"
-- 2. 【真正修复】收藏/删除按钮显示不全：与上面同一处坐标计算连带问题，一并修正
-- 3. 【修复】文本框偶发不显示、需切换分区才恢复的bug：SetDisplay 在"空文本"分支里没有
--    使当前 token 失效，导致后台一个尚未跑完的旧渲染协程会在清空后继续插入行，造成显示错乱。
--    现在无论走哪个分支，一进入 SetDisplay 就立刻使旧 token 失效。
-- 4. 【新增】整个UI（含所有按钮/文字/间距）根据窗口大小连续缩放：UI越大，间距和字号越宽松；
--    UI越小，越紧凑。拖动右下角↘手柄时实时生效，且只更新已存在的行属性（不重建实例），
--    对低配设备友好。
-- 5. 【新增】最小化不再收起成标题栏，而是收起成一个可拖动的小圆点悬浮球，点击圆点还原。
-- 6. 【新增】动画效果：最小化/还原使用缩放+淡出/淡入过渡；切换分区时列表有轻微滑入过渡；
--    动画时长很短（≤0.22秒）且只对单个Frame做Tween（不逐行Tween），保证低配设备流畅。
-- 7. 【优化】自动刷新时如果内容与上次显示完全一致，不再重建整个列表（避免每1.5秒重复重建UI）。
-- 8. 保留全部核心功能：多分区、对象池、批量yield防卡顿、搜索、收藏栏、导出Lua、屏蔽、自动刷新、复制、删除、缩放

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local function getHui()
    local ok, hui = pcall(function()
        if gethui then return gethui() end
        return nil
    end)
    return ok and hui or nil
end

-- 清理旧UI
pcall(function()
    local old = CoreGui:FindFirstChild("AutoTextCollectorUI")
    if old then old:Destroy() end
end)
pcall(function()
    local old = PlayerGui:FindFirstChild("AutoTextCollectorUI")
    if old then old:Destroy() end
end)
pcall(function()
    local hui = getHui()
    if hui then
        local old = hui:FindFirstChild("AutoTextCollectorUI")
        if old then old:Destroy() end
    end
end)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AutoTextCollectorUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true

local hui = getHui()
if hui then
    ScreenGui.Parent = hui
elseif syn and syn.protect_gui then
    syn.protect_gui(ScreenGui)
    ScreenGui.Parent = CoreGui
else
    ScreenGui.Parent = PlayerGui
end

local Sections = {"全部", "PlayerGui", "Workspace", "CoreGui", "RobloxGui", "PlayerList", "第三方UI"}
local CurrentSection = "全部"

local SystemNames = {
    RobloxGui = true, PlayerList = true, Backpack = true, Chat = true,
    BubbleChat = true, ExperienceChat = true, TextChatService = true,
    TopBar = true, Topbar = true, Health = true, EmotesMenu = true,
    Chrome = true, InspectMenu = true, PurchasePrompt = true, ScreenshotHud = true,
}

local SectionData = {}
local BlockedData = {}
for _, name in ipairs(Sections) do
    SectionData[name] = {Texts = {}, Map = {}, AllText = "未检测到 UI 文本"}
    BlockedData[name] = {}
end

local FavoriteData = {Texts = {}, Map = {}}

local AutoRefreshEnabled = false
local AutoRefreshInterval = 1.5
local AutoScrollToBottom = true
local BlockMode = false
local Minimized = false
local Animating = false -- 最小化/还原动画进行中时，屏蔽重复触发
local CurrentDisplayText = ""
local LastNormalSize = Vector2.new(480, 340) -- 与默认UI大小匹配，移动端友好
local LastNormalPosition = nil
local LastCirclePosition = nil -- 悬浮圆点最后拖动到的位置

-- 当前UI整体缩放（由 LayoutUI 根据窗口大小计算），用于让文本列表行响应式排版
local CurrentUIScale = 1

-- ==================== 创建单行（支持对象池） ====================
local RowPool = {}
local MAX_POOL_SIZE = 400

-- 搜索防抖相关
local SearchDebounceTimer = nil
local LastSearchKeyword = ""
local LastSearchSection = ""
local LastSearchResult = nil

local function CleanText(text)
    text = tostring(text or "")
    text = text:gsub("<[^>]->", "")
    text = text:gsub("\r", "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function EscapeLuaString(str)
    str = tostring(str or "")
    str = str:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r")
         :gsub("\t", "\\t"):gsub("\"", "\\\"")
    return str
end

local function IsTextObject(obj)
    return obj and (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox"))
end

local function GetObjectPath(obj)
    local t = {}
    local cur = obj
    while cur and cur ~= game do
        table.insert(t, 1, cur.Name)
        cur = cur.Parent
    end
    return table.concat(t, "/")
end

local function IsSystemUI(obj)
    local cur = obj
    while cur and cur ~= game do
        if SystemNames[cur.Name] then return true end
        cur = cur.Parent
    end
    return false
end

local function IsVisible(obj)
    local cur = obj
    while cur and cur ~= game do
        local ok, v = pcall(function() return cur.Visible end)
        if ok and v == false then return false end
        cur = cur.Parent
    end
    return true
end

local function Rebuild(section)
    local data = SectionData[section]
    if not data then return end
    data.AllText = (#data.Texts == 0) and "未检测到 UI 文本" or table.concat(data.Texts, "\n")
end

local function Count(section)
    local data = SectionData[section]
    return data and #data.Texts or 0
end

local function AddText(section, text)
    text = CleanText(text)
    if text == "" or text == "未检测到 UI 文本" then return false end
    if BlockMode and BlockedData[section] and BlockedData[section][text] then return false end
    local data = SectionData[section]
    if not data or data.Map[text] then return false end
    data.Map[text] = true
    table.insert(data.Texts, text)
    Rebuild(section)
    return true
end

local function AddTextWithAll(section, text)
    local added = AddText(section, text)
    if section ~= "全部" then
        if AddText("全部", text) then added = true end
    end
    return added
end

local function RemoveText(section, text)
    text = CleanText(text)
    local data = SectionData[section]
    if not data then return end
    data.Map[text] = nil
    for i = #data.Texts, 1, -1 do
        if data.Texts[i] == text then table.remove(data.Texts, i) end
    end
    Rebuild(section)
end

local function RebuildAll()
    SectionData["全部"].Texts = {}
    SectionData["全部"].Map = {}
    SectionData["全部"].AllText = "未检测到 UI 文本"
    for _, section in ipairs(Sections) do
        if section ~= "全部" then
            for _, text in ipairs(SectionData[section].Texts) do
                AddText("全部", text)
            end
        end
    end
    Rebuild("全部")
end

local function BelongsToSection(obj, section)
    if not obj or obj:IsDescendantOf(ScreenGui) then return false end
    if not IsVisible(obj) then return false end
    local path = GetObjectPath(obj)
    local huiRoot = getHui()

    if section == "PlayerGui" then
        return obj:IsDescendantOf(PlayerGui)
    elseif section == "Workspace" then
        return obj:IsDescendantOf(Workspace)
    elseif section == "CoreGui" then
        return obj:IsDescendantOf(CoreGui)
    elseif section == "RobloxGui" then
        return obj:IsDescendantOf(CoreGui) and string.find(path, "RobloxGui", 1, true) ~= nil
    elseif section == "PlayerList" then
        return obj:IsDescendantOf(CoreGui) and string.find(path, "PlayerList", 1, true) ~= nil
    elseif section == "第三方UI" then
        local inGui = obj:IsDescendantOf(PlayerGui) or obj:IsDescendantOf(CoreGui) or (huiRoot and obj:IsDescendantOf(huiRoot))
        return inGui and not IsSystemUI(obj)
    elseif section == "全部" then
        return obj:IsDescendantOf(PlayerGui) or obj:IsDescendantOf(CoreGui) or obj:IsDescendantOf(Workspace) or (huiRoot and obj:IsDescendantOf(huiRoot))
    end
    return false
end

local function TryReadText(obj, section)
    if not BelongsToSection(obj, section) then return 0 end
    local added = 0
    local function save(v)
        if AddTextWithAll(section, v) then added = added + 1 end
    end
    pcall(function() save(obj.Text) end)
    pcall(function() save(obj.ContentText) end)
    pcall(function() save(obj.LocalizedText) end)
    pcall(function() save(obj.PlaceholderText) end)
    return added
end

local function ScanContainer(root, section)
    local added = 0
    if not root then return 0 end
    pcall(function()
        local descendants = root:GetDescendants()
        for i, obj in ipairs(descendants) do
            if IsTextObject(obj) then
                added = added + TryReadText(obj, section)
            end
            -- 每处理 80 个元素 yield 一次，防止大量 UI 元素时阻塞主线程导致卡顿
            if i % 80 == 0 then
                task.wait()
            end
        end
    end)
    return added
end

local function ScanSection(section)
    local added = 0
    local huiRoot = getHui()
    if section == "PlayerGui" then
        added = added + ScanContainer(PlayerGui, section)
    elseif section == "Workspace" then
        added = added + ScanContainer(Workspace, section)
    elseif section == "CoreGui" or section == "RobloxGui" or section == "PlayerList" then
        added = added + ScanContainer(CoreGui, section)
        if huiRoot and huiRoot ~= CoreGui then added = added + ScanContainer(huiRoot, section) end
    elseif section == "第三方UI" then
        added = added + ScanContainer(PlayerGui, section)
        added = added + ScanContainer(CoreGui, section)
        if huiRoot and huiRoot ~= CoreGui then added = added + ScanContainer(huiRoot, section) end
    elseif section == "全部" then
        added = added + ScanSection("PlayerGui")
        added = added + ScanSection("CoreGui")
        added = added + ScanSection("第三方UI")
    end
    Rebuild(section)
    Rebuild("全部")
    return added
end

-- ==================== UI 创建 ====================
local function New(class, props, parent)
    local obj = Instance.new(class)
    for k, v in pairs(props or {}) do obj[k] = v end
    if parent then obj.Parent = parent end
    return obj
end

local function Corner(obj, r)
    return New("UICorner", {CornerRadius = UDim.new(0, r or 8)}, obj)
end

local function Stroke(obj, color, t, tr)
    return New("UIStroke", {Color = color or Color3.fromRGB(70, 78, 96), Thickness = t or 1, Transparency = tr or 0.35}, obj)
end

local Theme = {
    Panel = Color3.fromRGB(15, 18, 25),
    Panel2 = Color3.fromRGB(21, 25, 34),
    Card = Color3.fromRGB(27, 32, 43),
    Card2 = Color3.fromRGB(32, 38, 51),
    Text = Color3.fromRGB(235, 238, 245),
    Muted = Color3.fromRGB(155, 165, 185),
    Stroke = Color3.fromRGB(58, 67, 84),
    Accent = Color3.fromRGB(82, 145, 245),
    AccentDark = Color3.fromRGB(48, 94, 168),
    Green = Color3.fromRGB(70, 150, 105),
    Red = Color3.fromRGB(180, 72, 78),
    Purple = Color3.fromRGB(105, 86, 150),
    Yellow = Color3.fromRGB(135, 105, 56),
    Cyan = Color3.fromRGB(70, 135, 150),
}

-- 通用动画辅助函数：轻量、单实例Tween，低配设备也能流畅运行
-- 支持可选的回调（动画完成后执行）
local function Tween(obj, props, duration, style, dir, callback)
    local info = TweenInfo.new(duration or 0.18, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out)
    local tw = TweenService:Create(obj, info, props)
    if callback then
        tw.Completed:Connect(callback)
    end
    tw:Play()
    return tw
end

local function StyleButton(btn, color)
    btn.BackgroundColor3 = color or Theme.Card
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = true
    Corner(btn, 8)
    Stroke(btn, Theme.Stroke, 1, 0.55)
end

local Main = New("Frame", {
    Size = UDim2.new(0, 480, 0, 340), -- 移动端更友好，默认较小；可拖动右下角↘手柄自由调整大小
    Position = UDim2.new(0.5, -240, 0.5, -170),
    BackgroundColor3 = Theme.Panel,
    BorderSizePixel = 0,
    Active = true,
    Draggable = true,
}, ScreenGui)
Corner(Main, 18)
Stroke(Main, Theme.Stroke, 1, 0.36)

local Title = New("TextLabel", {
    BackgroundTransparency = 1,
    Text = "UI 文本提取器 v24",
    TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.SourceSansBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextSize = 17
}, Main)

local MinBtn = New("TextButton", {
    Text = "-",
    TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.SourceSansBold,
    BackgroundColor3 = Theme.Card2,
    TextSize = 18
}, Main)
StyleButton(MinBtn, Theme.Card2)

local CloseBtn = New("TextButton", {
    Text = "X",
    TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.SourceSansBold,
    BackgroundColor3 = Theme.Red,
    TextSize = 16
}, Main)
StyleButton(CloseBtn, Theme.Red)

local Content = New("Frame", {BackgroundTransparency = 1}, Main)

local LeftPanel = New("ScrollingFrame", {
    BackgroundColor3 = Theme.Panel2,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0,0,0,0),
    ScrollBarThickness = 6,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    VerticalScrollBarInset = Enum.ScrollBarInset.Always,
    ScrollBarImageColor3 = Color3.fromRGB(170,170,175),
    ClipsDescendants = true
}, Content)
Corner(LeftPanel, 8)
Stroke(LeftPanel, Theme.Stroke, 1, 0.38)

local StatusLabel = New("TextLabel", {
    BackgroundTransparency = 1,
    Text = "状态：待刷新",
    TextColor3 = Color3.fromRGB(200,200,205),
    Font = Enum.Font.SourceSans,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextSize = 12
}, Content)

local SectionFrame = New("Frame", {
    BackgroundColor3 = Theme.Panel2,
    BorderSizePixel = 0,
    ClipsDescendants = true
}, LeftPanel)
Corner(SectionFrame, 8)
Stroke(SectionFrame, Theme.Stroke, 1, 0.38)

-- 搜索框：必须放在 Content 而非 LeftPanel（ScrollingFrame），
-- 因为 Roblox 的 ScrollingFrame 内嵌 TextBox 会导致输入捕获冲突，
-- 轻则无法输入，重则整个滚动面板操作失效
local SearchBox = New("TextBox", {
    Text = "",
    PlaceholderText = "搜索当前分区文本...",
    ClearTextOnFocus = false,
    BackgroundColor3 = Theme.Card,
    TextColor3 = Color3.new(1,1,1),
    PlaceholderColor3 = Color3.fromRGB(155,155,160),
    Font = Enum.Font.SourceSans,
    TextSize = 12
}, Content)
Corner(SearchBox, 8)
Stroke(SearchBox, Theme.Stroke, 1, 0.38)

local SearchBtn = New("TextButton", {
    Text = "搜索",
    TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.SourceSansBold,
    BackgroundColor3 = Theme.Purple,
    TextSize = 13
}, Content)
StyleButton(SearchBtn, Theme.Purple)

local Scroll = New("ScrollingFrame", {
    BackgroundColor3 = Theme.Card,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(0,0,0,0),
    ScrollBarThickness = 8,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    VerticalScrollBarInset = Enum.ScrollBarInset.Always,
    ScrollBarImageColor3 = Color3.fromRGB(170,170,175),
    ClipsDescendants = true
}, Content)
Corner(Scroll, 8)
Stroke(Scroll, Theme.Stroke, 1, 0.38)

local ListLayout = New("UIListLayout", {
    Padding = UDim.new(0, 4),
    SortOrder = Enum.SortOrder.LayoutOrder
}, Scroll)

local BottomBar = New("Frame", {BackgroundTransparency = 1, ClipsDescendants = true}, LeftPanel)

local RefreshBtn = New("TextButton", {Text = "刷新", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, BackgroundColor3 = Theme.AccentDark, TextSize = 11}, BottomBar)
local AutoCheckBtn = New("TextButton", {Text = "☐ 自动刷新", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, BackgroundColor3 = Theme.Yellow, TextSize = 11}, BottomBar)
local CopyBtn = New("TextButton", {Text = "复制显示", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, BackgroundColor3 = Theme.Green, TextSize = 11}, BottomBar)
local BlockBtn = New("TextButton", {Text = "屏蔽：关", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, BackgroundColor3 = Theme.Purple, TextSize = 11}, BottomBar)
local FavBtn = New("TextButton", {Text = "收藏栏", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, BackgroundColor3 = Theme.AccentDark, TextSize = 11}, BottomBar)
local ExportBtn = New("TextButton", {Text = "导出Lua", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, BackgroundColor3 = Theme.Cyan, TextSize = 11}, BottomBar)
local ClearBtn = New("TextButton", {Text = "清空", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, BackgroundColor3 = Theme.Red, TextSize = 11}, BottomBar)

for _, b in ipairs({RefreshBtn, AutoCheckBtn, CopyBtn, BlockBtn, FavBtn, ExportBtn, ClearBtn}) do
    StyleButton(b, b.BackgroundColor3)
end

local ResizeHandle = New("TextButton", {
    Size = UDim2.new(0, 22, 0, 22),
    AnchorPoint = Vector2.new(1,1),
    Position = UDim2.new(1, -3, 1, -3),
    Text = "↘",
    TextColor3 = Color3.new(1,1,1),
    TextSize = 14,
    Font = Enum.Font.SourceSansBold,
    BackgroundColor3 = Theme.Stroke,
    ZIndex = 10
}, Main)
StyleButton(ResizeHandle, Theme.Stroke)

-- ==================== 最小化悬浮圆点 ====================
local MiniCircle = New("TextButton", {
    Name = "MiniCircle",
    Size = UDim2.new(0, 54, 0, 54),
    Position = UDim2.new(0.5, -27, 0.5, -27),
    BackgroundColor3 = Theme.Accent,
    BorderSizePixel = 0,
    Text = "文本",
    TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.SourceSansBold,
    TextSize = 14,
    AutoButtonColor = true,
    Active = true,
    Draggable = true,
    Visible = false,
    ZIndex = 20,
}, ScreenGui)
Corner(MiniCircle, 27) -- 圆形
Stroke(MiniCircle, Theme.Stroke, 1.5, 0.2)

local SectionButtons = {}
for _, section in ipairs(Sections) do
    local b = New("TextButton", {
        Text = section.." [0]",
        TextColor3 = Color3.fromRGB(225,225,230),
        Font = Enum.Font.SourceSansBold,
        TextTruncate = Enum.TextTruncate.AtEnd,
        BorderSizePixel = 0,
        BackgroundColor3 = Theme.Card2,
        TextSize = 11
    }, SectionFrame)
    Corner(b, 6)
    Stroke(b, Theme.Stroke, 1, 0.45)
    SectionButtons[section] = b
end

-- ==================== 收藏栏 ====================
local FavoriteMain, FavoriteScroll, FavoriteListLayout, FavoriteStatus

local function RefreshFavoriteList()
    if not FavoriteScroll then return end
    for _, obj in ipairs(FavoriteScroll:GetChildren()) do
        if obj:IsA("Frame") or obj:IsA("TextButton") then obj:Destroy() end
    end
    for i, text in ipairs(FavoriteData.Texts) do
        local row = New("Frame", {
            Size = UDim2.new(1, -12, 0, 34),
            BackgroundColor3 = Theme.Card2,
            BorderSizePixel = 0,
            LayoutOrder = i
        }, FavoriteScroll)
        Corner(row, 6)
        Stroke(row, Theme.Stroke, 1, 0.45)

        local label = New("TextButton", {
            Size = UDim2.new(1, -100, 1, 0),
            Position = UDim2.new(0, 6, 0, 0),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = Theme.Text,
            TextSize = 13,
            Font = Enum.Font.Code,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd
        }, row)

        local del = New("TextButton", {
            Size = UDim2.new(0, 42, 0, 24),
            Position = UDim2.new(1, -88, 0.5, -12),
            Text = "删除",
            TextColor3 = Color3.new(1,1,1),
            TextSize = 12,
            Font = Enum.Font.SourceSansBold,
            BackgroundColor3 = Theme.Red
        }, row)

        local copy = New("TextButton", {
            Size = UDim2.new(0, 42, 0, 24),
            Position = UDim2.new(1, -44, 0.5, -12),
            Text = "复制",
            TextColor3 = Color3.new(1,1,1),
            TextSize = 12,
            Font = Enum.Font.SourceSansBold,
            BackgroundColor3 = Theme.Green
        }, row)

        StyleButton(del, del.BackgroundColor3)
        StyleButton(copy, copy.BackgroundColor3)

        label.MouseButton1Click:Connect(function() 
            if setclipboard then setclipboard(text) elseif toclipboard then toclipboard(text) end
        end)
        copy.MouseButton1Click:Connect(function() 
            if setclipboard then setclipboard(text) elseif toclipboard then toclipboard(text) end
        end)
        del.MouseButton1Click:Connect(function()
            FavoriteData.Map[text] = nil
            for n = #FavoriteData.Texts, 1, -1 do 
                if FavoriteData.Texts[n] == text then table.remove(FavoriteData.Texts, n); break end 
            end
            RefreshFavoriteList()
            if FavoriteStatus then FavoriteStatus.Text = "收藏列表｜共 "..#FavoriteData.Texts.." 条" end
        end)
    end

    if #FavoriteData.Texts == 0 then
        local empty = New("TextButton", {
            Size = UDim2.new(1, -12, 0, 34),
            BackgroundColor3 = Theme.Card2,
            BorderSizePixel = 0,
            Text = "  收藏列表为空",
            TextColor3 = Theme.Muted,
            TextSize = 13,
            Font = Enum.Font.SourceSans,
            TextXAlignment = Enum.TextXAlignment.Left
        }, FavoriteScroll)
        Corner(empty, 6)
        Stroke(empty, Theme.Stroke, 1, 0.45)
    end

    task.defer(function()
        task.wait()
        if FavoriteScroll and FavoriteListLayout then
            FavoriteScroll.CanvasSize = UDim2.new(0, 0, 0, FavoriteListLayout.AbsoluteContentSize.Y + 10)
        end
    end)
end

local function CreateFavoriteUI()
    if FavoriteMain and FavoriteMain.Parent then
        FavoriteMain.Visible = true
        RefreshFavoriteList()
        if FavoriteStatus then FavoriteStatus.Text = "收藏列表｜共 "..#FavoriteData.Texts.." 条" end
        return
    end

    FavoriteMain = New("Frame", {
        Size = UDim2.new(0, 380, 0, 310),
        Position = UDim2.new(0.5, -190, 0.5, -155),
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true
    }, ScreenGui)
    Corner(FavoriteMain, 12)
    Stroke(FavoriteMain, Theme.Stroke, 1, 0.2)

    New("TextLabel", {
        Size = UDim2.new(1, -42, 0, 32),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Text = "收藏列表",
        TextColor3 = Color3.new(1,1,1),
        TextSize = 16,
        Font = Enum.Font.SourceSansBold,
        TextXAlignment = Enum.TextXAlignment.Left
    }, FavoriteMain)

    local close = New("TextButton", {
        Size = UDim2.new(0, 32, 0, 32),
        Position = UDim2.new(1, -32, 0, 0),
        BackgroundColor3 = Theme.Red,
        Text = "X",
        TextColor3 = Color3.new(1,1,1),
        TextSize = 14,
        Font = Enum.Font.SourceSansBold
    }, FavoriteMain)
    StyleButton(close, close.BackgroundColor3)

    FavoriteStatus = New("TextLabel", {
        Size = UDim2.new(1, -20, 0, 20),
        Position = UDim2.new(0, 10, 0, 34),
        BackgroundTransparency = 1,
        TextColor3 = Color3.fromRGB(200,200,205),
        TextSize = 12,
        Font = Enum.Font.SourceSans,
        TextXAlignment = Enum.TextXAlignment.Left
    }, FavoriteMain)

    FavoriteScroll = New("ScrollingFrame", {
        Size = UDim2.new(1, -20, 1, -105),
        Position = UDim2.new(0, 10, 0, 58),
        BackgroundColor3 = Theme.Card,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(0,0,0,0),
        ScrollBarThickness = 8,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        VerticalScrollBarInset = Enum.ScrollBarInset.Always
    }, FavoriteMain)
    Corner(FavoriteScroll, 8)
    Stroke(FavoriteScroll, Theme.Stroke, 1, 0.38)

    FavoriteListLayout = New("UIListLayout", {
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder
    }, FavoriteScroll)

    local bottom = New("Frame", {
        Size = UDim2.new(1, -20, 0, 34),
        Position = UDim2.new(0, 10, 1, -40),
        BackgroundTransparency = 1
    }, FavoriteMain)

    local copyAll = New("TextButton", {
        Size = UDim2.new(0.333, -4, 1, 0),
        Position = UDim2.new(0, 0, 0, 0),
        Text = "复制显示",
        TextColor3 = Color3.new(1,1,1),
        Font = Enum.Font.SourceSansBold,
        TextSize = 13,
        BackgroundColor3 = Theme.Green
    }, bottom)

    local exportLua = New("TextButton", {
        Size = UDim2.new(0.333, -4, 1, 0),
        Position = UDim2.new(0.333, 4, 0, 0),
        Text = "导出Lua",
        TextColor3 = Color3.new(1,1,1),
        Font = Enum.Font.SourceSansBold,
        TextSize = 13,
        BackgroundColor3 = Theme.Cyan
    }, bottom)

    local clearAll = New("TextButton", {
        Size = UDim2.new(0.333, -4, 1, 0),
        Position = UDim2.new(0.666, 8, 0, 0),
        Text = "清空全部",
        TextColor3 = Color3.new(1,1,1),
        Font = Enum.Font.SourceSansBold,
        TextSize = 13,
        BackgroundColor3 = Theme.Red
    }, bottom)

    StyleButton(copyAll, copyAll.BackgroundColor3)
    StyleButton(exportLua, exportLua.BackgroundColor3)
    StyleButton(clearAll, clearAll.BackgroundColor3)

    close.MouseButton1Click:Connect(function() FavoriteMain.Visible = false end)
    copyAll.MouseButton1Click:Connect(function()
        if setclipboard then setclipboard(table.concat(FavoriteData.Texts, "\n"))
        elseif toclipboard then toclipboard(table.concat(FavoriteData.Texts, "\n")) end
    end)
    exportLua.MouseButton1Click:Connect(function()
        -- 简单导出
        local lines = {"-- UI文本导出 (收藏列表)", "return {"}
        for _, t in ipairs(FavoriteData.Texts) do
            table.insert(lines, '    "'..EscapeLuaString(t)..'",')
        end
        table.insert(lines, "}")
        local luaText = table.concat(lines, "\n")
        if setclipboard then setclipboard(luaText) elseif toclipboard then toclipboard(luaText) end
        if writefile then
            local ok, err = pcall(function() writefile("UITextExport_收藏.lua", luaText) end)
            if not ok then print("writefile 失败:", err) end
        end
    end)
    clearAll.MouseButton1Click:Connect(function()
        FavoriteData.Texts = {}
        FavoriteData.Map = {}
        RefreshFavoriteList()
        if FavoriteStatus then FavoriteStatus.Text = "收藏列表｜共 0 条" end
    end)

    FavoriteStatus.Text = "收藏列表｜共 "..#FavoriteData.Texts.." 条"
    RefreshFavoriteList()
end

local function AddFavorite(text)
    text = CleanText(text)
    if text == "" then return end
    if not FavoriteData.Map[text] then
        FavoriteData.Map[text] = true
        table.insert(FavoriteData.Texts, text)
    end
    CreateFavoriteUI()
    RefreshFavoriteList()
    if FavoriteStatus then FavoriteStatus.Text = "收藏列表｜共 "..#FavoriteData.Texts.." 条" end
end

-- ==================== 显示相关 ====================
local DisplayedLines = {}
local DisplayedRows = {}
local CurrentUpdateToken = 0

local function ClearScroll()
    for _, obj in ipairs(Scroll:GetChildren()) do
        if obj:IsA("Frame") then
            obj.Visible = false
            obj.Parent = nil
            if #RowPool < MAX_POOL_SIZE then
                table.insert(RowPool, obj)
            else
                obj:Destroy()
            end
        end
    end
    DisplayedRows = {}
    DisplayedLines = {}
end

local function ResizeCanvas()
    task.defer(function()
        task.wait()
        if Scroll and ListLayout then
            Scroll.CanvasSize = UDim2.new(0, 0, 0, ListLayout.AbsoluteContentSize.Y + 10)
        end
    end)
end

local function ScrollBottom()
    if not AutoScrollToBottom then return end
    task.defer(function()
        task.wait()
        if Scroll then
            local maxY = math.max(0, Scroll.CanvasSize.Y.Offset - Scroll.AbsoluteSize.Y)
            Scroll.CanvasPosition = Vector2.new(0, maxY)
        end
    end)
end

local function GetCurrentText()
    Rebuild(CurrentSection)
    return SectionData[CurrentSection] and SectionData[CurrentSection].AllText or "未检测到 UI 文本"
end

-- ==================== 行尺寸计算（响应式：UI越大越宽松，越小越紧凑） ====================
-- 根据 CurrentUIScale（由 LayoutUI 依据窗口大小计算）连续缩放，而不是简单的两档切换
local function ComputeRowMetrics()
    local s = CurrentUIScale or 1
    local rowH = math.floor(math.clamp(36 * s, 28, 52))
    local actionW = math.floor(math.clamp(40 * s, 30, 58))
    local actionH = math.floor(math.clamp(23 * s, 18, 32))
    local rightPad = math.floor(math.clamp(7 * s, 5, 12))
    local gap = math.floor(math.clamp(4 * s, 3, 8))
    local labelTextSize = math.floor(math.clamp(12.5 * s, 10, 17))
    local actionTextSize = math.floor(math.clamp(11 * s, 9, 14))
    local compact = actionW <= 36 -- 窄屏下按钮文字用单字简写
    -- 从右到左：rightPad | 复制 | gap | 删除 | gap | 添加 | gap(与标签的间隔)
    local actionsWidth = rightPad + actionW * 3 + gap * 2 + gap
    return {
        rowH = rowH, actionW = actionW, actionH = actionH, rightPad = rightPad, gap = gap,
        labelTextSize = labelTextSize, actionTextSize = actionTextSize,
        actionsWidth = actionsWidth, compact = compact,
    }
end

-- 将尺寸应用到一个已存在的行（不重建实例，开销极小，可在拖动手柄时实时调用）
local function ApplyRowMetrics(row, m)
    if not row or not row.Parent then return end
    row.Size = UDim2.new(1, -12, 0, m.rowH)

    local label = row:FindFirstChild("Label")
    local add = row:FindFirstChild("AddBtn")
    local del = row:FindFirstChild("DelBtn")
    local copy = row:FindFirstChild("CopyBtn")
    if not (label and add and del and copy) then return end

    label.Size = UDim2.new(1, -m.actionsWidth, 1, 0)
    label.TextSize = m.labelTextSize

    -- 从右向左依次排列，修复原版复制按钮公式少减一个按钮宽度导致超出边界的问题
    copy.Size = UDim2.new(0, m.actionW, 0, m.actionH)
    copy.Position = UDim2.new(1, -(m.rightPad + m.actionW), 0.5, -m.actionH/2)
    copy.Text = m.compact and "复" or "复制"
    copy.TextSize = m.actionTextSize

    del.Size = UDim2.new(0, m.actionW, 0, m.actionH)
    del.Position = UDim2.new(1, -(m.rightPad + m.actionW * 2 + m.gap), 0.5, -m.actionH/2)
    del.Text = m.compact and "删" or "删除"
    del.TextSize = m.actionTextSize

    add.Size = UDim2.new(0, m.actionW, 0, m.actionH)
    add.Position = UDim2.new(1, -(m.rightPad + m.actionW * 3 + m.gap * 2), 0.5, -m.actionH/2)
    add.Text = m.compact and "藏" or "添加"
    add.TextSize = m.actionTextSize
end

-- 拖动手柄/窗口尺寸变化时调用：只更新已显示行的属性，不重建任何实例，低配设备也流畅
local function RestyleVisibleRows()
    local m = ComputeRowMetrics()
    for _, row in ipairs(DisplayedRows) do
        ApplyRowMetrics(row, m)
    end
end

-- ==================== 创建单行（支持对象池） ====================
local function CreateDisplayRow(line, index)
    local displayLine = (#line > 500) and (string.sub(line, 1, 500) .. "...") or line
    local m = ComputeRowMetrics()

    local row = table.remove(RowPool)
    if row then
        row.Visible = true
        row.Size = UDim2.new(1, -12, 0, m.rowH)
        row.LayoutOrder = index
        row.Parent = Scroll  -- 从对象池取出的行 Parent 已被 ClearScroll 设为 nil，必须重新挂回
        for _, child in ipairs(row:GetChildren()) do
            -- 保留 UI 装饰（圆角、描边），清理其余所有子对象，防止对象池复用时残留旧数据
            if not (child:IsA("UICorner") or child:IsA("UIStroke")) then
                child:Destroy()
            end
        end
    else
        row = New("Frame", {
            Size = UDim2.new(1, -12, 0, m.rowH),
            BackgroundColor3 = Theme.Card2,
            BorderSizePixel = 0,
            LayoutOrder = index
        }, Scroll)
        Corner(row, 7)
        Stroke(row, Theme.Stroke, 1, 0.50)
    end

    local label = New("TextButton", {
        Name = "Label",
        Size = UDim2.new(1, -m.actionsWidth, 1, 0),
        Position = UDim2.new(0, 8, 0, 0),
        BackgroundTransparency = 1,
        Text = displayLine,
        TextColor3 = Theme.Text,
        TextSize = m.labelTextSize,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd
    }, row)
    label:SetAttribute("FullText", displayLine)

    -- 从右向左：复制 -> 删除 -> 添加（修复版定位公式，三个按钮都完整落在行边界内）
    local copy = New("TextButton", {
        Name = "CopyBtn",
        Size = UDim2.new(0, m.actionW, 0, m.actionH),
        Position = UDim2.new(1, -(m.rightPad + m.actionW), 0.5, -m.actionH/2),
        Text = m.compact and "复" or "复制",
        TextColor3 = Color3.new(1,1,1),
        TextSize = m.actionTextSize,
        Font = Enum.Font.SourceSansBold,
        BackgroundColor3 = Theme.Green
    }, row)

    local del = New("TextButton", {
        Name = "DelBtn",
        Size = UDim2.new(0, m.actionW, 0, m.actionH),
        Position = UDim2.new(1, -(m.rightPad + m.actionW * 2 + m.gap), 0.5, -m.actionH/2),
        Text = m.compact and "删" or "删除",
        TextColor3 = Color3.new(1,1,1),
        TextSize = m.actionTextSize,
        Font = Enum.Font.SourceSansBold,
        BackgroundColor3 = Theme.Red
    }, row)

    local add = New("TextButton", {
        Name = "AddBtn",
        Size = UDim2.new(0, m.actionW, 0, m.actionH),
        Position = UDim2.new(1, -(m.rightPad + m.actionW * 3 + m.gap * 2), 0.5, -m.actionH/2),
        Text = m.compact and "藏" or "添加",
        TextColor3 = Color3.new(1,1,1),
        TextSize = m.actionTextSize,
        Font = Enum.Font.SourceSansBold,
        BackgroundColor3 = Theme.AccentDark
    }, row)

    StyleButton(add, add.BackgroundColor3)
    StyleButton(del, del.BackgroundColor3)
    StyleButton(copy, copy.BackgroundColor3)

    label.MouseButton1Click:Connect(function()
        if setclipboard then setclipboard(line) elseif toclipboard then toclipboard(line) end
    end)
    copy.MouseButton1Click:Connect(function()
        if setclipboard then setclipboard(line) elseif toclipboard then toclipboard(line) end
    end)
    add.MouseButton1Click:Connect(function() AddFavorite(line) end)

    del.MouseButton1Click:Connect(function()
        local oldPos = Scroll.CanvasPosition
        if BlockMode then
            if CurrentSection == "全部" then
                for _, sec in ipairs(Sections) do BlockedData[sec][line] = true end
            else
                BlockedData[CurrentSection][line] = true
                BlockedData["全部"][line] = true
            end
        end
        if CurrentSection == "全部" then
            for _, sec in ipairs(Sections) do RemoveText(sec, line) end
        else
            RemoveText(CurrentSection, line)
            RebuildAll()
        end
        SetDisplay(GetCurrentText(), false)
        task.defer(function()
            task.wait()
            if Scroll then
                local maxY = math.max(0, Scroll.CanvasSize.Y.Offset - Scroll.AbsoluteSize.Y)
                Scroll.CanvasPosition = Vector2.new(0, math.clamp(oldPos.Y, 0, maxY))
            end
        end)
        UpdateSectionButtons()
    end)

    return row
end

-- ==================== 修复版 SetDisplay（关键修复） ====================
-- animate: 是否在重建列表时做一个轻微滑入过渡（仅用于切换分区/搜索等主动操作，
--          自动刷新不传这个参数，避免每次自动刷新都做动画）
-- forceRebuild: 强制重建，即使内容和当前显示的一致
local SetDisplay

SetDisplay = function(text, autoBottom, animate, forceRebuild)
    CurrentDisplayText = text

    -- 关键修复：无论接下来走哪个分支，都先让"旧的渲染协程"失效。
    -- 旧版本只在非空分支里递增 token，导致空文本分支不会打断后台正在
    -- 分批插入行的旧协程，二者交错执行就会出现"文本框显示错乱，需要
    -- 切换分区才能恢复正常"的问题。现在统一在入口处递增，彻底杜绝竞态。
    CurrentUpdateToken = CurrentUpdateToken + 1
    local token = CurrentUpdateToken

    local newLines = {}
    for line in string.gmatch(tostring(text or "") .. "\n", "(.-)\n") do
        line = CleanText(line)
        if line ~= "" then table.insert(newLines, line) end
    end

    if #newLines == 0 then
        ClearScroll()
        local empty = New("TextButton", {
            Size = UDim2.new(1, -12, 0, 34),
            BackgroundColor3 = Theme.Card2,
            BorderSizePixel = 0,
            Text = "  未检测到 UI 文本",
            TextColor3 = Theme.Muted,
            TextSize = 13,
            Font = Enum.Font.SourceSans,
            TextXAlignment = Enum.TextXAlignment.Left,
            LayoutOrder = 1
        }, Scroll)
        Corner(empty, 6)
        Stroke(empty, Theme.Stroke, 1, 0.45)
        DisplayedLines = {}
        ResizeCanvas()
        if autoBottom then ScrollBottom() end
        return
    end

    -- 性能优化：内容和当前显示的完全一致时（自动刷新常见情况），跳过整表重建，
    -- 只同步一次尺寸即可，大幅减轻低配设备负担。
    -- 注意：必须同时检查 DisplayedRows 非空，否则若上次 ClearScroll 已清空行但
    -- DisplayedLines 尚未更新（不应出现，但防御性编程），会导致跳过重建却无行可渲染。
    if not forceRebuild and #newLines == #DisplayedLines and #DisplayedRows > 0 then
        local same = true
        for i = 1, #newLines do
            if newLines[i] ~= DisplayedLines[i] then same = false; break end
        end
        if same then
            RestyleVisibleRows()
            if autoBottom then ScrollBottom() end
            return
        end
    end

    -- 总是全量重建 + token 保护（彻底解决重入bug）
    ClearScroll()

    if animate then
        -- 分区切换/搜索时：列表从上方轻微滑入，比简单的位移更自然
        local origCanvasPos = Scroll.CanvasPosition
        Scroll.CanvasPosition = Vector2.new(origCanvasPos.X, math.max(0, origCanvasPos.Y - 30))
        Tween(Scroll, {CanvasPosition = origCanvasPos}, 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    end

    for i, line in ipairs(newLines) do
        if CurrentUpdateToken ~= token then return end
        local row = CreateDisplayRow(line, i)
        table.insert(DisplayedRows, row)
        if i % 12 == 0 then
            task.wait()
            if CurrentUpdateToken ~= token then return end
        end
    end

    DisplayedLines = newLines
    ResizeCanvas()
    if autoBottom then ScrollBottom() end
end

local function UpdateStatus(msg)
    local block = BlockMode and "屏蔽开" or "屏蔽关"
    local auto = AutoRefreshEnabled and "自动刷新开" or "自动刷新关"
    if msg and msg ~= "" then
        StatusLabel.Text = "状态："..auto.."｜"..CurrentSection.."｜"..Count(CurrentSection).."条｜"..block.."｜"..msg
    else
        StatusLabel.Text = "状态："..auto.."｜"..CurrentSection.."｜"..Count(CurrentSection).."条｜"..block
    end
end

local function UpdateSectionButtons()
    for name, b in pairs(SectionButtons) do
        if name == CurrentSection then
            b.BackgroundColor3 = Theme.Accent
            b.TextColor3 = Color3.new(1,1,1)
        else
            b.BackgroundColor3 = Theme.Card2
            b.TextColor3 = Theme.Text
        end
        b.Text = name.." ["..Count(name).."]"
    end
end

local function SearchNow()
    local keyword = CleanText(SearchBox.Text)
    local data = SectionData[CurrentSection]
    if not data then return end
    if keyword == "" then
        LastSearchKeyword = ""
        LastSearchResult = nil
        SetDisplay(GetCurrentText(), false, true)
        Scroll.CanvasPosition = Vector2.new(0,0)
        UpdateStatus("显示全部文本")
        return
    end
    -- 缓存：关键词和分区都没变，结果也不变则跳过重复搜索
    if keyword == LastSearchKeyword and CurrentSection == LastSearchSection and LastSearchResult then
        return
    end
    LastSearchKeyword = keyword
    LastSearchSection = CurrentSection
    local result = {}
    local lower = string.lower(keyword)
    for _, line in ipairs(data.Texts) do
        if string.find(string.lower(line), lower, 1, true) then
            table.insert(result, line)
        end
    end
    LastSearchResult = result
    if #result == 0 then
        SetDisplay("没有搜索到包含【"..keyword.."】的文本", false, true, true)
        UpdateStatus("搜索结果 0 条")
    else
        SetDisplay(table.concat(result, "\n"), false, true, true)
        UpdateStatus("搜索结果 "..#result.." 条")
    end
    Scroll.CanvasPosition = Vector2.new(0,0)
end

local function RefreshDisplay(added)
    UpdateSectionButtons()
    if CleanText(SearchBox.Text) ~= "" then
        SearchNow()
    else
        SetDisplay(GetCurrentText(), added and added > 0)
        if added and added > 0 then UpdateStatus("新增 "..added.." 条") else UpdateStatus("暂无新增") end
    end
end

local function ManualRefresh()
    local added = ScanSection(CurrentSection)
    RefreshDisplay(added)
end

local function ClearCurrent()
    local data = SectionData[CurrentSection]
    if not data then return end
    if BlockMode then
        if CurrentSection == "全部" then
            for _, sec in ipairs(Sections) do
                for _, text in ipairs(SectionData[sec].Texts) do BlockedData[sec][text] = true end
            end
        else
            for _, text in ipairs(data.Texts) do
                BlockedData[CurrentSection][text] = true
                BlockedData["全部"][text] = true
            end
        end
    end
    data.Texts = {}
    data.Map = {}
    data.AllText = "未检测到 UI 文本"
    if CurrentSection == "全部" then
        for _, sec in ipairs(Sections) do
            SectionData[sec].Texts = {}
            SectionData[sec].Map = {}
            SectionData[sec].AllText = "未检测到 UI 文本"
        end
    else
        RebuildAll()
    end
    SearchBox.Text = ""
    SetDisplay(GetCurrentText(), false)
    Scroll.CanvasPosition = Vector2.new(0,0)
    UpdateSectionButtons()
    UpdateStatus(BlockMode and "已清空并加入屏蔽" or "已清空当前分区")
end

-- ==================== 响应式 LayoutUI（UI越大越宽松，越小越紧凑） ====================
-- 与旧版最大区别：不再是"大屏/小屏"两档切换，而是根据窗口的实际宽高连续计算一个缩放系数 scale，
-- 所有间距、按钮尺寸、字号都乘以这个系数（并做min/max限制防止极端情况下过大或过小到无法使用）。
-- 拖动右下角↘手柄时，Main.AbsoluteSize 变化会实时触发本函数，所以整个UI会跟手缩放。
local function LayoutUI()
    if Minimized or Animating then return end

    local w, h = Main.AbsoluteSize.X, Main.AbsoluteSize.Y
    if w <= 0 then w = 480 end
    if h <= 0 then h = 340 end

    -- 基准尺寸为默认的 480x340，scale=1 时还原成默认版式
    local scale = math.clamp(math.min(w / 480, h / 340), 0.72, 1.7)
    CurrentUIScale = scale

    local pad = math.floor(math.clamp(8 * scale, 6, 14))
    local titleH = math.floor(math.clamp(32 * scale, 26, 48))
    local sideW = math.floor(math.clamp(155 * scale, 120, 240))
    local statusH = math.floor(math.clamp(20 * scale, 16, 30))
    local searchH = math.floor(math.clamp(26 * scale, 20, 38))
    local gap = math.floor(math.clamp(5 * scale, 3, 10))
    local actionH = math.floor(math.clamp(24 * scale, 18, 36))
    local sectionH = math.floor(math.clamp(24 * scale, 18, 36))
    local actionCount = 7

    local titleTextSize = math.floor(math.clamp(17 * scale, 13, 24))
    local topBtnSize = math.floor(math.clamp(28 * scale, 22, 40))
    local sectionTextSize = math.floor(math.clamp(11 * scale, 9, 16))
    local searchTextSize = math.floor(math.clamp(12 * scale, 10, 17))
    local searchBtnTextSize = math.floor(math.clamp(13 * scale, 10, 18))
    local actionTextSize = math.floor(math.clamp(11 * scale, 9, 16))
    local statusTextSize = math.floor(math.clamp(12 * scale, 10, 17))

    Title.Size = UDim2.new(1, -math.floor(80*scale), 0, titleH)
    Title.Position = UDim2.new(0, pad, 0, 0)
    Title.TextSize = titleTextSize

    MinBtn.Size = UDim2.new(0, topBtnSize, 0, topBtnSize)
    MinBtn.Position = UDim2.new(1, -(topBtnSize*2 + 4), 0, 2)
    MinBtn.TextSize = math.floor(math.clamp(18 * scale, 14, 24))

    CloseBtn.Size = UDim2.new(0, topBtnSize, 0, topBtnSize)
    CloseBtn.Position = UDim2.new(1, -(topBtnSize + 2), 0, 2)
    CloseBtn.TextSize = math.floor(math.clamp(16 * scale, 12, 22))

    Content.Size = UDim2.new(1, 0, 1, -titleH)
    Content.Position = UDim2.new(0, 0, 0, titleH)

    LeftPanel.Size = UDim2.new(0, sideW, 1, -pad*2)
    LeftPanel.Position = UDim2.new(0, pad, 0, pad)

    local sectionPanelH = #Sections * sectionH + (#Sections + 1) * gap
    SectionFrame.Size = UDim2.new(1, -pad, 0, sectionPanelH)
    SectionFrame.Position = UDim2.new(0, math.floor(pad/2), 0, gap)

    for i, section in ipairs(Sections) do
        local b = SectionButtons[section]
        b.Size = UDim2.new(1, -pad, 0, sectionH)
        b.Position = UDim2.new(0, math.floor(pad/2), 0, gap + (i-1) * (sectionH + gap))
        b.TextSize = sectionTextSize
    end

    -- LeftPanel 只包含分区按钮 + 功能按钮，不再包含搜索框
    local sideY = gap + sectionPanelH + gap
    local actionPanelH = actionCount * actionH + (actionCount-1) * gap
    BottomBar.Size = UDim2.new(1, -pad, 0, actionPanelH)
    BottomBar.Position = UDim2.new(0, math.floor(pad/2), 0, sideY)

    local leftContentH = sideY + actionPanelH + gap
    LeftPanel.CanvasSize = UDim2.new(0, 0, 0, leftContentH)

    local buttons = {RefreshBtn, AutoCheckBtn, CopyBtn, BlockBtn, FavBtn, ExportBtn, ClearBtn}
    for i, b in ipairs(buttons) do
        b.Size = UDim2.new(1, -pad, 0, actionH)
        b.Position = UDim2.new(0, math.floor(pad/2), 0, (i-1) * (actionH + gap))
        b.TextSize = actionTextSize
    end

    local listX = pad * 2 + sideW
    local rightW = math.max(120, w - listX - pad)

    StatusLabel.Size = UDim2.new(0, rightW, 0, statusH)
    StatusLabel.Position = UDim2.new(0, listX, 0, pad)
    StatusLabel.TextSize = statusTextSize

    -- 搜索框放在右侧区域：状态栏下方、文本列表上方，横跨整个右侧宽度
    local searchRowY = pad + statusH + gap
    SearchBtn.Size = UDim2.new(0, searchH * 2, 0, searchH)
    SearchBtn.Position = UDim2.new(0, listX, 0, searchRowY)
    SearchBtn.TextSize = searchBtnTextSize

    SearchBox.Visible = true
    SearchBox.Size = UDim2.new(0, rightW - searchH * 2 - gap, 0, searchH)
    SearchBox.Position = UDim2.new(0, listX + searchH * 2 + gap, 0, searchRowY)
    SearchBox.TextSize = searchTextSize

    local scrollY = searchRowY + searchH + gap
    Scroll.Size = UDim2.new(0, rightW, 1, -scrollY - pad)
    Scroll.Position = UDim2.new(0, listX, 0, scrollY)

    ResizeHandle.Visible = true
    ResizeCanvas()

    -- 同步已经显示在列表里的行（复制/删除/添加按钮 + 文本行高）到新的缩放比例，
    -- 只更新属性、不重建实例，所以拖动手柄的过程中也很流畅
    RestyleVisibleRows()
end

-- ==================== 事件连接 ====================
for _, section in ipairs(Sections) do
    SectionButtons[section].MouseButton1Click:Connect(function()
        CurrentSection = section
        SearchBox.Text = ""
        SetDisplay(GetCurrentText(), false, true, true)
        Scroll.CanvasPosition = Vector2.new(0,0)
        UpdateSectionButtons()
        UpdateStatus("已切换分区")
    end)
end

RefreshBtn.MouseButton1Click:Connect(function() ManualRefresh() end)

AutoCheckBtn.MouseButton1Click:Connect(function()
    AutoRefreshEnabled = not AutoRefreshEnabled
    AutoCheckBtn.Text = AutoRefreshEnabled and "☑ 自动刷新" or "☐ 自动刷新"
    AutoCheckBtn.BackgroundColor3 = AutoRefreshEnabled and Theme.Green or Theme.Yellow
    UpdateStatus(AutoRefreshEnabled and "自动刷新已开启" or "自动刷新已关闭")
end)

CopyBtn.MouseButton1Click:Connect(function()
    if setclipboard then setclipboard(CurrentDisplayText)
    elseif toclipboard then toclipboard(CurrentDisplayText) end
    UpdateStatus("已复制当前显示")
end)

BlockBtn.MouseButton1Click:Connect(function()
    BlockMode = not BlockMode
    if BlockMode then
        BlockBtn.Text = "屏蔽：开"
        BlockBtn.BackgroundColor3 = Theme.Purple
        UpdateStatus("屏蔽文本已开启")
    else
        BlockBtn.Text = "屏蔽：关"
        BlockBtn.BackgroundColor3 = Theme.Purple
        for _, sec in ipairs(Sections) do BlockedData[sec] = {} end
        UpdateStatus("屏蔽文本已关闭")
    end
end)

FavBtn.MouseButton1Click:Connect(function()
    CreateFavoriteUI()
    UpdateStatus("已打开收藏栏")
end)

ExportBtn.MouseButton1Click:Connect(function()
    local data = SectionData[CurrentSection]
    local safeName = tostring(CurrentSection):gsub("[\\/:*?\"<>|]", "_")
    local texts = data and data.Texts or {}
    local lines = {"-- UI文本导出", "-- 分区："..CurrentSection, "-- 数量："..#texts, "", "return {"}
    for _, t in ipairs(texts) do
        table.insert(lines, '    "'..EscapeLuaString(t)..'",')
    end
    table.insert(lines, "}")
    local luaText = table.concat(lines, "\n")
    if setclipboard then setclipboard(luaText) elseif toclipboard then toclipboard(luaText) end
    if writefile then
        local ok, err = pcall(function() writefile("UITextExport_"..safeName..".lua", luaText) end)
        if not ok then
            UpdateStatus("导出失败：无法写入文件")
            print("writefile 失败:", err)
            return
        end
    end
    UpdateStatus("已导出Lua")
end)

SearchBtn.MouseButton1Click:Connect(function()
    SearchNow()
end)

-- 搜索框获焦/失焦时的视觉高亮反馈
SearchBox.Focused:Connect(function()
    Tween(SearchBox, {BackgroundColor3 = Theme.AccentDark}, 0.15)
end)
SearchBox.FocusLost:Connect(function()
    Tween(SearchBox, {BackgroundColor3 = Theme.Card}, 0.15)
end)

SearchBox.FocusLost:Connect(function(enter)
    if enter then
        -- 回车键提交搜索
        SearchNow()
    elseif CleanText(SearchBox.Text) ~= "" then
        -- 移动端点击其他区域失去焦点时也自动搜索（不一定有回车键）
        SearchNow()
    end
end)

-- 搜索框文本变化时防抖搜索（0.3秒），避免每输入一个字符就重建列表
SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
    if SearchDebounceTimer then
        task.cancel(SearchDebounceTimer)
        SearchDebounceTimer = nil
    end
    local keyword = CleanText(SearchBox.Text)
    if keyword ~= "" then
        SearchDebounceTimer = task.delay(0.3, function()
            SearchDebounceTimer = nil
            SearchNow()
        end)
    end
end)

ClearBtn.MouseButton1Click:Connect(function() ClearCurrent() end)

-- ==================== 最小化 <-> 悬浮圆点（带动画） ====================
-- 需求：点击[-]不再收缩成标题栏，而是收缩成一个可拖动的小圆点；再次点击圆点还原，
-- 且过程要有缩放/淡入淡出动画，同时保证在低配设备上依旧流畅（只对单个Frame做Tween）。
local MIN_ANIM_TIME = 0.22

local function GetCircleTargetPosition()
    if LastCirclePosition then return LastCirclePosition end
    -- 默认目标：屏幕左侧居中
    local vw, vh = 800, 600
    pcall(function()
        local cam = Workspace.CurrentCamera
        if cam then vw, vh = cam.ViewportSize.X, cam.ViewportSize.Y end
    end)
    local x = math.clamp(16, 10, math.max(10, vw - 64))
    local y = math.clamp(math.floor(vh / 2 - 80), 10, math.max(10, vh - 64))
    return UDim2.new(0, x, 0, y)
end

local function MinimizeToCircle()
    if Animating then return end
    Animating = true
    Minimized = true

    LastNormalSize = Vector2.new(Main.AbsoluteSize.X, Main.AbsoluteSize.Y)
    LastNormalPosition = Main.Position

    -- 收起时立即隐藏内容区，避免子元素在缩小动画期间来回重排（对低配设备更友好）
    Content.Visible = false
    ResizeHandle.Visible = false
    Main.BackgroundTransparency = 0

    local target = GetCircleTargetPosition()
    Tween(Main, {
        Size = UDim2.new(0, 40, 0, 40),
        Position = target,
        BackgroundTransparency = 1,
    }, MIN_ANIM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

    task.delay(MIN_ANIM_TIME, function()
        Main.Visible = false
        -- 还原 Main 尺寸属性（此时不可见，不会造成视觉跳变），方便下次还原动画计算
        Main.Size = UDim2.new(0, LastNormalSize.X, 0, LastNormalSize.Y)
        Main.Position = LastNormalPosition

        MiniCircle.Position = target
        MiniCircle.Size = UDim2.new(0, 10, 0, 10)
        MiniCircle.BackgroundTransparency = 1
        MiniCircle.Visible = true
        Tween(MiniCircle, {
            Size = UDim2.new(0, 54, 0, 54),
            BackgroundTransparency = 0,
        }, MIN_ANIM_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
        Animating = false
    end)
end

local function RestoreFromCircle()
    if Animating then return end
    Animating = true
    Minimized = false

    LastCirclePosition = MiniCircle.Position -- 记住用户拖动圆点后的位置，方便下次最小化回到这里

    Tween(MiniCircle, {
        Size = UDim2.new(0, 10, 0, 10),
        BackgroundTransparency = 1,
    }, MIN_ANIM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

    task.delay(MIN_ANIM_TIME, function()
        MiniCircle.Visible = false

        Main.Position = LastCirclePosition or MiniCircle.Position
        Main.Size = UDim2.new(0, 40, 0, 40)
        Main.BackgroundTransparency = 1
        Main.Visible = true

        Tween(Main, {
            Size = UDim2.new(0, LastNormalSize.X, 0, LastNormalSize.Y),
            Position = LastNormalPosition or UDim2.new(0.5, -LastNormalSize.X/2, 0.5, -LastNormalSize.Y/2),
            BackgroundTransparency = 0,
        }, MIN_ANIM_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

        task.delay(MIN_ANIM_TIME, function()
            Content.Visible = true
            ResizeHandle.Visible = true
            LayoutUI()
            Animating = false
        end)
    end)
end

MinBtn.MouseButton1Click:Connect(function()
    if Minimized then RestoreFromCircle() else MinimizeToCircle() end
end)

MiniCircle.MouseButton1Click:Connect(function()
    RestoreFromCircle()
end)

CloseBtn.MouseButton1Click:Connect(function() ScreenGui:Destroy() end)

ListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() ResizeCanvas() end)
Main:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    if not Minimized then LayoutUI() end
end)

-- 缩放手柄
local resizing = false
local resizeStartPos, resizeStartSize
ResizeHandle.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        resizing = true
        resizeStartPos = input.Position
        resizeStartSize = Main.AbsoluteSize
        Main.Draggable = false
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not resizing then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local delta = input.Position - resizeStartPos
    local newW = math.clamp(resizeStartSize.X + delta.X, 400, 900)
    local newH = math.clamp(resizeStartSize.Y + delta.Y, 280, 700)
    Main.Size = UDim2.new(0, newW, 0, newH)
    LastNormalSize = Vector2.new(newW, newH)
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        resizing = false
        Main.Draggable = true
    end
end)

-- ==================== 自动刷新 ====================
task.spawn(function()
    while ScreenGui and ScreenGui.Parent do
        if AutoRefreshEnabled then
            pcall(function() ManualRefresh() end)
        else
            UpdateSectionButtons()
            UpdateStatus()
        end
        task.wait(AutoRefreshInterval)
    end
end)

-- ==================== 初始化 ====================
LayoutUI()
UpdateSectionButtons()
CurrentSection = "全部"
ManualRefresh()

print("[UI文本提取器 v24] 已加载 | 响应式布局 + 圆形最小化 + 动画")
