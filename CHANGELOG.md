# Changelog

All notable changes to this project will be documented in this file.

## [1.1.12] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_C / COLOR_GRAY_A), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_GRAY / COLOR_LIGHT_GRAY).

## [1.1.9] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification — clue removal
  simply dropped a fixed fraction of cells at random, measured to
  produce severe ambiguity (only Easy difficulty ever generated a
  unique puzzle, and rarely). Clue digging now removes cells one at a
  time and re-checks solution count with a bounded backtracking solver
  after each removal, putting a cell back if removing it breaks
  uniqueness. Every generated puzzle is now guaranteed to have exactly
  one solution.
