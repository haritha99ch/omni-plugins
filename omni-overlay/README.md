# Omni Overlay

Xbox Game Bar-style gaming overlay for Noctalia Shell. Features a dynamic island with Discord voice, OBS controls, audio, performance widgets, and a custom app workspace.

## Compositor Support

| Feature | Hyprland | Sway / Niri / LabWC |
|---|---|---|
| Overlay HUD (island, widgets) | Yes | Yes |
| Discord, OBS, Audio, Performance widgets | Yes | Yes |
| `special:overlay-apps` workspace | Yes | No |
| App shortcuts (overlay mode) | Yes | No |
| Click-through toggle | Yes | No |
| Super+Shift+G move to overlay | Yes | No |

The overlay HUD and all widgets work on any compositor supported by Noctalia Shell. The `special:overlay-apps` workspace feature is Hyprland-only - on other compositors the plugin runs without crashing but those features are silently disabled.

## Requirements

- [Noctalia Shell](https://github.com/noctalia-dev/noctalia-shell)

---

## Installation

Install via **Settings -> Plugins -> Available** from the `haritha99ch` source, or add the source manually:

```
https://github.com/haritha99ch/omni-plugins
```

After install, open **Settings -> Plugins -> Available** and install **Omni Overlay**.

---

## Required Hyprland Configuration

The following changes must be made manually to your Hyprland config. The plugin cannot write to config files itself.

### 1. General (`hyprland.conf`)

```conf
misc {
    close_special_on_empty = false  # keeps special:overlay-apps alive when all apps close
}
```

### 2. Keybinds (`hyprland.conf` or `keybinds.conf`)

```conf
# Toggle the overlay
bind = SUPER, G, exec, qs -c omni-shell ipc call plugin:omni-overlay toggle

# Move the active window into the overlay workspace
bind = SUPER SHIFT, G, exec, hyprctl dispatch movetoworkspace special:overlay-apps
```

### 2. Window Rules (`windowrules.conf`)

```conf
# Float all windows in the overlay workspace
windowrule = match:workspace special:overlay-apps, float true


### 3. Visual (optional but recommended, `hyprland.conf` or theme file)

```conf
decoration {
    dim_special = 0.4   # dims the workspace behind the overlay apps
    blur {
        special = false  # disables blur on special workspaces
    }
}
```

---


## Widget Setup

Additional widgets (Discord, OBS) are available via the built-in widget marketplace. Open the overlay -> island **Widgets** button -> settings gear -> add source:

```
https://github.com/haritha99ch/omni-overlay-widgets
```

This source is pre-configured on first install. See each widget's README for setup instructions.

---

## How `special:overlay-apps` Works

The overlay uses a Hyprland special workspace (`special:overlay-apps`) as a persistent app layer:

- **Super+G** opens the overlay HUD (island + widgets)
- **Super+Shift+G** moves any window into the overlay workspace
- Apps in `special:overlay-apps` stay running when the overlay closes - they are hidden, not killed
- The **click-through toggle** (mouse icon in the island) allows interacting with the workspace below when needed
- `special_fallthrough` is managed automatically by the plugin - no manual config required

---

## Notes

- Steam library path can be configured in the overlay island gear settings if Steam is installed at a non-default location
- The overlay works on any workspace, not just gaming workspaces
