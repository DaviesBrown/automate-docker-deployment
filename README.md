# Automated Docker Deployment Script

Bash script that automates deployment of Dockerized applications to remote servers with Nginx reverse proxy.

## Features

- Automated Git cloning with PAT authentication
- Docker & Docker Compose support
- Auto-installs Docker, Docker Compose, and Nginx on remote server
- Nginx reverse proxy configuration
- Comprehensive logging and error handling
- Idempotent (safe to re-run)
- Cleanup mode to remove deployments

## Prerequisites

**Local:** Bash, Git, SSH client, rsync  
**Remote:** Ubuntu/Debian server with SSH access and sudo privileges

## Usage

### Deploy Application

```bash
chmod +x deploy.sh
./deploy.sh
```

You'll be prompted for:
- Git repository URL
- Personal Access Token (PAT)
- Branch name (default: `main`)
- SSH username and server IP
- SSH key path (default: `~/.ssh/id_rsa`)
- Application port (default: `3000`)

### Remove Deployment

```bash
./deploy.sh --cleanup
```

## How It Works

1. **Collect Parameters** - Validates user inputs
2. **Clone Repository** - Clones/pulls repo using PAT
3. **Verify Structure** - Checks for Dockerfile or docker-compose.yml
4. **SSH Check** - Tests connection to remote server
5. **Prepare Environment** - Installs Docker, Docker Compose, Nginx
6. **Deploy App** - Transfers files, builds and runs container
7. **Configure Nginx** - Sets up reverse proxy (port 80 → app port)
8. **Validate** - Confirms all services running correctly

## Logging

Logs saved to `deploy_YYYYMMDD_HHMMSS.log` with timestamps and color-coded output.

## Troubleshooting

- **SSH fails:** Check key path/permissions and server IP
- **Container won't start:** Check logs with `docker logs <container-name>`
- **Nginx errors:** Run `sudo nginx -t` and check `/var/log/nginx/error.log`

## Author

HNG DevOps Stage 1 Project