const { EmbedBuilder } = require('discord.js');

const BOOSTER_MULTIPLIER = 2;
const CLAIM_WINDOW_MS = 24 * 60 * 60 * 1000;

// Fetches full member list and returns a weighted ticket pool: one entry per member holding
// the entry role, duplicated for boosters when the booster bonus is enabled. Entry is fully
// automatic — no reaction/click is involved in building this pool.
async function buildEntrantPool(guild, entryRoleId, boosterEnabled) {
  await guild.members.fetch().catch(() => {});
  const role = guild.roles.cache.get(entryRoleId);
  if (!role) return [];

  const tickets = [];
  for (const member of role.members.values()) {
    if (member.user.bot) continue;
    const weight = boosterEnabled && member.premiumSince ? BOOSTER_MULTIPLIER : 1;
    for (let i = 0; i < weight; i++) tickets.push(member.id);
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

function buildOpenGiveawayEmbed({ title, prize, description, winnerCount, entryRoleId, boosterEnabled, endsAt, entrantCount }) {
  const embed = new EmbedBuilder()
    .setColor(0xf2b705)
    .setTitle(`🎉 ${title}`)
    .setDescription(
      `**Prize:** ${prize}\n` +
      (description ? `${description}\n\n` : '\n') +
      `Anyone holding <@&${entryRoleId}> is automatically entered — no action needed.` +
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
    ? '_No eligible entrants — no winners were picked._'
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
  buildEntrantPool,
  pickWinners,
  buildOpenGiveawayEmbed,
  buildClosedGiveawayEmbed,
};
