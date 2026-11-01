local grid_utils = require("grid_utils")
local UndoStack  = require("undo_stack")
local Hint      = require("hint")
local Logic     = require("suguru_logic")

local emptyGrid = grid_utils.emptyGrid

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SIZES     = { 5, 6, 7, 8 }
local DEFAULT_N = 5
local MAX_CAGE  = 5   -- cages hold 1..MAX_CAGE cells

local DIR8 = { {-1,-1},{-1,0},{-1,1},{0,-1},{0,1},{1,-1},{1,0},{1,1} }

local function inBounds(r, c, n)
    return r >= 1 and r <= n and c >= 1 and c <= n
end

-- ---------------------------------------------------------------------------
-- Validity check for Suguru
-- ---------------------------------------------------------------------------

-- Returns true if placing v at (r,c) is valid given current grid.
local function isValid(grid, cage_id, cages, r, c, v, n)
    local id        = cage_id[r][c]
    local cage_size = cages[id].size

    if v > cage_size then return false end

    -- v must not appear in same cage already
    for _, cell in ipairs(cages[id].cells) do
        local cr, cc = cell[1], cell[2]
        if not (cr == r and cc == c) and grid[cr][cc] == v then
            return false
        end
    end

    -- No orthogonal or diagonal neighbour with same value
    for _, d in ipairs(DIR8) do
        local nr, nc = r + d[1], c + d[2]
        if inBounds(nr, nc, n) and grid[nr][nc] == v then
            return false
        end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- SuguruBoard
-- ---------------------------------------------------------------------------

local SuguruBoard = {}
SuguruBoard.__index = SuguruBoard

function SuguruBoard:new(opts)
    opts = opts or {}
    local obj = setmetatable({
        n          = opts.n          or DEFAULT_N,
        difficulty = opts.difficulty or "medium",
        cage_id    = nil,
        cages      = nil,
        solution   = nil,
        puzzle     = nil,
        user       = nil,
        wrong      = nil,
        won        = false,
        selected   = nil,
        undo       = UndoStack:new{ max_size = 500 },
    }, self)
    -- A caller about to load() a saved game, or to generate() at a chosen
    -- difficulty, passes no_generate so the grid isn't built for nothing.
    if not opts.no_generate then obj:generate() end
    return obj
end

function SuguruBoard:generate(diff)
    self.difficulty = diff or self.difficulty
    local n         = self.n
    local game      = Logic.generate(n, self.difficulty, math.random)

    if game then
        local cage_id  = emptyGrid(n, n, 0)
        local solution = emptyGrid(n, n, 0)
        local puzzle   = emptyGrid(n, n, 0)
        local user     = emptyGrid(n, n, 0)
        local cages    = {}
        for r = 1, n do
            for c = 1, n do
                local i  = (r - 1) * n + c
                local id = game.region[i]
                cage_id[r][c]  = id
                solution[r][c] = game.solution[i]
                puzzle[r][c]   = game.puzzle[i]
                user[r][c]     = game.puzzle[i]
                local cage = cages[id]
                if not cage then
                    cage = { cells = {}, size = 0 }
                    cages[id] = cage
                end
                cage.size = cage.size + 1
                cage.cells[cage.size] = {r, c}
            end
        end
        self.cage_id  = cage_id
        self.cages    = cages
        self.solution = solution
        self.puzzle   = puzzle
        self.user     = user
        self.wrong    = emptyGrid(n, n, false)
        self.won      = false
        self.selected = nil
        self.undo:clear()
        return
    end

    -- Fallback: single-cell cages, all value 1
    local n2    = DEFAULT_N
    self.n      = n2
    local cage_id = emptyGrid(n2, n2, 0)
    local cages   = {}
    local id = 0
    for r = 1, n2 do
        for c = 1, n2 do
            id = id + 1
            cage_id[r][c] = id
            cages[id] = { cells = {{r, c}}, size = 1 }
        end
    end
    self.cage_id  = cage_id
    self.cages    = cages
    self.solution = emptyGrid(n2, n2, 1)
    self.puzzle   = emptyGrid(n2, n2, 0)
    self.user     = emptyGrid(n2, n2, 0)
    self.wrong    = emptyGrid(n2, n2, false)
    self.won      = false
    self.selected = nil
    self.undo:clear()
end

function SuguruBoard:setCell(r, c, v)
    if self.puzzle[r][c] ~= 0 then return false end
    if self.won then return false end
    local old = self.user[r][c]
    if old == v then return false end
    self.undo:push{ r = r, c = c, old = old }
    self.user[r][c]  = v
    self.wrong[r][c] = false
    self:_checkWin()
    return true
end

function SuguruBoard:eraseCell(r, c)
    return self:setCell(r, c, 0)
end

function SuguruBoard:undoMove()
    local entry = self.undo:pop()
    if not entry then return false end
    self.user[entry.r][entry.c]  = entry.old
    self.wrong[entry.r][entry.c] = false
    self.won = false
    return true
end

function SuguruBoard:check()
    local n = self.n
    self.wrong = emptyGrid(n, n, false)
    for r = 1, n do
        for c = 1, n do
            local v = self.user[r][c]
            if v ~= 0 then
                self.user[r][c] = 0
                if not isValid(self.user, self.cage_id, self.cages, r, c, v, n) then
                    self.wrong[r][c] = true
                end
                self.user[r][c] = v
            end
        end
    end
end

function SuguruBoard:_checkWin()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] ~= self.solution[r][c] then
                self.won = false
                return
            end
        end
    end
    self.won = true
end

function SuguruBoard:countEmpty()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == 0 then count = count + 1 end
        end
    end
    return count
end

function SuguruBoard:isWon()
    return self.won
end

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

-- Givens are the non-zero cells of `puzzle`; setCell already refuses those
-- and accepts 0 as "empty", so no clearCell is needed.
Hint.install(SuguruBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    isGiven     = function(b, r, c) return b.puzzle[r][c] ~= 0 end,
    setCell     = function(b, r, c, v) return b:setCell(r, c, v) end,
    blank       = 0,
})

function SuguruBoard:serialize()
    local n = self.n
    local cid_flat, sol_flat, puz_flat, usr_flat = {}, {}, {}, {}
    local wrong_flat = {}
    for r = 1, n do
        for c = 1, n do
            cid_flat[#cid_flat + 1]   = self.cage_id[r][c]
            sol_flat[#sol_flat + 1]   = self.solution[r][c]
            puz_flat[#puz_flat + 1]   = self.puzzle[r][c]
            usr_flat[#usr_flat + 1]   = self.user[r][c]
            wrong_flat[#wrong_flat + 1] = self.wrong[r][c] and 1 or 0
        end
    end
    local cage_sizes, cage_cells = {}, {}
    for id, cage in pairs(self.cages) do
        cage_sizes[id] = cage.size
        cage_cells[id] = {}
        for _, cell in ipairs(cage.cells) do
            cage_cells[id][#cage_cells[id] + 1] = {cell[1], cell[2]}
        end
    end
    return {
        n          = n,
        difficulty = self.difficulty,
        cage_id    = cid_flat,
        cage_sizes = cage_sizes,
        cage_cells = cage_cells,
        solution   = sol_flat,
        puzzle     = puz_flat,
        user       = usr_flat,
        wrong      = wrong_flat,
        won        = self.won,
    }
end

function SuguruBoard:load(data)
    if type(data) ~= "table" or not data.cage_id then return false end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or "medium"
    self.cage_id    = emptyGrid(n, n, 0)
    self.solution   = emptyGrid(n, n, 0)
    self.puzzle     = emptyGrid(n, n, 0)
    self.user       = emptyGrid(n, n, 0)
    self.wrong      = emptyGrid(n, n, false)
    local idx = 1
    for r = 1, n do
        for c = 1, n do
            self.cage_id[r][c]  = data.cage_id[idx]  or 1
            self.solution[r][c] = data.solution[idx]  or 0
            self.puzzle[r][c]   = data.puzzle[idx]    or 0
            self.user[r][c]     = data.user[idx]      or 0
            self.wrong[r][c]    = (data.wrong and data.wrong[idx] == 1) or false
            idx = idx + 1
        end
    end
    self.cages = {}
    if data.cage_sizes then
        for id, sz in pairs(data.cage_sizes) do
            local cells = {}
            if data.cage_cells and data.cage_cells[id] then
                for _, cell in ipairs(data.cage_cells[id]) do
                    cells[#cells + 1] = {cell[1], cell[2]}
                end
            end
            self.cages[id] = { cells = cells, size = sz }
        end
    end
    self.won      = data.won or false
    self.selected = nil
    self.undo:clear()
    return true
end

SuguruBoard.SIZES     = SIZES
SuguruBoard.DEFAULT_N = DEFAULT_N
SuguruBoard.MAX_CAGE  = MAX_CAGE

return SuguruBoard
