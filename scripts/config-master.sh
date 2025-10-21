#!/bin/bash

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo "Error: 此脚本需要root权限运行"
    exit 1
fi

KUBEDEPLOY_INI_FULLPATH=$1

POD_NETWORK_CIDR=$(cat ${KUBEDEPLOY_INI_FULLPATH} |grep POD_NETWORK_CIDR | awk -F '='  '{print $2}')
SERVICE_CIDR=$(cat ${KUBEDEPLOY_INI_FULLPATH} |grep SERVICE_CIDR | awk -F '='  '{print $2}')
APISERVER_ADVERTISE_ADDRESS=$(cat ${KUBEDEPLOY_INI_FULLPATH} |grep APISERVER_ADVERTISE_ADDRESS | awk -F '='  '{print $2}')
KUBERNETES_VERSION=$(cat ${KUBEDEPLOY_INI_FULLPATH} |grep KUBERNETES_VERSION | awk -F '='  '{print $2}')

# 提取大版本号用于仓库URL
KUBERNETES_MAJOR_VERSION=$(echo $KUBERNETES_VERSION | cut -d'.' -f1-2)


check_ok() {
    local exit_code=$?
    local step_name=${1:-"操作"}
    
    if [ $exit_code != 0 ]; then
        echo "Error: ${step_name} 失败，退出码: $exit_code"
        echo "请检查错误日志并重试"
        exit 1
    else
        echo "Success: ${step_name} 完成"
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
    openBridgeSupport
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


openBridgeSupport(){
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
	check_ok "配置网络桥接支持"
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
	check_ok "关闭SELinux"
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
check_ok "卸载旧版本Docker"
echo "step:------> remove old docker version completed."
sleep 1

echo "step:------> configDocker begin"

cd /etc/yum.repos.d/
wget  https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
yum -y install -y docker-ce-19.03.9 docker-ce-cli-19.03.9 containerd.io

# 配置Docker daemon
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "registry-mirrors": [
    "https://registry.aliyuncs.com"
  ]
}
EOF

systemctl daemon-reload
systemctl enable docker
systemctl start docker
check_ok "配置Docker"
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

configKubeTools(){
echo "*********************************************************************************************************"
echo "*   NOTE:                                                                                               *"
echo "*        begin to config kube-tools ,including: deploy kubelet/kubectl/kubeadm                          *"
echo "*                                                                                                       *"
echo "*********************************************************************************************************"

# 删除旧的Kubernetes仓库配置
rm -f /etc/yum.repos.d/kubernetes.repo

cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${KUBERNETES_MAJOR_VERSION}/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=
EOF

# 彻底清理yum缓存
yum clean all
rm -rf /var/cache/yum/*
yum makecache

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

configKubetools_tmp(){
 curl -LO https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl
 chmod +x kubectl
 mv kubectl /usr/bin/kubectl
 kubectl version --client
}


configMaster(){
    echo "step:------> begin to config master"
	  systemctl stop kubelet
    kubeadm init --image-repository registry.aliyuncs.com/google_containers --kubernetes-version=v${KUBERNETES_VERSION} --pod-network-cidr=${POD_NETWORK_CIDR} --apiserver-advertise-address=${APISERVER_ADVERTISE_ADDRESS} --service-cidr=${SERVICE_CIDR}
    check_ok "初始化Master节点"
}

configClusterAfter(){
  mkdir -p $HOME/.kube
  cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
}

configClusterNetwork_calico(){
	echo "step:------> begin to config cluster network"
	kubectl apply -f https://docs.projectcalico.org/v3.19/manifests/calico.yaml
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
    #loadDockerImgs
    configKubeTools
    configMaster
    configClusterAfter
    configClusterNetwork_calico
  else
  	echo "*********************************************************************************************************"
  	echo "*                  OK ,You can config /etc/hosts and kubeedge.ini at first!                             *"
  	echo "*********************************************************************************************************"
  	exit 1
  fi
}

checkHostsAndKubeiniConfig
