local grid_utils = require("grid_utils")
local UndoStack  = require("undo_stack")
local Hint      = require("hint")
local bit       = require("bit")

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
-- Cage + value generation
-- ---------------------------------------------------------------------------

-- Same rule as isValid() below (no same value among the 8 neighbours), but
-- checked against a plain n×n value grid before a cage's final size is
-- decided.
local function isValidGlobal(grid, n, r, c, v)
    for _, d in ipairs(DIR8) do
        local nr, nc = r + d[1], c + d[2]
        if inBounds(nr, nc, n) and grid[nr][nc] == v then return false end
    end
    return true
end

-- Build cages AND assign their values in the same pass, instead of
-- generating a blind random cage layout and hoping a separate solve() can
-- fill it (measured: at n=6 that needed tens of thousands of attempts to
-- find a satisfiable layout by chance). Each new cage first grows its shape
-- over free cells, then looks for an order of 1..size that fits next to the
-- values already on the board, dropping its last cell until one does.
-- Leftover free cells are patched in a repair pass: join an adjacent cage
-- (its values re-ordered to fit), or become a size-1 cage.
--
-- A 6x6 board is tight: every cage holds one 1 and no two 1s may touch, so
-- there is room for 9 cages at most, nearly all of size 4-5. The old
-- builder restarted the whole board whenever the repair pass got stuck,
-- which took thousands of restarts (up to ~0.6 s on a desktop, ~15 s on a
-- Kobo). Now a stuck cell only clears the cages around it and that patch
-- is rebuilt, up to LOCAL_RETRIES times before a full restart.
local LOCAL_RETRIES = 60

local function tryGenerateCagesAndValues(n)
    local grid    = emptyGrid(n, n, 0)
    local cage_id = emptyGrid(n, n, 0)
    local cages   = {}
    local next_id = 0

    -- Gives the cells of `shape` the values 1..#shape in some order that
    -- clashes with no value already on the board (cells of one cage can't
    -- clash with each other: their values are all different). Plain
    -- backtracking, values tried in increasing order; at most 5! orders.
    -- Leaves the shape's cells at 0 when no order fits.
    local function assignValues(shape)
        local k = #shape
        local used = {}
        local function place(i)
            if i > k then return true end
            local rc = shape[i]
            for v = 1, k do
                if not used[v] and isValidGlobal(grid, n, rc[1], rc[2], v) then
                    used[v] = true
                    grid[rc[1]][rc[2]] = v
                    if place(i + 1) then return true end
                    grid[rc[1]][rc[2]] = 0
                    used[v] = false
                end
            end
            return false
        end
        return place(1)
    end

    local function growCage(r, c)
        -- Prefer sizes 2-3; allow 1-MAX_CAGE
        local weights = {1, 3, 3, 2, 1}
        local total_w = 0
        for _, w in ipairs(weights) do total_w = total_w + w end
        local rng = math.random(total_w)
        local acc, target = 0, 1
        for sz, w in ipairs(weights) do
            acc = acc + w
            if rng <= acc then target = sz; break end
        end

        local shape, in_shape = { {r, c} }, { [r * 100 + c] = true }
        while #shape < target do
            local candidates = {}
            for _, rc in ipairs(shape) do
                for _, d in ipairs(DIR4) do
                    local nr, nc = rc[1] + d[1], rc[2] + d[2]
                    if inBounds(nr, nc, n) and cage_id[nr][nc] == 0
                            and not in_shape[nr * 100 + nc] then
                        candidates[#candidates + 1] = {nr, nc}
                    end
                end
            end
            if #candidates == 0 then break end
            local pick = candidates[math.random(#candidates)]
            shape[#shape + 1] = pick
            in_shape[pick[1] * 100 + pick[2]] = true
        end

        while #shape > 0 and not assignValues(shape) do
            shape[#shape] = nil
        end
        if #shape > 0 then
            next_id = next_id + 1
            for _, rc in ipairs(shape) do cage_id[rc[1]][rc[2]] = next_id end
            cages[next_id] = { cells = shape, size = #shape }
        end
    end

    -- Repair: (r, c) joins an adjacent cage, re-ordering that cage's values
    -- so the new cell fits, or becomes a size-1 cage. False if neither.
    local function patchCell(r, c)
        local tried = {}
        for _, d in ipairs(DIR4) do
            local nr, nc = r + d[1], c + d[2]
            local id = inBounds(nr, nc, n) and cage_id[nr][nc] or 0
            if id > 0 and not tried[id] and cages[id].size < MAX_CAGE then
                tried[id] = true
                local cage = cages[id]
                local saved = {}
                for i, rc in ipairs(cage.cells) do
                    saved[i] = grid[rc[1]][rc[2]]
                    grid[rc[1]][rc[2]] = 0
                end
                local shape = {}
                for i, rc in ipairs(cage.cells) do shape[i] = rc end
                shape[#shape + 1] = {r, c}
                if assignValues(shape) then
                    cage.cells = shape
                    cage.size  = #shape
                    cage_id[r][c] = id
                    return true
                end
                for i, rc in ipairs(cage.cells) do grid[rc[1]][rc[2]] = saved[i] end
            end
        end
        if isValidGlobal(grid, n, r, c, 1) then
            next_id = next_id + 1
            cage_id[r][c] = next_id
            grid[r][c]    = 1
            cages[next_id] = { cells = {{r, c}}, size = 1 }
            return true
        end
        return false
    end

    -- Grows cages from the free cells of `order`, then patches what is
    -- left. Returns the cell it got stuck on, or nil when the board is full.
    local function fill(order)
        for _, cell in ipairs(order) do
            if cage_id[cell[1]][cell[2]] == 0 then growCage(cell[1], cell[2]) end
        end
        for r = 1, n do
            for c = 1, n do
                if cage_id[r][c] == 0 and not patchCell(r, c) then return r, c end
            end
        end
    end

    local all_cells = {}
    for r = 1, n do
        for c = 1, n do all_cells[#all_cells + 1] = {r, c} end
    end
    shuffle(all_cells)

    local sr, sc = fill(all_cells)
    local retries = 0
    while sr do
        retries = retries + 1
        if retries > LOCAL_RETRIES then return nil end
        -- Clear every cage that touches the stuck cell's 3x3 block, then
        -- rebuild the free patch in a fresh random order.
        for dr = -1, 1 do
            for dc = -1, 1 do
                local r, c = sr + dr, sc + dc
                local id = inBounds(r, c, n) and cage_id[r][c] or 0
                if id > 0 then
                    for _, rc in ipairs(cages[id].cells) do
                        cage_id[rc[1]][rc[2]] = 0
                        grid[rc[1]][rc[2]]    = 0
                    end
                    cages[id] = nil
                end
            end
        end
        local free = {}
        for r = 1, n do
            for c = 1, n do
                if cage_id[r][c] == 0 then free[#free + 1] = {r, c} end
            end
        end
        shuffle(free)
        sr, sc = fill(free)
    end

    -- Renumber the surviving cages 1..k in board order.
    local renum, out = {}, {}
    for r = 1, n do
        for c = 1, n do
            local id = cage_id[r][c]
            if not renum[id] then
                out[#out + 1] = cages[id]
                renum[id] = #out
            end
            cage_id[r][c] = renum[id]
        end
    end
    return grid, cage_id, out
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
-- Clue removal
-- ---------------------------------------------------------------------------

-- Counts solutions (up to `limit`) of the region+adjacency instance given
-- the current puzzle's fixed cells, using MRV cell ordering. Returns
-- (solutions_found, exhausted); exhausted=true means node_budget was hit
-- before the search concluded, so the count isn't proof. Mirrors
-- sudokukiller.koplugin/board.lua's countCageSolutions.
-- Since 1.6.0 the generator digs with logicSolve (below), which proves
-- uniqueness by itself; this counter stays as an independent check for
-- the specs.

local function countSolutions(puzzle, cage_id, cages, n, limit, node_budget)
    local grid = {}
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do grid[r][c] = puzzle[r][c] end
    end

    local solutions, nodes, exhausted = 0, 0, false

    local function isValid(r, c, v)
        local id = cage_id[r][c]
        local cage_size = cages[id].size
        if v > cage_size then return false end
        for _, cell in ipairs(cages[id].cells) do
            local cr, cc = cell[1], cell[2]
            if not (cr == r and cc == c) and grid[cr][cc] == v then return false end
        end
        for _, d in ipairs(DIR8) do
            local nr, nc = r + d[1], c + d[2]
            if inBounds(nr, nc, n) and grid[nr][nc] == v then return false end
        end
        return true
    end

    local empties = {}
    for r = 1, n do for c = 1, n do if grid[r][c] == 0 then empties[#empties + 1] = { r = r, c = c } end end end

    local function candidatesFor(r, c)
        local cage_size = cages[cage_id[r][c]].size
        local cands = {}
        for v = 1, cage_size do if isValid(r, c, v) then cands[#cands + 1] = v end end
        return cands
    end

    local function search(depth)
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if depth > #empties then solutions = solutions + 1; return end
        local best_idx, best_cands, best_len = nil, nil, 1000
        for i, cell in ipairs(empties) do
            if grid[cell.r][cell.c] == 0 then
                local cands = candidatesFor(cell.r, cell.c)
                if #cands < best_len then
                    best_len, best_cands, best_idx = #cands, cands, i
                    if best_len <= 1 then break end
                end
            end
        end
        if best_idx == nil then solutions = solutions + 1; return end
        if best_len == 0 then return end
        local cell = empties[best_idx]
        for _, v in ipairs(best_cands) do
            grid[cell.r][cell.c] = v
            search(depth + 1)
            grid[cell.r][cell.c] = 0
            if solutions >= limit or exhausted then return end
        end
    end
    search(1)
    return solutions, exhausted
end

-- ---------------------------------------------------------------------------
-- Human-style solver (1.6.0), used to grade and dig puzzles
-- ---------------------------------------------------------------------------
--
-- Keeps the digits still possible in every cell (bit v-1 for digit v) and
-- narrows them down without trial and error:
--   tier 1  what a beginner does:
--           - a placed digit is crossed out of its cage and of its 8
--             neighbours;
--           - a cell with one digit left takes it;
--           - a digit with one place left in its cage goes there.
--   tier 2  - "pointing": every place left for digit v in a cage touches
--             the same outside cell, so that cell is not v;
--           - pairs and triples inside a cage: two cells holding the same
--             two digits (three cells, three digits) take them away from
--             the rest of the cage, and two digits that only fit in the
--             same two cells clear those cells of everything else.
-- Tier 2 is only tried when tier 1 is stuck, and each tier-2 step counts:
-- that count tells the levels apart. A puzzle it finishes has exactly one
-- solution, since every step only follows from the rules.
local POP, LOW, BIT = {}, {}, {}
for v = 1, MAX_CAGE do BIT[v] = bit.lshift(1, v - 1) end
for m = 0, BIT[MAX_CAGE] * 2 - 1 do
    local k, lo = 0, 0
    for v = 1, MAX_CAGE do
        if bit.band(m, BIT[v]) ~= 0 then
            k = k + 1
            if lo == 0 then lo = v end
        end
    end
    POP[m], LOW[m] = k, lo
end

-- The parts of a layout the solver needs, built once per layout: cell
-- index (r-1)*n+c, each cage's cells, each cell's cage, neighbours, and
-- row/column for quick adjacency tests.
local function prepare(cage_id, cages, n)
    local ctx = { n = n, N = n * n, units = {}, size = {}, cage_of = {}, nbr = {}, row = {}, col = {} }
    for id, cage in ipairs(cages) do
        local u = {}
        for k, rc in ipairs(cage.cells) do u[k] = (rc[1] - 1) * n + rc[2] end
        ctx.units[id] = u
        ctx.size[id] = cage.size
    end
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            ctx.cage_of[i] = cage_id[r][c]
            ctx.row[i], ctx.col[i] = r, c
            local list = {}
            for _, d in ipairs(DIR8) do
                local nr, nc = r + d[1], c + d[2]
                if inBounds(nr, nc, n) then list[#list + 1] = (nr - 1) * n + nc end
            end
            ctx.nbr[i] = list
        end
    end
    return ctx
end

-- puzzle: grid of digits (0 = empty). Returns solved, t2_steps, values
-- (grid, 0 where still open).
local function solveCtx(puzzle, ctx, max_tier)
    local n, N = ctx.n, ctx.N
    local units, size, cage_of, nbr, row, col = ctx.units, ctx.size, ctx.cage_of, ctx.nbr, ctx.row, ctx.col
    local nunits = #units
    local band, bnot, bor = bit.band, bit.bnot, bit.bor
    local dom = {}
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            local v = puzzle[r][c]
            dom[i] = v > 0 and BIT[v] or BIT[size[cage_of[i]]] * 2 - 1
        end
    end
    local done, bad = {}, false
    local function removeMask(j, m)
        local old = dom[j]
        local new = band(old, bnot(m))
        if new ~= old then
            dom[j] = new
            if new == 0 then bad = true end
            return true
        end
        return false
    end

    local function tier1()
        local prog = false
        for i = 1, N do
            local m = dom[i]
            if not done[i] and POP[m] == 1 then
                done[i] = true
                prog = true
                local u = units[cage_of[i]]
                for k = 1, #u do
                    local j = u[k]
                    if j ~= i then removeMask(j, m) end
                end
                local nb = nbr[i]
                for k = 1, #nb do removeMask(nb[k], m) end
            end
        end
        if prog or bad then return prog end
        for id = 1, nunits do
            local u = units[id]
            for v = 1, size[id] do
                local b = BIT[v]
                local cnt, last = 0, nil
                for k = 1, #u do
                    if band(dom[u[k]], b) ~= 0 then cnt = cnt + 1; last = u[k] end
                end
                if cnt == 0 then bad = true; return false end
                if cnt == 1 and dom[last] ~= b then dom[last] = b; return true end
            end
        end
        return false
    end

    local function adjacent(x, p)
        local dr, dc = row[x] - row[p], col[x] - col[p]
        return dr >= -1 and dr <= 1 and dc >= -1 and dc <= 1 and x ~= p
    end

    local places = {}
    local function tier2()
        -- Pointing.
        for id = 1, nunits do
            local u = units[id]
            for v = 1, size[id] do
                local b = BIT[v]
                local np, placed = 0, false
                for k = 1, #u do
                    local j = u[k]
                    local m = dom[j]
                    if band(m, b) ~= 0 then
                        if m == b then placed = true end
                        np = np + 1
                        places[np] = j
                    end
                end
                if not placed and np >= 2 then
                    local ch = false
                    local nb = nbr[places[1]]
                    for k = 1, #nb do
                        local x = nb[k]
                        if cage_of[x] ~= id and band(dom[x], b) ~= 0 then
                            local all = true
                            for q = 2, np do
                                if not adjacent(x, places[q]) then all = false; break end
                            end
                            if all then removeMask(x, b); ch = true end
                        end
                    end
                    if ch then return true end
                end
            end
        end
        -- Subsets inside a cage.
        for id = 1, nunits do
            local u = units[id]
            local nu = #u
            if nu >= 3 then
                for x = 1, nu do
                    local mx = dom[u[x]]
                    if POP[mx] > 1 then
                        for y = x + 1, nu do
                            local my = dom[u[y]]
                            if POP[my] > 1 then
                                local m2 = bor(mx, my)
                                if POP[m2] == 2 then
                                    local ch = false
                                    for z = 1, nu do
                                        if z ~= x and z ~= y and removeMask(u[z], m2) then ch = true end
                                    end
                                    if ch then return true end
                                elseif POP[m2] == 3 then
                                    for w = y + 1, nu do
                                        local mw = dom[u[w]]
                                        if POP[mw] > 1 and POP[bor(m2, mw)] == 3 then
                                            local m3 = bor(m2, mw)
                                            local ch = false
                                            for z = 1, nu do
                                                if z ~= x and z ~= y and z ~= w and removeMask(u[z], m3) then ch = true end
                                            end
                                            if ch then return true end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                -- Hidden pairs.
                local sz = size[id]
                for v = 1, sz do
                    for w = v + 1, sz do
                        local bm = bor(BIT[v], BIT[w])
                        local hits, h1, h2, both = 0, nil, nil, true
                        for k = 1, nu do
                            local m = band(dom[u[k]], bm)
                            if m ~= 0 then
                                hits = hits + 1
                                if hits == 1 then h1 = u[k] else h2 = u[k] end
                                if m ~= bm then both = false end
                            end
                        end
                        if hits == 2 and both and (dom[h1] ~= bm or dom[h2] ~= bm) then
                            dom[h1], dom[h2] = bm, bm
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    local t2 = 0
    while not bad do
        if not tier1() then
            if bad then break end
            local solved = true
            for i = 1, N do if POP[dom[i]] ~= 1 then solved = false; break end end
            if solved then break end
            if max_tier >= 2 and tier2() then t2 = t2 + 1 else break end
        end
    end
    local values, solved = {}, not bad
    for r = 1, n do
        values[r] = {}
        for c = 1, n do
            local m = dom[(r - 1) * n + c]
            if POP[m] == 1 then values[r][c] = LOW[m] else values[r][c] = 0; solved = false end
        end
    end
    return solved, t2, values
end

local function logicSolve(puzzle, cage_id, cages, n, max_tier)
    return solveCtx(puzzle, prepare(cage_id, cages, n), max_tier)
end

-- What each level asks for (1.6.0). Before, digging only checked that the
-- answer stayed unique and levels differed only by how many digits were
-- left: some Medium/Hard puzzles (6x6 Hard: 7%) could only be finished by
-- trial and error.
--   tier          the hardest reasoning the puzzle may need (see logicSolve)
--   min_given     never show fewer digits than this fraction of the grid
--   min_t2/max_t2 how many tier-2 steps the solution needs
-- Easy: tier 1 only. Medium: a few tier-2 steps. Hard: fewer digits, more
-- tier-2 steps. Never trial and error.
local LEVELS = {
    easy   = function(n) return { tier = 1, min_given = 0.40, min_t2 = 0, max_t2 = 0 } end,
    medium = function(n) return { tier = 2, min_given = 0.25, min_t2 = 1, max_t2 = 3 } end,
    hard   = function(n) return { tier = 2, min_given = 0.0, min_t2 = 3, max_t2 = math.huge } end,
}

-- Digs one candidate: digits hidden in a random order, each one only if
-- the solver at the level's tier still finishes the grid. Returns the
-- puzzle and its tier-2 step count.
local function removeClues(solution, cage_id, cages, n, level, on_progress)
    local puzzle = emptyGrid(n, n, 0)
    for r = 1, n do
        for c = 1, n do puzzle[r][c] = solution[r][c] end
    end
    local removable = {}
    for r = 1, n do
        for c = 1, n do removable[#removable + 1] = {r, c} end
    end
    shuffle(removable)
    local total = n * n
    local floor_given = math.ceil(total * level.min_given)
    local shown = total
    local ctx = prepare(cage_id, cages, n)
    for i, cell in ipairs(removable) do
        if shown <= floor_given then break end
        if on_progress then on_progress(i / total) end
        local r, c = cell[1], cell[2]
        puzzle[r][c] = 0
        if solveCtx(puzzle, ctx, level.tier) then
            shown = shown - 1
        else
            puzzle[r][c] = solution[r][c]
        end
    end
    local _, t2 = solveCtx(puzzle, ctx, 2)
    return puzzle, t2
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
    -- opts.empty: the caller loads a save or generates right after, so
    -- skip the throwaway puzzle.
    if not opts.empty then obj:generate() end
    return obj
end

-- on_progress (optional): called with a 0..1 fraction as it goes.
function SuguruBoard:generate(diff, on_progress)
    self.difficulty = diff or self.difficulty
    local n         = self.n
    -- Each attempt is a constructive build with local repairs (no search
    -- over the whole board); measured at n=6 (the hardest supported size)
    -- over 2000 seeds: at most 10 attempts, so this cap is never
    -- reached in practice.
    local MAX_ATTEMPTS = 2000

    local level = (LEVELS[self.difficulty] or LEVELS.medium)(n)
    -- Up to CANDIDATES dug puzzles until one needs a number of tier-2
    -- steps in the level's range; otherwise the closest one. Each layout
    -- is dug in up to ORDERS different random orders before a new one is
    -- built (building a layout costs more than digging it). Every
    -- candidate is finished by logicSolve without trial, so any of them is
    -- a valid, unique puzzle. Bounded by attempt counts only: same seed,
    -- same puzzle on every device.
    local candidates = SuguruBoard.CANDIDATES[n] or 6
    local orders = SuguruBoard.ORDERS[n] or 4
    local best, best_miss, made = nil, nil, 0
    for attempt = 1, MAX_ATTEMPTS do
        local grid, cage_id, cages = tryGenerateCagesAndValues(n)
        if grid then
            for _ = 1, orders do
                made = made + 1
                local puzzle, t2 = removeClues(grid, cage_id, cages, n, level,
                    on_progress and function(f) on_progress((made - 1 + f) / candidates) end)
                local miss = 0
                if t2 < level.min_t2 then miss = level.min_t2 - t2
                elseif t2 > level.max_t2 then miss = t2 - level.max_t2 end
                if not best or miss < best_miss then
                    best = { grid = grid, cage_id = cage_id, cages = cages,
                             puzzle = puzzle, t2 = t2, attempt = made }
                    best_miss = miss
                end
                if miss == 0 or made >= candidates then break end
            end
            if best_miss == 0 or made >= candidates then break end
        end
    end
    if best then
        self.cage_id  = best.cage_id
        self.cages    = best.cages
        self.solution = best.grid
        self.puzzle   = best.puzzle
        -- How the kept puzzle graded (not saved; read by the specs).
        self.grade    = { t2 = best.t2, attempt = best.attempt }
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
        if on_progress then on_progress(1) end
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
SuguruBoard.LEVELS    = LEVELS
-- Dug candidates per puzzle, by size, and dig orders per layout (see
-- generate).
SuguruBoard.CANDIDATES = { [5] = 24, [6] = 12 }
SuguruBoard.ORDERS     = { [5] = 4, [6] = 12 }
-- for the specs
SuguruBoard._logicSolve     = logicSolve
SuguruBoard._countSolutions = countSolutions

return SuguruBoard
