local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

-- WoW's internal CLICK binding is used instead of Bindings.xml.
-- This keeps the configurable key fully self-contained and avoids
-- XML binding schema differences on WoW Forever/Camelot.
local BUTTON_NAME = "ForeverFarmRouteGathering_ToggleKeyButton"
local CLICK_COMMAND = "CLICK " .. BUTTON_NAME .. ":LeftButton"

local function CreateBindingButton()
    if _G[BUTTON_NAME] then
        NS.ToggleKeyButton = _G[BUTTON_NAME]
        return NS.ToggleKeyButton
    end

    local button = CreateFrame("Button", BUTTON_NAME, UIParent)
    button:SetSize(1, 1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    button:SetAlpha(0)
    button:EnableMouse(false)
    if button.RegisterForClicks then
        button:RegisterForClicks("LeftButtonUp")
    end
    button:SetScript("OnClick", function()
        if NS and NS.ToggleHUD and not NS._capturingRememberNodeKey and not NS._capturingMinimapKey then
            NS:ToggleHUD()
        end
    end)
    button:Show()

    NS.ToggleKeyButton = button
    return button
end

local function IsModifierKey(key)
    return key == "LSHIFT" or key == "RSHIFT"
        or key == "LCTRL" or key == "RCTRL"
        or key == "LALT" or key == "RALT"
end

local function BuildKey(key)
    if not key or key == "" or IsModifierKey(key) then return nil end

    local parts = {}
    if IsControlKeyDown and IsControlKeyDown() then parts[#parts + 1] = "CTRL" end
    if IsAltKeyDown and IsAltKeyDown() then parts[#parts + 1] = "ALT" end
    if IsShiftKeyDown and IsShiftKeyDown() then parts[#parts + 1] = "SHIFT" end
    parts[#parts + 1] = key
    return table.concat(parts, "-")
end

local function ClearBindingCommand(command)
    if not GetBindingKey or not SetBinding then return end
    local k1, k2 = GetBindingKey(command)
    if k1 then SetBinding(k1) end
    if k2 and k2 ~= k1 then SetBinding(k2) end
end

local function ApplyClickBinding(key)
    if not key or key == "" then return false end
    CreateBindingButton()

    -- Prefer the dedicated API when the client provides it.
    if SetBindingClick then
        local ok = SetBindingClick(key, BUTTON_NAME, "LeftButton")
        if ok == false then return false end
        return true
    end

    if SetBinding then
        local ok = SetBinding(key, CLICK_COMMAND)
        if ok == false then return false end
        return true
    end

    return false
end

local function SaveCurrentBindings()
    if not SaveBindings or not GetCurrentBindingSet then return end

    -- A new character can report the default set (0) during the intro.
    -- SaveBindings accepts only account (1) or character (2) bindings.
    -- Keep the live binding and addon preference without choosing a new scope.
    local bindingSet = GetCurrentBindingSet()
    if bindingSet == 1 or bindingSet == 2 then
        SaveBindings(bindingSet)
    end
end

function NS:GetToggleKeyDisplay()
    local key = self.db and self.db.toggleKey
    if not key or key == "" then
        return (self.L and self.L.KEYBIND_NONE) or "Not bound"
    end

    if GetBindingText then
        local text = GetBindingText(key, "KEY_")
        if text and text ~= "" then
            return text
        end
    end
    return key
end

function NS:RefreshKeybindUI()
    local button = self.OptionsPanel
        and self.OptionsPanel.pages
        and self.OptionsPanel.pages.controls
        and self.OptionsPanel.pages.controls.keyButton

    if button and not self._capturingToggleKey then
        button:SetText(self:GetToggleKeyDisplay())
    end
end

function NS:SetToggleKey(key, silent)
    if InCombatLockdown and InCombatLockdown() then
        if not silent and self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return false
    end
    if not self.db then return false end

    if key and key ~= "" and (key == self.db.dismissKey or key == self.db.pauseKey or key == self.db.minimapKey or key == self.db.rememberNodeKey) then
        self.Print("That key is already assigned to the other addon action.")
        return false
    end

    -- Remove the previous internal CLICK binding before assigning a new key.
    ClearBindingCommand(CLICK_COMMAND)

    if key and key ~= "" then
        if not ApplyClickBinding(key) then
            return false
        end
        self.db.toggleKey = key
    else
        self.db.toggleKey = nil
    end

    SaveCurrentBindings()

    self:RefreshKeybindUI()

    if not silent and self.L then
        if self.db.toggleKey then
            self.Print(string.format(self.L.KEYBIND_SAVED, self:GetToggleKeyDisplay()))
        else
            self.Print(self.L.KEYBIND_CLEARED)
        end
    end

    return true
end

function NS:ClearToggleKeybind()
    return self:SetToggleKey(nil, true)
end

function NS:CancelToggleKeyCapture(button)
    if not self._capturingToggleKey then return end
    self._capturingToggleKey = nil
    if button then
        button:SetScript("OnKeyDown", nil)
        if button.EnableKeyboard then button:EnableKeyboard(false) end
        if button.SetPropagateKeyboardInput then button:SetPropagateKeyboardInput(true) end
    end
    self:RefreshKeybindUI()
end

function NS:BeginToggleKeyCapture(button)
    if self.CancelRememberNodeKeyCapture then self:CancelRememberNodeKeyCapture(self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls and self.OptionsPanel.pages.controls.rememberNodeKeyButton) end
    local mini=self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls
    if mini and self.CancelMinimapKeyCapture then self:CancelMinimapKeyCapture(mini.minimapKeyButton) end
    if not button then return end

    if InCombatLockdown and InCombatLockdown() then
        if self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return
    end

    local controls = self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls
    if controls then
        self:CancelDismissKeyCapture(controls.dismissKeyButton)
        if self.CancelPauseKeyCapture then self:CancelPauseKeyCapture(controls.pauseKeyButton) end
    end

    self._capturingToggleKey = true
    button:SetText((self.L and self.L.KEYBIND_SET) or "Press a key ...")

    if button.EnableKeyboard then
        button:EnableKeyboard(true)
    end
    if button.SetPropagateKeyboardInput then
        button:SetPropagateKeyboardInput(false)
    end

    button:SetScript("OnKeyDown", function(btn, key)
        if key == "ESCAPE" then
            NS:CancelToggleKeyCapture(btn)
            return
        end

        if key == "BACKSPACE" or key == "DELETE" then
            NS:CancelToggleKeyCapture(btn)
            NS:SetToggleKey(nil)
            return
        end

        local binding = BuildKey(key)
        if not binding then return end

        NS:CancelToggleKeyCapture(btn)
        NS:SetToggleKey(binding)
    end)
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    if not NS.db then return end

    CreateBindingButton()

    -- Always rebuild the live binding from the addon's SavedVariables so
    -- /reload and client restarts behave identically.
    ClearBindingCommand(CLICK_COMMAND)

    if NS.db.toggleKey and NS.db.toggleKey ~= "" then
        ApplyClickBinding(NS.db.toggleKey)
    end

    SaveCurrentBindings()

    NS:RefreshKeybindUI()
end)

-- Independent mouse-pointer dismissal binding.
do
local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

-- WoW's internal CLICK binding is used instead of Bindings.xml.
-- This keeps the configurable key fully self-contained and avoids
-- XML binding schema differences on WoW Forever/Camelot.
local BUTTON_NAME = "ForeverFarmRouteGathering_DismissKeyButton"
local CLICK_COMMAND = "CLICK " .. BUTTON_NAME .. ":LeftButton"

local function CreateBindingButton()
    if _G[BUTTON_NAME] then
        NS.DismissKeyButton = _G[BUTTON_NAME]
        return NS.DismissKeyButton
    end

    local button = CreateFrame("Button", BUTTON_NAME, UIParent)
    button:SetSize(1, 1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    button:SetAlpha(0)
    button:EnableMouse(false)
    if button.RegisterForClicks then
        button:RegisterForClicks("LeftButtonUp")
    end
    button:SetScript("OnClick", function()
        if NS and NS.DismissRememberedNodeAtCursor and not NS._capturingRememberNodeKey and not NS._capturingMinimapKey then
            NS:RunDismissKeyAction()
        end
    end)
    button:Show()

    NS.DismissKeyButton = button
    return button
end

-- A mouse-enabled normal minimap consumes mouse clicks before global CLICK
-- bindings. Route only the configured chord through a non-replacing hook.
function NS:RunDismissKeyAction()
    local now = GetTime and GetTime()
    if now and self._lastDismissKeyAction and now-self._lastDismissKeyAction < 0.1 then return false end
    if now then self._lastDismissKeyAction = now end
    if self.DismissRememberedNodeAtCursor then return self:DismissRememberedNodeAtCursor() end
    return false
end

function NS:HandleDismissMinimapMouseUp(mouse)
    local keys = {LeftButton="BUTTON1", RightButton="BUTTON2", MiddleButton="BUTTON3", Button4="BUTTON4", Button5="BUTTON5"}
    local key = keys[mouse]
    if not key or not self.db or not self.db.dismissKey or self._capturingDismissKey then return false end
    local parts = {}
    if IsControlKeyDown and IsControlKeyDown() then parts[#parts+1]="CTRL" end
    if IsAltKeyDown and IsAltKeyDown() then parts[#parts+1]="ALT" end
    if IsShiftKeyDown and IsShiftKeyDown() then parts[#parts+1]="SHIFT" end
    parts[#parts+1]=key
    local chord=table.concat(parts,"-")
    if chord ~= self.db.dismissKey then return false end
    if GetBindingAction and GetBindingAction(chord) ~= CLICK_COMMAND then return false end
    return self:RunDismissKeyAction()
end

local minimapDismissHooked
local function HookDismissMinimap()
    if not minimapDismissHooked and Minimap and Minimap.HookScript then
        Minimap:HookScript("OnMouseUp",function(_,mouse) NS:HandleDismissMinimapMouseUp(mouse) end)
        minimapDismissHooked=true
    end
end

local function IsModifierKey(key)
    return key == "LSHIFT" or key == "RSHIFT"
        or key == "LCTRL" or key == "RCTRL"
        or key == "LALT" or key == "RALT"
end

local function BuildKey(key)
    if not key or key == "" or IsModifierKey(key) then return nil end

    local parts = {}
    if IsControlKeyDown and IsControlKeyDown() then parts[#parts + 1] = "CTRL" end
    if IsAltKeyDown and IsAltKeyDown() then parts[#parts + 1] = "ALT" end
    if IsShiftKeyDown and IsShiftKeyDown() then parts[#parts + 1] = "SHIFT" end
    parts[#parts + 1] = key
    return table.concat(parts, "-")
end

local function ClearBindingCommand(command)
    if not GetBindingKey or not SetBinding then return end
    local k1, k2 = GetBindingKey(command)
    if k1 then SetBinding(k1) end
    if k2 and k2 ~= k1 then SetBinding(k2) end
end

local function ApplyClickBinding(key)
    if not key or key == "" then return false end
    CreateBindingButton()

    -- Prefer the dedicated API when the client provides it.
    if SetBindingClick then
        local ok = SetBindingClick(key, BUTTON_NAME, "LeftButton")
        if ok == false then return false end
        return true
    end

    if SetBinding then
        local ok = SetBinding(key, CLICK_COMMAND)
        if ok == false then return false end
        return true
    end

    return false
end

local function SaveCurrentBindings()
    if not SaveBindings or not GetCurrentBindingSet then return end

    -- A new character can report the default set (0) during the intro.
    -- SaveBindings accepts only account (1) or character (2) bindings.
    -- Keep the live binding and addon preference without choosing a new scope.
    local bindingSet = GetCurrentBindingSet()
    if bindingSet == 1 or bindingSet == 2 then
        SaveBindings(bindingSet)
    end
end

function NS:GetDismissKeyDisplay()
    local key = self.db and self.db.dismissKey
    if not key or key == "" then
        return (self.L and self.L.KEYBIND_NONE) or "Not bound"
    end

    if GetBindingText then
        local text = GetBindingText(key, "KEY_")
        if text and text ~= "" then
            return text
        end
    end
    return key
end

function NS:RefreshDismissKeybindUI()
    local button = self.OptionsPanel
        and self.OptionsPanel.pages
        and self.OptionsPanel.pages.controls
        and self.OptionsPanel.pages.controls.dismissKeyButton

    if button and not self._capturingDismissKey then
        button:SetText(self:GetDismissKeyDisplay())
    end
end

function NS:SetDismissKey(key, silent)
    if InCombatLockdown and InCombatLockdown() then
        if not silent and self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return false
    end
    if not self.db then return false end

    if key and key ~= "" and (key == self.db.toggleKey or key == self.db.pauseKey or key == self.db.minimapKey or key == self.db.rememberNodeKey) then
        self.Print("That key is already assigned to the other addon action.")
        return false
    end

    -- Remove the previous internal CLICK binding before assigning a new key.
    ClearBindingCommand(CLICK_COMMAND)

    if key and key ~= "" then
        if not ApplyClickBinding(key) then
            return false
        end
        self.db.dismissKey = key
    else
        self.db.dismissKey = nil
    end

    SaveCurrentBindings()

    self:RefreshDismissKeybindUI()

    if not silent and self.L then
        if self.db.dismissKey then
            self.Print(string.format(self.L.DISMISS_KEYBIND_SAVED, self:GetDismissKeyDisplay()))
        else
            self.Print(self.L.DISMISS_KEYBIND_CLEARED)
        end
    end

    return true
end

function NS:ClearDismissKeybind()
    return self:SetDismissKey(nil, true)
end

function NS:CancelDismissKeyCapture(button)
    if not self._capturingDismissKey then return end
    self._capturingDismissKey = nil
    if button then
        button:SetScript("OnKeyDown", nil)
        button:SetScript("OnMouseDown", nil)
        if button.EnableKeyboard then button:EnableKeyboard(false) end
        if button.SetPropagateKeyboardInput then button:SetPropagateKeyboardInput(true) end
    end
    self:RefreshDismissKeybindUI()
end

function NS:BeginDismissKeyCapture(button)
    if self.CancelRememberNodeKeyCapture then self:CancelRememberNodeKeyCapture(self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls and self.OptionsPanel.pages.controls.rememberNodeKeyButton) end
    local mini=self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls
    if mini and self.CancelMinimapKeyCapture then self:CancelMinimapKeyCapture(mini.minimapKeyButton) end
    if not button then return end

    if InCombatLockdown and InCombatLockdown() then
        if self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return
    end

    local controls = self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls
    if controls then
        self:CancelToggleKeyCapture(controls.keyButton)
        if self.CancelPauseKeyCapture then self:CancelPauseKeyCapture(controls.pauseKeyButton) end
    end

    self._capturingDismissKey = true
    button:SetText((self.L and self.L.KEYBIND_SET) or "Press a key ...")

    if button.EnableKeyboard then
        button:EnableKeyboard(true)
    end
    if button.SetPropagateKeyboardInput then
        button:SetPropagateKeyboardInput(false)
    end

    button:SetScript("OnMouseDown", function(btn, mouse)
        local keys = {RightButton = "BUTTON2", MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5"}
        local key = keys[mouse]
        if not key then return end
        local binding = BuildKey(key)
        NS:CancelDismissKeyCapture(btn)
        NS:SetDismissKey(binding)
    end)

    button:SetScript("OnKeyDown", function(btn, key)
        if key == "ESCAPE" then
            NS:CancelDismissKeyCapture(btn)
            return
        end

        if key == "BACKSPACE" or key == "DELETE" then
            NS:CancelDismissKeyCapture(btn)
            NS:SetDismissKey(nil)
            return
        end

        local binding = BuildKey(key)
        if not binding then return end

        NS:CancelDismissKeyCapture(btn)
        NS:SetDismissKey(binding)
    end)
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    if not NS.db then return end

    HookDismissMinimap()
    CreateBindingButton()

    -- Always rebuild the live binding from the addon's SavedVariables so
    -- /reload and client restarts behave identically.
    ClearBindingCommand(CLICK_COMMAND)

    if NS.db.dismissKey and NS.db.dismissKey ~= "" then
        ApplyClickBinding(NS.db.dismissKey)
    end

    SaveCurrentBindings()

    NS:RefreshDismissKeybindUI()
end)

end

-- Independent pause-swapping binding.
do
local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

-- WoW's internal CLICK binding is used instead of Bindings.xml.
-- This keeps the configurable key fully self-contained and avoids
-- XML binding schema differences on WoW Forever/Camelot.
local BUTTON_NAME = "ForeverFarmRouteGathering_PauseKeyButton"
local CLICK_COMMAND = "CLICK " .. BUTTON_NAME .. ":LeftButton"

local function CreateBindingButton()
    if _G[BUTTON_NAME] then
        NS.PauseKeyButton = _G[BUTTON_NAME]
        return NS.PauseKeyButton
    end

    local button = CreateFrame("Button", BUTTON_NAME, UIParent)
    button:SetSize(1, 1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    button:SetAlpha(0)
    button:EnableMouse(false)
    if button.RegisterForClicks then
        button:RegisterForClicks("LeftButtonUp")
    end
    button:SetScript("OnClick", function()
        if NS and NS.ToggleTrackingSwapsPaused
            and not NS._capturingRememberNodeKey and not NS._capturingMinimapKey and not NS._capturingPauseKey and not NS._capturingToggleKey and not NS._capturingDismissKey
            and not (NS._pauseBindingQuietUntil and GetTime and GetTime() <= NS._pauseBindingQuietUntil) then
            NS:ToggleTrackingSwapsPaused()
        end
    end)
    button:Show()

    NS.PauseKeyButton = button
    return button
end

local function IsModifierKey(key)
    return key == "LSHIFT" or key == "RSHIFT"
        or key == "LCTRL" or key == "RCTRL"
        or key == "LALT" or key == "RALT"
end

local function BuildKey(key)
    if not key or key == "" or IsModifierKey(key) then return nil end

    local parts = {}
    if IsControlKeyDown and IsControlKeyDown() then parts[#parts + 1] = "CTRL" end
    if IsAltKeyDown and IsAltKeyDown() then parts[#parts + 1] = "ALT" end
    if IsShiftKeyDown and IsShiftKeyDown() then parts[#parts + 1] = "SHIFT" end
    parts[#parts + 1] = key
    return table.concat(parts, "-")
end

local function ClearBindingCommand(command)
    if not GetBindingKey or not SetBinding then return end
    local k1, k2 = GetBindingKey(command)
    if k1 then SetBinding(k1) end
    if k2 and k2 ~= k1 then SetBinding(k2) end
end

local function ApplyClickBinding(key)
    if not key or key == "" then return false end
    CreateBindingButton()

    -- Prefer the dedicated API when the client provides it.
    if SetBindingClick then
        local ok = SetBindingClick(key, BUTTON_NAME, "LeftButton")
        if ok == false then return false end
        return true
    end

    if SetBinding then
        local ok = SetBinding(key, CLICK_COMMAND)
        if ok == false then return false end
        return true
    end

    return false
end

local function SaveCurrentBindings()
    if not SaveBindings or not GetCurrentBindingSet then return end

    -- A new character can report the default set (0) during the intro.
    -- SaveBindings accepts only account (1) or character (2) bindings.
    -- Keep the live binding and addon preference without choosing a new scope.
    local bindingSet = GetCurrentBindingSet()
    if bindingSet == 1 or bindingSet == 2 then
        SaveBindings(bindingSet)
    end
end

function NS:GetPauseKeyDisplay()
    local key = self.db and self.db.pauseKey
    if not key or key == "" then
        return (self.L and self.L.KEYBIND_NONE) or "Not bound"
    end

    if GetBindingText then
        local text = GetBindingText(key, "KEY_")
        if text and text ~= "" then
            return text
        end
    end
    return key
end

function NS:RefreshPauseKeybindUI()
    local button = self.OptionsPanel
        and self.OptionsPanel.pages
        and self.OptionsPanel.pages.controls
        and self.OptionsPanel.pages.controls.pauseKeyButton

    if button and not self._capturingPauseKey then
        button:SetText(self:GetPauseKeyDisplay())
    end
end

function NS:SetPauseKey(key, silent)
    if InCombatLockdown and InCombatLockdown() then
        if not silent and self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return false
    end
    if not self.db then return false end

    if key and key ~= "" and (key == self.db.dismissKey or key == self.db.toggleKey or key == self.db.minimapKey or key == self.db.rememberNodeKey) then
        self.Print("That key is already assigned to the other addon action.")
        return false
    end

    -- Remove the previous internal CLICK binding before assigning a new key.
    ClearBindingCommand(CLICK_COMMAND)

    if key and key ~= "" then
        if not ApplyClickBinding(key) then
            return false
        end
        self.db.pauseKey = key
    else
        self.db.pauseKey = nil
    end

    SaveCurrentBindings()

    self:RefreshPauseKeybindUI()

    if not silent and self.L then
        if self.db.pauseKey then
            self.Print(string.format((self.L.PAUSE_KEYBIND_SAVED or "Pause swaps key saved: %s"), self:GetPauseKeyDisplay()))
        else
            self.Print((self.L.PAUSE_KEYBIND_CLEARED or "Pause swaps key cleared."))
        end
    end

    return true
end

function NS:ClearPauseKeybind()
    return self:SetPauseKey(nil, true)
end

function NS:CancelPauseKeyCapture(button)
    if not self._capturingPauseKey then return end
    self._capturingPauseKey = nil
    if button then
        button:SetScript("OnKeyDown", nil)
        button:SetScript("OnKeyUp", nil)
        if button.EnableKeyboard then button:EnableKeyboard(false) end
        if button.SetPropagateKeyboardInput then button:SetPropagateKeyboardInput(true) end
    end
    self:RefreshPauseKeybindUI()
end

function NS:BeginPauseKeyCapture(button)
    if self.CancelRememberNodeKeyCapture then self:CancelRememberNodeKeyCapture(self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls and self.OptionsPanel.pages.controls.rememberNodeKeyButton) end
    local mini=self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls
    if mini and self.CancelMinimapKeyCapture then self:CancelMinimapKeyCapture(mini.minimapKeyButton) end
    if not button then return end

    if InCombatLockdown and InCombatLockdown() then
        if self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return
    end

    local controls = self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls
    if controls then
        self:CancelDismissKeyCapture(controls.dismissKeyButton)
        self:CancelToggleKeyCapture(controls.keyButton)
    end

    self._capturingPauseKey = true
    button:SetText((self.L and self.L.KEYBIND_SET) or "Press a key ...")

    if button.EnableKeyboard then
        button:EnableKeyboard(true)
    end
    if button.SetPropagateKeyboardInput then
        button:SetPropagateKeyboardInput(false)
    end

    button:SetScript("OnKeyDown", function(btn, key)
        if key == "ESCAPE" then
            NS:CancelPauseKeyCapture(btn)
            return
        end

        if key == "BACKSPACE" or key == "DELETE" then
            NS:CancelPauseKeyCapture(btn)
            NS:SetPauseKey(nil)
            return
        end

        local binding = BuildKey(key)
        if not binding then return end

        -- Keep capture active through release so this assignment cannot also
        -- invoke the CLICK binding, including when the key was already bound.
        btn:SetScript("OnKeyUp", function(releasedButton, releasedKey)
            if releasedKey ~= key then return end
            NS._pauseBindingQuietUntil = GetTime and (GetTime() + 0.25) or nil
            NS:CancelPauseKeyCapture(releasedButton)
            NS:SetPauseKey(binding)
        end)
    end)
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    if not NS.db then return end

    CreateBindingButton()

    -- Always rebuild the live binding from the addon's SavedVariables so
    -- /reload and client restarts behave identically.
    ClearBindingCommand(CLICK_COMMAND)

    if NS.db.pauseKey and NS.db.pauseKey ~= "" then
        ApplyClickBinding(NS.db.pauseKey)
    end

    SaveCurrentBindings()

    NS:RefreshPauseKeybindUI()
end)


end

-- Independent experimental minimap toggle binding.
do
local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

-- WoW's internal CLICK binding is used instead of Bindings.xml.
-- This keeps the configurable key fully self-contained and avoids
-- XML binding schema differences on WoW Forever/Camelot.
local BUTTON_NAME = "ForeverFarmRouteGathering_MinimapKeyButton"
local CLICK_COMMAND = "CLICK " .. BUTTON_NAME .. ":LeftButton"

local function CreateBindingButton()
    if _G[BUTTON_NAME] then
        NS.MinimapKeyButton = _G[BUTTON_NAME]
        return NS.MinimapKeyButton
    end

    local button = CreateFrame("Button", BUTTON_NAME, UIParent)
    button:SetSize(1, 1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    button:SetAlpha(0)
    button:EnableMouse(false)
    if button.RegisterForClicks then
        button:RegisterForClicks("LeftButtonUp")
    end
    button:SetScript("OnClick", function()
        if NS and NS.SetExperimentalMinimapEnabled
            and not NS._capturingRememberNodeKey and not NS._capturingMinimapKey and not NS._capturingPauseKey and not NS._capturingToggleKey and not NS._capturingDismissKey
            and not (NS._minimapBindingQuietUntil and GetTime and GetTime() <= NS._minimapBindingQuietUntil) then
            NS:SetExperimentalMinimapEnabled(not (NS.db and NS.db.minimap and NS.db.minimap.fullTimeScanning))
        end
    end)
    button:Show()

    NS.MinimapKeyButton = button
    return button
end

local function IsModifierKey(key)
    return key == "LSHIFT" or key == "RSHIFT"
        or key == "LCTRL" or key == "RCTRL"
        or key == "LALT" or key == "RALT"
end

local function BuildKey(key)
    if not key or key == "" or IsModifierKey(key) then return nil end

    local parts = {}
    if IsControlKeyDown and IsControlKeyDown() then parts[#parts + 1] = "CTRL" end
    if IsAltKeyDown and IsAltKeyDown() then parts[#parts + 1] = "ALT" end
    if IsShiftKeyDown and IsShiftKeyDown() then parts[#parts + 1] = "SHIFT" end
    parts[#parts + 1] = key
    return table.concat(parts, "-")
end

local function ClearBindingCommand(command)
    if not GetBindingKey or not SetBinding then return end
    local k1, k2 = GetBindingKey(command)
    if k1 then SetBinding(k1) end
    if k2 and k2 ~= k1 then SetBinding(k2) end
end

local function ApplyClickBinding(key)
    if not key or key == "" then return false end
    CreateBindingButton()

    -- Prefer the dedicated API when the client provides it.
    if SetBindingClick then
        local ok = SetBindingClick(key, BUTTON_NAME, "LeftButton")
        if ok == false then return false end
        return true
    end

    if SetBinding then
        local ok = SetBinding(key, CLICK_COMMAND)
        if ok == false then return false end
        return true
    end

    return false
end

local function SaveCurrentBindings()
    if not SaveBindings or not GetCurrentBindingSet then return end

    -- A new character can report the default set (0) during the intro.
    -- SaveBindings accepts only account (1) or character (2) bindings.
    -- Keep the live binding and addon preference without choosing a new scope.
    local bindingSet = GetCurrentBindingSet()
    if bindingSet == 1 or bindingSet == 2 then
        SaveBindings(bindingSet)
    end
end

function NS:GetMinimapKeyDisplay()
    local key = self.db and self.db.minimapKey
    if not key or key == "" then
        return (self.L and self.L.KEYBIND_NONE) or "Not bound"
    end

    if GetBindingText then
        local text = GetBindingText(key, "KEY_")
        if text and text ~= "" then
            return text
        end
    end
    return key
end

function NS:RefreshMinimapKeybindUI()
    local button = self.OptionsPanel
        and self.OptionsPanel.pages
        and self.OptionsPanel.pages.controls
        and self.OptionsPanel.pages.controls.minimapKeyButton

    if button and not self._capturingMinimapKey then
        button:SetText(self:GetMinimapKeyDisplay())
    end
end

function NS:SetMinimapKey(key, silent)
    if InCombatLockdown and InCombatLockdown() then
        if not silent and self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return false
    end
    if not self.db then return false end

    if key and key ~= "" and (key == self.db.dismissKey or key == self.db.toggleKey or key == self.db.pauseKey or key == self.db.rememberNodeKey) then
        self.Print("That key is already assigned to the other addon action.")
        return false
    end

    -- Remove the previous internal CLICK binding before assigning a new key.
    ClearBindingCommand(CLICK_COMMAND)

    if key and key ~= "" then
        if not ApplyClickBinding(key) then
            return false
        end
        self.db.minimapKey = key
    else
        self.db.minimapKey = nil
    end

    SaveCurrentBindings()

    self:RefreshMinimapKeybindUI()

    if not silent and self.L then
        if self.db.minimapKey then
            self.Print(string.format((self.L.MINIMAP_KEYBIND_SAVED or "Minimap key saved: %s"), self:GetMinimapKeyDisplay()))
        else
            self.Print((self.L.MINIMAP_KEYBIND_CLEARED or "Minimap key cleared."))
        end
    end

    return true
end

function NS:ClearMinimapKeybind()
    return self:SetMinimapKey(nil, true)
end

function NS:CancelMinimapKeyCapture(button)
    if not self._capturingMinimapKey then return end
    self._capturingMinimapKey = nil
    if button then
        button:SetScript("OnKeyDown", nil)
        button:SetScript("OnKeyUp", nil)
        if button.EnableKeyboard then button:EnableKeyboard(false) end
        if button.SetPropagateKeyboardInput then button:SetPropagateKeyboardInput(true) end
    end
    self:RefreshMinimapKeybindUI()
end

function NS:BeginMinimapKeyCapture(button)
    if self.CancelRememberNodeKeyCapture then self:CancelRememberNodeKeyCapture(self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls and self.OptionsPanel.pages.controls.rememberNodeKeyButton) end
    if not button then return end

    if InCombatLockdown and InCombatLockdown() then
        if self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return
    end

    local controls = self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls
    if controls then
        self:CancelDismissKeyCapture(controls.dismissKeyButton)
        self:CancelToggleKeyCapture(controls.keyButton)
        self:CancelPauseKeyCapture(controls.pauseKeyButton)
    end

    self._capturingMinimapKey = true
    button:SetText((self.L and self.L.KEYBIND_SET) or "Press a key ...")

    if button.EnableKeyboard then
        button:EnableKeyboard(true)
    end
    if button.SetPropagateKeyboardInput then
        button:SetPropagateKeyboardInput(false)
    end

    button:SetScript("OnKeyDown", function(btn, key)
        if key == "ESCAPE" then
            NS:CancelMinimapKeyCapture(btn)
            return
        end

        if key == "BACKSPACE" or key == "DELETE" then
            NS:CancelMinimapKeyCapture(btn)
            NS:SetMinimapKey(nil)
            return
        end

        local binding = BuildKey(key)
        if not binding then return end

        -- Keep capture active through release so this assignment cannot also
        -- invoke the CLICK binding, including when the key was already bound.
        btn:SetScript("OnKeyUp", function(releasedButton, releasedKey)
            if releasedKey ~= key then return end
            NS._minimapBindingQuietUntil = GetTime and (GetTime() + 0.25) or nil
            NS:CancelMinimapKeyCapture(releasedButton)
            NS:SetMinimapKey(binding)
        end)
    end)
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    if not NS.db then return end

    CreateBindingButton()

    -- Always rebuild the live binding from the addon's SavedVariables so
    -- /reload and client restarts behave identically.
    ClearBindingCommand(CLICK_COMMAND)

    if NS.db.minimapKey and NS.db.minimapKey ~= "" then
        ApplyClickBinding(NS.db.minimapKey)
    end

    SaveCurrentBindings()

    NS:RefreshMinimapKeybindUI()
end)


end

-- Independent manual saved-node lookup binding.
do
local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

-- WoW's internal CLICK binding is used instead of Bindings.xml.
-- This keeps the configurable key fully self-contained and avoids
-- XML binding schema differences on WoW Forever/Camelot.
local BUTTON_NAME = "ForeverFarmRouteGathering_RememberNodeKeyButton"
local CLICK_COMMAND = "CLICK " .. BUTTON_NAME .. ":LeftButton"

local function CreateBindingButton()
    if _G[BUTTON_NAME] then
        NS.RememberNodeKeyButton = _G[BUTTON_NAME]
        return NS.RememberNodeKeyButton
    end

    local button = CreateFrame("Button", BUTTON_NAME, UIParent)
    button:SetSize(1, 1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    button:SetAlpha(0)
    button:EnableMouse(false)
    if button.RegisterForClicks then
        button:RegisterForClicks("LeftButtonUp")
    end
    button:SetScript("OnClick", function()
        if NS and NS.RememberNodeAtCursor
            and not NS._capturingMinimapKey and not NS._capturingRememberNodeKey and not NS._capturingPauseKey and not NS._capturingToggleKey and not NS._capturingDismissKey
            and not (NS._rememberNodeBindingQuietUntil and GetTime and GetTime() <= NS._rememberNodeBindingQuietUntil) then
            NS:RememberNodeAtCursor()
        end
    end)
    button:Show()

    NS.RememberNodeKeyButton = button
    return button
end

local function IsModifierKey(key)
    return key == "LSHIFT" or key == "RSHIFT"
        or key == "LCTRL" or key == "RCTRL"
        or key == "LALT" or key == "RALT"
end

local function BuildKey(key)
    if not key or key == "" or IsModifierKey(key) then return nil end

    local parts = {}
    if IsControlKeyDown and IsControlKeyDown() then parts[#parts + 1] = "CTRL" end
    if IsAltKeyDown and IsAltKeyDown() then parts[#parts + 1] = "ALT" end
    if IsShiftKeyDown and IsShiftKeyDown() then parts[#parts + 1] = "SHIFT" end
    parts[#parts + 1] = key
    return table.concat(parts, "-")
end

local function ClearBindingCommand(command)
    if not GetBindingKey or not SetBinding then return end
    local k1, k2 = GetBindingKey(command)
    if k1 then SetBinding(k1) end
    if k2 and k2 ~= k1 then SetBinding(k2) end
end

local function ApplyClickBinding(key)
    if not key or key == "" then return false end
    CreateBindingButton()

    -- Prefer the dedicated API when the client provides it.
    if SetBindingClick then
        local ok = SetBindingClick(key, BUTTON_NAME, "LeftButton")
        if ok == false then return false end
        return true
    end

    if SetBinding then
        local ok = SetBinding(key, CLICK_COMMAND)
        if ok == false then return false end
        return true
    end

    return false
end

local function SaveCurrentBindings()
    if not SaveBindings or not GetCurrentBindingSet then return end

    -- A new character can report the default set (0) during the intro.
    -- SaveBindings accepts only account (1) or character (2) bindings.
    -- Keep the live binding and addon preference without choosing a new scope.
    local bindingSet = GetCurrentBindingSet()
    if bindingSet == 1 or bindingSet == 2 then
        SaveBindings(bindingSet)
    end
end

function NS:GetRememberNodeKeyDisplay()
    local key = self.db and self.db.rememberNodeKey
    if not key or key == "" then
        return (self.L and self.L.KEYBIND_NONE) or "Not bound"
    end

    if GetBindingText then
        local text = GetBindingText(key, "KEY_")
        if text and text ~= "" then
            return text
        end
    end
    return key
end

function NS:RefreshRememberNodeKeybindUI()
    local button = self.OptionsPanel
        and self.OptionsPanel.pages
        and self.OptionsPanel.pages.controls
        and self.OptionsPanel.pages.controls.rememberNodeKeyButton

    if button and not self._capturingRememberNodeKey then
        button:SetText(self:GetRememberNodeKeyDisplay())
    end
end

function NS:SetRememberNodeKey(key, silent)
    if InCombatLockdown and InCombatLockdown() then
        if not silent and self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return false
    end
    if not self.db then return false end

    if key and key ~= "" and (key == self.db.dismissKey or key == self.db.toggleKey or key == self.db.pauseKey or key == self.db.minimapKey) then
        self.Print("That key is already assigned to the other addon action.")
        return false
    end

    -- Remove the previous internal CLICK binding before assigning a new key.
    ClearBindingCommand(CLICK_COMMAND)

    if key and key ~= "" then
        if not ApplyClickBinding(key) then
            return false
        end
        self.db.rememberNodeKey = key
    else
        self.db.rememberNodeKey = nil
    end

    SaveCurrentBindings()

    self:RefreshRememberNodeKeybindUI()

    if not silent and self.L then
        if self.db.rememberNodeKey then
            self.Print(string.format((self.L.REMEMBER_NODE_KEYBIND_SAVED or "Remember node key saved: %s"), self:GetRememberNodeKeyDisplay()))
        else
            self.Print((self.L.REMEMBER_NODE_KEYBIND_CLEARED or "Remember node key cleared."))
        end
    end

    return true
end

function NS:ClearRememberNodeKeybind()
    return self:SetRememberNodeKey(nil, true)
end

function NS:CancelRememberNodeKeyCapture(button)
    if not self._capturingRememberNodeKey then return end
    self._capturingRememberNodeKey = nil
    if button then
        button:SetScript("OnKeyDown", nil)
        button:SetScript("OnKeyUp", nil)
        if button.EnableKeyboard then button:EnableKeyboard(false) end
        if button.SetPropagateKeyboardInput then button:SetPropagateKeyboardInput(true) end
    end
    self:RefreshRememberNodeKeybindUI()
end

function NS:BeginRememberNodeKeyCapture(button)
    if not button then return end

    if InCombatLockdown and InCombatLockdown() then
        if self.L then
            self.Print(self.L.KEYBIND_COMBAT)
        end
        return
    end

    local controls = self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.controls
    if controls then
        self:CancelDismissKeyCapture(controls.dismissKeyButton)
        self:CancelToggleKeyCapture(controls.keyButton)
        self:CancelPauseKeyCapture(controls.pauseKeyButton)
    end

    if controls then self:CancelMinimapKeyCapture(controls.minimapKeyButton) end
    self._capturingRememberNodeKey = true
    button:SetText((self.L and self.L.KEYBIND_SET) or "Press a key ...")

    if button.EnableKeyboard then
        button:EnableKeyboard(true)
    end
    if button.SetPropagateKeyboardInput then
        button:SetPropagateKeyboardInput(false)
    end

    button:SetScript("OnKeyDown", function(btn, key)
        if key == "ESCAPE" then
            NS:CancelRememberNodeKeyCapture(btn)
            return
        end

        if key == "BACKSPACE" or key == "DELETE" then
            NS:CancelRememberNodeKeyCapture(btn)
            NS:SetRememberNodeKey(nil)
            return
        end

        local binding = BuildKey(key)
        if not binding then return end

        -- Keep capture active through release so this assignment cannot also
        -- invoke the CLICK binding, including when the key was already bound.
        btn:SetScript("OnKeyUp", function(releasedButton, releasedKey)
            if releasedKey ~= key then return end
            NS._rememberNodeBindingQuietUntil = GetTime and (GetTime() + 0.25) or nil
            NS:CancelRememberNodeKeyCapture(releasedButton)
            NS:SetRememberNodeKey(binding)
        end)
    end)
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    if not NS.db then return end

    CreateBindingButton()

    -- Always rebuild the live binding from the addon's SavedVariables so
    -- /reload and client restarts behave identically.
    ClearBindingCommand(CLICK_COMMAND)

    if NS.db.rememberNodeKey and NS.db.rememberNodeKey ~= "" then
        ApplyClickBinding(NS.db.rememberNodeKey)
    end

    SaveCurrentBindings()

    NS:RefreshRememberNodeKeybindUI()
end)


end
