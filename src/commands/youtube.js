const { SlashCommandBuilder, PermissionFlagsBits, EmbedBuilder, ChannelType } = require('discord.js');
const db = require('../db');
const youtubeClient = require('../services/youtubeClient');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('youtube')
    .setDescription('Manage YouTube new-video announcements for this server')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('add')
      .setDescription('Get notified when a YouTube channel uploads a new video')
      .addStringOption(opt => opt.setName('channel_url').setDescription('Channel handle (@name), URL, or channel ID').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post announcements in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addRoleOption(opt => opt.setName('role').setDescription('Role to ping (optional)').setRequired(false))
      .addStringOption(opt => opt.setName('message').setDescription('Custom message. Use {channel} {title} {url}').setRequired(false)))
    .addSubcommand(sub => sub
      .setName('remove')
      .setDescription('Stop tracking a YouTube channel')
      .addStringOption(opt => opt.setName('channel_url').setDescription('Channel handle, URL, or channel ID').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('list')
      .setDescription('List tracked YouTube channels for this server')),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'add') {
      await interaction.deferReply({ ephemeral: true });
      const input = interaction.options.getString('channel_url').trim();
      const announceChannel = interaction.options.getChannel('channel');
      const role = interaction.options.getRole('role');
      const message = interaction.options.getString('message');

      let channelId;
      try {
        channelId = await youtubeClient.resolveChannelId(input);
      } catch (err) {
        return interaction.editReply(`❌ Couldn't reach YouTube right now: ${err.message}`);
      }
      if (!channelId) {
        return interaction.editReply(`❌ Couldn't find a YouTube channel for \`${input}\`. Try pasting the full channel URL instead.`);
      }

      let result;
      try {
        result = await youtubeClient.getLatestVideo(channelId);
      } catch (err) {
        return interaction.editReply(`❌ Found the channel but couldn't read its video feed: ${err.message}`);
      }
      const channelName = result?.channelName || input;

      db.addYoutubeSub(interaction.guildId, channelId, channelName, announceChannel.id, role?.id ?? null, message ?? null);

      // Seed state immediately so we don't announce the channel's existing latest video as "new"
      const state = db.getYoutubeState(channelId);
      if (result?.latest && (!state || !state.initialized)) {
        db.setYoutubeState(channelId, result.latest.videoId);
      }

      return interaction.editReply(
        `✅ Now tracking **${channelName}** — I'll announce in ${announceChannel} when they upload.` +
        (role ? ` I'll ping ${role}.` : '')
      );
    }

    if (sub === 'remove') {
      const input = interaction.options.getString('channel_url').trim();
      let channelId;
      try {
        channelId = await youtubeClient.resolveChannelId(input);
      } catch {
        channelId = null;
      }
      // Fall back to matching by stored channel_id or name if resolution fails (e.g. channel deleted)
      const subs = db.listYoutubeSubsForGuild(interaction.guildId);
      const match = subs.find(s => s.channel_id === channelId || s.channel_name?.toLowerCase() === input.toLowerCase());

      const targetId = channelId || match?.channel_id;
      if (!targetId) {
        return interaction.reply({ content: `⚠️ Couldn't resolve or find \`${input}\` in this server's list.`, ephemeral: true });
      }

      const changes = db.removeYoutubeSub(interaction.guildId, targetId);
      if (changes === 0) {
        return interaction.reply({ content: `⚠️ \`${input}\` wasn't being tracked in this server.`, ephemeral: true });
      }
      return interaction.reply({ content: `🗑️ Stopped tracking **${match?.channel_name || input}**.`, ephemeral: true });
    }

    if (sub === 'list') {
      const subs = db.listYoutubeSubsForGuild(interaction.guildId);
      if (subs.length === 0) {
        return interaction.reply({ content: 'No YouTube channels are being tracked in this server yet. Use `/youtube add` to get started.', ephemeral: true });
      }

      const embeds = [];
      for (let i = 0; i < subs.length; i += 25) {
        const embed = new EmbedBuilder()
          .setColor(0xff0000)
          .setTitle(`Tracked YouTube channels (${subs.length} total)`);
        for (const s of subs.slice(i, i + 25)) {
          embed.addFields({
            name: s.channel_name || s.channel_id,
            value: `Channel: <#${s.announce_channel_id}>${s.role_id ? ` • Role: <@&${s.role_id}>` : ''}`,
          });
        }
        embeds.push(embed);
      }
      return interaction.reply({ embeds: embeds.slice(0, 10), ephemeral: true });
    }
  },
};
