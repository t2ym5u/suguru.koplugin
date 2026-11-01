-- suguru_logic.lua
-- Puzzle generation by deduction: every puzzle produced here can be completed
-- with the rules below, without guessing, which also proves it has exactly one
-- solution. The difficulty is the set of rules the puzzle needs, not just how
-- many clues it keeps.
--
--   singles: a cell with one candidate; a digit with one home in its region.
--   witness: additionally, for each region, enumerate every remaining fill
--            (at most 5! = 120). Inward: a candidate found in no fill is dropped.
--            Outward: a digit placed next to an outside cell in EVERY fill can
--            never go in that cell.
--
-- The witness rule, the singles and the carving are ported from sen-ltd/suguru
-- (https://github.com/sen-ltd/suguru), MIT licence, Copyright (c) 2026 SEN LLC;
-- see THIRD_PARTY_NOTICES.md.
--
-- Cells are indexed flat: i = (row - 1) * n + col, from 1 to n*n. Candidates are
-- 5-bit masks (digit v -> bit 2^(v-1)). All randomness goes through the `rand`
-- argument and nothing depends on the clock or on platform-specific maths (no
-- pow, no sort on computed keys), so the same seed gives the same puzzle on every
-- device, which the Daily Challenge needs.

local bitlib = require("bit")
local band, bor, bnot = bitlib.band, bitlib.bor, bitlib.bnot

local Logic = {}

local MAX_REGION = 5
local BIT = { 1, 2, 4, 8, 16 }
local FULL = { 1, 3, 7, 15, 31 } -- FULL[size] = digits 1..size
local POP, HAS, FIRST = {}, {}, {}
for m = 0, 31 do
    local p = 0
    HAS[m] = {}
    for v = 1, MAX_REGION do
        local has = band(m, BIT[v]) ~= 0
        HAS[m][v] = has
        if has then
            p = p + 1
            if not FIRST[m] then
                FIRST[m] = v
            end
        end
    end
    POP[m] = p
end

local function copyArray(t, N)
    local r = {}
    for i = 1, N do
        r[i] = t[i]
    end
    return r
end

local function shuffle(t, rand)
    for i = #t, 2, -1 do
        local j = rand(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- Precomputes regions, neighbours (8 directions) and peers (neighbours + same
-- region) for a flat region layout.
function Logic.buildTopology(n, region)
    local N = n * n
    local cells, maxId = {}, 0
    for i = 1, N do
        local id = region[i]
        cells[id] = cells[id] or {}
        cells[id][#cells[id] + 1] = i
        if id > maxId then
            maxId = id
        end
    end
    local rsize = {}
    for id = 1, maxId do
        if not cells[id] or #cells[id] > MAX_REGION then
            return nil
        end
        rsize[id] = #cells[id]
    end
    local nb, peers = {}, {}
    for i = 1, N do
        local r = math.floor((i - 1) / n)
        local c = (i - 1) % n
        local list = {}
        for dr = -1, 1 do
            for dc = -1, 1 do
                if not (dr == 0 and dc == 0) then
                    local rr, cc = r + dr, c + dc
                    if rr >= 0 and rr < n and cc >= 0 and cc < n then
                        list[#list + 1] = rr * n + cc + 1
                    end
                end
            end
        end
        nb[i] = list
        local seen, p = {}, {}
        for _, j in ipairs(list) do
            seen[j] = true
            p[#p + 1] = j
        end
        for _, j in ipairs(cells[region[i]]) do
            if j ~= i and not seen[j] then
                seen[j] = true
                p[#p + 1] = j
            end
        end
        peers[i] = p
    end
    return {
        n = n,
        N = N,
        R = maxId,
        region = region,
        cells = cells,
        rsize = rsize,
        nb = nb,
        peers = peers,
    }
end

local function baseCandidates(T, val)
    local used = {}
    for id = 1, T.R do
        local m = 0
        for _, c in ipairs(T.cells[id]) do
            if val[c] > 0 then
                m = bor(m, BIT[val[c]])
            end
        end
        used[id] = m
    end
    local cand = {}
    for i = 1, T.N do
        if val[i] > 0 then
            cand[i] = BIT[val[i]]
        else
            local id = T.region[i]
            local m = band(FULL[T.rsize[id]], bnot(used[id]))
            for _, j in ipairs(T.nb[i]) do
                if val[j] > 0 then
                    m = band(m, bnot(BIT[val[j]]))
                end
            end
            if m == 0 then
                return nil
            end
            cand[i] = m
        end
    end
    return cand
end

local function refineByWitnesses(T, val, cand)
    local changed = true
    while changed do
        changed = false
        for id = 1, T.R do
            local cells = T.cells[id]
            local blanks, missing = {}, FULL[#cells]
            for _, c in ipairs(cells) do
                if val[c] > 0 then
                    missing = band(missing, bnot(BIT[val[c]]))
                else
                    blanks[#blanks + 1] = c
                end
            end
            local nbl = #blanks
            if nbl > 0 then
                -- blank cells outside the region that touch the region's blanks
                local outside, touching, oidx = {}, {}, {}
                for b = 1, nbl do
                    for _, j in ipairs(T.nb[blanks[b]]) do
                        if val[j] == 0 and T.region[j] ~= id then
                            local o = oidx[j]
                            if not o then
                                o = #outside + 1
                                outside[o] = j
                                touching[o] = {}
                                oidx[j] = o
                            end
                            touching[o][#touching[o] + 1] = b
                        end
                    end
                end
                local nout = #outside
                local support, pinned, fill = {}, {}, {}
                for b = 1, nbl do support[b] = 0 end
                for o = 1, nout do pinned[o] = 31 end
                local witnesses = 0
                local function dfs(k, left)
                    if k > nbl then
                        witnesses = witnesses + 1
                        for b = 1, nbl do
                            support[b] = bor(support[b], fill[b])
                        end
                        for o = 1, nout do
                            local adj = 0
                            local t = touching[o]
                            for q = 1, #t do
                                adj = bor(adj, fill[t[q]])
                            end
                            pinned[o] = band(pinned[o], adj)
                        end
                        return
                    end
                    local opts = band(cand[blanks[k]], left)
                    while opts ~= 0 do
                        local d = band(opts, -opts)
                        opts = band(opts, opts - 1)
                        fill[k] = d
                        dfs(k + 1, band(left, bnot(d)))
                    end
                end
                dfs(1, missing)
                if witnesses == 0 then
                    return false
                end
                for b = 1, nbl do
                    local c = blanks[b]
                    local nx = band(cand[c], support[b])
                    if nx ~= cand[c] then
                        cand[c] = nx
                        changed = true
                        if nx == 0 then return false end
                    end
                end
                for o = 1, nout do
                    local c = outside[o]
                    local nx = band(cand[c], bnot(pinned[o]))
                    if nx ~= cand[c] then
                        cand[c] = nx
                        changed = true
                        if nx == 0 then return false end
                    end
                end
            end
        end
    end
    return true
end

local function hasConflict(T, val)
    for i = 1, T.N do
        local v = val[i]
        if v > 0 then
            if v > T.rsize[T.region[i]] then
                return true
            end
            for _, j in ipairs(T.peers[i]) do
                if val[j] == v then
                    return true
                end
            end
        end
    end
    return false
end

-- Applies the rules ("singles" or "witness") to a fixpoint on a copy of givens.
-- Returns complete (bool), resulting values.
function Logic.logicSolve(T, givens, rules)
    local val = copyArray(givens, T.N)
    while true do
        if hasConflict(T, val) then
            return false, val
        end
        local cand = baseCandidates(T, val)
        if not cand then
            return false, val
        end
        if rules == "witness" and not refineByWitnesses(T, val, cand) then
            return false, val
        end
        local moved = false
        for i = 1, T.N do
            if val[i] == 0 and POP[cand[i]] == 1 then
                val[i] = FIRST[cand[i]]
                moved = true
            end
        end
        for id = 1, T.R do
            local cells = T.cells[id]
            for d = 1, #cells do
                local placed, homes, home = false, 0, nil
                for _, c in ipairs(cells) do
                    if val[c] == d then
                        placed = true
                        break
                    end
                    if val[c] == 0 and HAS[cand[c]][d] then
                        homes = homes + 1
                        home = c
                    end
                end
                if not placed then
                    if homes == 0 then
                        return false, val
                    elseif homes == 1 and val[home] == 0 then
                        val[home] = d
                        moved = true
                    end
                end
            end
        end
        if not moved then
            for i = 1, T.N do
                if val[i] == 0 then
                    return false, val
                end
            end
            return true, val
        end
    end
end

-- Starts from the solution and removes clues (random order) as long as the grid
-- stays solvable with the given rule set; stops at minGivens clues.
local function carve(T, solution, rules, minGivens, rand)
    local N = T.N
    local puzzle = copyArray(solution, N)
    local order = {}
    for i = 1, N do
        order[i] = i
    end
    shuffle(order, rand)
    local givens = N
    for _, i in ipairs(order) do
        if givens <= minGivens then
            break
        end
        local v = puzzle[i]
        puzzle[i] = 0
        if Logic.logicSolve(T, puzzle, rules) then
            givens = givens - 1
        else
            puzzle[i] = v
        end
    end
    return puzzle
end

-- Easy: basic rules, extra clues; Medium: basic rules, minimal clues;
-- Hard: the witness rule is allowed (never any guessing).
local function makePuzzle(T, solution, difficulty, rand)
    if difficulty == "easy" then
        return carve(T, solution, "singles", math.floor(T.N * 0.40 + 0.5), rand)
    elseif difficulty == "hard" then
        return carve(T, solution, "witness", 0, rand)
    end
    return carve(T, solution, "singles", 0, rand)
end

-- Weighted sampling without replacement, on integer weights.
local function weightedOrder(opts, rand)
    local out, total = {}, 0
    for _, o in ipairs(opts) do
        total = total + o.w
    end
    while #opts > 0 do
        local x, k = rand(total), 1
        while x > opts[k].w do
            x = x - opts[k].w
            k = k + 1
        end
        total = total - opts[k].w
        out[#out + 1] = table.remove(opts, k)
    end
    return out
end

-- Builds regions and a solution together, cell by cell (reading order), with
-- backtracking. Each cell can open a region, join the region on its left or
-- above, or merge both. A "closed" region (no upcoming neighbour cell left)
-- must hold exactly 1..size, so everything produced here is fillable.
local function generateSolution(n, rand, maxNodes)
    local N = n * n
    local nodes = 0
    local result

    local function stats(reg, val, id, upto)
        local size, mask = 0, 0
        for j = 1, upto do
            if reg[j] == id then
                size = size + 1
                mask = mask + BIT[val[j]]
            end
        end
        return size, mask
    end

    -- After cells 1..i are assigned: does the region still have an upcoming neighbour?
    local function isClosed(reg, id, i)
        for j = 1, i do
            if reg[j] == id then
                if (j - 1) % n < n - 1 and j + 1 > i then
                    return false
                end
                if j + n <= N and j + n > i then
                    return false
                end
            end
        end
        return true
    end

    -- Already-assigned neighbours (left, up-left, up, up-right) holding v?
    local function conflict(val, i, v)
        local c = (i - 1) % n
        if c > 0 and val[i - 1] == v then return true end
        if i > n then
            if val[i - n] == v then return true end
            if c > 0 and val[i - n - 1] == v then return true end
            if c < n - 1 and val[i - n + 1] == v then return true end
        end
        return false
    end

    -- Each region gets a target size when created: it only accepts digits <= target,
    -- which yields a realistic mix of sizes (otherwise almost every region ends at 5,
    -- because a randomly drawn 5 forces it to keep growing).
    local function pickTarget()
        local x = rand(100)
        if x <= 3 then return 1
        elseif x <= 11 then return 2
        elseif x <= 31 then return 3
        elseif x <= 63 then return 4
        else return 5 end
    end

    local function rec(reg, val, i, nextId, tgt)
        if result then return end
        nodes = nodes + 1
        if nodes > maxNodes then return end
        if i > N then
            result = { reg = reg, val = val }
            return
        end
        local c = (i - 1) % n
        local L = c > 0 and reg[i - 1] or nil
        local U = i > n and reg[i - n] or nil
        local sL, mL, sU, mU
        if L then sL, mL = stats(reg, val, L, i - 1) end
        if U and U ~= L then sU, mU = stats(reg, val, U, i - 1) end

        local opts = { { kind = "new", w = 2, target = pickTarget() } }
        if L and sL < tgt[L] then
            opts[#opts + 1] = { kind = "join", id = L, size = sL, mask = mL, w = 8, target = tgt[L] }
        end
        if U and U ~= L and sU < tgt[U] then
            opts[#opts + 1] = { kind = "join", id = U, size = sU, mask = mU, w = 8, target = tgt[U] }
        end
        if L and U and U ~= L and sL + sU < MAX_REGION and band(mL, mU) == 0 then
            local t = math.max(tgt[L], tgt[U], sL + sU + 1)
            opts[#opts + 1] = { kind = "merge", size = sL + sU, mask = mL + mU, w = 3, target = t }
        end

        for _, o in ipairs(weightedOrder(opts, rand)) do
            local reg2 = copyArray(reg, i - 1)
            local tgt2 = tgt
            local id, nid, size0, mask0 = nil, nextId, 0, 0
            if o.kind == "new" then
                id, nid = nextId, nextId + 1
                tgt2 = copyArray(tgt, nextId - 1)
                tgt2[id] = o.target
            elseif o.kind == "join" then
                id, size0, mask0 = o.id, o.size, o.mask
            else
                id, size0, mask0 = L, o.size, o.mask
                for j = 1, i - 1 do
                    if reg2[j] == U then
                        reg2[j] = L
                    end
                end
                tgt2 = copyArray(tgt, nextId - 1)
                tgt2[L] = o.target
            end
            reg2[i] = id
            local values = shuffle({ 1, 2, 3, 4, 5 }, rand)
            for _, v in ipairs(values) do
                if v <= o.target and not HAS[mask0][v] and not conflict(val, i, v) then
                    local val2 = copyArray(val, i - 1)
                    val2[i] = v
                    local ok = true
                    local checked = {}
                    for _, rid in ipairs({ id, reg2[i - 1] or 0, i > n and reg2[i - n] or 0 }) do
                        if rid ~= 0 and not checked[rid] then
                            checked[rid] = true
                            if isClosed(reg2, rid, i) then
                                local s, m = stats(reg2, val2, rid, i)
                                if m ~= FULL[s] then
                                    ok = false
                                    break
                                end
                            end
                        end
                    end
                    if ok then
                        rec(reg2, val2, i + 1, nid, tgt2)
                    end
                    if result or nodes > maxNodes then
                        return
                    end
                end
            end
        end
    end

    rec({}, {}, 1, 1, {})
    if not result then
        return nil
    end
    -- Contiguous region renumbering
    local map, count, region = {}, 0, {}
    for i = 1, N do
        local id = result.reg[i]
        if not map[id] then
            count = count + 1
            map[id] = count
        end
        region[i] = map[id]
    end
    return region, result.val
end

local function countSingleCellRegions(T)
    local s = 0
    for id = 1, T.R do
        if T.rsize[id] == 1 then
            s = s + 1
        end
    end
    return s
end

-- Checks that a full grid satisfies every rule.
function Logic.isValidSolution(T, grid)
    for i = 1, T.N do
        local v = grid[i]
        if not v or v < 1 or v > T.rsize[T.region[i]] then
            return false
        end
        for _, j in ipairs(T.peers[i]) do
            if grid[j] == v then
                return false
            end
        end
    end
    return true
end

-- Generates a full game as flat arrays: { n, region, solution, puzzle }, or nil.
function Logic.generate(n, difficulty, rand)
    local maxSingles = math.max(1, math.floor(n * n / 18))
    local fallback
    for _ = 1, 60 do
        local region, solution = generateSolution(n, rand, 4000)
        if region then
            local T = Logic.buildTopology(n, region)
            if T and countSingleCellRegions(T) <= maxSingles and Logic.isValidSolution(T, solution) then
                local game = {
                    n = n,
                    region = region,
                    solution = solution,
                    puzzle = makePuzzle(T, solution, difficulty, rand),
                }
                -- On Hard we want a grid that the basic rules cannot finish;
                -- otherwise retry a few times.
                if difficulty ~= "hard" or not Logic.logicSolve(T, game.puzzle, "singles") then
                    return game
                end
                fallback = fallback or { game = game, tries = 0 }
                fallback.tries = fallback.tries + 1
                if fallback.tries >= 6 then
                    return fallback.game
                end
            end
        end
    end
    return fallback and fallback.game or nil
end

return Logic
