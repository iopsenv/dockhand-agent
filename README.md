# x-dockhand-agent

Deploys a [Dockhand](https://github.com/finsys) agent (`ghcr.io/finsys/hawser`) on a host, connecting it to a central Dockhand dashboard so the host's Docker stacks can be managed remotely.

## Requirements

- Docker Engine + Docker Compose plugin
- A running Dockhand Main dashboard (to get `DH_MAIN_HOSTNAME` and a `DH_TOKEN`)

## Quick start

```bash
git clone <this-repo-url> x-dockhand-agent
cd x-dockhand-agent
bash bootstrap.sh
```

`bootstrap.sh` will:

1. Create `.env` from `env.example` if it doesn't exist yet (or create an empty `.env` if the example is missing).
2. Suggest a value for `LOCAL_HOSTNAME`: the existing value in `.env`, or the system hostname if the value is missing or a placeholder. Press Enter to accept it, or type a different name.
3. Prompt for `DH_MAIN_HOSTNAME` and `DH_TOKEN` if either is missing or still a placeholder. Token input is hidden.
4. Create the external Docker volume (`x-dockhand-stacks_<LOCAL_HOSTNAME>`) if it doesn't exist.
5. Run `docker compose up -d`.

You can re-run the script: it always asks you to confirm `LOCAL_HOSTNAME`, keeps already-set connection values, and reuses the existing volume when the name stays the same. Run it from the repository directory.

Example prompt:

```text
LOCAL_HOSTNAME [yoursystemname.local]:
```

Pressing Enter saves `LOCAL_HOSTNAME=yoursystemname.local` in `.env`. Typing `customname` saves that name instead.

## Environment variables

| Variable | Description |
| --- | --- |
| `LOCAL_HOSTNAME` | Name shown for this agent in Dockhand. Also sets the container hostname to `dockhand.<LOCAL_HOSTNAME>` and the external stacks volume to `x-dockhand-stacks_<LOCAL_HOSTNAME>`. Bootstrap suggests the system hostname on first setup. |
| `DH_MAIN_HOSTNAME` | Hostname of your Dockhand Main dashboard, without a scheme or path (for example, `dockhand.example.com`). Compose connects to `wss://<DH_MAIN_HOSTNAME>/api/hawser/connect`. |
| `DH_TOKEN` | Auth token for this agent; get it from the Dockhand dashboard under *Environments*. |

Copy `env.example` to `.env` and fill these in, or run `bootstrap.sh` to configure them interactively. Use a hostname-style value for `LOCAL_HOSTNAME`, such as `yoursystemname.local`: letters, digits and hyphens, with a letter or digit at each end. The script currently checks that the name is nonempty but does not validate its format.

`.env` contains literal configuration values. Set an actual name for `LOCAL_HOSTNAME`; `$(hostname)` in `.env` is not executed. Bootstrap obtains the suggested system name itself.

## Manual setup (without bootstrap.sh)

Run these commands from the repository directory:

```bash
cp env.example .env
nano .env   # fill in LOCAL_HOSTNAME, DH_MAIN_HOSTNAME and DH_TOKEN
```

After saving `.env`, create the matching volume and start the stack. For example, if you set `LOCAL_HOSTNAME=customname`:

```bash
docker volume create x-dockhand-stacks_customname
docker compose up -d
```

The volume suffix must match the `LOCAL_HOSTNAME` value in `.env`.

## Notes

- Changing `LOCAL_HOSTNAME` after deployment changes the agent name, container hostname and volume name. Bootstrap creates the new volume if needed; it does not copy the existing stacks into it. The old volume remains available. Keep the same name to reuse your existing stacks.
- The volume stores stacks at `/data/stacks` inside the container. It is `external: true` on purpose — a `docker compose down` (even `down -v`) won't touch it. It has to be removed manually with `docker volume rm` if you no longer need its contents.
- The container mounts `/var/run/docker.sock`, giving it full control over Docker on that host. Only deploy this on machines you intend to manage through Dockhand.

## Acknowledgments

The setup in this repo (compose file structure, bootstrap script, docs) was
developed with the help of Claude Code. The idea, the requirements, and the
decisions behind it (external volumes for safe backups, per-host `.env`,
polling-based git updates instead of webhooks, etc.) are mine — Claude helped
turn them into working scripts and documentation.

## Future feature mental note :)

- to add optional systemd service + timer for git reset --hard origin/main