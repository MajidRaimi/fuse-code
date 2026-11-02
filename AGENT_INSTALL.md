# Installing fuse-code as a coding agent

These steps are for an AI coding agent (such as Claude Code) installing fuse-code on behalf of a user. A human can follow them too, but the [README](README.md) is friendlier.

fuse-code installs a `fuse` command that runs Claude Code on Humain's FUSE models. The user's regular `claude` command and its settings are not changed.

## What you need from the user

- **Their FUSE API key.** Ask for it if they haven't given it. You can't install without it.
- **A FUSE endpoint, only if they say they use a different one.** The default is `https://api.fuse.humainaic.com`. Pass another one as `FUSE_BASE_URL`.

## Handling the key

- Pass the key to the installer only through the `FUSE_API_KEY` environment variable, exactly as shown below.
- Never echo it, print it, put it in a file, or commit it. Don't repeat it back to the user.
- The installer saves it to a file that only the user can read. You don't need to store it anywhere.

## Install

The installer checks the key, then tests each model through Claude Code, three at a time. This can take several minutes. Run it with a long timeout (10 minutes) or in the background, and don't stop it early.

### Windows

Run the installer through Windows PowerShell. Don't use Git Bash or WSL for it.

From a PowerShell tool or terminal:

```powershell
$env:FUSE_API_KEY = 'THE_KEY'; irm https://raw.githubusercontent.com/MajidRaimi/fuse-code/main/install.ps1 | iex
```

From a Bash tool (Git Bash) on Windows:

```bash
FUSE_API_KEY='THE_KEY' powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/MajidRaimi/fuse-code/main/install.ps1 | iex"
```

Git and jq are not needed.

### macOS and Linux

```bash
git clone https://github.com/MajidRaimi/fuse-code.git ~/fuse-code
cd ~/fuse-code
FUSE_API_KEY='THE_KEY' ./install.sh
```

The installer needs `curl` and `jq`. If `jq` is missing, it tries Homebrew or apt. If apt asks for a sudo password you can't type, ask the user to run `sudo apt-get install -y jq`, then run the installer again.

If `~/fuse-code` already exists and is a fuse-code clone, run `git -C ~/fuse-code pull` instead of cloning.

## Success looks like

- The output ends with `Done. Run fuse to start Claude Code on FUSE.`
- It lists the `main`, `sonnet` and `small` models and the `/model` list.
- Lines like `Skipping <model>: ...` are normal. They mean that model didn't pass the check and was left out.

## Verify

Your current shell won't have the updated `PATH` yet, so use the full path:

- **Windows:** `& "$env:USERPROFILE\.local\bin\fuse.exe" -p "Reply with the single word ok"`. Use `fuse.cmd` if `fuse.exe` doesn't exist.
- **macOS and Linux:** `~/.local/bin/fuse -p "Reply with the single word ok"`

It should print `ok`.

Don't start an interactive `fuse` session yourself. Tell the user to open a new terminal and run `fuse`.

## Errors

| Message | What to do |
|---|---|
| `FUSE rejected that API key (HTTP 401)` or `403` | The key is wrong or revoked. Ask the user for the correct key and run the install again. |
| `no model passed the Claude Code check` | Show the user the `Skipping ...` lines. Their key probably has no chat model enabled. |
| `Could not reach <url>` | Network or proxy problem, or a wrong `FUSE_BASE_URL`. |
| `Could not build fuse.exe (...)` on Windows | This isn't fatal. `fuse.cmd` is used instead. Mention it to the user. |
| `running scripts is disabled on this system` | Use the exact commands above, which bypass the policy for that one process. If Group Policy blocks that too, tell the user to ask IT. |

## Afterwards

Tell the user:

- Open a **new** terminal and run `fuse`.
- Inside a session, `/model` lists the FUSE models.
- `fuse --refresh-models` re-tests the models after FUSE adds new ones.
- To uninstall, run `fuse --uninstall` themselves in a terminal. It asks for confirmation, which you can't answer.

Don't edit `~/.claude/settings.json` or anything under `~/.claude/fuse` by hand. The installer and `fuse` manage those.
