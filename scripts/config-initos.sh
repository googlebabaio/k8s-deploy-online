#!/bin/bash
KUBEDEPLOY_INI_FULLPATH=$2
KUBERNETES_VERSION=$(cat ${KUBEDEPLOY_INI_FULLPATH} |grep KUBERNETES_VERSION | awk -F '='  '{print $2}')

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
yum remove docker docker-common container-selinux docker-selinux docker-engine
check_ok
echo "step:------> remove old docker version completed."
sleep 1

echo "step:------> configDocker begin"

cd /etc/yum.repos.d/
wget  https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
yum install docker-ce -y

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

configKubeTools(){
echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*        begin to config kube-tools ,including: deploy kubelet/kubectl/kubeadm                          *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"

cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

yum install -y kubelet-${KUBERNETES_VERSION} kubeadm-${KUBERNETES_VERSION} kubectl-${KUBERNETES_VERSION} --disableexcludes=kubernetes

systemctl enable --now kubelet

systemctl daemon-reload
systemctl restart kubelet

yum install -y bash-completion
source /usr/share/bash-completion/bash_completion
#source <(kubectl completion bash)

echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*         finish config kube-tools .                                                                    *"
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


case $1 in
2)
	#copyKubeTools
	prepareEnv
	configDocker
	#loadDockerImgs
	configKubeTools
	;;
3)
	prepareEnv
	configKubeTool
	;;
4)
	prepareEnv
	configDocker
	;;
5)
	#configKubeTools
	#prepareEnv
	#loadDockerImgs
	;;
6)
	#copyKubeTools
	prepareEnv
	configDocker
	#loadDockerImgs
	;;
*)
	echo "Error! laozi ling luan le!"
	exit 1
	;;
esac
