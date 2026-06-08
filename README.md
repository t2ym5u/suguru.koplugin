# Suguru

> **Status: stub — not yet implemented**

## Description

Divide the grid into regions. Fill each cell so no two adjacent cells share the same digit and each region contains 1–size.

## Files to create

- `board.lua` — game logic, puzzle generator, serialize/load
- `board_widget.lua` — grid rendering and tap gestures
- `screen.lua` — full-screen layout (buttons + board)
- `main.lua` — PluginBase entry point

## Notes

Number placement puzzle — use GridWidgetBase from game-common.
