local lp         = game:GetService("Players").LocalPlayer
local RunService = game:GetService("RunService")

-- World 1 di Z=-177.5, spacing 2500 studs/world (linear di sumbu Z, dicek manual).
-- worldsMod.GetCurrentWorld()/GetCurrentRoot() KEBUKTI stale (gak keupdate abis
-- teleport) -- world dihitung dari posisi langsung, bukan dari API itu.
local WORLD1_Z = -177.5
local WORLD_SPACING_Z = 2500

local function getWorldByPos(pos)
    return 1 + math.round((pos.Z - WORLD1_Z) / WORLD_SPACING_Z)
end

local function getMyWorld()
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    return getWorldByPos(root.Position)
end

-- Rarity didapet dari event server "Impact" -- lebih reliable daripada
-- ProximityPrompt (butuh geometry ke-stream dulu). Fallback ke getSwordRarity
-- di bawah kalo event-nya kelewat (script start pas sword udah ada duluan).
local pendingRarity = nil
local pendingSwordName = nil
local swordDropEvent = game:GetService("ReplicatedStorage"):WaitForChild("PunchEscapeRemotes"):WaitForChild("SwordDropEvent")
swordDropEvent.OnClientEvent:Connect(function(kind, _, rarity, swordName)
    if kind == "Impact" then
        pendingRarity = rarity
        pendingSwordName = swordName
    end
end)

-- token/chat punya user sendiri -- jangan di-share/paste script ini ke publik.
local TG_TOKEN = "7476184189:AAGurzPwWAm-UVlARQy2uQE7A4-0mVIpuJw"
local TG_CHAT_ID = -1002405121033
local TG_THREAD_ID = 7414

-- nama fungsi HTTP-nya beda-beda tiap executor, coba yang umum dipake.
local httpRequest = request or http_request or (syn and syn.request)

-- swordName datang dari server, escape biar gak break tag HTML pesannya.
local function escapeHtml(s)
    return (s:gsub("[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

local function notifyTelegram(text)
    if not httpRequest then return end
    task.spawn(function()
        pcall(function()
            httpRequest({
                Url = "https://api.telegram.org/bot" .. TG_TOKEN .. "/sendMessage",
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = game:GetService("HttpService"):JSONEncode({
                    chat_id = TG_CHAT_ID,
                    message_thread_id = TG_THREAD_ID,
                    text = text,
                    parse_mode = "HTML",
                }),
            })
        end)
    end)
end

-- leaderstats-nya StringValue yang udah diformat game-nya sendiri ("1.01M",
-- "9.44Dd"), gak perlu itung ulang dari NumericStats yang masih raw e+39.
local function getLeaderstat(name)
    local ls = lp:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild(name)
    return v and v.Value
end

local RARITY_COLOR = {
    Common    = Color3.fromRGB(180, 180, 180),
    Uncommon  = Color3.fromRGB(90, 255, 130),
    Rare      = Color3.fromRGB(80, 170, 255),
    Epic      = Color3.fromRGB(200, 90, 255),
    Legendary = Color3.fromRGB(255, 170, 0),
    Mythic    = Color3.fromRGB(255, 60, 120),
}

-- fallback: rarity-nya ada di ProximityPrompt.ObjectText, formatnya
-- "<Rarity> Sword". pakai GetDescendants() manual, bukan FindFirstChild(name,
-- true) -- yang kedua itu kebukti gak reliable di environment ini.
local function getSwordRarity(swordModel)
    for _, inst in ipairs(swordModel:GetDescendants()) do
        if inst:IsA("ProximityPrompt") then
            local rarity = inst.ObjectText:match("^(%a+) Sword$")
            return rarity or inst.ObjectText
        end
    end
    return nil
end

-- countdown "Sword Drop in Xm Ys" udah ada TextLabel-nya sendiri dari game
-- (PunchEscapeSwordDropUI.Root.Timer), di-update tiap detik sama game --
-- tinggal dibaca, gak perlu itung timer sendiri.
local function getDropTimerText()
    local ui = lp.PlayerGui:FindFirstChild("PunchEscapeSwordDropUI")
    local root = ui and ui:FindFirstChild("Root")
    local timer = root and root:FindFirstChild("Timer")
    return timer and timer.Text
end

-- tombol WORLDS asli game -- klik programatik ke TeleportButton kebukti
-- gak jalan (UI framework custom), jadi cuma bukain menu-nya, TELEPORT
-- tetep diklik manual (100% jalan karena klik asli).
local function findWorldsWindow()
    local ui = lp.PlayerGui:FindFirstChild("PunchEscapeUI")
    local root = ui and ui:FindFirstChild("Root")
    local modalShade = root and root:FindFirstChild("ModalShade")
    local win = modalShade and modalShade:FindFirstChild("WORLDSWindow")
    return win, modalShade
end

local worldsScaleConn = nil

local function setWorldsMenuOpen(open)
    local win, modalShade = findWorldsWindow()
    if not win then return false, "WORLDSWindow gak ketemu" end
    modalShade.Visible = open
    win.Visible = open

    if worldsScaleConn then
        worldsScaleConn:Disconnect()
        worldsScaleConn = nil
    end

    -- framework-nya spring/tween UIScale balik ke target closed-nya (0.04)
    -- tiap frame karena state internal-nya gak pernah kita set ke "open" --
    -- paksa sekali doang kalah, jadi di-re-force tiap frame selama kebuka.
    local scale = open and win:FindFirstChildOfClass("UIScale")
    if scale then
        scale.Scale = 1
        worldsScaleConn = RunService.RenderStepped:Connect(function()
            if scale.Scale ~= 1 then scale.Scale = 1 end
        end)
    end
    return true
end

-- Satu radius dipake konsisten di semua elemen utama (card, pill, tombol) --
-- R-11: variasi radius cuma buat bar aksen tipis yang emang beda bentuk.
local CORNER = UDim.new(0, 12)

-- Warna aksen per baris = identitas tetap ("ini row target" vs "ini row kamu"),
-- bukan dekorasi acak -- konsisten dipake tiap kali GUI ini muncul.
local ACCENT_SWORD = Color3.fromRGB(150, 100, 255)
local ACCENT_ME     = Color3.fromRGB(70, 210, 165)
local ACCENT_NEUTRAL = Color3.fromRGB(90, 86, 115)

local CAPTION_COLOR = Color3.fromRGB(150, 146, 175) -- >4.5:1 di atas bg gelap (R-25)
local VALUE_COLOR    = Color3.fromRGB(235, 232, 250)

local sg, card
local uiRefs = {}
local worldsMenuOpen = false

-- bar warna tipis di kiri tiap row: nandain kategori row itu (sword/rarity/kamu),
-- bukan cuma hiasan -- gantiin badge lingkaran+emoji yang lama.
local function newRow(parent, accentColor, caption, layoutOrder)
    local row = Instance.new("Frame", parent)
    row.Name = caption .. "Row"
    row.Size = UDim2.new(1, 0, 0, 30)
    row.BackgroundTransparency = 1
    row.LayoutOrder = layoutOrder

    local rowLayout = Instance.new("UIListLayout", row)
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    rowLayout.Padding = UDim.new(0, 10)

    local accentBar = Instance.new("Frame", row)
    accentBar.Name = "Accent"
    accentBar.Size = UDim2.new(0, 4, 1, -4)
    accentBar.BackgroundColor3 = accentColor
    accentBar.BorderSizePixel = 0
    Instance.new("UICorner", accentBar).CornerRadius = UDim.new(1, 0)

    local textCol = Instance.new("Frame", row)
    textCol.Size = UDim2.new(1, -14, 1, 0)
    textCol.BackgroundTransparency = 1

    local capLbl = Instance.new("TextLabel", textCol)
    capLbl.Size = UDim2.new(1, 0, 0, 12)
    capLbl.Position = UDim2.new(0, 0, 0, 1)
    capLbl.BackgroundTransparency = 1
    capLbl.Text = caption
    capLbl.TextColor3 = CAPTION_COLOR
    capLbl.TextSize = 10
    capLbl.Font = Enum.Font.GothamBold
    capLbl.TextXAlignment = Enum.TextXAlignment.Left

    local valLbl = Instance.new("TextLabel", textCol)
    valLbl.Name = "Value"
    valLbl.Size = UDim2.new(1, 0, 0, 16)
    valLbl.Position = UDim2.new(0, 0, 0, 13)
    valLbl.BackgroundTransparency = 1
    valLbl.Text = "-"
    valLbl.TextColor3 = VALUE_COLOR
    valLbl.TextSize = 14
    valLbl.Font = Enum.Font.GothamBold
    valLbl.TextXAlignment = Enum.TextXAlignment.Left

    return accentBar, valLbl
end

local function newDivider(parent, layoutOrder)
    local div = Instance.new("Frame", parent)
    div.Name = "Divider"
    div.Size = UDim2.new(1, 0, 0, 1)
    div.BackgroundColor3 = Color3.fromRGB(70, 55, 120)
    div.BackgroundTransparency = 0.3
    div.BorderSizePixel = 0
    div.LayoutOrder = layoutOrder
end

local function makeGUI()
    local old = lp.PlayerGui:FindFirstChild("SwordTracker")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui", lp.PlayerGui)
    gui.Name = "SwordTracker"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 999

    -- satu glow ambient di belakang card, warnanya ngikut status (R-13:
    -- max 1-2 elemen boleh glow, ini yang satu itu). Fungsinya beneran:
    -- kebaca dari sudut mata biar gak perlu ngelirik detail buat tau status.
    local glow = Instance.new("Frame", gui)
    glow.Name = "Glow"
    glow.BackgroundColor3 = ACCENT_NEUTRAL
    glow.BackgroundTransparency = 0.86
    glow.BorderSizePixel = 0
    glow.ZIndex = 0
    Instance.new("UICorner", glow).CornerRadius = UDim.new(0, 26)

    local c = Instance.new("Frame", gui)
    c.Name = "Card"
    c.Size = UDim2.new(0, 232, 0, 0)
    c.AutomaticSize = Enum.AutomaticSize.Y
    c.Position = UDim2.new(1, -244, 0, 12)
    -- bg flat, gak pake gradient dekoratif -- biar warna border/pill (state)
    -- yang jadi satu-satunya sinyal warna yang narik perhatian (R-01, R-31).
    c.BackgroundColor3 = Color3.fromRGB(18, 15, 28)
    c.BorderSizePixel = 0
    c.Active = true -- perlu buat Draggable
    c.Draggable = true -- fungsional: biar gak numpuk sama HUD game
    Instance.new("UICorner", c).CornerRadius = CORNER

    local stroke = Instance.new("UIStroke", c)
    stroke.Name = "Stroke"
    -- warna border = satu-satunya indikator status (idle/nyambung/beda world),
    -- ini "satu aksen niat" yang dipake, bukan dekorasi lepas (Liveliness Toolkit).
    stroke.Color = ACCENT_NEUTRAL
    stroke.Thickness = 1.5

    local pad = Instance.new("UIPadding", c)
    pad.PaddingTop = UDim.new(0, 14)
    pad.PaddingBottom = UDim.new(0, 14)
    pad.PaddingLeft = UDim.new(0, 14)
    pad.PaddingRight = UDim.new(0, 14)

    local mainLayout = Instance.new("UIListLayout", c)
    mainLayout.SortOrder = Enum.SortOrder.LayoutOrder
    mainLayout.Padding = UDim.new(0, 10)

    local titleLbl = Instance.new("TextLabel", c)
    titleLbl.Size = UDim2.new(1, 0, 0, 20)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "Sword Tracker"
    titleLbl.TextColor3 = VALUE_COLOR
    titleLbl.TextSize = 17
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.LayoutOrder = 1

    newDivider(c, 2)

    local _, swVal = newRow(c, ACCENT_SWORD, "SWORD LOCATION", 3)
    -- rarity: warna aksen dinamis ikut tier beneran (RARITY_COLOR), bukan
    -- ngasal -- ini satu-satunya warna yang punya makna fungsional literal.
    local rarityAccent, rarityVal = newRow(c, ACCENT_NEUTRAL, "RARITY", 4)
    local _, myVal = newRow(c, ACCENT_ME, "YOUR LOCATION", 5)

    local pill = Instance.new("Frame", c)
    pill.Name = "Pill"
    pill.Size = UDim2.new(1, 0, 0, 34)
    pill.BackgroundColor3 = Color3.fromRGB(30, 24, 55)
    pill.BorderSizePixel = 0
    pill.LayoutOrder = 6
    Instance.new("UICorner", pill).CornerRadius = CORNER

    -- gradient cuma di sini, satu tempat: pill ini kesimpulan akhir bagian
    -- tracker (jawaban "sword-nya kejar apa gak"), jadi wajar dikasih bobot
    -- visual lebih dari row-row lain (R-01: gradient boleh kalau motong hirarki).
    local pillGrad = Instance.new("UIGradient", pill)
    pillGrad.Rotation = 90

    local pillTxt = Instance.new("TextLabel", pill)
    pillTxt.Name = "PillTxt"
    pillTxt.Size = UDim2.new(1, -16, 1, 0)
    pillTxt.Position = UDim2.new(0, 8, 0, 0)
    pillTxt.BackgroundTransparency = 1
    pillTxt.Text = "Menunggu sword drop..."
    pillTxt.TextColor3 = Color3.fromRGB(170, 160, 210)
    pillTxt.TextSize = 13
    pillTxt.Font = Enum.Font.GothamBold
    pillTxt.TextXAlignment = Enum.TextXAlignment.Center
    pillTxt.TextTruncate = Enum.TextTruncate.AtEnd

    newDivider(c, 7)

    -- tombol Worlds -- bagian aksi terpisah dari bagian info, tapi tetep
    -- satu card, satu bahasa visual (radius/warna sama, bukan panel baru).
    local worldsBtn = Instance.new("TextButton", c)
    worldsBtn.Name = "WorldsBtn"
    worldsBtn.Size = UDim2.new(1, 0, 0, 34)
    -- ACCENT_SWORD polos di sini cuma 3.78:1 sama teks putih (R-25 butuh 4.5:1
    -- buat 13px bold) -- digelapin dikit, pola Lerp yang sama kayak applyPillColor.
    worldsBtn.BackgroundColor3 = ACCENT_SWORD:Lerp(Color3.new(0, 0, 0), 0.35)
    worldsBtn.Text = "Buka Menu Worlds"
    worldsBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    worldsBtn.TextSize = 13
    worldsBtn.Font = Enum.Font.GothamBold
    worldsBtn.AutoButtonColor = true
    worldsBtn.LayoutOrder = 8
    Instance.new("UICorner", worldsBtn).CornerRadius = CORNER

    worldsBtn.MouseButton1Click:Connect(function()
        worldsMenuOpen = not worldsMenuOpen
        local ok, err = setWorldsMenuOpen(worldsMenuOpen)
        if not ok then
            worldsMenuOpen = false
            worldsBtn.Text = "Gagal: " .. tostring(err)
            return
        end
        worldsBtn.Text = worldsMenuOpen and "Tutup Menu Worlds" or "Buka Menu Worlds"
    end)

    uiRefs = {
        swVal = swVal,
        rarityVal = rarityVal,
        rarityAccent = rarityAccent,
        myVal = myVal,
        pill = pill,
        pillGrad = pillGrad,
        pillTxt = pillTxt,
        stroke = stroke,
        glow = glow,
    }

    -- glow ngikutin card: posisi (buat drag) dan ukuran (card auto-resize
    -- ngikut konten). Dipasang di ScreenGui, bukan di dalem card, biar gak
    -- ke-ganggu UIListLayout-nya card.
    local function syncGlow()
        glow.Size = UDim2.new(0, c.AbsoluteSize.X + 24, 0, c.AbsoluteSize.Y + 24)
        glow.Position = UDim2.new(0, c.AbsolutePosition.X - 12, 0, c.AbsolutePosition.Y - 12)
    end
    c:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncGlow)
    c:GetPropertyChangedSignal("AbsolutePosition"):Connect(syncGlow)
    task.defer(syncGlow)

    return gui, c
end

sg, card = makeGUI()

lp.CharacterAdded:Connect(function()
    task.wait(0.5)
    sg, card = makeGUI()
end)

-- satu sistem warna status, dipake di border card + pill -- ini "satu aksen"
-- yang jawab pertanyaan inti widget ini: "aku di tempat yang bener gak?"
local STATE_COLOR = {
    idle  = ACCENT_NEUTRAL,
    match = Color3.fromRGB(70, 220, 140),
    hunt  = Color3.fromRGB(255, 175, 60),
}

-- pill dikasih gradient 2 nada dari warna state-nya sendiri (bukan warna
-- baru) -- nambah kedalaman visual tanpa nambah entri baru ke palette.
local function applyPillColor(pill, pillGrad, baseColor)
    pill.BackgroundColor3 = baseColor
    pillGrad.Color = ColorSequence.new(baseColor, baseColor:Lerp(Color3.new(0, 0, 0), 0.35))
end

local function setUI(swordWorld, myWorld, rarity, dropTimerText)
    if not card or not card.Parent then sg, card = makeGUI() end
    local swVal        = uiRefs.swVal
    local rarityVal     = uiRefs.rarityVal
    local rarityAccent  = uiRefs.rarityAccent
    local myVal         = uiRefs.myVal
    local pill          = uiRefs.pill
    local pillGrad       = uiRefs.pillGrad
    local pillTxt       = uiRefs.pillTxt
    local stroke        = uiRefs.stroke
    local glow           = uiRefs.glow
    if not swVal then return end

    myVal.Text = myWorld and ("World " .. myWorld) or "-"

    if not swordWorld then
        swVal.Text = "-"
        rarityVal.Text = "-"
        rarityAccent.BackgroundColor3 = ACCENT_NEUTRAL
        pillTxt.Text = dropTimerText or "Menunggu sword drop..."
        pillTxt.TextColor3 = Color3.fromRGB(170, 160, 210)
        applyPillColor(pill, pillGrad, Color3.fromRGB(30, 24, 55))
        stroke.Color = STATE_COLOR.idle
        glow.BackgroundColor3 = STATE_COLOR.idle
        return
    end

    swVal.Text = "World " .. swordWorld

    if rarity then
        rarityVal.Text = rarity
        rarityAccent.BackgroundColor3 = RARITY_COLOR[rarity] or ACCENT_NEUTRAL
    else
        rarityVal.Text = "mencari..."
        rarityAccent.BackgroundColor3 = ACCENT_NEUTRAL
    end

    if myWorld and myWorld == swordWorld then
        pillTxt.Text = "Sword ada di world kamu"
        pillTxt.TextColor3 = Color3.fromRGB(140, 255, 190)
        applyPillColor(pill, pillGrad, Color3.fromRGB(10, 55, 35))
        stroke.Color = STATE_COLOR.match
        glow.BackgroundColor3 = STATE_COLOR.match
    else
        pillTxt.Text = "Sword ada di World " .. swordWorld
        pillTxt.TextColor3 = Color3.fromRGB(255, 210, 130)
        applyPillColor(pill, pillGrad, Color3.fromRGB(55, 38, 10))
        stroke.Color = STATE_COLOR.hunt
        glow.BackgroundColor3 = STATE_COLOR.hunt
    end
end

local lastSW, lastMW, lastRarity, lastSwordName = nil, nil, nil, nil
local lastChild = nil
local streamPending = false
local streamAcc = 0
local tickAcc = 0

RunService.Heartbeat:Connect(function(dt)
    tickAcc += dt
    if tickAcc < 0.5 then return end
    tickAcc = 0

    local myWorld = getMyWorld()
    local act     = workspace:FindFirstChild("ActiveSwordDrop")
    local child   = act and (act:FindFirstChild("FallenSword") or act:GetChildren()[1])

    if not child then
        lastChild = nil
        lastSW = nil; lastMW = myWorld; lastRarity = nil
        -- selalu di-refresh (bukan cuma pas state berubah) karena countdown-nya
        -- jalan tiap detik, perlu keliatan ngitung turun bukan macet.
        local ok, timerText = pcall(getDropTimerText)
        setUI(nil, myWorld, nil, ok and timerText)
        return
    end

    local sPos = nil
    pcall(function() sPos = child:GetPivot().Position end)
    local swordWorld = sPos and getWorldByPos(sPos)

    local isNewSword = child ~= lastChild
    if isNewSword then
        lastChild = child
        lastRarity = nil
        lastSwordName = nil
        streamAcc = 0
        pendingRarity = nil
        pendingSwordName = nil
    end

    -- coba ambil rarity tiap tick selama belum ketemu (bukan cuma sekali
    -- pas sword baru muncul), biar begitu kamu nyampe world-nya langsung
    -- ke-update otomatis tanpa perlu rerun script.
    local rarityJustResolved = false
    if not lastRarity and pendingRarity then
        lastRarity = pendingRarity
        lastSwordName = pendingSwordName
        pendingRarity = nil
        pendingSwordName = nil
        rarityJustResolved = true
    end
    if not lastRarity then
        local rarity = nil
        pcall(function() rarity = getSwordRarity(act) end)
        if rarity then
            lastRarity = rarity
            rarityJustResolved = true
        elseif sPos then
            streamAcc += 0.5
            if not streamPending and streamAcc >= 2 then
                streamAcc = 0
                streamPending = true
                local streamPos = sPos
                task.spawn(function()
                    -- ini method Player, bukan Workspace, dan arg ke-2 timeout (detik)
                    -- bukan radius -- salah target sebelumnya, errornya ketelen pcall.
                    pcall(function() lp:RequestStreamAroundAsync(streamPos, 10) end)
                    streamPending = false
                end)
            end
        end
    end

    if rarityJustResolved and swordWorld then
        -- <code> = tap-to-copy di Telegram; value-nya di-escape juga (bukan
        -- cuma nama sword) karena leaderstats tetep data dari luar script.
        local function field(labelText, value)
            return "<b>" .. labelText .. ":</b> <code>" .. escapeHtml(tostring(value)) .. "</code>"
        end

        local DIVIDER = "――――――――――"
        local lines = {
            field("Player", lp.Name),
            DIVIDER,
            field("Rarity", lastRarity),
        }
        if lastSwordName then
            table.insert(lines, field("Name", lastSwordName))
        end
        table.insert(lines, field("World", swordWorld))
        table.insert(lines, DIVIDER)

        local rebirths = getLeaderstat("Rebirths")
        local power = getLeaderstat("Power")
        local wins = getLeaderstat("Wins")
        if rebirths then table.insert(lines, field("Rebirths", rebirths)) end
        if power then table.insert(lines, field("Power", power)) end
        if wins then table.insert(lines, field("Wins", wins)) end

        notifyTelegram(table.concat(lines, "\n"))
    end

    if isNewSword or rarityJustResolved or swordWorld ~= lastSW or myWorld ~= lastMW then
        lastSW = swordWorld; lastMW = myWorld
        setUI(swordWorld, myWorld, lastRarity)
    end
end)
