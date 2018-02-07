#!/bin/sh

# fail script immediately when any error during execution of deploy script
set -e

# Functions

function getPropertyValueFromFile() {
    echo "$(grep "^$2[ ]\{0,1\}=[ ]\{0,1\}.*" "$1" | cut -d'=' -f2- | xargs)"
}

function checkPropertyExist() {
    echo "$(grep "^$2[ ]\{0,1\}=" "$1")"
}

function replaceOrAppendProperty() {
    if [ "$(checkPropertyExist "$1" "$2")" ]; then
        sed -i'' "s|^[ \t]*${2}[ \t]*=\([ \t]*.*\)$|${2}=${3}|" "$1"
    else
        echo "$2=$3" >> "$1"
    fi
}

function appendValueToProperty() {
    if [ "$(checkPropertyExist "$1" "$2")" ]; then
        sed -i'' "s|^[ \t]*${2}[ \t]*=\([ \t]*.*\)$|&${3}|" "$1"
    fi
}

function editPropertyIfFileExists() {
    if [[ -e "$1" ]] && [[ "x${3}" != "x" ]]; then
        sed -i'' "s|^[ \t]*${2}[ \t]*=\([ \t]*.*\)$|${2}=${3}|" "$1"
    fi

}
function prepare_hazelcast_resources() {
    echo "Starting hazelcast configuration in directory: ${FUSE_HAZELCAST}"

    set +e
    source_dir="$(safe_resolve_dir $WORK_DIR/hazelcast/*/deployment/hazelcast)"
    set -e

    if [[ -d $source_dir ]]; then
        cp -R $source_dir/* $FUSE_HAZELCAST

        pushd $FUSE_HAZELCAST > /dev/null

        for d in * ; do
            if [[ -d $d ]]; then
                echo "<hazelcast xmlns=\"http://www.hazelcast.com/schema/config\"
                            xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"
                            xsi:schemaLocation=\"http://www.hazelcast.com/schema/config http://www.hazelcast.com/schema/config/hazelcast-config-3.5.xsd\">" > "$FUSE_HAZELCAST/${d}${HAZELCAST_CONFIG_FILE_SUFFIX}"
                for f in $d/* ; do
                    echo "  <import resource=\"file:$FUSE_HAZELCAST/$f\"/>" >> "$FUSE_HAZELCAST/${d}${HAZELCAST_CONFIG_FILE_SUFFIX}"
                done
                echo "</hazelcast>" >> "$FUSE_HAZELCAST/${d}${HAZELCAST_CONFIG_FILE_SUFFIX}"
             fi
        done

        popd > /dev/null

    fi
}

function process_liquibase_resources() {
    echo "Starting liquibase configuration in directory: $FUSE_LIQUIBASE"

    set +e
    source_dir="$(safe_resolve_dir $WORK_DIR/liquibase/*/deployment/liquibase-files)"
    set -e

    if [[ -d $source_dir ]]; then
        echo "Building liquibase scripts from: $source_dir"

        cp -R $source_dir/* $FUSE_LIQUIBASE

        pushd $FUSE_LIQUIBASE > /dev/null

        #building migration.xml files per system
        for sys in * ; do
            if [[ -d $sys ]]; then
                process_liquibase_build_migraiton_xml "$FUSE_LIQUIBASE" "$sys"
                process_liquibase_execute "$FUSE_LIQUIBASE/$sys/migration.xml" "$sys"
            fi
        done

        popd > /dev/null
    fi
}

function process_liquibase_build_migraiton_xml() {
    echo "Building liquibase migration file for $2"
    pushd "$1/$2" > /dev/null
    echo '<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
                xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
                http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-3.5.xsd">' \
            > "$1/$2/migration.xml"

    for script in * ; do
        if [[ "$script" != "migration.xml" ]]; then
            echo "      <include file=\"$script\" relativeToChangelogFile=\"true\" />" >> "$1/$2/migration.xml"
        fi
    done

    echo "</databaseChangeLog>" >> "$1/$2/migration.xml"
    popd > /dev/null
}

function process_liquibase_execute() {
    LB_SCRIPT_FILE=$1

    # Find config file
    if [[ "$2" = "default" ]]; then
        config_file="$(find "${FUSE_ETC}" -type f -name "*xads*.cfg" | xargs egrep -i "(xads[0-9]\.osgi\.default[.]{0,1}=[.]{0,1}true)" | cut -d: -f1)"
    else
        config_file="$(find "${FUSE_ETC}" -type f -name "*xads*.cfg" | xargs egrep -i "(xads[0-9]\.osgi\.name[.]{0,1}=[.]{0,1}${2})" | cut -d: -f1)"
    fi

    if [[ "$config_file" = "" ]]; then
        echo "No configuration file found for XADS resource: ${2}, not running liquibase"
        return;
    fi

    echo "Found config file: $config_file, for system: $2"

    config_properties_file="${config_file:0:${#config_file}-4}.properties.cfg"
    echo "Found connection file: $config_properties_file, for system: $2"

    if [[ ! -f "$FUSE_DIR/tooling/liquibase.jar" ]]; then
        echo "ERROR: Liquibase jar missing in: $FUSE_DIR/tooling/liquibase.jar"
        exit 13
    fi

    if [[ ! -e "$FUSE_DIR/tooling/jdbc_drivers" ]]; then
        echo "ERROR: JDBC driver jars re missing in: $FUSE_DIR/tooling/jdbc_drivers/"
        exit 14
    fi

    config_num="$(echo "$config_file" | rev | cut -d. -f2 | rev )"

    echo "Populating db values for liquibase from config file number: $config_num"
    XA_DRIVER_CLASS_NAME="$(getPropertyValueFromFile "$config_file" "${config_num}.ds.class")"
    DRIVER_CLASS_NAME="$(get_jdbc_driver "$XA_DRIVER_CLASS_NAME")"
    DB_SERVER="$(getPropertyValueFromFile "$config_properties_file" "serverName")"
    DB_NAME="$(getPropertyValueFromFile "$config_properties_file" "databaseName")"
    DB_PORT="$(getPropertyValueFromFile "$config_properties_file" "portNumber")"
    DB_USERNAME="$(getPropertyValueFromFile "$config_properties_file" "user")"
    DB_PASSWORD="$(getPropertyValueFromFile "$config_properties_file" "password")"
    LB_DRIVERS_CLASSPATH="`echo $FUSE_DIR/tooling/jdbc_drivers/*jar | tr ' ' ':'`"
    JDBC_URL="$(get_jdbc_url "$DRIVER_CLASS_NAME" "$DB_SERVER" "$DB_PORT" "$DB_NAME")"

    echo "Calling Liquibase script: ${LB_SCRIPT_FILE} with:"
    echo "  Driver:     ${DRIVER_CLASS_NAME}"
    echo "  Script:     ${LB_SCRIPT_FILE}"
    echo "  JDBC URL:   ${JDBC_URL}"
    echo "  Username:   ${DB_USERNAME}"
    echo "  Classpath:  ${LB_DRIVERS_CLASSPATH}"
    echo "Script:"
    cat "${LB_SCRIPT_FILE}"

    java -jar "$FUSE_DIR/tooling/liquibase.jar" \
          --driver="${DRIVER_CLASS_NAME}" \
          --classpath="${LB_DRIVERS_CLASSPATH}" \
          --changeLogFile="${LB_SCRIPT_FILE}" \
          --url="${JDBC_URL}" \
          --username="${DB_USERNAME}" \
          --password="${DB_PASSWORD}" \
          update
}

function get_jdbc_driver() {
    if [[ "$1" == *"microsoft"* ]] ; then
        echo "com.microsoft.sqlserver.jdbc.SQLServerDriver"
    elif [[ "$1" == *"mariadb"* ]] ; then
        echo "org.mariadb.jdbc.Driver"
    else
        (>&2 echo "*** ERROR *** No data base driver found...")
        exit 1
    fi
}

function get_jdbc_url() {
    if [[ "$1" == *"microsoft"* ]] ; then
        echo "jdbc:sqlserver://${2}:${3};databaseName=${4}"
    elif [[ "$1" == *"mariadb"* ]] ; then
        echo "jdbc:mariadb://${2}:${3}/${4}"
    else
        (>&2 echo "*** ERROR *** No data base driver found...")
        exit 1
    fi
}

function reset_to_clean_fuse() {
    echo "Restarting fuse..."

    $FUSE_SERVICE stop
    clean_fuse
    $FUSE_SERVICE start
}

function clean_fuse() {
    echo "Cleaning directory structure in work dir: $WORK_DIR"
    cd $WORK_DIR

    rm -rf $WORK_DIR/bundles
    rm -rf $WORK_DIR/configs
    rm -rf $WORK_DIR/liquibase
    rm -rf $WORK_DIR/hazelcast
    rm -rf $FUSE_REPO
    rm -rf $FUSE_REPO_CACHE
    rm -rf $FUSE_HAZELCAST
    rm -rf $FUSE_LIQUIBASE

    rm -rf $FUSE_CACHE
    rm -rf $FUSE_DEPLOY/*
}

function prepare_directory_structure() {
    echo "Preparing directory structure in work dir: $WORK_DIR"

    cd $WORK_DIR

    mkdir -p $FUSE_REPO
    mkdir -p $FUSE_HAZELCAST
    mkdir -p $FUSE_LIQUIBASE
    mkdir -p $WORK_DIR/bundles
    mkdir -p $WORK_DIR/configs
    mkdir -p $WORK_DIR/liquibase
    mkdir -p $WORK_DIR/hazelcast

    tar -xf *-bundles.tar.gz -C bundles/
    tar -xf *-configs.tar.gz -C configs/
    tar -xf *-liquibase.tar.gz -C liquibase/
    tar -xf *-hazelcast.tar.gz -C hazelcast/

}

function copy_environment_config_files() {
    if [[ -e "$WORK_DIR/configs" ]]; then
        echo "Found configs directory, configuring with environment: $ENVIRONMANTE_NAME"
        cd $WORK_DIR/configs/*/$ENVIRONMANTE_NAME
        cp -R . $FUSE_ETC
    fi
}

function copy_base_resources() {
    echo "Copying files to $FUSE_REPO"
    cd $WORK_DIR/bundles/*/
    cp -R . $FUSE_REPO

    prepare_hazelcast_resources
    process_liquibase_resources

}

function build_init_script() {
    echo "#!/bin/sh
    SF_PROVIDERS_FEATURES=\"${SF_PROVIDERS_FEATURES}\"
    SF_SIMULATORS_FEATURES=\"${SF_SIMULATORS_FEATURES}\"

    echo \"Installing features...\"
    $FUSE_CLIENT \"feature:repo-add mvn:${SF_PROJECT_GROUPID_ARTFACTID}/$FEATURE_VERSION/xml/features\"

    # Workaround for fuse 6.2+ bug, whcih is not showing whether services are started or stopped.
    $FUSE_CLIENT \"osgi:list\" > /dev/null

    echo \"Installing connectivity features...\"
    $FUSE_CLIENT \"feature:install ${SF_PREFIX}connectivity/$FEATURE_VERSION\"

    $FUSE_CLIENT \"osgi:list\" > /dev/null

    echo \"Installing main feature: ${SF_PREFIX}${SF_VARIANT}\"
    $FUSE_CLIENT \"feature:install ${SF_PREFIX}${SF_VARIANT}/$FEATURE_VERSION\"
    sleep 10

    echo \"Installing live providers...\"
    for prov in \${SF_PROVIDERS_FEATURES//,/ }
    do
        prov=(\`echo \"\$prov\" | xargs\`)
        $FUSE_CLIENT \"feature:install ${SF_PREFIX}live-\$prov/$FEATURE_VERSION\"
    done

    echo \"Installing mocks...\"
    for mock in \${SF_SIMULATORS_FEATURES//,/ }
    do
        mock=(\`echo \"\$mock\" | xargs\`)
        $FUSE_CLIENT \"feature:install ${SF_PREFIX}mock-\$mock/$FEATURE_VERSION\"
    done
    " > /opt/fuse/init_features.sh
    chmod a+x /opt/fuse/init_features.sh
}

function build_local_microservice_init_script() {
    echo "#!/bin/sh
    REPOSITORIES=\"${FEATURE_REPOSITORIES}\"
    FEATURES=\"${FEATURE_LIST}\"

    # Workaround for fuse 6.2+ bug, whcih is not showing whether services are started or stopped.
    $FUSE_CLIENT \"osgi:list\" > /dev/null

    echo \"Installing repositories...\"
    for prov in \${REPOSITORIES//,/ }
    do
        prov=(\`echo \"\$prov\" | xargs\`)
        echo \"Installing repository \$prov...\"
        $FUSE_CLIENT \"feature:repo-add \$prov\"
    done

    echo \"Installing features...\"
    for prov in \${FEATURES//,/ }
    do
        prov=(\`echo \"\$prov\" | xargs\`)
        echo \"Installing feature \$prov...\"
        $FUSE_CLIENT \"feature:install \$prov\"
    done

    " > /opt/fuse/init_features.sh
    chmod a+x /opt/fuse/init_features.sh
}

function inject_configuration() {
    echo "Configuring files basing on environment variables..."

    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads1.properties.cfg" "serverName" "$XADS1_SERVICE_NAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads1.properties.cfg" "user" "$XADS1_USERNAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads1.properties.cfg" "password" "$XADS1_PASSWORD"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads1.properties.cfg" "portNumber" "$XADS1_PORT"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads1.properties.cfg" "databaseName" "$XADS1_DB"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads2.properties.cfg" "serverName" "$XADS2_SERVICE_NAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads2.properties.cfg" "user" "$XADS2_USERNAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads2.properties.cfg" "password" "$XADS2_PASSWORD"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads2.properties.cfg" "portNumber" "$XADS2_PORT"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads2.properties.cfg" "databaseName" "$XADS2_DB"

    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads1.cfg" "xads1.osgi.name" "$XADS1_NAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads1.cfg" "xads1.osgi.default" "$XADS1_DEFAULT"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads2.cfg" "xads2.osgi.name" "$XADS2_NAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads2.cfg" "xads2.osgi.default" "$XADS2_DEFAULT"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads1.cfg" "xads1.ds.class" "$XADS1_DRIVER"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.xads2.cfg" "xads2.ds.class" "$XADS2_DRIVER"

    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.jms1.cfg" "jms1.url" "$JMS1_SERVICE_NAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.jms1.cfg" "jms1.user" "$JMS1_USERNAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.jms1.cfg" "jms1.password" "$JMS1_PASSWORD"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.jms2.cfg" "jms2.url" "$JMS2_SERVICE_NAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.jms2.cfg" "jms2.user" "$JMS2_USERNAME"
    editPropertyIfFileExists "$FUSE_ETC/com.integ.connectivity.jms2.cfg" "jms2.password" "$JMS2_PASSWORD"
}

function docker_deploy_local_service() {
    inject_configuration
    copy_base_resources

    echo "Configure boot features: $FEATURE_LIST..."

    build_local_microservice_init_script
}

function docker_deploy_microservice() {
    copy_environment_config_files
    inject_configuration
    copy_base_resources

    echo "Configure boot features..."

    build_init_script
}

function openshift_deploy_microservice() {
    prepare_directory_structure
    copy_environment_config_files
    copy_base_resources

    echo "Configure boot features..."

    build_init_script
}

function openshift_deploy() {
    prepare_directory_structure
    copy_environment_config_files
    inject_configuration
    copy_base_resources
    echo "Configure boot features..."

    build_init_script
}

function bamboo_deploy() {
    FEATURE_VERSION="`cat $WORK_DIR/build.result.version.txt`"

    reset_to_clean_fuse
    prepare_directory_structure
    copy_environment_config_files
    copy_base_resources
    build_init_script

    /opt/fuse/init_features.sh
}

function local_configure() {
    if [ "${WORK_DIR}" = "" ] || [ "${FUSE_DIR}" = "" ]
    then
        echo "\nError: Cannot determine directory structure, maybe you are missing -f=<path_to_fuse> parameter?"
        echo "See usage for help:"
        print_usage
        exit 10
    fi

    clean_fuse
    prepare_directory_structure
    prepare_hazelcast_resources
    process_liquibase_resources
}

function safe_resolve_dir() {
    stderr="$(pushd "$1" > /dev/null)"
    if [ "${?}" != "0" ]; then
        echo "Error occurred when safe resolving directory"  >&2
        echo "/non/existing/directory/as/given/one/was/not/found"
        exit 11
    fi

    pushd "$1" > /dev/null
    echo "$(pwd -L)"
    popd > /dev/null
}

function print_usage() {
    echo ""
    echo "Usage"
    echo "Action indication flags:"
    echo "  --configure     Indicates that we want to do configuration only, no deploy logic executed"
    echo "  --deploy        Peforms full deployment, including configuration. To be used by Bamboo"
    echo ""
    echo "Parameters:"
    echo "  -f=             Fuse root directory"
    echo "  --fusedir=      Fuse root directory"
    echo ""
    echo "Other:"
    echo "  --help          To see this help"
    echo ""
    exit 12
}

#Parsing arguments

for i in "$@"
do
case $i in
    -f=*|--fusedir=*)
    FUSE_DIR="$(safe_resolve_dir "${i#*=}")"
    shift # past argument=value
    ;;
    --configure)
    MODE="config"
    WORK_DIR="$(safe_resolve_dir "$(dirname "${0}")/../../../../target")"
    shift # past argument with no value
    ;;
    --deploy)
    MODE="deploy"
    shift # past argument with no value
    ;;
    --deploy-openshift)
    MODE="deploy-openshift"
    shift # past argument with no value
    ;;
    --deploy-microservice-openshift)
    MODE="deploy-microservice-openshift"
    shift # past argument with no value
    ;;
    --deploy-microservice-docker)
    MODE="deploy-microservice-docker"
    shift # past argument with no value
    ;;
    --deploy-local-service-docker)
    MODE="deploy-local-service-docker"
    shift # past argument with no value
    ;;
    --help)
    print_usage
    ;;
    *)
        echo "Unknown parameter passed, stopping"
        exit 1
    ;;
esac
done

if [[ "$WORK_DIR" = "" ]]; then
    echo "WORK_DIR directory not set properly, are you trying to run --deploy manually? This is very dangerous as require many variables to be exported and should be used only by bamboo."
    exit 2
fi


ENVIRONMANTE_NAME="${SF_ENV_NAME}"

FUSE_CACHE=$FUSE_DIR/data/cache
FUSE_REPO_CACHE=$FUSE_DIR/data/repository
FUSE_DEPLOY=$FUSE_DIR/deploy
FUSE_ETC=$FUSE_DIR/etc.integ
FUSE_HAZELCAST=$FUSE_DIR/hazelcast.confd
FUSE_LIQUIBASE=$FUSE_DIR/liquibase-files
FUSE_REPO=$FUSE_DIR/repository

FUSE_CLIENT="$FUSE_DIR/bin/client -r 25 -d 10 "
HAZELCAST_CONFIG_FILE_SUFFIX=-config.xml


# Main code

echo "Starting srcript using WORK_DIR=$WORK_DIR"

if [ "${MODE}" = "config" ]
then
    local_configure
elif  [ "${MODE}" = "deploy" ]
then
    bamboo_deploy
elif  [ "${MODE}" = "deploy-openshift" ]
then
    openshift_deploy
elif  [ "${MODE}" = "deploy-microservice-openshift" ]
then
    openshift_deploy_microservice
elif  [ "${MODE}" = "deploy-microservice-docker" ]
then
    docker_deploy_microservice
elif  [ "${MODE}" = "deploy-local-service-docker" ]
then
    docker_deploy_local_service
else
    print_usage
fi