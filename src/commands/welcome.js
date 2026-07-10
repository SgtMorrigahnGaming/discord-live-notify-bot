const { SlashCommandBuilder, PermissionFlagsBits, ChannelType, AttachmentBuilder } = require('discord.js');
const db = require('../db');
const { generateWelcomeCard } = require('../utils/welcomeCard');

function fillTemplate(template, vars) {
  if (!template) return null;
  let out = template;
  for (const [key, val] of Object.entries(vars)) {
    out = out.replaceAll(`{${key}}`, val ?? '');
  }
  return out;
}

module.exports = {
  data: new SlashCommandBuilder()
    .setName('welcome')
    .setDescription('Configure the welcome card + DM new members get when they join')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('setup')
      .setDescription('Turn on welcome messages')
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post the welcome card in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('dm_message').setDescription('Optional DM to send too. Use {user} {server}').setRequired(false)))
    .addSubcommand(sub => sub
      .setName('test')
      .setDescription('Preview the welcome card + DM using your own account, without posting publicly'))
    .addSubcommand(sub => sub
      .setName('disable')
      .setDescription('Turn off welcome messages (keeps your settings for later)'))
    .addSubcommand(sub => sub
      .setName('enable')
      .setDescription('Turn welcome messages back on using previously saved settings')),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'setup') {
      const channel = interaction.options.getChannel('channel');
      const dmMessage = interaction.options.getString('dm_message');
      db.setWelcomeConfig(interaction.guildId, channel.id, dmMessage || null);
      return interaction.reply({
        content: `✅ New members will now get a welcome card in ${channel}` +
          (dmMessage ? ' plus a DM.' : '. No DM configured — add one anytime by running \`/welcome setup\` again.') +
          `\n\nTry \`/welcome test\` to preview it before anyone else sees it.`,
        ephemeral: true,
      });
    }

    if (sub === 'test') {
      await interaction.deferReply({ ephemeral: true });
      const config = db.getWelcomeConfig(interaction.guildId);
      if (!config) {
        return interaction.editReply('⚠️ Welcome messages haven\'t been set up yet — run `/welcome setup` first.');
      }

      const member = interaction.member;
      const buffer = await generateWelcomeCard({
        avatarUrl: member.displayAvatarURL({ extension: 'png', size: 256 }),
        username: member.user.username,
        guildName: interaction.guild.name,
        memberCount: interaction.guild.memberCount,
      });
      const attachment = new AttachmentBuilder(buffer, { name: 'welcome-preview.png' });

      const dmPreview = config.dm_message
        ? `\n\n**DM preview:**\n> ${fillTemplate(config.dm_message, { user: member.displayName, server: interaction.guild.name })}`
        : '\n\n*(No DM configured)*';

      return interaction.editReply({
        content: `This is what new members will see in <#${config.channel_id}>:${dmPreview}`,
        files: [attachment],
      });
    }

    if (sub === 'disable') {
      const changes = db.setWelcomeEnabled(interaction.guildId, false);
      if (changes === 0) {
        return interaction.reply({ content: '⚠️ Welcome messages were never set up — nothing to disable.', ephemeral: true });
      }
      return interaction.reply({ content: '🔕 Welcome messages turned off. Your channel/DM settings are kept — run `/welcome enable` to turn back on.', ephemeral: true });
    }

    if (sub === 'enable') {
      const config = db.getWelcomeConfig(interaction.guildId);
      if (!config) {
        return interaction.reply({ content: '⚠️ No previous settings found — run `/welcome setup` instead.', ephemeral: true });
      }
      db.setWelcomeEnabled(interaction.guildId, true);
      return interaction.reply({ content: `🔔 Welcome messages turned back on, posting in <#${config.channel_id}>.`, ephemeral: true });
    }
  },
};
