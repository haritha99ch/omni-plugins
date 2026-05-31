# Discord Widget

Discord voice overlay for Omni Overlay. Shows voice channel participants, speaking indicators, mute/deafen controls, and a server/channel browser.

## Requirements

- Discord desktop client running on the same machine
- A registered Discord application with RPC enabled

## Setup

### 1. Create a Discord Application

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Click **New Application** and give it any name
3. Go to **OAuth2** in the sidebar
4. Under **Redirects**, add `http://localhost`
5. Go to **Rich Presence** in the sidebar and enable it
6. Note your **Client ID** (OAuth2 page, top)
7. Click **Reset Secret** to get your **Client Secret** (OAuth2 page)

### 2. Enter Credentials in the Overlay

1. Open the overlay (Super+G)
2. Open the Discord widget panel
3. Click the **gear icon** in the Discord panel header
4. Enter your Client ID and Client Secret
5. Click the **check button** to save

Credentials are stored at `~/.config/omni-overlay/discord/config.json`.

### 3. Authorize

On first use, Discord will show an authorization dialog asking you to grant the application access to your voice state. Click **Authorize**.

The token is cached at `~/.config/omni-overlay/discord/auth.json` so you only need to authorize once.

## Notes

- The widget connects to Discord's local IPC socket (`/run/user/$UID/discord-ipc-0`). Discord must be running.
- Voice participants stay visible after closing the overlay if the **pin** button is enabled in the voice controls.
