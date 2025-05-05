#!/bin/bash

# Function to initialize logging
init_logging() {
    # Create logs directory with absolute path
    LOGS_DIR="$(pwd)/logs"
    mkdir -p "$LOGS_DIR"
    LOG_FILE="$LOGS_DIR/installation_$(date +%Y%m%d_%H%M%S).log"
    echo "Installation started at $(date)" > "$LOG_FILE"

    # Create symlink to latest log using absolute paths
    ln -sf "$LOG_FILE" "$LOGS_DIR/latest.log"
    echo -e "${BLUE}Log file created: $LOG_FILE${NC}"
    echo -e "${BLUE}Latest log symlink: $LOGS_DIR/latest.log${NC}"

    # Export variables for other modules
    export LOGS_DIR LOG_FILE
}

# Function to log commands and their output
log_command() {
    local cmd="$1"
    local description="$2"

    echo -e "\n\n==== $description ====" >> "$LOG_FILE"
    echo "Command: $cmd" >> "$LOG_FILE"
    echo "Executing at: $(date)" >> "$LOG_FILE"
    echo "Output:" >> "$LOG_FILE"

    # Execute command and capture both stdout and stderr
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        echo "Status: SUCCESS" >> "$LOG_FILE"
        return 0
    else
        local exit_code=$?
        echo "Status: FAILED (exit code: $exit_code)" >> "$LOG_FILE"
        return $exit_code
    fi
}

# Function to log a message
log_message() {
    local message="$1"
    local level="${2:-INFO}"  # Default to INFO if not specified

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
    
    # Also print to console with appropriate color
    case "$level" in
        "ERROR")
            echo -e "${RED}[ERROR] $message${NC}"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING] $message${NC}"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS] $message${NC}"
            ;;
        *)
            echo -e "${BLUE}[INFO] $message${NC}"
            ;;
    esac
}

# Function to get the latest log file
get_latest_log() {
    echo "$LOGS_DIR/latest.log"
}

# Function to show log file location
show_log_location() {
    echo -e "${BLUE}Current log file: $LOG_FILE${NC}"
    echo -e "${BLUE}Latest log symlink: $LOGS_DIR/latest.log${NC}"
} 