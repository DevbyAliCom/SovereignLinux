#!/bin/bash

# Ensure script runs from its directory for docker compose context
# This allows 'docker compose' commands to find your docker-compose.yml
cd "$(dirname "$0")" || exit 1

# --- Configuration Variables ---
# GitLab Docker Compose service name (usually 'web' from your docker-compose.yml)
GITLAB_SERVICE_NAME="web"
# Exact name of your GitLab container (e.g., 'gitlab-docker-web-1').
# Find this by running 'docker compose ps'.
GITLAB_CONTAINER_NAME="gitlab-docker-web-1"

# The path on your HOST machine where GitLab's internal backups are created.
# This corresponds to /var/opt/gitlab/backups inside the container.
# IMPORTANT: Replace $USER with your actual Linux username (e.g., /home/yourusername/gitlab-docker/data/backups)
GITLAB_BACKUP_HOST_DIR="/home/$USER/gitlab-docker/data/backups"

# Temporary directory on your HOST machine for staging the GitLab backup tarball.
# This directory MUST be writable by the user running this script.
LOCAL_TEMP_DIR="/tmp/gitlab_backup_temp"

# Local directory on your HOST machine where BorgBackup will store its encrypted repository.
# This directory MUST be writable by the user running this script.
# IMPORTANT: Replace $USER with your actual Linux username (e.g., /home/yourusername/gitlab-docker/borg_repo)
LOCAL_BORG_REPO="/home/$USER/gitlab-docker/borg_repo"

# The name of your Rclone remote (configured via 'rclone config').
# EXAMPLE: If you named it 'aws-gitlab-s3', use that here.
RCLONE_REMOTE_NAME="hp-probook-aws-s3" # <<< CUSTOMIZE THIS LINE

# Your S3 bucket name and the path within it where backups will be stored.
# EXAMPLE: "your-actual-bucket-name/gitlab-backups"
# IMPORTANT: Replace 'your-actual-bucket-name' with your actual S3 bucket name.
S3_BUCKET_PATH="hp-probook-backups" # <<< CUSTOMIZE THIS LINE

# --- Security: Retrieve Borg Passphrase ---
# This script assumes your Borg passphrase is stored in a file at the specified path.
# This file MUST be readable ONLY by the user running this script (chmod 400).
# IMPORTANT: Replace $USER with your actual Linux username (e.g., /home/yourusername/.borg_passphrase_file)
export BORG_PASSPHRASE=$(cat "/home/$USER/.borg_passphrase_file")
if [ -z "$BORG_PASSPHRASE" ]; then
    echo "$(date): ERROR: BORG_PASSPHRASE is empty. Check /home/$USER/.borg_passphrase_file content and permissions. Exiting." | tee -a ~/gitlab_backup_log.txt
    exit 1
fi
# For even more robust security, especially in shared environments, consider using a secrets management solution
# like AWS Secrets Manager, HashiCorp Vault, or a similar tool to retrieve the passphrase.

# --- Script Logic ---

# Ensure necessary temporary and local Borg repository directories exist
mkdir -p "$LOCAL_TEMP_DIR"
mkdir -p "$LOCAL_BORG_REPO"

# Log the start of the backup process
# IMPORTANT: Replace $USER with your actual Linux username for the log path
echo "$(date): Starting GitLab backup process..." | tee -a /home/$USER/gitlab_backup_log.txt

# --- Step 1: Trigger GitLab's built-in backup inside the container ---
# This command runs 'gitlab-rake' inside the specified container to create the backup tarball.
echo "$(date): Creating GitLab internal backup..." | tee -a /home/$USER/gitlab_backup_log.txt
# Capture all output and exit code from the gitlab-rake command
GITLAB_BACKUP_OUTPUT=$(docker exec "$GITLAB_CONTAINER_NAME" gitlab-rake gitlab:backup:create 2>&1)
GITLAB_RAKE_EXIT_CODE=$?

# Log the full output of the gitlab-rake command
echo "$GITLAB_BACKUP_OUTPUT" | tee -a /home/$USER/gitlab_backup_log.txt

if [ "$GITLAB_RAKE_EXIT_CODE" -ne 0 ]; then
    echo "$(date): ERROR: GitLab internal backup failed. See previous log output for details. Exiting." | tee -a /home/$USER/gitlab_backup_log.txt
    exit 1
fi

# Extract the filename of the newly created backup tarball from the captured output
GITLAB_INTERNAL_BACKUP_FILENAME=$(echo "$GITLAB_BACKUP_OUTPUT" | grep -oP 'Creating backup archive: \K[^ ]+\.tar' | tail -n 1)

if [ -z "$GITLAB_INTERNAL_BACKUP_FILENAME" ]; then
    echo "$(date): ERROR: Could not determine latest GitLab backup filename. Check 'gitlab-rake' output format. Exiting." | tee -a /home/$USER/gitlab_backup_log.txt
    exit 1
fi

# --- Step 2: Copy the backup tarball from the container to the local host ---
# Using 'docker cp' is robust as it bypasses host-side permission issues for accessing root-owned files
# within Docker volumes.
echo "$(date): Copying GitLab backup: $GITLAB_INTERNAL_BACKUP_FILENAME from container to $LOCAL_TEMP_DIR/" | tee -a /home/$USER/gitlab_backup_log.txt
docker cp "$GITLAB_CONTAINER_NAME:/var/opt/gitlab/backups/$GITLAB_INTERNAL_BACKUP_FILENAME" "$LOCAL_TEMP_DIR/$GITLAB_INTERNAL_BACKUP_FILENAME"
if [ $? -ne 0 ]; then
    echo "$(date): ERROR: Failed to copy GitLab backup from container using 'docker cp'. Check container name/path." | tee -a /home/$USER/gitlab_backup_log.txt
    exit 1
fi
# Update the variable to point to the copied file for subsequent steps
LATEST_GITLAB_BACKUP="$LOCAL_TEMP_DIR/$GITLAB_INTERNAL_BACKUP_FILENAME"

# --- Step 3: Initialize BorgBackup repository (if not already initialized) ---
# This creates the Borg repository structure locally if it doesn't exist.
if ! borg info "$LOCAL_BORG_REPO" &>/dev/null; then
    echo "$(date): Initializing BorgBackup repository at $LOCAL_BORG_REPO" | tee -a /home/$USER/gitlab_backup_log.txt
    borg init --encryption=repokey-blake2b "$LOCAL_BORG_REPO" # Using recommended 'repokey-blake2b'
    if [ $? -ne 0 ]; then
        echo "$(date): ERROR: Failed to initialize BorgBackup repository. Exiting." | tee -a /home/$USER/gitlab_backup_log.txt
        exit 1
    fi
else
    echo "$(date): BorgBackup repository already initialized." | tee -a /home/$USER/gitlab_backup_log.txt
fi

# --- Step 4: Create an encrypted and deduplicated Borg archive ---
# This adds the GitLab backup tarball to the Borg repository as a new archive.
ARCHIVE_NAME="gitlab-$(date +%Y%m%d-%H%M%S)"
echo "$(date): Creating Borg archive: $ARCHIVE_NAME from $LATEST_GITLAB_BACKUP" | tee -a /home/$USER/gitlab_backup_log.txt
borg create --stats --compression lz4 "$LOCAL_BORG_REPO::$ARCHIVE_NAME" "$LATEST_GITLAB_BACKUP"
if [ $? -ne 0 ]; then
    echo "$(date): ERROR: Failed to create Borg archive. Exiting." | tee -a /home/$USER/gitlab_backup_log.txt
    exit 1
fi

# --- Step 5: Prune old Borg archives ---
# This manages the retention policy, keeping only a defined number of backups.
echo "$(date): Pruning old Borg archives..." | tee -a /home/$USER/gitlab_backup_log.txt
borg prune --stats --keep-daily=7 --keep-weekly=4 --keep-monthly=6 "$LOCAL_BORG_REPO"
if [ $? -ne 0 ]; then
    echo "$(date): WARN: Borg prune might have failed, but continuing. Check logs." | tee -a /home/$USER/gitlab_backup_log.txt
fi

# --- Step 6: Sync local Borg repository to S3 using Rclone ---
# This uploads the changes in your local Borg repository to your S3 bucket.
echo "$(date): Uploading encrypted Borg repository to S3: $RCLONE_REMOTE_NAME:$S3_BUCKET_PATH" | tee -a /home/$USER/gitlab_backup_log.txt
rclone sync "$LOCAL_BORG_REPO" "$RCLONE_REMOTE_NAME:$S3_BUCKET_PATH" --progress --checksum --transfers 4
if [ $? -ne 0 ]; then
    echo "$(date): ERROR: Failed to sync to S3. Exiting." | tee -a /home/$USER/gitlab_backup_log.txt
    exit 1
fi

# --- Step 7: Clean up temporary files ---
# Removes the local GitLab backup tarball copied in Step 2.
echo "$(date): Cleaning up temporary files..." | tee -a /home/$USER/gitlab_backup_log.txt
rm -f "$LOCAL_TEMP_DIR"/*.tar

# GitLab's internal rake task already handles cleanup of the original backup in /var/opt/gitlab/backups
echo "$(date): GitLab backup complete and uploaded to S3." | tee -a /home/$USER/gitlab_backup_log.txt
