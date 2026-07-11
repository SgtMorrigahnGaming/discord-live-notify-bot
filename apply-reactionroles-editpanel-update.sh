#!/usr/bin/env bash
# apply-reactionroles-editpanel-update.sh
#
# One-time patch script — adds panel editing (title/description/move-channel) to the
# reaction roles feature, both as a slash command and on the dashboard.
#
# What this touches:
#   - src/commands/reactionroles.js  (new `edit-panel` subcommand)
#   - src/db.js                      (new `movePanel` helper)
#   - src/web/api.js                 (new PATCH /guilds/:guildId/reactionroles/panels/:messageId)
#   - src/web/public/index.html      (Edit button + form on each panel card in the dashboard)
#
# Run this from the repo root. It overwrites the four files above with their updated
# versions (each is backed up to <file>.bak first) and does NOT touch the database file
# or restart the bot — do that yourself after reviewing the diff.
#
# After running: re-register slash commands (new subcommand), e.g.
#   npm run deploy-commands:guild     # instant, one server
#   npm run deploy-commands           # global, can take up to an hour
# Then restart the bot process / dashboard so the new files are loaded.

set -euo pipefail

if [ ! -f "package.json" ] || [ ! -d "src" ]; then
  echo "❌ Run this from the repo root (where package.json and src/ live)." >&2
  exit 1
fi

backup() {
  if [ -f "$1" ]; then
    cp "$1" "$1.bak"
    echo "  backed up $1 -> $1.bak"
  fi
}

echo "Backing up files about to change..."
backup "src/commands/reactionroles.js"
backup "src/db.js"
backup "src/web/api.js"
backup "src/web/public/index.html"

echo "Writing src/commands/reactionroles.js..."
cat > src/commands/reactionroles.js << 'RR_CMD_EOF'
const { SlashCommandBuilder, PermissionFlagsBits, EmbedBuilder, ChannelType } = require('discord.js');
const db = require('../db');
const emojiUtil = require('../utils/emoji');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('reactionroles')
    .setDescription('Set up self-serve roles via message reactions')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('create-panel')
      .setDescription('Post a new panel message that you can attach reaction roles to')
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post the panel in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('title').setDescription('Panel title').setRequired(true))
      .addStringOption(opt => opt.setName('description').setDescription('Panel description').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('edit-panel')
      .setDescription('Edit the title/description/channel of an existing panel message')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID (right-click it -> Copy Message ID)').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel the panel message is currently in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('title').setDescription('New panel title (leave blank to keep current)').setRequired(false))
      .addStringOption(opt => opt.setName('description').setDescription('New panel description (leave blank to keep current)').setRequired(false))
      .addChannelOption(opt => opt.setName('new_channel').setDescription('Move the panel to this channel (leave blank to keep it where it is)').addChannelTypes(ChannelType.GuildText).setRequired(false)))
    .addSubcommand(sub => sub
      .setName('add')
      .setDescription('Attach an emoji-role pair to an existing panel message')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID (right-click it -> Copy Message ID)').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel the panel message is in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('emoji').setDescription('Emoji to react with (pick from the emoji picker)').setRequired(true))
      .addRoleOption(opt => opt.setName('role').setDescription('Role to grant when someone reacts').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('remove')
      .setDescription('Remove an emoji-role pair from a panel')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel the panel message is in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('emoji').setDescription('Emoji to remove').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('list')
      .setDescription('List emoji-role pairs on a panel')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID').setRequired(true))),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'create-panel') {
      const channel = interaction.options.getChannel('channel');
      const title = interaction.options.getString('title');
      const description = interaction.options.getString('description');

      const embed = new EmbedBuilder().setColor(0x5865f2).setTitle(title).setDescription(description);
      const message = await channel.send({ embeds: [embed] }).catch(() => null);
      if (!message) {
        return interaction.reply({ content: `❌ Couldn't post in ${channel} — check I have permission to send messages there.`, ephemeral: true });
      }

      return interaction.reply({
        content: `✅ Panel posted in ${channel}.\nMessage ID: \`${message.id}\`\n\nNow use \`/reactionroles add\` with that message ID to attach emoji-role pairs to it.`,
        ephemeral: true,
      });
    }

    if (sub === 'edit-panel') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const channel = interaction.options.getChannel('channel');
      const newTitle = interaction.options.getString('title');
      const newDescription = interaction.options.getString('description');
      const newChannel = interaction.options.getChannel('new_channel');

      if (!newTitle && !newDescription && !newChannel) {
        return interaction.editReply('❌ Give at least a new title, description, or channel — otherwise there\'s nothing to change.');
      }

      const message = await channel.messages.fetch(messageId).catch(() => null);
      if (!message) {
        return interaction.editReply(`❌ Couldn't find a message with ID \`${messageId}\` in ${channel}.`);
      }
      if (message.author.id !== interaction.client.user.id) {
        return interaction.editReply(`❌ That message wasn't posted by me, so I can't edit it.`);
      }
      const existing = message.embeds[0];
      if (!existing) {
        return interaction.editReply(`❌ That message doesn't have an embed to edit — it doesn't look like a reaction role panel.`);
      }

      const embed = EmbedBuilder.from(existing)
        .setTitle(newTitle ?? existing.title)
        .setDescription(newDescription ?? existing.description);

      const isMoving = newChannel && newChannel.id !== channel.id;

      if (!isMoving) {
        try {
          await message.edit({ embeds: [embed] });
        } catch (err) {
          return interaction.editReply(`❌ Couldn't edit that message: ${err.message}`);
        }
        return interaction.editReply(`✅ Panel updated in ${channel}.`);
      }

      // Moving to a new channel: Discord messages can't change channel, so repost + re-attach
      // reactions on the new message, repoint the DB rows at it, then clean up the old one.
      const pairs = db.listReactionRolesForMessage(messageId);

      let newMessage;
      try {
        newMessage = await newChannel.send({ embeds: [embed] });
      } catch (err) {
        return interaction.editReply(`❌ Couldn't post in ${newChannel} — check I have permission to send messages there. (${err.message})`);
      }

      const failedEmoji = [];
      for (const pair of pairs) {
        const emoji = { id: pair.emoji_id, name: pair.emoji_name };
        try {
          await newMessage.react(emojiUtil.toReactString(emoji));
        } catch {
          failedEmoji.push(emojiUtil.displayEmoji(emoji));
        }
      }

      db.movePanel(messageId, newMessage.id, newChannel.id);
      await message.delete().catch(() => {});

      let reply = `✅ Panel moved to ${newChannel}.\nNew message ID: \`${newMessage.id}\``;
      if (failedEmoji.length > 0) {
        reply += `\n⚠️ Couldn't re-add these reactions (role mappings were still moved, but you'll need to react manually or re-add them): ${failedEmoji.join(', ')}`;
      }
      return interaction.editReply(reply);
    }

    if (sub === 'add') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const channel = interaction.options.getChannel('channel');
      const rawEmoji = interaction.options.getString('emoji');
      const role = interaction.options.getRole('role');

      const parsedEmoji = emojiUtil.parseEmojiInput(rawEmoji);
      if (!parsedEmoji) {
        return interaction.editReply(`❌ Couldn't understand \`${rawEmoji}\` as an emoji. Pick one from Discord's emoji picker rather than typing a shortcode.`);
      }

      if (role.managed || role.id === interaction.guild.id) {
        return interaction.editReply(`❌ Can't use that role — it's managed by an integration or is the default @everyone role.`);
      }
      if (interaction.guild.members.me.roles.highest.position <= role.position) {
        return interaction.editReply(`❌ I can't assign **${role.name}** — it's positioned above my own highest role. Move my role above it in Server Settings → Roles.`);
      }

      const message = await channel.messages.fetch(messageId).catch(() => null);
      if (!message) {
        return interaction.editReply(`❌ Couldn't find a message with ID \`${messageId}\` in ${channel}.`);
      }

      try {
        await message.react(emojiUtil.toReactString(parsedEmoji));
      } catch (err) {
        return interaction.editReply(`❌ Couldn't react with that emoji: ${err.message}. If it's a custom emoji, make sure it's from this server (or one I'm also in).`);
      }

      db.addReactionRole(interaction.guildId, channel.id, messageId, parsedEmoji.id, parsedEmoji.name, role.id, null);

      return interaction.editReply(`✅ ${emojiUtil.displayEmoji(parsedEmoji)} on that panel now grants **${role.name}**.`);
    }

    if (sub === 'remove') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const channel = interaction.options.getChannel('channel');
      const rawEmoji = interaction.options.getString('emoji');

      const parsedEmoji = emojiUtil.parseEmojiInput(rawEmoji);
      if (!parsedEmoji) {
        return interaction.editReply(`❌ Couldn't understand \`${rawEmoji}\` as an emoji.`);
      }

      const changes = db.removeReactionRole(messageId, parsedEmoji.id, parsedEmoji.name);
      if (changes === 0) {
        return interaction.editReply(`⚠️ That emoji wasn't attached to that message.`);
      }

      const message = await channel.messages.fetch(messageId).catch(() => null);
      if (message) {
        const reaction = message.reactions.cache.find(r =>
          parsedEmoji.id ? r.emoji.id === parsedEmoji.id : r.emoji.name === parsedEmoji.name
        );
        if (reaction) await reaction.users.remove(interaction.client.user.id).catch(() => {});
      }

      return interaction.editReply(`🗑️ Removed ${emojiUtil.displayEmoji(parsedEmoji)} from that panel.`);
    }

    if (sub === 'list') {
      const messageId = interaction.options.getString('message_id').trim();
      const rows = db.listReactionRolesForMessage(messageId);
      if (rows.length === 0) {
        return interaction.reply({ content: 'No emoji-role pairs are attached to that message yet.', ephemeral: true });
      }
      const embed = new EmbedBuilder()
        .setColor(0x5865f2)
        .setTitle('Reaction roles on this panel')
        .setDescription(rows.map(r => {
          const emoji = emojiUtil.displayEmoji({ id: r.emoji_id, name: r.emoji_name });
          return `${emoji} → <@&${r.role_id}>`;
        }).join('\n'));
      return interaction.reply({ embeds: [embed], ephemeral: true });
    }
  },
};
RR_CMD_EOF

echo "Writing src/db.js..."
cat > src/db.js << 'RR_DB_EOF'
const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');
const config = require('./config');

const dbPath = path.resolve(config.db.path);
fs.mkdirSync(path.dirname(dbPath), { recursive: true });

const db = new Database(dbPath);
db.pragma('journal_mode = WAL');

db.exec(`
CREATE TABLE IF NOT EXISTS twitch_subscriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  streamer_login TEXT NOT NULL,
  announce_channel_id TEXT NOT NULL,
  role_id TEXT,
  custom_message TEXT,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(guild_id, streamer_login)
);

CREATE TABLE IF NOT EXISTS youtube_subscriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  channel_name TEXT,
  announce_channel_id TEXT NOT NULL,
  role_id TEXT,
  custom_message TEXT,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(guild_id, channel_id)
);

-- Shared state per unique streamer/channel, independent of how many guilds track it
CREATE TABLE IF NOT EXISTS twitch_state (
  streamer_login TEXT PRIMARY KEY,
  is_live INTEGER NOT NULL DEFAULT 0,
  last_stream_id TEXT
);

CREATE TABLE IF NOT EXISTS youtube_state (
  channel_id TEXT PRIMARY KEY,
  last_video_id TEXT,
  initialized INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS reaction_roles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  emoji_id TEXT,
  emoji_name TEXT NOT NULL,
  role_id TEXT NOT NULL,
  dm_message TEXT,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(message_id, emoji_id, emoji_name)
 );

CREATE TABLE IF NOT EXISTS guild_welcome_config (
  guild_id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL,
  dm_message TEXT,
  enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS freegames_subscriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('steam','gog','epic')),
  channel_id TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(guild_id, source)
);

CREATE TABLE IF NOT EXISTS freegames_announced (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source TEXT NOT NULL,
  external_id TEXT NOT NULL,
  announced_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(source, external_id)
);
`);

module.exports = {
  raw: db,

  // ---- Twitch ----
  addTwitchSub(guildId, streamerLogin, channelId, roleId, customMessage) {
    const stmt = db.prepare(`
      INSERT INTO twitch_subscriptions (guild_id, streamer_login, announce_channel_id, role_id, custom_message)
      VALUES (@guildId, @streamerLogin, @channelId, @roleId, @customMessage)
      ON CONFLICT(guild_id, streamer_login) DO UPDATE SET
        announce_channel_id = excluded.announce_channel_id,
        role_id = excluded.role_id,
        custom_message = excluded.custom_message
    `);
    stmt.run({ guildId, streamerLogin: streamerLogin.toLowerCase(), channelId, roleId, customMessage });
    db.prepare(`INSERT OR IGNORE INTO twitch_state (streamer_login) VALUES (?)`).run(streamerLogin.toLowerCase());
  },
  removeTwitchSub(guildId, streamerLogin) {
    return db.prepare(`DELETE FROM twitch_subscriptions WHERE guild_id = ? AND streamer_login = ?`)
      .run(guildId, streamerLogin.toLowerCase()).changes;
  },
  listTwitchSubsForGuild(guildId) {
    return db.prepare(`SELECT * FROM twitch_subscriptions WHERE guild_id = ? ORDER BY streamer_login`).all(guildId);
  },
  listAllUniqueTwitchStreamers() {
    return db.prepare(`SELECT DISTINCT streamer_login FROM twitch_subscriptions`).all().map(r => r.streamer_login);
  },
  listGuildSubsForStreamer(streamerLogin) {
    return db.prepare(`SELECT * FROM twitch_subscriptions WHERE streamer_login = ?`).all(streamerLogin.toLowerCase());
  },
  getTwitchState(streamerLogin) {
    return db.prepare(`SELECT * FROM twitch_state WHERE streamer_login = ?`).get(streamerLogin.toLowerCase());
  },
  setTwitchState(streamerLogin, isLive, lastStreamId) {
    db.prepare(`
      INSERT INTO twitch_state (streamer_login, is_live, last_stream_id) VALUES (@login, @isLive, @streamId)
      ON CONFLICT(streamer_login) DO UPDATE SET is_live = excluded.is_live, last_stream_id = excluded.last_stream_id
    `).run({ login: streamerLogin.toLowerCase(), isLive: isLive ? 1 : 0, streamId: lastStreamId });
  },
  pruneOrphanTwitchState() {
    db.prepare(`
      DELETE FROM twitch_state WHERE streamer_login NOT IN (SELECT DISTINCT streamer_login FROM twitch_subscriptions)
    `).run();
  },

  // ---- YouTube ----
  addYoutubeSub(guildId, channelId, channelName, announceChannelId, roleId, customMessage) {
    const stmt = db.prepare(`
      INSERT INTO youtube_subscriptions (guild_id, channel_id, channel_name, announce_channel_id, role_id, custom_message)
      VALUES (@guildId, @channelId, @channelName, @announceChannelId, @roleId, @customMessage)
      ON CONFLICT(guild_id, channel_id) DO UPDATE SET
        channel_name = excluded.channel_name,
        announce_channel_id = excluded.announce_channel_id,
        role_id = excluded.role_id,
        custom_message = excluded.custom_message
    `);
    stmt.run({ guildId, channelId, channelName, announceChannelId, roleId, customMessage });
    db.prepare(`INSERT OR IGNORE INTO youtube_state (channel_id) VALUES (?)`).run(channelId);
  },
  removeYoutubeSub(guildId, channelId) {
    return db.prepare(`DELETE FROM youtube_subscriptions WHERE guild_id = ? AND channel_id = ?`)
      .run(guildId, channelId).changes;
  },
  listYoutubeSubsForGuild(guildId) {
    return db.prepare(`SELECT * FROM youtube_subscriptions WHERE guild_id = ? ORDER BY channel_name`).all(guildId);
  },
  listAllUniqueYoutubeChannels() {
    return db.prepare(`SELECT DISTINCT channel_id FROM youtube_subscriptions`).all().map(r => r.channel_id);
  },
  listGuildSubsForYoutubeChannel(channelId) {
    return db.prepare(`SELECT * FROM youtube_subscriptions WHERE channel_id = ?`).all(channelId);
  },
  getYoutubeState(channelId) {
    return db.prepare(`SELECT * FROM youtube_state WHERE channel_id = ?`).get(channelId);
  },
  setYoutubeState(channelId, lastVideoId) {
    db.prepare(`
      INSERT INTO youtube_state (channel_id, last_video_id, initialized) VALUES (@channelId, @videoId, 1)
      ON CONFLICT(channel_id) DO UPDATE SET last_video_id = excluded.last_video_id, initialized = 1
    `).run({ channelId, videoId: lastVideoId });
  },
  pruneOrphanYoutubeState() {
    db.prepare(`
      DELETE FROM youtube_state WHERE channel_id NOT IN (SELECT DISTINCT channel_id FROM youtube_subscriptions)
    `).run();
  },

  // ---- Reaction roles ----
  addReactionRole(guildId, channelId, messageId, emojiId, emojiName, roleId, dmMessage) {
    db.prepare(`
      INSERT INTO reaction_roles (guild_id, channel_id, message_id, emoji_id, emoji_name, role_id, dm_message)
      VALUES (@guildId, @channelId, @messageId, @emojiId, @emojiName, @roleId, @dmMessage)
      ON CONFLICT(message_id, emoji_id, emoji_name) DO UPDATE SET
        role_id = excluded.role_id,
        dm_message = excluded.dm_message
    `).run({ guildId, channelId, messageId, emojiId, emojiName, roleId, dmMessage });
  },
  removeReactionRole(messageId, emojiId, emojiName) {
    return db.prepare(`
      DELETE FROM reaction_roles
      WHERE message_id = ? AND COALESCE(emoji_id, '') = COALESCE(?, '') AND emoji_name = ?
    `).run(messageId, emojiId, emojiName).changes;
  },
  getReactionRole(messageId, emojiId, emojiName) {
    return db.prepare(`
      SELECT * FROM reaction_roles
      WHERE message_id = ? AND COALESCE(emoji_id, '') = COALESCE(?, '') AND emoji_name = ?
    `).get(messageId, emojiId, emojiName);
  },
  listReactionRolesForMessage(messageId) {
    return db.prepare(`SELECT * FROM reaction_roles WHERE message_id = ?`).all(messageId);
  },
  listReactionRolePanelsForGuild(guildId) {
    return db.prepare(`SELECT DISTINCT message_id, channel_id FROM reaction_roles WHERE guild_id = ?`).all(guildId);
  },
  movePanel(oldMessageId, newMessageId, newChannelId) {
    db.prepare(`
      UPDATE reaction_roles SET message_id = @newMessageId, channel_id = @newChannelId
      WHERE message_id = @oldMessageId
    `).run({ oldMessageId, newMessageId, newChannelId });
  },

  // ---- Welcome config ----
  setWelcomeConfig(guildId, channelId, dmMessage) {
    db.prepare(`
      INSERT INTO guild_welcome_config (guild_id, channel_id, dm_message, enabled)
      VALUES (@guildId, @channelId, @dmMessage, 1)
      ON CONFLICT(guild_id) DO UPDATE SET
        channel_id = excluded.channel_id,
        dm_message = excluded.dm_message,
        enabled = 1
    `).run({ guildId, channelId, dmMessage });
  },
  getWelcomeConfig(guildId) {
    return db.prepare(`SELECT * FROM guild_welcome_config WHERE guild_id = ?`).get(guildId);
  },
setWelcomeEnabled(guildId, enabled) {
    return db.prepare(`UPDATE guild_welcome_config SET enabled = ? WHERE guild_id = ?`)
      .run(enabled ? 1 : 0, guildId).changes;
  },

  // ---- Free games ----
  addFreeGamesSub(guildId, source, channelId) {
    db.prepare(`
      INSERT INTO freegames_subscriptions (guild_id, source, channel_id)
      VALUES (@guildId, @source, @channelId)
      ON CONFLICT(guild_id, source) DO UPDATE SET channel_id = excluded.channel_id
    `).run({ guildId, source, channelId });
  },
  removeFreeGamesSub(guildId, source) {
    return db.prepare(`DELETE FROM freegames_subscriptions WHERE guild_id = ? AND source = ?`)
      .run(guildId, source).changes;
  },
  listFreeGamesSubsForGuild(guildId) {
    return db.prepare(`SELECT * FROM freegames_subscriptions WHERE guild_id = ?`).all(guildId);
  },
  listGuildSubsForFreeGamesSource(source) {
    return db.prepare(`SELECT * FROM freegames_subscriptions WHERE source = ?`).all(source);
  },
  listActiveFreeGamesSources() {
    return db.prepare(`SELECT DISTINCT source FROM freegames_subscriptions`).all().map(r => r.source);
  },
  hasAnnouncedFreeGame(source, externalId) {
    return !!db.prepare(`SELECT 1 FROM freegames_announced WHERE source = ? AND external_id = ?`).get(source, externalId);
  },
markFreeGameAnnounced(source, externalId) {
    db.prepare(`INSERT OR IGNORE INTO freegames_announced (source, external_id) VALUES (?, ?)`).run(source, externalId);
  },

  // ---- Full data purge (called when the bot is removed from a server) ----
  purgeGuildData(guildId) {
    const tx = db.transaction((id) => {
      db.prepare(`DELETE FROM twitch_subscriptions WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM youtube_subscriptions WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM reaction_roles WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM guild_welcome_config WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM freegames_subscriptions WHERE guild_id = ?`).run(id);
    });
    tx(guildId);
    this.pruneOrphanTwitchState();
    this.pruneOrphanYoutubeState();
  },
};
RR_DB_EOF

echo "Writing src/web/api.js..."
cat > src/web/api.js << 'RR_API_EOF'
const express = require('express');
const { PermissionsBitField, ChannelType, EmbedBuilder } = require('discord.js');
const db = require('../db');
const twitchClient = require('../services/twitchClient');
const youtubeClient = require('../services/youtubeClient');
const emojiUtil = require('../utils/emoji');
const { generateWelcomeCard } = require('../utils/welcomeCard');
const { requireAuth, requireGuildAccess } = require('./authMiddleware');

function buildRouter(client) {
  const router = express.Router();
  router.use(requireAuth);

  // ---- Guilds the logged-in user can manage AND the bot is present in ----
  router.get('/guilds', (req, res) => {
    const manageable = req.session.manageableGuildIds || [];
    const guilds = manageable
      .map(id => client.guilds.cache.get(id))
      .filter(Boolean)
      .map(g => ({ id: g.id, name: g.name, icon: g.iconURL({ size: 64 }) }));
    res.json(guilds);
  });

  const guildRouter = express.Router({ mergeParams: true });
  guildRouter.use(requireGuildAccess(client));
  router.use('/guilds/:guildId', guildRouter);

  // ---- Text channels + roles for building dropdowns in the UI ----
  guildRouter.get('/channels', (req, res) => {
    const guild = client.guilds.cache.get(req.params.guildId);
    const me = guild.members.me;
    const channels = guild.channels.cache
      .filter(c => c.type === ChannelType.GuildText && c.permissionsFor(me)?.has(PermissionsBitField.Flags.SendMessages))
      .map(c => ({ id: c.id, name: c.name }))
      .sort((a, b) => a.name.localeCompare(b.name));
    res.json(channels);
  });

  guildRouter.get('/roles', (req, res) => {
    const guild = client.guilds.cache.get(req.params.guildId);
    const roles = guild.roles.cache
      .filter(r => r.id !== guild.id) // exclude @everyone
      .map(r => ({ id: r.id, name: r.name }))
      .sort((a, b) => a.name.localeCompare(b.name));
    res.json(roles);
  });

  // ---- Twitch subscriptions ----
  guildRouter.get('/twitch', (req, res) => {
    res.json(db.listTwitchSubsForGuild(req.params.guildId));
  });

  guildRouter.post('/twitch', async (req, res) => {
    const { username, channelId, roleId, message } = req.body;
    if (!username || !channelId) {
      return res.status(400).json({ error: 'username and channelId are required' });
    }
    if (!process.env.TWITCH_CLIENT_ID || !process.env.TWITCH_CLIENT_SECRET) {
      return res.status(400).json({ error: 'Twitch API credentials are not configured on this bot instance' });
    }
    let user;
    try {
      user = await twitchClient.userExists(username.trim().toLowerCase());
    } catch (err) {
      return res.status(502).json({ error: `Couldn't reach Twitch: ${err.message}` });
    }
    if (!user) {
      return res.status(404).json({ error: `No Twitch user found with username "${username}"` });
    }
    db.addTwitchSub(req.params.guildId, username.trim().toLowerCase(), channelId, roleId || null, message || null);
    res.json({ ok: true, displayName: user.display_name });
  });

  guildRouter.delete('/twitch/:username', (req, res) => {
    const changes = db.removeTwitchSub(req.params.guildId, req.params.username);
    if (changes === 0) return res.status(404).json({ error: 'Not tracked' });
    res.json({ ok: true });
  });

  // ---- YouTube subscriptions ----
  guildRouter.get('/youtube', (req, res) => {
    res.json(db.listYoutubeSubsForGuild(req.params.guildId));
  });

  guildRouter.post('/youtube', async (req, res) => {
    const { channelUrl, channelId: announceChannelId, roleId, message } = req.body;
    if (!channelUrl || !announceChannelId) {
      return res.status(400).json({ error: 'channelUrl and channelId are required' });
    }
    let channelId;
    try {
      channelId = await youtubeClient.resolveChannelId(channelUrl.trim());
    } catch (err) {
      return res.status(502).json({ error: `Couldn't reach YouTube: ${err.message}` });
    }
    if (!channelId) {
      return res.status(404).json({ error: `Couldn't find a YouTube channel for "${channelUrl}"` });
    }
    let result;
    try {
      result = await youtubeClient.getLatestVideo(channelId);
    } catch (err) {
      return res.status(502).json({ error: `Found the channel but couldn't read its feed: ${err.message}` });
    }
    const channelName = result?.channelName || channelUrl;
    db.addYoutubeSub(req.params.guildId, channelId, channelName, announceChannelId, roleId || null, message || null);

    const state = db.getYoutubeState(channelId);
    if (result?.latest && (!state || !state.initialized)) {
      db.setYoutubeState(channelId, result.latest.videoId);
    }
    res.json({ ok: true, channelName });
  });

  guildRouter.delete('/youtube/:channelId', (req, res) => {
    const changes = db.removeYoutubeSub(req.params.guildId, req.params.channelId);
    if (changes === 0) return res.status(404).json({ error: 'Not tracked' });
    res.json({ ok: true });
  });

  // ---- Free games ----
  guildRouter.get('/freegames', (req, res) => {
    res.json(db.listFreeGamesSubsForGuild(req.params.guildId));
  });

  guildRouter.post('/freegames', (req, res) => {
    const { source, channelId } = req.body;
    if (!['steam', 'gog', 'epic'].includes(source) || !channelId) {
      return res.status(400).json({ error: 'source (steam|gog|epic) and channelId are required' });
    }
    db.addFreeGamesSub(req.params.guildId, source, channelId);
    res.json({ ok: true });
  });

  guildRouter.delete('/freegames/:source', (req, res) => {
    const changes = db.removeFreeGamesSub(req.params.guildId, req.params.source);
    if (changes === 0) return res.status(404).json({ error: 'Not enabled' });
    res.json({ ok: true });
  });

  // ---- Welcome ----
  guildRouter.get('/welcome', (req, res) => {
    res.json(db.getWelcomeConfig(req.params.guildId) || null);
  });

  guildRouter.post('/welcome', (req, res) => {
    const { channelId, dmMessage } = req.body;
    if (!channelId) return res.status(400).json({ error: 'channelId is required' });
    db.setWelcomeConfig(req.params.guildId, channelId, dmMessage || null);
    res.json({ ok: true });
  });

  guildRouter.post('/welcome/enabled', (req, res) => {
    const { enabled } = req.body;
    const changes = db.setWelcomeEnabled(req.params.guildId, !!enabled);
    if (changes === 0) return res.status(404).json({ error: 'Welcome not set up yet' });
    res.json({ ok: true });
  });

  guildRouter.post('/welcome/preview', async (req, res) => {
    const config = db.getWelcomeConfig(req.params.guildId);
    if (!config) return res.status(404).json({ error: 'Welcome not set up yet' });

    const guild = client.guilds.cache.get(req.params.guildId);
    const member = await guild.members.fetch(req.session.user.id).catch(() => null);
    if (!member) return res.status(404).json({ error: "Couldn't find your member record in this server" });

    try {
      const buffer = await generateWelcomeCard({
        avatarUrl: member.displayAvatarURL({ extension: 'png', size: 256 }),
        username: member.user.username,
        guildName: guild.name,
        memberCount: guild.memberCount,
      });
      res.set('Content-Type', 'image/png');
      res.send(buffer);
    } catch (err) {
      res.status(500).json({ error: `Failed to generate preview: ${err.message}` });
    }
  });

  // ---- Reaction roles ----
  guildRouter.get('/reactionroles/panels', (req, res) => {
    const panels = db.listReactionRolePanelsForGuild(req.params.guildId);
    const withMappings = panels.map(p => ({
      ...p,
      mappings: db.listReactionRolesForMessage(p.message_id),
    }));
    res.json(withMappings);
  });

  guildRouter.post('/reactionroles/panels', async (req, res) => {
    const { channelId, title, description } = req.body;
    if (!channelId || !title || !description) {
      return res.status(400).json({ error: 'channelId, title, and description are required' });
    }
    const channel = client.channels.cache.get(channelId);
    if (!channel) return res.status(404).json({ error: 'Channel not found' });

    const embed = new EmbedBuilder().setColor(0x5865f2).setTitle(title).setDescription(description);
    const message = await channel.send({ embeds: [embed] }).catch(() => null);
    if (!message) return res.status(502).json({ error: "Couldn't post in that channel — check my permissions there" });

    res.json({ ok: true, messageId: message.id, channelId });
  });

  guildRouter.patch('/reactionroles/panels/:messageId', async (req, res) => {
    const { channelId, title, description, newChannelId } = req.body;
    if (!channelId) return res.status(400).json({ error: 'channelId (current channel) is required' });
    if (!title && !description && !newChannelId) {
      return res.status(400).json({ error: 'Provide at least a title, description, or newChannelId to change' });
    }

    const channel = client.channels.cache.get(channelId);
    const message = await channel?.messages.fetch(req.params.messageId).catch(() => null);
    if (!message) return res.status(404).json({ error: 'Panel message not found' });
    if (message.author.id !== client.user.id) {
      return res.status(400).json({ error: "That message wasn't posted by me, so I can't edit it" });
    }
    const existing = message.embeds[0];
    if (!existing) return res.status(400).json({ error: "That message doesn't look like a reaction role panel" });

    const embed = EmbedBuilder.from(existing)
      .setTitle(title || existing.title)
      .setDescription(description || existing.description);

    const isMoving = newChannelId && newChannelId !== channelId;

    if (!isMoving) {
      const edited = await message.edit({ embeds: [embed] }).catch(() => null);
      if (!edited) return res.status(502).json({ error: "Couldn't edit that message" });
      return res.json({ ok: true, messageId: message.id, channelId });
    }

    const newChannel = client.channels.cache.get(newChannelId);
    if (!newChannel) return res.status(404).json({ error: 'Target channel not found' });

    const pairs = db.listReactionRolesForMessage(req.params.messageId);

    const newMessage = await newChannel.send({ embeds: [embed] }).catch(() => null);
    if (!newMessage) return res.status(502).json({ error: "Couldn't post in the new channel — check my permissions there" });

    const failedEmoji = [];
    for (const pair of pairs) {
      const emoji = { id: pair.emoji_id, name: pair.emoji_name };
      try {
        await newMessage.react(emojiUtil.toReactString(emoji));
      } catch {
        failedEmoji.push(emojiUtil.displayEmoji(emoji));
      }
    }

    db.movePanel(req.params.messageId, newMessage.id, newChannelId);
    await message.delete().catch(() => {});

    res.json({ ok: true, messageId: newMessage.id, channelId: newChannelId, failedEmoji });
  });

  guildRouter.post('/reactionroles/panels/:messageId/mappings', async (req, res) => {
    const { channelId, emoji, roleId } = req.body;
    if (!channelId || !emoji || !roleId) {
      return res.status(400).json({ error: 'channelId, emoji, and roleId are required' });
    }

    const parsedEmoji = emojiUtil.parseEmojiInput(emoji);
    if (!parsedEmoji) return res.status(400).json({ error: `Couldn't understand "${emoji}" as an emoji` });

    const guild = client.guilds.cache.get(req.params.guildId);
    const role = guild.roles.cache.get(roleId);
    if (!role) return res.status(404).json({ error: 'Role not found' });
    if (role.managed || role.id === guild.id) {
      return res.status(400).json({ error: "Can't use that role — it's managed by an integration or is @everyone" });
    }
    if (guild.members.me.roles.highest.position <= role.position) {
      return res.status(400).json({ error: `I can't assign "${role.name}" — move my role above it in Server Settings → Roles` });
    }

    const channel = client.channels.cache.get(channelId);
    const message = await channel?.messages.fetch(req.params.messageId).catch(() => null);
    if (!message) return res.status(404).json({ error: 'Panel message not found' });

    try {
      await message.react(emojiUtil.toReactString(parsedEmoji));
    } catch (err) {
      return res.status(502).json({ error: `Couldn't react with that emoji: ${err.message}` });
    }

    db.addReactionRole(req.params.guildId, channelId, req.params.messageId, parsedEmoji.id, parsedEmoji.name, roleId, null);
    res.json({ ok: true });
  });

  guildRouter.delete('/reactionroles/panels/:messageId/mappings', async (req, res) => {
    const emojiId = req.query.emojiId || null;
    const emojiName = req.query.emojiName;
    if (!emojiName) return res.status(400).json({ error: 'emojiName query param is required' });

    const changes = db.removeReactionRole(req.params.messageId, emojiId, emojiName);
    if (changes === 0) return res.status(404).json({ error: 'Not found' });
    res.json({ ok: true });
  });

  return router;
}

module.exports = buildRouter;
RR_API_EOF

echo "Writing src/web/public/index.html..."
cat > src/web/public/index.html << 'RR_HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>VVC Skald Bot</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@500&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #0e0f13;
    --panel: #16181f;
    --panel-border: #262935;
    --text: #e8e9ee;
    --text-dim: #8a8d9a;
    --twitch: #9146ff;
    --twitch-dim: #9146ff33;
    --youtube: #ff3b3b;
    --youtube-dim: #ff3b3b33;
    --ok: #3ddc97;
    --err: #ff5c5c;
    --radius: 10px;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: 'Inter', sans-serif;
    min-height: 100vh;
  }
  h1, h2, h3, .display { font-family: 'Space Grotesk', sans-serif; }
  .mono { font-family: 'JetBrains Mono', monospace; }

  /* --- Login screen --- */
  #loginScreen {
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-direction: column;
    gap: 28px;
    text-align: center;
    padding: 24px;
  }
  .on-air {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 12px;
    letter-spacing: 0.12em;
    color: var(--youtube);
    border: 1px solid var(--youtube-dim);
    background: var(--youtube-dim);
    padding: 6px 12px;
    border-radius: 999px;
  }
  .on-air .dot {
    width: 7px; height: 7px; border-radius: 50%;
    background: var(--youtube);
    animation: pulse 1.6s infinite ease-in-out;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; box-shadow: 0 0 0 0 var(--youtube-dim); }
    50% { opacity: 0.5; }
  }
  #loginScreen h1 { font-size: 40px; margin: 0; }
  #loginScreen p { color: var(--text-dim); max-width: 420px; margin: 0; }
  .btn-discord {
    display: inline-flex; align-items: center; gap: 10px;
    background: #5865f2; color: white; border: none;
    padding: 14px 26px; border-radius: var(--radius);
    font-family: 'Space Grotesk', sans-serif; font-weight: 600; font-size: 15px;
    cursor: pointer; text-decoration: none;
    transition: transform 0.15s ease, background 0.15s ease;
  }
  .btn-discord:hover { background: #4954c4; transform: translateY(-1px); }

  /* --- App shell (sidebar layout) --- */
  #app { display: none; }
  .app-shell { display: flex; min-height: 100vh; }

  .sidebar {
    width: 230px; flex-shrink: 0; background: var(--panel); border-right: 1px solid var(--panel-border);
    padding: 20px 16px; display: flex; flex-direction: column; gap: 20px;
  }
  .sidebar-brand { display: flex; align-items: center; gap: 8px; padding: 0 4px; }
  .sidebar-brand .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok); }
  .sidebar-brand span.display { font-size: 15px; font-weight: 600; }

  select#guildSelect {
    background: #1c1f28; color: var(--text); border: 1px solid var(--panel-border);
    padding: 10px 12px; border-radius: var(--radius); font-family: 'Space Grotesk', sans-serif;
    font-size: 13px; width: 100%;
  }

  .nav-items { display: flex; flex-direction: column; gap: 2px; }
  .nav-item {
    display: flex; align-items: center; gap: 8px;
    background: transparent; border: none; border-left: 3px solid transparent; color: var(--text-dim);
    text-align: left; padding: 10px 10px; border-radius: 6px; cursor: pointer;
    font-family: 'Space Grotesk', sans-serif; font-size: 13px; width: 100%;
  }
  .nav-item .swatch { width: 8px; height: 8px; border-radius: 2px; background: var(--nav-accent, var(--text-dim)); flex-shrink: 0; }
  .nav-item:hover { background: #1c1f28; color: var(--text); }
  .nav-item.active { background: #1c1f28; color: var(--text); border-left-color: var(--nav-accent, var(--twitch)); }

  .sidebar-footer { margin-top: auto; display: flex; gap: 10px; padding: 0 4px; }
  .sidebar-footer a { color: var(--text-dim); font-size: 11px; text-decoration: none; }
  .sidebar-footer a:hover { color: var(--text); text-decoration: underline; }

  .main-area { flex: 1; min-width: 0; }
  .main-area .content { max-width: 780px; margin: 0 auto; padding: 24px; }

  @media (max-width: 800px) {
    .app-shell { flex-direction: column; }
    .sidebar { width: 100%; flex-direction: row; align-items: center; padding: 12px 16px; gap: 14px; overflow-x: auto; }
    .sidebar-brand { flex-shrink: 0; }
    select#guildSelect { width: auto; flex-shrink: 0; }
    .nav-items { flex-direction: row; flex-shrink: 0; }
    .nav-item { white-space: nowrap; }
    .sidebar-footer { margin-top: 0; margin-left: auto; flex-shrink: 0; }
  }

  header.topbar {
    display: flex; align-items: center; justify-content: flex-end;
    padding: 16px 24px;
    border-bottom: 1px solid var(--panel-border);
    flex-wrap: wrap; gap: 12px;
  }
  .topbar-right { display: flex; align-items: center; gap: 18px; flex-wrap: wrap; }
  .support-note { display: flex; align-items: center; gap: 8px; }
  .support-note span { font-size: 12px; color: var(--text-dim); }
  @media (max-width: 760px) { .support-note span { display: none; } }
  .support-icon {
    width: 28px; height: 28px; border-radius: 50%; display: flex; align-items: center; justify-content: center;
    background: #1c1f28; border: 1px solid var(--panel-border); color: var(--text-dim);
    transition: color 0.15s ease, border-color 0.15s ease;
  }
  .support-icon:hover { color: var(--text); border-color: var(--text-dim); }
  .support-icon svg { width: 15px; height: 15px; }
  .user-area { display: flex; align-items: center; gap: 12px; }
  .user-area img { width: 28px; height: 28px; border-radius: 50%; }
  .user-area .name { font-size: 14px; color: var(--text-dim); }
  .btn-ghost {
    background: transparent; border: 1px solid var(--panel-border); color: var(--text-dim);
    padding: 7px 14px; border-radius: 8px; font-family: inherit; font-size: 13px; cursor: pointer;
  }
  .btn-ghost:hover { color: var(--text); border-color: var(--text-dim); }

  .module-page { display: none; }
  .module-page.active { display: block; }

  .panel {
    background: var(--panel); border: 1px solid var(--panel-border);
    border-radius: var(--radius); padding: 20px; border-top: 3px solid var(--accent);
  }
  .panel.twitch { --accent: var(--twitch); }
  .panel.youtube { --accent: var(--youtube); }
  .panel h2 {
    display: flex; align-items: center; gap: 8px;
    font-size: 16px; margin: 0 0 16px;
  }
  .panel h2 .swatch { width: 10px; height: 10px; border-radius: 3px; background: var(--accent); }

  .sub-item {
    display: flex; align-items: center; justify-content: space-between;
    padding: 10px 12px; background: #1c1f28; border-radius: 8px; margin-bottom: 8px;
    font-size: 13px;
  }
  .sub-item .meta { color: var(--text-dim); font-size: 12px; margin-top: 2px; }
  .sub-item button {
    background: transparent; border: none; color: var(--err); cursor: pointer; font-size: 12px;
    padding: 4px 8px;
  }
  .empty-state { color: var(--text-dim); font-size: 13px; padding: 12px 0; }

  form.add-form { margin-top: 16px; display: flex; flex-direction: column; gap: 10px; }
  form.add-form input, form.add-form select {
    background: #1c1f28; border: 1px solid var(--panel-border); color: var(--text);
    padding: 9px 12px; border-radius: 8px; font-family: inherit; font-size: 13px; width: 100%;
  }
  form.add-form button {
    background: var(--accent); border: none; color: #0e0f13; font-weight: 600;
    padding: 10px; border-radius: 8px; cursor: pointer; font-family: 'Space Grotesk', sans-serif;
    font-size: 13px; margin-top: 4px;
  }
  form.add-form button:hover { opacity: 0.9; }
  form.add-form button:disabled { opacity: 0.5; cursor: not-allowed; }

  #toast {
    position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%);
    background: var(--panel); border: 1px solid var(--panel-border); color: var(--text);
    padding: 12px 18px; border-radius: 8px; font-size: 13px; display: none; max-width: 90vw;
  }
  #toast.ok { border-color: var(--ok); color: var(--ok); }
  #toast.err { border-color: var(--err); color: var(--err); }

  .source-cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
  @media (max-width: 700px) { .source-cards { grid-template-columns: 1fr; } }
  .source-card {
    background: #1c1f28; border: 1px solid var(--panel-border); border-radius: 10px; padding: 14px;
  }
  .source-card .src-name { font-family: 'Space Grotesk', sans-serif; font-weight: 600; font-size: 14px; margin-bottom: 8px; }
  .source-card .meta { color: var(--text-dim); font-size: 12px; margin-bottom: 10px; }
  .source-card select { width: 100%; margin-bottom: 8px; }
  .source-card button { width: 100%; }
  .btn-remove-inline {
    background: transparent; border: 1px solid var(--err); color: var(--err);
    padding: 8px; border-radius: 8px; cursor: pointer; font-size: 12px; width: 100%;
  }
  .btn-enable-inline {
    background: var(--ok); border: none; color: #0e0f13; font-weight: 600;
    padding: 8px; border-radius: 8px; cursor: pointer; font-size: 12px; width: 100%;
  }

  .toggle-row { display: flex; align-items: center; gap: 10px; margin: 12px 0; font-size: 13px; }
  .toggle-switch { position: relative; width: 40px; height: 22px; flex-shrink: 0; }
  .toggle-switch input { opacity: 0; width: 0; height: 0; }
  .toggle-slider {
    position: absolute; cursor: pointer; inset: 0; background: #3a3d4a; border-radius: 22px; transition: 0.2s;
  }
  .toggle-slider::before {
    content: ""; position: absolute; width: 16px; height: 16px; left: 3px; top: 3px;
    background: white; border-radius: 50%; transition: 0.2s;
  }
  .toggle-switch input:checked + .toggle-slider { background: var(--ok); }
  .toggle-switch input:checked + .toggle-slider::before { transform: translateX(18px); }

  textarea.welcome-dm {
    background: #1c1f28; border: 1px solid var(--panel-border); color: var(--text);
    padding: 9px 12px; border-radius: 8px; font-family: inherit; font-size: 13px; width: 100%;
    min-height: 70px; resize: vertical;
  }
  #welcomePreviewImg { width: 100%; border-radius: 10px; margin-top: 12px; display: none; }

  .rr-panel { background: #1c1f28; border-radius: 8px; padding: 12px; margin-bottom: 12px; }
  .rr-panel .rr-panel-header { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 8px; }
  .rr-panel .rr-panel-title { font-size: 12px; color: var(--text-dim); }
  .rr-panel .rr-edit-btn { flex-shrink: 0; width: auto; padding: 5px 10px; font-size: 12px; background: transparent; border: 1px solid var(--panel-border); }
  .rr-edit-form { display: flex; flex-direction: column; gap: 6px; margin-bottom: 10px; padding: 10px; background: #14161d; border-radius: 6px; }
  .rr-edit-form .rr-edit-actions { display: flex; gap: 6px; }
  .rr-edit-form .rr-edit-actions button { flex-shrink: 0; width: auto; padding: 8px 14px; }
  .rr-edit-form .rr-edit-actions button.cancel { background: transparent; border: 1px solid var(--panel-border); }
  .rr-mapping-row {
    display: flex; align-items: center; justify-content: space-between;
    padding: 6px 0; font-size: 13px; border-top: 1px solid var(--panel-border);
  }
  .rr-mapping-row:first-of-type { border-top: none; }
  .rr-add-mapping { display: flex; gap: 6px; margin-top: 10px; }
  .rr-add-mapping input, .rr-add-mapping select { flex: 1; min-width: 0; }
  .rr-add-mapping button { flex-shrink: 0; width: auto; padding: 9px 14px; }
</style>
</head>
<body>

  <div id="loginScreen">
    <div class="on-air"><span class="dot"></span> WAITING FOR SIGNAL</div>
    <h1>VVC Skald Bot</h1>
    <p>Manage Twitch/YouTube announcements, free game alerts, reaction roles, and welcome messages — no command line required.</p>
    <a class="btn-discord" href="/auth/discord/login">Continue with Discord</a>
    <div style="margin-top: 8px;">
      <a href="/tos" style="color: var(--text-dim); font-size: 12px; margin-right: 16px;">Terms of Service</a>
      <a href="/privacy" style="color: var(--text-dim); font-size: 12px;">Privacy Policy</a>
    </div>
  </div>

  <div id="app">
    <div class="app-shell">
      <nav class="sidebar">
        <div class="sidebar-brand"><span class="dot"></span><span class="display">VVC Skald Bot</span></div>
        <select id="guildSelect"></select>
        <div class="nav-items">
          <button class="nav-item active" data-module="twitch" style="--nav-accent: #9146ff;"><span class="swatch"></span>Twitch</button>
          <button class="nav-item" data-module="youtube" style="--nav-accent: #ff3b3b;"><span class="swatch"></span>YouTube</button>
          <button class="nav-item" data-module="freegames" style="--nav-accent: #66c0f4;"><span class="swatch"></span>Free games</button>
          <button class="nav-item" data-module="welcome" style="--nav-accent: #3ddc97;"><span class="swatch"></span>Welcome</button>
          <button class="nav-item" data-module="reactionroles" style="--nav-accent: #9146ff;"><span class="swatch"></span>Reaction roles</button>
        </div>
        <div class="sidebar-footer">
          <a href="/tos" target="_blank">Terms</a>
          <a href="/privacy" target="_blank">Privacy</a>
        </div>
      </nav>

      <div class="main-area">
        <header class="topbar">
          <div class="topbar-right">
            <div class="support-note">
              <span>If you like the bot, donations are always appreciated</span>
              <a class="support-icon" href="https://paypal.me/MorrigahnGaming" target="_blank" rel="noopener" title="Donate via PayPal">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M9 8h4a2.5 2.5 0 0 1 0 5H9V8z"/><path d="M9 13v4"/></svg>
              </a>
              <a class="support-icon" href="https://ko-fi.com/sgt_morrigahngaming" target="_blank" rel="noopener" title="Support on Ko-fi">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h13a3 3 0 0 1 0 6h-1"/><path d="M4 8v8a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2v-2"/><path d="M8 3c-.5 1 -1 1.5 0 3"/><path d="M11 3c-.5 1 -1 1.5 0 3"/></svg>
              </a>
            </div>
            <div class="user-area">
              <img id="userAvatar" src="" alt="" />
              <span class="name" id="userName"></span>
              <button class="btn-ghost" id="logoutBtn">Log out</button>
            </div>
          </div>
        </header>

        <div class="content">
          <section class="module-page active" id="module-twitch">
            <section class="panel twitch">
              <h2><span class="swatch"></span>Twitch streamers</h2>
              <div id="twitchList"></div>
              <form class="add-form" id="twitchForm">
                <input type="text" id="twitchUsername" placeholder="Twitch username" required />
                <select id="twitchChannel" required></select>
                <select id="twitchRole"><option value="">No role ping</option></select>
                <input type="text" id="twitchMessage" placeholder="Custom message (optional) — {streamer} {title} {game} {url}" />
                <button type="submit">Track streamer</button>
              </form>
            </section>
          </section>

          <section class="module-page" id="module-youtube">
            <section class="panel youtube">
              <h2><span class="swatch"></span>YouTube channels</h2>
              <div id="youtubeList"></div>
              <form class="add-form" id="youtubeForm">
                <input type="text" id="youtubeUrl" placeholder="Channel @handle or URL" required />
                <select id="youtubeChannel" required></select>
                <select id="youtubeRole"><option value="">No role ping</option></select>
                <input type="text" id="youtubeMessage" placeholder="Custom message (optional) — {channel} {title} {url}" />
                <button type="submit">Track channel</button>
              </form>
            </section>
          </section>

          <section class="module-page" id="module-freegames">
            <section class="panel" style="--accent: #66c0f4;">
              <h2><span class="swatch"></span>Free games</h2>
              <div class="source-cards" id="freeGamesCards"></div>
            </section>
          </section>

          <section class="module-page" id="module-welcome">
            <section class="panel" style="--accent: #3ddc97;">
              <h2><span class="swatch"></span>Welcome new members</h2>
              <form class="add-form" id="welcomeForm">
                <select id="welcomeChannel" required></select>
                <textarea class="welcome-dm" id="welcomeDm" placeholder="Optional DM message — {user} {server}"></textarea>
                <button type="submit">Save welcome settings</button>
              </form>
              <div class="toggle-row" id="welcomeToggleRow" style="display:none;">
                <label class="toggle-switch">
                  <input type="checkbox" id="welcomeEnabledToggle" />
                  <span class="toggle-slider"></span>
                </label>
                <span id="welcomeToggleLabel">Welcome messages are on</span>
              </div>
              <button class="btn-ghost" id="welcomePreviewBtn" type="button" style="margin-top: 10px;">Preview card</button>
              <img id="welcomePreviewImg" alt="Welcome card preview" />
            </section>
          </section>

          <section class="module-page" id="module-reactionroles">
            <section class="panel" style="--accent: #9146ff;">
              <h2><span class="swatch"></span>Reaction roles</h2>
              <div id="rrPanelsList"></div>
              <form class="add-form" id="rrCreateForm">
                <select id="rrChannel" required></select>
                <input type="text" id="rrTitle" placeholder="Panel title" required />
                <input type="text" id="rrDescription" placeholder="Panel description" required />
                <button type="submit">Create new panel</button>
              </form>
            </section>
          </section>
        </div>
      </div>
    </div>
  </div>

  <div id="toast"></div>

<script>
  const state = { guildId: null };

  function toast(msg, kind) {
    const el = document.getElementById('toast');
    el.textContent = msg;
    el.className = kind || '';
    el.style.display = 'block';
    setTimeout(() => { el.style.display = 'none'; }, 4000);
  }

  async function api(path, opts) {
    const res = await fetch('/api' + path, {
      headers: { 'Content-Type': 'application/json' },
      ...opts,
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || 'Request failed');
    return body;
  }

  async function init() {
    let me;
    try {
      me = await fetch('/api/me').then(r => r.ok ? r.json() : Promise.reject());
    } catch {
      document.getElementById('loginScreen').style.display = 'flex';
      return;
    }
    document.getElementById('loginScreen').style.display = 'none';
    document.getElementById('app').style.display = 'block';
    document.getElementById('userName').textContent = me.username;
    document.getElementById('userAvatar').src = me.avatar
      ? `https://cdn.discordapp.com/avatars/${me.id}/${me.avatar}.png?size=64`
      : `https://cdn.discordapp.com/embed/avatars/0.png`;

    const guilds = await api('/guilds');
    const select = document.getElementById('guildSelect');
    if (guilds.length === 0) {
      select.innerHTML = '<option>No manageable servers with this bot installed</option>';
      return;
    }
    select.innerHTML = guilds.map(g => `<option value="${g.id}">${g.name}</option>`).join('');
    select.addEventListener('change', () => loadGuild(select.value));
    state.guildId = guilds[0].id;
    await loadGuild(state.guildId);
  }

  async function loadGuild(guildId) {
    state.guildId = guildId;
    const [channels, roles, twitchSubs, youtubeSubs, freeGamesSubs, welcomeConfig, rrPanels] = await Promise.all([
      api(`/guilds/${guildId}/channels`),
      api(`/guilds/${guildId}/roles`),
      api(`/guilds/${guildId}/twitch`),
      api(`/guilds/${guildId}/youtube`),
      api(`/guilds/${guildId}/freegames`),
      api(`/guilds/${guildId}/welcome`),
      api(`/guilds/${guildId}/reactionroles/panels`),
    ]);
    state.channels = channels;
    state.roles = roles;

    const chanOpts = channels.map(c => `<option value="${c.id}">#${c.name}</option>`).join('');
    document.getElementById('twitchChannel').innerHTML = chanOpts;
    document.getElementById('youtubeChannel').innerHTML = chanOpts;
    document.getElementById('welcomeChannel').innerHTML = chanOpts;
    document.getElementById('rrChannel').innerHTML = chanOpts;

    const roleOpts = '<option value="">No role ping</option>' + roles.map(r => `<option value="${r.id}">@${r.name}</option>`).join('');
    document.getElementById('twitchRole').innerHTML = roleOpts;
    document.getElementById('youtubeRole').innerHTML = roleOpts;

    renderTwitchList(twitchSubs, channels, roles);
    renderYoutubeList(youtubeSubs, channels, roles);
    renderFreeGames(freeGamesSubs, channels);
    renderWelcome(welcomeConfig, channels);
    renderReactionRoles(rrPanels, channels, roles);
  }

  function channelName(channels, id) { return channels.find(c => c.id === id)?.name || id; }
  function roleName(roles, id) { return id ? (roles.find(r => r.id === id)?.name || id) : null; }

  function renderTwitchList(subs, channels, roles) {
    const el = document.getElementById('twitchList');
    if (subs.length === 0) { el.innerHTML = '<div class="empty-state">No streamers tracked yet.</div>'; return; }
    el.innerHTML = subs.map(s => `
      <div class="sub-item">
        <div>
          <div>${s.streamer_login}</div>
          <div class="meta">#${channelName(channels, s.announce_channel_id)}${s.role_id ? ' • @' + roleName(roles, s.role_id) : ''}</div>
        </div>
        <button data-username="${s.streamer_login}">Remove</button>
      </div>
    `).join('');
    el.querySelectorAll('button').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          await api(`/guilds/${state.guildId}/twitch/${btn.dataset.username}`, { method: 'DELETE' });
          toast(`Stopped tracking ${btn.dataset.username}`, 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
  }

  function renderYoutubeList(subs, channels, roles) {
    const el = document.getElementById('youtubeList');
    if (subs.length === 0) { el.innerHTML = '<div class="empty-state">No channels tracked yet.</div>'; return; }
    el.innerHTML = subs.map(s => `
      <div class="sub-item">
        <div>
          <div>${s.channel_name || s.channel_id}</div>
          <div class="meta">#${channelName(channels, s.announce_channel_id)}${s.role_id ? ' • @' + roleName(roles, s.role_id) : ''}</div>
        </div>
        <button data-id="${s.channel_id}">Remove</button>
      </div>
    `).join('');
    el.querySelectorAll('button').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          await api(`/guilds/${state.guildId}/youtube/${btn.dataset.id}`, { method: 'DELETE' });
          toast('Stopped tracking channel', 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
  }

  // ---- Free games ----
  const FREEGAMES_SOURCES = [
    { key: 'steam', label: 'Steam' },
    { key: 'gog', label: 'GOG' },
    { key: 'epic', label: 'Epic Games' },
  ];

  function renderFreeGames(subs, channels) {
    const el = document.getElementById('freeGamesCards');
    const chanOpts = channels.map(c => `<option value="${c.id}">#${c.name}</option>`).join('');

    el.innerHTML = FREEGAMES_SOURCES.map(({ key, label }) => {
      const sub = subs.find(s => s.source === key);
      if (sub) {
        return `
          <div class="source-card">
            <div class="src-name">${label}</div>
            <div class="meta">Posting in #${channelName(channels, sub.channel_id)}</div>
            <button class="btn-remove-inline" data-source="${key}" data-action="disable">Turn off</button>
          </div>
        `;
      }
      return `
        <div class="source-card">
          <div class="src-name">${label}</div>
          <div class="meta">Not enabled</div>
          <select data-source="${key}" class="fg-channel-select">${chanOpts}</select>
          <button class="btn-enable-inline" data-source="${key}" data-action="enable">Turn on</button>
        </div>
      `;
    }).join('');

    el.querySelectorAll('button[data-action="enable"]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const source = btn.dataset.source;
        const select = el.querySelector(`select[data-source="${source}"]`);
        try {
          await api(`/guilds/${state.guildId}/freegames`, { method: 'POST', body: JSON.stringify({ source, channelId: select.value }) });
          toast(`${source} free games turned on`, 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
    el.querySelectorAll('button[data-action="disable"]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const source = btn.dataset.source;
        try {
          await api(`/guilds/${state.guildId}/freegames/${source}`, { method: 'DELETE' });
          toast(`${source} free games turned off`, 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
  }

  // ---- Welcome ----
  function renderWelcome(config, channels) {
    const toggleRow = document.getElementById('welcomeToggleRow');
    const toggle = document.getElementById('welcomeEnabledToggle');
    const toggleLabel = document.getElementById('welcomeToggleLabel');

    if (config) {
      document.getElementById('welcomeChannel').value = config.channel_id;
      document.getElementById('welcomeDm').value = config.dm_message || '';
      toggleRow.style.display = 'flex';
      toggle.checked = !!config.enabled;
      toggleLabel.textContent = config.enabled ? 'Welcome messages are on' : 'Welcome messages are off';
    } else {
      toggleRow.style.display = 'none';
    }
  }

  document.getElementById('welcomeEnabledToggle').addEventListener('change', async (e) => {
    try {
      await api(`/guilds/${state.guildId}/welcome/enabled`, { method: 'POST', body: JSON.stringify({ enabled: e.target.checked }) });
      document.getElementById('welcomeToggleLabel').textContent = e.target.checked ? 'Welcome messages are on' : 'Welcome messages are off';
      toast(e.target.checked ? 'Welcome messages turned on' : 'Welcome messages turned off', 'ok');
    } catch (err) { toast(err.message, 'err'); e.target.checked = !e.target.checked; }
  });

  document.getElementById('welcomePreviewBtn').addEventListener('click', async (e) => {
    const btn = e.target;
    btn.disabled = true;
    btn.textContent = 'Generating...';
    try {
      const res = await fetch(`/api/guilds/${state.guildId}/welcome/preview`, { method: 'POST' });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || 'Preview failed');
      }
      const blob = await res.blob();
      const img = document.getElementById('welcomePreviewImg');
      img.src = URL.createObjectURL(blob);
      img.style.display = 'block';
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
    btn.textContent = 'Preview card';
  });

  // ---- Reaction roles ----
  function renderReactionRoles(panels, channels, roles) {
    const el = document.getElementById('rrPanelsList');
    if (panels.length === 0) { el.innerHTML = '<div class="empty-state">No reaction role panels yet — create one below.</div>'; return; }

    el.innerHTML = panels.map(p => `
      <div class="rr-panel" data-message-id="${p.message_id}" data-channel-id="${p.channel_id}">
        <div class="rr-panel-header">
          <div class="rr-panel-title">Panel in #${channelName(channels, p.channel_id)} — message ID ${p.message_id}</div>
          <button type="button" class="rr-edit-btn" data-action="toggle-edit">Edit</button>
        </div>
        <div class="rr-edit-form" style="display:none;">
          <input type="text" class="rr-edit-title" placeholder="New title (leave blank to keep current)" />
          <input type="text" class="rr-edit-description" placeholder="New description (leave blank to keep current)" />
          <select class="rr-edit-channel">
            ${channels.map(c => `<option value="${c.id}" ${c.id === p.channel_id ? 'selected' : ''}>#${c.name}</option>`).join('')}
          </select>
          <div class="rr-edit-actions">
            <button type="button" class="rr-edit-save">Save</button>
            <button type="button" class="cancel" data-action="toggle-edit">Cancel</button>
          </div>
        </div>
        <div class="rr-mappings">
          ${p.mappings.map(m => `
            <div class="rr-mapping-row">
              <span>${m.emoji_id ? `[custom:${m.emoji_name}]` : m.emoji_name} → @${roleName(roles, m.role_id)}</span>
              <button data-message-id="${p.message_id}" data-emoji-id="${m.emoji_id || ''}" data-emoji-name="${m.emoji_name}">Remove</button>
            </div>
          `).join('') || '<div class="empty-state">No emoji-role pairs yet.</div>'}
        </div>
        <div class="rr-add-mapping">
          <input type="text" placeholder="Emoji" class="rr-emoji-input" />
          <select class="rr-role-select">${roles.map(r => `<option value="${r.id}">@${r.name}</option>`).join('')}</select>
          <button type="button" class="rr-add-btn">Add</button>
        </div>
      </div>
    `).join('');

    el.querySelectorAll('[data-action="toggle-edit"]').forEach(btn => {
      btn.addEventListener('click', () => {
        const form = btn.closest('.rr-panel').querySelector('.rr-edit-form');
        form.style.display = form.style.display === 'none' ? 'flex' : 'none';
      });
    });

    el.querySelectorAll('.rr-edit-save').forEach(btn => {
      btn.addEventListener('click', async () => {
        const panelEl = btn.closest('.rr-panel');
        const title = panelEl.querySelector('.rr-edit-title').value.trim();
        const description = panelEl.querySelector('.rr-edit-description').value.trim();
        const newChannelId = panelEl.querySelector('.rr-edit-channel').value;
        const currentChannelId = panelEl.dataset.channelId;

        const body = { channelId: currentChannelId };
        if (title) body.title = title;
        if (description) body.description = description;
        if (newChannelId !== currentChannelId) body.newChannelId = newChannelId;

        if (!body.title && !body.description && !body.newChannelId) {
          toast('Change a title, description, or channel first', 'err');
          return;
        }

        btn.disabled = true;
        try {
          const result = await api(`/guilds/${state.guildId}/reactionroles/panels/${panelEl.dataset.messageId}`, {
            method: 'PATCH',
            body: JSON.stringify(body),
          });
          if (result.failedEmoji && result.failedEmoji.length > 0) {
            toast(`Panel moved, but couldn't re-add: ${result.failedEmoji.join(', ')}`, 'err');
          } else {
            toast('Panel updated', 'ok');
          }
          loadGuild(state.guildId);
        } catch (err) {
          toast(err.message, 'err');
        } finally {
          btn.disabled = false;
        }
      });
    });

    el.querySelectorAll('.rr-mapping-row button').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          const params = new URLSearchParams({ emojiName: btn.dataset.emojiName });
          if (btn.dataset.emojiId) params.set('emojiId', btn.dataset.emojiId);
          await api(`/guilds/${state.guildId}/reactionroles/panels/${btn.dataset.messageId}/mappings?${params}`, { method: 'DELETE' });
          toast('Mapping removed', 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });

    el.querySelectorAll('.rr-add-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const panelEl = btn.closest('.rr-panel');
        const emoji = panelEl.querySelector('.rr-emoji-input').value.trim();
        const roleId = panelEl.querySelector('.rr-role-select').value;
        if (!emoji) { toast('Enter an emoji first', 'err'); return; }
        try {
          await api(`/guilds/${state.guildId}/reactionroles/panels/${panelEl.dataset.messageId}/mappings`, {
            method: 'POST',
            body: JSON.stringify({ channelId: panelEl.dataset.channelId, emoji, roleId }),
          });
          toast('Mapping added', 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
  }

  document.getElementById('rrCreateForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      const body = {
        channelId: document.getElementById('rrChannel').value,
        title: document.getElementById('rrTitle').value,
        description: document.getElementById('rrDescription').value,
      };
      await api(`/guilds/${state.guildId}/reactionroles/panels`, { method: 'POST', body: JSON.stringify(body) });
      toast('Panel created', 'ok');
      e.target.reset();
      loadGuild(state.guildId);
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
  });

  document.getElementById('welcomeForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      const body = {
        channelId: document.getElementById('welcomeChannel').value,
        dmMessage: document.getElementById('welcomeDm').value || null,
      };
      await api(`/guilds/${state.guildId}/welcome`, { method: 'POST', body: JSON.stringify(body) });
      toast('Welcome settings saved', 'ok');
      loadGuild(state.guildId);
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
  });

  document.getElementById('twitchForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      const body = {
        username: document.getElementById('twitchUsername').value,
        channelId: document.getElementById('twitchChannel').value,
        roleId: document.getElementById('twitchRole').value || null,
        message: document.getElementById('twitchMessage').value || null,
      };
      const result = await api(`/guilds/${state.guildId}/twitch`, { method: 'POST', body: JSON.stringify(body) });
      toast(`Now tracking ${result.displayName}`, 'ok');
      e.target.reset();
      loadGuild(state.guildId);
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
  });

  document.getElementById('youtubeForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      const body = {
        channelUrl: document.getElementById('youtubeUrl').value,
        channelId: document.getElementById('youtubeChannel').value,
        roleId: document.getElementById('youtubeRole').value || null,
        message: document.getElementById('youtubeMessage').value || null,
      };
      const result = await api(`/guilds/${state.guildId}/youtube`, { method: 'POST', body: JSON.stringify(body) });
      toast(`Now tracking ${result.channelName}`, 'ok');
      e.target.reset();
      loadGuild(state.guildId);
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
  });

  document.getElementById('logoutBtn').addEventListener('click', async () => {
    await fetch('/auth/logout', { method: 'POST' });
    location.reload();
  });

  document.querySelectorAll('.nav-item').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.nav-item').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      document.querySelectorAll('.module-page').forEach(p => p.classList.remove('active'));
      document.getElementById('module-' + btn.dataset.module).classList.add('active');
    });
  });

  init();
</script>
</body>
</html>
RR_HTML_EOF

echo ""
echo "✅ Done. Four files updated (backups saved as *.bak)."
echo ""
echo "Next steps:"
echo "  1. Review the changes (git diff)."
echo "  2. Re-deploy slash commands so /reactionroles edit-panel shows up:"
echo "       npm run deploy-commands:guild   (instant, for testing in one server)"
echo "       npm run deploy-commands         (global, can take up to an hour)"
echo "  3. Restart the bot / dashboard process."
