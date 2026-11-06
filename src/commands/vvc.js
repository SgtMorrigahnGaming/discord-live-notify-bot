const { SlashCommandBuilder, PermissionFlagsBits, EmbedBuilder } = require('discord.js');
const db = require('../db');
const logger = require('../utils/logger');
const {
  resolveAnnouncement,
  buildAllowedMentions,
  buildPingLine,
  stripLeadingPings,
} = require('../utils/announceFormat');

const COOLDOWN_MS = 10_000;
const cooldowns = new Map(); // `${guildId}:${userId}` -> timestamp of last use

const COLORS = {
  blurple: 0x5865f2,
  green: 0x2ecc71,
  orange: 0xe67e22,
  red: 0xe74c3c,
  purple: 0x9b59b6,
  gold: 0xf1c40f,
  teal: 0x1abc9c,
};

function hasModAccess(interaction) {
  const member = interaction.member;
  if (!member) return false;
  // Administrators (and the server owner) are always allowed.
  if (member.permissions?.has(PermissionFlagsBits.Administrator)) return true;

  const cfg = db.getAnnounceConfig(interaction.guildId);
  if (!cfg?.mod_role_id) return false;
  return Array.isArray(member.roles)
    ? member.roles.includes(cfg.mod_role_id)
    : Boolean(member.roles?.cache?.has(cfg.mod_role_id));
}

function truncate(str, max) {
  return str.length > max ? `${str.slice(0, max - 1)}…` : str;
}

async function logAnnouncement(interaction, { style, text, message }) {
  logger.info(
    `Announcement posted in guild ${interaction.guildId} #${interaction.channelId} by ${interaction.user.tag} (${interaction.user.id}) [${style}]`
  );
  const cfg = db.getAnnounceConfig(interaction.guildId);
  if (!cfg?.log_channel_id) return;
  const logChannel = await interaction.client.channels.fetch(cfg.log_channel_id).catch(() => null);
  if (!logChannel) {
    logger.warn(`Announce log: configured channel ${cfg.log_channel_id} not found in guild ${interaction.guildId}`);
    return;
  }
  const embed = new EmbedBuilder()
    .setColor(0x5865f2)
    .setTitle('📣 Announcement posted')
    .addFields(
      { name: 'Posted by', value: `${interaction.user.tag} (${interaction.user.id})` },
      { name: 'Channel', value: `<#${interaction.channelId}>`, inline: true },
      { name: 'Style', value: style, inline: true },
      { name: 'Message', value: truncate(text, 1000) || '—' }
    )
    .setTimestamp();
  if (message?.url) embed.addFields({ name: 'Link', value: `[Jump to announcement](${message.url})` });
  await logChannel.send({ embeds: [embed], allowedMentions: { parse: [] } }).catch((err) => {
    logger.error(`Announce log: failed to post in guild ${interaction.guildId}:`, err);
  });
}

module.exports = {
  data: new SlashCommandBuilder()
    .setName('vvc')
    .setDescription('Post an announcement as the bot in this channel (moderators only)')
    .setDMPermission(false)
    .addStringOption(opt => opt
      .setName('message')
      .setDescription('The announcement. Supports @everyone, @here, @role_name, #channel-name and \\n for a new line')
      .setMaxLength(1500)
      .setRequired(true))
    .addStringOption(opt => opt
      .setName('style')
      .setDescription('Plain text (default) or an embed with a colored bar')
      .addChoices(
        { name: 'Plain text', value: 'plain' },
        { name: 'Embed', value: 'embed' }
      )
      .setRequired(false))
    .addStringOption(opt => opt
      .setName('title')
      .setDescription('Embed title (only used with the embed style)')
      .setMaxLength(256)
      .setRequired(false))
    .addStringOption(opt => opt
      .setName('color')
      .setDescription('Embed bar color (only used with the embed style)')
      .addChoices(
        { name: 'Blurple', value: 'blurple' },
        { name: 'Green', value: 'green' },
        { name: 'Orange', value: 'orange' },
        { name: 'Red', value: 'red' },
        { name: 'Purple', value: 'purple' },
        { name: 'Gold', value: 'gold' },
        { name: 'Teal', value: 'teal' }
      )
      .setRequired(false)),

  async execute(interaction) {
    if (!interaction.inGuild()) {
      return interaction.reply({ content: '❌ This command only works inside a server.', ephemeral: true });
    }

    if (!hasModAccess(interaction)) {
      const cfg = db.getAnnounceConfig(interaction.guildId);
      const hint = cfg?.mod_role_id
        ? 'Only members with the moderator role can post announcements.'
        : 'No moderator role has been set up for this server yet — an admin can set one with `/vvcrole set`.';
      return interaction.reply({ content: `🚫 ${hint}`, ephemeral: true });
    }

    const cooldownKey = `${interaction.guildId}:${interaction.user.id}`;
    const last = cooldowns.get(cooldownKey) || 0;
    const waitMs = COOLDOWN_MS - (Date.now() - last);
    if (waitMs > 0) {
      return interaction.reply({
        content: `⏳ Slow down — you can post another announcement in ${Math.ceil(waitMs / 1000)}s.`,
        ephemeral: true,
      });
    }

    const channel = interaction.channel;
    const me = interaction.guild?.members?.me;
    const perms = me && channel?.permissionsFor ? channel.permissionsFor(me) : null;
    if (!channel || !perms) {
      return interaction.reply({ content: '❌ I can\'t post in this channel.', ephemeral: true });
    }
    const style = interaction.options.getString('style') || 'plain';
    const needed = [PermissionFlagsBits.ViewChannel, PermissionFlagsBits.SendMessages];
    if (style === 'embed') needed.push(PermissionFlagsBits.EmbedLinks);
    if (!perms.has(needed)) {
      return interaction.reply({
        content: `❌ I'm missing permissions in this channel (I need View Channel, Send Messages${style === 'embed' ? ', Embed Links' : ''}).`,
        ephemeral: true,
      });
    }

    await interaction.deferReply({ ephemeral: true });

    const raw = interaction.options.getString('message');
    const resolved = resolveAnnouncement(raw, interaction.guild);
    const allowedMentions = buildAllowedMentions(resolved);

    let payload;
    if (style === 'embed') {
      const description = stripLeadingPings(resolved.text);
      if (description.length > 4000) {
        return interaction.editReply('❌ That announcement is too long once mentions are expanded. Please shorten it.');
      }
      const embed = new EmbedBuilder()
        .setColor(COLORS[interaction.options.getString('color')] ?? COLORS.blurple)
        .setDescription(description);
      const title = interaction.options.getString('title');
      if (title) embed.setTitle(title);
      // Mentions inside an embed never notify anyone, so pings go in the message content.
      const pingLine = buildPingLine(resolved);
      payload = { embeds: [embed], allowedMentions };
      if (pingLine) payload.content = pingLine;
    } else {
      if (resolved.text.length > 2000) {
        return interaction.editReply('❌ That announcement is too long once mentions are expanded. Please shorten it.');
      }
      payload = { content: resolved.text, allowedMentions };
    }

    let message;
    try {
      message = await channel.send(payload);
    } catch (err) {
      logger.error(`Announce: failed to post in guild ${interaction.guildId}:`, err);
      return interaction.editReply('❌ Discord rejected the announcement. Check my permissions in this channel and try again.');
    }
    cooldowns.set(cooldownKey, Date.now());

    const notes = [];
    if ((resolved.pingEveryone || resolved.pingHere) && !perms.has(PermissionFlagsBits.MentionEveryone)) {
      notes.push('⚠️ I don\'t have the **Mention Everyone** permission in this channel, so `@everyone` / `@here` won\'t notify anyone.');
    }
    if (resolved.roleIds.length > 0 && !perms.has(PermissionFlagsBits.MentionEveryone)) {
      const unmentionable = resolved.roleIds.filter((id) => !interaction.guild.roles.cache.get(id)?.mentionable);
      if (unmentionable.length > 0) {
        notes.push(`⚠️ ${unmentionable.map((id) => `<@&${id}>`).join(', ')} isn't mentionable and I lack **Mention Everyone**, so that role wasn't pinged.`);
      }
    }
    if (resolved.unresolved.length > 0) {
      notes.push(`ℹ️ I couldn't match: ${resolved.unresolved.map((u) => `\`${u}\``).join(', ')} — left as plain text.`);
    }

    await interaction.editReply({
      content: ['✅ Announcement posted.', ...notes].join('\n'),
      allowedMentions: { parse: [] },
    });

    await logAnnouncement(interaction, { style, text: resolved.text, message }).catch((err) => {
      logger.error('Announce log error:', err);
    });
  },
};
