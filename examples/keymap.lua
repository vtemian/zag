-- Example keymap overrides. Drop into ~/.config/zag/config.lua or
-- require() from it.

-- Change split triggers to match your muscle memory
zag.keymap("normal", "|", "split_vertical")
zag.keymap("normal", "-", "split_horizontal")

-- Window close via Ctrl-chord from either mode
zag.keymap("normal", "<C-q>", "close_window")
zag.keymap("insert", "<C-q>", "close_window")

-- Quick mode toggle from insert mode
zag.keymap("insert", "<C-n>", "enter_normal_mode")
