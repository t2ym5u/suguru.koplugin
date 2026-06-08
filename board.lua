local grid_utils = require("grid_utils")
local UndoStack  = require("undo_stack")

local emptyGrid = grid_utils.emptyGrid
local shuffle   = grid_utils.shuffle

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SIZES     = { 5, 6 }
local DEFAULT_N = 5
local MAX_CAGE  = 5   -- cages hold 1..MAX_CAGE cells

local DIR4 = { {-1,0},{1,0},{0,-1},{0,1} }
local DIR8 = { {-1,-1},{-1,0},{-1,1},{0,-1},{0,1},{1,-1},{1,0},{1,1} }

local function inBounds(r, c, n)
    return r >= 1 and r <= n and c >= 1 and c <= n
end

-- ---------------------------------------------------------------------------
-- Cage generation (BFS flood-fill, sizes 1-5, preferring 2-3)
-- ---------------------------------------------------------------------------

local function generateCages(n)
    local cage_id = emptyGrid(n, n, 0)
    local cages   = {}
    local next_id = 1

    local all_cells = {}
    for r = 1, n do
        for c = 1, n do all_cells[#all_cells + 1] = {r, c} end
    end
    shuffle(all_cells)

    for _, cell in ipairs(all_cells) do
        local r, c = cell[1], cell[2]
        if cage_id[r][c] == 0 then
            local id   = next_id
            next_id    = next_id + 1
            local cage = { cells = {{r, c}}, size = 1 }
            cages[id]  = cage
            cage_id[r][c] = id

            -- Prefer sizes 2-3; allow 1-MAX_CAGE
            local weights = {1, 3, 3, 2, 1}
            local total_w = 0
            for _, w in ipairs(weights) do total_w = total_w + w end
            local rng = math.random(total_w)
            local acc = 0
            local target = 1
            for sz, w in ipairs(weights) do
                acc = acc + w
                if rng <= acc then target = sz; break end
            end

            local frontier = {{r, c}}
            while cage.size < target and #frontier > 0 do
                local fi   = math.random(#frontier)
                local fc   = frontier[fi]
                local dirs = { {-1,0},{1,0},{0,-1},{0,1} }
                shuffle(dirs)
                local grown = false
                for _, d in ipairs(dirs) do
                    local nr, nc = fc[1] + d[1], fc[2] + d[2]
                    if inBounds(nr, nc, n) and cage_id[nr][nc] == 0 then
                        cage_id[nr][nc] = id
                        cage.size = cage.size + 1
                        cage.cells[#cage.cells + 1] = {nr, nc}
                        frontier[#frontier + 1] = {nr, nc}
                        grown = true
                        break
                    end
                end
                if not grown then
                    table.remove(frontier, fi)
                end
            end
        end
    end

    return cage_id, cages
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
-- Backtracking solver
-- ---------------------------------------------------------------------------

local function solve(grid, cage_id, cages, cells, idx, n)
    if idx > #cells then return true end
    local r, c      = cells[idx][1], cells[idx][2]
    local cage_size = cages[cage_id[r][c]].size
    for v = 1, cage_size do
        if isValid(grid, cage_id, cages, r, c, v, n) then
            grid[r][c] = v
            if solve(grid, cage_id, cages, cells, idx + 1, n) then
                return true
            end
            grid[r][c] = 0
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Clue removal
-- ---------------------------------------------------------------------------

local function removeClues(solution, n, difficulty)
    local keep_ratio
    if     difficulty == "easy"   then keep_ratio = 0.55
    elseif difficulty == "hard"   then keep_ratio = 0.20
    else                               keep_ratio = 0.35
    end

    local puzzle = emptyGrid(n, n, 0)
    for r = 1, n do
        for c = 1, n do puzzle[r][c] = solution[r][c] end
    end

    local removable = {}
    for r = 1, n do
        for c = 1, n do removable[#removable + 1] = {r, c} end
    end
    shuffle(removable)

    local total   = n * n
    local to_keep = math.floor(total * keep_ratio)
    local kept    = 0
    for _, cell in ipairs(removable) do
        if kept < to_keep then
            kept = kept + 1
        else
            puzzle[cell[1]][cell[2]] = 0
        end
    end
    return puzzle
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
    obj:generate()
    return obj
end

function SuguruBoard:generate(diff)
    self.difficulty = diff or self.difficulty
    local n         = self.n
    local MAX_ATTEMPTS = 20

    for _ = 1, MAX_ATTEMPTS do
        local cage_id, cages = generateCages(n)

        local cells = {}
        for r = 1, n do
            for c = 1, n do cells[#cells + 1] = {r, c} end
        end

        local grid = emptyGrid(n, n, 0)
        if solve(grid, cage_id, cages, cells, 1, n) then
            self.cage_id  = cage_id
            self.cages    = cages
            self.solution = grid
            self.puzzle   = removeClues(grid, n, self.difficulty)
            self.user     = emptyGrid(n, n, 0)
            self.wrong    = emptyGrid(n, n, false)
            for r = 1, n do
                for c = 1, n do
                    self.user[r][c] = self.puzzle[r][c]
                end
            end
            self.won      = false
            self.selected = nil
            self.undo:clear()
            return
        end
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
