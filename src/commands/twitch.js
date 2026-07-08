const { SlashCommandBuilder, PermissionFlagsBits, EmbedBuilder, ChannelType } = require('discord.js');
const db = require('../db');
const twitchClient = require('../services/twitchClient');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('twitch')
    .setDescription('Manage Twitch live announcements for this server')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('add')
      .setDescription('Get notified when a Twitch streamer goes live')
      .addStringOption(opt => opt.setName('username').setDescription('Twitch username (login)').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post announcements in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addRoleOption(opt => opt.setName('role').setDescription('Role to ping (optional)').setRequired(false))
      .addStringOption(opt => opt.setName('message').setDescription('Custom message. Use {streamer} {title} {game} {url}').setRequired(false)))
    .addSubcommand(sub => sub
      .setName('remove')
      .setDescription('Stop tracking a Twitch streamer')
      .addStringOption(opt => opt.setName('username').setDescription('Twitch username (login)').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('list')
      .setDescription('List tracked Twitch streamers for this server')),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'add') {
      await interaction.deferReply({ ephemeral: true });
      const username = interaction.options.getString('username').trim().toLowerCase();
      const channel = interaction.options.getChannel('channel');
      const role = interaction.options.getRole('role');
      const message = interaction.options.getString('message');

      if (!process.env.TWITCH_CLIENT_ID || !process.env.TWITCH_CLIENT_SECRET) {
        return interaction.editReply('⚠️ This bot instance has not been configured with Twitch API credentials yet. Ask the bot host to set `TWITCH_CLIENT_ID` / `TWITCH_CLIENT_SECRET`.');
      }

      let user;
      try {
        user = await twitchClient.userExists(username);
      } catch (err) {
        return interaction.editReply(`❌ Couldn't reach Twitch's API right now: ${err.message}`);
      }
      if (!user) {
        return interaction.editReply(`❌ No Twitch user found with username \`${username}\`. Double-check the spelling — this should be the login name from the twitch.tv URL, not the display name.`);
      }

      db.addTwitchSub(interaction.guildId, username, channel.id, role?.id ?? null, message ?? null);

      return interaction.editReply(
        `✅ Now tracking **${user.display_name}** — I'll announce in ${channel} when they go live.` +
        (role ? ` I'll ping ${role}.` : '')
      );
    }

    if (sub === 'remove') {
      const username = interaction.options.getString('username').trim().toLowerCase();
      const changes = db.removeTwitchSub(interaction.guildId, username);
      if (changes === 0) {
        return interaction.reply({ content: `⚠️ \`${username}\` wasn't being tracked in this server.`, ephemeral: true });
      }
      return interaction.reply({ content: `🗑️ Stopped tracking **${username}**.`, ephemeral: true });
    }

    if (sub === 'list') {
      const subs = db.listTwitchSubsForGuild(interaction.guildId);
      if (subs.length === 0) {
        return interaction.reply({ content: 'No Twitch streamers are being tracked in this server yet. Use `/twitch add` to get started.', ephemeral: true });
      }

      const embeds = [];
      for (let i = 0; i < subs.length; i += 25) {
        const embed = new EmbedBuilder()
          .setColor(0x9146ff)
          .setTitle(`Tracked Twitch streamers (${subs.length} total)`);
        for (const s of subs.slice(i, i + 25)) {
          embed.addFields({
            name: s.streamer_login,
            value: `Channel: <#${s.announce_channel_id}>${s.role_id ? ` • Role: <@&${s.role_id}>` : ''}`,
          });
        }
        embeds.push(embed);
      }
      return interaction.reply({ embeds: embeds.slice(0, 10), ephemeral: true });
    }
  },
};
