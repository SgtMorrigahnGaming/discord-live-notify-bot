const express = require('express');
const { PermissionsBitField, ChannelType, EmbedBuilder } = require('discord.js');
const db = require('../db');
const twitchClient = require('../services/twitchClient');
const youtubeClient = require('../services/youtubeClient');
const emojiUtil = require('../utils/emoji');
const { generateWelcomeCard } = require('../utils/welcomeCard');
const { requireAuth, requireGuildAccess } = require('./authMiddleware');
const pollInteractions = require('../services/pollInteractions');
const pollCloser = require('../services/pollCloser');
const giveawayCloser = require('../services/giveawayCloser');

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

  // ---- Guild's custom emoji, for the emoji picker in reaction roles ----
  guildRouter.get('/emojis', (req, res) => {
    const guild = client.guilds.cache.get(req.params.guildId);
    const emojis = guild.emojis.cache
      .map(e => ({
        id: e.id,
        name: e.name,
        animated: e.animated,
        url: e.imageURL({ size: 32, extension: e.animated ? 'gif' : 'png' }),
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
    res.json(emojis);
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

    db.createReactionRolePanel(req.params.guildId, channelId, message.id);
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

  guildRouter.delete('/reactionroles/panels/:messageId', async (req, res) => {
    const channelId = req.query.channelId;
    if (!channelId) return res.status(400).json({ error: 'channelId query param is required' });

    const channel = client.channels.cache.get(channelId);
    const message = await channel?.messages.fetch(req.params.messageId).catch(() => null);
    if (message && message.author.id === client.user.id) {
      await message.delete().catch(() => {});
    }

    db.deleteReactionRolePanel(req.params.messageId);
    res.json({ ok: true });
  });

  // ---- Polls ----
  guildRouter.get('/polls', (req, res) => {
    const polls = db.listPollsForGuild(req.params.guildId);
    const withCounts = polls.map(p => ({
      ...p,
      counts: db.getVoteCounts(p.id, p.choices.length),
    }));
    res.json(withCounts);
  });

  guildRouter.post('/polls', async (req, res) => {
    const { channelId, question, durationHours, talliesVisible, choices } = req.body;
    if (!channelId || !question || !durationHours || !Array.isArray(choices)) {
      return res.status(400).json({ error: 'channelId, question, durationHours, and choices are required' });
    }

    const trimmedQuestion = question.trim();
    const trimmedChoices = choices.map(c => (c || '').trim()).filter(Boolean);
    if (!trimmedQuestion) return res.status(400).json({ error: 'Question is required' });
    if (trimmedChoices.length < 2) return res.status(400).json({ error: 'At least 2 choices are required' });
    if (trimmedChoices.length > 10) return res.status(400).json({ error: 'Polls are capped at 10 choices' });

    const hours = Number(durationHours);
    if (!Number.isFinite(hours) || hours <= 0) {
      return res.status(400).json({ error: 'durationHours must be a positive number' });
    }

    const channel = client.channels.cache.get(channelId);
    if (!channel) return res.status(404).json({ error: 'Channel not found' });

    const closesAt = Math.floor(Date.now() / 1000) + Math.round(hours * 3600);
    const pollId = db.createPoll({
      guildId: req.params.guildId,
      channelId,
      question: trimmedQuestion,
      choices: trimmedChoices,
      talliesVisible: !!talliesVisible,
      createdBy: req.session.user.id,
      closesAt,
    });

    const embed = pollInteractions.buildOpenPollEmbed({
      question: trimmedQuestion,
      choices: trimmedChoices,
      closesAt,
      talliesVisible: !!talliesVisible,
      counts: talliesVisible ? new Array(trimmedChoices.length).fill(0) : null,
    });
    const rows = pollInteractions.buildVoteButtonRows(pollId, trimmedChoices);

    const message = await channel.send({ embeds: [embed], components: rows }).catch(() => null);
    if (!message) {
      db.deletePoll(pollId);
      return res.status(502).json({ error: "Couldn't post in that channel — check my permissions there" });
    }
    db.setPollMessage(pollId, message.id);

    res.json({ ok: true, pollId, messageId: message.id });
  });

  guildRouter.post('/polls/:pollId/close', async (req, res) => {
    const poll = db.getPoll(req.params.pollId);
    if (!poll || poll.guild_id !== req.params.guildId) return res.status(404).json({ error: 'Poll not found' });
    if (poll.status === 'closed') return res.status(400).json({ error: 'That poll is already closed' });
    await pollCloser.closePollNow(client, poll.id);
    res.json({ ok: true });
  });

  // ---- Giveaways ----
  guildRouter.get('/giveaways', (req, res) => {
    const giveaways = db.listGiveawaysForGuild(req.params.guildId);
    const withDetails = giveaways.map(g => ({
      ...g,
      entrant_count: db.getGiveawayEntryCount(g.id),
      winners: db.getGiveawayWinners(g.id),
    }));
    res.json(withDetails);
  });

  guildRouter.post('/giveaways', async (req, res) => {
    const { channelId, entryRoleId, boosterEnabled, autoRerollEnabled, title, prize, description, durationHours, winnerCount } = req.body;
    if (!channelId || !entryRoleId || !title || !prize || !durationHours || !winnerCount) {
      return res.status(400).json({ error: 'channelId, entryRoleId, title, prize, durationHours, and winnerCount are required' });
    }

    const trimmedTitle = (title || '').trim();
    const trimmedPrize = (prize || '').trim();
    const trimmedDescription = (description || '').trim();
    if (!trimmedTitle) return res.status(400).json({ error: 'Title is required' });
    if (!trimmedPrize) return res.status(400).json({ error: 'Prize is required' });

    const hours = Number(durationHours);
    if (!Number.isFinite(hours) || hours <= 0) {
      return res.status(400).json({ error: 'durationHours must be a positive number' });
    }
    const winners = Number(winnerCount);
    if (!Number.isInteger(winners) || winners < 1) {
      return res.status(400).json({ error: 'winnerCount must be a whole number of at least 1' });
    }

    const guild = client.guilds.cache.get(req.params.guildId);
    const channel = client.channels.cache.get(channelId);
    if (!channel) return res.status(404).json({ error: 'Channel not found' });
    const role = guild.roles.cache.get(entryRoleId);
    if (!role) return res.status(404).json({ error: 'Entry role not found' });
    if (role.managed || role.id === guild.id) {
      return res.status(400).json({ error: "Can't use that role as the entry role — it's managed by an integration or is @everyone" });
    }

    const endsAt = Math.floor(Date.now() / 1000) + Math.round(hours * 3600);

    const giveawayId = db.createGiveaway({
      guildId: req.params.guildId,
      channelId,
      title: trimmedTitle,
      prize: trimmedPrize,
      description: trimmedDescription || null,
      winnerCount: winners,
      entryRoleId,
      boosterEnabled: !!boosterEnabled,
      autoRerollEnabled: !!autoRerollEnabled,
      createdBy: req.session.user.id,
      endsAt,
    });

    const giveawayFormat = require('../utils/giveawayFormat');
    const embed = giveawayFormat.buildOpenGiveawayEmbed({
      title: trimmedTitle,
      prize: trimmedPrize,
      description: trimmedDescription,
      winnerCount: winners,
      entryRoleId,
      boosterEnabled: !!boosterEnabled,
      endsAt,
      entrantCount: 0,
    });

    const message = await channel.send({ embeds: [embed], components: [giveawayFormat.buildEnterButtonRow(giveawayId, false)] }).catch(() => null);
    if (!message) {
      db.deleteGiveaway(giveawayId);
      return res.status(502).json({ error: "Couldn't post in that channel — check my permissions there" });
    }
    db.setGiveawayMessage(giveawayId, message.id);

    res.json({ ok: true, giveawayId, messageId: message.id });
  });

  guildRouter.post('/giveaways/:giveawayId/close', async (req, res) => {
    const giveaway = db.getGiveaway(req.params.giveawayId);
    if (!giveaway || giveaway.guild_id !== req.params.guildId) return res.status(404).json({ error: 'Giveaway not found' });
    if (giveaway.status === 'closed') return res.status(400).json({ error: 'That giveaway is already closed' });
    await giveawayCloser.closeGiveawayNow(client, giveaway.id);
    res.json({ ok: true });
  });

  // ---- Mod Action Logging ----
  guildRouter.get('/modlog', (req, res) => {
    res.json(db.getModlogConfig(req.params.guildId) || {
      ban_channel_id: null, kick_channel_id: null, timeout_channel_id: null,
      roleremove_channel_id: null, spam_channel_id: null,
      spam_enabled: 0, spam_channel_threshold: 3, spam_timeout_minutes: 10, spam_exempt_role_ids: [],
    });
  });

  guildRouter.post('/modlog/channels', (req, res) => {
    const { banChannelId, kickChannelId, timeoutChannelId, roleremoveChannelId, spamChannelId } = req.body;
    db.setModlogChannels(req.params.guildId, {
      banChannelId: banChannelId || null,
      kickChannelId: kickChannelId || null,
      timeoutChannelId: timeoutChannelId || null,
      roleremoveChannelId: roleremoveChannelId || null,
      spamChannelId: spamChannelId || null,
    });
    res.json({ ok: true });
  });

  guildRouter.post('/modlog/spam', (req, res) => {
    const { enabled, channelThreshold, timeoutMinutes, exemptRoleIds } = req.body;
    const threshold = Number(channelThreshold);
    const timeout = Number(timeoutMinutes);
    if (!Number.isInteger(threshold) || threshold < 2) {
      return res.status(400).json({ error: 'channelThreshold must be a whole number of at least 2' });
    }
    if (!Number.isFinite(timeout) || timeout <= 0) {
      return res.status(400).json({ error: 'timeoutMinutes must be a positive number' });
    }
    db.setModlogSpamSettings(req.params.guildId, {
      enabled: !!enabled,
      channelThreshold: threshold,
      timeoutMinutes: timeout,
      exemptRoleIds: Array.isArray(exemptRoleIds) ? exemptRoleIds : [],
    });
    res.json({ ok: true });
  });

  return router;
}

module.exports = buildRouter;
