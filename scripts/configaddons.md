#!/bin/bash

ROOTDIR=/softdb

check_ok() {
    if [ $? != 0 ]
        then
        echo "Error, Check the error log."
        exit 1
    fi
}


instanllHelm(){
curl -Lo /tmp/helm-linux-amd64.tar.gz https://storage.googleapis.com/kubernetes-helm/helm-v2.14.3-linux-amd64.tar.gz
tar zxf /tmp/helm-linux-amd64.tar.gz -C /tmp/

chmod a+x /tmp/linux-amd64/helm
mv /tmp/linux-amd64/helm /usr/local/bin

kubectl create -f $ROOTDIR/k8s-deploy/addons/helm/helm-account.yaml
helm init --service-account tiller
helm repo update
kubectl get pod -n kube-system
}


installIstio(){

}
