# Live & Upload Notifier (Discord Bot)

Announces when a **Twitch streamer goes live** and when a **YouTube channel uploads a new video**.
No artificial limit on how many streamers/channels a server can track, and no limit on how many
servers can use the bot.

## Why this scales without needing paid tiers

Most bots that offer this limit you to 1-3 tracked channels because they poll the source API
*per subscription*. This bot instead keeps one shared "state" table per **unique** streamer/channel
across the whole bot, and polls that unique set once per cycle:

- If 500 servers all track the same streamer, that's **1** Twitch API call per cycle, not 500.
- YouTube uses the free public RSS feed (`/feeds/videos.xml?channel_id=...`) — **no API key, no quota,
  no cost at all**, regardless of scale.
- Twitch uses the Helix API's `/streams` endpoint, batched 100 streamers per request (its max),
  polled every 60s by default. Twitch's app-token rate limit is 800 requests/minute, so even
  ~10,000 unique streamers (100 batches) polled every 60s is well within limits.

This means you can self-host a single instance, invite it to as many servers as you want, and
let each server track as many streamers/channels as they want, without your hosting costs or API
usage scaling with server count — only with the number of *unique* streamers/channels people
actually track.

## Requirements

- Node.js 18+ (uses native `fetch`)
- A Discord bot application
- A Twitch Developer application (free, for `/twitch` commands — YouTube needs nothing)

## 1. Create the Discord bot

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications) → **New Application**.
2. Under **Bot**, click **Reset Token** and copy it → this is `DISCORD_TOKEN`.
3. On the **General Information** page, copy the **Application ID** → this is `DISCORD_CLIENT_ID`.
4. Under **Bot**, no privileged intents are needed (this bot only uses slash commands + sends messages).
5. Under **OAuth2 → URL Generator**:
   - Scopes: `bot`, `applications.commands`
   - Bot permissions: `Send Messages`, `Embed Links`, `View Channel`
   - Copy the generated URL — this is your **invite link**. Anyone can use it to add the bot to
     their own server with no involvement from you.

## 2. Create the Twitch app (for `/twitch`, optional but recommended)

1. Go to the [Twitch Developer Console](https://dev.twitch.tv/console/apps) → **Register Your Application**.
2. OAuth Redirect URL can be `https://localhost` (unused — this bot only uses the app/client-credentials flow, not user login).
3. Category: "Application Integration" (or similar).
4. Copy the **Client ID**, then generate and copy a **Client Secret**.

If you skip this, `/youtube` still works fully; `/twitch add` will just tell users Twitch isn't configured.

## 3. Configure and install

```bash
cp .env.example .env
# then fill in DISCORD_TOKEN, DISCORD_CLIENT_ID, TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET

npm install
```

## 4. Register the slash commands

```bash
npm run deploy-commands
```

Global commands can take up to an hour to show up everywhere the first time. For instant testing
in one server while developing, set `GUILD_ID` in `.env` (right-click your server → Copy Server ID,
with Developer Mode on) and run:

```bash
npm run deploy-commands:guild
```

## 5. Run it

```bash
npm start
```

Or with Docker:

```bash
docker compose up -d --build
```

The SQLite database lives at `./data/bot.sqlite` (or wherever `DB_PATH` points) — back this up if you
care about preserving subscriptions.

## Commands

All commands require the **Manage Server** permission.

| Command | Description |
|---|---|
| `/twitch add <username> <channel> [role] [message]` | Track a Twitch streamer |
| `/twitch remove <username>` | Stop tracking |
| `/twitch list` | List tracked streamers in this server |
| `/youtube add <channel_url> <channel> [role] [message]` | Track a YouTube channel (accepts `@handle`, full URL, or raw channel ID) |
| `/youtube remove <channel_url>` | Stop tracking |
| `/youtube list` | List tracked channels in this server |
| `/help` | Show this info in Discord |

Custom messages support placeholders:
- Twitch: `{streamer}`, `{title}`, `{game}`, `{url}`
- YouTube: `{channel}`, `{title}`, `{url}`

## Resource footprint (so you know what to expect on your machine)

- **CPU/RAM**: trivial — this is a small Node process with no heavy computation. Comfortably runs
  on a Raspberry Pi or a cheap VPS.
- **Bandwidth**: each poll cycle transfers small JSON/XML responses (a few KB per batch of 100
  streamers, and a few KB per YouTube RSS feed). Even tracking thousands of unique
  streamers/channels, this is well under 1 GB/day.
- **Disk**: SQLite file grows by roughly one row per subscription — negligible (megabytes even at
  tens of thousands of subscriptions).
- **No inbound ports needed**: this bot only makes outbound requests (to Discord, Twitch, and
  YouTube) and polls on an interval. You don't need port forwarding, a domain, or SSL certificates
  to self-host it, unlike webhook-based designs.

Default poll intervals (60s for Twitch, 5 min for YouTube) are tuned to stay well within Twitch's
rate limits and to match how often YouTube's RSS feed realistically updates. You can adjust
`TWITCH_POLL_INTERVAL_MS` / `YOUTUBE_POLL_INTERVAL_MS` in `.env` if needed.

## Sharing it with a bot community

Once you've confirmed it's stable:

1. Keep it running 24/7 on your machine (or move it to a small VPS later if you prefer).
2. Share the invite link from step 1 — anyone can add it to their own server immediately, no
   approval or per-server setup needed on your end.
3. Optionally list it on a bot directory (e.g. top.gg) once you're comfortable with uptime.

Since everything is self-contained (one process + one SQLite file), moving hosts later is just
copying the `data/` folder and `.env` to the new machine.

## Project structure

```
src/
  index.js                 Bot entry point, wires up commands + pollers
  config.js                Env var loading
  db.js                    SQLite schema + all queries
  deploy-commands.js        Registers slash commands globally
  deploy-commands-guild.js  Registers slash commands to one guild (instant, for testing)
  commands/
    twitch.js               /twitch add|remove|list
    youtube.js               /youtube add|remove|list
    help.js
  services/
    twitchClient.js          Twitch Helix API wrapper (app token, batched requests)
    twitchPoller.js          Polling loop + offline->live detection
    youtubeClient.js         Channel ID resolution + RSS feed reading
    youtubePoller.js         Polling loop + new-video detection
    announcer.js             Embed building + sending
  utils/logger.js
```

## Troubleshooting

- **"This bot instance has not been configured with Twitch API credentials yet"** — set
  `TWITCH_CLIENT_ID` and `TWITCH_CLIENT_SECRET` in `.env` and restart.
- **Commands don't show up in Discord** — global commands take up to an hour; use
  `npm run deploy-commands:guild` with `GUILD_ID` set for instant testing.
- **YouTube channel not found** — try pasting the full channel URL (e.g.
  `https://www.youtube.com/@handle`) instead of just the handle or name.
- **No announcements coming through** — check the bot has permission to view and send messages in
  the configured announcement channel, and check the console logs for errors.
