# Version control for your daybook

Your daybook is just `YYYY-MM-DD.day` plain-text files on disk, so it drops straight
into git — you get a full, diffable history of your time log and a safety net, with no
extra machinery inside daylog. Pair it with [`autosave`](../doc/daylog.txt) (`:help
daylog-autosave`) and a file-watcher that auto-commits, and your daybook is saved and
committed hands-free as you log.

> **Optional.** daylog needs none of this — it's a nice add-on if you want your daybook
> under version control. Any file backup or sync (git, a synced folder, a cron job)
> works just as well; this guide is one convenient recipe.

## 1. Put your daybook under git

```sh
cd ~/daylog          # your daybook.root
git init
```

git needs an identity or commits fail; set one if you don't have a global one:

```sh
git config user.name  "Your Name"
git config user.email "you@example.com"
```

## 2. Auto-commit on change with gitwatch

[`gitwatch`](https://github.com/gitwatch/gitwatch) watches a directory and commits every
change as it lands. It shells out to `git` and `inotifywait`, so install
`inotify-tools` first (`sudo apt install inotify-tools`, or your package manager's
equivalent). Then drop the script somewhere on your `PATH`:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/gitwatch/gitwatch/master/gitwatch.sh \
  -o ~/.local/bin/gitwatch
chmod +x ~/.local/bin/gitwatch

gitwatch -s 5 ~/daylog
```

`-s 5` is the settle delay: gitwatch waits 5 seconds after the last change before
committing, so a burst of writes collapses into one commit. This complements
`autosave` nicely — autosave writes the `.day` file a few seconds after you stop
typing, and gitwatch commits it a few seconds after that.

## 3. Keep it running (systemd user service)

On Linux, run gitwatch as a user service so it starts with your session and restarts
if it dies. Create `~/.config/systemd/user/gitwatch-daybook.service`:

```ini
[Unit]
Description=gitwatch auto-commit for ~/daylog
Documentation=https://github.com/gitwatch/gitwatch
After=default.target

[Service]
Type=simple
# gitwatch shells out to git/inotifywait; give the user service a usable PATH.
Environment=PATH=/usr/local/bin:/usr/bin:/bin:%h/.local/bin
ExecStart=%h/.local/bin/gitwatch -s 5 %h/daylog
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

Then enable and start it:

```sh
systemctl --user daemon-reload
systemctl --user enable --now gitwatch-daybook.service

# watch it work:
journalctl --user -u gitwatch-daybook.service -f
```

`enable` starts it whenever your systemd user instance comes up (i.e. when you open a
session); `Restart=on-failure` brings it back if it crashes. If you want it running
even with no login session open (e.g. a headless box), also run `loginctl
enable-linger "$USER"` — otherwise skip it; when you always edit with a shell open the
user instance is already up.

Not on systemd? Run `gitwatch -s 5 ~/daylog` under whatever keeps background jobs on
your platform — launchd on macOS, a terminal multiplexer, or a `@reboot` cron entry.

## Notes

- Commits are **local by default**. To push to a remote as well, add `-r <remote>` to
  the `gitwatch` command (e.g. `gitwatch -s 5 -r origin ~/daylog`).
- gitwatch commits on a *change event*, not at startup, so the first commit lands the
  next time a file changes — capturing whatever is already in the daybook. Run
  `git add -A && git commit -m "baseline"` first if you'd rather start from a clean
  snapshot.
