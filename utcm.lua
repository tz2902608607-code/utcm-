-- Roblox 汉化脚本
-- 由 Roblox 汉化脚本在线生成器生成
-- 默认使用普通扫描模式。Hook 模式可能被反作弊拦截，请谨慎开启。

local Translations = {
    ["Unstability || Crazy Multiverse Timeline"] = "不稳定||疯狂的多元宇宙时间线",
    ["Script made by error_v5"] = "脚本由error_v5编写",
    ["Remove Character Boxes"] = "免费全角色",
    ["Fear AutoFarm (normal)"] = "自动收集恐惧（慢）",
    ["Reaper Chara Scythe"] = "收割者Chara Scythe",
    ["Gamepass characters"] = "通行证角色",
    ["Halloween Realm"] = "万圣节地图",
    ["Infinite Yield"] = "管理员命令脚本",
    ["Keep Jumppower"] = "保持当前跳跃高度",
    ["Self Destruct"] = "关闭脚本",
    ["Soul AutoFarm"] = "自动收集灵魂",
    ["Core AutoFarm"] = "自动收集核心",
    ["Quick Travel"] = "一键传送",
    ["Ten No-Kami"] = "十神",
    ["Shadow Orb"] = "暗影法球",
    ["Azure Sans"] = "蔚蓝Sans",
    ["Keep Speed"] = "保持当前速度",
    ["Teleports"] = "传送",
    ["Waterfall"] = "瀑布",
    ["OuterTale"] = "外星传说",
    ["Jumppower"] = "跳跃高度",
    ["AutoFarm"] = "自动收集货币",
    ["God Sans"] = "上帝Sans",
    ["Snowdin"] = "雪镇",
    ["Hotland"] = "热域",
    ["Vampire"] = "吸血鬼",
    ["GodMode"] = "上帝模式",
    ["TP Tool"] = "传送工具",
    ["Player"] = "玩家",
    ["Badges"] = "徽章",
    ["Lobby"] = "大厅",
    ["Clock"] = "时钟",
    ["Speed"] = "速度",
    ["Home"] = "主页",
    ["Main"] = "菜单",
    ["User"] = "用户",
    ["City"] = "城市",
}

local TextClasses = {
    TextLabel = true,
    TextButton = true,
    TextBox = true,
}

local function isTextObject(obj)
    return obj and TextClasses[obj.ClassName] == true
end

local function escapePattern(text)
    return text:gsub("(%W)", "%%%1")
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
            text = string.gsub(text, escapePattern(en), cn)
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
    local success, err = pcall(function()
        setupHookTranslation()
    end)

    if success then
        print("翻译引擎：Hook 模式已启用")
    else
        warn("Hook 模式失败，已切换普通扫描模式：", err)
        setupFallbackTranslation()
    end
end

setupTranslationEngine()

local success, err = pcall(function()
    loadstring(game:HttpGet("https://raw.githubusercontent.com/ILOVETHECOFFINOFANDYANDLEYLEY/crazy-multiverse-timeline/main/no"))()
end)

if not success then
    warn("远程脚本加载失败：", err)
end