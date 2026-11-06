const { SlashCommandBuilder, PermissionFlagsBits, ChannelType, EmbedBuilder } = require('discord.js');
const db = require('../db');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('afkprotect')
    .setDescription('Keep voice channels or members from being swept into the AFK channel')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommandGroup(group => group
      .setName('channel')
      .setDescription('Protect an entire voice channel')
      .addSubcommand(sub => sub
        .setName('add')
        .setDescription('Anyone idled out of this channel gets moved straight back')
        .addChannelOption(opt => opt.setName('channel').setDescription('Voice channel to protect').addChannelTypes(ChannelType.GuildVoice).setRequired(true)))
      .addSubcommand(sub => sub
        .setName('remove')
        .setDescription('Stop protecting a voice channel')
        .addChannelOption(opt => opt.setName('channel').setDescription('Voice channel to unprotect').addChannelTypes(ChannelType.GuildVoice).setRequired(true)))
      .addSubcommand(sub => sub
        .setName('list')
        .setDescription('List protected voice channels')))
    .addSubcommandGroup(group => group
      .setName('user')
      .setDescription('Protect a specific member, in any voice channel')
      .addSubcommand(sub => sub
        .setName('add')
        .setDescription('This member gets moved back no matter which channel they idle out of')
        .addUserOption(opt => opt.setName('user').setDescription('Member to protect').setRequired(true)))
      .addSubcommand(sub => sub
        .setName('remove')
        .setDescription('Stop protecting a member')
        .addUserOption(opt => opt.setName('user').setDescription('Member to unprotect').setRequired(true)))
      .addSubcommand(sub => sub
        .setName('list')
        .setDescription('List protected members'))),

  async execute(interaction) {
    const group = interaction.options.getSubcommandGroup();
    const sub = interaction.options.getSubcommand();

    if (group === 'channel') {
      if (sub === 'add') {
        const channel = interaction.options.getChannel('channel');
        if (channel.id === interaction.guild.afkChannelId) {
          return interaction.reply({ content: `❌ ${channel} is already this server's AFK channel — nothing to protect it from.`, ephemeral: true });
        }
        db.addAfkProtectedChannel(interaction.guildId, channel.id, interaction.user.id);
        return interaction.reply({ content: `✅ ${channel} is now protected — anyone idled out of it into AFK gets moved straight back.`, ephemeral: true });
      }

      if (sub === 'remove') {
        const channel = interaction.options.getChannel('channel');
        const changes = db.removeAfkProtectedChannel(interaction.guildId, channel.id);
        if (changes === 0) {
          return interaction.reply({ content: `⚠️ ${channel} wasn't protected.`, ephemeral: true });
        }
        return interaction.reply({ content: `🗑️ ${channel} is no longer protected.`, ephemeral: true });
      }

      if (sub === 'list') {
        const rows = db.listAfkProtectedChannels(interaction.guildId);
        if (rows.length === 0) {
          return interaction.reply({ content: 'No voice channels are protected yet.', ephemeral: true });
        }
        const embed = new EmbedBuilder()
          .setColor(0x3ddc97)
          .setTitle('AFK-protected channels')
          .setDescription(rows.map(r => `<#${r.channel_id}>`).join('\n'));
        return interaction.reply({ embeds: [embed], ephemeral: true });
      }
    }

    if (group === 'user') {
      if (sub === 'add') {
        const user = interaction.options.getUser('user');
        db.addAfkProtectedUser(interaction.guildId, user.id, interaction.user.id);
        return interaction.reply({ content: `✅ ${user} is now protected — they'll be moved back no matter which channel they idle out of.`, ephemeral: true });
      }

      if (sub === 'remove') {
        const user = interaction.options.getUser('user');
        const changes = db.removeAfkProtectedUser(interaction.guildId, user.id);
        if (changes === 0) {
          return interaction.reply({ content: `⚠️ ${user} wasn't protected.`, ephemeral: true });
        }
        return interaction.reply({ content: `🗑️ ${user} is no longer protected.`, ephemeral: true });
      }

      if (sub === 'list') {
        const rows = db.listAfkProtectedUsers(interaction.guildId);
        if (rows.length === 0) {
          return interaction.reply({ content: 'No members are protected yet.', ephemeral: true });
        }
        const embed = new EmbedBuilder()
          .setColor(0x3ddc97)
          .setTitle('AFK-protected members')
          .setDescription(rows.map(r => `<@${r.user_id}>`).join('\n'));
        return interaction.reply({ embeds: [embed], ephemeral: true });
      }
    }
  },
};
