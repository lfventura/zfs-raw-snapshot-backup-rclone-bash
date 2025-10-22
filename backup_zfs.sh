#!/bin/bash
# ===================================================================
# ADVANCED ZFS BACKUP SCRIPT
# ===================================================================
#
# MAIN CONFIGURATIONS:
# -------------------------
# TELEGRAM_BOT_TOKEN    : Telegram bot token for notifications
# TELEGRAM_CHAT_ID      : Chat/user ID to receive alerts
# ZPOOL_ORIGEM          : Source ZFS pool/dataset name
# S3_REMOTE             : Configured rclone remote name
# S3_BUCKET_PATH        : S3 bucket/folder path.
#                         If used with an rclone type "crypt", this probably 
#                         already has the remote directive configured and this variable can be
#                         defined only as a subfolder.
#                         If used with an rclone type "s3", this variable must be the complete bucket. (<bucket-name>/<folder>)
#                    
# RETENTION_BACKUP_FILE_MAX         : Number of backups to keep (retention)
#
# BACKUP MODES:
# ----------------
# BACKUP_MODE="FULL"  : Backup entire pool as a single file
#                       ⚠️ IMPORTANT: FULL mode does NOT support filters!
#                       Always use FILTER_TYPE="NONE" and FILTER_LIST=""
# BACKUP_MODE="SPLIT" : Backup each dataset individually in separate files
#                       ✅ Supports all filter types
#
# FILTER TYPES:
# ----------------
# FILTER_TYPE="NONE"    : No filters (default - processes everything)
#                         ✅ Compatible with: FULL and SPLIT
#                         📝 FILTER_LIST must be empty
# FILTER_TYPE="INCLUDE" : Includes only datasets specified in FILTER_LIST
#                         ✅ Compatible only with: SPLIT
#                         📝 FILTER_LIST is required
# FILTER_TYPE="EXCLUDE" : Excludes datasets specified in FILTER_LIST
#                         ✅ Compatible only with: SPLIT
#                         📝 FILTER_LIST is required
#
# FILTER LIST:
# -----------------
# FILTER_LIST : List of datasets separated by comma for filtering
#               Ex: "dataset1,dataset2,home" or "tmp,cache,logs"
#               ⚠️ If filled, FILTER_TYPE must be INCLUDE or EXCLUDE
#               ⚠️ If FILTER_TYPE is INCLUDE/EXCLUDE, FILTER_LIST is required
#
# DELETION POLICY:
# -------------------
# DELETION_MODE="PRE_DELETE"  : Remove old backups BEFORE sending the new one
# DELETION_MODE="POST_DELETE" : Remove old backups AFTER sending the new one
#                              ✅ Valid values: PRE_DELETE, POST_DELETE
#
# AUTOMATIC VALIDATIONS:
# -----------------------
# The script automatically validates all configurations before execution:
# ✓ BACKUP_MODE must be 'FULL' or 'SPLIT'
# ✓ FILTER_TYPE must be 'NONE', 'INCLUDE' or 'EXCLUDE'  
# ✓ DELETION_MODE must be 'PRE_DELETE' or 'POST_DELETE'
# ✓ RETENTION_BACKUP_FILE_MAX must be an integer >= 0
# ✓ BACKUP_MODE='FULL' cannot use filters (FILTER_TYPE must be 'NONE')
# ✓ FILTER_TYPE='INCLUDE'/'EXCLUDE' requires non-empty FILTER_LIST
# ✓ Non-empty FILTER_LIST requires FILTER_TYPE='INCLUDE'/'EXCLUDE'
#
# CONFIGURATION EXAMPLES:
# -------------------------
# 1. Traditional complete backup (single file):
#    BACKUP_MODE="FULL" 
#    FILTER_TYPE="NONE"      ← Required for FULL mode
#    FILTER_LIST=""          ← Must be empty for FULL mode
#
# 2. Split backup of all datasets:
#    BACKUP_MODE="SPLIT"
#    FILTER_TYPE="NONE"
#    FILTER_LIST=""          ← Empty = processes all datasets
#
# 3. Split backup of specific datasets only:
#    BACKUP_MODE="SPLIT"
#    FILTER_TYPE="INCLUDE"   ← Required when FILTER_LIST is not empty
#    FILTER_LIST="home,documents,photos,important"
#
# 4. Split backup excluding temporary datasets:
#    BACKUP_MODE="SPLIT"
#    FILTER_TYPE="EXCLUDE"   ← Required when FILTER_LIST is not empty
#    FILTER_LIST="tmp,cache,logs,temp,swap"
#
# ❌ INVALID CONFIGURATIONS (will be rejected):
# - BACKUP_MODE="FULL" + FILTER_TYPE="INCLUDE"  (FULL mode doesn't support filters)
# - BACKUP_MODE="FULL" + FILTER_LIST="something"     (FULL mode doesn't support filters)
# - FILTER_TYPE="INCLUDE" + FILTER_LIST=""      (filter without list)
# - FILTER_TYPE="NONE" + FILTER_LIST="something"     (list without filter)
#
# HOW IT WORKS:
# --------------
# - The script creates recursive snapshots of the pool/datasets
# - Compresses data with zstd during sending
# - Uploads to S3 using rclone
# - Manages automatic retention of old backups
# - Sends Telegram notifications on error
# - Performs automatic cleanup of local snapshots
#
# GENERATED FILES:
# -----------------
# FULL mode : zfs_backup_full_<pool>_<timestamp>.zst
# SPLIT mode: zfs_backup_split_<dataset>_<timestamp>.zst
#
# ===================================================================

# Disable immediate error checking at the beginning, so TRAP captures the error correctly
set -u

# ===================================================================
# CONFIGURATION SECTION
# ===================================================================

# --- LOAD CONFIGURATION FROM .env FILE ---
# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Check if .env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Configuration file not found: $ENV_FILE"
    echo ""
    echo "SETUP INSTRUCTIONS:"
    echo "1. Copy the template: cp .env.example .env"
    echo "2. Edit .env with your actual values"
    echo "3. Set secure permissions: chmod 600 .env"
    echo ""
    exit 1
fi

# Check file permissions for security
ENV_PERMISSIONS=$(stat -c "%a" "$ENV_FILE")
if [ "$ENV_PERMISSIONS" != "600" ] && [ "$ENV_PERMISSIONS" != "400" ]; then
    echo "WARNING: .env file has insecure permissions: $ENV_PERMISSIONS"
    echo "Recommended: chmod 600 .env"
    echo ""
fi

# Load configuration from .env file
echo "Loading configuration from: $ENV_FILE"
set -a  # Automatically export all variables
source "$ENV_FILE"
set +a  # Disable automatic export

# --- VALIDATE REQUIRED CONFIGURATIONS ---
# Check if essential variables are set
REQUIRED_VARS=("ZPOOL_ORIGEM" "S3_REMOTE" "S3_BUCKET_PATH" "RCLONE_BIN" "RETENTION_BACKUP_FILE_MAX" "DELETION_MODE" "BACKUP_MODE" "FILTER_TYPE")
MISSING_VARS=""

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS="$MISSING_VARS $var"
    fi
done

if [ -n "$MISSING_VARS" ]; then
    echo "ERROR: Required configuration variables are missing or empty:"
    for var in $MISSING_VARS; do
        echo "  - $var"
    done
    echo ""
    echo "Please check your .env file and ensure all required variables are set."
    exit 1
fi

# --- COMPUTED VARIABLES (DO NOT MODIFY) ---
SERVER_HOSTNAME=$(hostname)
ZPOOL_FILE_FORMAT="$(echo $ZPOOL_ORIGEM | sed -e s/\\//--/g)"

# --- AUTOMATIC VARIABLES (DO NOT MODIFY) ---
SNAPSHOT_NOME="$(date +%Y%m%d_%H%M%S)"
SNAPSHOT_ID="${ZPOOL_ORIGEM}@${SNAPSHOT_NOME}"

# File naming patterns (will be used based on BACKUP_MODE)
S3_OBJECT_PREFIX_FULL="zfs_backup_full_$ZPOOL_FILE_FORMAT"
S3_OBJECT_PREFIX_SPLIT="zfs_backup_split"

# FULL mode filename
ARQUIVO_ATUAL_FULL="${S3_OBJECT_PREFIX_FULL}_${SNAPSHOT_NOME}.zst"

# ===================================================================
# SCRIPT FUNCTIONS
# ===================================================================

# --- FUNCTION: SEND TELEGRAM MESSAGE ---
# Argument $1: Message text
send_telegram_alert() {
    # Check if Telegram is enabled and configured
    if [ "$TELEGRAM_ALERT" != "TRUE" ]; then
        echo "Telegram notifications disabled."
        return 0
    fi
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "WARNING: Telegram notifications enabled but BOT_TOKEN or CHAT_ID missing."
        return 1
    fi
    
    local MENSAGEM_TEXT=$1
    local URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

    # Add emojis and formatting
    local MENSAGEM_FORMATADA="❌ CRITICAL ERROR on ${SERVER_HOSTNAME} ❌\n\n[ZFS BACKUP FAILED]\n\nDetails:\n${MENSAGEM_TEXT}"

    # Use curl to send the request
    echo "Sending Telegram notification..."
    sudo curl -s -X POST "$URL" -d chat_id="$TELEGRAM_CHAT_ID" -d text="$MENSAGEM_FORMATADA"
}

# --- FUNCTION: ERROR TRAP (Executed AFTER script fails) ---
# This function is called if the script exits with an error status (any command fails)
handle_error() {
    local EXIT_CODE=$?
    local LINHA_ERRO=$1
    
    echo "DEBUG: handle_error called with EXIT_CODE=$EXIT_CODE, LINE=$LINHA_ERRO"
    
    # Check if the error is not error 1 (grep) or 0 (success)
    if [ "$EXIT_CODE" -ne 0 ]; then
        local MENSAGEM_ERRO="Script failed at line $LINHA_ERRO. EXIT STATUS: $EXIT_CODE."
        
        echo "ERROR DETECTED: $MENSAGEM_ERRO"

        # Try to destroy pending local snapshot to free the pool
        echo "RECOVERY ACTION: Trying to destroy pending local snapshot..."
        # The local snapshot may have been created, but sending failed.
        sudo zfs destroy -r "${SNAPSHOT_ID}" 2>/dev/null || echo "Warning: Local snapshot could not be destroyed. Manual cleanup may be needed."

        # Send notification
        send_telegram_alert "$MENSAGEM_ERRO"
        
        # Exit with the original error code
        exit $EXIT_CODE
    fi
}

# Configure TRAP to call handle_error with the line where the error occurred
# The 'trap' command must be configured at the beginning, but 'set -e' status will be reactivated below
trap 'handle_error $LINENO' ERR

# Reactivate strict mode after configuring trap
set -eo pipefail

# Uncomment the line below to test if the error trap is working
# false

# --- DATASET FILTERING FUNCTIONS ---
# Gets list of first-level datasets from pool
get_datasets_list() {
    local pool_name="$1"
    zfs list -H -o name -d1 "$pool_name" | grep '/' | sort
}

# Apply INCLUDE/EXCLUDE filters on dataset list
filter_datasets() {
    local datasets_raw="$1"
    
    case "$FILTER_TYPE" in
        "NONE")
            echo "$datasets_raw"
            ;;
        "INCLUDE")
            if [ -n "$FILTER_LIST" ]; then
                local included=""
                IFS=',' read -ra FILTERS <<< "$FILTER_LIST"
                for filter in "${FILTERS[@]}"; do
                    filter=$(echo "$filter" | xargs) # Remove spaces
                    local matches=$(echo "$datasets_raw" | grep -E "(^|/)${filter}(/|$)" || true)
                    if [ -n "$matches" ]; then
                        if [ -n "$included" ]; then
                            included="$included\n$matches"
                        else
                            included="$matches"
                        fi
                    fi
                done
                echo -e "$included" | sort -u
            else
                echo "$datasets_raw"
            fi
            ;;
        "EXCLUDE")
            if [ -n "$FILTER_LIST" ]; then
                local filtered="$datasets_raw"
                IFS=',' read -ra FILTERS <<< "$FILTER_LIST"
                for filter in "${FILTERS[@]}"; do
                    filter=$(echo "$filter" | xargs) # Remove spaces
                    filtered=$(echo "$filtered" | grep -vE "(^|/)${filter}(/|$)" || true)
                done
                echo "$filtered"
            else
                echo "$datasets_raw"
            fi
            ;;
        *)
            echo "ERROR: Invalid FILTER_TYPE: $FILTER_TYPE" >&2
            echo "$datasets_raw"
            ;;
    esac
}

# --- CENTRALIZED DELETION AND RETENTION FUNCTION (CORRECTED) ---
# Objective: Remove backups that exceed RETENTION_TARGET (the oldest ones).
# Argument $1: Number of backups to keep.
# Argument $2: Optional - specific dataset pattern for SPLIT mode
aplicar_politica_retencao() {
    local RETENTION_TARGET=$1
    local DATASET_PATTERN=$2
    echo "Applying retention policy: keep the $RETENTION_BACKUP_FILE_MAX most recent backups..."

    # 1. List all existing backups in S3 based on backup mode
    local BACKUP_PATTERN
    if [[ "$BACKUP_MODE" == "FULL" ]]; then
        BACKUP_PATTERN="zfs_backup_full_${ZPOOL_FILE_FORMAT}_"
        echo "Looking for FULL backups with pattern: $BACKUP_PATTERN"
    else
        if [ -n "$DATASET_PATTERN" ]; then
            # For SPLIT mode with specific dataset
            BACKUP_PATTERN="zfs_backup_split_${DATASET_PATTERN}_"
            echo "Looking for SPLIT backups of dataset '$DATASET_PATTERN' with pattern: $BACKUP_PATTERN"
        else
            # This shouldn't happen in normal operation
            echo "ERROR: SPLIT mode requires dataset pattern for retention"
            return 1
        fi
    fi
    
    ALL_BACKUPS=$(sudo "${RCLONE_BIN}" lsf "${S3_REMOTE}":"${S3_BUCKET_PATH}" | grep "${BACKUP_PATTERN}" | sort || true)

    # If there are no backups, exit.
    if [[ -z "$ALL_BACKUPS" ]]; then
        echo "No backups found with pattern '$BACKUP_PATTERN' to apply the policy."
        return
    fi

    # 2. Convert list to array
    readarray -t ARRAY_BACKUPS <<< "$ALL_BACKUPS"
    COUNT_EXISTING=${#ARRAY_BACKUPS[@]}

    echo "Found $COUNT_EXISTING existing backup(s) for pattern '$BACKUP_PATTERN':"
    printf '%s\n' "${ARRAY_BACKUPS[@]}"

    # 3. If RETENTION_TARGET is 0, delete EVERYTHING.
    if [[ "$RETENTION_TARGET" -eq 0 ]]; then
        FILES_TO_DELETE="${ALL_BACKUPS}"
    else
        # 4. Keep the RETENTION_TARGET number (the newest ones) and delete the rest (the oldest ones).
        NUM_TO_KEEP=$RETENTION_TARGET
        NUM_TO_DELETE=$(($COUNT_EXISTING - $NUM_TO_KEEP))

        if [[ "$NUM_TO_DELETE" -le 0 ]]; then
            echo "No backup exceeded the retention of $RETENTION_TARGET for pattern '$BACKUP_PATTERN'."
            return
        fi

        # Select the N OLDEST files (the ones that will be deleted).
        # We use sort to order (old at the top) and head to get the N oldest.
        FILES_TO_DELETE=$(echo "$ALL_BACKUPS" | head -n "$NUM_TO_DELETE")
    fi

    # 5. Execute deletion
    if [[ ! -z "$FILES_TO_DELETE" ]]; then
        echo "Files to be removed to comply with retention ($RETENTION_TARGET):"
        echo "$FILES_TO_DELETE"

        for file in $FILES_TO_DELETE; do
            echo "Deleting: $file"
            sudo "${RCLONE_BIN}" deletefile "${S3_REMOTE}":"${S3_BUCKET_PATH}"/"${file}"
        done
        echo "Deletion completed. Total of $(echo "$FILES_TO_DELETE" | wc -l) object(s) removed."
    fi
}

if [[ -z "$RETENTION_BACKUP_FILE_MAX" ]]; then
    echo "ERROR: It is necessary to provide the number of Full backups to maintain."
    exit 1
fi

# Check if RETENTION_BACKUP_FILE_MAX is a valid number
if ! [[ "$RETENTION_BACKUP_FILE_MAX" =~ ^[0-9]+$ ]]; then
    echo "ERROR: RETENTION_BACKUP_FILE_MAX='$RETENTION_BACKUP_FILE_MAX' must be a positive integer."
    echo "Example: RETENTION_BACKUP_FILE_MAX=7 (to keep 7 backups)"
    exit 1
fi

if [[ "$RETENTION_BACKUP_FILE_MAX" -lt 0 ]]; then
    echo "ERROR: RETENTION_BACKUP_FILE_MAX='$RETENTION_BACKUP_FILE_MAX' cannot be negative."
    echo "Use 0 to delete all backups or a positive number to keep backups."
    exit 1
fi

# --- CONFIGURATION VALIDATIONS ---
echo "--- VALIDATING CONFIGURATIONS ---"

# Validation 1: Check if BACKUP_MODE has valid value
if [[ "$BACKUP_MODE" != "FULL" && "$BACKUP_MODE" != "SPLIT" ]]; then
    echo "ERROR: BACKUP_MODE='$BACKUP_MODE' is invalid."
    echo "Valid values: 'FULL', 'SPLIT'."
    echo ""
    echo "BACKUP_MODE='FULL'  : Backup entire pool in a single file"
    echo "BACKUP_MODE='SPLIT' : Backup each dataset in separate files"
    exit 1
fi

# Validation 2: Check if FILTER_TYPE has valid value
if [[ "$FILTER_TYPE" != "NONE" && "$FILTER_TYPE" != "INCLUDE" && "$FILTER_TYPE" != "EXCLUDE" ]]; then
    echo "ERROR: FILTER_TYPE='$FILTER_TYPE' is invalid."
    echo "Valid values: 'NONE', 'INCLUDE', 'EXCLUDE'."
    echo ""
    echo "FILTER_TYPE='NONE'    : Process all datasets (no filters)"
    echo "FILTER_TYPE='INCLUDE' : Process only datasets listed in FILTER_LIST"
    echo "FILTER_TYPE='EXCLUDE' : Process all except datasets listed in FILTER_LIST"
    exit 1
fi

# Validation 3: Check if DELETION_MODE has valid value
if [[ "$DELETION_MODE" != "PRE_DELETE" && "$DELETION_MODE" != "POST_DELETE" ]]; then
    echo "ERROR: DELETION_MODE='$DELETION_MODE' is invalid."
    echo "Valid values: 'PRE_DELETE', 'POST_DELETE'."
    echo ""
    echo "DELETION_MODE='PRE_DELETE'  : Remove old backups BEFORE sending the new one"
    echo "DELETION_MODE='POST_DELETE' : Remove old backups AFTER sending the new one"
    exit 1
fi

# Validation 4: If BACKUP_MODE is FULL, cannot use filters
if [[ "$BACKUP_MODE" == "FULL" ]]; then
    if [[ "$FILTER_TYPE" != "NONE" ]]; then
        echo "ERROR: BACKUP_MODE='FULL' cannot use FILTER_TYPE='$FILTER_TYPE'."
        echo "For FULL mode, use only FILTER_TYPE='NONE'."
        echo "To use filters, change to BACKUP_MODE='SPLIT'."
        exit 1
    fi
    
    if [[ -n "$FILTER_LIST" ]]; then
        echo "ERROR: BACKUP_MODE='FULL' cannot use FILTER_LIST."
        echo "For FULL mode, leave FILTER_LIST empty."
        echo "To use filters, change to BACKUP_MODE='SPLIT'."
        exit 1
    fi
fi

# Validation 5: If FILTER_TYPE is not NONE, must have FILTER_LIST
if [[ "$FILTER_TYPE" != "NONE" ]]; then
    if [[ -z "$FILTER_LIST" ]]; then
        echo "ERROR: FILTER_TYPE='$FILTER_TYPE' requires a non-empty FILTER_LIST."
        echo "Define FILTER_LIST with datasets separated by comma."
        echo "Example: FILTER_LIST=\"dataset1,dataset2,dataset3\""
        exit 1
    fi
fi

# Validation 6: If FILTER_LIST is not empty, must have valid FILTER_TYPE
if [[ -n "$FILTER_LIST" ]]; then
    if [[ "$FILTER_TYPE" == "NONE" ]]; then
        echo "ERROR: FILTER_LIST defined but FILTER_TYPE='NONE'."
        echo "To use FILTER_LIST, define FILTER_TYPE as 'INCLUDE' or 'EXCLUDE'."
        echo "Or clear FILTER_LIST to use FILTER_TYPE='NONE'."
        exit 1
    fi
fi

echo "✓ All configurations are valid."

echo "--- BACKUP START ---"
echo "Backup mode: $BACKUP_MODE"
echo "Filter: $FILTER_TYPE"
if [ -n "$FILTER_LIST" ]; then
    echo "Filter list: $FILTER_LIST"
fi

case "$BACKUP_MODE" in
    "FULL")
        echo "=== FULL MODE: Backup of entire pool ==="
        
        # --- 1. CREATE LOCAL SNAPSHOT ---
        echo "--- 1. Creating Snapshot: ${SNAPSHOT_ID} ---"
        sudo zfs snapshot -r "${SNAPSHOT_ID}"

        # --- 2. PRE-DELETION LOGIC (PRE_DELETE) ---
        if [[ "$DELETION_MODE" == "PRE_DELETE" ]]; then
            echo "--- 2. PRE_DELETE MODE ACTIVE ---"
            APLICAR_RETENCAO_PRE=$(($RETENTION_BACKUP_FILE_MAX > 0 ? $RETENTION_BACKUP_FILE_MAX - 1 : 0))
            aplicar_politica_retencao $APLICAR_RETENCAO_PRE
        fi

        # --- 3. SENDING NEW FULL ---
        echo "--- 3. Sending New Full (RAW + ZSTD) to S3 ---"
        
        # Complete pool backup (FULL mode always uses FILTER_TYPE="NONE")
        # If this fails, the trap will handle the error automatically
        sudo zfs send -Rwv "${SNAPSHOT_ID}" | \
            sudo zstd | \
            sudo "${RCLONE_BIN}" rcat "${S3_REMOTE}":"${S3_BUCKET_PATH}"/"${ARQUIVO_ATUAL_FULL}"

        echo "✓ Full backup sent successfully"

        # --- 4. POST-DELETION LOGIC (POST_DELETE) ---
        if [[ "$DELETION_MODE" == "POST_DELETE" ]]; then
            echo "--- 4. POST_DELETE MODE ACTIVE ---"
            aplicar_politica_retencao $RETENTION_BACKUP_FILE_MAX
        fi

        # --- 5. Local Cleanup ---
        echo "--- 5. Destroying Temporary Local Snapshot ---"
        sudo zfs destroy "${SNAPSHOT_ID}"
        ;;
        
    "SPLIT")
        echo "=== SPLIT MODE: Backup of individual datasets ==="
        
        # Get dataset list
        echo "--- 1. Getting dataset list ---"
        DATASETS_RAW=$(get_datasets_list "$ZPOOL_ORIGEM")
        DATASETS_FILTERED=$(filter_datasets "$DATASETS_RAW")
        
        if [ -z "$DATASETS_FILTERED" ]; then
            echo "ERROR: No dataset found after applying filters."
            exit 1
        fi
        
        echo "Datasets that will be processed:"
        echo "$DATASETS_FILTERED"
        
        # Create snapshot of all datasets
        echo "--- 2. Creating Snapshot: ${SNAPSHOT_ID} ---"
        sudo zfs snapshot -r "${SNAPSHOT_ID}"
        
        # --- 3. PRE-DELETION LOGIC (PRE_DELETE) ---
        if [[ "$DELETION_MODE" == "PRE_DELETE" ]]; then
            echo "--- 3. PRE_DELETE MODE ACTIVE ---"
            echo "Applying retention policy for each dataset individually..."
            APLICAR_RETENCAO_PRE=$(($RETENTION_BACKUP_FILE_MAX > 0 ? $RETENTION_BACKUP_FILE_MAX - 1 : 0))
            
            # Apply retention for each dataset that will be backed up
            while IFS= read -r dataset; do
                if [ -n "$dataset" ]; then
                    DATASET_SAFE_NAME=$(echo "$dataset" | sed -e 's/\//_/g')
                    echo "Checking retention for dataset: $dataset (pattern: $DATASET_SAFE_NAME)"
                    aplicar_politica_retencao $APLICAR_RETENCAO_PRE "$DATASET_SAFE_NAME"
                fi
            done <<< "$DATASETS_FILTERED"
        fi
        
        # --- 4. SENDING INDIVIDUAL DATASETS ---
        echo "--- 4. Sending individual datasets to S3 ---"
        BACKUP_COUNT=0
        
        while IFS= read -r dataset; do
            if [ -n "$dataset" ]; then
                echo "Processing dataset: $dataset"
                DATASET_SAFE_NAME=$(echo "$dataset" | sed -e 's/\//_/g')
                DATASET_ARQUIVO="zfs_backup_split_${DATASET_SAFE_NAME}_${SNAPSHOT_NOME}.zst"
                
                echo "  Sending $dataset as $DATASET_ARQUIVO"
                
                # Remove if/else structure to allow set -e to work properly
                # If this command fails, the trap will be triggered immediately
                sudo zfs send -Rwv "${dataset}@${SNAPSHOT_NOME}" | \
                    sudo zstd | \
                    sudo "${RCLONE_BIN}" rcat "${S3_REMOTE}":"${S3_BUCKET_PATH}"/"${DATASET_ARQUIVO}"
                
                echo "  ✓ Dataset $dataset sent successfully"
                BACKUP_COUNT=$((BACKUP_COUNT + 1))
            fi
        done <<< "$DATASETS_FILTERED"
        
        echo "Summary: $BACKUP_COUNT dataset(s) sent successfully"
        
        # --- 5. POST-DELETION LOGIC (POST_DELETE) ---
        if [[ "$DELETION_MODE" == "POST_DELETE" ]]; then
            echo "--- 5. POST_DELETE MODE ACTIVE ---"
            echo "Applying retention policy for each dataset individually..."
            
            # Apply retention for each dataset that was backed up successfully
            while IFS= read -r dataset; do
                if [ -n "$dataset" ]; then
                    DATASET_SAFE_NAME=$(echo "$dataset" | sed -e 's/\//_/g')
                    echo "Checking retention for dataset: $dataset (pattern: $DATASET_SAFE_NAME)"
                    aplicar_politica_retencao $RETENTION_BACKUP_FILE_MAX "$DATASET_SAFE_NAME"
                fi
            done <<< "$DATASETS_FILTERED"
        fi
        
        # --- 6. Local Cleanup ---
        echo "--- 6. Destroying Temporary Local Snapshot ---"
        sudo zfs destroy -r "${SNAPSHOT_ID}"
        ;;
esac

echo "--- BACKUP COMPLETED SUCCESSFULLY ---"
echo "Mode used: $BACKUP_MODE"
if [ "$BACKUP_MODE" = "SPLIT" ] && [ -n "$BACKUP_COUNT" ]; then
    echo "Total datasets processed: $BACKUP_COUNT"
fi
echo "Timestamp: $(date)"