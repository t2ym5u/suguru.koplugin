local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("SuguruBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    -- Regression guard for the 2026-07-21 bug: independent random cage
    -- generation checked against the strict 8-directional adjacency rule
    -- only after the fact, causing 100% fallback at n=6 to a hardcoded
    -- single-cell-cages/all-value-1 puzzle that silently overrides the
    -- requested n (`self.n = n2` in the fallback branch). Fixed by
    -- interleaving cage growth with value assignment. These tests assert
    -- the board honors the requested n and the solution is genuinely valid.
    local function newBoard(n, diff)
        math.randomseed(42)
        return Board:new{ n = n or 5, difficulty = diff or "medium" }
    end

    describe("construction", function()
        it("creates a 5×5 board by default", function()
            local b = Board:new()
            assert.are.equal(5, b.n)
        end)
    end)

    describe("generate", function()
        it("honors the requested n instead of falling back to 5", function()
            for _, n in ipairs(Board.SIZES) do
                math.randomseed(n * 137)
                local b = Board:new{ n = n }
                assert.are.equal(n, b.n, ("n silently downgraded for requested n=%d"):format(n))
            end
        end)

        it("each cage's solution values are a permutation of 1..cage size", function()
            local b = newBoard(6)
            for _, cage in pairs(b.cages) do
                local seen = {}
                for _, cell in ipairs(cage.cells) do
                    local v = b.solution[cell[1]][cell[2]]
                    assert.is_true(v >= 1 and v <= cage.size,
                        ("value %d out of range for cage size %d"):format(v, cage.size))
                    assert.is_nil(seen[v], ("duplicate value %d in cage"):format(v))
                    seen[v] = true
                end
            end
        end)

        it("no two 8-adjacent cells share the same solution value", function()
            local b = newBoard(6)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    for dr = -1, 1 do
                        for dc = -1, 1 do
                            if not (dr == 0 and dc == 0) then
                                local nr, nc = r + dr, c + dc
                                if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                                    assert.are_not.equal(b.solution[r][c], b.solution[nr][nc],
                                        ("equal values at 8-adjacent [%d][%d]/[%d][%d]"):format(r, c, nr, nc))
                                end
                            end
                        end
                    end
                end
            end
        end)

        it("the solution passes the game's own validity check with zero errors", function()
            local b = newBoard(6)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    b.user[r][c] = b.solution[r][c]
                end
            end
            b:check()
            for r = 1, n do
                for c = 1, n do
                    assert.is_false(b.wrong[r][c], ("solution cell [%d][%d] flagged wrong"):format(r, c))
                end
            end
        end)

        it("runs across all supported sizes without hanging or erroring", function()
            for _, n in ipairs(Board.SIZES) do
                math.randomseed(n * 977)
                local ok = pcall(function() Board:new{ n = n } end)
                assert.is_true(ok, ("generate failed for n=%d"):format(n))
            end
        end)
    end)

    -- 1.5.0: the cage builder repairs a stuck patch locally instead of
    -- restarting the whole board (6x6 took up to ~0.6 s on a desktop).
    -- Guard what it must still deliver on many seeds: connected cages of
    -- 1..size, no equal 8-neighbours, a puzzle with exactly one solution
    -- (counted by a plain backtracker independent of board.lua's), fast.
    describe("generator over many seeds", function()
        local DIR4 = { {-1,0},{1,0},{0,-1},{0,1} }

        local function countSolutions(b, limit)
            local n, g = b.n, {}
            for r = 1, n do
                g[r] = {}
                for c = 1, n do g[r][c] = b.puzzle[r][c] end
            end
            local count = 0
            local function ok(r, c, v)
                for dr = -1, 1 do
                    for dc = -1, 1 do
                        local nr, nc = r + dr, c + dc
                        if (dr ~= 0 or dc ~= 0) and nr >= 1 and nr <= n and nc >= 1 and nc <= n
                                and g[nr][nc] == v then
                            return false
                        end
                    end
                end
                for _, cell in ipairs(b.cages[b.cage_id[r][c]].cells) do
                    if g[cell[1]][cell[2]] == v then return false end
                end
                return true
            end
            local function rec(k)
                if count >= limit then return end
                if k > n * n then count = count + 1; return end
                local r, c = math.floor((k - 1) / n) + 1, (k - 1) % n + 1
                if g[r][c] ~= 0 then return rec(k + 1) end
                for v = 1, b.cages[b.cage_id[r][c]].size do
                    if ok(r, c, v) then
                        g[r][c] = v
                        rec(k + 1)
                        g[r][c] = 0
                    end
                end
            end
            rec(1)
            return count
        end

        it("builds valid, uniquely solvable puzzles quickly at every size and difficulty", function()
            for _, n in ipairs(Board.SIZES) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local worst = 0
                    for seed = 1, 15 do
                        math.randomseed(seed * 7919 + n)
                        local t0 = os.clock()
                        local b = Board:new{ n = n, difficulty = diff }
                        worst = math.max(worst, os.clock() - t0)
                        assert.are.equal(n, b.n)
                        local cells_seen = 0
                        for id, cage in ipairs(b.cages) do
                            local vals, in_cage = {}, {}
                            for _, cell in ipairs(cage.cells) do
                                assert.are.equal(id, b.cage_id[cell[1]][cell[2]])
                                local v = b.solution[cell[1]][cell[2]]
                                assert.is_true(v >= 1 and v <= cage.size)
                                assert.is_nil(vals[v])
                                vals[v] = true
                                in_cage[cell[1] * 100 + cell[2]] = true
                                cells_seen = cells_seen + 1
                            end
                            -- connected (orthogonally)
                            local first = cage.cells[1]
                            local stack, seen, reached = { first }, { [first[1] * 100 + first[2]] = true }, 1
                            while #stack > 0 do
                                local cur = table.remove(stack)
                                for _, d in ipairs(DIR4) do
                                    local key = (cur[1] + d[1]) * 100 + cur[2] + d[2]
                                    if in_cage[key] and not seen[key] then
                                        seen[key] = true
                                        reached = reached + 1
                                        stack[#stack + 1] = { cur[1] + d[1], cur[2] + d[2] }
                                    end
                                end
                            end
                            assert.are.equal(#cage.cells, reached)
                        end
                        assert.are.equal(n * n, cells_seen)
                        for r = 1, n do
                            for c = 1, n do
                                for dr = -1, 1 do
                                    for dc = -1, 1 do
                                        local nr, nc = r + dr, c + dc
                                        if (dr ~= 0 or dc ~= 0) and nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                                            assert.are_not.equal(b.solution[r][c], b.solution[nr][nc])
                                        end
                                    end
                                end
                                local p = b.puzzle[r][c]
                                assert.is_true(p == 0 or p == b.solution[r][c])
                            end
                        end
                        assert.are.equal(1, countSolutions(b, 2),
                            ("n=%d %s seed %d is not uniquely solvable"):format(n, diff, seed))
                    end
                    -- generous: ~0.05 s on a desktop
                    assert.is_true(worst < 1.0, ("n=%d %s took %.2f s"):format(n, diff, worst))
                end
            end
        end)
    end)

    describe("setCell / eraseCell / undoMove", function()
        it("setCell rejects a given (puzzle) cell", function()
            local b = newBoard(6)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.puzzle[rr][cc] ~= 0 then r, c = rr, cc; goto done end
                end
            end
            ::done::
            if not r then return end
            local ok = b:setCell(r, c, 1)
            assert.is_false(ok)
        end)

        it("setCell + undoMove round-trips a non-given cell", function()
            local b = newBoard(6)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.puzzle[rr][cc] == 0 then r, c = rr, cc; goto done end
                end
            end
            ::done::
            assert.is_not_nil(r)
            b:setCell(r, c, b.solution[r][c])
            assert.are.equal(b.solution[r][c], b.user[r][c])
            b:undoMove()
            assert.are.equal(0, b.user[r][c])
        end)
    end)

    describe("serialize / load", function()
        it("round-trips cages, solution and user state", function()
            local b = newBoard(6)
            local data = b:serialize()
            local b2   = Board:new{ n = b.n }
            local ok   = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(#b.cages, #b2.cages)
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
end)
