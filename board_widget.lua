local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

-- ---------------------------------------------------------------------------
-- Colors
-- Cage backgrounds cycle through 5 gray shades (indices 0-4)
-- ---------------------------------------------------------------------------

local CAGE_COLORS = {
    Blitbuffer.COLOR_WHITE,
    Blitbuffer.COLOR_GRAY_E,
    Blitbuffer.COLOR_GRAY_D,
    Blitbuffer.COLOR_GRAY_C,
    Blitbuffer.COLOR_GRAY_B,
}
local NUM_CAGE_COLORS = #CAGE_COLORS

local C_BG       = Blitbuffer.COLOR_WHITE
local C_LINE     = Blitbuffer.COLOR_BLACK
local C_THIN     = Blitbuffer.COLOR_GRAY_9
local C_SEL_BG   = Blitbuffer.COLOR_GRAY_D
local C_WRONG_BG = Blitbuffer.COLOR_GRAY_A
local C_NUM      = Blitbuffer.COLOR_BLACK
local C_USER_NUM = Blitbuffer.COLOR_GRAY_4

-- ---------------------------------------------------------------------------
-- SuguruBoardWidget
-- ---------------------------------------------------------------------------

local SuguruBoardWidget = GridWidgetBase:extend{
    board    = nil,
    selected = nil,   -- {r, c}
}

-- Pre-compute a cage-index to color-index mapping so adjacent cages
-- get different shades when possible.
local function assignCageColors(cage_id, cages, n)
    local color_map = {}
    local used = {}

    for r = 1, n do
        for c = 1, n do
            local id = cage_id[r][c]
            if not color_map[id] then
                -- Find colors used by adjacent cages
                used = {}
                for _, cell in ipairs(cages[id].cells) do
                    local cr, cc = cell[1], cell[2]
                    local dirs = { {-1,0},{1,0},{0,-1},{0,1} }
                    for _, d in ipairs(dirs) do
                        local nr, nc = cr + d[1], cc + d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                            local nid = cage_id[nr][nc]
                            if nid ~= id and color_map[nid] then
                                used[color_map[nid]] = true
                            end
                        end
                    end
                end
                -- Pick the first unused color
                local chosen = 1
                for ci = 1, NUM_CAGE_COLORS do
                    if not used[ci] then chosen = ci; break end
                end
                color_map[id] = chosen
            end
        end
    end
    return color_map
end

function SuguruBoardWidget:init()
    local n   = self.board and self.board.n or 5
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)

    if self.board then
        self.cage_color_map = assignCageColors(
            self.board.cage_id, self.board.cages, n)
    end
end

function SuguruBoardWidget:onCellTap(row, col)
    if self.onCellTap_cb then self.onCellTap_cb(row, col) end
end

function SuguruBoardWidget:onCellHold(row, col)
    if self.onCellHold_cb then self.onCellHold_cb(row, col) end
end

-- ---------------------------------------------------------------------------
-- paintTo
-- ---------------------------------------------------------------------------

function SuguruBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local board    = self.board
    local n        = board.n
    local cell     = self.dimen.w / n
    local cmap     = self.cage_color_map or {}

    -- Background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Cell backgrounds by cage color
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)
            local bg
            if self.selected and self.selected[1] == r and self.selected[2] == c then
                bg = C_SEL_BG
            elseif board.wrong[r][c] then
                bg = C_WRONG_BG
            else
                local cage_idx = board.cage_id[r][c]
                local ci = cmap[cage_idx] or 1
                bg = CAGE_COLORS[ci]
            end
            if bg and bg ~= C_BG then
                bb:paintRect(cx, cy, cw, ch, bg)
            end
        end
    end

    -- Thin grid lines between cells in same cage
    local thin  = 1
    local thick = math.max(3, math.floor(cell * 0.12))

    -- Draw all grid lines thinly first
    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        drawLine(bb, x + math.floor(i * cell), y, lw, self.dimen.h, C_LINE)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, lw, C_LINE)
    end

    -- Draw thick cage borders over thin lines
    for r = 1, n do
        for c = 1, n do
            -- Right border
            if c < n and board.cage_id[r][c] ~= board.cage_id[r][c + 1] then
                local bx = x + math.floor(c * cell) - math.floor(thick / 2)
                local by = y + math.floor((r - 1) * cell)
                drawLine(bb, bx, by, thick, math.ceil(cell), C_LINE)
            end
            -- Bottom border
            if r < n and board.cage_id[r][c] ~= board.cage_id[r + 1][c] then
                local bx = x + math.floor((c - 1) * cell)
                local by = y + math.floor(r * cell) - math.floor(thick / 2)
                drawLine(bb, bx, by, math.ceil(cell), thick, C_LINE)
            end
        end
    end

    -- Cell numbers
    local pad   = self.number_padding or 2
    local inner = math.max(1, math.floor(cell - 2 * pad))
    local face  = self.number_face

    for r = 1, n do
        for c = 1, n do
            local v = board.user[r][c]
            if v and v > 0 then
                local cx    = x + math.floor((c - 1) * cell)
                local cy    = y + math.floor((r - 1) * cell)
                local text  = tostring(v)
                local color = (board.puzzle[r][c] ~= 0) and C_NUM or C_USER_NUM
                if board.wrong[r][c] then color = C_LINE end
                local m  = RenderText:sizeUtf8Text(0, inner, face, text, true, false)
                local bx = cx + pad + math.floor((inner - m.x) / 2)
                local by = cy + pad + math.floor((inner + m.y_top - m.y_bottom) / 2)
                RenderText:renderUtf8Text(bb, bx, by, face, text, true, false, color)
            end
        end
    end
end

return SuguruBoardWidget
