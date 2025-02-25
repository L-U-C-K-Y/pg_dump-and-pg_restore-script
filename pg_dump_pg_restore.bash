#!/bin/bash

# PostgreSQL credentials
PGHOST_DUMP=dump-host.com
PGPORT_DUMP=5432
PGUSER_DUMP=postgres

PGHOST_RESTORE=restore-host.com
PGPORT_RESTORE=5432
PGUSER_RESTORE=postgres

# Array of databases
DATABASES=(
  db1
  db2
  db3
)

# Parallel jobs for restore
JOBS=4

# Setup directories and logging
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
DUMP_DIR="./${TIMESTAMP}/"
mkdir -p $DUMP_DIR
LOGFILE="${DUMP_DIR}pg_dump_restore.log"

# Logging function
log() {
  echo "--------------------------------------------------------------------------"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOGFILE}"
  echo "--------------------------------------------------------------------------"
}

convertsecs() {
    h=$(($1/3600))
    m=$(($1%3600/60))
    s=$(($1%60))
    printf "%02d:%02d:%02d\n" $h $m $s
}

# Check disk space
REQUIRED_DISK_SPACE=2048
CURRENT_DISK_SPACE=$(df / | tail -1 | awk '{print $4}')

if (( CURRENT_DISK_SPACE < REQUIRED_DISK_SPACE )); then
  log "Not enough disk space. Required: ${REQUIRED_DISK_SPACE}MB, Available: ${CURRENT_DISK_SPACE}MB"
  exit 1
fi

# Print connection info
log "Dump Connection:"
log "Host: $PGHOST_DUMP"
log "Port: $PGPORT_DUMP"
log "User: $PGUSER_DUMP"
log "Restore Connection:"
log "Host: $PGHOST_RESTORE"
log "Port: $PGPORT_RESTORE"
log "User: $PGUSER_RESTORE"

# Get passwords
printf "Please enter the PostgreSQL password for dump: "
read -s PGPASSWORD_DUMP
export PGPASSWORD_DUMP
echo

printf "Please enter the PostgreSQL password for restore: "
read -s PGPASSWORD_RESTORE
export PGPASSWORD_RESTORE
echo

# Test connections
PGPASSWORD=$PGPASSWORD_DUMP psql -h $PGHOST_DUMP -p $PGPORT_DUMP -U $PGUSER_DUMP -d postgres -c '\q' || exit 1
log "Dump connection successful."
PGPASSWORD=$PGPASSWORD_RESTORE psql -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE -d postgres -c '\q' || exit 1
log "Restore connection successful."

# DUMP SECTION
log "STARTING DUMP"
START_TIME_TOTAL_DUMP=$(date +%s)

for DB_NAME in "${DATABASES[@]}"
do
  DUMP_FILE="${DB_NAME}.dump"
  DUMP_FILE_PATH="${DUMP_DIR}${DUMP_FILE}"

  log "Creating PostgreSQL dump of database $DB_NAME..."
  START_TIME=$(date +%s)
  
  PGPASSWORD=$PGPASSWORD_DUMP pg_dump -h $PGHOST_DUMP -p $PGPORT_DUMP -U $PGUSER_DUMP -Fc -f $DUMP_FILE_PATH $DB_NAME
  if [ $? -eq 0 ]; then
    END_TIME=$(date +%s)
    log "Dump of $DB_NAME created at $DUMP_FILE_PATH in $(convertsecs $((END_TIME-START_TIME)))"
  else
    log "Failed to create dump of $DB_NAME"
    exit 1
  fi
done

END_TIME_TOTAL_DUMP=$(date +%s)
log "DUMP COMPLETED in $(convertsecs $((END_TIME_TOTAL_DUMP-START_TIME_TOTAL_DUMP)))"

# RESTORE SECTION
RESTORE_DIR=$DUMP_DIR

log "STARTING RESTORE"
START_TIME_TOTAL_RESTORE=$(date +%s)

for DB_NAME in "${DATABASES[@]}"
do
  RESTORE_FILE="${DB_NAME}.dump"
  RESTORE_FILE_PATH="${RESTORE_DIR}${RESTORE_FILE}"

  # Create role name
  ROLE_NAME=$(echo $DB_NAME | rev | cut -d '_' -f 2- | rev)

  # Check/create role
  PGPASSWORD=$PGPASSWORD_RESTORE psql -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE -tAc "SELECT 1 FROM pg_roles WHERE rolname='$ROLE_NAME'" | grep -q 1
  if [ $? -eq 0 ]; then
    log "Role $ROLE_NAME exists."
  else
    log "Creating role $ROLE_NAME..."
    PGPASSWORD=$PGPASSWORD_RESTORE psql -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE -c "CREATE ROLE $ROLE_NAME LOGIN;"
  fi

  log "Adding $PGUSER_RESTORE to role $ROLE_NAME..."
  PGPASSWORD=$PGPASSWORD_RESTORE psql -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE -c "GRANT $ROLE_NAME TO $PGUSER_RESTORE;"

  # Check/handle existing database
  PGPASSWORD=$PGPASSWORD_RESTORE psql -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1
  if [ $? -eq 0 ]; then
    log "Database $DB_NAME exists."
    printf "Do you want to drop the existing database (y/n): "
    read DROP_DB
    if [ "$DROP_DB" = "y" ]; then
      log "Dropping database $DB_NAME..."
      PGPASSWORD=$PGPASSWORD_RESTORE dropdb -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE $DB_NAME
    else
      log "Skipping restore for database $DB_NAME"
      continue
    fi
  fi

  log "Creating database $DB_NAME..."
  PGPASSWORD=$PGPASSWORD_RESTORE createdb -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE $DB_NAME

  log "Granting permissions to $ROLE_NAME on database $DB_NAME..."
  PGPASSWORD=$PGPASSWORD_RESTORE psql -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE -c "GRANT CONNECT, TEMPORARY ON DATABASE $DB_NAME TO $ROLE_NAME;"

  log "Restoring PostgreSQL database $DB_NAME..."
  START_TIME=$(date +%s)

  PGPASSWORD=$PGPASSWORD_RESTORE pg_restore -h $PGHOST_RESTORE -p $PGPORT_RESTORE -U $PGUSER_RESTORE -d $DB_NAME -j $JOBS -Fc $RESTORE_FILE_PATH
  END_TIME=$(date +%s)
  log "Database $DB_NAME restored from $RESTORE_FILE_PATH in $(convertsecs $((END_TIME-START_TIME)))"
done

END_TIME_TOTAL_RESTORE=$(date +%s)
log "RESTORE COMPLETED in $(convertsecs $((END_TIME_TOTAL_RESTORE-START_TIME_TOTAL_RESTORE)))"

unset PGPASSWORD_DUMP
unset PGPASSWORD_RESTORE