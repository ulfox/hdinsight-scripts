## Set runtime opts
set -o pipefail

## Runtime functions

### Set exec error
trap 'catch_err $? $LINENO' ERR

### Log action is used for all lines that would do a simple echo
function log_action() {
    echo "$(printf  '%(%Y-%m-%d %H:%M:%S)T\n'): ${*}"  | tee -a /var/log/lenses/setup.log
}

### Die function for printing message in stdout and exiting with 1
function die() {
    for i in "${@}"; do
        log_action "${i}"
    done
    exit 1
}

### Trap exec error function handler
function catch_err() {
    log_action  "Line ${2} with error: ${1}\n\nEnd of Execution"
}

### Create lenses logdir
mkdir -vp /var/log/lenses

### Write input to $logdir/env
base64 <<< "${@}" > /var/log/lenses/env
chmod 0600 /var/log/lenses/env

### Check Args function
function args_check() {
    if [ "${1}" == "" ] || [ -z "${1// }" ] || [[ "${1}" =~ ^\- ]]; then
        return 1
    else
        return 0
    fi
}

export LENSES_VERSION="4.0.9"
export LENSES_ARCHIVE="lenses-latest-linux64.tar.gz"
export TMP_DIR="/tmp"

### Optionarg parserer
while [ "${#}" -gt 0 ]; do
    case "${1}" in
        "-n")
            if args_check "${2}"; then
                export CLUSTER_NAME="${2}"
                shift 1
            fi;;
        "-l")
            if args_check "${2}"; then
                export LICENSE="${2}"
                shift 1
            fi;;
        "-t")
            if args_check "${2}"; then
                export LENSES_STORAGE_TYPE="${2}"
                shift 1
            fi;;
        "-H")
            if args_check "${2}"; then
                export LENSES_STORAGE_POSTGRES_HOSTNAME="${2}"
                shift 1
            fi;;
        "-E")
            if args_check "${2}"; then
                export LENSES_STORAGE_POSTGRES_PORT="${2}"
                shift 1
            fi;;
        "-U")
            if args_check "${2}"; then
                export LENSES_STORAGE_POSTGRES_USERNAME="${2}"
                shift 1
            fi;;
        "-P")
            if args_check "${2}"; then
                export LENSES_STORAGE_POSTGRES_PASSWORD="${2}"
                shift 1
            fi;;
        "-D")
            if args_check "${2}"; then
                export LENSES_STORAGE_POSTGRES_DATABASE="${2}"
                shift 1
            fi;;
        *)
            echo "Option ${optname} is not supported" | tee -a ;;
    esac
    shift 1
done

env | tee -a  /var/log/lenses/env

while getopts n:l:g: optname; do
  case $optname in
    n)
      CLUSTER_NAME="${OPTARG}";;
    l)
      LICENSE="${OPTARG}";;
    *)
      echo "Option ${optname} is not supported";;
  esac
done

## Set Lenses Global Environment
LENSES_VERSION="4.0"
LENSES_ARCHIVE="lenses-latest-linux64.tar.gz"
LENSES_ARCHIVE_URI="https://archive.landoop.com/lenses/${LENSES_VERSION}/${LENSES_ARCHIVE}"
TMP_DIR="/tmp"

# Ambari Watch Dog Username and Password since user's username/password are not passed from the HDI app deployment template
CLUSTER_ADMIN=$(python - <<'CLUSTER_ADMIN_END'
import hdinsight_common.Constants as Constants
print Constants.AMBARI_WATCHDOG_USERNAME
CLUSTER_ADMIN_END
)

CLUSTER_PASSWORD=$(python - <<'CLUSTER_PASSWORD_END'
import hdinsight_common.ClusterManifestParser as ClusterManifestParser
import hdinsight_common.Constants as Constants
import base64

base64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password
print base64.b64decode(base64pwd)
CLUSTER_PASSWORD_END
)

CLUSTER_NAME=$(python - <<'CLUSTER_NAME_END'
import hdinsight_common.ClusterManifestParser as ClusterManifestParser
print ClusterManifestParser.parse_local_manifest().deployment.cluster_name
CLUSTER_NAME_END
)

if ! command -v jq >/dev/null 2>&1 || ! command -v hashalot >/dev/null 2>&1; then
    apt -y install jq hashalot
fi

# Fetch Lenses Archive
rm -f "${TMP_DIR}/${LENSES_ARCHIVE}"
wget -q "${LENSES_ARCHIVE_URI}" -P "${TMP_DIR}"

echo "Untar Lenses Archive"
tar -xzf "${TMP_DIR}/${LENSES_ARCHIVE}" -C /opt/

# AutoDiscover Kafka Brokers and Zookeeper
echo "AutoDiscover Brokers and Zookeper"
LENSES_KAFKA_BROKERS=$(curl -u $CLUSTER_ADMIN:$CLUSTER_PASSWORD -sS -G "http://headnodehost:8080/api/v1/clusters/$CLUSTER_NAME/services/KAFKA/components/KAFKA_BROKER" \
    | jq -r '.host_components[].HostRoles.host_name')

if [ -z "${LENSES_KAFKA_BROKERS}" ]; then
    echo "[ERROR] Unable to find Cluster Kafka Brokers"         
    exit 1
fi

LENSES_ZOOKEPER=$(curl -u $CLUSTER_ADMIN:$CLUSTER_PASSWORD -sS -G "http://headnodehost:8080/api/v1/clusters/$CLUSTER_NAME/services/ZOOKEEPER/components/ZOOKEEPER_SERVER" \
    | jq -r '.host_components[].HostRoles.host_name')

# Configure Lenses
chmod -R 0755 /opt/lenses
cd /opt/lenses

# Make lenses.conf & security.conf empty
touch lenses.conf
touch security.conf

cat << EOF > /opt/lenses/lenses.conf
lenses.port=9991

lenses.secret.file=security.conf
lenses.sql.state.dir="kafka-streams-state"
lenses.license.file=license.json
EOF
if [ ! -z "$LENSES_KAFKA_BROKERS" ]; then
    for broker in $LENSES_KAFKA_BROKERS; do
        brokers="${brokers:+$brokers,}PLAINTEXT://$broker:9092"
    done
    echo lenses.kafka.brokers="\"${brokers}\"" >> /opt/lenses/lenses.conf
fi

if [ ! -z "$LENSES_ZOOKEPER" ]; then
    for host in $LENSES_ZOOKEPER; do
        zookeper="${zookeper:+$zookeper, }{url:\"$host:2181\"}"
    done
    echo lenses.zookeeper.hosts="[${zookeper}]" >> /opt/lenses/lenses.conf
fi

# Append Lenses License
cat << EOF > /opt/lenses/license.json
${LICENSE}
EOF

if [ "${LENSES_STORAGE_TYPE}" == "postgres" ]; then
cat << EOF >> /opt/lenses/lenses.conf
lenses.storage.postgres.database: "${LENSES_STORAGE_POSTGRES_DATABASE}"
lenses.storage.postgres.host: "${LENSES_STORAGE_POSTGRES_HOSTNAME}"
lenses.storage.postgres.port: "${LENSES_STORAGE_POSTGRES_PORT}"
lenses.storage.postgres.username: "${LENSES_STORAGE_POSTGRES_USERNAME}"
EOF
cat << EOF >> /opt/lenses/security.conf
lenses.storage.postgres.password: "${LENSES_STORAGE_POSTGRES_PASSWORD}"
EOF
fi

# Systemd service for Lenses
touch /etc/systemd/system/lenses-io.service
cat << EOF > /etc/systemd/system/lenses-io.service
[Unit]
Description=Run Lenses.io Service
;After=opt-lenses.mount
;Requires=opt-lenses.mount

[Service]
Restart=always
User=root
Group=root
LimitNOFILE=4096
PermissionsStartOnly=true

Environment=FORCE_JAVA_HOME="/opt/lenses/jre"
Environment=LT_PACKAGE="azure_hdinsight"
Environment=LT_PACKAGE_VERSION=${LENSES_VERSION}

WorkingDirectory=/opt/lenses
ExecStart=/opt/lenses/bin/lenses lenses.conf

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart lenses-io
systemctl enable lenses-io.service

