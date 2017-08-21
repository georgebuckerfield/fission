#!/bin/bash

#
# Test runner. Shell scripts that build fission CLI and server, push a
# docker image to GCR, deploy it on a cluster, and run tests against
# that deployment.
#

set -euo pipefail

ROOT=$(dirname $0)/..

helm_setup() {
    helm init
}

gcloud_login() {
    KEY=${HOME}/gcloud-service-key.json
    if [ ! -f $KEY ]
    then
	echo $FISSION_CI_SERVICE_ACCOUNT | base64 -d - > $KEY
    fi
    
    gcloud auth activate-service-account --key-file $KEY
}

build_and_push_fission_bundle() {
    image_tag=$1

    pushd $ROOT/fission-bundle
    ./build.sh
    docker build -t $image_tag .

    gcloud_login
    
    gcloud docker -- push $image_tag
    popd
}

build_fission_cli() {
    pushd $ROOT/fission
    go build .
    popd
}

generate_test_id() {
    echo $(date|md5sum|cut -c1-6)
}

helm_install_fission() {
    id=$1
    image=$2
    imageTag=$3
    controllerNodeport=$4
    routerNodeport=$5

    ns=f-$id
    fns=f-func-$id

    helmVars=image=$image,imageTag=$imageTag,functionNamespace=$fns,controllerPort=$controllerNodeport,routerPort=$routerNodeport,pullPolicy=alwaysPull

    helm_setup
    
    echo "Installing fission"
    helm install		\
	 --wait			\
	 --name $id		\
	 --set $helmVars	\
	 --namespace $ns        \
	 $ROOT/charts/fission-all
}

wait_for_service() {
    id=$1
    svc=$2

    ns=f-$id
    while true
    do
	ip=$(kubectl -n $ns get svc $svc -o jsonpath='{...ip}')
	if [ ! -z $ip ]
	then
	    break
	fi
	echo Waiting for service $svc...
	sleep 1
    done
}

wait_for_services() {
    id=$1

    wait_for_service $id controller
    wait_for_service $id router
}

helm_uninstall_fission() {
    if [ ! -z ${FISSION_TEST_SKIP_DELETE:+} ]
    then
	echo "Fission uninstallation skipped"
	return
    fi
    echo "Uninstalling fission"
    helm delete --purge $1
}

set_environment() {
    id=$1
    ns=f-$id

    export FISSION_URL=http://$(kubectl -n $ns get svc controller -o jsonpath='{...ip}')
    export FISSION_ROUTER=$(kubectl -n $ns get svc router -o jsonpath='{...ip}')

    # set path to include cli
    export PATH=$ROOT/fission:$PATH
}

dump_logs() {
    id=$1

    ns=f-$id
    fns=f-func-$id

    echo --- router logs ---
    kubectl -n $ns get pod -o name  | grep router | xargs kubectl -n $ns logs 
    echo --- end router logs ---

    echo --- poolmgr logs ---
    kubectl -n $ns get pod -o name  | grep poolmgr | xargs kubectl -n $ns logs 
    echo --- end poolmgr logs ---

    functionPods=$(kubectl -n $fns get pod -o name -l functionName)
    for p in $functionPods
    do
	echo "--- function pod logs $p ---"
	containers=$(kubectl -n $fns get pod $p -o jsonpath={.spec.containers[*].name})
	for c in $containers
	do
	    echo "--- function pod logs $p: container $c ---"
	    kubectl -n $fns logs $p $c
	    echo "--- end function pod logs $p: container $c ---"
	done
	echo "--- end function pod logs $p ---"
    done
}

run_all_tests() {
    id=$1

    export FISSION_NAMESPACE=f-$id
    export FUNCTION_NAMESPACE=f-func-$id
        
    failures=0
    for file in $ROOT/test/tests/test_*.sh
    do
	echo ------- Running $file -------
	e=$file
	if [ ! $e ]
	then
	    echo FAILED: $file
	    failures=$(($failures+1))
	fi
    done

    if [ $failures -ne 0 ]
    then
	exit 1
    fi
}

install_and_test() {
    image=$1
    imageTag=$2

    controllerPort=31234
    routerPort=31235

    id=$(generate_test_id)
    trap "helm_uninstall_fission $id" EXIT
    helm_install_fission $id $image $imageTag $controllerPort $routerPort

    wait_for_services $id
    set_environment $id

    if run_all_tests $id
    then
	success=0
    else
	success=1
    fi

    dump_logs $id

    if [ ! $success ]
    then
	exit 1
    fi
}


# if [ $# -lt 2 ]
# then
#     echo "Usage: test.sh [image] [imageTag]"
#     exit 1
# fi
# install_and_test $1 $2