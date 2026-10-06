---
name: ece-claude-kit
description: Maintain this ECE Claude Kit repository, which installs Claude Code, herdr and a Remote Control launcher on CMU ECE cluster nodes without root, keeping binaries and credentials on node-local /scratch.
---

# ECE Claude Kit maintenance

Read the repository README for the wizard, file layout and daily usage. Normal usage is the one-line `install.sh` bootstrap or `ece-kit` without arguments; keep the Chinese numbered menu, visible defaults, saved settings and the status-based default choice. Subcommands exist for automation only. Resolve the repository relative to this skill (`../..`).

Environment facts that shape the design (from ECE-ITS documentation): home directories are Andrew AFS with a 2GB quota, and exceeding it blocks login; AFS tokens expire after 24 hours, so long-running processes must not depend on writing to AFS; `/scratch` is node-local, roughly 512GB, and files older than 28 days are deleted automatically; there is no root. Users switch nodes, so everything node-local must be re-creatable by re-running the installer, and everything in home must be shared safely between nodes.

Keep Claude Code binaries under `/scratch/$USER/claude-bin` via the `~/.local/share/claude` symlink, and `CLAUDE_CONFIG_DIR` at `/scratch/$USER/claude-config`. Keep `~/.local/bin/claude` as the kit launcher (marked `# ece-claude-kit launcher`) that picks the newest version present on the current node; never restore the installer's version symlink there, because a shared home would point other nodes at missing versions. The launcher also sets `CLAUDE_CONFIG_DIR` when the shell config was not loaded. Keep `/scratch/$USER` at mode 700.

Shell configuration is a single marked block (`# >>> ece-claude-kit >>>`) written to the login shell's rc file (zsh, bash or tcsh syntax). Rewriting must replace the block, including the earlier `ece-claude` block, never append duplicates. Pasted interactive commands must not rely on inline `#` comments, because zsh disables interactive comments by default; the zsh block enables `interactivecomments`.

Remote Control requires a claude.ai subscription login (not API keys) and an interactive trust/enable confirmation on first run; do not try to bypass either. herdr replaces tmux for persistence only; do not use herdr's own remote feature. `ece-claude` warns when it is not inside herdr, tmux or screen. Do not add tunnels, exit nodes, Tailscale or other services that open paths into the CMU network, and do not default to permission-bypass modes on this shared cluster.

Use official installers (`https://claude.ai/install.sh`, `https://herdr.dev/install.sh`) and the user's chosen Claude release channel. Check current official documentation before changing CLI flags (`claude remote-control`, `claude auth status|login`, `herdr integration install claude`). Untested assumptions to keep visible in the README: herdr's prebuilt binary on RHEL 8 glibc, and herdr integration writing to `CLAUDE_CONFIG_DIR`.

After any change run `bash tests/test_kit.sh` (temporary HOME and scratch, fake `curl` and `getent`, no network or login) and `shellcheck -x entrypoint.sh install.sh bin/* tests/*.sh`. Add a test for each new behavior. Never commit credentials, session transcripts or personal identifiers such as an Andrew ID; documentation uses placeholders.
