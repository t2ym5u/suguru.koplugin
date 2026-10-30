local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase          = require("screen_base")
local MenuHelper          = require("menu_helper")
local SuguruBoard         = lrequire("board")
local SuguruBoardWidget   = lrequire("board_widget")

local GAME_RULES_EN = _([[
Suguru — Rules

Fill every cell of the grid with a number so that:

1. Each outlined group of N cells contains every number from 1 to N exactly once.
2. No two cells containing the same number may touch each other — not even diagonally.

Given clue numbers are fixed. Use the group sizes and adjacency rules to deduce the remaining numbers.

Tap a cell to select it, then tap a digit to fill it in. Long-press a cell to clear it.
]])

local GAME_RULES_FR = [[
Suguru — Règles

Remplissez chaque case de la grille avec un chiffre de sorte que :

1. Chaque groupe délimité de N cases contienne tous les chiffres de 1 à N exactement une fois.
2. Deux cases contenant le même chiffre ne peuvent pas se toucher — même en diagonale.

Les chiffres indices sont fixes. Utilisez la taille des groupes et les règles d'adjacence pour déduire les autres chiffres.

Appuyez sur une case pour la sélectionner, puis sur un chiffre pour la remplir. Appui long sur une case pour l'effacer.
]]

local SuguruScreen = ScreenBase:extend{}

function SuguruScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", SuguruBoard.DEFAULT_N)
    local diff  = self.plugin:getSetting("difficulty", "medium")
    self.board  = SuguruBoard:new{ n = n, difficulty = diff }
    if not self.board:load(state) then
        self.board:generate(diff)
    end
    self.selected = nil
    ScreenBase.init(self)
end

function SuguruScreen:serializeState()
    return self.board:serialize()
end

function SuguruScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Suguru"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getSizeButtonText(), callback = function() self:openSizeMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Digit pad 1..MAX_CAGE
    local keys = {}
    for d = 1, SuguruBoard.MAX_CAGE do
        local dv = d
        keys[#keys + 1] = { id = "digit_" .. d, text = tostring(d),
                            callback = function() self:onDigitKey(dv) end }
    end
    local number_pad = self:buildNumberPad(keys)

    -- Bottom bar
    local action_bar = self:buildActionBar({
        { text = _("Erase"), callback = function() self:onErase() end },
        { text = _("Check"), callback = function() self:onCheck() end },
        { text = _("Hint"),  callback = function() self:onHint() end },
        { text = _("Undo"),  callback = function() self:onUndo() end },
    })

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        number_pad,
        VerticalSpan:new{ width = Size.span.vertical_default },
        action_bar,
    }

    -- The widget draws its own outer border, so the frame only pads.
    local frame_pad = Size.padding.large
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = SuguruBoardWidget:new{
        max_size       = math.min(budget_w, budget_h) - 2 * frame_pad,
        board          = self.board,
        selected       = self.selected,
        onCellTap_cb   = function(r, c) self:onCellTap(r, c) end,
        onCellHold_cb  = function(r, c) self:onCellHold(r, c) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function SuguruScreen:onCellTap(r, c)
    self.selected = { r, c }
    self.board_widget.selected = self.selected
    self.board_widget:refresh()
    self:updateStatus()
end

function SuguruScreen:onCellHold(r, c)
    self:onCellTap(r, c)
    self:onErase()
end

function SuguruScreen:onDigitKey(d)
    if not self.selected then
        self:updateStatus(_("Tap a cell first."))
        return
    end
    local r, c = self.selected[1], self.selected[2]
    local ok   = self.board:setCell(r, c, d)
    if ok then
        self.plugin:saveState(self.board:serialize())
        if self.board.won then
            self:updateStatus(_("Congratulations! Puzzle solved!"))
        else
            self:updateStatus()
        end
    end
    self.board_widget:refresh()
end

function SuguruScreen:onErase()
    if not self.selected then return end
    local r, c = self.selected[1], self.selected[2]
    self.board:eraseCell(r, c)
    self.plugin:saveState(self.board:serialize())
    self.board_widget:refresh()
    self:updateStatus()
end

function SuguruScreen:onUndo()
    if self.board:undoMove() then
        self.board_widget:refresh()
        self:updateStatus()
        self.plugin:saveState(self.board:serialize())
    end
end

function SuguruScreen:onCheck()
    self.board:check()
    self.board_widget:refresh()
    local empty = self.board:countEmpty()
    if self.board.won then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    elseif empty > 0 then
        self:updateStatus(T(_("Check done. Empty: %1"), empty))
    else
        self:updateStatus(_("Some cells have errors."))
    end
end

function SuguruScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "medium")
    local n    = self.plugin:getSetting("grid_n", SuguruBoard.DEFAULT_N)
    self.board  = SuguruBoard:new{ n = n, difficulty = diff }
    self.board:generate(diff)
    self.selected = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function SuguruScreen:openSizeMenu()
    local sizes = {}
    for _, sz in ipairs(SuguruBoard.SIZES) do
        sizes[#sizes + 1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", SuguruBoard.DEFAULT_N),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function SuguruScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

function SuguruScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.won then
        status = _("Congratulations! Puzzle solved!")
    else
        local empty = self.board:countEmpty()
        local n     = self.board.n
        local diff  = self.plugin:getSetting("difficulty", "medium")
        local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = self:joinStatus(T("%1×%2", n, n), label, T(_("Empty: %1"), empty))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends with a status update, so this
    -- is where the bar learns that the round ended (or was undone).
    self:refreshActionBar()
end

function SuguruScreen:getSizeButtonText()
    local n = self.board.n
    return T(_("Size: %1"), n .. "\xC3\x97" .. n)
end

function SuguruScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "medium")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Difficulty: %1"), label)
end

-- won is saved with the board.
function SuguruScreen:isRoundOver()
    return self.board.won
end

return SuguruScreen
