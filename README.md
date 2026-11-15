<p align="center"><img src="assets/icon-1024.png" width="160" alt="KeyGlow icon"></p>
<h1 align="center">KeyGlow</h1>
<p align="center">Make your MacBook keyboard backlight breathe, pulse to your music, flash when your code finishes, and test your reflexes.</p>

---

KeyGlow is a tiny menu bar app that animates the built-in keyboard backlight on a MacBook.

## Effects

| | Effect | What it does |
|---|---|---|
| 🌬️ | **Breathe** | Slow, calm fade in and out |
| ❤️ | **Heartbeat** | Lub-dub pulse |
| ⚡ | **Strobe** | Hard on/off flashing |
| 🕯️ | **Candle** | Warm, random flicker |
| 🌊 | **Ocean** | Rolling, layered waves |
| ⛈️ | **Storm** | Darkness with sudden lightning strikes |
| 🎵 | **Music** | Pulses to the beat of whatever your Mac is playing (or the mic) |
| ⌨️ | **Typing** | Flashes on every keystroke |
| 📡 | **Morse** | Blinks any message you type in Morse code |

Adjust speed and the brightness range with sliders. When you stop or quit, your keyboard goes back to exactly how it was.

## ⏱️ Reflex Game

Hit **Play Reflex Game**, look at your keyboard, and press any key the instant it lights up. Press too early and it strobes at you. Your best time is saved, so post your score. 🏆

## 🔔 Flash when anything finishes

KeyGlow responds to `keyglow://` links, so any script, app or AI agent can flash your keyboard:

```sh
open -g keyglow://done        # ✅ double pulse
open -g keyglow://attention   # 👀 three blinks
open -g keyglow://error       # ❌ angry strobe
open -g "keyglow://flash?times=5"
open -g "keyglow://morse?text=sos"
open -g keyglow://effect/candle   # start any effect
open -g keyglow://stop
```

Know when a long build is done without staring at it:

```sh
npm run build && open -g keyglow://done || open -g keyglow://error
```

### Claude Code

Make your keyboard glow when Claude finishes a task or needs your input. Add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "open -g keyglow://done 2>/dev/null || true", "async": true }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "open -g keyglow://attention 2>/dev/null || true", "async": true }] }]
  }
}
```

The same trick works with any tool that can run a shell command when it's done.

## Install

1. Download **KeyGlow.zip** from the [latest release](../../releases/latest) and unzip it.
2. Drag **KeyGlow.app** into your Applications folder and open it.
3. KeyGlow isn't notarized by Apple, so macOS will block it the first time. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/KeyGlow.app`
4. Click the ⌨️ icon in your menu bar.

**Requirements:** a MacBook with a backlit keyboard, macOS 13 Ventura or later. Works on both Apple Silicon and Intel Macs.

### Permissions
- **Music → Mac audio** asks for "System Audio Recording" access (macOS 14.2+). **Music → Microphone** asks for microphone access. Either way, audio is only measured for loudness. It is never recorded, saved or sent anywhere.
- **Typing** and the **Reflex Game** use Accessibility access (System Settings → Privacy & Security → Accessibility). KeyGlow only notices *that* a key was pressed and never reads which key. The game also works without this permission as long as the KeyGlow panel stays open.

KeyGlow has no network code at all. The whole app is one Swift file, [`KeyGlow.swift`](KeyGlow.swift), so you can read it yourself.

## Build from source

```sh
git clone https://github.com/0xroachyeth/KeyGlow.git
cd KeyGlow
./build.sh
```

Requires Xcode or the Xcode Command Line Tools.

## How it works

macOS has no public API for the keyboard backlight. KeyGlow uses `KeyboardBrightnessClient` from Apple's private `CoreBrightness` framework, the same thing Control Center uses. That means a future macOS update could break it, and it can't be on the Mac App Store.

MacBook backlights are a single white zone, so effects change the brightness of the whole keyboard at once. No per-key RGB, sorry!

## License

MIT
