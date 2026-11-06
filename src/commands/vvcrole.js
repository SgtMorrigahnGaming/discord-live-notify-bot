const { SlashCommandBuilder, PermissionFlagsBits, ChannelType } = require('discord.js');
const db = require('../db');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('vvcrole')
    .setDescription('Choose which role may use /vvc announcements in this server')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .setDMPermission(false)
    .addSubcommand(sub => sub
      .setName('set')
      .setDescription('Set the moderator role allowed to use /vvc')
      .addRoleOption(opt => opt.setName('role').setDescription('The moderator role').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('log')
      .setDescription('Log every announcement (who posted what) to a channel — leave empty to turn logging off')
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel for announcement logs').addChannelTypes(ChannelType.GuildText).setRequired(false)))
    .addSubcommand(sub => sub
      .setName('clear')
      .setDescription('Remove the moderator role (only Administrators can use /vvc afterwards)'))
    .addSubcommand(sub => sub
      .setName('view')
      .setDescription('Show the current /vvc settings')),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();
    const guildId = interaction.guildId;

    if (sub === 'set') {
      const role = interaction.options.getRole('role');
      // The @everyone role shares its id with the guild — setting it would open /vvc to every member.
      if (role.id === guildId) {
        return interaction.reply({
          content: '❌ You can\'t use @everyone as the moderator role — that would let every member post announcements. Pick a real moderator role.',
          ephemeral: true,
        });
      }
      db.setAnnounceModRole(guildId, role.id);
      return interaction.reply({
        content: `✅ Members with ${role} (and Administrators) can now use \`/vvc\`.`,
        ephemeral: true,
        allowedMentions: { parse: [] },
      });
    }

    if (sub === 'log') {
      const channel = interaction.options.getChannel('channel');
      db.setAnnounceLogChannel(guildId, channel?.id ?? null);
      return interaction.reply({
        content: channel
          ? `✅ Announcements will be logged in ${channel}.`
          : '🗑️ Announcement logging is now off.',
        ephemeral: true,
        allowedMentions: { parse: [] },
      });
    }

    if (sub === 'clear') {
      db.setAnnounceModRole(guildId, null);
      return interaction.reply({
        content: '🗑️ Moderator role removed. Only Administrators can use `/vvc` until you set a new one with `/vvcrole set`.',
        ephemeral: true,
      });
    }

    if (sub === 'view') {
      const cfg = db.getAnnounceConfig(guildId);
      const role = cfg?.mod_role_id ? interaction.guild.roles.cache.get(cfg.mod_role_id) : null;
      const roleLine = !cfg?.mod_role_id
        ? 'Not set — only Administrators can use `/vvc`.'
        : role
          ? `${role}`
          : '⚠️ The saved role no longer exists — only Administrators can use `/vvc`. Set a new one with `/vvcrole set`.';
      const logLine = cfg?.log_channel_id ? `<#${cfg.log_channel_id}>` : 'Off';
      return interaction.reply({
        content: `**/vvc settings**\nModerator role: ${roleLine}\nAnnouncement log: ${logLine}`,
        ephemeral: true,
        allowedMentions: { parse: [] },
      });
    }
  },
};
