# Installation

## Requirements

- Apple Intelligence turned on and the on-device model downloaded
- Command Line Tools (`swiftc`)
- [KanAI](https://github.com/k1bot2026/kanboard-plugin-kanai) for Kanboard with its `local` provider

Tested with Swift 6.4 on macOS 27.0. The FoundationModels framework is marked macOS 26.0 and later in the SDK, and older releases are untested


## Build and run

1. `sh build.sh` builds `./kanai-afm-bridge`
2. `./kanai-afm-bridge` starts brings it up on `127.0.0.1:11437`
3. `sh test.sh` (from a second terminal) to check the model list, chat, a prompt-injection canary, JSON mode, the request guards, and the context-overflow error


## SSH reverse tunnel to the Kanboard server

Kanboard on another machine can't see your Mac's loopback, so opens a reverse tunnel on your Mac:

```
ssh -N -R 127.0.0.1:11437:127.0.0.1:11437 user@your-kanboard-server
```

On the server, `curl -s http://127.0.0.1:11437/v1/models` should list `apple-foundation`. The tunnel exists only while your Mac is awake and the SSH process is running.


## Run at login

`launchd/install.sh` installs per-user LaunchAgents that start the bridge at login and will restart it if it exits.

1. `sh build.sh`
2. `sh launchd/install.sh` installs the bridge alone. Logs go to `~/Library/Logs/kanai-afm-bridge.log`.

Settings are environment variables on the install command. All are optional:

| Variable | Default | Description |
|---|---|---|
| `KANAI_AFM_BRIDGE_PORT` | `11437` | Port for the bridge and for both ends of the tunnel |
| `KANAI_TUNNEL_SSH_PORT` | `22` | SSH port of the Kanboard server |
| `KANAI_TUNNEL_KEY` | `~/.ssh/kanai-tunnel` | Private key used by the tunnel |
| `KANAI_AFM_BRIDGE_TOKEN` | none | Bearer token the bridge requires. Letters, digits, and `. _ ~ -` only. The LaunchAgent file are always mode 600. KanAI's `local` provider can't send it, so leave it unset for KanAI |

Example: `KANAI_TUNNEL_SSH_PORT=2222 sh launchd/install.sh tunnel@your-kanboard-server`

To stop, start, or restart, see the "Stop, start, and restart" section of README.md.

For a tunnel to survive restarts, it needs a key without a passphrase that's restricted on the server to this one forward. Use an unprivileged account on the server (the examples call it `tunnel`) and *not* root. The tunnel account can be separate from the account that runs Kanboard's PHP, because the firewall rule below allows the Kanboard user and not the tunnel account:

1. `ssh-keygen -t ed25519 -N "" -f ~/.ssh/kanai-tunnel`
2. Add the public key to `~tunnel/.ssh/authorized_keys` on the server as one line beginning with `restrict,port-forwarding,permitlisten="127.0.0.1:11437"` (use your port if it isn't 11437), then a space and the contents of `~/.ssh/kanai-tunnel.pub`
3. On the server, set `ClientAliveInterval 30` and `ClientAliveCountMax 3` in `sshd_config` and reload sshd, so a dead tunnel listener gets cleared and the port can be reused
4. Connect once manually so the server's host key is saved: `ssh -i ~/.ssh/kanai-tunnel tunnel@your-kanboard-server` (the restricted key refuses a shell, and that's expected). The agent runs with `BatchMode` and fails silently on an unknown host key
5. `sh launchd/install.sh tunnel@your-kanboard-server` installs both agents

`sh launchd/uninstall.sh` uninstalls it.

A LaunchAgent starts when you log in. After a restart, the bridge comes back up once you're logged in, so unattended restarts need automatic login (FileVault doesn't allow this, though). A Mac that's asleep or off obviously won't be able to answer.


## Firewall for the tunnel port

Through the tunnel, the port opens on the server's loopback, so every local user and web app on the server can reach it. These steps are for a server that runs firewalld. They add a rule that lets only the account that runs Kanboard's PHP and root connect to `127.0.0.1:11437`. The rule matches the process that opens the connection, and that is Kanboard's PHP and not the sshd listener. A tunnel account that isn't the Kanboard user doesn't need to be allowed, and allowing only that account would block KanAI. This is reasoned from how the owner match works and hasn't been tested with two separate accounts. Root can always reach the port.

Replace `kanboard` with the name of the account that runs Kanboard's PHP.

1. Add the following rules as root:

   ```bash
   firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -o lo -p tcp -d 127.0.0.1 --dport 11437 -m owner --uid-owner kanboard -j ACCEPT
   firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 1 -o lo -p tcp -d 127.0.0.1 --dport 11437 -m owner --uid-owner 0 -j ACCEPT
   firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 2 -o lo -p tcp -d 127.0.0.1 --dport 11437 -j REJECT
   ```

2. Reload so they take effect.

   ```bash
   firewall-cmd --reload
   ```

3. Check that all three rules are listed, that they were saved and not just loaded, and that firewalld is running.

   ```bash
   firewall-cmd --direct --get-all-rules && firewall-cmd --state
   grep 11437 /etc/firewalld/direct.xml
   ```

4. Test as a user that should be blocked (any account except the Kanboard user and root). It should fail with curl exit 7.

   ```bash
   sudo -u www-data curl -s -m 5 http://127.0.0.1:11437/v1/models; echo "exit $?"
   ```

5. Test as the Kanboard user. It should list `apple-foundation`.

   ```bash
   sudo -u kanboard curl -s -m 5 http://127.0.0.1:11437/v1/models
   ```

An incorrect or deleted SSH key makes the Mac retry every 30s. If the server runs fail2ban, add your Mac's public IP to `ignoreip` for the `sshd` jail or the retries might get it banned.

### If firewalld ends up in a FAILED state

A bad rule is probably blocking `--permanent` changes. Back up `/etc/firewalld/direct.xml`, rewrite it with the three rules, and restart.

```xml
<?xml version="1.0" encoding="utf-8"?>
<direct>
  <rule ipv="ipv4" table="filter" chain="OUTPUT" priority="0">-o lo -p tcp -d 127.0.0.1 --dport 11437 -m owner --uid-owner kanboard -j ACCEPT</rule>
  <rule ipv="ipv4" table="filter" chain="OUTPUT" priority="1">-o lo -p tcp -d 127.0.0.1 --dport 11437 -m owner --uid-owner 0 -j ACCEPT</rule>
  <rule ipv="ipv4" table="filter" chain="OUTPUT" priority="2">-o lo -p tcp -d 127.0.0.1 --dport 11437 -j REJECT</rule>
</direct>
```

```bash
cp /etc/firewalld/direct.xml /root/direct.xml.bak && systemctl restart firewalld
```

### After a server reboot

A server reboot doesn't affect the tunnel itself. The Mac creates the forward when it connects, so the server keeps nothing to restore. The firewall is the only part that has to come back on its own: keep the rules permanent and make sure firewalld starts at boot.

1. Confirm firewalld starts at boot. It should print `enabled`. If it doesn't, run `systemctl enable firewalld`.

   ```bash
   systemctl is-enabled firewalld
   ```

2. Confirm sshd clears a dead tunnel listener after the connection drops, so the port can be reused when the Mac reconnects. Each line should be set at least once.

   ```bash
   grep -E '^(ClientAliveInterval|ClientAliveCountMax)' /etc/ssh/sshd_config
   ```

3. Reboot the server, then wait for the Mac to reconnect. The Mac's LaunchAgent restarts `ssh -N` every 30s until sshd is up. Time to reconnect isn't measured.

4. Run steps 3 to 5 of the firewall steps again as root.

A server reboot was tested: the tunnel reconnected on its own and the rules stayed in force. The reconnect time wasn't measured.


## KanAI's scheduled digests

KanAI's `kanai:digest` command writes a daily summary for every project that has the auto digest turned on. It runs from cron on the Kanboard server, which has no idea whether your Mac is awake. If your Mac is off, the digest fails with an error.

To guard against this, ask the bridge for its model list first and run the digest only if it answers. When your Mac is off or the tunnel is down, the check fails and cron skips the day.

1. As the Kanboard user, run `crontab -e`
2. Add one line (cron uses the server's clock, so pick the hour with that in mind):

```
0 9 * * * cd /path/to/kanboard && curl -sf -m 5 http://127.0.0.1:11437/v1/models >/dev/null && ./cli kanai:digest >> /tmp/kanai-digest.log 2>&1
```

The guard has a few limits: a skipped day isn't retried or logged, a Mac that goes to sleep during the run leaves some projects with a digest and some without, and the model list answers even when the on-device model is unavailable. Re-running after a partial run duplicates the projects that already have one.

The cron job connects to the port as its own user, so that user must be the one the firewall rule allows (reasoned and not tested). The `kanai:digest` idempotence claim is read from `DigestCommand.php` and not tested. If the tunnel is down at run time, cron skips the day and writes no log line.

Run it once a day at most. `kanai:digest` doesn't check for an existing digest, so a second run on the same day will add a duplicate conversation.

A skipped day is normal if your Mac is often asleep at that hour. For a digest every day, you can use OpenAI or Claude in KanAI's settings instead.


## Compatibility

- Kanboard with KanAI 1.7.0
- No changes to KanAI or Kanboard are needed
