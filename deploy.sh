#!/bin/bash

################################################################################
# Automated Docker Deployment Script
# This script deploys a Dockerized application to a remote server with Nginx
################################################################################

set -e  # Exit on any error

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
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
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
    
    # App name (derived from repo)
    APP_NAME=$(basename "$GIT_REPO" .git)
    
    log "Parameters collected successfully"
    log "Repository: $GIT_REPO"
    log "Branch: $GIT_BRANCH"
    log "Server: $SSH_USER@$SERVER_IP"
    log "App Port: $APP_PORT"
    log "App Name: $APP_NAME"
}

################################################################################
# Task 2: Clone the Repository
################################################################################

clone_repository() {
    log "=== Task 2: Cloning Repository ==="
    
    # Create authenticated URL
    AUTH_REPO=$(echo "$GIT_REPO" | sed "s|https://|https://$GIT_TOKEN@|")
    
    if [[ -d "$APP_NAME" ]]; then
        log_warn "Directory $APP_NAME already exists, pulling latest changes"
        cd "$APP_NAME"
        git pull origin "$GIT_BRANCH" 2>&1 | tee -a "$LOG_FILE"
    else
        log "Cloning repository..."
        git clone -b "$GIT_BRANCH" "$AUTH_REPO" "$APP_NAME" 2>&1 | tee -a "$LOG_FILE"
        cd "$APP_NAME"
    fi
    
    log "Repository cloned/updated successfully"
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
    
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" "echo 'SSH connection successful'" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ SSH connection established"
    else
        log_error "Cannot connect to $SSH_USER@$SERVER_IP"
        exit 1
    fi
}

################################################################################
# Task 5: Prepare Remote Environment
################################################################################

prepare_remote_environment() {
    log "=== Task 5: Preparing Remote Environment ==="
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << 'ENDSSH' 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        echo "Updating system packages..."
        sudo apt-get update -qq
        
        # Install Docker if not present
        if ! command -v docker &> /dev/null; then
            echo "Installing Docker..."
            sudo apt-get install -y docker.io
            sudo systemctl enable docker
            sudo systemctl start docker
        fi
        
        # Install Docker Compose if not present
        if ! command -v docker-compose &> /dev/null; then
            echo "Installing Docker Compose..."
            sudo apt-get install -y docker-compose
        fi
        
        # Install Nginx if not present
        if ! command -v nginx &> /dev/null; then
            echo "Installing Nginx..."
            sudo apt-get install -y nginx
            sudo systemctl enable nginx
            sudo systemctl start nginx
        fi
        
        # Add user to docker group
        sudo usermod -aG docker $USER || true
        
        echo "Verifying installations..."
        docker --version
        docker-compose --version
        nginx -v
        
        echo "Remote environment ready"
ENDSSH
    
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
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_DIR" 2>&1 | tee -a "$LOG_FILE"
    rsync -avz -e "ssh -i $SSH_KEY" --exclude='.git' "$PROJECT_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_DIR/" 2>&1 | tee -a "$LOG_FILE"
    
    log "Files transferred successfully"
    
    # Build and run on remote server
    log "Building and running Docker container..."
    
    if [[ "$DEPLOY_TYPE" == "compose" ]]; then
        ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
            set -e
            cd $REMOTE_DIR
            
            # Stop existing containers
            docker-compose down || true
            
            # Build and start
            docker-compose up -d --build
            
            # Wait for container to be healthy
            sleep 5
            docker-compose ps
ENDSSH
    else
        ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
            set -e
            cd $REMOTE_DIR
            
            # Stop and remove existing container
            docker stop $APP_NAME || true
            docker rm $APP_NAME || true
            
            # Build new image
            docker build -t $APP_NAME:latest .
            
            # Run container
            docker run -d --name $APP_NAME -p $APP_PORT:$APP_PORT --restart unless-stopped $APP_NAME:latest
            
            # Wait for container to start
            sleep 5
            docker ps | grep $APP_NAME
ENDSSH
    fi
    
    log "✓ Application deployed successfully"
}

################################################################################
# Task 7: Configure Nginx Reverse Proxy
################################################################################

configure_nginx() {
    log "=== Task 7: Configuring Nginx Reverse Proxy ==="
    
    NGINX_CONFIG="/etc/nginx/sites-available/$APP_NAME"
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        # Create Nginx configuration
        sudo tee $NGINX_CONFIG > /dev/null << 'NGINX_EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF
        
        # Enable site
        sudo ln -sf $NGINX_CONFIG /etc/nginx/sites-enabled/$APP_NAME
        
        # Remove default if exists
        sudo rm -f /etc/nginx/sites-enabled/default
        
        # Test configuration
        sudo nginx -t
        
        # Reload Nginx
        sudo systemctl reload nginx
        
        echo "Nginx configured successfully"
ENDSSH
    
    log "✓ Nginx configured successfully"
}

################################################################################
# Task 8: Validate Deployment
################################################################################

validate_deployment() {
    log "=== Task 8: Validating Deployment ==="
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        # Check Docker service
        if systemctl is-active --quiet docker; then
            echo "✓ Docker service is running"
        else
            echo "✗ Docker service is not running"
            exit 1
        fi
        
        # Check container
        if docker ps | grep -q $APP_NAME; then
            echo "✓ Container $APP_NAME is running"
        else
            echo "✗ Container $APP_NAME is not running"
            exit 1
        fi
        
        # Check Nginx
        if systemctl is-active --quiet nginx; then
            echo "✓ Nginx is running"
        else
            echo "✗ Nginx is not running"
            exit 1
        fi
        
        # Test endpoint
        sleep 2
        if curl -f -s http://localhost:$APP_PORT > /dev/null; then
            echo "✓ Application is responding on port $APP_PORT"
        else
            echo "⚠ Application may not be fully ready yet"
        fi
        
        if curl -f -s http://localhost > /dev/null; then
            echo "✓ Nginx proxy is working"
        else
            echo "⚠ Nginx proxy may not be fully configured"
        fi
ENDSSH
    
    log "✓ Deployment validated"
    log ""
    log "=========================================="
    log "Deployment completed successfully!"
    log "Access your application at: http://$SERVER_IP"
    log "=========================================="
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
    validate_deployment
    
    log "All tasks completed successfully!"
}

# Run main function
main "$@"