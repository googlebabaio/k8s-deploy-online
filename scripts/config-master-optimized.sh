#!/bin/bash

# Kubernetes Master节点配置脚本 - 优化版本
# 作者: 优化版本
# 日期: $(date +%Y-%m-%d)

set -euo pipefail  # 严格模式：遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 改进的错误处理函数
check_ok() {
    local exit_code=$?
    local step_name=${1:-"操作"}
    
    if [ $exit_code != 0 ]; then
        log_error "${step_name}失败，退出码: $exit_code"
        log_error "请检查错误日志并重试"
        exit 1
    else
        log_success "${step_name}完成"
    fi
}

# 备份配置文件
backup_config() {
    local config_file=$1
    local backup_dir="/root/k8s-backup-$(date +%Y%m%d-%H%M%S)"
    
    if [[ -f "$config_file" ]]; then
        mkdir -p "$backup_dir"
        cp "$config_file" "$backup_dir/"
        log_info "已备份 $config_file 到 $backup_dir"
    fi
}

# 验证配置文件
validate_config() {
    local config_file=$1
    
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在: $config_file"
        exit 1
    fi
    
    # 检查必需的配置项
    local required_vars=("POD_NETWORK_CIDR" "SERVICE_CIDR" "APISERVER_ADVERTISE_ADDRESS" "KUBERNETES_VERSION")
    
    for var in "${required_vars[@]}"; do
        if ! grep -q "^${var}=" "$config_file"; then
            log_error "配置文件缺少必需的配置项: $var"
            exit 1
        fi
    done
    
    log_success "配置文件验证通过"
}

# 读取配置
read_config() {
    local config_file=$1
    
    POD_NETWORK_CIDR=$(grep "^POD_NETWORK_CIDR=" "$config_file" | cut -d'=' -f2 | tr -d ' ')
    SERVICE_CIDR=$(grep "^SERVICE_CIDR=" "$config_file" | cut -d'=' -f2 | tr -d ' ')
    APISERVER_ADVERTISE_ADDRESS=$(grep "^APISERVER_ADVERTISE_ADDRESS=" "$config_file" | cut -d'=' -f2 | tr -d ' ')
    KUBERNETES_VERSION=$(grep "^KUBERNETES_VERSION=" "$config_file" | cut -d'=' -f2 | tr -d ' ')
    DOCKER_VERSION=$(grep "^DOCKER_VERSION=" "$config_file" | cut -d'=' -f2 | tr -d ' ' || echo "19.03.9")
    
    # 提取大版本号用于仓库URL
    KUBERNETES_MAJOR_VERSION=$(echo $KUBERNETES_VERSION | cut -d'.' -f1-2)
    
    log_info "配置读取完成:"
    log_info "  POD_NETWORK_CIDR: $POD_NETWORK_CIDR"
    log_info "  SERVICE_CIDR: $SERVICE_CIDR"
    log_info "  APISERVER_ADVERTISE_ADDRESS: $APISERVER_ADVERTISE_ADDRESS"
    log_info "  KUBERNETES_VERSION: $KUBERNETES_VERSION (完整版本)"
    log_info "  KUBERNETES_MAJOR_VERSION: $KUBERNETES_MAJOR_VERSION (大版本，用于仓库)"
    log_info "  DOCKER_VERSION: $DOCKER_VERSION"
}

# 关闭swap
close_swap() {
    log_info "开始关闭swap..."
    
    swapoff -a
    sed -i '/swap/d' /etc/fstab
    echo "vm.swappiness = 0" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    
    check_ok "关闭swap"
}

# 关闭防火墙
close_firewall() {
    log_info "开始关闭防火墙..."
    
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    
    # 检查iptables
    if command -v iptables >/dev/null 2>&1; then
        iptables -F
        iptables -t nat -F
        iptables -t mangle -F
        iptables -X
    fi
    
    check_ok "关闭防火墙"
}

# 配置网络桥接支持
configure_bridge() {
    log_info "开始配置网络桥接支持..."
    
    # 备份原配置
    backup_config /etc/sysctl.conf
    
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
fs.may_detach_mounts = 1
vm.overcommit_memory = 1
vm.panic_on_oom = 0
fs.inotify.max_user_watches = 89100
fs.file-max = 52706963
fs.nr_open = 52706963
net.netfilter.nf_conntrack_max = 2310720
EOF
    
    sysctl --system > /dev/null
    check_ok "配置网络桥接支持"
}

# 关闭SELinux
disable_selinux() {
    log_info "开始关闭SELinux..."
    
    setenforce 0 2>/dev/null || true
    
    # 备份配置文件
    backup_config /etc/selinux/config
    backup_config /etc/sysconfig/selinux
    
    # 修改配置文件
    for config_file in /etc/selinux/config /etc/sysconfig/selinux; do
        if [[ -f "$config_file" ]]; then
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' "$config_file"
            sed -i 's/^SELINUX=permissive/SELINUX=disabled/g' "$config_file"
        fi
    done
    
    check_ok "关闭SELinux"
}

# 配置Docker
configure_docker() {
    log_info "开始配置Docker..."
    
    # 卸载旧版本Docker
    log_info "卸载旧版本Docker..."
    yum remove -y docker docker-common container-selinux docker-selinux docker-engine 2>/dev/null || true
    
    # 安装Docker仓库
    log_info "配置Docker仓库..."
    cd /etc/yum.repos.d/
    wget -q https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    
    # 安装指定版本的Docker
    log_info "安装Docker CE $DOCKER_VERSION..."
    yum install -y docker-ce-${DOCKER_VERSION} docker-ce-cli-${DOCKER_VERSION} containerd.io
    
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
    
    # 启动Docker服务
    systemctl daemon-reload
    systemctl enable docker
    systemctl start docker
    
    # 验证Docker安装
    docker version > /dev/null
    check_ok "配置Docker"
}

# 加载Docker镜像
load_docker_images() {
    log_info "开始加载Docker镜像..."
    
    local images_dir="/usr/local/src/kubeedge/images"
    
    if [[ ! -d "$images_dir" ]]; then
        log_warning "镜像目录不存在: $images_dir，跳过镜像加载"
        return 0
    fi
    
    cd "$images_dir"
    
    # 定义镜像列表
    local images=(
        "coredns.tar"
        "etcd.tar"
        "flannel.tar"
        "kube-apiserver.tar"
        "kube-controller-manager.tar"
        "kube-proxy.tar"
        "kube-scheduler.tar"
        "pause.tar"
        "alpine.tar"
        "edgecontroller.tar"
        "nginx.tar"
        "traefik.tar"
    )
    
    for image in "${images[@]}"; do
        if [[ -f "$image" ]]; then
            log_info "加载镜像: $image"
            docker load < "$image" > /dev/null
        else
            log_warning "镜像文件不存在: $image"
        fi
    done
    
    check_ok "加载Docker镜像"
}

# 配置Kubernetes工具
configure_kube_tools() {
    log_info "开始配置Kubernetes工具..."
    
    # 配置Kubernetes仓库
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${KUBERNETES_MAJOR_VERSION}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${KUBERNETES_MAJOR_VERSION}/rpm/RPM-GPG-KEY-kubernetes
EOF
    
    # 安装Kubernetes工具
    log_info "安装Kubernetes工具..."
    yum install -y kubelet-${KUBERNETES_VERSION} kubeadm-${KUBERNETES_VERSION} kubectl-${KUBERNETES_VERSION} --disableexcludes=kubernetes
    
    # 启用kubelet
    systemctl enable kubelet
    
    # 安装bash-completion
    yum install -y bash-completion
    source /usr/share/bash-completion/bash_completion
    
    check_ok "配置Kubernetes工具"
}

# 初始化Master节点
init_master() {
    log_info "开始初始化Master节点..."
    
    # 停止kubelet服务
    systemctl stop kubelet 2>/dev/null || true
    
    # 初始化集群
    log_info "执行kubeadm init..."
    kubeadm init \
        --image-repository registry.aliyuncs.com/google_containers \
        --kubernetes-version=v${KUBERNETES_VERSION} \
        --pod-network-cidr=${POD_NETWORK_CIDR} \
        --apiserver-advertise-address=${APISERVER_ADVERTISE_ADDRESS} \
        --service-cidr=${SERVICE_CIDR}
    
    check_ok "初始化Master节点"
}

# 配置集群访问
configure_cluster_access() {
    log_info "开始配置集群访问..."
    
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    
    check_ok "配置集群访问"
}

# 配置网络插件
configure_network() {
    log_info "开始配置网络插件..."
    
    # 使用Calico作为网络插件
    kubectl apply -f https://docs.projectcalico.org/v3.19/manifests/calico.yaml
    
    # 等待网络插件就绪
    log_info "等待网络插件就绪..."
    kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s
    
    check_ok "配置网络插件"
}

# 显示加入命令
show_join_command() {
    log_info "生成节点加入命令..."
    
    local token=$(kubeadm token list | grep authentication | awk '{print $1}')
    local ca_hash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    
    echo "*********************************************************************************************************"
    echo "*   Master节点配置完成！                                                                                *"
    echo "*                                                                                                       *"
    echo "*   要加入工作节点，请在每个工作节点上运行以下命令：                                                    *"
    echo "*                                                                                                       *"
    echo "kubeadm join ${APISERVER_ADVERTISE_ADDRESS}:6443 \\"
    echo "    --token ${token} \\"
    echo "    --discovery-token-ca-cert-hash sha256:${ca_hash}"
    echo "*                                                                                                       *"
    echo "*********************************************************************************************************"
}

# 验证集群状态
verify_cluster() {
    log_info "验证集群状态..."
    
    # 等待所有Pod就绪
    kubectl wait --for=condition=ready pod --all -n kube-system --timeout=300s
    
    # 显示节点状态
    log_info "节点状态:"
    kubectl get nodes
    
    # 显示Pod状态
    log_info "Pod状态:"
    kubectl get pods -n kube-system
    
    check_ok "验证集群状态"
}

# 主函数
main() {
    local config_file=$1
    
    log_info "开始Kubernetes Master节点配置..."
    
    # 检查root权限
    check_root
    
    # 验证配置文件
    validate_config "$config_file"
    
    # 读取配置
    read_config "$config_file"
    
    # 确认配置
    echo "*********************************************************************************************************"
    echo "*   配置确认                                                                                            *"
    echo "*********************************************************************************************************"
    echo "POD_NETWORK_CIDR: $POD_NETWORK_CIDR"
    echo "SERVICE_CIDR: $SERVICE_CIDR"
    echo "APISERVER_ADVERTISE_ADDRESS: $APISERVER_ADVERTISE_ADDRESS"
    echo "KUBERNETES_VERSION: $KUBERNETES_VERSION"
    echo "DOCKER_VERSION: $DOCKER_VERSION"
    echo "*********************************************************************************************************"
    echo "确认继续? (y/n):"
    read -r answer
    
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_info "用户取消操作"
        exit 0
    fi
    
    # 执行配置步骤
    close_swap
    close_firewall
    configure_bridge
    disable_selinux
    configure_docker
    load_docker_images
    configure_kube_tools
    init_master
    configure_cluster_access
    configure_network
    verify_cluster
    show_join_command
    
    log_success "Kubernetes Master节点配置完成！"
}

# 脚本入口
if [[ $# -ne 1 ]]; then
    log_error "用法: $0 <配置文件路径>"
    exit 1
fi

main "$1"
