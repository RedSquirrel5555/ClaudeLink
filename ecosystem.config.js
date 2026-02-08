module.exports = {
  apps: [
    {
      name: "claudelink",
      script: "bot.py",
      interpreter: "python",
      restart_delay: 5000,
      max_restarts: 10,
      autorestart: true,
      env: {
        PYTHONUNBUFFERED: "1",
      },
    },
  ],
};
