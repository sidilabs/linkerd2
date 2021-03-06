#!/usr/bin/env bash

# Override CI's `set -e` default, so we can catch errors manually and display
# proper messages
set +e

##### Test setup helpers #####

export default_test_names=(deep external-issuer helm-deep helm-upgrade multicluster uninstall upgrade-edge upgrade-stable cni-calico-deep)
export all_test_names=(cluster-domain "${default_test_names[*]}")

handle_input() {
  export images=''
  export test_name=''
  export skip_cluster_create=''

  while :
  do
    case $1 in
      -h|--help)
        echo "Run Linkerd integration tests.

Optionally specify a test with the --name flag: [${all_test_names[*]}]

Note: The cluster-domain test requires a cluster configuration with a custom cluster domain (see test/configs/cluster-domain.yaml)

Usage:
    ${0##*/} [--images] [--name test-name] [--skip-cluster-create] /path/to/linkerd

Examples:
    # Run all tests in isolated clusters
    ${0##*/} /path/to/linkerd

    # Run single test in isolated clusters
    ${0##*/} --name test-name /path/to/linkerd

    # Skip KinD/k3d cluster creation and run all tests in default cluster context
    ${0##*/} --skip-cluster-create /path/to/linkerd

    # Load images from tar files located under the 'image-archives' directory
    # Note: This is primarily for CI
    ${0##*/} --images /path/to/linkerd

Available Commands:
    --name: the argument to this option is the specific test to run
    --skip-cluster-create: skip KinD/k3d cluster creation step and run tests in an existing cluster.
    --images: (Primarily for CI) load the images from local .tar files in the current directory."
        exit 0
        ;;
      --images)
        images=1
        ;;
      --name)
        test_name=$2
        if [ -z "$test_name" ]; then
          echo 'Error: the argument for --name was not specified'
          exit 1
        fi
        shift
        ;;
      --skip-cluster-create)
        skip_cluster_create=1
        ;;
      *)
        break
    esac
    shift
  done

  export linkerd_path="$1"
  if [ -z "$linkerd_path" ]; then
    echo "Error: path to linkerd binary is required
Help:
     ${0##*/} -h|--help
Basic usage:
     ${0##*/} /path/to/linkerd"
    exit 64
  fi
}

test_setup() {
  bindir=$( cd "${BASH_SOURCE[0]%/*}" && pwd )
  export bindir

  export test_directory="$bindir"/../test/integration

  check_linkerd_binary
}

check_linkerd_binary() {
  printf 'Checking the linkerd binary...'
  if [[ "$linkerd_path" != /* ]]; then
    printf '\n[%s] is not an absolute path\n' "$linkerd_path"
    exit 1
  fi
  if [ ! -x "$linkerd_path" ]; then
    printf '\n[%s] does not exist or is not executable\n' "$linkerd_path"
    exit 1
  fi
  exit_code=0
  "$linkerd_path" version --client > /dev/null 2>&1
  exit_on_err 'error running linkerd version command'
  printf '[ok]\n'
}

##### Cluster helpers #####

create_kind_cluster() {
  local name=$1
  local config=$2
  "$bindir"/kind create cluster --name "$name" --config "$test_directory"/configs/"$config".yaml --wait 300s 2>&1
  exit_on_err 'error creating KinD cluster'
  export context="kind-$name"
}

create_k3d_cluster() {
  local name=$1
  local network=$2
  "$bindir"/k3d cluster create "$name" --wait --network "$network"
}

check_cluster() {
  check_if_k8s_reachable
  check_if_l5d_exists
}

delete_kind_cluster() {
  local name=$1
  "$bindir"/kind delete cluster --name "$name" 2>&1
  exit_on_err 'error deleting cluster'
}

delete_k3d_cluster() {
  local name=$1
  "$bindir"/k3d cluster delete "$name"
  exit_on_err 'error deleting cluster'
}

cleanup_cluster() {
  "$bindir"/test-cleanup "$context" > /dev/null 2>&1
  exit_on_err 'error removing existing Linkerd resources'
}

check_if_k8s_reachable() {
  printf 'Checking if there is a Kubernetes cluster available...'
  exit_code=0
  kubectl --context="$context" --request-timeout=5s get ns > /dev/null 2>&1
  exit_on_err 'error connecting to Kubernetes cluster'
  printf '[ok]\n'
}

check_if_l5d_exists() {
  printf 'Checking if Linkerd resources exist on cluster...'
  local resources
  resources=$(kubectl --context="$context" get all,clusterrole,clusterrolebinding,mutatingwebhookconfigurations,validatingwebhookconfigurations,psp,crd -l linkerd.io/control-plane-ns --all-namespaces -oname)
  if [ -n "$resources" ]; then
    printf '
Linkerd resources exist on cluster:
\n%s\n
Help:
    Run: [%s/test-cleanup]' "$resources" "$bindir"
    exit 1
  fi
  printf '[ok]\n'
}

##### Test runner helpers #####

start_test() {
  if [ "$1" == multicluster ]; then
    start_k3d_test
  else
    start_kind_test "$@"
  fi
}

start_kind_test() {
  name=$1
  config=$2
  export helm_path="$bindir"/helm 

  test_setup
  if [ -z "$skip_cluster_create" ]; then
    create_kind_cluster "$name" "$config"
    "$bindir"/image-load --kind ${images:+'--images'} "$name"
    exit_on_err "error calling '$bindir/image-load'"
  fi
  check_cluster
  run_"$name"_test
  exit_on_err "error calling 'run_${name}_test'"

  if [ -z "$skip_cluster_create" ]; then
    delete_kind_cluster "$name"
  else
    cleanup_cluster
  fi
}

start_k3d_test() {
  test_setup
  if [ -z "$skip_cluster_create" ]; then
    create_k3d_cluster source multicluster-test
    "$bindir"/image-load --k3d ${images:+'--images'} source
    create_k3d_cluster target multicluster-test
    "$bindir"/image-load --k3d ${images:+'--images'} target
  fi
  export context="k3d-source"
  check_cluster
  export context="k3d-target"
  check_cluster

  run_multicluster_test
  exit_on_err "error calling 'run_multicluster_test'"

  if [ -z "$skip_cluster_create" ]; then
    delete_k3d_cluster source
    delete_k3d_cluster target
  else
    export context="k3d-source"
    cleanup_cluster
    export context="k3d-target"
    cleanup_cluster
  fi
}

multicluster_link() {
  lbIP=$(kubectl --context="$context" get svc -n kube-system traefik -o 'go-template={{ (index .status.loadBalancer.ingress 0).ip }}')
  "$linkerd_path" multicluster link --api-server-address "https://${lbIP}:6443" --cluster-name "$1"
}

get_test_config() {
  local name=$1
  config=''
  case $name in
    cluster-domain)
      config='cluster-domain'
      ;;
    cni-calico-deep)
      config='cni-calico'
      ;;
    *)
      config='default'
      ;;
  esac
  echo "$config"
}

run_test(){
  local filename=$1
  shift

  printf 'Test script: [%s] Params: [%s]\n' "${filename##*/}" "$*"
  # Exit on failure here
  GO111MODULE=on go test --failfast --mod=readonly "$filename" --linkerd="$linkerd_path" --helm-path="$helm_path" --k8s-context="$context" --integration-tests "$@" || exit 1
}

# Returns the latest version for the release channel
# $1: release channel to check
latest_release_channel() {
    curl -s https://versioncheck.linkerd.io/version.json | grep -o "$1-[0-9]*.[0-9]*.[0-9]*"
}

# Install a specific Linkerd version.
# $1 - URL to use to download specific Linkerd version
# $2 - Linkerd version
install_version() {
    tmp=$(mktemp -d -t l5dbin.XXX)

    local install_url=$1
    local version=$2

    curl -s "$install_url" | HOME=$tmp sh > /dev/null 2>&1

    local linkerd_path=$tmp/.linkerd2/bin/linkerd
    local test_app_namespace=upgrade-test

    (
        set -x
        "$linkerd_path" install | kubectl --context="$context" apply -f - 2>&1
    )
    exit_on_err "install_version() - installing $version failed"

    (
        set -x
        "$linkerd_path" check 2>&1
    )
    exit_on_err 'install_version() - linkerd check failed'

    #Now we need to install the app that will be used to verify that upgrade does not break anything
    kubectl --context="$context" create namespace "$test_app_namespace" > /dev/null 2>&1
    kubectl --context="$context" label namespaces "$test_app_namespace" 'linkerd.io/is-test-data-plane'='true' > /dev/null 2>&1
    (
        set -x
        "$linkerd_path" inject "$test_directory/testdata/upgrade_test.yaml" | kubectl --context="$context" apply --namespace="$test_app_namespace" -f - 2>&1
    )
    exit_on_err 'install_version() - linkerd inject failed'
}

upgrade_test() {
  local release_channel=$1
  local install_url=$2

  local upgrade_version
  upgrade_version=$(latest_release_channel "$release_channel")

  if [ -z "$upgrade_version" ]; then
    echo 'error getting upgrade_version'
    exit 1
  fi

  install_version "$install_url" "$upgrade_version"
  run_test "$test_directory/install_test.go" --upgrade-from-version="$upgrade_version"
}

# Run the upgrade-edge test by upgrading the most-recent edge release to the
# HEAD of this branch.
run_upgrade-edge_test() {
  edge_install_url="https://run.linkerd.io/install-edge"
  upgrade_test "edge" "$edge_install_url"
}

# Run the upgrade-stable test by upgrading the most-recent stable release to the
# HEAD of this branch.
run_upgrade-stable_test() {
  if [ -n "$RUN_ARM_TEST" ]; then
    echo "Skipped. Linkerd stable version does not support ARM yet"
    exit 0
  fi

  stable_install_url="https://run.linkerd.io/install"
  upgrade_test "stable" "$stable_install_url"
}

setup_helm() {
  export helm_path="$bindir"/helm
  helm_chart="$( cd "$bindir"/.. && pwd )"/charts/linkerd2
  export helm_chart
  export helm_release_name='helm-test'
  export helm_multicluster_release_name="multicluster-test"
  "$bindir"/helm-build
  "$helm_path" --kube-context="$context" repo add linkerd https://helm.linkerd.io/stable
  exit_on_err 'error setting up Helm'
}

helm_cleanup() {
  (
    set -e
    "$helm_path" --kube-context="$context" delete "$helm_release_name"
    # `helm delete` doesn't wait for resources to be deleted, so we wait explicitly.
    # We wait for the namespace to be gone so the following call to `cleanup` doesn't fail when it attempts to delete
    # the same namespace that is already being deleted here (error thrown by the NamespaceLifecycle controller).
    # We don't have that problem with global resources, so no need to wait for them to be gone.
    kubectl wait --for=delete ns/linkerd --timeout=120s
  )
  exit_on_err 'error cleaning up Helm'
}

run_helm-upgrade_test() {
  if [ -n "$RUN_ARM_TEST" ]; then
    echo "Skipped. Linkerd stable version does not support ARM yet"
    exit 0
  fi

  local stable_version
  stable_version=$(latest_release_channel "stable")

  if [ -z "$stable_version" ]; then
    echo 'error getting stable_version'
    exit 1
  fi

  setup_helm
  run_test "$test_directory/install_test.go" --helm-path="$helm_path" --helm-chart="$helm_chart" \
  --helm-stable-chart='linkerd/linkerd2' --helm-release="$helm_release_name" --upgrade-helm-from-version="$stable_version"
  helm_cleanup
}

run_uninstall_test() {
  run_test "$test_directory/uninstall/uninstall_test.go" --uninstall=true
}

run_multicluster_test() {
  tmp=$(mktemp -d -t l5dcerts.XXX)
  pwd=$PWD
  cd "$tmp"
  "$bindir"/certs-openssl
  cd "$pwd"
  export context="k3d-target"
  run_test "$test_directory/install_test.go" --multicluster --certs-path "$tmp"
  run_test "$test_directory/multicluster/target1" --multicluster
  link=$(multicluster_link target)

  export context="k3d-source"
  run_test "$test_directory/install_test.go" --multicluster --certs-path "$tmp"
  echo "$link" | kubectl --context="$context" apply -f -
  run_test "$test_directory/multicluster/source" --multicluster

  export context="k3d-target"
  run_test "$test_directory/multicluster/target2" --multicluster
}

run_deep_test() {
  local tests=()
  run_test "$test_directory/install_test.go"
  while IFS= read -r line; do tests+=("$line"); done <<< "$(go list "$test_directory"/.../...)"
  for test in "${tests[@]}"; do
    run_test "$test"
  done
}

run_cni-calico-deep_test() {
  local tests=()
  run_test "$test_directory/install_test.go" --cni --calico
  while IFS= read -r line; do tests+=("$line"); done <<< "$(go list "$test_directory"/.../...)"
  for test in "${tests[@]}"; do
    run_test "$test" --cni
  done
}

run_helm-deep_test() {
  local tests=()
  setup_helm
  helm_multicluster_chart="$( cd "$bindir"/.. && pwd )"/charts/linkerd2-multicluster
  run_test "$test_directory/install_test.go" --helm-path="$helm_path" --helm-chart="$helm_chart" \
  --helm-release="$helm_release_name" --multicluster-helm-chart="$helm_multicluster_chart" \
  --multicluster-helm-release="$helm_multicluster_release_name"
  while IFS= read -r line; do tests+=("$line"); done <<< "$(go list "$test_directory"/.../...)"
  for test in "${tests[@]}"; do
    run_test "$test"
  done
  helm_cleanup
}

run_external-issuer_test() {
  run_test "$test_directory/install_test.go" --external-issuer=true
  run_test "$test_directory/externalissuer/external_issuer_test.go" --external-issuer=true
}

run_cluster-domain_test() {
  run_test "$test_directory/install_test.go" --cluster-domain='custom.domain'
}

# exit_on_err should be called right after a command to check the result status
# and eventually generate a Github error annotation. Do not use after calls to
# `go test` as that generates its own annotations. Note this should be called
# outside subshells in order for the script to terminate.
exit_on_err() {
  exit_code=$?
  if [ $exit_code -ne 0 ]; then
    export GH_ANNOTATION=${GH_ANNOTATION:-}
    if [ -n "$GH_ANNOTATION" ]; then
      printf '::error::%s\n' "$1"
    else
      printf '\n=== FAIL: %s\n' "$1"
    fi
    exit $exit_code
  fi
}
