const NUMBER_EMOJI = ['1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '🔟'];

function numberEmoji(i) {
  return NUMBER_EMOJI[i] || `${i + 1}.`;
}

// counts=null -> hide vote numbers (poll still open, tallies hidden). counts=array -> show them.
function buildPollDescription(choices, counts) {
  return choices.map((c, i) => {
    const base = `${numberEmoji(i)} ${c}`;
    if (!counts) return base;
    const n = counts[i] || 0;
    return `${base} — **${n}** vote${n === 1 ? '' : 's'}`;
  }).join('\n');
}

module.exports = { numberEmoji, buildPollDescription, MAX_CHOICES: 10 };
