#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# This script starts a local karmada control plane based on current codebase and with a certain number of clusters joined.
# Parameters: [HOST_IPADDRESS](optional) if you want to export clusters' API server port to specific IP address
# This script depends on utils in: ${REPO_ROOT}/hack/util.sh
# 1. used by developer to setup develop environment quickly.
# 2. used by e2e testing to setup test environment automatically.

function usage() {
    echo "Usage:"
    echo "    hack/local-up-karmada.sh [HOST_IPADDRESS] [-h]"
    echo "Args:"
    echo "    HOST_IPADDRESS: (optional) if you want to export clusters' API server port to specific IP address"
    echo "    h: print help information"
}

while getopts 'h' OPT; do
    case $OPT in
        h)
          usage
          exit 0
          ;;
        ?)
          usage
          exit 1
          ;;
    esac
done

REPO_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
source "${REPO_ROOT}"/hack/util.sh

# variable define
KUBECONFIG_PATH=${KUBECONFIG_PATH:-"${HOME}/.kube"}
MAIN_KUBECONFIG=${MAIN_KUBECONFIG:-"${KUBECONFIG_PATH}/karmada.config"}
HOST_CLUSTER_NAME=${HOST_CLUSTER_NAME:-"karmada-host"}
KARMADA_APISERVER_CLUSTER_NAME=${KARMADA_APISERVER_CLUSTER_NAME:-"karmada-apiserver"}
MEMBER_CLUSTER_KUBECONFIG=${MEMBER_CLUSTER_KUBECONFIG:-"${KUBECONFIG_PATH}/members.config"}
MEMBER_CLUSTER_1_NAME=${MEMBER_CLUSTER_1_NAME:-"member1"}
MEMBER_CLUSTER_2_NAME=${MEMBER_CLUSTER_2_NAME:-"member2"}
PULL_MODE_CLUSTER_NAME=${PULL_MODE_CLUSTER_NAME:-"member3"}
MEMBER_TMP_CONFIG_PREFIX="member-tmp"
MEMBER_CLUSTER_1_TMP_CONFIG="${KUBECONFIG_PATH}/${MEMBER_TMP_CONFIG_PREFIX}-${MEMBER_CLUSTER_1_NAME}.config"
MEMBER_CLUSTER_2_TMP_CONFIG="${KUBECONFIG_PATH}/${MEMBER_TMP_CONFIG_PREFIX}-${MEMBER_CLUSTER_2_NAME}.config"
PULL_MODE_CLUSTER_TMP_CONFIG="${KUBECONFIG_PATH}/${MEMBER_TMP_CONFIG_PREFIX}-${PULL_MODE_CLUSTER_NAME}.config"
HOST_IPADDRESS=${1:-}

CLUSTER_VERSION=${CLUSTER_VERSION:-"kindest/node:v1.27.3"}
KIND_LOG_FILE=${KIND_LOG_FILE:-"/tmp/karmada"}

#step0: prepare
# proxy setting in China mainland
if [[ -n ${CHINA_MAINLAND:-} ]]; then
  util::set_mirror_registry_for_china_mainland ${REPO_ROOT}
fi

# Make sure go exists and the go version is a viable version.
util::cmd_must_exist "go"
util::verify_go_version

# Make sure docker exists
util::cmd_must_exist "docker"

# install kind and kubectl
kind_version=v0.20.0
echo -n "Preparing: 'kind' existence check - "
if util::cmd_exist kind; then
  echo "passed"
else
  echo "not pass"
  util::install_tools "sigs.k8s.io/kind" $kind_version
fi
# get arch name and os name in bootstrap
BS_ARCH=$(go env GOARCH)
BS_OS=$(go env GOOS)
# check arch and os name before installing
util::install_environment_check "${BS_ARCH}" "${BS_OS}"
echo -n "Preparing: 'kubectl' existence check - "
if util::cmd_exist kubectl; then
  echo "passed"
else
  echo "not pass"
  util::install_kubectl "" "${BS_ARCH}" "${BS_OS}"
fi
#step1. create host cluster and member clusters in parallel
# host IP address: script parameter ahead of macOS IP
if [[ -z "${HOST_IPADDRESS}" ]]; then
  util::get_macos_ipaddress # Adapt for macOS
  HOST_IPADDRESS=${MAC_NIC_IPADDRESS:-}
fi
#prepare for kindClusterConfig
TEMP_PATH=$(mktemp -d)
trap '{ rm -rf ${TEMP_PATH}; }' EXIT
echo -e "Preparing kindClusterConfig in path: ${TEMP_PATH}"
cp -rf "${REPO_ROOT}"/artifacts/kindClusterConfig/member1.yaml "${TEMP_PATH}"/member1.yaml
cp -rf "${REPO_ROOT}"/artifacts/kindClusterConfig/member2.yaml "${TEMP_PATH}"/member2.yaml

util::delete_all_clusters "${MAIN_KUBECONFIG}" "${MEMBER_CLUSTER_KUBECONFIG}" "${KIND_LOG_FILE}"

if [[ -n "${HOST_IPADDRESS}" ]]; then # If bind the port of clusters(karmada-host, member1 and member2) to the host IP
  util::verify_ip_address "${HOST_IPADDRESS}"
  cp -rf "${REPO_ROOT}"/artifacts/kindClusterConfig/karmada-host.yaml "${TEMP_PATH}"/karmada-host.yaml
  sed -i'' -e "s/{{host_ipaddress}}/${HOST_IPADDRESS}/g" "${TEMP_PATH}"/karmada-host.yaml
  sed -i'' -e 's/networking:/&\'$'\n''  apiServerAddress: "'${HOST_IPADDRESS}'"/' "${TEMP_PATH}"/member1.yaml
  sed -i'' -e 's/networking:/&\'$'\n''  apiServerAddress: "'${HOST_IPADDRESS}'"/' "${TEMP_PATH}"/member2.yaml
  util::create_cluster "${HOST_CLUSTER_NAME}" "${MAIN_KUBECONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}" "${TEMP_PATH}"/karmada-host.yaml
else
  util::create_cluster "${HOST_CLUSTER_NAME}" "${MAIN_KUBECONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}"
fi
util::create_cluster "${MEMBER_CLUSTER_1_NAME}" "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}" "${TEMP_PATH}"/member1.yaml
util::create_cluster "${MEMBER_CLUSTER_2_NAME}" "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}" "${TEMP_PATH}"/member2.yaml
util::create_cluster "${PULL_MODE_CLUSTER_NAME}" "${PULL_MODE_CLUSTER_TMP_CONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}"

#step2. make images and get karmadactl
export VERSION="latest"
export REGISTRY="docker.io/karmada"
make images GOOS="linux" --directory="${REPO_ROOT}"

GO111MODULE=on go install "github.com/karmada-io/karmada/cmd/karmadactl"
GOPATH=$(go env GOPATH | awk -F ':' '{print $1}')
KARMADACTL_BIN="${GOPATH}/bin/karmadactl"

#step3. wait until the host cluster ready
echo "Waiting for the host clusters to be ready..."
util::check_clusters_ready "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}"

#step4. load components images to kind cluster
kind load docker-image "${REGISTRY}/karmada-controller-manager:${VERSION}" --name="${HOST_CLUSTER_NAME}"
kind load docker-image "${REGISTRY}/karmada-scheduler:${VERSION}" --name="${HOST_CLUSTER_NAME}"
kind load docker-image "${REGISTRY}/karmada-descheduler:${VERSION}" --name="${HOST_CLUSTER_NAME}"
kind load docker-image "${REGISTRY}/karmada-webhook:${VERSION}" --name="${HOST_CLUSTER_NAME}"
kind load docker-image "${REGISTRY}/karmada-scheduler-estimator:${VERSION}" --name="${HOST_CLUSTER_NAME}"
kind load docker-image "${REGISTRY}/karmada-aggregated-apiserver:${VERSION}" --name="${HOST_CLUSTER_NAME}"
kind load docker-image "${REGISTRY}/karmada-search:${VERSION}" --name="${HOST_CLUSTER_NAME}"
kind load docker-image "${REGISTRY}/karmada-metrics-adapter:${VERSION}" --name="${HOST_CLUSTER_NAME}"

#step5. install karmada control plane components
"${REPO_ROOT}"/hack/deploy-karmada.sh "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}"

#step6. wait until the member cluster ready and join member clusters
util::check_clusters_ready "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"
util::check_clusters_ready "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"

# connecting networks between karmada-host, member1 and member2 clusters
echo "connecting cluster networks..."
util::add_routes "${MEMBER_CLUSTER_1_NAME}" "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"
util::add_routes "${MEMBER_CLUSTER_2_NAME}" "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"

util::add_routes "${HOST_CLUSTER_NAME}" "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"
util::add_routes "${MEMBER_CLUSTER_1_NAME}" "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}"

util::add_routes "${HOST_CLUSTER_NAME}" "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"
util::add_routes "${MEMBER_CLUSTER_2_NAME}" "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}"
echo "cluster networks connected"

#join push mode member clusters
export KUBECONFIG="${MAIN_KUBECONFIG}"
${KARMADACTL_BIN} join --karmada-context="${KARMADA_APISERVER_CLUSTER_NAME}" ${MEMBER_CLUSTER_1_NAME} --cluster-kubeconfig="${MEMBER_CLUSTER_1_TMP_CONFIG}" --cluster-context="${MEMBER_CLUSTER_1_NAME}"
"${REPO_ROOT}"/hack/deploy-scheduler-estimator.sh "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}" "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"
${KARMADACTL_BIN} join --karmada-context="${KARMADA_APISERVER_CLUSTER_NAME}" ${MEMBER_CLUSTER_2_NAME} --cluster-kubeconfig="${MEMBER_CLUSTER_2_TMP_CONFIG}" --cluster-context="${MEMBER_CLUSTER_2_NAME}"
"${REPO_ROOT}"/hack/deploy-scheduler-estimator.sh "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}" "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"

# wait until the pull mode cluster ready
util::check_clusters_ready "${PULL_MODE_CLUSTER_TMP_CONFIG}" "${PULL_MODE_CLUSTER_NAME}"
kind load docker-image "${REGISTRY}/karmada-agent:${VERSION}" --name="${PULL_MODE_CLUSTER_NAME}"

#step7. deploy karmada agent in pull mode member clusters
"${REPO_ROOT}"/hack/deploy-agent-and-estimator.sh "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}" "${MAIN_KUBECONFIG}" "${KARMADA_APISERVER_CLUSTER_NAME}" "${PULL_MODE_CLUSTER_TMP_CONFIG}" "${PULL_MODE_CLUSTER_NAME}"

#step8. deploy metrics adapter in member clusters
"${REPO_ROOT}"/hack/deploy-k8s-metrics-server.sh "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"
"${REPO_ROOT}"/hack/deploy-k8s-metrics-server.sh "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"
"${REPO_ROOT}"/hack/deploy-k8s-metrics-server.sh "${PULL_MODE_CLUSTER_TMP_CONFIG}" "${PULL_MODE_CLUSTER_NAME}"

# wait all of clusters member1, member2 and member3 status is ready
util:wait_cluster_ready "${KARMADA_APISERVER_CLUSTER_NAME}" "${MEMBER_CLUSTER_1_NAME}"
util:wait_cluster_ready "${KARMADA_APISERVER_CLUSTER_NAME}" "${MEMBER_CLUSTER_2_NAME}"
util:wait_cluster_ready "${KARMADA_APISERVER_CLUSTER_NAME}" "${PULL_MODE_CLUSTER_NAME}"

#step9. merge temporary kubeconfig of member clusters by kubectl
export KUBECONFIG=$(find ${KUBECONFIG_PATH} -maxdepth 1 -type f | grep ${MEMBER_TMP_CONFIG_PREFIX} | tr '\n' ':')
kubectl config view --flatten > ${MEMBER_CLUSTER_KUBECONFIG}
rm $(find ${KUBECONFIG_PATH} -maxdepth 1 -type f | grep ${MEMBER_TMP_CONFIG_PREFIX})

function print_success() {
  echo -e "$KARMADA_GREETING"
  echo "Local Karmada is running."
  echo -e "\nTo start using your karmada, run:"
  echo -e "  export KUBECONFIG=${MAIN_KUBECONFIG}"
  echo "Please use 'kubectl config use-context ${HOST_CLUSTER_NAME}/${KARMADA_APISERVER_CLUSTER_NAME}' to switch the host and control plane cluster."
  echo -e "\nTo manage your member clusters, run:"
  echo -e "  export KUBECONFIG=${MEMBER_CLUSTER_KUBECONFIG}"
  echo "Please use 'kubectl config use-context ${MEMBER_CLUSTER_1_NAME}/${MEMBER_CLUSTER_2_NAME}/${PULL_MODE_CLUSTER_NAME}' to switch to the different member cluster."
}

print_success
