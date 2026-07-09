function requireAuth(req, res, next) {
  if (!req.session.user) {
    return res.status(401).json({ error: 'Not logged in' });
  }
  next();
}

/**
 * Verifies the logged-in user can manage :guildId (owner or Manage Server on Discord's side,
 * captured at login time) AND that the bot is actually a member of that guild.
 */
function requireGuildAccess(client) {
  return (req, res, next) => {
    const { guildId } = req.params;
    const manageable = req.session.manageableGuildIds || [];
    if (!manageable.includes(guildId)) {
      return res.status(403).json({ error: "You don't have permission to manage this server" });
    }
    if (!client.guilds.cache.has(guildId)) {
      return res.status(404).json({ error: 'The bot is not a member of this server' });
    }
    next();
  };
}

module.exports = { requireAuth, requireGuildAccess };
