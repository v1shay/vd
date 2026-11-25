---
name: virtual-display
description: Use the installed vd CLI when the user asks Codex to operate native Mac apps on the local virtual display, move an existing window there, or work in a separate GUI window in the background.
---

In Codex, call `vd_observe` with `{"command":"status"}` on the `virtual-display` MCP server first. Use `vd` on that server for actions and `vd_view` for screenshots. A sandboxed shell can get a misleading LaunchServices “executable is missing” error even while the host is running. On that error, switch to MCP in the same session. If the tool inventory is lazy-loaded, search for `virtual-display` or `vd_observe`.

Prefer the registered `virtual-display` MCP server and its `vd` tool in Codex. Command and arguments match the local CLI. MCP screenshots take no output path and return the PNG directly. In a normal terminal, run `vd help`. If the shell has a limited PATH, use `~/.local/bin/vd`. `vd start` returns the extended display's bounds. `vd permissions` reports the host's Accessibility and Screen Recording grants.

For a fresh instance use `vd launch TextEdit /absolute/path/to/file.txt`. For an existing window use `vd windows --all`, match the requested app and window, then `vd move PID WINDOW`. Use the returned PID and window ID for subsequent operations. Apps that insist on reusing the user's foreground instance can decline background launch.

Use `vd inspect PID WINDOW` and `vd press` or `vd set` for accessible controls. For a visual task, use `vd screenshot PID WINDOW /tmp/unique-name.png` and view the PNG with the agent's image viewer. Use window-local coordinates with `vd click`, `drag`, or `scroll`. Reinspect or recapture after an action and verify the actual result. `vd key` and `type` target a separate background process with a single visible window. If VD rejects delivery, report the limitation and preserve the user's active desktop.

For a human watching the agent, run `vd` or `vd view` in a Kitty-graphics terminal on their main display. Tab switches live virtual displays; q closes the viewer.

For Chrome keyboard tasks, use `vd launch Chrome URL` and use the returned PID and WINDOW. This opens a real Chrome page with its own temporary profile and private input pipe. `vd type PID WINDOW TEXT` inserts text; `vd key PID WINDOW Space` or `Enter` sends browser key events. Existing Chrome windows moved onto VD retain the native-input limitations.
