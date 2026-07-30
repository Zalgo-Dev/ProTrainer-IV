-- ProTrainer (GTA IV) - menu "PRO TRAINER"
-- Recreation en Lua du menu de Simple Trainer (trainer.ini de la v6.5),
-- adaptee aux natives realistement disponibles sur ce loader -- voir
-- docs/LUA_API.md du depot TrainerInjector pour le detail de l'API (natives
-- typees/comptees/brutes, draw_text, is_key_down, set_menu_open...).
--
-- F4 ouvre/ferme le menu, Echap le referme aussi.
-- Haut/Bas    : deplace la selection dans l'onglet courant.
-- Gauche/Droite : change d'onglet (categorie).
-- , / .       : fait defiler les choix d'un item "liste" (arme, vehicule,
--               skin, meteo, niveau de recherche...) sans encore l'appliquer.
-- Entree      : active/desactive un item ON/OFF, declenche une action, ou
--               applique le choix actuellement affiche d'un item "liste".

local VK_F4     = 0x73
local VK_ESCAPE = 0x1B
local VK_UP     = 0x26
local VK_DOWN   = 0x28
local VK_LEFT   = 0x25
local VK_RIGHT  = 0x27
local VK_RETURN = 0x0D
local VK_COMMA  = 0xBC
local VK_PERIOD = 0xBE

-- eWeapon, docs/reference/ScriptEnums.h.
local WEAPON_KNIFE       = 3
local WEAPON_GRENADE     = 4
local WEAPON_MOLOTOV     = 5
local WEAPON_PISTOL      = 7
local WEAPON_DEAGLE      = 9
local WEAPON_SHOTGUN     = 10
local WEAPON_MICRO_UZI   = 12
local WEAPON_MP5         = 13
local WEAPON_AK47        = 14
local WEAPON_M4          = 15
local WEAPON_SNIPERRIFLE = 16
local WEAPON_M40A1       = 17
local WEAPON_RLAUNCHER   = 18
local WEAPON_FTHROWER    = 19
local WEAPON_MINIGUN     = 20

-- Hashes de modeles, docs/reference/ScriptEnums.h (vehicules + peds + Niko).
local IG_NIKO                 = 0x6032264F
local MODEL_M_Y_BUSINESS_01   = 0x5B404032
local MODEL_F_Y_BUSINESS_01   = 0x1B0DCC86
local MODEL_M_Y_COP           = 0xF5148AB2
local MODEL_M_Y_STREETPUNK_04 = 0x8D1CBD36
local MODEL_INFERNUS    = 0x18F25AC7
local MODEL_TURISMO     = 0x8EF34547
local MODEL_COMET       = 0x3F637729
local MODEL_BANSHEE     = 0xC1E908D2
local MODEL_SULTAN      = 0x39DA2754
local MODEL_POLICE      = 0x79FBB0C5
local MODEL_NRG900      = 0x47B9138A
local MODEL_ANNIHILATOR = 0x31F0B376

-- Notification a l'ecran (overlay GDI via draw_text), pas de msgbox() : une
-- vraie popup Windows vole le focus et peut faire perdre le device D3D en
-- plein ecran exclusif (voir docs/KNOWN_ISSUES.md du depot TrainerInjector).
local notification = nil
local NOTIFICATION_DURATION = 3.0

local function showNotification(text)
    notification = { text = text, expiresAt = os.clock() + NOTIFICATION_DURATION }
end

local function drawNotification()
    if not notification then return end
    if os.clock() > notification.expiresAt then
        notification = nil
        return
    end
    draw_text(40, 280, notification.text, 0xFF33FFFF)
end

-- Point de passage unique pour recuperer le Ped du joueur local -- toutes
-- les features qui en ont besoin passent par ici. GET_PLAYER_ID/
-- GET_PLAYER_CHAR sont deux natives typees, chacune avec une seule sortie
-- par pointeur -> l'appel direct renvoie deja la valeur decodee.
local function getPlayerPed()
    local playerId = GET_PLAYER_ID()
    if not playerId then return nil end
    return GET_PLAYER_CHAR(playerId)
end

-- CREATE_CAR/CHANGE_PLAYER_MODEL (et toute native qui instancie un modele)
-- plantent si le modele n'est pas deja streame en memoire -- il faut le
-- demander puis attendre qu'il soit charge avant de creer quoi que ce soit
-- avec (comportement standard des scripts GTA, pas specifique a ce loader).
--
-- Important : cette attente NE DOIT PAS bloquer dans une boucle synchrone.
-- onTick() (et donc tout ce qu'il appelle, y compris une action de menu)
-- s'execute entierement a l'interieur d'un seul appel depuis le hook
-- EndScene -- une boucle qui tourne jusqu'a ce que HAS_MODEL_LOADED devienne
-- vrai bloque donc le jeu entier (plus aucune frame ne se termine) pendant
-- toute sa duree. Le streaming de modele (lecture disque, decompression)
-- s'etale probablement sur plusieurs frames du jeu -- le bloquer ainsi
-- l'empeche justement de progresser, ce qui faisait echouer le chargement a
-- coup sur (timeout systematique, voir docs/KNOWN_ISSUES.md du depot
-- TrainerInjector). La demande est donc suivie sur plusieurs appels de
-- onTick (un seul test HAS_MODEL_LOADED par frame) plutot qu'en boucle.
local pendingModelRequest = nil -- { modelHash, deadline, kind, info }

local function beginModelRequest(modelHash, kind, info)
    if HAS_MODEL_LOADED(modelHash) then return true end
    REQUEST_MODEL(modelHash)
    pendingModelRequest = { modelHash = modelHash, deadline = os.clock() + 5.0, kind = kind, info = info }
    showNotification("Chargement du modele...")
    return false
end

--------------------------------------------------------------------------
-- Etat des features (lu/ecrit par les items de menu, applique en continu
-- depuis onTick pour les toggles -- voir applyContinuousFeatures plus bas).
--------------------------------------------------------------------------

local godModeEnabled = false
local armourEnabled = false
local invincibleEnabled = false
local neverWantedEnabled = false
local infiniteAmmoEnabled = false
local carInvincibleEnabled = false
local fastRunMultiplier = 1.0

local savedPositions = { nil, nil, nil }

local weaponLoadout = {
    { name = "Couteau",              value = WEAPON_KNIFE,       ammo = 1 },
    { name = "Grenades",             value = WEAPON_GRENADE,     ammo = 20 },
    { name = "Molotov",              value = WEAPON_MOLOTOV,     ammo = 20 },
    { name = "Pistolet",             value = WEAPON_PISTOL,      ammo = 250 },
    { name = "Desert Eagle",         value = WEAPON_DEAGLE,      ammo = 250 },
    { name = "Fusil a pompe",        value = WEAPON_SHOTGUN,     ammo = 250 },
    { name = "Micro Uzi",            value = WEAPON_MICRO_UZI,   ammo = 500 },
    { name = "MP5",                  value = WEAPON_MP5,         ammo = 500 },
    { name = "AK-47",                value = WEAPON_AK47,        ammo = 500 },
    { name = "M4",                   value = WEAPON_M4,          ammo = 500 },
    { name = "Fusil de precision",   value = WEAPON_SNIPERRIFLE, ammo = 50 },
    { name = "M40A1",                value = WEAPON_M40A1,       ammo = 50 },
    { name = "Lance-roquettes",      value = WEAPON_RLAUNCHER,   ammo = 20 },
    { name = "Lance-flammes",        value = WEAPON_FTHROWER,    ammo = 200 },
    { name = "Minigun",              value = WEAPON_MINIGUN,     ammo = 1000 },
}

local function giveAllWeapons()
    local ped = getPlayerPed()
    if not ped then
        showNotification("Ped introuvable")
        return
    end
    for _, w in ipairs(weaponLoadout) do
        -- GIVE_WEAPON_TO_CHAR(Ped, eWeapon, Ammo, bool equiper) -- typee,
        -- 4 entrees, aucune sortie -> l'appel renvoie juste `true`.
        GIVE_WEAPON_TO_CHAR(ped, w.value, w.ammo, true)
    end
    showNotification("Toutes les armes donnees")
end

local function repairCurrentVehicle()
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    local car = GET_CAR_CHAR_IS_USING(ped)
    if not car or car == 0 then showNotification("Pas dans un vehicule"); return end
    FIX_CAR(car)
    -- SET_CAR_HEALTH n'est couverte par aucune des trois sources de types
    -- (native brute, native_info("SET_CAR_HEALTH") renvoie nil) -- meme
    -- appel direct, juste pas de decodage automatique du resultat.
    call_native("SET_CAR_HEALTH", car, 1000)
    showNotification("Vehicule repare")
end

local function flipCurrentVehicle()
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    local car = GET_CAR_CHAR_IS_USING(ped)
    if not car or car == 0 then showNotification("Pas dans un vehicule"); return end
    SET_CAR_ON_GROUND_PROPERLY(car)
    showNotification("Vehicule remis sur ses roues")
end

local function boostCurrentVehicle()
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    local car = GET_CAR_CHAR_IS_USING(ped)
    if not car or car == 0 then showNotification("Pas dans un vehicule"); return end
    SET_CAR_FORWARD_SPEED(car, 100.0)
    showNotification("Boost applique")
end

local function explodeCurrentVehicle()
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    local car = GET_CAR_CHAR_IS_USING(ped)
    if not car or car == 0 then showNotification("Pas dans un vehicule"); return end
    EXPLODE_CAR(car)
    showNotification("Vehicule detruit")
end

local function deleteCurrentVehicle()
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    local car = GET_CAR_CHAR_IS_USING(ped)
    if not car or car == 0 then showNotification("Pas dans un vehicule"); return end
    -- Ne jamais DELETE_CAR un vehicule que le ped occupe encore : le jeu garde
    -- une reference "vehicule courant" sur le ped vers l'objet qu'on vient de
    -- liberer, dereferencee au tick suivant -> crash. On ejecte le joueur au
    -- meme endroit d'abord (meme schema que MARK_MODEL_AS_NO_LONGER_NEEDED
    -- apres CREATE_CAR/CHANGE_PLAYER_MODEL plus haut).
    local x, y, z = GET_CAR_COORDINATES(car)
    WARP_CHAR_FROM_CAR_TO_COORD(ped, x, y, z)
    MARK_CAR_AS_NO_LONGER_NEEDED(car)
    DELETE_CAR(car)
    showNotification("Vehicule supprime")
end

local vehicleLocked = false

local function toggleLockCurrentVehicle(locked)
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    local car = GET_CAR_CHAR_IS_USING(ped)
    if not car or car == 0 then showNotification("Pas dans un vehicule"); return end
    LOCK_CAR_DOORS(car, locked and 2 or 1)
    showNotification(locked and "Portes verrouillees" or "Portes deverrouillees")
end

local vehicleSpawnList = {
    { name = "Infernus",             value = MODEL_INFERNUS },
    { name = "Turismo",              value = MODEL_TURISMO },
    { name = "Comet",                value = MODEL_COMET },
    { name = "Banshee",              value = MODEL_BANSHEE },
    { name = "Sultan",               value = MODEL_SULTAN },
    { name = "Police",               value = MODEL_POLICE },
    { name = "NRG-900 (moto)",       value = MODEL_NRG900 },
    { name = "Annihilator (helico)", value = MODEL_ANNIHILATOR },
}

local function finishVehicleSpawn(modelHash, info)
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    -- 5 unites devant le joueur en coordonnees locales -> coordonnees monde.
    local x, y, z = GET_OFFSET_FROM_CHAR_IN_WORLD_COORDS(ped, 0.0, 5.0, 0.0)
    local car = CREATE_CAR(modelHash, x, y, z, true)
    MARK_MODEL_AS_NO_LONGER_NEEDED(modelHash)
    if not car or car == 0 then showNotification("Echec de la creation du vehicule"); return end
    WARP_CHAR_INTO_CAR(ped, car)
    showNotification((info and info.name or "Vehicule") .. " genere")
end

local function spawnVehicle(modelHash, info)
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    if beginModelRequest(modelHash, "vehicle", info) then
        finishVehicleSpawn(modelHash, info)
    end
end

local skinList = {
    { name = "Niko (par defaut)",  value = IG_NIKO },
    { name = "Homme d'affaires",   value = MODEL_M_Y_BUSINESS_01 },
    { name = "Femme d'affaires",   value = MODEL_F_Y_BUSINESS_01 },
    { name = "Policier",           value = MODEL_M_Y_COP },
    { name = "Voyou",              value = MODEL_M_Y_STREETPUNK_04 },
}

local function finishApplySkin(modelHash)
    local playerId = GET_PLAYER_ID()
    if not playerId then showNotification("Joueur introuvable"); return end
    CHANGE_PLAYER_MODEL(playerId, modelHash)
    MARK_MODEL_AS_NO_LONGER_NEEDED(modelHash)
    showNotification("Skin change")
end

local function applySkin(modelHash)
    local playerId = GET_PLAYER_ID()
    if not playerId then showNotification("Joueur introuvable"); return end
    if beginModelRequest(modelHash, "skin", nil) then
        finishApplySkin(modelHash)
    end
end

local wantedLevelList = {
    { name = "0 (aucun)", value = 0 },
    { name = "1", value = 1 },
    { name = "2", value = 2 },
    { name = "3", value = 3 },
    { name = "4", value = 4 },
    { name = "5", value = 5 },
    { name = "6 (max)", value = 6 },
}

local function applyWantedLevel(level)
    local playerId = GET_PLAYER_ID()
    if not playerId then showNotification("Joueur introuvable"); return end
    SET_MAX_WANTED_LEVEL(math.max(level, 6))
    ALTER_WANTED_LEVEL(playerId, level)
    APPLY_WANTED_LEVEL_CHANGE_NOW(playerId)
    showNotification("Niveau de recherche : " .. level)
end

local fastRunList = {
    { name = "Normal",     value = 1.0 },
    { name = "Rapide",     value = 1.5 },
    { name = "Tres rapide", value = 2.0 },
    { name = "Extreme",    value = 3.0 },
}

local weatherList = {
    { name = "Grand soleil",     value = 0 },
    { name = "Ensoleille",       value = 1 },
    { name = "Ensoleille venteux", value = 2 },
    { name = "Nuageux",          value = 3 },
    { name = "Pluie",            value = 4 },
    { name = "Bruine",           value = 5 },
    { name = "Brouillard",       value = 6 },
    { name = "Orage",            value = 7 },
    { name = "Grand soleil (2)", value = 8 },
    { name = "Ensoleille venteux (2)", value = 9 },
}

local function applyWeather(index)
    FORCE_WEATHER(index)
    showNotification("Meteo changee")
end

local function savePosition(slot)
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    local x, y, z = GET_CHAR_COORDINATES(ped)
    savedPositions[slot] = { x = x, y = y, z = z }
    showNotification("Position " .. slot .. " sauvegardee")
end

local function teleportToPosition(slot)
    local pos = savedPositions[slot]
    if not pos then showNotification("Position " .. slot .. " vide"); return end
    local ped = getPlayerPed()
    if not ped then showNotification("Ped introuvable"); return end
    SET_CHAR_COORDINATES(ped, pos.x, pos.y, pos.z)
    showNotification("Teleporte a la position " .. slot)
end

--------------------------------------------------------------------------
-- Definition du menu : chaque onglet est une liste d'items de 3 sortes --
-- "toggle" (ON/OFF), "action" (declenchement instantane) ou "list" (choix
-- parmi plusieurs valeurs, defile avec , / . puis applique avec Entree).
--------------------------------------------------------------------------

local tabs = {
    {
        name = "JOUEUR",
        items = {
            {
                kind = "toggle", label = "Sante infinie",
                get = function() return godModeEnabled end,
                set = function(v) godModeEnabled = v end,
            },
            {
                kind = "toggle", label = "Armure infinie",
                get = function() return armourEnabled end,
                set = function(v) armourEnabled = v end,
            },
            {
                kind = "toggle", label = "Invincibilite",
                get = function() return invincibleEnabled end,
                set = function(v) invincibleEnabled = v end,
            },
            {
                kind = "toggle", label = "Ne jamais etre recherche",
                get = function() return neverWantedEnabled end,
                set = function(v) neverWantedEnabled = v end,
                onToggle = function(v) if not v then SET_MAX_WANTED_LEVEL(6) end end,
            },
            {
                kind = "action", label = "Effacer le niveau de recherche",
                run = function()
                    local playerId = GET_PLAYER_ID()
                    if playerId then CLEAR_WANTED_LEVEL(playerId) end
                    showNotification("Niveau de recherche efface")
                end,
            },
            {
                kind = "list", label = "Forcer le niveau de recherche",
                options = wantedLevelList, pendingIndex = 1,
                apply = function(value) applyWantedLevel(value) end,
            },
            {
                kind = "list", label = "Vitesse de course",
                options = fastRunList, pendingIndex = 1,
                apply = function(value) fastRunMultiplier = value; showNotification("Vitesse de course : " .. value .. "x") end,
            },
            {
                kind = "list", label = "Changer de skin",
                options = skinList, pendingIndex = 1,
                apply = function(value) applySkin(value) end,
            },
        },
    },
    {
        name = "ARMES",
        items = {
            {
                kind = "action", label = "Donner toutes les armes",
                run = giveAllWeapons,
            },
            {
                kind = "list", label = "Donner une arme",
                options = weaponLoadout, pendingIndex = 1,
                apply = function(value, opt)
                    local ped = getPlayerPed()
                    if not ped then showNotification("Ped introuvable"); return end
                    GIVE_WEAPON_TO_CHAR(ped, value, opt.ammo, true)
                    showNotification("Arme donnee : " .. opt.name)
                end,
            },
            {
                kind = "toggle", label = "Munitions infinies",
                get = function() return infiniteAmmoEnabled end,
                set = function(v) infiniteAmmoEnabled = v end,
            },
        },
    },
    {
        name = "VEHICULE",
        items = {
            { kind = "action", label = "Reparer le vehicule", run = repairCurrentVehicle },
            {
                kind = "toggle", label = "Vehicule increvable",
                get = function() return carInvincibleEnabled end,
                set = function(v) carInvincibleEnabled = v end,
            },
            {
                kind = "toggle", label = "Verrouiller les portes",
                get = function() return vehicleLocked end,
                set = function(v) vehicleLocked = v end,
                onToggle = function(v) toggleLockCurrentVehicle(v) end,
            },
            { kind = "action", label = "Remettre sur ses roues", run = flipCurrentVehicle },
            { kind = "action", label = "Boost de vitesse", run = boostCurrentVehicle },
            { kind = "action", label = "Exploser le vehicule", run = explodeCurrentVehicle },
            { kind = "action", label = "Supprimer le vehicule", run = deleteCurrentVehicle },
            {
                kind = "list", label = "Faire apparaitre un vehicule",
                options = vehicleSpawnList, pendingIndex = 1,
                apply = function(value, opt) spawnVehicle(value, opt) end,
            },
        },
    },
    {
        name = "TELEPORT",
        items = {
            { kind = "action", label = "Sauvegarder position 1", run = function() savePosition(1) end },
            { kind = "action", label = "Teleporter position 1", run = function() teleportToPosition(1) end },
            { kind = "action", label = "Sauvegarder position 2", run = function() savePosition(2) end },
            { kind = "action", label = "Teleporter position 2", run = function() teleportToPosition(2) end },
            { kind = "action", label = "Sauvegarder position 3", run = function() savePosition(3) end },
            { kind = "action", label = "Teleporter position 3", run = function() teleportToPosition(3) end },
        },
    },
    {
        name = "MONDE",
        items = {
            {
                kind = "list", label = "Meteo",
                options = weatherList, pendingIndex = 1,
                apply = function(value) applyWeather(value) end,
            },
        },
    },
}

--------------------------------------------------------------------------
-- Moteur du menu (navigation, dessin) -- generique, ne connait rien des
-- features elles-memes, uniquement des 3 "kind" d'item ci-dessus.
--------------------------------------------------------------------------

local menuOpen = false
local selectedTab = 1
local selectedItem = {}
for i = 1, #tabs do selectedItem[i] = 1 end

local wasF4, wasEsc, wasUp, wasDown, wasLeft, wasRight, wasEnter, wasComma, wasPeriod =
    false, false, false, false, false, false, false, false, false

-- Point de passage unique pour changer l'etat du menu : previent le loader
-- via set_menu_open() a CHAQUE changement (voir docs/LUA_API.md).
local function setMenuOpen(open)
    menuOpen = open
    set_menu_open(menuOpen)
end

local function currentItems()
    return tabs[selectedTab].items
end

local function activateSelectedItem()
    local item = currentItems()[selectedItem[selectedTab]]
    if not item then return end
    if item.kind == "toggle" then
        local newVal = not item.get()
        item.set(newVal)
        if item.onToggle then item.onToggle(newVal) end
    elseif item.kind == "action" then
        item.run()
    elseif item.kind == "list" then
        local opt = item.options[item.pendingIndex]
        item.apply(opt.value, opt)
        item.appliedIndex = item.pendingIndex
    end
end

local function cycleSelectedList(direction)
    local item = currentItems()[selectedItem[selectedTab]]
    if not item or item.kind ~= "list" then return end
    local n = #item.options
    item.pendingIndex = ((item.pendingIndex - 1 + direction) % n) + 1
end

local function handleInput()
    local f4Down = is_key_down(VK_F4)
    if f4Down and not wasF4 then setMenuOpen(not menuOpen) end
    wasF4 = f4Down

    if not menuOpen then return end

    local escDown = is_key_down(VK_ESCAPE)
    if escDown and not wasEsc then setMenuOpen(false) end
    wasEsc = escDown

    local upDown = is_key_down(VK_UP)
    if upDown and not wasUp then
        local n = #currentItems()
        selectedItem[selectedTab] = selectedItem[selectedTab] - 1
        if selectedItem[selectedTab] < 1 then selectedItem[selectedTab] = n end
    end
    wasUp = upDown

    local downDown = is_key_down(VK_DOWN)
    if downDown and not wasDown then
        local n = #currentItems()
        selectedItem[selectedTab] = selectedItem[selectedTab] + 1
        if selectedItem[selectedTab] > n then selectedItem[selectedTab] = 1 end
    end
    wasDown = downDown

    local leftDown = is_key_down(VK_LEFT)
    if leftDown and not wasLeft then
        selectedTab = selectedTab - 1
        if selectedTab < 1 then selectedTab = #tabs end
    end
    wasLeft = leftDown

    local rightDown = is_key_down(VK_RIGHT)
    if rightDown and not wasRight then
        selectedTab = selectedTab + 1
        if selectedTab > #tabs then selectedTab = 1 end
    end
    wasRight = rightDown

    local commaDown = is_key_down(VK_COMMA)
    if commaDown and not wasComma then cycleSelectedList(-1) end
    wasComma = commaDown

    local periodDown = is_key_down(VK_PERIOD)
    if periodDown and not wasPeriod then cycleSelectedList(1) end
    wasPeriod = periodDown

    local enterDown = is_key_down(VK_RETURN)
    if enterDown and not wasEnter then activateSelectedItem() end
    wasEnter = enterDown
end

local function itemLabel(item)
    if item.kind == "toggle" then
        return item.label .. "  [" .. (item.get() and "ON" or "OFF") .. "]"
    elseif item.kind == "action" then
        return item.label
    elseif item.kind == "list" then
        local opt = item.options[item.pendingIndex]
        local suffix = (item.appliedIndex == item.pendingIndex) and "  (actif)" or "  (Entree)"
        return item.label .. " : " .. opt.name .. suffix
    end
    return item.label
end

local function drawMenu()
    if not menuOpen then return end

    draw_text(40, 40, "== PRO TRAINER ==", 0xFFFF3333)

    local tabLine = ""
    for i, tab in ipairs(tabs) do
        if i == selectedTab then
            tabLine = tabLine .. "[ " .. tab.name .. " ]  "
        else
            tabLine = tabLine .. "  " .. tab.name .. "    "
        end
    end
    draw_text(40, 62, tabLine, 0xFF33FFFF)

    for i, item in ipairs(currentItems()) do
        local isSelected = (i == selectedItem[selectedTab])
        local prefix = isSelected and "> " or "  "
        local color = isSelected and 0xFFFFFF33 or 0xFFFFFFFF
        draw_text(40, 62 + i * 18, prefix .. itemLabel(item), color)
    end
end

--------------------------------------------------------------------------
-- Application en continu des toggles (rappelee chaque frame -- l'etat OFF
-- doit lui aussi etre reaffirme, sinon desactiver une option ne desactive
-- rien cote jeu tant que rien d'autre ne touche ce flag).
--------------------------------------------------------------------------

local function applyContinuousFeatures()
    local ped = getPlayerPed()
    if ped then
        if godModeEnabled then
            SET_CHAR_HEALTH(ped, 200.0)
        end

        if armourEnabled then
            local current = GET_CHAR_ARMOUR(ped)
            if current and current < 100 then
                ADD_ARMOUR_TO_CHAR(ped, 100 - current)
            end
        end

        SET_CHAR_INVINCIBLE(ped, invincibleEnabled)

        if fastRunMultiplier ~= 1.0 then
            SET_CHAR_MOVE_ANIM_SPEED_MULTIPLIER(ped, fastRunMultiplier)
        end

        if infiniteAmmoEnabled then
            for _, w in ipairs(weaponLoadout) do
                GIVE_WEAPON_TO_CHAR(ped, w.value, w.ammo, false)
            end
        end

        if carInvincibleEnabled then
            local car = GET_CAR_CHAR_IS_USING(ped)
            if car and car ~= 0 then
                SET_CAR_STRONG(car, true)
            end
        end
    end

    if neverWantedEnabled then
        local playerId = GET_PLAYER_ID()
        if playerId then
            CLEAR_WANTED_LEVEL(playerId)
            SET_MAX_WANTED_LEVEL(0)
        end
    end
end

-- Suivi non bloquant de pendingModelRequest (voir beginModelRequest plus
-- haut) : un seul test HAS_MODEL_LOADED par frame, jamais de boucle qui
-- attend sur place.
local function updatePendingModelRequest()
    local req = pendingModelRequest
    if not req then return end
    if HAS_MODEL_LOADED(req.modelHash) then
        pendingModelRequest = nil
        if req.kind == "vehicle" then
            finishVehicleSpawn(req.modelHash, req.info)
        elseif req.kind == "skin" then
            finishApplySkin(req.modelHash)
        end
    elseif os.clock() > req.deadline then
        pendingModelRequest = nil
        showNotification("Echec du chargement du modele")
    end
end

-- Appele une fois par frame par le loader (voir lua_engine.cpp::TickLuaFrame
-- dans le depot TrainerInjector).
function onTick()
    handleInput()
    drawMenu()
    drawNotification()
    applyContinuousFeatures()
    updatePendingModelRequest()
end

log("main.lua charge, Lua version: " .. _VERSION)
log("ProTrainer pret. Appuyez sur F4 en jeu pour ouvrir le menu.")
