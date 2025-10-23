#!/bin/bash

################################################################################
# Automated Docker Deployment Script
# This script deploys a Dockerized application to a remote server with Nginx
################################################################################

set -e  # Exit on any error
set -o pipefail  # Exit if any command in a pipeline fails

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log file with timestamp (absolute path)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"

################################################################################
# Helper Functions
################################################################################

log() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[INFO $timestamp]${NC} $1" | tee -a "$LOG_FILE"
    echo "[INFO $timestamp] $1" >> "$LOG_FILE.detailed"
}

log_error() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ERROR $timestamp]${NC} $1" | tee -a "$LOG_FILE"
    echo "[ERROR $timestamp] $1" >> "$LOG_FILE.detailed"
}

log_warn() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[WARN $timestamp]${NC} $1" | tee -a "$LOG_FILE"
    echo "[WARN $timestamp] $1" >> "$LOG_FILE.detailed"
}

log_debug() {
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[DEBUG $timestamp] $1" >> "$LOG_FILE.detailed"
}

# Error handling trap
error_exit() {
    log_error "Script failed at line $1"
    exit 1
}

trap 'error_exit $LINENO' ERR

################################################################################
# Task 1: Collect Parameters from User Input
################################################################################

collect_parameters() {
    log "=== Task 1: Collecting Deployment Parameters ==="
    
    # Git Repository URL
    read -p "Enter Git Repository URL: " GIT_REPO
    if [[ ! "$GIT_REPO" =~ ^https?:// ]]; then
        log_error "Invalid repository URL"
        exit 1
    fi
    
    # Personal Access Token
    read -sp "Enter Personal Access Token (PAT): " GIT_TOKEN
    echo ""
    if [[ -z "$GIT_TOKEN" ]]; then
        log_error "PAT cannot be empty"
        exit 1
    fi
    
    # Branch name
    read -p "Enter branch name [main]: " GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}
    
    # SSH Username
    read -p "Enter remote server username: " SSH_USER
    if [[ -z "$SSH_USER" ]]; then
        log_error "Username cannot be empty"
        exit 1
    fi
    
    # Server IP
    read -p "Enter remote server IP address: " SERVER_IP
    if [[ ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid IP address format"
        exit 1
    fi
    
    # SSH Key Path
    read -p "Enter SSH key path [~/.ssh/id_rsa]: " SSH_KEY
    SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
    SSH_KEY="${SSH_KEY/#\~/$HOME}"  # Expand tilde
    
    if [[ ! -f "$SSH_KEY" ]]; then
        log_error "SSH key not found at $SSH_KEY"
        exit 1
    fi
    
    # Application Port
    read -p "Enter application internal port [3000]: " APP_PORT
    APP_PORT=${APP_PORT:-3000}
    
    # Domain name (optional for SSL)
    read -p "Enter domain name (optional, leave empty for IP-only access): " DOMAIN_NAME
    
    # SSL Configuration
    ENABLE_SSL="no"
    if [[ -n "$DOMAIN_NAME" ]]; then
        read -p "Enable SSL/HTTPS with Let's Encrypt? (yes/no) [yes]: " ENABLE_SSL
        ENABLE_SSL=${ENABLE_SSL:-yes}
        
        if [[ "$ENABLE_SSL" == "yes" ]]; then
            read -p "Enter email for SSL certificate notifications: " SSL_EMAIL
            if [[ -z "$SSL_EMAIL" ]]; then
                log_error "Email is required for SSL certificates"
                exit 1
            fi
        fi
    fi
    
    # App name (derived from repo)
    APP_NAME=$(basename "$GIT_REPO" .git)
    
    log "Parameters collected successfully"
    log "Repository: $GIT_REPO"
    log "Branch: $GIT_BRANCH"
    log "Server: $SSH_USER@$SERVER_IP"
    log "App Port: $APP_PORT"
    log "App Name: $APP_NAME"
    if [[ -n "$DOMAIN_NAME" ]]; then
        log "Domain: $DOMAIN_NAME"
        log "SSL Enabled: $ENABLE_SSL"
    fi
}

################################################################################
# Task 2: Clone the Repository
################################################################################

clone_repository() {
    log "=== Task 2: Cloning Repository ==="
    log_debug "Repository URL: $GIT_REPO"
    log_debug "Target branch: $GIT_BRANCH"
    
    # Create authenticated URL
    AUTH_REPO=$(echo "$GIT_REPO" | sed "s|https://|https://$GIT_TOKEN@|")
    
    if [[ -d "$APP_NAME" ]]; then
        log_warn "Directory $APP_NAME already exists, pulling latest changes"
        cd "$APP_NAME"
        
        # Fetch all branches
        log "Fetching latest changes from remote..."
        if ! git fetch origin 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Failed to fetch from repository"
            exit 1
        fi
        
        # Switch to the specified branch
        log "Switching to branch: $GIT_BRANCH"
        if ! git checkout "$GIT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Failed to switch to branch $GIT_BRANCH"
            exit 1
        fi
        
        # Pull latest changes
        log "Pulling latest changes..."
        if ! git pull origin "$GIT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Failed to pull latest changes from repository"
            exit 1
        fi
    else
        log "Cloning repository..."
        log_debug "Cloning branch $GIT_BRANCH from $GIT_REPO"
        if ! git clone -b "$GIT_BRANCH" "$AUTH_REPO" "$APP_NAME" 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Failed to clone repository"
            exit 1
        fi
        cd "$APP_NAME"
        
        # Verify we're on the correct branch
        CURRENT_BRANCH=$(git branch --show-current)
        log "Currently on branch: $CURRENT_BRANCH"
        if [[ "$CURRENT_BRANCH" != "$GIT_BRANCH" ]]; then
            log_warn "Branch mismatch detected, switching to $GIT_BRANCH"
            git checkout "$GIT_BRANCH" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    
    log "Repository cloned/updated successfully"
    log_debug "Final branch: $(git branch --show-current)"
    log_debug "Latest commit: $(git log -1 --oneline)"
}

################################################################################
# Task 3: Navigate and Verify Project Structure
################################################################################

verify_project() {
    log "=== Task 3: Verifying Project Structure ==="
    
    PROJECT_DIR=$(pwd)
    log "Current directory: $PROJECT_DIR"
    
    if [[ -f "Dockerfile" ]]; then
        log "✓ Dockerfile found"
        DEPLOY_TYPE="dockerfile"
    elif [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        log "✓ docker-compose.yml found"
        DEPLOY_TYPE="compose"
    else
        log_error "No Dockerfile or docker-compose.yml found"
        exit 1
    fi
}

################################################################################
# Task 4: SSH Connectivity Check
################################################################################

check_ssh_connection() {
    log "=== Task 4: Testing SSH Connection ==="
    
    # First check if server is reachable via ping
    log "Checking network connectivity to $SERVER_IP..."
    if ping -c 3 -W 5 "$SERVER_IP" > /dev/null 2>&1; then
        log "✓ Server is reachable (ping successful)"
    else
        log_warn "Server did not respond to ping (might have ICMP disabled)"
    fi
    
    # Check if SSH port is open
    log "Checking if SSH port (22) is accessible..."
    if timeout 10 bash -c "echo > /dev/tcp/$SERVER_IP/22" 2>/dev/null; then
        log "✓ SSH port 22 is open and accessible"
    else
        log_error "Cannot connect to SSH port 22 on $SERVER_IP"
        log_error "Please check: 1) Server is running 2) Firewall allows SSH 3) SSH service is active"
        exit 1
    fi
    
    # Attempt SSH connection
    log "Attempting SSH connection..."
    if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo 'SSH connection successful'" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Cannot connect to $SSH_USER@$SERVER_IP"
        log_error "Please check: 1) SSH key is correct 2) Username is correct 3) Key permissions (chmod 600)"
        exit 1
    fi
    
    log "✓ SSH connection established successfully"
    log_debug "SSH user: $SSH_USER"
    log_debug "SSH key: $SSH_KEY"
}

################################################################################
# Task 5: Prepare Remote Environment
################################################################################

prepare_remote_environment() {
    log "=== Task 5: Preparing Remote Environment ==="
    
    if ! ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << 'ENDSSH' 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        echo "Updating system packages..."
        sudo apt-get update -qq
        
        # Install Docker if not present
        if ! command -v docker &> /dev/null; then
            echo "Installing Docker..."
            sudo apt-get install -y docker.io
            sudo systemctl enable docker
            sudo systemctl start docker
        else
            echo "Docker already installed"
        fi
        
        # Install Docker Compose if not present
        if ! command -v docker-compose &> /dev/null; then
            echo "Installing Docker Compose..."
            sudo apt-get install -y docker-compose
        else
            echo "Docker Compose already installed"
        fi
        
        # Install Nginx if not present
        if ! command -v nginx &> /dev/null; then
            echo "Installing Nginx..."
            sudo apt-get install -y nginx
            sudo systemctl enable nginx
            sudo systemctl start nginx
        else
            echo "Nginx already installed"
        fi
        
        # Install Certbot if not present (for SSL)
        if ! command -v certbot &> /dev/null; then
            echo "Installing Certbot..."
            sudo apt-get install -y certbot python3-certbot-nginx
        else
            echo "Certbot already installed"
        fi
        
        # Add user to docker group
        sudo usermod -aG docker $USER || true
        
        echo "Verifying installations..."
        docker --version
        docker-compose --version
        nginx -v
        certbot --version
        
        echo "Remote environment ready"
ENDSSH
    then
        log_error "Failed to prepare remote environment"
        exit 1
    fi
    
    log "✓ Remote environment prepared"
}

################################################################################
# Task 6: Deploy the Dockerized Application
################################################################################

deploy_application() {
    log "=== Task 6: Deploying Application ==="
    
    REMOTE_DIR="/home/$SSH_USER/$APP_NAME"
    
    # Transfer files to remote server
    log "Transferring files to remote server..."
    if ! ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_DIR" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to create remote directory"
        exit 1
    fi
    
    if ! rsync -avz -e "ssh -i $SSH_KEY" --exclude='.git' "$PROJECT_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_DIR/" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to transfer files to remote server"
        exit 1
    fi
    
    log "Files transferred successfully"
    
    # Build and run on remote server
    log "Building and running Docker container..."
    
    if [[ "$DEPLOY_TYPE" == "compose" ]]; then
        if ! ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
            set -e
            cd $REMOTE_DIR
            
            # Stop existing containers
            echo "Stopping existing containers..."
            docker-compose down || true
            
            # Build and start
            echo "Building and starting containers..."
            docker-compose up -d --build
            
            # Wait for container to be healthy
            echo "Waiting for containers to be healthy..."
            sleep 5
            
            # Check container health
            echo "Checking container health..."
            MAX_RETRIES=12
            RETRY_COUNT=0
            
            while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
                if docker-compose ps | grep -q "Up"; then
                    echo "✓ Containers are up and running"
                    docker-compose ps
                    break
                fi
                
                RETRY_COUNT=\$((RETRY_COUNT + 1))
                if [ \$RETRY_COUNT -eq \$MAX_RETRIES ]; then
                    echo "✗ Container health check failed after \$MAX_RETRIES attempts"
                    docker-compose logs --tail=50
                    exit 1
                fi
                
                echo "Waiting for containers... (attempt \$RETRY_COUNT/\$MAX_RETRIES)"
                sleep 5
            done
            
            # Show container logs
            echo "Recent container logs:"
            docker-compose logs --tail=20
ENDSSH
        then
            log_error "Failed to deploy application using docker-compose"
            exit 1
        fi
    else
        if ! ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
            set -e
            cd $REMOTE_DIR
            
            # Stop and remove existing container
            echo "Stopping existing container..."
            docker stop $APP_NAME 2>/dev/null || true
            docker rm $APP_NAME 2>/dev/null || true
            
            # Remove old image to force rebuild
            docker rmi $APP_NAME:latest 2>/dev/null || true
            
            # Build new image
            echo "Building Docker image..."
            docker build -t $APP_NAME:latest .
            
            # Run container
            echo "Starting container..."
            docker run -d \
                --name $APP_NAME \
                -p $APP_PORT:$APP_PORT \
                --restart unless-stopped \
                --health-cmd="curl -f http://localhost:$APP_PORT/health || exit 1" \
                --health-interval=30s \
                --health-timeout=10s \
                --health-retries=3 \
                $APP_NAME:latest
            
            # Wait for container to start
            echo "Waiting for container to start..."
            sleep 5
            
            # Check container health with retries
            echo "Checking container health..."
            MAX_RETRIES=12
            RETRY_COUNT=0
            
            while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
                CONTAINER_STATUS=\$(docker inspect --format='{{.State.Status}}' $APP_NAME 2>/dev/null || echo "not found")
                
                if [ "\$CONTAINER_STATUS" = "running" ]; then
                    echo "✓ Container is running"
                    
                    # Additional health check - try to connect to the port
                    if curl -f -s http://localhost:$APP_PORT > /dev/null 2>&1 || nc -z localhost $APP_PORT 2>/dev/null; then
                        echo "✓ Application is responding on port $APP_PORT"
                        docker ps | grep $APP_NAME
                        break
                    else
                        echo "Container running but app not responding yet..."
                    fi
                elif [ "\$CONTAINER_STATUS" = "exited" ] || [ "\$CONTAINER_STATUS" = "not found" ]; then
                    echo "✗ Container failed to start or exited"
                    docker logs $APP_NAME --tail=50 2>/dev/null || true
                    exit 1
                fi
                
                RETRY_COUNT=\$((RETRY_COUNT + 1))
                if [ \$RETRY_COUNT -eq \$MAX_RETRIES ]; then
                    echo "✗ Container health check failed after \$MAX_RETRIES attempts"
                    docker logs $APP_NAME --tail=50
                    exit 1
                fi
                
                echo "Waiting for container to be healthy... (attempt \$RETRY_COUNT/\$MAX_RETRIES)"
                sleep 5
            done
            
            # Show container details and logs
            echo "Container details:"
            docker inspect $APP_NAME --format='{{.State.Status}}: {{.State.Health.Status}}' 2>/dev/null || docker ps | grep $APP_NAME
            echo ""
            echo "Recent container logs:"
            docker logs $APP_NAME --tail=20
ENDSSH
        then
            log_error "Failed to deploy application using Docker"
            exit 1
        fi
    fi
    
    log "✓ Application deployed successfully"
    log "✓ Container health checks passed"
}

################################################################################
# Task 7: Configure Nginx Reverse Proxy
################################################################################

configure_nginx() {
    log "=== Task 7: Configuring Nginx Reverse Proxy ==="
    
    NGINX_CONFIG="/etc/nginx/sites-available/$APP_NAME"
    
    # Determine server_name based on domain or IP
    if [[ -n "$DOMAIN_NAME" ]]; then
        SERVER_NAME="$DOMAIN_NAME"
        log "Configuring Nginx for domain: $DOMAIN_NAME"
    else
        SERVER_NAME="_"
        log "Configuring Nginx for IP-based access"
    fi
    
    log "Creating Nginx configuration file..."
    log_debug "Config file: $NGINX_CONFIG"
    log_debug "Server name: $SERVER_NAME"
    log_debug "Proxy target: http://localhost:$APP_PORT"
    
    if ! ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        echo "Creating Nginx configuration..."
        
        # Backup existing config if it exists
        if [ -f $NGINX_CONFIG ]; then
            echo "Backing up existing configuration..."
            sudo cp $NGINX_CONFIG ${NGINX_CONFIG}.backup.\$(date +%Y%m%d_%H%M%S)
        fi
        
        # Create comprehensive Nginx configuration
        sudo tee $NGINX_CONFIG > /dev/null << 'NGINX_EOF'
# Nginx configuration for $APP_NAME
# Generated by automated deployment script

upstream $APP_NAME {
    server localhost:$APP_PORT;
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    
    # Logging
    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;
    
    # Client body size limit
    client_max_body_size 50M;
    
    # Proxy settings
    location / {
        proxy_pass http://$APP_NAME;
        proxy_http_version 1.1;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        
        # Standard proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # Proxy timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Disable caching for dynamic content
        proxy_cache_bypass \$http_upgrade;
        proxy_no_cache \$http_upgrade;
        
        # Buffer settings
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        proxy_busy_buffers_size 8k;
    }
    
    # Health check endpoint (optional)
    location /health {
        proxy_pass http://$APP_NAME/health;
        access_log off;
    }
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
NGINX_EOF
        
        echo "Configuration created at $NGINX_CONFIG"
        
        # Create symbolic link to enable site
        echo "Enabling site..."
        sudo ln -sf $NGINX_CONFIG /etc/nginx/sites-enabled/$APP_NAME
        
        # Remove default site if it exists
        if [ -f /etc/nginx/sites-enabled/default ]; then
            echo "Removing default Nginx site..."
            sudo rm -f /etc/nginx/sites-enabled/default
        fi
        
        # List enabled sites
        echo "Enabled sites:"
        ls -la /etc/nginx/sites-enabled/
        
        # Test Nginx configuration
        echo "Testing Nginx configuration..."
        sudo nginx -t
        
        # Reload Nginx to apply changes
        echo "Reloading Nginx..."
        sudo systemctl reload nginx
        
        # Verify Nginx is running
        if systemctl is-active --quiet nginx; then
            echo "✓ Nginx is running and configuration applied"
        else
            echo "✗ Nginx is not running"
            exit 1
        fi
        
        echo "Nginx configured successfully"
ENDSSH
    then
        log_error "Failed to configure Nginx"
        exit 1
    fi
    
    log "✓ Nginx configured successfully"
    log "✓ Configuration file created at: $NGINX_CONFIG"
    log "✓ Site enabled and Nginx reloaded"
}

################################################################################
# Task 7b: Configure SSL with Let's Encrypt
################################################################################

configure_ssl() {
    if [[ "$ENABLE_SSL" != "yes" ]] || [[ -z "$DOMAIN_NAME" ]]; then
        log "Skipping SSL configuration (not enabled or no domain provided)"
        return 0
    fi
    
    log "=== Task 7b: Configuring SSL with Let's Encrypt ==="
    
    log_warn "IMPORTANT: Make sure $DOMAIN_NAME points to $SERVER_IP before continuing"
    read -p "Press Enter to continue with SSL setup, or Ctrl+C to cancel..."
    
    if ! ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        echo "Obtaining SSL certificate from Let's Encrypt..."
        
        # Run certbot in non-interactive mode
        sudo certbot --nginx \
            -d $DOMAIN_NAME \
            --non-interactive \
            --agree-tos \
            --email $SSL_EMAIL \
            --redirect
        
        echo "SSL certificate obtained and configured successfully"
        
        # Test Nginx configuration
        sudo nginx -t
        
        # Setup auto-renewal (certbot usually does this automatically)
        sudo systemctl enable certbot.timer || true
        
        echo "SSL configuration complete"
ENDSSH
    then
        log_error "Failed to configure SSL"
        log_warn "You can manually run: sudo certbot --nginx -d $DOMAIN_NAME"
        exit 1
    fi
    
    log "✓ SSL configured successfully"
    log "✓ Auto-renewal enabled"
}

################################################################################
# Task 8: Validate Deployment
################################################################################

validate_deployment() {
    log "=== Task 8: Validating Deployment ==="
    
    log "Running comprehensive deployment validation..."
    
    if ! ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        echo "=== Validation Step 1: Docker Service ==="
        # Check if Docker service is installed
        if ! command -v docker &> /dev/null; then
            echo "✗ Docker is not installed"
            exit 1
        fi
        echo "✓ Docker is installed"
        
        # Check if Docker service is enabled
        if systemctl is-enabled --quiet docker; then
            echo "✓ Docker service is enabled"
        else
            echo "⚠ Docker service is not enabled"
        fi
        
        # Check if Docker service is active/running
        if systemctl is-active --quiet docker; then
            echo "✓ Docker service is running"
        else
            echo "✗ Docker service is not running"
            systemctl status docker --no-pager || true
            exit 1
        fi
        
        # Check Docker daemon health
        if docker info > /dev/null 2>&1; then
            echo "✓ Docker daemon is healthy"
        else
            echo "✗ Docker daemon is not responding"
            exit 1
        fi
        
        echo ""
        echo "=== Validation Step 2: Container Status ==="
        # Check if container exists
        if docker ps -a --format '{{.Names}}' | grep -q "^$APP_NAME\$"; then
            echo "✓ Container $APP_NAME exists"
        else
            echo "✗ Container $APP_NAME not found"
            echo "Available containers:"
            docker ps -a --format 'table {{.Names}}\t{{.Status}}'
            exit 1
        fi
        
        # Check if container is running
        if docker ps --format '{{.Names}}' | grep -q "^$APP_NAME\$"; then
            echo "✓ Container $APP_NAME is running"
            
            # Get container details
            CONTAINER_STATUS=\$(docker inspect --format='{{.State.Status}}' $APP_NAME)
            CONTAINER_UPTIME=\$(docker inspect --format='{{.State.StartedAt}}' $APP_NAME)
            echo "  Status: \$CONTAINER_STATUS"
            echo "  Started: \$CONTAINER_UPTIME"
            
            # Check container health if health check is defined
            HEALTH_STATUS=\$(docker inspect --format='{{.State.Health.Status}}' $APP_NAME 2>/dev/null || echo "none")
            if [ "\$HEALTH_STATUS" != "none" ]; then
                echo "  Health: \$HEALTH_STATUS"
            fi
        else
            echo "✗ Container $APP_NAME is not running"
            echo "Container status:"
            docker ps -a --filter "name=$APP_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
            echo "Recent logs:"
            docker logs $APP_NAME --tail=30
            exit 1
        fi
        
        # Check container ports
        CONTAINER_PORTS=\$(docker port $APP_NAME 2>/dev/null || echo "none")
        if [ "\$CONTAINER_PORTS" != "none" ]; then
            echo "✓ Container ports are mapped:"
            echo "\$CONTAINER_PORTS"
        fi
        
        echo ""
        echo "=== Validation Step 3: Nginx Service ==="
        # Check if Nginx is installed
        if ! command -v nginx &> /dev/null; then
            echo "✗ Nginx is not installed"
            exit 1
        fi
        echo "✓ Nginx is installed"
        
        # Check if Nginx service is enabled
        if systemctl is-enabled --quiet nginx; then
            echo "✓ Nginx service is enabled"
        else
            echo "⚠ Nginx service is not enabled"
        fi
        
        # Check if Nginx is running
        if systemctl is-active --quiet nginx; then
            echo "✓ Nginx service is running"
        else
            echo "✗ Nginx service is not running"
            systemctl status nginx --no-pager || true
            exit 1
        fi
        
        # Test Nginx configuration
        if sudo nginx -t > /dev/null 2>&1; then
            echo "✓ Nginx configuration is valid"
        else
            echo "✗ Nginx configuration has errors"
            sudo nginx -t
            exit 1
        fi
        
        echo ""
        echo "=== Validation Step 4: Application Connectivity ==="
        # Test application on internal port
        echo "Testing application on port $APP_PORT..."
        MAX_RETRIES=5
        RETRY_COUNT=0
        
        while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
            if curl -f -s -m 5 http://localhost:$APP_PORT > /dev/null 2>&1; then
                echo "✓ Application is responding on port $APP_PORT"
                break
            elif nc -z localhost $APP_PORT 2>/dev/null; then
                echo "✓ Port $APP_PORT is open (app may not have HTTP endpoint)"
                break
            fi
            
            RETRY_COUNT=\$((RETRY_COUNT + 1))
            if [ \$RETRY_COUNT -eq \$MAX_RETRIES ]; then
                echo "✗ Application is not responding on port $APP_PORT"
                echo "Checking if port is listening:"
                netstat -tln | grep $APP_PORT || ss -tln | grep $APP_PORT || true
                exit 1
            fi
            
            echo "Retrying... (\$RETRY_COUNT/\$MAX_RETRIES)"
            sleep 2
        done
        
        # Test Nginx proxy
        echo "Testing Nginx proxy on port 80..."
        if curl -f -s -m 5 http://localhost > /dev/null 2>&1; then
            echo "✓ Nginx proxy is working correctly"
        else
            echo "✗ Nginx proxy is not working"
            echo "Nginx error log:"
            sudo tail -20 /var/log/nginx/error.log || true
            exit 1
        fi
        
        echo ""
        echo "=== Validation Summary ==="
        echo "✓ Docker service: Running"
        echo "✓ Container status: Running"
        echo "✓ Nginx service: Running"
        echo "✓ Application: Responding"
        echo "✓ Proxy: Functional"
        echo ""
        echo "Deployment validation completed successfully!"
ENDSSH
    then
        log_error "Deployment validation failed"
        exit 1
    fi
    
    log "✓ All validation checks passed"
    log ""
    log "=========================================="
    log "🎉 Deployment completed successfully!"
    log "=========================================="
    log "Application: $APP_NAME"
    log "Access URL: http://$SERVER_IP"
    if [[ -n "$DOMAIN_NAME" ]]; then
        log "Domain URL: http://$DOMAIN_NAME"
    fi
    log "Container Port: $APP_PORT"
    log "Deployment Time: $(date +'%Y-%m-%d %H:%M:%S')"
    log "=========================================="
    log ""
    log "Next steps:"
    if [[ "$ENABLE_SSL" != "yes" ]] && [[ -n "$DOMAIN_NAME" ]]; then
        log "  - Consider enabling SSL with: ./deploy.sh --ssl"
    fi
    log "  - Monitor logs: ssh -i $SSH_KEY $SSH_USER@$SERVER_IP 'docker logs -f $APP_NAME'"
    log "  - Check status: ssh -i $SSH_KEY $SSH_USER@$SERVER_IP 'docker ps'"
    log "=========================================="
}

################################################################################
# Task 7b: Configure SSL with Let's Encrypt
################################################################################

configure_ssl() {
    if [[ "$ENABLE_SSL" != "yes" ]] || [[ -z "$DOMAIN_NAME" ]]; then
        log "Skipping SSL configuration (not enabled or no domain provided)"
        return 0
    fi
    
    log "=== Task 7b: Configuring SSL with Let's Encrypt ==="
    
    log_warn "IMPORTANT: Make sure $DOMAIN_NAME points to $SERVER_IP before continuing"
    read -p "Press Enter to continue with SSL setup, or Ctrl+C to cancel..."
    
    if ! ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        echo "Obtaining SSL certificate from Let's Encrypt..."
        
        # Run certbot in non-interactive mode
        sudo certbot --nginx \
            -d $DOMAIN_NAME \
            --non-interactive \
            --agree-tos \
            --email $SSL_EMAIL \
            --redirect
        
        echo "SSL certificate obtained and configured successfully"
        
        # Test Nginx configuration
        sudo nginx -t
        
        # Setup auto-renewal (certbot usually does this automatically)
        sudo systemctl enable certbot.timer || true
        
        echo "SSL configuration complete"
ENDSSH
    then
        log_error "Failed to configure SSL"
        log_warn "You can manually run: sudo certbot --nginx -d $DOMAIN_NAME"
        exit 1
    fi
    
    log "✓ SSL configured successfully"
    log "✓ Auto-renewal enabled"
}

################################################################################
# Cleanup Function (Optional)
################################################################################

cleanup_deployment() {
    log "=== Cleaning up deployment ==="
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        # Stop and remove containers
        docker stop $APP_NAME || true
        docker rm $APP_NAME || true
        
        # Remove images
        docker rmi $APP_NAME:latest || true
        
        # Remove Nginx config
        sudo rm -f /etc/nginx/sites-enabled/$APP_NAME
        sudo rm -f /etc/nginx/sites-available/$APP_NAME
        sudo systemctl reload nginx
        
        # Remove project directory
        rm -rf /home/$SSH_USER/$APP_NAME
        
        echo "Cleanup completed"
ENDSSH
    
    log "✓ Cleanup completed"
}

################################################################################
# Main Execution
################################################################################

main() {
    log "Starting deployment script..."
    log "Log file: $LOG_FILE"
    
    # Check for cleanup flag
    if [[ "$1" == "--cleanup" ]]; then
        collect_parameters
        cleanup_deployment
        exit 0
    fi
    
    # Execute deployment tasks
    collect_parameters
    clone_repository
    verify_project
    check_ssh_connection
    prepare_remote_environment
    deploy_application
    configure_nginx
    configure_ssl  # New SSL configuration step
    validate_deployment
    
    log "All tasks completed successfully!"
}

# Run main function
main "$@"