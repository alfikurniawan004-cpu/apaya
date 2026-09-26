local lp         = game:GetService("Players").LocalPlayer
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")

-- World 1 di Z=-177.5, spacing 2500 studs/world (linear di sumbu Z, dicek manual).
-- worldsMod.GetCurrentWorld()/GetCurrentRoot() KEBUKTI stale (gak keupdate abis
-- teleport) -- world dihitung dari posisi langsung, bukan dari API itu.
local WORLD1_Z = -177.5
local WORLD_SPACING_Z = 2500

local function getMyWorld()
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    return 1 + math.round((root.Position.Z - WORLD1_Z) / WORLD_SPACING_Z)
end

-- Semua state drop ada di attribute ReplicatedStorage.SwordDropState, replicate
-- ke tiap client dari detik pertama join, gak peduli sword-nya di world mana
-- (dicek pake diag_nextdrop.lua): Phase "Active"/"Waiting", SwordName, Rarity,
-- World (0 pas Waiting), EndsAt (unix time despawn / drop berikutnya).
-- Gak perlu event Impact, scan ProximityPrompt, atau RequestStreamAroundAsync.
local dropState = RS:WaitForChild("SwordDropState")

local function getDropState()
    local rarity = dropState:GetAttribute("Rarity")
    local world = dropState:GetAttribute("World")
    -- attr-nya di-set satu-satu (Phase dulu, Rarity/World belakangan) -- anggap
    -- belum ada sword sampe semuanya keisi, tick berikutnya (0.5s) nyusul.
    if dropState:GetAttribute("Phase") ~= "Active" or not rarity or rarity == "" or not world or world == 0 then
        return nil
    end
    return {
        rarity = rarity,
        name = dropState:GetAttribute("SwordName"),
        world = world,
        id = dropState:GetAttribute("EndsAt"), -- beda tiap drop = penanda "sword baru"
    }
end

-- Teleport ke world: protokol yang sama persis kayak tombol TELEPORT game
-- (hasil decompile PlayerScripts.PunchEscapeWorldUI, 2026-09-26):
--   client  WorldTeleportRequest:FireServer("Prepare", n)
--   server  Effects "WorldTeleportPrepared" (n, posSpawn)
--   client  RequestStreamAroundAsync(posSpawn) lalu FireServer("Commit", n)
--   server  pindahin, bales Effects "WorldTeleported" (n, pos)
-- Buat server ini identik sama klik asli; server yang ngecek world-nya udah
-- kebuka. Script UI game ngabaikan balasan yang bukan dia yang mulai.
local remotes = RS:WaitForChild("PunchEscapeRemotes")
local worldTeleport = remotes:WaitForChild("WorldTeleportRequest")
local effects = remotes:WaitForChild("Effects")
local teleportPending = nil

local function teleportToWorld(n)
    if teleportPending then return end
    teleportPending = n
    worldTeleport:FireServer("Prepare", n)
    -- kalau server gak pernah bales (world kekunci, throttle), jangan nyangkut
    task.delay(25, function()
        if teleportPending == n then teleportPending = nil end
    end)
end

effects.OnClientEvent:Connect(function(kind, n, pos)
    if n ~= teleportPending then return end -- Effects rame (AFK rock dll), saring dulu
    if kind == "WorldTeleportPrepared" then
        task.spawn(function()
            if typeof(pos) == "Vector3" then
                pcall(function() lp:RequestStreamAroundAsync(pos, 20) end)
            end
            if teleportPending == n then worldTeleport:FireServer("Commit", n) end
        end)
    elseif kind == "WorldTeleported" then
        teleportPending = nil
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

-- Dua set tier, dipilih per chip di card: yang dikirim ke Telegram, dan yang
-- diambil otomatis. Disimpen ke file (nama dipisah koma) karena script
-- full-reset tiap join (autoexec). Set kosong = fitur mati. Tier yang gak
-- dikenal (tier baru di atas ???) ikut nyala selama set-nya gak kosong.
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "???" }
local NOTIFY_FILE = "swordtracker_notify.txt"
local GRAB_FILE = "swordtracker_grab.txt"

local function loadSet(file, default)
    local ok, saved = pcall(readfile, file)
    if not (ok and type(saved) == "string") then return default end
    local set = {}
    for name in saved:gmatch("[^,]+") do set[name] = true end
    return set
end

local function saveSet(file, set)
    if not writefile then return end
    local list = {}
    for _, r in ipairs(RARITIES) do
        if set[r] then table.insert(list, r) end
    end
    pcall(writefile, file, table.concat(list, ","))
end

local function wants(set, rarity)
    if next(set) == nil then return false end
    if not table.find(RARITIES, rarity) then return true end
    return set[rarity] == true
end

local notifyOn = loadSet(NOTIFY_FILE, { Rare = true, Epic = true, Legendary = true, Mythic = true, ["???"] = true })
local grabOn = loadSet(GRAB_FILE, {}) -- default mati: ini aksi, bukan cuma notif

-- Ambil otomatis: gak ngegerakin karakter sendiri, numpang fitur "Menang
-- Otomatis" punya game (AutoWinRequest:FireServer(true/false), keadaannya
-- di attribute LocalPlayer.AutoWin). Fitur itu ngelariin karakter sepanjang
-- track ke arah -X (100 stud/s, Z tetap) sambil ngancurin tembok, dan balik
-- ke start pas nyampe ujung. Sword selalu jatuh di garis track itu (dicek
-- diag_autowin.lua + 4 drop kerekam). Jadi: nunggu X karakter lewat X sword
-- -> matiin auto-win (berhenti ~5 stud) -> tahan ProximityPrompt (API resmi,
-- sama kayak nahan E, server tetep ngecek jarak) -> balikin auto-win.
local autoWin = remotes:WaitForChild("AutoWinRequest")
local swordEvent = remotes:WaitForChild("SwordDropEvent")
local swordPos = nil -- dari Impact (nyampe ke semua client); nil kalau script start pas sword udah di tanah
local grabState = nil -- teks langkah yang lagi jalan, nil = idle
local grabNote, grabNoteUntil = nil, 0 -- hasil terakhir, ditampilin sebentar

swordEvent.OnClientEvent:Connect(function(kind, a, b)
    if kind == "Impact" and typeof(a) == "Vector3" then
        swordPos = a
    elseif kind == "Collected" and grabState then
        -- (kind, rarity, swordName, ...) cuma dikirim ke yang ngambil
        notifyTelegram("<b>Dapet: " .. escapeHtml(tostring(a) .. ": " .. tostring(b)) .. "</b>\nWorld "
            .. tostring(lp:GetAttribute("CurrentWorld")) .. ", ambil otomatis.")
    end
end)

local function setAutoWin(on)
    if (lp:GetAttribute("AutoWin") == true) ~= on then autoWin:FireServer(on) end
end

local function findPrompt()
    local act = workspace:FindFirstChild("ActiveSwordDrop")
    if not act then return nil end
    for _, d in ipairs(act:GetDescendants()) do
        if d:IsA("ProximityPrompt") then return d end
    end
end

-- Rentang X jalur auto-win di satu world, dibaca dari model world-nya
-- (Workspace.Worlds["World N"]["Destructable walls"]: Stage<k> + WinPart di
-- ujung tiap stage, dicek diag_world.lua). X terkecil = pad win stage
-- terakhir (~-890) = ujung lari; X terbesar = tembok pertama (~+2) = start.
-- nil kalau foldernya belum ke-stream.
local function trackRange(world)
    local f = workspace:FindFirstChild("Worlds")
    f = f and f:FindFirstChild("World " .. world)
    f = f and f:FindFirstChild("Destructable walls")
    if not f then return nil end
    local minX, maxX = nil, nil
    for _, d in ipairs(f:GetDescendants()) do
        if d:IsA("BasePart") then
            local x = d.Position.X
            if not minX or x < minX then minX = x end
            if not maxX or x > maxX then maxX = x end
        end
    end
    return minX, maxX
end

local function grabSword(target, world)
    if grabState then return end
    grabState = "Mulai..."
    task.spawn(function()
        local wasOn = lp:GetAttribute("AutoWin") == true
        local deadline = os.clock() + 90
        local function active() return dropState:GetAttribute("Phase") == "Active" end
        -- abis kelar: auto-win balik nyala kalau tadinya nyala ATAU mode ambil
        -- otomatis lagi aktif (farming lanjut sampe drop berikutnya)
        local function finish(msg)
            setAutoWin(wasOn or next(grabOn) ~= nil)
            grabState = nil
            grabNote, grabNoteUntil = msg, os.clock() + 4
        end

        if world > (lp:GetAttribute("MaxWorldUnlocked") or 1) then
            return finish("World " .. world .. " belum kebuka")
        end

        if lp:GetAttribute("CurrentWorld") ~= world then
            -- urutan sama kayak manual: lari diberhentiin dulu, baru pindah world
            grabState = "Stop auto-win..."
            setAutoWin(false)
            local t = os.clock() + 2
            repeat task.wait(0.1) until lp:GetAttribute("AutoWin") ~= true or os.clock() > t

            grabState = "Teleport ke World " .. world .. "..."
            teleportToWorld(world)
            repeat task.wait(0.2) until lp:GetAttribute("CurrentWorld") == world or os.clock() > deadline or not active()
            if lp:GetAttribute("CurrentWorld") ~= world then return finish(active() and "Teleport gagal" or "Sword keburu diambil") end
            task.wait(1)
        end

        -- cek dulu sword-nya di jalur auto-win apa nggak, biar gak lari sia-sia:
        -- lewat ujung = tolak; di belakang start (deket spawn, gak ada tembok)
        -- = jalan biasa tanpa auto-win. Folder belum ke-stream = lewatin cek,
        -- penghitung putaran di bawah yang jaga.
        local endX, startX = trackRange(world)
        if endX and target.X < endX - 8 then return finish("Sword di luar track (lewat ujung)") end
        local walkOnly = startX ~= nil and target.X > startX + 8

        local root
        if walkOnly then
            -- auto-win harus mati dulu, kalau nggak MoveTo rebutan sama lari-nya
            grabState = "Jalan ke sword..."
            setAutoWin(false)
            local t = os.clock() + 2
            repeat task.wait(0.1) until lp:GetAttribute("AutoWin") ~= true or os.clock() > t
        else
            grabState = "Lari ke sword..."
            setAutoWin(true)
            -- sword di 40 stud terakhir sebelum ujung: berhenti lebih awal (25 stud
            -- sebelum sword) biar karakter gak nyentuh garis pad win (= reset ke
            -- start). Sisanya jalan biasa: tembok di situ udah pecah, dan pad
            -- win cuma di pinggir track sedangkan sword jatuh di tengah.
            local lead = (endX and target.X < endX + 40) and 25 or 8
            local lastX, laps = nil, 0
            repeat
                task.wait() -- tiap frame: 100 stud/s = ~1.7 stud/frame, jendela pasti kena
                local c = lp.Character
                root = c and c:FindFirstChild("HumanoidRootPart")
                if not active() then return finish("Sword keburu diambil") end
                if os.clock() > deadline then return finish("Kelamaan, batal") end
                if root then
                    -- lompat balik ke start = satu putaran. Satu putaran wajar (mulai
                    -- dari posisi yang udah lewat sword-nya); dua putaran tanpa pernah
                    -- kena jendela = sword di luar jalur auto-win, jangan muter terus.
                    if lastX and root.Position.X - lastX > 300 then laps = laps + 1 end
                    lastX = root.Position.X
                    if laps >= 2 then return finish("Sword di luar jalur auto-win") end
                end
                -- jendela [sword-8, sword+lead]: dateng dari arah +X, jadi berhenti
                -- begitu masuk jarak lead; udah lewat jauh = tunggu putaran berikutnya
            until root and root.Position.X - target.X <= lead and root.Position.X - target.X >= -8
            setAutoWin(false)
        end

        grabState = "Ngambil..."
        task.wait(0.3) -- biar karakter beneran berhenti dulu
        local c = lp.Character
        root = c and c:FindFirstChild("HumanoidRootPart")
        if not root then return finish("Karakter gak ada") end
        -- berhentinya bisa agak jauh (overshoot ~5 stud + beda Z 1-4 stud): sisanya
        -- jalan biasa, tembok di situ udah pecah. Kalau jauh banget berarti auto-win
        -- keburu reset ke start, jangan nabrak tembok pake MoveTo. Kasus di
        -- belakang start boleh lebih jauh, dari spawn ke situ gak ada tembok.
        local gapLeft = (root.Position - target).Magnitude
        if gapLeft > (walkOnly and 150 or 40) then return finish("Auto-win keburu reset, sword kelewat") end
        local hum = c:FindFirstChildOfClass("Humanoid")
        if hum and gapLeft > 6 then
            hum:MoveTo(target)
            hum.MoveToFinished:Wait()
        end

        local prompt
        for _ = 1, 15 do
            prompt = findPrompt()
            if prompt then break end
            task.wait(0.2)
        end
        if not prompt then return finish("Prompt sword gak ketemu") end
        prompt:InputHoldBegin()
        task.wait(prompt.HoldDuration + 0.25)
        prompt:InputHoldEnd()
        local t = os.clock() + 4
        repeat task.wait(0.2) until not active() or os.clock() > t
        finish(active() and "Gak keambil, coba lagi" or "Dapet!")
    end)
end

-- leaderstats-nya StringValue yang udah diformat game-nya sendiri ("1.01M",
-- "9.44Dd"), gak perlu itung ulang dari NumericStats yang masih raw e+39.
local function getLeaderstat(name)
    local ls = lp:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild(name)
    return v and v.Value
end

-- countdown "Sword Drop in Xm Ys" / "Sword despawns in Xm Ys" udah ada
-- TextLabel-nya sendiri dari game (PunchEscapeSwordDropUI.Root.Timer),
-- di-update tiap detik sama game -- tinggal dibaca, gak perlu itung sendiri.
local function getDropTimerText()
    local ui = lp.PlayerGui:FindFirstChild("PunchEscapeSwordDropUI")
    local root = ui and ui:FindFirstChild("Root")
    local timer = root and root:FindFirstChild("Timer")
    local text = timer and timer.Text
    if text == "" then return nil end
    return text
end

-- ===== Card =====
-- Arah (dipilih user): overlay instrumen, kayak timer speedrun.
-- Dial ENERGY 1 / RHYTHM 1 / MOTION 1 (motion cuma hover tombol).
-- * Dark opaque: numpang di atas gameplay yang warna-warni, kontras teks
--   harus gak tergantung apa yang ada di belakang card.
-- * Satu-satunya warna = warna rarity. Makin tinggi tier makin nyala baris
--   itu, jadi "seberapa peduli lu" kebaca dari sudut mata. Status world
--   dibawa teks, bukan warna, biar tetep kebaca buat buta warna.
-- * Tanpa glow/gradient/stripe/divider/judul: jarak antar baris yang jadi
--   struktur, dan judul gak ngasih info apa-apa.
-- * Tiap baris kalimat ("Kamu di World 3"), bukan label:nilai -- ini suara
--   card-nya. Gotham = font UI Roblox sendiri, biar card kebaca sebagai
--   bagian client, bukan benda asing.
-- * Semua pasangan warna dicek pake contrast-check.py di atas #121212:
--   teks 15.9:1, teks redup 7.2:1, stroke 5.4:1, rarity 5.5:1 (Mythic)
--   sampe 18.7:1 (???). Semuanya >= 4.5:1.
local BG       = Color3.fromRGB(18, 18, 18)    -- #121212
local BG_HOVER = Color3.fromRGB(38, 38, 38)    -- #262626
local EDGE     = Color3.fromRGB(138, 138, 138) -- #8A8A8A, batas non-teks >= 3:1
local TEXT     = Color3.fromRGB(236, 236, 236) -- #ECECEC
local TEXT_DIM = Color3.fromRGB(160, 160, 160) -- #A0A0A0
local RADIUS   = UDim.new(0, 8)                -- satu radius buat card + tombol

local RARITY_COLOR = {
    Common    = Color3.fromRGB(180, 180, 180),
    Uncommon  = Color3.fromRGB(90, 255, 130),
    Rare      = Color3.fromRGB(80, 170, 255),
    Epic      = Color3.fromRGB(200, 90, 255),
    Legendary = Color3.fromRGB(255, 170, 0),
    Mythic    = Color3.fromRGB(255, 60, 120),
    ["???"]   = Color3.fromRGB(255, 255, 255),
}

local sg, card
local uiRefs = {}

local function newLine(parent, order, size, font, color)
    local l = Instance.new("TextLabel", parent)
    l.Size = UDim2.new(1, 0, 0, size + 4)
    l.BackgroundTransparency = 1
    l.Text = ""
    l.TextColor3 = color
    l.TextSize = size
    l.Font = font
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextTruncate = Enum.TextTruncate.AtEnd
    l.LayoutOrder = order
    return l
end

local function makeGUI()
    local old = lp.PlayerGui:FindFirstChild("SwordTracker")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui", lp.PlayerGui)
    gui.Name = "SwordTracker"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 999

    local c = Instance.new("Frame", gui)
    c.Name = "Card"
    c.Size = UDim2.new(0, 260, 0, 0) -- 232px dalam: cukup buat baris chip 4 tier
    c.AutomaticSize = Enum.AutomaticSize.Y
    c.Position = UDim2.new(1, -272, 0, 12)
    c.BackgroundColor3 = BG
    c.BorderSizePixel = 0
    c.Active = true
    c.Draggable = true -- biar bisa digeser kalo nutupin HUD game
    Instance.new("UICorner", c).CornerRadius = RADIUS

    local edge = Instance.new("UIStroke", c)
    edge.Color = EDGE
    edge.Thickness = 1

    local pad = Instance.new("UIPadding", c)
    pad.PaddingTop = UDim.new(0, 12)
    pad.PaddingBottom = UDim.new(0, 12)
    pad.PaddingLeft = UDim.new(0, 14)
    pad.PaddingRight = UDim.new(0, 14)

    local layout = Instance.new("UIListLayout", c)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)

    -- satu fokus per layar: baris status. Sisanya lebih kecil dan redup.
    local status = newLine(c, 1, 16, Enum.Font.GothamBold, TEXT)
    local rarity = newLine(c, 2, 14, Enum.Font.GothamBold, TEXT)
    local me     = newLine(c, 3, 13, Enum.Font.GothamMedium, TEXT_DIM)
    local timer  = newLine(c, 4, 13, Enum.Font.GothamMedium, TEXT_DIM)

    -- jarak ekstra sebelum tombol = ganti bagian (info -> aksi), tanpa divider
    local gap = Instance.new("Frame", c)
    gap.Size = UDim2.new(1, 0, 0, 6)
    gap.BackgroundTransparency = 1
    gap.LayoutOrder = 5

    -- tombol outline (bukan blok warna): aksi sekunder, card ini utamanya
    -- buat dibaca. Batas tombolnya dari stroke, hover cuma nge-tint bg.
    local function newButton(order, text)
        local b = Instance.new("TextButton", c)
        b.Size = UDim2.new(1, 0, 0, 36)
        b.BackgroundColor3 = BG
        b.BorderSizePixel = 0
        b.AutoButtonColor = false
        b.Text = text
        b.TextColor3 = TEXT
        b.TextSize = 13
        b.Font = Enum.Font.GothamMedium
        b.LayoutOrder = order
        Instance.new("UICorner", b).CornerRadius = RADIUS
        local e = Instance.new("UIStroke", b)
        e.Color = EDGE
        e.Thickness = 1
        -- Inert = lagi nampilin alasan ("belum kebuka"), bukan tombol hidup:
        -- gak usah hover biar gak keliatan bisa diklik
        b.MouseEnter:Connect(function()
            if not b:GetAttribute("Inert") then b.BackgroundColor3 = BG_HOVER end
        end)
        b.MouseLeave:Connect(function() b.BackgroundColor3 = BG end)
        return b
    end

    -- cuma muncul kalau sword-nya di world lain (gak ada tujuan = gak ada
    -- tombol). Teks-nya nyebut tujuannya, bukan "Teleport" doang.
    local goBtn = newButton(6, "")
    goBtn.Name = "GoBtn"
    goBtn.Visible = false
    goBtn.MouseButton1Click:Connect(function()
        local target = uiRefs.goTarget
        if not target or goBtn:GetAttribute("Inert") then return end
        -- posisi ketauan = ambil otomatis; gak ketauan = minimal anter ke world-nya
        if swordPos then grabSword(swordPos, target) else teleportToWorld(target) end
    end)

    -- grup chip per tier, dua baris (4 + 3) biar muat di 232px dalam card.
    -- Nyala = diisi warna tier-nya + teks gelap, mati = outline redup.
    -- Bedanya bentuk (isi vs garis), bukan cuma warna, biar tetep kebaca
    -- buat buta warna. Warna tier di sini bawa info (tier mana), bukan hiasan.
    -- Dipake dua kali: Notif Telegram dan Ambil otomatis, bahasa visual sama.
    local function chipGroup(order, caption, set, file)
        local cap = newLine(c, order, 13, Enum.Font.GothamMedium, TEXT_DIM)
        cap.Text = caption
        local rows = { { "Common", "Uncommon", "Rare", "Epic" }, { "Legendary", "Mythic", "???" } }
        for i, names in ipairs(rows) do
            local row = Instance.new("Frame", c)
            row.Size = UDim2.new(1, 0, 0, 24)
            row.BackgroundTransparency = 1
            row.LayoutOrder = order + i
            local rowLayout = Instance.new("UIListLayout", row)
            rowLayout.FillDirection = Enum.FillDirection.Horizontal
            rowLayout.Padding = UDim.new(0, 4)

            for _, rarity in ipairs(names) do
                local chip = Instance.new("TextButton", row)
                chip.Name = "Chip_" .. rarity
                chip.AutomaticSize = Enum.AutomaticSize.X
                chip.Size = UDim2.new(0, 0, 1, 0)
                chip.BorderSizePixel = 0
                chip.AutoButtonColor = false
                chip.Text = rarity
                chip.TextSize = 11
                chip.Font = Enum.Font.GothamBold
                Instance.new("UICorner", chip).CornerRadius = RADIUS
                local chipPad = Instance.new("UIPadding", chip)
                chipPad.PaddingLeft = UDim.new(0, 8)
                chipPad.PaddingRight = UDim.new(0, 8)
                local chipEdge = Instance.new("UIStroke", chip)
                chipEdge.Thickness = 1

                local function paint()
                    local on = set[rarity] == true
                    chip.BackgroundTransparency = on and 0 or 1
                    chip.BackgroundColor3 = RARITY_COLOR[rarity]
                    chip.TextColor3 = on and BG or TEXT_DIM
                    chipEdge.Color = on and RARITY_COLOR[rarity] or EDGE
                end
                paint()
                chip.MouseButton1Click:Connect(function()
                    set[rarity] = (not set[rarity]) or nil
                    saveSet(file, set)
                    paint()
                end)
            end
        end
    end
    chipGroup(7, "Notif Telegram:", notifyOn, NOTIFY_FILE)
    chipGroup(10, "Ambil otomatis:", grabOn, GRAB_FILE)

    uiRefs = { status = status, rarity = rarity, me = me, timer = timer, go = goBtn }
    return gui, c
end

sg, card = makeGUI()

lp.CharacterAdded:Connect(function()
    task.wait(0.5)
    sg, card = makeGUI()
end)

-- sword = tabel dari getDropState(), nil = lagi Waiting.
-- Tiga keadaan: nunggu (countdown), ada sword, karakter belum spawn.
local function setUI(sword, myWorld, timerText)
    if not card or not card.Parent then sg, card = makeGUI() end
    local r = uiRefs
    if not r.status then return end

    r.me.Text = myWorld and ("Kamu di World " .. myWorld) or "Karakter belum spawn"

    -- tombol aksi: ada yang bisa dilakuin = ada tombol. Posisi sword ketauan
    -- -> "Ambil" (world mana pun); gak ketauan -> cuma "Teleport" ke world
    -- lain. Kekunci = inert, cuma ngasih tau kenapa. Lagi jalan = teks langkah.
    local target = sword and (sword.world ~= myWorld or swordPos) and sword.world or nil
    r.goTarget = target
    r.go.Visible = target ~= nil
    if target then
        local locked = target > (lp:GetAttribute("MaxWorldUnlocked") or 1)
        r.go:SetAttribute("Inert", locked or grabState ~= nil)
        r.go.TextColor3 = locked and TEXT_DIM or TEXT
        if locked then
            r.go.Text = "World " .. target .. " belum kebuka"
        elseif grabState then
            r.go.Text = grabState
        elseif swordPos then
            r.go.Text = target == myWorld and "Ambil sword" or ("Ambil sword di World " .. target)
        elseif teleportPending == target then
            r.go.Text = "Teleport ke World " .. target .. "..."
        else
            r.go.Text = "Teleport ke World " .. target
        end
    end

    -- hasil ambil terakhir numpang di baris status 4 detik (tombolnya
    -- keburu ilang begitu sword keambil)
    local note = grabNote and os.clock() < grabNoteUntil and grabNote or nil

    if not sword then
        r.status.Text = note or timerText or "Menunggu sword drop"
        r.rarity.Visible = false
        r.timer.Visible = false
        return
    end

    if note then
        r.status.Text = note
    elseif myWorld == sword.world then
        r.status.Text = "Sword ada di world kamu"
    else
        r.status.Text = "Sword ada di World " .. sword.world
    end
    local name = sword.name
    r.rarity.Text = sword.rarity .. ((name and name ~= "") and (": " .. name) or "")
    r.rarity.TextColor3 = RARITY_COLOR[sword.rarity] or TEXT
    r.rarity.Visible = true
    r.timer.Text = timerText or ""
    r.timer.Visible = timerText ~= nil
end

-- Format dipilih user: baris pertama (yang muncul di preview notif) jawab
-- "worth balik gak", sisanya kalimat pendek. Semua teks dari game di-escape.
local function notifySword(sword)
    local head = sword.rarity
    if sword.name and sword.name ~= "" then head = head .. ": " .. sword.name end
    local lines = { "<b>" .. escapeHtml(head) .. "</b>" }

    local myWorld = getMyWorld()
    if myWorld == sword.world then
        table.insert(lines, "Jatuh di World " .. sword.world .. ", kamu udah di sana.")
    elseif myWorld then
        table.insert(lines, "Jatuh di World " .. sword.world .. ", kamu di World " .. myWorld .. ".")
    else
        table.insert(lines, "Jatuh di World " .. sword.world .. ".")
    end

    -- sword.id = EndsAt (unix time despawn dari server), os.date tanpa "!" = jam lokal
    if type(sword.id) == "number" then
        local left = math.max(0, math.floor(sword.id - os.time()))
        table.insert(lines, string.format("Ilang jam %s (%dm %ds lagi).", os.date("%H:%M:%S", sword.id), left // 60, left % 60))
    end

    local stats = {}
    for _, name in ipairs({ "Rebirths", "Power", "Wins" }) do
        local v = getLeaderstat(name)
        if v then table.insert(stats, name .. " " .. escapeHtml(tostring(v))) end
    end
    if #stats > 0 then
        table.insert(lines, "――――――――――")
        for _, s in ipairs(stats) do table.insert(lines, s) end
    end

    notifyTelegram(table.concat(lines, "\n"))
end

local lastId, grabTriedId = nil, nil
local lastAutoWinReq = 0
local tickAcc = 0

-- UI di-refresh tiap tick (bukan cuma pas berubah) karena countdown-nya
-- jalan tiap detik di dua keadaan (drop in / despawns in).
RunService.Heartbeat:Connect(function(dt)
    tickAcc += dt
    if tickAcc < 0.5 then return end
    tickAcc = 0

    local sword = getDropState()
    if sword then
        if sword.id ~= lastId then
            lastId = sword.id
            if wants(notifyOn, sword.rarity) then notifySword(sword) end
        end
        -- ambil otomatis: sekali per drop, dan baru pas posisinya udah ada
        -- (Impact bisa telat/duluan sedetik dari attr)
        if swordPos and grabTriedId ~= sword.id and wants(grabOn, sword.rarity) then
            grabTriedId = sword.id
            grabSword(swordPos, sword.world)
        end
    else
        -- posisi cuma dibuang pas transisi Active -> Waiting. Impact drop
        -- berikutnya bisa dateng ~1 detik SEBELUM attr-nya keisi, jangan
        -- sampe kehapus di tick yang masih Waiting itu.
        if lastId then swordPos = nil end
        lastId = nil
    end

    -- mode ambil otomatis = auto-win jalan terus di antara ambilan (pas lagi
    -- ambil, grabSword yang pegang). Kirim ulang paling cepet 3s sekali biar
    -- gak nge-spam kalau server lagi nolak. Matiin = kosongin chip-nya.
    if next(grabOn) ~= nil and not grabState and lp:GetAttribute("AutoWin") ~= true
        and os.clock() - lastAutoWinReq > 3 then
        lastAutoWinReq = os.clock()
        autoWin:FireServer(true)
    end

    local ok, timerText = pcall(getDropTimerText)
    setUI(sword, getMyWorld(), ok and timerText or nil)
end)
