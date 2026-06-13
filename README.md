## Server Admin

### Crontab thingy

```crontab
# 30 23 *   *   *     /usr/sbin/rtcwake -m mem -u -t $(date +\%s -d "tomorrow 06:30am")
```

### BIOS settings

- AC power setting: last state

### Odysseus

Odysseus is pinned to its stable `main` branch as a Git submodule. Clone this
stack with submodules, or initialize it after cloning:

```bash
git submodule update --init --recursive
docker compose up -d --build odysseus odysseus-chromadb odysseus-searxng odysseus-ntfy
```

Runtime data lives under the ignored `odysseus-data/` directory. The web UI is
available on port `7000`; companion services bind to loopback only.
