# xdr-boost

Free and open-source XDR brightness booster for MacBook Pro. Like [Vivid](https://www.getvivid.app/), but free.

Unlocks the full brightness of your Liquid Retina XDR display beyond the standard SDR limit. Your MacBook Pro can go up to 1600 nits — this tool lets you use it.

## Features

- Boosts screen brightness beyond the standard 500 nit SDR limit using XDR hardware
- No white tint or washed-out colors — uses multiply compositing to preserve colors perfectly
- Compact menu bar popover with an on/off switch and an individual boost slider for each display
- Per-display boost levels adjustable in 0.1x steps up to 4.0x and restored when a display reconnects
- Global keyboard shortcut (**Ctrl+Option+Cmd+V**) to toggle from anywhere
- Survives sleep/wake, lid close/open, and lock/unlock — brightness auto-restores
- Starts with XDR off — rebooting always gives you a normal screen
- Emergency kill switch (`xdr-boost --kill`) if anything goes wrong
- Single binary, no dependencies, ~250 lines of Swift
- Launch agent for auto-start on login

## How it works

MacBook Pro displays can output up to 1600 nits, but macOS caps regular desktop content at ~500 nits. The extra brightness is reserved for HDR content.

xdr-boost creates an invisible Metal overlay using `multiply` compositing with EDR (Extended Dynamic Range) values above 1.0. This triggers the display hardware to boost its backlight, making everything brighter while preserving colors perfectly — no white tint, no washed-out look.

## Requirements

- MacBook Pro with Liquid Retina XDR display (M1 Pro/Max or later)
- macOS 26.0+

## Install

### Download (recommended)

1. Download `XDR-Boost.dmg` from the [latest release](https://github.com/zooltar/xdr-boost/releases/latest)
2. Open the DMG and drag **XDR Boost** to **Applications**
3. Open **XDR Boost** from Applications
4. First time: right-click > Open, then click Open in the dialog
5. Click the **☀** menu bar icon > **Start at Login** to auto-start on login

Release downloads are built for Apple silicon and are ad-hoc signed, but not notarized. macOS may therefore show a security warning on first launch; using **right-click > Open** once allows the app to run. Every push to `main` and every pull request also produces a directly downloadable `XDR-Boost.dmg` artifact retained for 90 days under the corresponding GitHub Actions run. Publishing a GitHub Release builds its selected tag and attaches the same DMG to that release automatically.

### Build from source

```bash
git clone https://github.com/zooltar/xdr-boost.git
cd xdr-boost
make app
```

The app will be at `.build/XDR Boost.app`. To create a DMG:

```bash
make dmg
```

### CLI install (advanced)

```bash
make build
sudo make install
make launch-agent   # auto-start on login
```

### Uninstall

**App:** Delete from Applications and remove from System Settings > General > Login Items.

**CLI:**
```bash
make remove-agent
sudo make uninstall
```

## Usage

```bash
# Run with menu bar icon (default 2x boost)
xdr-boost

# Run with custom boost level
xdr-boost 3.0
```

Click the **☀** icon in your menu bar to open the compact controls. From there you can:
- Toggle XDR brightness on/off
- Adjust each connected XDR-capable display independently in 0.1x steps, up to 4.0x
- Quit

### Keyboard shortcut

**Ctrl+Option+Cmd+V** — toggle XDR brightness on/off from anywhere, no need to find the menu bar icon.

### Emergency kill

If something goes wrong and you can't see your screen:

```bash
# From terminal (even blind-type it)
xdr-boost --kill

# Or just
pkill xdr-boost
```

The app always starts with XDR **off** — you have to manually turn it on. So rebooting will always give you a normal screen.

### Sleep, lid close, and lock screen

A common problem with XDR brightness apps is that closing your laptop or locking the screen kills the brightness boost, and it doesn't come back when you return. xdr-boost fixes this with a watchdog that automatically restores your brightness within a few seconds after:

- Closing and reopening the laptop lid
- Locking and unlocking the screen
- Sleep and wake
- Plugging/unplugging external displays

If you turned XDR on, it stays on — no matter what.

## License

MIT
