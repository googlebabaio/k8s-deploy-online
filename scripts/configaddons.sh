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
cd $ROOTDIR
curl -L https://git.io/getLatestIstio | ISTIO_VERSION=1.2.6 sh -
export PATH="$PATH:/root/istio-1.2.6/bin"
istioctl verify-install
cd istio-1.2.6/
for i in install/kubernetes/helm/istio-init/files/crd*yaml;
  do kubectl apply -f $i;
done
kubectl apply -f install/kubernetes/istio-demo.yaml
kubectl patch service istio-ingressgateway  -p '{"spec":{"type":"NodePort"}}' -n istio-system
kubectl get pod,svc -n istio-system
}

installPromethus(){
cd $ROOTDIR
}

case $1 in
1)
  instanllHelm
	;;
2)
  installIstio
	;;
*)
	echo "Error! laozi ling luan le!"
	exit 1
	;;
esac
