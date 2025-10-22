# ZFS Raw Snapshot Backup with Rclone

A Bash script with advanced filters to backup ZFS raw snapshots to S3 using rclone (compatible with other rclone backends).

## Features

- **Flexible Backup Modes**: Full pool backup or individual dataset backups
- **Advanced Filtering**: Include/exclude specific datasets
- **Automatic Retention**: Configurable backup retention policies
- **Error Handling**: Comprehensive error handling with optional Telegram notifications
- **Security**: Configuration separated in `.env` file with secure permissions
- **Compression**: Built-in zstd compression for efficient storage

## Quick Setup

1. **Clone and copy template**:
   ```bash
   git clone https://github.com/lfventura/zfs-raw-snapshot-backup-rclone-bash.git
   cd zfs-raw-snapshot-backup-rclone-bash
   cp .env.example .env
   chmod 600 .env
   ```

2. **Edit configuration**:
   ```bash
   nano .env
   ```

### Common Next Steps
3. **Configure rclone remote** (if not already done):
   ```bash
   rclone config
   ```

4. **Test the setup**:
   ```bash
   # Test rclone connection
   rclone lsf your_remote:your_bucket
   
   # Run backup
   sudo ./backup_zfs.sh
   ```

## Configuration

All settings are configured in the `.env` file. Key parameters:

### Required Settings
- `ZPOOL_ORIGEM`: Source ZFS pool/dataset name
- `S3_REMOTE`: Rclone remote name
- `S3_BUCKET_PATH`: S3 bucket and path
- `BACKUP_MODE`: `FULL` or `SPLIT`
- `FILTER_TYPE`: `NONE`, `INCLUDE`, or `EXCLUDE`

### Optional Settings
- `TELEGRAM_BOT_TOKEN`: Bot token for notifications
- `TELEGRAM_CHAT_ID`: Chat ID for notifications
- `RETENTION_BACKUP_FILE_MAX`: Number of backups to keep
- `FILTER_LIST`: Comma-separated list of datasets

## Backup Modes

### FULL Mode
- Backs up entire pool as single file
- No filtering supported
- File format: `zfs_backup_full_<pool>_<timestamp>.zst`

### SPLIT Mode
- Backs up each dataset individually
- Supports all filtering options
- File format: `zfs_backup_split_<dataset>_<timestamp>.zst`

## Filtering Examples

### Include specific datasets only:
```bash
BACKUP_MODE="SPLIT"
FILTER_TYPE="INCLUDE"
FILTER_LIST="home,documents,photos"
```

### Exclude temporary datasets:
```bash
BACKUP_MODE="SPLIT"
FILTER_TYPE="EXCLUDE" 
FILTER_LIST="tmp,cache,logs"
```

### No filtering (backup all):
```bash
BACKUP_MODE="SPLIT"
FILTER_TYPE="NONE"
FILTER_LIST=""
```

## Security Best Practices

- **File Permissions**: `.env` should have `600` permissions
- **Secrets Management**: Never commit `.env` to version control
- **Access Control**: Run with appropriate sudo permissions
- **Telegram Tokens**: Keep bot tokens secure and private
