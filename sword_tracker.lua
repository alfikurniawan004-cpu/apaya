local lp         = game:GetService("Players").LocalPlayer
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")

-- Jalan dua kali di sesi yang sama (autoexec + Execute manual) = dua instance
-- saling ngancurin GUI tiap tick dan dobel kirim Telegram/ambil. Token run:
-- instance lama berhenti sendiri begitu yang baru nyala.
-- Token-nya baru diklaim pas Heartbeat instance ini udah nyambung (bawah
-- file): kalau diklaim duluan terus loading-nya gagal, instance lama keburu
-- berhenti dan card beku (kejadian 2026-09-27). Sebelum diklaim, handler
-- instance baru ngalah ke yang lama.
local RUN = {}
local genv = (getgenv and getgenv()) or _G
local function stale() return genv.SwordTrackerRun ~= RUN end

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
    if stale() or n ~= teleportPending then return end -- Effects rame (AFK rock dll), saring dulu
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
local TG_THREAD_ID = 7414        -- topic utama: notif drop
local TG_THREAD_DAPET = 201986   -- topic "INI DAPET": hasil ambil yang berhasil
local TG_THREAD_GAGAL = 201990   -- topic "INI gak dapet": hasil ambil yang gagal

-- nama fungsi HTTP-nya beda-beda tiap executor, coba yang umum dipake.
local httpRequest = request or http_request or (syn and syn.request)

-- swordName datang dari server, escape biar gak break tag HTML pesannya.
local function escapeHtml(s)
    return (s:gsub("[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

-- threadId opsional: default topic utama (drop), hasil ambil ke topic sendiri
local function notifyTelegram(text, threadId)
    if not httpRequest then return end
    task.spawn(function()
        pcall(function()
            httpRequest({
                Url = "https://api.telegram.org/bot" .. TG_TOKEN .. "/sendMessage",
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = game:GetService("HttpService"):JSONEncode({
                    chat_id = TG_CHAT_ID,
                    message_thread_id = threadId or TG_THREAD_ID,
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
    local list, seen = {}, {}
    for _, r in ipairs(RARITIES) do
        if set[r] then table.insert(list, r); seen[r] = true end
    end
    -- tier di luar daftar sword (mis. charm "Rainbow") ikut disimpen, urut abjad
    local extra = {}
    for k in pairs(set) do
        if not seen[k] then table.insert(extra, k) end
    end
    table.sort(extra)
    for _, k in ipairs(extra) do table.insert(list, k) end
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
local claimedBy = nil -- dari Claimed (kind, playerName, rarity, swordName): siapa yang keduluan
local grabState = nil -- teks langkah yang lagi jalan, nil = idle
local claimSpam, claimTries = false, 0 -- event claim (tombol di card), lihat startClaim
local grabNote, grabNoteUntil = nil, 0 -- hasil terakhir, ditampilin sebentar
-- Collected cuma dikirim ke yang ngambil: satu-satunya bukti "gw yang dapet".
-- Phase keluar Active doang bisa berarti diambil orang atau despawn.
local grabCollected = false

-- prompt yang lagi tampil ke lu, dilacak dari awal: PromptShown cuma fire
-- pas transisi, jadi nyambung ke prompt.PromptShown abis udah deket = telat
local shownPrompts = setmetatable({}, { __mode = "k" })
do
    local pps = game:GetService("ProximityPromptService")
    pps.PromptShown:Connect(function(p) shownPrompts[p] = true end)
    pps.PromptHidden:Connect(function(p) shownPrompts[p] = nil end)
end

swordEvent.OnClientEvent:Connect(function(kind, a, b)
    -- instance lama yang masih di tengah grab tetep butuh Collected-nya sendiri
    if stale() and not grabState then return end
    if kind == "Impact" and typeof(a) == "Vector3" then
        swordPos = a
        claimedBy = nil
    elseif kind == "Claimed" then
        claimedBy = tostring(a)
    elseif kind == "Collected" and (grabState or claimSpam) then
        if grabState then grabCollected = true end
        -- (kind, rarity, swordName, ...) cuma dikirim ke yang ngambil.
        -- Penanda di awal baris pertama (yang muncul di preview notif) biar
        -- pesan "dapet" kebaca dari jauh di antara notif drop dan gagal.
        notifyTelegram("✅ <b>DAPET: " .. escapeHtml(tostring(a) .. ": " .. tostring(b)) .. "</b>\nWorld "
            .. tostring(lp:GetAttribute("CurrentWorld")) .. ", ambil otomatis.", TG_THREAD_DAPET)
    end
end)

-- AFK pad ("Peternakan AFK"): masuk lewat AFKPrompt di Worlds["World N"].Train
-- ["Train<i>"], server nge-set PlayerStats.AFKPad = i; keluar lewat
-- AFKExitRequest:FireServer() (yang ditembak game pas lompat). Dicek
-- diag_afk.lua 2026-09-27.
local afkExit = remotes:WaitForChild("AFKExitRequest")
local AFK_FILE = "swordtracker_afk.txt"
local afkMode = false
do
    local ok, saved = pcall(readfile, AFK_FILE)
    afkMode = ok and saved == "1"
end
-- dideklarasi di sini (bukan di blok AFK di bawah) karena grabSword/startClaim
-- nunggu afkState kelar dulu sebelum mulai
local afkState = nil -- teks langkah goToPad yang lagi jalan, nil = idle
local afkNote = nil -- alasan gagal terakhir, ditampilin di tombol
local afkRetryAt = 0 -- keeper AFK diem sampe waktu ini (gagal / teleport manual)
-- teks langkah beli charm yang lagi jalan (jalan ke toko / beli), nil = idle.
-- Di sini karena grab/claim/goToPad/keeper ngecek ini buat gak rebutan karakter.
local charmState = nil

local function afkPad()
    local ps = lp:FindFirstChild("PlayerStats")
    local v = ps and ps:FindFirstChild("AFKPad")
    return v and v.Value or 0
end

-- keluar pad dulu sebelum lari/teleport/jalan: selama AFK karakter dikunci
local function exitAFK()
    if afkPad() == 0 then return end
    afkExit:FireServer()
    local t = os.clock() + 3
    repeat task.wait(0.1) until afkPad() == 0 or os.clock() > t
end

-- MoveTo + tunggu yang gak bisa nyangkut: MoveToFinished gak pernah fire
-- kalau karakter mati/diganti di tengah jalan. abortFn opsional buat
-- berhenti di tengah (mis. ada sword yang mau diambil).
local function moveToTimed(hum, pos, timeout, abortFn)
    local done = false
    local conn = hum.MoveToFinished:Once(function() done = true end)
    hum:MoveTo(pos)
    local t = os.clock() + (timeout or 10)
    local aborted = false
    -- mentok = jarak datar ke tujuan gak berkurang >= 1.5 stud per 0.5s -> lompat.
    -- Diukur dari JARAK KE TUJUAN, bukan "gerak apa nggak": nabrak dinding di
    -- WalkSpeed 100 bikin karakter meluncur nyamping sepanjang dinding, jadi
    -- keliatan "gerak" padahal gak maju (kejadian 2026-09-27: diem di kaki
    -- undakan pad baris belakang, 3.8 stud; lompatan default ~7 stud).
    -- 6x lompat masih mentok = nyerah. (Game matiin state Jumping selama
    -- auto-win nyala; semua pemanggil jalan ini udah matiin auto-win duluan.)
    local function flatTo(p)
        local d = p - pos
        return Vector3.new(d.X, 0, d.Z).Magnitude
    end
    local lastFlat = hum.RootPart and flatTo(hum.RootPart.Position)
    local lastCheck, jumps = os.clock(), 0
    repeat
        task.wait(0.1)
        aborted = abortFn ~= nil and abortFn()
        local rp = hum.RootPart
        if rp and lastFlat and os.clock() - lastCheck >= 0.5 then
            local flat = flatTo(rp.Position)
            if flat > 3 and lastFlat - flat < 1.5 then
                jumps = jumps + 1
                if jumps > 6 then break end
                hum.Jump = true
                hum:MoveTo(pos)
            end
            lastFlat, lastCheck = flat, os.clock()
        end
    until done or aborted or os.clock() > t or not hum.Parent or hum.Health <= 0
    conn:Disconnect()
    if aborted and hum.RootPart then hum:MoveTo(hum.RootPart.Position) end
end

-- Jalan pake PathfindingService: ngelewatin tangga/undakan/lompatan. MoveTo
-- lurus mentok di undakan pad baris belakang (kejadian 2026-09-27, pad
-- x8.86B/x7.68B lantainya lebih tinggi). Rute gak ketemu = jalan lurus.
-- reached() opsional: berhenti begitu udah nyampe (mis. masuk zona toko).
local PathfindingService = game:GetService("PathfindingService")
local function walkTo(hum, pos, abortFn, reached)
    local root = hum.RootPart
    if not root then return end
    local function stop() return (abortFn ~= nil and abortFn()) or (reached ~= nil and reached()) end
    local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 4 })
    local ok = pcall(function() path:ComputeAsync(root.Position, pos) end)
    if ok and path.Status == Enum.PathStatus.Success then
        -- rute kehitung tapi gak bisa diikutin (mentok undakan) = tiap titik
        -- nunggu timeout satu-satu, bisa menitan (kejadian 2026-09-27 "Jalan ke
        -- pad x8.1B..." nyangkut). Meleset 2 titik berturut / lewat 25s = nyerah,
        -- biar pemanggilnya nyoba cara lain.
        local misses, tEnd = 0, os.clock() + 25
        for _, wp in ipairs(path:GetWaypoints()) do
            if stop() or not hum.Parent or os.clock() > tEnd then return end
            if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
            moveToTimed(hum, wp.Position, 3, stop)
            local rp = hum.RootPart
            if rp and (rp.Position - wp.Position).Magnitude > 6 then
                misses = misses + 1
                if misses >= 2 then return end
            else
                misses = 0
            end
        end
        return
    end
    moveToTimed(hum, pos, 9, stop)
end

local function setAutoWin(on)
    if (lp:GetAttribute("AutoWin") == true) ~= on then
        -- auto-win pas masih duduk di pad = karakter kekunci; keluar pad dulu
        if on and afkPad() > 0 then afkExit:FireServer() end
        autoWin:FireServer(on)
    end
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
-- Zona finish. Auto-win gak pernah lewat ~90 stud sebelum tembok terakhir:
-- begitu tinjunya (MaximumWallPunchDistance 90) nyampe tembok stage terakhir,
-- server nganggep world kelar dan nge-reset ke start (kejadian 2026-09-27:
-- DeepSea di X -897 World 1, lari cuma nyampe X -798, 2 putaran). Sword di
-- situ: lari sampe garis aman, auto-win mati, tembok sisanya ditinju pake
-- PunchRequest (remote yang sama kayak klik mukul), terus jalan.
-- Semua world pake template X yang sama; fallback kalau Train/tembok belum ke-stream.
local TRACK_END_X = -890
local punchRemote = remotes:WaitForChild("PunchRequest")

-- tembok personal terdekat yang belum pecah, di antara karakter dan sword
-- (ciri "belum pecah" sama kayak activeWallTarget punya game: PersonalWall,
-- CanQuery, gak transparan)
local function nextWall(from, target)
    local f = workspace:FindFirstChild("PunchEscapePersonalWalls")
    if not f then return nil end
    local best = nil
    for _, v in ipairs(f:GetChildren()) do
        if v:IsA("BasePart") and v:GetAttribute("PersonalWall") == true and v.CanQuery and v.Transparency < 1 then
            local p = v.Position
            if p.X <= from.X + 4 and p.X >= target.X - 2 and math.abs(p.Z - target.Z) < 30 then
                if not best or p.X > best.Position.X then best = v end
            end
        end
    end
    return best
end

local function trackRange(world)
    local f = workspace:FindFirstChild("Worlds")
    f = f and f:FindFirstChild("World " .. world)
    f = f and f:FindFirstChild("Destructable walls")
    if not f then return nil end
    -- part-nya di-stream satu-satu: abis teleport cuma stage deket spawn yang
    -- ada, dan min X dari situ = "ujung" palsu di tengah track (kejadian
    -- 2026-09-26: Mythic di World 5 ditolak "lewat ujung"). Ujung cuma
    -- dipercaya kalau 4 pad win stage terakhir udah ada, start kalau
    -- stage pertama udah ada isinya.
    local first, firstN, last, lastN = nil, math.huge, nil, -math.huge
    for _, s in ipairs(f:GetChildren()) do
        local n = tonumber(s:GetAttribute("Stage"))
        if n then
            if n < firstN then first, firstN = s, n end
            if n > lastN then last, lastN = s, n end
        end
    end
    local endX, startX = nil, nil
    local pads = last and last:FindFirstChild("WinPart")
    if pads then
        local cnt = 0
        for _, p in ipairs(pads:GetChildren()) do
            if p:IsA("BasePart") then
                cnt = cnt + 1
                if not endX or p.Position.X < endX then endX = p.Position.X end
            end
        end
        if cnt < 4 then endX = nil end
    end
    if first then
        for _, d in ipairs(first:GetDescendants()) do
            if d:IsA("BasePart") and (not startX or d.Position.X > startX) then startX = d.Position.X end
        end
    end
    return endX, startX
end

local function grabSword(target, world)
    if grabState or claimSpam then return end -- claim event lagi pegang karakter
    grabState = "Mulai..."
    task.spawn(function()
        local wasOn = lp:GetAttribute("AutoWin") == true
        local deadline = os.clock() + 90
        -- goToPad yang udah lewat checkpoint terakhirnya masih bisa dudukin
        -- karakter / teleport; tunggu kelar dulu (maks 10s) baru keluar pad
        local t0 = os.clock() + 10
        -- (beli charm juga: dia ngalah begitu ngeliat grabState, tinggal nunggu)
        repeat task.wait(0.1) until (not afkState and not teleportPending and not charmState) or os.clock() > t0
        exitAFK() -- lagi duduk di pad AFK = kekunci, gak bisa lari/teleport
        local label = tostring(dropState:GetAttribute("Rarity")) .. ": " .. tostring(dropState:GetAttribute("SwordName"))
        local function active() return dropState:GetAttribute("Phase") == "Active" end
        grabCollected = false
        -- Phase keluar Active = diambil orang ATAU despawn (EndsAt lewat); bedain.
        -- Claimed (orang lain) menang: jam PC bisa beda dikit sama server.
        local endsAt = dropState:GetAttribute("EndsAt")
        local function lostMsg()
            if claimedBy and claimedBy ~= lp.Name then return "Sword keburu diambil" end
            if type(endsAt) == "number" and os.time() >= endsAt - 1 then return "Sword keburu ilang (despawn)" end
            return "Sword keburu diambil"
        end
        -- abis kelar: auto-win balik nyala kalau tadinya nyala ATAU mode ambil
        -- otomatis lagi aktif (farming lanjut sampe drop berikutnya). Gagal =
        -- kirim ke Telegram juga (yang sukses udah lewat event Collected), user
        -- AFK gak bakal liat baris status yang cuma 4 detik.
        local zoneInfo = nil -- info zona finish (jumlah tinju), ikut ke pesan gagal
        local function finish(msg, success)
            -- mode AFK: auto-win mati, keeper di Heartbeat yang balikin ke pad
            setAutoWin((wasOn or next(grabOn) ~= nil) and not afkMode)
            grabState = nil
            grabNote, grabNoteUntil = msg, os.clock() + 4
            if not success then
                local why = msg .. (zoneInfo or "")
                if claimedBy and claimedBy ~= lp.Name and msg == "Sword keburu diambil" then
                    why = why .. " sama " .. claimedBy
                end
                notifyTelegram("❌ <b>Gagal ambil: " .. escapeHtml(label) .. "</b>\n" .. escapeHtml(why) .. ".\nWorld " .. world .. ".", TG_THREAD_GAGAL)
            end
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
            -- teleport lain (mis. ke pad AFK) masih jalan = teleportToWorld bakal
            -- nolak diam-diam; tunggu itu kelar dulu (maks 10s)
            t = os.clock() + 10
            repeat task.wait(0.1) until not teleportPending or os.clock() > t
            teleportToWorld(world)
            repeat task.wait(0.2) until lp:GetAttribute("CurrentWorld") == world or os.clock() > deadline or not active()
            if lp:GetAttribute("CurrentWorld") ~= world then return finish(active() and "Teleport gagal" or lostMsg()) end
            task.wait(1)
            -- minta stream sekitar sword-nya dulu (maks 5s): biar tembok/pad
            -- buat trackRange dan part sword buat prompt udah ada
            pcall(function() lp:RequestStreamAroundAsync(target, 5) end)
        end

        -- cek dulu sword-nya di jalur auto-win apa nggak, biar gak lari sia-sia:
        -- lewat ujung = tolak; di belakang start (deket spawn, gak ada tembok)
        -- = jalan biasa tanpa auto-win. Folder belum ke-stream = lewatin cek,
        -- penghitung putaran di bawah yang jaga.
        local endX, startX = trackRange(world)
        if endX and target.X < endX - 8 then return finish("Sword di luar track (lewat ujung)") end
        local walkOnly = startX ~= nil and target.X > startX + 8
        local zoneEnd = endX or TRACK_END_X
        -- sword lewat titik reset auto-win (~ujung+100): lari cuma sampe garis
        -- aman ujung+150 (tembok stage terakhir masih utuh, server belum reset)
        local finishZone = not walkOnly and target.X < zoneEnd + 100
        local aimX = finishZone and (zoneEnd + 150) or target.X

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
            -- berhenti begitu lewat aimX (X sword, atau garis aman zona finish)
            local lead = finishZone and 0 or 8
            local lastX, laps = nil, 0
            local runMin, runMax, maxStep, frames = math.huge, -math.huge, 0, 0
            -- stat lari buat pesan gagal: ketauan karakter beneran lewat X sword
            -- apa nggak, dan fps-nya anjlok apa nggak (kejadian 2026-09-27:
            -- "di luar jalur" di World 4 tanpa data buat nebak sebabnya)
            local function runInfo()
                return string.format(" (sword X %.0f, target lari X %.0f, lari X %.0f..%.0f, langkah max %.0f, %d putaran, %d frame)",
                    target.X, aimX, runMin, runMax, maxStep, laps, frames)
            end
            local hit = false
            repeat
                task.wait()
                local c = lp.Character
                root = c and c:FindFirstChild("HumanoidRootPart")
                if not active() then return finish(lostMsg()) end
                if os.clock() > deadline then return finish("Kelamaan, batal" .. runInfo()) end
                -- instance baru udah jalan dan bakal ngurus drop ini sendiri
                if stale() then autoWin:FireServer(false); grabState = nil; return end
                if root then
                    local x = root.Position.X
                    frames = frames + 1
                    if x < runMin then runMin = x end
                    if x > runMax then runMax = x end
                    -- frame pertama udah pas di sebelah sword (mis. jatuh deket start)
                    if not lastX and math.abs(x - aimX) <= 8 then hit = true end
                    if lastX then
                        local step = x - lastX
                        -- lompat balik ke start = satu putaran. Satu putaran wajar (mulai
                        -- dari posisi yang udah lewat sword-nya); dua putaran tanpa pernah
                        -- kena = sword di luar jalur auto-win, jangan muter terus.
                        if step > 300 then
                            laps = laps + 1
                            -- abis di-reset ke start (X ~+6): sword deket start (X ~0)
                            -- udah di dalam jendela di frame ini, gak ada "lintasan"
                            local d = x - aimX
                            if d <= lead and d >= -8 then hit = true end
                        else
                            if math.abs(step) > maxStep then maxStep = math.abs(step) end
                            -- deteksi LINTASAN antar frame, bukan nunggu frame pas di dalam
                            -- jendela: frame lalu masih > sword+lead, frame ini udah <= itu.
                            -- Tahan fps anjlok (100 stud/s, satu frame bisa loncat >16 stud).
                            local dxPrev, dx = lastX - aimX, x - aimX
                            if dxPrev > lead and dx <= lead then hit = true end
                        end
                    end
                    lastX = x
                    if laps >= 2 then return finish("Sword di luar jalur auto-win" .. runInfo()) end
                end
            until hit
            -- langsung FireServer, bukan setAutoWin: kalau hit di frame pertama,
            -- attribute AutoWin belum sempet jadi true dan setAutoWin(false) bakal
            -- ngira udah mati terus gak ngirim apa-apa. Server proses berurutan.
            autoWin:FireServer(false)

            if finishZone then
                -- tinju tembok sisanya sendiri (auto-win mati = server gak nge-reset
                -- pas ngeliat kita deket ujung). Maks 20s; X lompat ke start = server
                -- tetep nganggep world kelar pas tembok terakhir pecah.
                grabState = "Mecahin tembok terakhir..."
                task.wait(0.3)
                local punched = 0
                local tEnd = os.clock() + 20
                while os.clock() < tEnd do
                    if not active() then zoneInfo = string.format(" (zona finish, %d tinju)", punched); return finish(lostMsg()) end
                    if stale() then grabState = nil; return end
                    local c2 = lp.Character
                    local r2 = c2 and c2:FindFirstChild("HumanoidRootPart")
                    local h2 = c2 and c2:FindFirstChildOfClass("Humanoid")
                    if not (r2 and h2) then return finish("Karakter gak ada") end
                    if r2.Position.X > aimX + 300 then
                        zoneInfo = string.format(" (zona finish, %d tinju)", punched)
                        return finish("Tembok terakhir pecah = world kelar, ke-reset ke start")
                    end
                    local wall = nextWall(r2.Position, target)
                    if not wall then break end
                    -- tinju kejangkau 90 stud; lebih dari 60 = deketin dulu
                    if (wall.Position - r2.Position).Magnitude > 60 then
                        h2:MoveTo(Vector3.new(wall.Position.X + 6, r2.Position.Y, r2.Position.Z))
                    end
                    punchRemote:FireServer(wall.Position)
                    punched = punched + 1
                    task.wait(0.25)
                end
                zoneInfo = string.format(" (zona finish, %d tinju)", punched)
            end
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
        -- 60, bukan 40: deteksi lintasan bisa kelewat satu frame pas fps anjlok
        -- zona finish: berhenti di garis aman ~150 stud sebelum ujung, sisanya jalan
        if gapLeft > ((walkOnly or finishZone) and 250 or 60) then
            return finish(string.format("Auto-win keburu reset, sword kelewat (jarak %.0f)", gapLeft))
        end
        local hum = c:FindFirstChildOfClass("Humanoid")
        if hum and gapLeft > 6 then moveToTimed(hum, target, 8) end

        local prompt
        for _ = 1, 15 do
            prompt = findPrompt()
            if prompt then break end
            task.wait(0.2)
        end
        if not prompt then return finish("Prompt sword gak ketemu") end

        -- prompt-nya nempel di part sword, bisa beda beberapa stud dari titik
        -- Impact (kejadian 2026-09-26: "Gak keambil" padahal udah di titik
        -- Impact). Deketin ke part prompt-nya sampe dalam jangkauan, tunggu
        -- prompt-nya beneran muncul, baru tahan. Masih gagal = coba
        -- fireproximityprompt kalau executor-nya punya.
        local adornee = prompt.Parent
        local function promptPos()
            if adornee and adornee:IsA("BasePart") then return adornee.Position end
            if adornee and adornee:IsA("Model") then return adornee:GetPivot().Position end
            if adornee and adornee:IsA("Attachment") then return adornee.WorldPosition end
            return target
        end
        local reach = math.max(2, prompt.MaxActivationDistance - 2)
        if hum and (root.Position - promptPos()).Magnitude > reach then moveToTimed(hum, promptPos(), 6) end
        local triggered = false
        local c2 = prompt.Triggered:Connect(function() triggered = true end)
        local t = os.clock() + 2
        repeat task.wait(0.1) until shownPrompts[prompt] or os.clock() > t
        local shown = shownPrompts[prompt] == true
        prompt:InputHoldBegin()
        task.wait(prompt.HoldDuration + 0.25)
        prompt:InputHoldEnd()
        t = os.clock() + 3
        repeat task.wait(0.2) until not active() or os.clock() > t
        if active() and fireproximityprompt then
            pcall(fireproximityprompt, prompt)
            t = os.clock() + 3
            repeat task.wait(0.2) until not active() or os.clock() > t
        end
        c2:Disconnect()
        if active() then
            -- angka-angkanya ikut ke Telegram biar kegagalan berikutnya langsung kebaca sebabnya
            return finish(string.format("Gak keambil (jarak %.1f, max %.0f, hold %.1fs, LOS %s, enabled %s, shown %s, triggered %s, fpp %s)",
                (root.Position - promptPos()).Magnitude, prompt.MaxActivationDistance, prompt.HoldDuration,
                tostring(prompt.RequiresLineOfSight), tostring(prompt.Enabled), tostring(shown), tostring(triggered),
                tostring(fireproximityprompt ~= nil)))
        end
        -- Phase udah keluar Active: dapet cuma kalau Collected beneran nyampe
        -- ke kita (bisa telat dikit dari attribute-nya)
        t = os.clock() + 1.5
        repeat task.wait(0.1) until grabCollected or os.clock() > t
        if not grabCollected then return finish(lostMsg()) end
        finish("Dapet!", true)
    end)
end

-- Event claim (mis. "The Admin's Blade" di hub, prompt "Attempt to claim",
-- stok terbatas). Prompt-nya dilacak lewat DescendantAdded, bukan scan tiap
-- tick. Tombol di card cuma muncul kalau prompt-nya ada. Nyoba = jalan ke
-- deket, tahan prompt (API resmi kayak nahan E), ulang sampe prompt ilang
-- atau di-stop.
local eventPrompt = nil

local function isEventPrompt(d)
    return d:IsA("ProximityPrompt") and d.ActionText:lower():find("attempt") ~= nil
end
local function watchPrompt(d)
    if not d:IsA("ProximityPrompt") then return end
    if isEventPrompt(d) then eventPrompt = d; return end
    -- ActionText kadang di-set abis instance-nya masuk
    d:GetPropertyChangedSignal("ActionText"):Once(function()
        if isEventPrompt(d) then eventPrompt = d end
    end)
end
task.spawn(function()
    for _, d in ipairs(workspace:GetDescendants()) do watchPrompt(d) end
end)
workspace.DescendantAdded:Connect(watchPrompt)
workspace.DescendantRemoving:Connect(function(d)
    if d == eventPrompt then eventPrompt = nil end
end)

local function promptWorldPos(p)
    local a = p.Parent
    if a and a:IsA("BasePart") then return a.Position end
    if a and a:IsA("Model") then return a:GetPivot().Position end
    if a and a:IsA("Attachment") then return a.WorldPosition end
end

local claimGen = 0
-- status auto-win yang dibalikin pas claim kelar. Di level modul, bukan per
-- klik: Stop -> Claim cepet-cepet bikin klik kedua ngebaca AutoWin yang udah
-- dimatiin klik pertama, dan nilai aslinya ilang.
local claimRestore = false

local function startClaim()
    if claimSpam then claimSpam = false; return end
    if grabState then return end -- lagi ngambil sword; dua-duanya rebutan karakter
    claimSpam, claimTries = true, 0
    -- generasi: Stop lalu Claim cepet-cepet gak boleh ninggalin loop lama jalan
    claimGen = claimGen + 1
    local my = claimGen
    claimRestore = claimRestore or lp:GetAttribute("AutoWin") == true
    -- langsung FireServer: setAutoWin(false) no-op kalau attribute-nya belum
    -- sempet true (auto-win baru aja dinyalain)
    autoWin:FireServer(false)
    task.spawn(function()
        local function going() return claimSpam and claimGen == my and not stale() end
        -- goToPad yang lagi masuk pad bisa dudukin karakter abis kita keluar pad
        local t0 = os.clock() + 10
        repeat task.wait(0.1) until (not afkState and not charmState) or os.clock() > t0
        while going() do
            local p = eventPrompt
            if not (p and p.Parent) then break end
            exitAFK() -- murah kalau gak lagi duduk; jaga-jaga kalau keduluan pad
            local c = lp.Character
            local root = c and c:FindFirstChild("HumanoidRootPart")
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            local pos = promptWorldPos(p)
            if root and hum and pos and (root.Position - pos).Magnitude > p.MaxActivationDistance - 2 then
                moveToTimed(hum, pos, 8, function() return not going() end)
            end
            if p.Enabled and going() then
                p:InputHoldBegin()
                task.wait(p.HoldDuration + 0.1)
                p:InputHoldEnd()
                claimTries = claimTries + 1
            end
            task.wait(0.4)
        end
        if claimGen == my then
            claimSpam = false
            -- balikin auto-win kayak sebelum claim (mode AFK/ambil otomatis
            -- punya keeper sendiri di Heartbeat)
            if claimRestore and not afkMode and not stale() then setAutoWin(true) end
            claimRestore = false
        end
    end)
end

-- Pad AFK terbaik, dibaca dari attribute part Workspace.Worlds["World N"].Train
-- ["Train<i>"]: TrainingIndex, PowerMultiplier, RequiredRebirths, GamePassId.
-- SENGAJA gak require PunchEscapeConfig: modul yang di-require duluan dari
-- executor jadi "RobloxScript module", dan script game sendiri gagal require-nya
-- ("Cannot require a RobloxScript module from a non RobloxScript context"),
-- kejadian 2026-09-27: HUD power/level game beku semua.
-- Pad terbaik selalu di world tertinggi yang kebuka (multiplier pad world atas
-- > semua pad world bawah, dicek dari tabel Training), dan pad pertama tiap
-- world syaratnya 0 rebirth, jadi pasti ada yang bisa dipake di situ.
local MarketplaceService = game:GetService("MarketplaceService")
local passOwned, passRetryAt = {}, {}

-- nil/0 = gak butuh pass. Belum kecek = dianggap belum punya, dicek di
-- background; gagal cek = coba lagi 30s kemudian (bukan "gak punya" permanen).
local function ownsPass(id)
    if not id or id == 0 then return true end
    if passOwned[id] ~= nil then return passOwned[id] end
    if os.clock() >= (passRetryAt[id] or 0) then
        passRetryAt[id] = os.clock() + 30
        task.spawn(function()
            local ok, owns = pcall(function() return MarketplaceService:UserOwnsGamePassAsync(lp.UserId, id) end)
            if ok then passOwned[id] = owns == true end
        end)
    end
    return passOwned[id] == true
end

local function fmtMult(m)
    for _, s in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if m >= s[1] then
            local num = string.format("%.2f", m / s[1]):gsub("%.?0+$", "")
            return "x" .. num .. s[2]
        end
    end
    return "x" .. tostring(m)
end

local function trainFolder(world)
    local worlds = workspace:FindFirstChild("Worlds")
    local w = worlds and worlds:FindFirstChild("World " .. world)
    return w and w:FindFirstChild("Train")
end

-- data player udah ke-load (autoexec bisa jalan duluan sebelum server ngisi)
local function afkWorld()
    local ns = lp:FindFirstChild("NumericStats")
    if not (ns and ns:FindFirstChild("Rebirths")) then return nil end
    return lp:GetAttribute("MaxWorldUnlocked")
end

-- pad yang udah kebukti gak kejangkau (jalan + balik ke spawn tetep gagal):
-- dilewatin sampe waktu ini, biar AFK lanjut di pad terbaik berikutnya
-- ketimbang nyangkut di bawah undakan (kejadian 2026-09-27, pad x8.1B)
local padBlockedUntil = {}

-- nil kalau folder Train world itu belum ke-stream
local function pickPad(world)
    local train = trainFolder(world)
    if not train then return nil end
    local reb = lp.NumericStats.Rebirths.Value
    local best = nil
    for _, part in ipairs(train:GetChildren()) do
        local idx = part:GetAttribute("TrainingIndex")
        local mult = part:GetAttribute("PowerMultiplier")
        if type(idx) == "number" and type(mult) == "number"
            and (part:GetAttribute("RequiredRebirths") or 0) <= reb
            and os.clock() >= (padBlockedUntil[idx] or 0)
            and ownsPass(part:GetAttribute("GamePassId")) then
            if not best or mult > best.mult then best = { index = idx, world = world, mult = mult, part = part } end
        end
    end
    return best
end

-- multiplier pad yang lagi didudukin (dari part-nya), nil kalau gak duduk
local function currentPadMult(world)
    local i = afkPad()
    if i <= 0 then return nil end
    local train = trainFolder(world)
    local part = train and train:FindFirstChild("Train" .. i)
    return part and part:GetAttribute("PowerMultiplier")
end

local function goToPad(world)
    if afkState then return end
    afkState = "Ke pad AFK World " .. world .. "..."
    task.spawn(function()
        local function interrupted() return grabState ~= nil or claimSpam or charmState ~= nil or not afkMode or stale() end
        local function fail(msg)
            afkState, afkNote, afkRetryAt = nil, msg, os.clock() + 15
        end
        setAutoWin(false)
        local t = os.clock() + 2
        repeat task.wait(0.1) until lp:GetAttribute("AutoWin") ~= true or os.clock() > t
        if interrupted() then afkState = nil; return end
        exitAFK() -- pindah dari pad lama

        if lp:GetAttribute("CurrentWorld") ~= world then
            if interrupted() then afkState = nil; return end
            afkState = "Teleport ke World " .. world .. "..."
            teleportToWorld(world)
            t = os.clock() + 25
            repeat task.wait(0.2) until lp:GetAttribute("CurrentWorld") == world or os.clock() > t or interrupted()
            if interrupted() then afkState = nil; return end
            if lp:GetAttribute("CurrentWorld") ~= world then return fail("Teleport ke World " .. world .. " gagal") end
            task.wait(1)
        end

        -- pad-pad di deket spawn, ke-stream bareng spawn; kasih waktu bentar
        local worlds = workspace:FindFirstChild("Worlds")
        local w = worlds and worlds:FindFirstChild("World " .. world)
        if w then w:WaitForChild("Train", 5) end
        task.wait(0.5)
        local pad = pickPad(world)
        local prompt = pad and pad.part:FindFirstChildWhichIsA("ProximityPrompt", true)
        if not prompt then return fail("Pad AFK World " .. world .. " gak ketemu") end
        local c = lp.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        local root = c and c:FindFirstChild("HumanoidRootPart")
        if not (hum and root) then return fail("Karakter gak ada") end

        afkState = "Jalan ke pad " .. fmtMult(pad.mult) .. "..."
        local pos = promptWorldPos(prompt) or pad.part.Position
        -- pathfinding (pad baris belakang lantainya lebih tinggi); diulang sampe
        -- 3x kalau belum nyampe (rute panjang dari ujung track / MoveTo 8s)
        local function near() return (root.Position - pos).Magnitude <= prompt.MaxActivationDistance - 2 end
        for _ = 1, 3 do
            if near() or interrupted() then break end
            walkTo(hum, pos, interrupted, near)
        end
        if interrupted() then afkState = nil; return end

        -- masih gak nyampe (jauh / peta belum ke-stream / kehalang undakan):
        -- muncul ulang di spawn world ini lewat teleport ke world lain terus
        -- balik (pad AFK ada di deket spawn), abis itu jalan lagi dari situ
        if not near() then
            local maxW = afkWorld() or world
            local other = (world > 1) and (world - 1) or ((maxW > world) and (world + 1) or nil)
            if other then
                afkState = "Balik ke spawn World " .. world .. "..."
                for _, target in ipairs({ other, world }) do
                    t = os.clock() + 10
                    repeat task.wait(0.1) until not teleportPending or os.clock() > t
                    teleportToWorld(target)
                    t = os.clock() + 25
                    repeat task.wait(0.2) until lp:GetAttribute("CurrentWorld") == target or os.clock() > t or interrupted()
                    if interrupted() then afkState = nil; return end
                    task.wait(1)
                end
                c = lp.Character
                hum = c and c:FindFirstChildOfClass("Humanoid")
                root = c and c:FindFirstChild("HumanoidRootPart")
                if not (hum and root) then return fail("Karakter gak ada") end
                -- part pad bisa ke-stream ulang abis teleport: ambil posisi baru
                pad = pickPad(world) or pad
                prompt = pad.part:FindFirstChildWhichIsA("ProximityPrompt", true) or prompt
                pos = promptWorldPos(prompt) or pad.part.Position
                afkState = "Jalan ke pad " .. fmtMult(pad.mult) .. "..."
                for _ = 1, 2 do
                    if near() or interrupted() then break end
                    walkTo(hum, pos, interrupted, near)
                end
                if interrupted() then afkState = nil; return end
            end
        end

        -- tetep gak nyampe: pad ini diblok 10 menit, keeper langsung milih pad
        -- terbaik berikutnya (mis. baris depan) ketimbang nyangkut terus
        if not near() then
            padBlockedUntil[pad.index] = os.clock() + 600
            fail(string.format("Pad %s gak kejangkau (jarak %.0f), pake pad bawahnya dulu",
                fmtMult(pad.mult), (root.Position - pos).Magnitude))
            afkRetryAt = os.clock() + 1
            return
        end

        prompt:InputHoldBegin()
        task.wait(prompt.HoldDuration + 0.2)
        prompt:InputHoldEnd()
        t = os.clock() + 3
        repeat task.wait(0.1) until afkPad() == pad.index or os.clock() > t
        if afkPad() ~= pad.index and fireproximityprompt then
            pcall(fireproximityprompt, prompt)
            t = os.clock() + 3
            repeat task.wait(0.1) until afkPad() == pad.index or os.clock() > t
        end
        if afkPad() ~= pad.index then
            return fail(string.format("Gak bisa masuk pad (jarak %.1f, max %.0f)",
                (root.Position - pos).Magnitude, prompt.MaxActivationDistance))
        end
        afkState, afkNote = nil, nil
    end)
end

-- ===== Charm Shop (auto beli pake Crystals) =====
-- Protokol dari decompile PlayerScripts.PunchEscapeCharmsUI (2026-09-27):
--   client  CharmShopRequest:FireServer("Get")         -> minta stok
--   server  CharmShopRequest.OnClientEvent({EndsAt, Window, Offers={id,id,id},
--           Purchased={[i]=true}})   (dikirim juga abis beli / pas restock)
--   client  CharmShopRequest:FireServer("Buy", slot, Window)   -> beli pake Crystals
-- Rarity/harga ada di PunchEscapeCharmConfig, yang GAK BOLEH di-require (bikin
-- script game gagal require). Gantinya dibaca dari kartu toko game
-- (CharmsShopWindow.Offer1..3): handler game ngisi kartu itu tiap stok dateng,
-- walaupun jendelanya ketutup.
-- PENTING: toko ini juga punya beli pake ROBUX (duit beneran) dan refresh pake
-- Robux. Script ini cuma boleh ngirim "Get" dan "Buy". Test-nya gagal kalau
-- nama aksi Robux muncul sebagai string di file ini.
local charmRemote = remotes:WaitForChild("CharmShopRequest")
local CHARM_FILE = "swordtracker_charm.txt"
local CHARM_RARITY = { Rare = true, Epic = true, Legendary = true, Mythic = true, Rainbow = true }
local charmOn = loadSet(CHARM_FILE, {}) -- default mati: ini ngabisin Crystals
local charmShop = nil -- state terakhir dari server
local charmHandledWindow = nil -- rotasi stok yang udah diproses
local charmBusy = false
local lastCharmGet = -math.huge -- request pertama langsung jalan

charmRemote.OnClientEvent:Connect(function(p)
    if stale() then return end
    if type(p) == "table" and type(p.Offers) == "table" then charmShop = p end
end)

local function fmtNum(n)
    for _, s in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= s[1] then return (string.format("%.2f", n / s[1]):gsub("%.?0+$", "")) .. s[2] end
    end
    return tostring(math.floor(n))
end

local function crystals()
    local ns = lp:FindFirstChild("NumericStats")
    local v = ns and ns:FindFirstChild("Crystals")
    return v and v.Value or 0
end

-- rarity, nama, teks harga dari kartu toko game (nil kalau belum ada).
-- Nama = label yang teksnya id charm-nya dikasih spasi ("Solar Radiance" buat
-- id SolarRadiance), jadi label dekorasi lain gak ketuker jadi nama.
local function charmCard(i, id)
    local ui = lp.PlayerGui:FindFirstChild("PunchEscapeUI")
    local win = ui and ui:FindFirstChild("CharmsShopWindow", true)
    local card = win and win:FindFirstChild("Offer" .. i, true)
    if not card then return nil end
    local rarity, name, price = nil, nil, nil
    for _, d in ipairs(card:GetDescendants()) do
        if d:IsA("TextLabel") then
            -- label di dalem tombol: cuma tombol Crystals (BuyWins) yang dibaca
            -- harganya; tombol lain (Robux) dilewatin tanpa perlu disebut namanya
            local btn = d:FindFirstAncestorWhichIsA("GuiButton")
            if btn then
                if btn.Name == "BuyWins" and d.Text:find("Crystals") then price = d.Text end
            else
                if CHARM_RARITY[d.Text] then
                    rarity = d.Text
                elseif id and d.Text:gsub("%s", "") == id then
                    name = d.Text
                end
            end
        end
    end
    return rarity, name, price
end

-- Server cuma ngizinin beli kalau lagi berdiri di toko ("Stand near the Charms
-- shop to purchase.", 2026-09-27). Zona toko = part Worlds["World N"]["Boss
-- Things"].CharmShop, dicek persis kayak game-nya (GetPartBoundsInBox ke
-- karakter, ukuran part + (0.3, 0.8, 0.3)).
local charmRetryAt = 0

local function shopZone()
    local worlds = workspace:FindFirstChild("Worlds")
    local w = worlds and worlds:FindFirstChild("World " .. tostring(lp:GetAttribute("CurrentWorld") or 1))
    local bt = w and w:FindFirstChild("Boss Things")
    local z = bt and bt:FindFirstChild("CharmShop")
    return (z and z:IsA("BasePart")) and z or nil
end

local function inShop(z)
    local c = lp.Character
    if not (c and z) then return false end
    local op = OverlapParams.new()
    op.FilterType = Enum.RaycastFilterType.Include
    op.FilterDescendantsInstances = { c }
    return #workspace:GetPartBoundsInBox(z.CFrame, z.Size + Vector3.new(0.3, 0.8, 0.3), op) > 0
end

-- slot yang rarity-nya dicentang dan belum kebeli di rotasi ini. Balikin juga
-- true kalau ada kartu yang rarity-nya belum kebaca (handler toko game belum
-- ngisi): rotasinya jangan dianggap kelar, minta stok ulang.
local function wantedSlots(window)
    local s = charmShop
    local list, unread = {}, false
    if not s or s.Window ~= window then return list, false end
    for i = 1, 3 do
        local id = tostring(s.Offers[i])
        local rarity, name, price = charmCard(i, id)
        local bought = type(s.Purchased) == "table" and s.Purchased[i] == true
        if not rarity then unread = true end
        if rarity and charmOn[rarity] and not bought then
            table.insert(list, { i = i, id = id, rarity = rarity, name = name, price = price })
        end
    end
    return list, unread
end

-- "done" = rotasi ini kelar (kebeli / gak ada yang dimau / gagal dan udah
-- dilaporin); "retry" = lagi ada yang lebih penting (grab sword / claim event),
-- dicoba lagi 10s kemudian di rotasi yang sama.
local function buyWanted(window)
    task.wait(0.4) -- kasih handler toko game waktu ngisi kartu
    local want, unread = wantedSlots(window)
    if unread then return "reread" end
    if #want == 0 then return "done" end
    -- semua chip dimatiin di tengah jalan = batal (jalan ke toko ikut berhenti)
    local function busy() return grabState ~= nil or claimSpam or stale() or next(charmOn) == nil end
    if busy() then return "retry" end

    local wasOn = lp:GetAttribute("AutoWin") == true
    charmState = "Ke Charm Shop..."
    local function done(status)
        charmState = nil
        -- auto-win manual dibalikin; mode AFK / ambil otomatis punya keeper sendiri
        if wasOn and not afkMode and next(grabOn) == nil and not grabState then setAutoWin(true) end
        return status
    end
    local function fail(msg)
        notifyTelegram("❌ <b>Gagal beli charm</b>\n" .. escapeHtml(msg) .. ".", TG_THREAD_GAGAL)
        return done("done")
    end

    -- goToPad yang lagi jalan ngalah begitu liat charmState; tunggu dia lepas
    local t = os.clock() + 10
    repeat task.wait(0.1) until not afkState or os.clock() > t
    autoWin:FireServer(false)
    exitAFK()

    local z = shopZone()
    if not z then
        -- toko gak ada di world ini: coba world tertinggi (tempat toko ketemu pertama)
        local w = afkWorld()
        if w and lp:GetAttribute("CurrentWorld") ~= w then
            charmState = "Teleport ke World " .. w .. " (Charm Shop)..."
            t = os.clock() + 10
            repeat task.wait(0.1) until not teleportPending or os.clock() > t
            teleportToWorld(w)
            t = os.clock() + 25
            repeat task.wait(0.2) until lp:GetAttribute("CurrentWorld") == w or os.clock() > t or busy()
            if busy() then return done("retry") end
            task.wait(1)
            local worlds = workspace:FindFirstChild("Worlds")
            local wm = worlds and worlds:FindFirstChild("World " .. w)
            local bt = wm and wm:WaitForChild("Boss Things", 5)
            if bt then bt:WaitForChild("CharmShop", 5) end
            z = shopZone()
        end
    end
    if not z then return fail("Charm Shop gak ketemu di World " .. tostring(lp:GetAttribute("CurrentWorld"))) end

    charmState = "Jalan ke Charm Shop..."
    local c = lp.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    local root = c and c:FindFirstChild("HumanoidRootPart")
    if not (hum and root) then return fail("Karakter gak ada") end
    -- tujuan = bawah zona + 3 (tengah part bisa di dalem meja toko, pathfinding
    -- gak bisa nyari rute ke dalem benda); berhenti begitu masuk zona
    local goal = Vector3.new(z.Position.X, z.Position.Y - z.Size.Y / 2 + 3, z.Position.Z)
    for _ = 1, 4 do
        if inShop(z) or busy() then break end
        walkTo(hum, goal, busy, function() return inShop(z) end)
    end
    if busy() then return done("retry") end
    if not inShop(z) then
        return fail(string.format("Gak nyampe Charm Shop (jarak %.0f)", (root.Position - z.Position).Magnitude))
    end

    charmState = "Beli charm..."
    for _, it in ipairs(want) do
        local s = charmShop
        if stale() or not s or s.Window ~= window then break end
        -- chip rarity ini masih nyala? (bisa dimatiin selama jalan ke toko)
        if charmOn[it.rarity] and not (type(s.Purchased) == "table" and s.Purchased[it.i] == true) then
            local oc = lp:FindFirstChild("OwnedCharms")
            local owned = oc and oc:FindFirstChild(it.id)
            local before = owned and owned.Value or 0
            local label = it.rarity .. ": " .. (it.name or it.id)
            charmRemote:FireServer("Buy", it.i, window) -- Crystals doang
            local ok = false
            t = os.clock() + 4
            repeat
                task.wait(0.2)
                local now = charmShop
                ok = (now and now.Window == window and type(now.Purchased) == "table" and now.Purchased[it.i] == true)
                    or (owned ~= nil and owned.Value > before)
            until ok or os.clock() > t
            if ok then
                notifyTelegram("✅ <b>BELI CHARM: " .. escapeHtml(label) .. "</b>\n" .. escapeHtml(it.price or "?")
                    .. ", sisa " .. fmtNum(crystals()) .. " Crystals.", TG_THREAD_DAPET)
            else
                notifyTelegram("❌ <b>Gagal beli charm: " .. escapeHtml(label) .. "</b>\nHarga " .. escapeHtml(it.price or "?")
                    .. ", Crystals lu " .. fmtNum(crystals()) .. ".", TG_THREAD_GAGAL)
            end
            task.wait(0.5)
        end
    end
    return done("done")
end

-- Notif restock ke topic utama (sama kayak notif drop pedang), sekali per
-- rotasi, cuma kalau minimal satu kartu rarity-nya nyala di chip "Notif
-- Telegram" (Rainbow gak punya chip di situ -> dianggap tier baru, selalu
-- lolos lewat wants()). Jalan walaupun auto-beli mati.
local CHARM_TIER = { Rainbow = 5, Mythic = 4, Legendary = 3, Epic = 2, Rare = 1 }
local charmNotifiedWindow = nil
local charmNotifying = false

local function notifyRestock(window)
    task.wait(0.4) -- kasih handler toko game waktu ngisi kartu
    local s = charmShop
    if not s or s.Window ~= window then return "done" end
    local cards, any = {}, false
    for i = 1, 3 do
        local id = tostring(s.Offers[i])
        local rarity, name, price = charmCard(i, id)
        if not rarity then return "reread" end
        if wants(notifyOn, rarity) then any = true end
        table.insert(cards, { i = i, rarity = rarity, name = name or id, price = price or "?",
            bought = type(s.Purchased) == "table" and s.Purchased[i] == true })
    end
    if not any then return "done" end

    local tiers = {}
    for _, c in ipairs(cards) do table.insert(tiers, c) end
    table.sort(tiers, function(a, b) return (CHARM_TIER[a.rarity] or 0) > (CHARM_TIER[b.rarity] or 0) end)
    local head = {}
    for _, c in ipairs(tiers) do table.insert(head, c.rarity) end
    local lines = { "<b>Charm restock: " .. escapeHtml(table.concat(head, ", ")) .. "</b>" }
    for _, c in ipairs(cards) do
        local tag = c.bought and " (udah kebeli)" or (charmOn[c.rarity] and " (auto-beli)" or "")
        table.insert(lines, string.format("%d. %s: %s, %s%s", c.i, escapeHtml(c.rarity), escapeHtml(c.name), escapeHtml(c.price), tag))
    end
    if type(s.EndsAt) == "number" then
        table.insert(lines, "Restock lagi jam " .. os.date("%H:%M:%S", s.EndsAt) .. ".")
    end
    notifyTelegram(table.concat(lines, "\n"))
    return "done"
end

-- dipanggil tiap tick (0.5s): minta stok pas startup dan tiap restock lewat
-- (sama kayak yang dilakuin jendela toko game), terus proses sekali per rotasi
local function charmTick()
    -- gak ada yang butuh stok (auto-beli mati + notif mati) = gak usah minta
    if next(charmOn) == nil and next(notifyOn) == nil then return end
    -- tunggu script toko game siap: RemoteEvent cuma ngantri event selama belum
    -- ada listener sama sekali; kalau kita duluan, balesan "Get" pertama cuma
    -- ketangkep kita dan kartu toko gak pernah keisi (autoexec pas join)
    local ps = lp:FindFirstChild("PlayerScripts")
    local cui = ps and ps:FindFirstChild("PunchEscapeCharmsUI")
    if not (cui and cui:GetAttribute("CharmsUIReady") == true) then return end
    local now = workspace:GetServerTimeNow()
    if (not charmShop or now >= (charmShop.EndsAt or 0)) and os.clock() - lastCharmGet > 5 then
        lastCharmGet = os.clock()
        charmRemote:FireServer("Get")
    end
    local s = charmShop
    if s and s.Window ~= charmNotifiedWindow and not charmNotifying and next(notifyOn) ~= nil then
        local w = s.Window
        charmNotifying = true
        task.spawn(function()
            local ok, res = pcall(notifyRestock, w)
            if not ok then warn("[SwordTracker] charm notif: " .. tostring(res)); res = "done" end
            if res == "reread" then charmShop = nil else charmNotifiedWindow = w end
            charmNotifying = false
        end)
    end
    -- auto-beli cuma kalau ada chip "Beli charm" yang nyala
    if s and next(charmOn) ~= nil and s.Window ~= charmHandledWindow and not charmBusy and os.clock() >= charmRetryAt then
        local w = s.Window
        charmBusy = true
        task.spawn(function()
            -- error di tengah jalan jangan ninggalin charmBusy/charmState nyangkut
            local ok, res = pcall(buyWanted, w)
            if not ok then
                warn("[SwordTracker] charm: " .. tostring(res))
                charmState = nil
                res = "done"
            end
            if res == "retry" then
                charmRetryAt = os.clock() + 10
            elseif res == "reread" then
                charmShop = nil -- tick berikutnya minta "Get" lagi (tetep dibatesin 5s)
            else
                charmHandledWindow = w
            end
            charmBusy = false
        end)
    end
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
    Rainbow   = Color3.fromRGB(255, 140, 230), -- tier charm; #FF8CE6, 9.05:1 dua arah
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
        b.TextTruncate = Enum.TextTruncate.AtEnd -- teks langkah bisa panjang
        local bp = Instance.new("UIPadding", b)
        bp.PaddingLeft = UDim.new(0, 8)
        bp.PaddingRight = UDim.new(0, 8)
        b.LayoutOrder = order
        Instance.new("UICorner", b).CornerRadius = RADIUS
        local e = Instance.new("UIStroke", b)
        -- default Contextual di TextButton = ngegaris huruf, bukan pinggir tombol
        e.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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
        if swordPos then
            grabSword(swordPos, target)
        else
            -- teleport manual: keeper AFK diem 90s (kalau nggak, dia langsung
            -- narik balik ke pad), dan keluar pad dulu (duduk = kekunci)
            afkRetryAt = os.clock() + 90
            task.spawn(function()
                exitAFK()
                teleportToWorld(target)
            end)
        end
    end)

    -- grup chip per tier, dua baris (4 + 3) biar muat di 232px dalam card.
    -- Nyala = diisi warna tier-nya + teks gelap, mati = outline redup.
    -- Bedanya bentuk (isi vs garis), bukan cuma warna, biar tetep kebaca
    -- buat buta warna. Warna tier di sini bawa info (tier mana), bukan hiasan.
    -- Dipake dua kali: Notif Telegram dan Ambil otomatis, bahasa visual sama.
    local SWORD_ROWS = { { "Common", "Uncommon", "Rare", "Epic" }, { "Legendary", "Mythic", "???" } }
    local function chipGroup(order, caption, set, file, rows)
        local cap = newLine(c, order, 13, Enum.Font.GothamMedium, TEXT_DIM)
        cap.Text = caption
        rows = rows or SWORD_ROWS
        for i, names in ipairs(rows) do
            local row = Instance.new("Frame", c)
            row.Size = UDim2.new(1, 0, 0, 24)
            row.BackgroundTransparency = 1
            row.LayoutOrder = order + i
            local rowLayout = Instance.new("UIListLayout", row)
            rowLayout.FillDirection = Enum.FillDirection.Horizontal
            rowLayout.Padding = UDim.new(0, 4)
            -- default SortOrder = Name: chip jadi urut abjad (kejadian 2026-09-27)
            rowLayout.SortOrder = Enum.SortOrder.LayoutOrder

            for j, rarity in ipairs(names) do
                local chip = Instance.new("TextButton", row)
                chip.Name = "Chip_" .. rarity
                chip.LayoutOrder = j
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
                chipEdge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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
        return cap
    end
    -- tombol event claim: cuma ada kalau prompt "Attempt to claim" ada di map
    local claimBtn = newButton(7, "")
    claimBtn.Name = "ClaimBtn"
    claimBtn.Visible = false
    claimBtn.MouseButton1Click:Connect(startClaim)

    chipGroup(8, "Notif Telegram:", notifyOn, NOTIFY_FILE)
    chipGroup(11, "Ambil otomatis:", grabOn, GRAB_FILE)
    -- Charm Shop: rarity yang dibeli otomatis pake Crystals tiap restock.
    -- Caption-nya di-update setUI (hitung mundur restock).
    local charmCap = chipGroup(15, "Beli charm (Crystals):", charmOn, CHARM_FILE,
        { { "Rare", "Epic", "Legendary" }, { "Mythic", "Rainbow" } })

    -- mode AFK: di antara ambilan duduk di pad AFK terbaik (bukan auto-win).
    -- Teks tombol = keadaan sekarang, di-update setUI.
    local afkBtn = newButton(14, "")
    afkBtn.Name = "AfkBtn"
    afkBtn.MouseButton1Click:Connect(function()
        afkMode = not afkMode
        afkNote, afkRetryAt = nil, 0
        -- Stop = turun dari pad juga, sama kayak di game (interact lagi / lompat;
        -- lompat nembak AFKExitRequest yang sama)
        if not afkMode then task.spawn(exitAFK) end
        if writefile then pcall(writefile, AFK_FILE, afkMode and "1" or "0") end
    end)

    uiRefs = { status = status, rarity = rarity, me = me, timer = timer, go = goBtn, claim = claimBtn, afk = afkBtn, charmCap = charmCap }
    return gui, c
end

-- Gak di-rebuild tiap respawn: ResetOnSpawn=false udah bikin GUI-nya
-- bertahan, dan rebuild ngereset posisi card yang udah di-drag. setUI
-- tetep bikin ulang kalau GUI-nya beneran ilang.
sg, card = makeGUI()

-- sword = tabel dari getDropState(), nil = lagi Waiting.
-- Tiga keadaan: nunggu (countdown), ada sword, karakter belum spawn.
local function setUI(sword, myWorld, timerText)
    if not card or not card.Parent then sg, card = makeGUI() end
    local r = uiRefs
    if not r.status then return end

    r.me.Text = myWorld and ("Kamu di World " .. myWorld) or "Karakter belum spawn"

    if not afkMode then
        r.afk.Text = "Nyalain AFK di pad terbaik"
    else
        -- toggle: teks nyebut aksi klik-nya ("Stop AFK") + keadaan sekarang,
        -- bukan keadaan doang (user nanya "stopnya gimana", 2026-09-27)
        local detail
        if afkState then
            detail = afkState
        elseif afkNote then
            detail = afkNote
        else
            local w = afkWorld()
            local curMult = w and lp:GetAttribute("CurrentWorld") == w and currentPadMult(w)
            detail = curMult and (fmtMult(curMult) .. ", World " .. w)
                or (w and "nunggu giliran" or "nunggu data player")
        end
        r.afk.Text = "Stop AFK (" .. detail .. ")"
    end

    -- caption Charm Shop: hitung mundur restock (dari EndsAt server)
    if r.charmCap then
        local s = charmShop
        if charmState then
            r.charmCap.Text = charmState
        elseif next(charmOn) == nil then
            r.charmCap.Text = "Beli charm (Crystals):"
        elseif s and type(s.EndsAt) == "number" then
            local left = math.max(0, math.ceil(s.EndsAt - workspace:GetServerTimeNow()))
            r.charmCap.Text = string.format("Beli charm, restock %dm %02ds:", left // 60, left % 60)
        else
            r.charmCap.Text = "Beli charm, baca stok..."
        end
    end

    local ep = eventPrompt
    r.claim.Visible = ep ~= nil and ep.Parent ~= nil
    if r.claim.Visible then
        local what = ep.ObjectText ~= "" and ep.ObjectText or "event"
        r.claim.Text = claimSpam and string.format("Stop claim (%d percobaan)", claimTries)
            or ("Claim " .. what)
    end

    -- tombol aksi: ada yang bisa dilakuin = ada tombol. Posisi sword ketauan
    -- -> "Ambil" (world mana pun); gak ketauan -> cuma "Teleport" ke world
    -- lain. Kekunci = inert, cuma ngasih tau kenapa. Lagi jalan = teks langkah.
    local target = sword and (sword.world ~= myWorld or swordPos) and sword.world or nil
    r.goTarget = target
    r.go.Visible = target ~= nil
    if target then
        local locked = target > (lp:GetAttribute("MaxWorldUnlocked") or 1)
        -- lagi claim event = grabSword nolak; jangan keliatan bisa diklik
        r.go:SetAttribute("Inert", locked or grabState ~= nil or claimSpam)
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
local function logicTick()
    charmTick()
    local sword = getDropState()
    if sword then
        if sword.id ~= lastId then
            lastId = sword.id
            if wants(notifyOn, sword.rarity) then notifySword(sword) end
        end
        -- ambil otomatis: sekali per drop, dan baru pas posisinya udah ada
        -- (Impact bisa telat/duluan sedetik dari attr)
        -- lagi claim event = tunda, drop-nya dicoba begitu claim-nya berhenti
        if swordPos and not claimSpam and grabTriedId ~= sword.id and wants(grabOn, sword.rarity) then
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
    -- mode AFK = di antara ambilan duduk di pad AFK terbaik, bukan auto-win.
    -- Gagal masuk pad = coba lagi 15 detik kemudian (afkRetryAt).
    -- Data player belum ke-load = diem (jangan nganggep 0 rebirth/World 1).
    -- Udah duduk di pad yang multiplier-nya >= pilihan terbaik = diem juga
    -- (mis. pad gamepass yang cek kepemilikannya belum balik).
    if afkMode and not grabState and not claimSpam and not charmState and not afkState and os.clock() > afkRetryAt then
        local w = afkWorld()
        if w then
            local here = lp:GetAttribute("CurrentWorld") == w
            local pad = here and pickPad(w) or nil
            local cur = here and currentPadMult(w) or nil
            if not here or not cur or (pad and cur < pad.mult) then goToPad(w) end
        end
    end

    if not afkMode and next(grabOn) ~= nil and not grabState and not claimSpam and not charmState and lp:GetAttribute("AutoWin") ~= true
        and os.clock() - lastAutoWinReq > 3 then
        lastAutoWinReq = os.clock()
        autoWin:FireServer(true)
    end
    return sword
end

-- Error di Heartbeat gak nge-stop game, tapi sisa tick itu gak jalan: kalau
-- kejadian tiap tick sebelum setUI, card beku diam-diam. Logika dan UI
-- dibungkus terpisah; error-nya ditampilin di baris status + F9 + file.
local lastErr = nil
local function reportErr(where, err)
    local msg = tostring(err)
    if msg == lastErr then return end
    lastErr = msg
    warn("[SwordTracker] " .. where .. ": " .. msg)
    pcall(writefile, "swordtracker_error.txt", os.date("%Y-%m-%d %H:%M:%S ") .. where .. "\n" .. msg)
end

local hbConn
hbConn = RunService.Heartbeat:Connect(function(dt)
    -- ada instance baru yang jalan: yang ini berhenti, GUI-nya udah punya yang baru
    if stale() then hbConn:Disconnect(); return end
    tickAcc += dt
    if tickAcc < 0.5 then return end
    tickAcc = 0

    local okL, swordOrErr = xpcall(logicTick, debug.traceback)
    if not okL then reportErr("logika", swordOrErr) end
    local sword = okL and swordOrErr or getDropState()

    local ok, timerText = pcall(getDropTimerText)
    local okU, errU = xpcall(function() setUI(sword, getMyWorld(), ok and timerText or nil) end, debug.traceback)
    if not okU then reportErr("UI", errU) end
    if (not okL or not okU) and uiRefs.status then
        local firstLine = tostring(lastErr):match("[^\n]*") or "?"
        pcall(function() uiRefs.status.Text = "Error: " .. firstLine:sub(1, 70) end)
    end
end)
-- klaim token terakhir: sekarang instance lama boleh berhenti
genv.SwordTrackerRun = RUN
