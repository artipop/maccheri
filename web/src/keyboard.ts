// KeyboardEvent.code → USB HID usage (keyboard page 0x07), which the simulator's Indigo keyboard
// takes. `code` names the physical key, so layouts are the simulator's business, as with a
// hardware keyboard on a real iPhone.

const letters = 'abcdefghijklmnopqrstuvwxyz'
const table: Record<string, number> = {}
for (let i = 0; i < 26; i++) table[`Key${letters[i].toUpperCase()}`] = 0x04 + i
for (let i = 1; i <= 9; i++) table[`Digit${i}`] = 0x1e + i - 1
table.Digit0 = 0x27
Object.assign(table, {
  Enter: 0x28, Escape: 0x29, Backspace: 0x2a, Tab: 0x2b, Space: 0x2c,
  Minus: 0x2d, Equal: 0x2e, BracketLeft: 0x2f, BracketRight: 0x30, Backslash: 0x31,
  Semicolon: 0x33, Quote: 0x34, Backquote: 0x35, Comma: 0x36, Period: 0x37, Slash: 0x38,
  CapsLock: 0x39, IntlBackslash: 0x64,
  F1: 0x3a, F2: 0x3b, F3: 0x3c, F4: 0x3d, F5: 0x3e, F6: 0x3f, F7: 0x40, F8: 0x41, F9: 0x42, F10: 0x43, F11: 0x44, F12: 0x45,
  Insert: 0x49, Home: 0x4a, PageUp: 0x4b, Delete: 0x4c, End: 0x4d, PageDown: 0x4e,
  ArrowRight: 0x4f, ArrowLeft: 0x50, ArrowDown: 0x51, ArrowUp: 0x52,
  NumpadEnter: 0x58,
  ControlLeft: 0xe0, ShiftLeft: 0xe1, AltLeft: 0xe2, MetaLeft: 0xe3,
  ControlRight: 0xe4, ShiftRight: 0xe5, AltRight: 0xe6, MetaRight: 0xe7,
})

export function hidUsage(code: string): number | null {
  return table[code] ?? null
}
