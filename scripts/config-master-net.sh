#!/bin/bash

KUBEDEPLOY_INI_FULLPATH=$1

POD_NETWORK_CIDR=$(cat ${KUBEDEPLOY_INI_FULLPATH} |grep POD_NETWORK_CIDR | awk -F '='  '{print $2}')
SERVICE_CIDR=$(cat ${KUBEDEPLOY_INI_FULLPATH} |grep SERVICE_CIDR | awk -F '='  '{print $2}')
APISERVER_ADVERTISE_ADDRESS=$(cat ${KUBEDEPLOY_INI_FULLPATH} |grep APISERVER_ADVERTISE_ADDRESS | awk -F '='  '{print $2}')



check_ok() {
    if [ $? != 0 ]
        then
        echo "Error, Check the error log."
        exit 1
    fi
}

prepareEnv(){
echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*        begin to init os ,including: closeFirewalld ,closeFirewalld,closeSelinux,openBrigeSupport      *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"

    closeSwapoff
    closeFirewalld
    openBrigeSupport
    closeSelinux

echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*         finish init os.                                                                               *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"

}

closeSwapoff(){
  echo "step:------> closeSwapoff begin"
  swapoff -a
  echo "vm.swappiness = 0">> /etc/sysctl.conf
  sysctl -p
  echo "step:------> closeSwapoff completed."
}


closeFirewalld(){
echo "step:------> closeFirewalld begin"
    systemctl status firewalld
    systemctl stop firewalld.service
    systemctl disable firewalld.service
echo "step:------> closeFirewalld completed."
}


openBrigeSupport(){
    echo "step:------> openBrigeSupport begin"

	cat <<EOF >  /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
fs.may_detach_mounts = 1
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_watches=89100
fs.file-max=52706963
fs.nr_open=52706963
net.netfilter.nf_conntrack_max=2310720
EOF

	sysctl -p /etc/sysctl.conf
	check_ok
	sleep 1
    echo "step:------> openBrigeSupport completed."
}


closeSelinux(){
    echo "step:------> closeselinux begin"
	setenforce 0
	sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/sysconfig/selinux
	sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
	sed -i "s/^SELINUX=permissive/SELINUX=disabled/g" /etc/sysconfig/selinux
	sed -i "s/^SELINUX=permissive/SELINUX=disabled/g" /etc/selinux/config
	check_ok
	sleep 1
	echo "step:------> closeselinux completed."
}

configDocker(){
echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*        begin to config docker ,including: remove old version docker ,deploy docker-ce-18.09.5         *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"
echo "step:------> remove old docker version"
sleep 1
yum remove -y docker docker-common container-selinux docker-selinux docker-engine
check_ok
echo "step:------> remove old docker version completed."
sleep 1

echo "step:------> configDocker begin"

cd /usr/local/src/kubeedge
tar -zxf docker-18.09.5.tgz
cp docker/* /usr/local/bin

cd /usr/lib/systemd/system

cat > docker.service <<EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io

[Service]
Environment="PATH=/usr/local/bin:/bin:/sbin:/usr/bin:/usr/sbin"
EnvironmentFile=-/run/flannel/docker
ExecStart=/usr/local/bin/dockerd --log-level=error $DOCKER_NETWORK_OPTIONS
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable docker
    systemctl start docker
    check_ok
    echo "step:------> configDocker completed."
echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*         finish config docker.                                                                         *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"
}


loadDockerImgs(){
echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*            Now,We will load some images (pod-infrastructure,pasue,dns,etc..),                         *"
echo "*            And it will store docker's default datadir !                                               *"
echo "*                                                                                                       *"
echo "*            If you want to change the default docker datadir,Please do something else                  *"
echo "*            After config completed by  manually !                                                      *"
echo "*                                                                                                       *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"

echo "step:------> loading some docker images"
sleep 1
cd /usr/local/src/kubeedge
echo "step:------> unzip docker images packages"
sleep 1
tar -zxf k8s-imgs.tar.gz
check_ok
echo "step:------> unzip docker images packages completed."

  cd images
  docker load < coredns.tar
  docker load < etcd.tar
  docker load < flannel.tar
  docker load < kube-apiserver.tar
  docker load < kube-controller-manager.tar
  docker load < kube-proxy.tar
  docker load < kube-scheduler.tar
  docker load < pause.tar
  docker load < alpine.tar
  docker load < edgecontroller.tar
  docker load < nginx.tar
  docker load < traefik.tar
echo "step:------> loading some k8s images completed."
sleep 1

echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*         finish load docker images, the images list :                                                  *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"
    docker images
}

configKubelet_feiqi(){
echo "step:------> begin to config kubelet "


cat <<EOF > /usr/lib/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /usr/lib/systemd/system/kubelet.service.d/

cat <<EOF > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/sysconfig/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF

cat <<EOF > /var/lib/kubelet/kubeadm-flags.env
KUBELET_KUBEADM_ARGS=--cgroup-driver=cgroupfs --network-plugin=cni
EOF

cat <<EOF > /etc/sysconfig/kubelet
KUBELET_EXTRA_ARGS=
EOF

systemctl daemon-reload
systemctl enable kubelet && systemctl restart kubelet
systemctl status kubelet -l

echo "step:------> config kubelet completed"
}

configKubelet(){
echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*        begin to config kube-tools ,including: deploy kubelet/kubectl/kubeadm                          *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"
	cd /usr/local/src/kubeedge/
	tar -zxf rpm.tar.gz
	cd rpm
	rpm -ivh --force *
  systemctl enable kubelet.service
echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*         finish config kube-tools .                                                                    *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"
}


configMaster(){
    echo "step:------> begin to config master"
	systemctl stop kubelet
    kubeadm init --kubernetes-version=v1.14.1 --pod-network-cidr=${POD_NETWORK_CIDR} --apiserver-advertise-address=${APISERVER_ADVERTISE_ADDRESS}
    check_ok
}

configClusterAfter(){
  mkdir -p $HOME/.kube
  cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
}

configClusterNetwork(){
	echo "step:------> begin to config cluster network"
	kubectl create -f /usr/local/src/kubeedge/kube-flannel.yaml
	echo "step:------> cluster network config completed!"
  echo "step:------> config master completed!"
  echo "*********************************************************************************************************"
  echo "*   NOTE:                                                                                               *"
  echo "*   Then you can join any number of worker nodes by running the following on each as root:              *"
  echo "*   kubeadm join $(cat ${KUBEDEPLOY_INI_FULLPATH} |grep APISERVER_ADVERTISE_ADDRESS | awk -F '='  '{print $2}'):6443 --token $(kubeadm token list |grep authentication| awk '{print $1}')  \                                *"
  echo '--discovery-token-ca-cert-hash sha256:'$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')'  *'
  echo "*                                                                                                       *"
  echo "*********************************************************************************************************"
}

copyKubeTools(){
  echo "*********************************************************************************************************"
  echo "*   NOTE:                                                                                               *"
  echo "*        Please wait ,It's time to unzip install packages                                               *"
  echo "*                                                                                                       *"
  echo "*********************************************************************************************************"
  cd /usr/local/src
	rm -rf kubeedge
  tar -zxf kubeedge.tar.gz
	if [  -f "/usr/bin/kubelet" ];then
		rm -rf /usr/bin/kubelet
	fi

	if [  -f "/usr/bin/kubectl" ];then
		rm -rf /usr/bin/kubectl
	fi

	if [  -f "/usr/bin/kubeadm" ];then
		rm -rf /usr/bin/kubeadm
	fi
  cp /usr/local/src/kubeedge/kubelet /usr/bin/
  cp /usr/local/src/kubeedge/kubectl /usr/bin/
  cp /usr/local/src/kubeedge/kubeadm /usr/bin/

  echo "*********************************************************************************************************"
  echo "*   NOTE:                                                                                               *"
  echo "*        install packages unzip completed!                                                              *"
  echo "*                                                                                                       *"
  echo "*********************************************************************************************************"
}

checkHostsAndKubeiniConfig(){
  echo "*********************************************************************************************************"
  echo "*   NOTE:                                                                                               *"
  echo "*        Your /etc/hosts and apiserver-address(kubeedge.ini) as shown below :                           *"
  echo "*                                                                                                       *"
  echo "*********************************************************************************************************"
  cat /etc/hosts
  echo "---------------------------------------------------------------------------------------------------------"
  echo ${APISERVER_ADVERTISE_ADDRESS}
  echo "*********************************************************************************************************"
  echo "*   NOTE:                                                                                               *"
  echo "*       Please make sure your config is right !                                                         *"
  echo "*                                                                                                       *"
  echo "*********************************************************************************************************"
  echo "Are you sure?  (y/n):"
  read answer
  if [ "${answer}" = "yes" -o "${answer}" = "y" ];then
  	copyKubeTools
    prepareEnv
    configDocker
    loadDockerImgs
    configKubelet
    configMaster
    configClusterAfter
    configClusterNetwork
  else
  	echo "*********************************************************************************************************"
  	echo "*                  OK ,You can config /etc/hosts and kubeedge.ini at first!                             *"
  	echo "*********************************************************************************************************"
  	exit 1
  fi
}

checkHostsAndKubeiniConfig
