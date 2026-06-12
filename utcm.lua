local Translations = {
    ["Unstability || Crazy Multiverse Timeline"] = "不稳定 || 疯狂的多元宇宙时间线",
    ["Script made by error_v5"] = "脚本由error_v5制作",
    ["Remove Character Boxes"] = "删除角色盒子",
    ["Fear AutoFarm (normal)"] = "自动收恐惧（慢）",
    ["Gamepass characters"] = "通行证角色",
    ["Reaper Chara Scythe"] = "死神·卡拉·镰刀",
    ["Halloween Realm"] = "万圣节地图",
    ["Infinite Yield"] = "无限收益",
    ["Keep Jumppower"] = "保持当前跳跃高度",
    ["Self Destruct"] = "关闭脚本",
    ["Soul AutoFarm"] = "自动收灵魂",
    ["Core AutoFarm"] = "自动收核心",
    ["Quick Travel"] = "快速传送",
    ["Ten No-Kami"] = "十神",
    ["Azure Sans"] = "余烬sans",
    ["Shadow Orb"] = "影珠",
    ["Keep Speed"] = "保持当前速度",
    ["Teleports"] = "传送",
    ["Waterfall"] = "瀑布",
    ["OuterTale"] = "外传",
    ["Jumppower"] = "跳跃高度",
    ["AutoFarm"] = "自动收益",
    ["God Sans"] = "上帝sans",
    ["GodMode"] = "上帝模式",
    ["Snowdin"] = "雪镇",
    ["Hotland"] = "热域",
    ["Vampire"] = "吸血鬼",
    ["TP Tool"] = "传送工具",
    ["Player"] = "玩家",
    ["Badges"] = "勋章",
    ["635 WS"] = "635速度",
    ["140 WS"] = "140速度",
    ["Lobby"] = "大厅",
    ["Clock"] = "时钟",
    ["Speed"] = "速度",
    ["28 WS"] = "28速度",
    ["25 WS"] = "25速度",
    ["Home"] = "主页",
    ["Main"] = "菜单",
    ["User"] = "用户",
    ["City"] = "城市",
    ["50"] = "50",
}
local TextClasses = {
    TextLabel = true,
    TextButton = true,
    TextBox = true,
}
local function isTextObject(obj)
    return obj and TextClasses[obj.ClassName] == true
end
local function translateText(text)
    if type(text) ~= "string" or text == "" then
        return text
    end
    if Translations[text] then
        return Translations[text]
    end
    for en, cn in pairs(Translations) do
        if string.find(text, en, 1, true) then
            text = string.gsub(text, en:gsub("(%W)", "%%%1"), cn)
        end
    end
    return text
end
local function translateObject(obj)
    if not isTextObject(obj) then
        return
    end
    pcall(function()
        local oldText = obj.Text
        local newText = translateText(oldText)
        if newText ~= oldText then
            obj.Text = newText
        end
    end)
end
local function scanContainer(container)
    if not container then
        return
    end
    pcall(function()
        for _, obj in ipairs(container:GetDescendants()) do
            translateObject(obj)
        end
    end)
end
local function listenContainer(container)
    if not container then
        return
    end
    pcall(function()
        container.DescendantAdded:Connect(function(obj)
            task.defer(function()
                task.wait(0.05)
                translateObject(obj)
            end)
        end)
    end)
end
local function setupFallbackTranslation()
    local CoreGui = game:GetService("CoreGui")
    local Players = game:GetService("Players")
    local LocalPlayer = Players.LocalPlayer
    scanContainer(CoreGui)
    listenContainer(CoreGui)
    if LocalPlayer then
        local PlayerGui = LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5)
        if PlayerGui then
            scanContainer(PlayerGui)
            listenContainer(PlayerGui)
        end
    end
    task.spawn(function()
        while task.wait(3) do
            scanContainer(CoreGui)
            local player = Players.LocalPlayer
            if player and player:FindFirstChild("PlayerGui") then
                scanContainer(player.PlayerGui)
            end
        end
    end)
end
local function setupHookTranslation()
    local mt = getrawmetatable(game)
    local oldNewIndex = mt.__newindex
    setreadonly(mt, false)
    mt.__newindex = newcclosure(function(t, k, v)
        if isTextObject(t) and k == "Text" and type(v) == "string" then
            v = translateText(v)
        end
        return oldNewIndex(t, k, v)
    end)
    setreadonly(mt, true)
end
local function setupTranslationEngine()
    setupFallbackTranslation()
    print("翻译引擎：已禁用Hook，使用纯扫描模式")
end
setupTranslationEngine()

local success, err = pcall(function()
    loadstring(game:HttpGet("https://raw.githubusercontent.com/ILOVETHECOFFINOFANDYANDLEYLEY/crazy-multiverse-timeline/main/no"))()
end)
if not success then
    warn("加载远程脚本失败:", err)
end
