const path = require('path');
const crypto = require('crypto');
const express = require('express');
const session = require('express-session');
const config = require('../config');
const logger = require('../utils/logger');
const oauth = require('./discordOAuth');
const buildApiRouter = require('./api');

function start(client) {
  if (!config.web.enabled) {
    logger.info('Web dashboard disabled (set WEB_ENABLED=true in .env to enable it).');
    return;
  }
  if (!config.web.publicUrl || !config.web.clientSecret || !config.web.sessionSecret) {
    logger.warn('Web dashboard enabled but WEB_PUBLIC_URL / DISCORD_CLIENT_SECRET / SESSION_SECRET is missing — dashboard NOT started.');
    return;
  }

  const app = express();
  app.set('trust proxy', 1); // we sit behind a reverse proxy (nginx/Caddy) terminating TLS
  app.use(express.json());
  app.use(session({
    secret: config.web.sessionSecret,
    resave: false,
    saveUninitialized: false,
    cookie: {
      httpOnly: true,
      secure: config.web.publicUrl.startsWith('https://'),
      sameSite: 'lax',
      maxAge: 7 * 24 * 60 * 60 * 1000, // 7 days
    },
  }));

  // ---- Auth routes ----
  app.get('/auth/discord/login', (req, res) => {
    const state = crypto.randomBytes(16).toString('hex');
    req.session.oauthState = state;
    res.redirect(oauth.getAuthorizeUrl(state));
  });

  app.get('/auth/discord/callback', async (req, res) => {
    const { code, state } = req.query;
    if (!code || !state || state !== req.session.oauthState) {
      return res.status(400).send('Invalid OAuth state — please try logging in again.');
    }
    delete req.session.oauthState;

    try {
      const tokenData = await oauth.exchangeCode(code);
      const user = await oauth.getUser(tokenData.access_token);
      const manageableGuilds = await oauth.getManageableGuilds(tokenData.access_token);

      req.session.user = { id: user.id, username: user.username, avatar: user.avatar };
      req.session.manageableGuildIds = manageableGuilds.map(g => g.id);

      res.redirect('/');
    } catch (err) {
      logger.error('OAuth callback error:', err);
      res.status(500).send('Login failed — check server logs.');
    }
  });

  app.post('/auth/logout', (req, res) => {
    req.session.destroy(() => res.json({ ok: true }));
  });

  app.get('/api/me', (req, res) => {
    if (!req.session.user) return res.status(401).json({ error: 'Not logged in' });
    res.json(req.session.user);
  });

  // Unauthenticated on purpose — visitors without the bot need this before they can log in usefully.
  app.get('/api/invite-url', (req, res) => {
    res.json({ url: config.web.inviteUrl });
  });

  // ---- API ----
  app.use('/api', buildApiRouter(client));

  // ---- Public legal pages (no login required — must stay reachable by anyone) ----
  app.get('/tos', (req, res) => res.sendFile(path.join(__dirname, 'public', 'tos.html')));
  app.get('/privacy', (req, res) => res.sendFile(path.join(__dirname, 'public', 'privacy.html')));

  // ---- Static frontend ----
  app.use(express.static(path.join(__dirname, 'public')));
  // Catch-all so client-side routes still load index.html (Express 5 no longer accepts a bare '*' route)
  app.use((req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
  });

  app.listen(config.web.port, () => {
    logger.info(`Web dashboard listening on port ${config.web.port} (public URL: ${config.web.publicUrl})`);
  });
}

module.exports = { start };
