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

    describe("deduction", function()
        local Logic = require("suguru_logic")

        local function flat(grid, n)
            local out = {}
            for r = 1, n do
                for c = 1, n do out[(r - 1) * n + c] = grid[r][c] end
            end
            return out
        end

        local function topology(b)
            return Logic.buildTopology(b.n, flat(b.cage_id, b.n))
        end

        it("every puzzle can be completed without guessing, at every size and level", function()
            for _, n in ipairs(Board.SIZES) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    for k = 1, 5 do
                        math.randomseed(n * 1000 + k)
                        local b = Board:new{ n = n, difficulty = diff }
                        assert.are.equal(n, b.n)
                        local T = topology(b)
                        local rules = (diff == "hard") and "witness" or "singles"
                        local done, val = Logic.logicSolve(T, flat(b.puzzle, n), rules)
                        assert.is_true(done, ("%dx%d %s needs guessing"):format(n, n, diff))
                        local sol = flat(b.solution, n)
                        for i = 1, n * n do
                            assert.are.equal(sol[i], val[i])
                        end
                    end
                end
            end
        end)

        it("hard puzzles need more than the basic rules", function()
            for _, n in ipairs(Board.SIZES) do
                math.randomseed(n * 31)
                local b = Board:new{ n = n, difficulty = "hard" }
                assert.is_false((Logic.logicSolve(topology(b), flat(b.puzzle, n), "singles")))
            end
        end)

        it("the same seed gives the same puzzle (Daily Challenge)", function()
            local function build()
                math.randomseed(20261101)
                local b = Board:new{ n = 6, difficulty = "medium", no_generate = true }
                b:generate()
                return table.concat(flat(b.cage_id, 6), ",") .. "|" .. table.concat(flat(b.puzzle, 6), ",")
            end
            assert.are.equal(build(), build())
        end)

        it("no_generate leaves the random sequence untouched", function()
            math.randomseed(7)
            local expected = math.random(1000000)
            math.randomseed(7)
            Board:new{ n = 6, no_generate = true }
            assert.are.equal(expected, math.random(1000000))
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
