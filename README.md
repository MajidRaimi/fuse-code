# fuse-code

Run [Claude Code](https://claude.com/claude-code) on Humain's FUSE models with one command.

Clone the repo, run one script, paste your FUSE API key. You get a `fuse` command that opens Claude Code on FUSE, with a green theme so you can tell it apart at a glance, and a `/model` list that only shows models that actually work for your key. Your regular `claude` command and its settings stay exactly as they were.

## Install

### macOS and Linux

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

### Windows

Paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/MajidRaimi/fuse-code/main/install.ps1 | iex
```

It downloads the latest fuse-code, asks for your FUSE API key (the input is hidden), and sets everything up. No Git, jq or WSL needed.

If you'd rather work from a clone:

```powershell
git clone https://github.com/MajidRaimi/fuse-code.git
cd fuse-code
.\install.cmd
```

To skip the key prompt:

```powershell
$env:FUSE_API_KEY = "your-key"; .\install.cmd
```

Then open a new terminal (PowerShell, Command Prompt or Windows Terminal) and run `fuse`.

### What you need

- macOS, Linux, or Windows 10 (1809 or later) and Windows 11
- On macOS and Linux: `curl` and `jq`. macOS 15 and later ship `jq`. If it's missing, the installer installs it with Homebrew or apt when it can.
- On Windows: nothing extra. The installer only uses the Windows PowerShell that ships with Windows.
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

In PowerShell, set the variable first:

```powershell
$env:FUSE_THEME = "light"; fuse --refresh-models
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

On Windows the same files live under your user folder:

| Path | What |
|---|---|
| `%USERPROFILE%\.local\bin\fuse.exe` | the launcher, built on your machine during install |
| `%USERPROFILE%\.local\bin\fuse.cmd` | a fallback launcher, used if `fuse.exe` can't be built |
| `%USERPROFILE%\.config\fuse\env` | your key, endpoint and model picks, readable only by your Windows account |
| `%USERPROFILE%\.claude\fuse\settings.json` | the `/model` list and theme, used only by `fuse` |
| `%USERPROFILE%\.claude\themes\fuse.json`, `fuse-light.json` | the dark and light green themes |
| `%USERPROFILE%\.local\share\fuse-code\` | a copy of these scripts, so refresh works even if you delete the clone |

`fuse.exe` is a few lines of C# from `lib/FuseLauncher.cs`, compiled with the .NET Framework that ships with Windows. It passes the arguments it receives to Claude Code unchanged, including `&`, `%` and multi-line prompts. (Windows PowerShell 5.1 itself still drops empty arguments and strips quotes inside an argument before any program sees them, so put prompts with quotes in a file or use PowerShell 7.) If it can't be built, the installer says so and `fuse.cmd` takes over, which can't pass `&` or line breaks.

If `%USERPROFILE%\.local\bin` isn't on your user `PATH`, the installer adds it. That's also the folder the Claude Code installer uses, so this fixes `claude` not being found in new terminals too.

## Your regular Claude Code stays untouched

`fuse` sets the FUSE endpoint, key and models only for the session it starts. Sessions you already have open, and every plain `claude` you start later, keep using your normal account.

There's one catch in Claude Code itself: picking a model with `/model` or a theme with `/theme` saves that choice to your global `~/.claude/settings.json`, which every session reads. A FUSE model saved there would break plain `claude`. So `fuse` checks that file when it starts and when it exits. Any FUSE model or FUSE theme it finds there gets put back to what you had before, or removed if you had nothing set.

On Windows, closing the terminal window ends `fuse` without giving it a chance to clean up, so `fuse` starts a small hidden helper that waits for the session to end and does the same check. It exits as soon as it's done.

## Update

```bash
fuse --self-update
```

This pulls the latest version into your clone and reinstalls it, keeping your key and model picks. It's the same as `git pull` followed by `./install.sh`.

On Windows, if you installed with the one-liner or Git isn't installed, it downloads the latest version instead.

## Uninstall

```bash
fuse --uninstall
```

This removes everything in the table above, including the saved key. Your regular Claude Code setup isn't touched.

## Troubleshooting

**`fuse: command not found`.** Open a new terminal, or run `export PATH="$HOME/.local/bin:$PATH"`.

**`'fuse' is not recognized` on Windows.** Open a new terminal so it picks up the updated `PATH`.

**`running scripts is disabled on this system` on Windows.** Run the installer through `.\install.cmd`, or with the one-liner above, which start PowerShell with the execution policy relaxed for that one process. If your organization enforces the policy through Group Policy, ask IT to allow it or use WSL with the macOS and Linux steps.

**`FUSE rejected that API key`.** The key is wrong or revoked. Run `FUSE_API_KEY=new-key fuse --refresh-models`.

**`no model passed the Claude Code check`.** None of your models answered. Check that your key has access to a chat model such as Kimi K3 or GLM 5.3 Flash.

**A model disappeared from `/model`.** It failed the check on the last refresh. The installer prints the reason when that happens.

**A warning that Claude Code doesn't recognize a model.** That's expected for FUSE model names. It only means Claude Code assumes a 200k context for that model, which is safe.

## Security

- Your key is only ever stored in `~/.config/fuse/env`, with mode 600 (on Windows, with permissions that allow only your account). It is never written to this repo or your shell profile. The hidden prompt keeps it out of your shell history too; passing `FUSE_API_KEY=...` on the command line does not.
- The key is passed to Claude Code and to `curl` through the environment and stdin, never as a command-line argument, so it doesn't show up in `ps`.
- `fuse` turns off Claude Code's non-essential traffic (telemetry, error reports, update checks) and the claude.ai connectors, so your FUSE sessions only talk to FUSE.

## License

MIT
