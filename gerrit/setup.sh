#!/bin/bash

# Copyright (C) 2019 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

GERRIT_VERSION=$1
PLUGINS_VERSION=$(echo ${GERRIT_VERSION} | cut -d'.' -f1-2)

export CI_BASE=https://gerrit-ci.gerritforge.com/view/Plugins-stable-${PLUGINS_VERSION}/job
export GROOVY_PROVIDER_BASE=plugin-scripting-groovy-provider-bazel-master-stable-${PLUGINS_VERSION}
if [ "$PLUGINS_VERSION" = "2.14" ] || [ "$PLUGINS_VERSION" = "2.15" ]; then
  export CI_BASE=https://archive-ci.gerritforge.com/view/Plugins-stable-${PLUGINS_VERSION}
  export GROOVY_PROVIDER_BASE=plugin-scripting-groovy-provider-bazel-stable-${PLUGINS_VERSION}
fi

export COMMON_LOCATION=/tmp/migration/gerrit_setup
export LOCATION_TEST_SITE_1=$COMMON_LOCATION/instance-1
export LOCATION_TEST_SITE_2=$COMMON_LOCATION/instance-2
export FAKE_NFS=$COMMON_LOCATION/fake_nfs
export RELEASE_WAR_FILE_LOCATION=${COMMON_LOCATION}/gerrit.war
export CONF_TEST_SITE_1=${LOCATION_TEST_SITE_1}/etc/gerrit.config
export CONF_HA_TEST_SITE_1=${LOCATION_TEST_SITE_1}/etc/high-availability.config
export CONF_TEST_SITE_2=${LOCATION_TEST_SITE_2}/etc/gerrit.config
export CONF_HA_TEST_SITE_2=${LOCATION_TEST_SITE_2}/etc/high-availability.config

function install_plugins() {
  local dir=$1
  local plugin_dir=$dir/plugins
  local lib_dir=$dir/lib

#audit-sl4j
wget ${CI_BASE}/plugin-metrics-reporter-prometheus-bazel-stable-${PLUGINS_VERSION}/lastSuccessfulBuild/artifact/bazel-bin/plugins/metrics-reporter-prometheus/metrics-reporter-prometheus.jar -O "$plugin_dir/metrics-reporter-prometheus.jar"
wget ${CI_BASE}/${GROOVY_PROVIDER_BASE}/lastSuccessfulBuild/artifact/bazel-bin/plugins/groovy-provider/groovy-provider.jar -O "$plugin_dir/groovy-provider.jar"
# wget ${CI_BASE}/plugin-high-availability-bazel-stable-${PLUGINS_VERSION}/lastSuccessfulBuild/artifact/bazel-bin/plugins/high-availability/high-availability.jar -O "$plugin_dir/high-availability.jar"
wget ${CI_BASE}/plugin-javamelody-bazel-stable-${PLUGINS_VERSION}/lastSuccessfulBuild/artifact/bazel-bin/plugins/javamelody/javamelody.jar -O "$plugin_dir/javamelody.jar"
wget ${CI_BASE}/plugin-javamelody-bazel-stable-${PLUGINS_VERSION}/lastSuccessfulBuild/artifact/bazel-bin/plugins/javamelody/javamelody-deps_deploy.jar -O "$lib_dir/javamelody-deps_deploy.jar"
wget ${CI_BASE}/plugin-readonly-bazel-stable-${PLUGINS_VERSION}/lastSuccessfulBuild/artifact/bazel-bin/plugins/readonly/readonly.jar  -O "$plugin_dir/readonly.jar"
}

function configure_ha_plugin() {
  local conf_file=$1
  local peer_info=$2

git config -f ${conf_file} main.sharedDirectory $FAKE_NFS
git config -f ${conf_file} peerInfo.strategy static
git config -f ${conf_file} peerInfo.static.url ${peer_info}
git config -f ${conf_file} autoReindex.enabled true
}

function configure_gerrit() {
  local conf_file=$1
  local gerrit_port=$2
  local sshd_port=$3

#DB
git config -f ${conf_file} database.dataSourceInterceptorClass 'com.googlesource.gerrit.plugins.javamelody.MonitoringDataSourceInterceptor'
git config -f ${conf_file} database.database 'reviewdb'
git config -f ${conf_file} database.hostname 'localhost'
git config -f ${conf_file} database.password 'secret'
git config -f ${conf_file} database.poolLimit '270'
git config -f ${conf_file} database.poolMaxIdle '16'
git config -f ${conf_file} database.port '5432'
git config -f ${conf_file} database.type 'postgresql'
git config -f ${conf_file} database.username 'gerrit'

# LDAP
git config -f ${conf_file} ldap.server 'ldap://localhost'
git config -f ${conf_file} ldap.username 'cn=admin,dc=example,dc=org'
git config -f ${conf_file} ldap.accountBase 'dc=example,dc=org'
git config -f ${conf_file} ldap.accountPattern '(&(objectClass=person)(uid=${username}))'
git config -f ${conf_file} ldap.accountFullName 'displayName'
git config -f ${conf_file} ldap.accountEmailAddress 'mail'
git config -f ${conf_file} ldap.groupBase 'dc=example,dc=org'
git config -f ${conf_file} ldap.password "secret"

#[index]
git config -f ${conf_file} index.autoReindexIfStale 'False'
git config -f ${conf_file} index.batchThreads '12'
git config -f ${conf_file} index.threads '6'
git config -f ${conf_file} index.type 'LUCENE'

#[auth]
git config -f ${conf_file} auth.gitBasicAuthPolicy 'HTTP_LDAP'
git config -f ${conf_file} auth.type 'ldap'
git config -f ${conf_file} auth.userNameToLowerCase 'True'

#[receive]
git config -f ${conf_file} receive.checkReferencedObjectsAreReachable 'False'
git config -f ${conf_file} receive.enableSignedPush 'False'
git config -f ${conf_file} receive.maxBatchChanges '50'
git config -f ${conf_file} receive.maxObjectSizeLimit '50m'

git config -f ${conf_file} gerrit.serverId '175d01ee-4b2a-462c-bae4-2081138dddc7'

#[sshd]
git config -f ${conf_file} sshd.listenAddress "*:${sshd_port}"

# download
git config -f ${conf_file} download.scheme 'ssh'
git config -f ${conf_file} download.scheme 'http'
git config -f ${conf_file} download.command 'checkout'
git config -f ${conf_file} download.command 'cherry_pick'
git config -f ${conf_file} download.command 'pull'
git config -f ${conf_file} download.command 'format_patch'

#Notedb
git config -f ${conf_file} noteDb.changes.autoMigrate 'false'
git config -f ${conf_file} noteDb.changes.trial 'false'
git config -f ${conf_file} noteDb.changes.write 'false'
git config -f ${conf_file} noteDb.changes.read 'false'
git config -f ${conf_file} noteDb.changes.sequence 'false'
git config -f ${conf_file} noteDb.changes.primaryStorage 'review db'
git config -f ${conf_file} noteDb.changes.disableReviewDb 'false'

git config -f ${conf_file} gerrit.canonicalWebUrl "http://localhost:${gerrit_port}"
git config -f ${conf_file} httpd.listenUrl "http://*:${gerrit_port}/"
}

pushd ${LOCATION_TEST_SITE_1} || echo "${LOCATION_TEST_SITE_1} doesn't exist. nothing to do"
./bin/gerrit.sh stop
popd

pushd ${LOCATION_TEST_SITE_2} || echo "${LOCATION_TEST_SITE_2} doesn't exist. nothing to do"
./bin/gerrit.sh stop
popd

rm -rf $COMMON_LOCATION $LOCATION_TEST_SITE_1 $LOCATION_TEST_SITE_2 $FAKE_NFS
mkdir -p $COMMON_LOCATION $LOCATION_TEST_SITE_1 $LOCATION_TEST_SITE_2 $FAKE_NFS

wget https://gerrit-releases.storage.googleapis.com/gerrit-"$GERRIT_VERSION".war \
  -O ${RELEASE_WAR_FILE_LOCATION} || { echo >&2 "Cannot download gerrit.war plugin: Check internet connection. Abort\
ing"; exit 1; }

java -jar ${RELEASE_WAR_FILE_LOCATION} init -d ${LOCATION_TEST_SITE_1} --install-all-plugins --batch --no-auto-start
configure_gerrit ${CONF_TEST_SITE_1} 18080 39418
configure_ha_plugin ${CONF_HA_TEST_SITE_1} 'http://localhost:18081'
install_plugins ${LOCATION_TEST_SITE_1}

java -jar ${RELEASE_WAR_FILE_LOCATION} init -d ${LOCATION_TEST_SITE_2} --install-all-plugins --batch --no-auto-start
configure_gerrit ${CONF_TEST_SITE_2} 18081 49418
configure_ha_plugin ${CONF_HA_TEST_SITE_2} 'http://localhost:18080'
install_plugins ${LOCATION_TEST_SITE_2}

rm -rf ${LOCATION_TEST_SITE_2}/git && \
ln -fs ${LOCATION_TEST_SITE_1}/git ${LOCATION_TEST_SITE_2}/git

echo "Start instance-1"
pushd ${LOCATION_TEST_SITE_1} || echo "${LOCATION_TEST_SITE_1} doesn't exist. nothing to do"
rm -rf ./db/ReviewDb.*
java -jar ${RELEASE_WAR_FILE_LOCATION} init -d ${LOCATION_TEST_SITE_1} --install-all-plugins --batch --no-auto-start
./bin/gerrit.sh restart
popd

echo "Start instance-2"
pushd ${LOCATION_TEST_SITE_2} || echo "${LOCATION_TEST_SITE_2} doesn't exist. nothing to do"
rm -rf ./db/ReviewDb.*
./bin/gerrit.sh restart
popd
