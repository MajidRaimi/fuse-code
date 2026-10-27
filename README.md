# fuse-code

Run [Claude Code](https://claude.com/claude-code) on Humain's FUSE models with one command.

Clone the repo, run one script, paste your FUSE API key. You get a `fuse` command that opens Claude Code on FUSE, with a green theme so you can tell it apart at a glance, and a `/model` list that only shows models that actually work for your key. Your regular `claude` command and its settings stay exactly as they were.

## Install

```bash
git clone https://github.com/MajidRaimi/fuse-code.git
cd fuse-code
./install.sh
```

The script asks for your FUSE API key (the input is hidden). That's the only question.

To skip the prompt, pass the key in the environment:

```bash
FUSE_API_KEY=your-key ./install.sh
```

Then open a new terminal and run:

```bash
fuse
```

### What you need

- macOS or Linux (on Windows, use WSL)
- `curl` and `jq`. macOS 15 and later ship `jq`. If it's missing, the installer installs it with Homebrew or apt when it can.
- Claude Code. If it isn't installed, the installer offers to install it with the official installer.
- A FUSE API key

## Using it

`fuse` takes everything `claude` takes:

```bash
fuse                     # new session
fuse -c                  # continue the last session
fuse "fix the failing test"
fuse --model 'zai-org/GLM-5.3-Flash[1m]'
```

Inside a session, `/model` lists the FUSE models that passed the install check.

## Models

On install, fuse-code reads the models your key can use from FUSE, then runs each candidate through a short Claude Code request. A model only goes in the `/model` list if it answered. Models that fail are skipped with the reason, for example:

```
Skipping tarjama/llmx-1.0: API Error: 400 "auto" tool choice requires ...
```

It fills Claude Code's three model slots like this:

| Slot | Used for | First choice, then fallbacks |
|---|---|---|
| main | the session model, and anything that asks for Opus | Kimi K3, GLM 5.3 Flash, DeepSeek V4.1 Flash |
| sonnet | subagents and tasks that ask for Sonnet | GLM 5.3 Flash, Kimi K3, DeepSeek V4.1 Flash |
| small | quick background work that asks for Haiku | Qwen 3.8 Flash, DeepSeek V4.1 Flash, GLM 5.3 Flash |

Models with a 1M context window get the `[1m]` suffix, so Claude Code compacts at the right size.

### Refresh the model list

When FUSE adds or removes models, run:

```bash
fuse --refresh-models
```

This lists your models again, tests them again, and rebuilds the `/model` list. It keeps the models you already use if they still work. New chat models with at least 200k context are picked up automatically and labeled "new on Fuse".

To go back to the default picks:

```bash
fuse --reset-models
```

To pin a slot yourself, pass it when refreshing:

```bash
FUSE_DEFAULT_MODEL=deepseek-ai/DeepSeek-V4.1-Flash fuse --refresh-models
```

Restart open `fuse` sessions to see the new list.

## Settings

| Variable | What it does | Default |
|---|---|---|
| `FUSE_API_KEY` | your key, also how you replace it | asked on first install |
| `FUSE_BASE_URL` | the FUSE endpoint | `https://api.fuse.humainaic.com` |
| `FUSE_THEME` | `dark` or `light` | `dark` |
| `FUSE_DEFAULT_MODEL` | pin the main slot | picked for you |
| `FUSE_SONNET_MODEL` | pin the sonnet slot | picked for you |
| `FUSE_SMALL_MODEL` | pin the small slot | picked for you |

Set any of them in front of `./install.sh` or `fuse --refresh-models`. They're saved, so you only set them once. For example, on a light terminal:

```bash
FUSE_THEME=light fuse --refresh-models
```

To change your key:

```bash
FUSE_API_KEY=new-key fuse --refresh-models
```

## What it installs

| Path | What |
|---|---|
| `~/.local/bin/fuse` | the launcher |
| `~/.config/fuse/env` | your key, endpoint and model picks, readable only by you (mode 600) |
| `~/.claude/fuse/settings.json` | the `/model` list and theme, used only by `fuse` |
| `~/.claude/themes/fuse.json`, `fuse-light.json` | the dark and light green themes |
| `~/.local/share/fuse-code/` | a copy of these scripts, so refresh works even if you delete the clone |

If `~/.local/bin` isn't on your `PATH`, the installer adds it to `~/.zshrc` or your bash profile.

If you already had a `fuse` command, it's moved to `fuse.bak-<date>` rather than overwritten.

## Your regular Claude Code stays untouched

`fuse` sets the FUSE endpoint, key and models only for the session it starts. Sessions you already have open, and every plain `claude` you start later, keep using your normal account.

There's one catch in Claude Code itself: picking a model with `/model` or a theme with `/theme` saves that choice to your global `~/.claude/settings.json`, which every session reads. A FUSE model saved there would break plain `claude`. So `fuse` checks that file when it starts and when it exits. Any FUSE model or FUSE theme it finds there gets put back to what you had before, or removed if you had nothing set.

## Update

```bash
fuse --self-update
```

This pulls the latest version into your clone and reinstalls it, keeping your key and model picks. It's the same as `git pull` followed by `./install.sh`.

## Uninstall

```bash
fuse --uninstall
```

This removes everything in the table above, including the saved key. Your regular Claude Code setup isn't touched.

## Troubleshooting

**`fuse: command not found`.** Open a new terminal, or run `export PATH="$HOME/.local/bin:$PATH"`.

**`FUSE rejected that API key`.** The key is wrong or revoked. Run `FUSE_API_KEY=new-key fuse --refresh-models`.

**`no model passed the Claude Code check`.** None of your models answered. Check that your key has access to a chat model such as Kimi K3 or GLM 5.3 Flash.

**A model disappeared from `/model`.** It failed the check on the last refresh. The installer prints the reason when that happens.

**A warning that Claude Code doesn't recognize a model.** That's expected for FUSE model names. It only means Claude Code assumes a 200k context for that model, which is safe.

## Security

- Your key is only ever stored in `~/.config/fuse/env`, with mode 600. It is never written to this repo or your shell profile. The hidden prompt keeps it out of your shell history too; passing `FUSE_API_KEY=...` on the command line does not.
- The key is passed to Claude Code and to `curl` through the environment and stdin, never as a command-line argument, so it doesn't show up in `ps`.
- `fuse` turns off Claude Code's non-essential traffic (telemetry, error reports, update checks) and the claude.ai connectors, so your FUSE sessions only talk to FUSE.

## License

MIT
