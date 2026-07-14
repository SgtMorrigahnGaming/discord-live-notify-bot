const { EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle } = require('discord.js');

const BOOSTER_MULTIPLIER = 2;
const CLAIM_WINDOW_MS = 24 * 60 * 60 * 1000;

// Turns a list of entrant user IDs into a weighted ticket pool: one ticket per entrant,
// duplicated for boosters when the booster bonus is enabled. userIds should already be
// the people who clicked "Enter Giveaway" — this function only handles weighting.
async function buildTicketPool(guild, userIds, boosterEnabled) {
  const tickets = [];
  for (const userId of userIds) {
    let weight = 1;
    if (boosterEnabled) {
      const member = await guild.members.fetch(userId).catch(() => null);
      if (member && member.premiumSince) weight = BOOSTER_MULTIPLIER;
    }
    for (let i = 0; i < weight; i++) tickets.push(userId);
  }
  return tickets;
}

// Weighted random sample without replacement — a winning userId has ALL of its tickets
// removed before the next pick, so nobody can win two winner slots in the same drawing.
function pickWinners(tickets, count, excludeIds = []) {
  const excluded = new Set(excludeIds);
  let pool = tickets.filter(id => !excluded.has(id));
  const winners = [];

  while (winners.length < count && pool.length > 0) {
    const idx = Math.floor(Math.random() * pool.length);
    const userId = pool[idx];
    winners.push(userId);
    pool = pool.filter(id => id !== userId);
  }
  return winners;
}

function buildEnterButtonRow(giveawayId, entered) {
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId(`giveaway_enter:${giveawayId}`)
      .setLabel(entered ? '🎉 Entered — click to leave' : '🎉 Enter Giveaway')
      .setStyle(entered ? ButtonStyle.Secondary : ButtonStyle.Success)
  );
}

function buildOpenGiveawayEmbed({ title, prize, description, winnerCount, entryRoleId, boosterEnabled, endsAt, entrantCount }) {
  const embed = new EmbedBuilder()
    .setColor(0xf2b705)
    .setTitle(`🎉 ${title}`)
    .setDescription(
      `**Prize:** ${prize}\n` +
      (description ? `${description}\n\n` : '\n') +
      `Click **Enter Giveaway** below to join — you need <@&${entryRoleId}> to be eligible.` +
      (boosterEnabled ? `\n🚀 Server boosters get **${BOOSTER_MULTIPLIER}x** entries.` : '')
    )
    .addFields(
      { name: 'Winners', value: `${winnerCount}`, inline: true },
      { name: 'Entrants', value: `${entrantCount}`, inline: true },
      { name: 'Ends', value: `<t:${endsAt}:R>`, inline: true },
    )
    .setFooter({ text: 'Winners are picked and DM\'d automatically when this closes' });
  return embed;
}

function buildClosedGiveawayEmbed({ title, prize, description, winners, entrantCount }) {
  const winnerLine = winners.length === 0
    ? '_No entrants — no winners were picked._'
    : winners.map(w => `🏆 <@${w.user_id}>${w.replaced ? ' _(rerolled — did not claim in time)_' : w.claimed ? ' ✅ claimed' : w.unclaimed_final ? ' ⚠️ unclaimed' : ' ⏳ awaiting claim'}`).join('\n');

  return new EmbedBuilder()
    .setColor(0x57f287)
    .setTitle(`🎉 ${title} — Closed`)
    .setDescription(
      `**Prize:** ${prize}\n` +
      (description ? `${description}\n\n` : '\n') +
      winnerLine
    )
    .addFields({ name: 'Entrants', value: `${entrantCount}`, inline: true })
    .setFooter({ text: 'Giveaway closed' });
}

module.exports = {
  BOOSTER_MULTIPLIER,
  CLAIM_WINDOW_MS,
  buildTicketPool,
  pickWinners,
  buildEnterButtonRow,
  buildOpenGiveawayEmbed,
  buildClosedGiveawayEmbed,
};
