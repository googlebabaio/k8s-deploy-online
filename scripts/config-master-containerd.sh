#!/bin/bash

# Kubernetes Master节点配置脚本 - containerd版本
# 使用containerd作为容器运行时，替代Docker
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
    log_info "  DOCKER_VERSION: $DOCKER_VERSION (包含containerd)"
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

# 配置系统repo源
configure_yum_repos() {
    log_info "开始配置阿里云yum源..."
    
    # 备份原始repo文件
    mkdir -p /etc/yum.repos.d/backup
    cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
    
    # 清理所有仓库配置，避免冲突
    log_info "清理旧的仓库配置..."
    rm -f /etc/yum.repos.d/kubernetes.repo
    rm -f /etc/yum.repos.d/docker-ce.repo
    
    # 导入基础源的GPG密钥
    log_info "导入基础源GPG密钥..."
    rpm --import https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
    rpm --import https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-7
    rpm --import https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
    
    # 清理yum缓存，避免使用旧配置
    log_info "清理yum缓存..."
    yum clean all || log_warning "yum clean all失败，继续执行"
    rm -rf /var/cache/yum/* || log_warning "清理缓存目录失败，继续执行"
    
    # 配置阿里云CentOS源（需要GPG验证）
    cat <<EOF > /etc/yum.repos.d/CentOS-Base.repo
[base]
name=CentOS-\$releasever - Base - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/\$releasever/os/\$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[updates]
name=CentOS-\$releasever - Updates - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/\$releasever/updates/\$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[extras]
name=CentOS-\$releasever - Extras - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/\$releasever/extras/\$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[epel]
name=Extra Packages for Enterprise Linux 7 - \$basearch - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/epel/7/\$basearch
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-7
EOF
    
    # 清理yum缓存
    yum clean all
    yum makecache
    
    check_ok "配置阿里云yum源"
}

# 配置Docker和containerd
configure_docker_containerd() {
    log_info "开始配置Docker和containerd..."
    
    # 卸载旧版本Docker
    log_info "卸载旧版本Docker..."
    yum remove -y docker docker-common container-selinux docker-selinux docker-engine 2>/dev/null || true
    
    # 安装Docker CE (包含containerd)
    log_info "安装Docker CE $DOCKER_VERSION..."
    cd /etc/yum.repos.d/
    wget -q https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    
    # 检查Docker仓库是否可用
    log_info "检查Docker仓库..."
    yum repolist | grep docker-ce || {
        log_error "Docker仓库配置失败"
        exit 1
    }
    
    # 检查可用版本
    log_info "检查Docker CE可用版本..."
    yum list available docker-ce --showduplicates | grep ${DOCKER_VERSION} || {
        log_warning "指定版本 ${DOCKER_VERSION} 不可用，检查可用版本："
        yum list available docker-ce --showduplicates | head -10
        log_info "尝试安装最新版本..."
        yum install -y docker-ce docker-ce-cli containerd.io
    }
    
    # 安装Docker CE (会自动安装containerd)
    log_info "安装Docker CE组件..."
    if yum list available docker-ce-${DOCKER_VERSION} >/dev/null 2>&1; then
        yum install -y docker-ce-${DOCKER_VERSION} docker-ce-cli-${DOCKER_VERSION} containerd.io
    else
        log_warning "指定版本不可用，安装最新版本..."
        yum install -y docker-ce docker-ce-cli containerd.io
    fi
    
    # 验证Docker安装
    log_info "验证Docker安装..."
    which docker || {
        log_error "Docker安装失败，未找到docker命令"
        log_info "尝试重新安装..."
        yum reinstall -y docker-ce-${DOCKER_VERSION} docker-ce-cli-${DOCKER_VERSION}
    }
    
    # 检查Docker命令
    docker --version || {
        log_error "Docker命令不可用"
        exit 1
    }
    
    # 配置Docker daemon (仅作为客户端)
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
    
    # 配置containerd (主要容器运行时)
    log_info "配置containerd作为主要容器运行时..."
    mkdir -p /etc/containerd
    
    # 创建完整的containerd配置文件
    cat <<EOF > /etc/containerd/config.toml
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"

[grpc]
  address = "/run/containerd/containerd.sock"
  uid = 0
  gid = 0
  max_recv_message_size = 16777216
  max_send_message_size = 16777216

[ttrpc]
  address = ""
  uid = 0
  gid = 0

[debug]
  address = ""
  uid = 0
  gid = 0
  level = ""

[metrics]
  address = ""
  grpc_histogram = false

[cgroup]
  path = ""

[timeouts]
  "io.containerd.timeout.shim.cleanup" = "5s"
  "io.containerd.timeout.shim.load" = "5s"
  "io.containerd.timeout.shim.shutdown" = "3s"
  "io.containerd.timeout.task.state" = "2s"

[plugins]
  [plugins."io.containerd.gc.v1.scheduler"]
    pause_threshold = 0.02
    deletion_threshold = 0
    mutation_threshold = 100
    schedule_delay = "0s"
    startup_delay = "100ms"
  [plugins."io.containerd.grpc.v1.cri"]
    disable_tcp_service = true
    stream_server_address = "127.0.0.1"
    stream_server_port = "0"
    stream_idle_timeout = "4h0m0s"
    enable_selinux = false
    selinux_category_range = 1024
    sandbox_image = "registry.k8s.io/pause:3.9"
    stats_collect_period = 10
    systemd_cgroup = true
    enable_tls_streaming = false
    max_container_log_line_size = 16384
    disable_cgroup = false
    disable_apparmor = false
    restrict_oom_score_adj = false
    max_concurrent_downloads = 3
    disable_proc_mount = false
    unset_seccomp_profile = ""
    tolerate_missing_hugetlb_controller = true
    disable_hugetlb_controller = true
    ignore_image_defined_volumes = false
    [plugins."io.containerd.grpc.v1.cri".containerd]
      snapshotter = "overlayfs"
      default_runtime_name = "runc"
      no_pivot = false
      disable_snapshot_annotations = true
      discard_unpacked_layers = false
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          runtime_engine = ""
          runtime_root = ""
          privileged_without_host_devices = false
          base_runtime_spec = ""
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
      max_conf_num = 1
      conf_template = ""
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
          endpoint = ["https://registry.aliyuncs.com"]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."k8s.gcr.io"]
          endpoint = ["https://registry.aliyuncs.com/google_containers"]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
          endpoint = ["https://registry.aliyuncs.com/google_containers"]
      [plugins."io.containerd.grpc.v1.cri".registry.configs]
        [plugins."io.containerd.grpc.v1.cri".registry.configs."registry.aliyuncs.com".tls]
          insecure_skip_verify = true
        [plugins."io.containerd.grpc.v1.cri".registry.configs."registry.aliyuncs.com".auth]
          username = ""
          password = ""
          auth = ""
          identity_token = ""
    [plugins."io.containerd.grpc.v1.cri".image_decryption]
      key_model = ""
    [plugins."io.containerd.grpc.v1.cri".x509_key_pair_streaming]
      tls_cert_file = ""
      tls_private_key_file = ""
EOF
    
    # 验证containerd配置文件
    log_info "验证containerd配置文件..."
    containerd config dump > /dev/null
    if [ $? -ne 0 ]; then
        log_error "containerd配置文件有语法错误，请检查"
        exit 1
    fi
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable docker
    systemctl enable containerd
    
    # 先启动containerd
    log_info "启动containerd服务..."
    systemctl start containerd
    sleep 3
    
    # 再启动docker
    log_info "启动Docker服务..."
    systemctl start docker
    sleep 3
    
    # 验证服务状态
    log_info "检查服务状态..."
    systemctl is-active --quiet containerd
    if [ $? -ne 0 ]; then
        log_error "containerd服务启动失败"
        systemctl status containerd
        exit 1
    fi
    
    systemctl is-active --quiet docker
    if [ $? -ne 0 ]; then
        log_error "Docker服务启动失败"
        systemctl status docker
        exit 1
    fi
    
    # 验证安装
    log_info "验证Docker和containerd安装..."
    
    # 检查Docker
    if command -v docker >/dev/null 2>&1; then
        docker --version
    else
        log_error "Docker命令不可用"
        exit 1
    fi
    
    # 检查containerd
    if command -v containerd >/dev/null 2>&1; then
        containerd --version
    else
        log_error "containerd命令不可用"
        exit 1
    fi
    
    # 验证服务连接
    log_info "测试Docker和containerd连接..."
    docker version > /dev/null 2>&1 || {
        log_warning "Docker服务可能未完全启动，等待5秒..."
        sleep 5
        docker version > /dev/null || {
            log_error "Docker服务连接失败"
            systemctl status docker
            exit 1
        }
    }
    
    check_ok "配置Docker和containerd"
}

# 安装runc
install_runc() {
    log_info "开始安装runc..."
    
    # 下载runc
    cd /tmp
    #wget -q https://github.com/opencontainers/runc/releases/download/v1.1.4/runc.amd64
    cp ./scripts/runc.amd64 /tmp/runc.amd64
    chmod +x /tmp/runc.amd64
    mv /tmp/runc.amd64 /usr/local/bin/runc
    
    check_ok "安装runc"
}   

# 安装CNI插件
install_cni_plugins() {
    log_info "开始安装CNI插件..."
    
    # 下载CNI插件
    cd /tmp
    ##wget -q https://github.com/containernetworking/plugins/releases/download/v1.1.1/cni-plugins-linux-amd64-v1.1.1.tgz
    cp ./scripts/cni-plugins-linux-amd64-v1.1.1.tgz /tmp/cni-plugins-linux-amd64-v1.1.1.tgz
    mkdir -p /opt/cni/bin
    tar -xzf /tmp/cni-plugins-linux-amd64-v1.1.1.tgz -C /opt/cni/bin/
    
    check_ok "安装CNI插件"
}

# 配置Kubernetes工具
configure_kube_tools() {
    log_info "开始配置Kubernetes工具..."
    
    # 删除旧的Kubernetes仓库配置
    log_info "清理旧的Kubernetes仓库配置..."
    rm -f /etc/yum.repos.d/kubernetes.repo
    
    # 配置Kubernetes仓库
    log_info "配置Kubernetes仓库..."
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${KUBERNETES_MAJOR_VERSION}/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=
EOF
    
    # 彻底清理yum缓存
    log_info "清理yum缓存..."
    yum clean all || log_warning "yum clean all失败，继续执行"
    rm -rf /var/cache/yum/* || log_warning "清理缓存目录失败，继续执行"
    yum makecache || log_warning "yum makecache失败，继续执行"
    
    # 安装Kubernetes工具
    log_info "安装Kubernetes工具..."
    yum install -y kubelet-${KUBERNETES_VERSION} kubeadm-${KUBERNETES_VERSION} kubectl-${KUBERNETES_VERSION} --disableexcludes=kubernetes || {
        log_warning "阿里云Kubernetes仓库安装失败，尝试使用官方仓库..."
        
        # 配置官方Kubernetes仓库作为备用
        cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
        
        # 清理缓存并重试
        yum clean all
        yum makecache
        
        # 重新尝试安装
        yum install -y kubelet-${KUBERNETES_VERSION} kubeadm-${KUBERNETES_VERSION} kubectl-${KUBERNETES_VERSION} --disableexcludes=kubernetes
    }
    
    # 配置kubelet使用containerd (Kubernetes 1.24+默认)
    log_info "配置kubelet使用containerd作为容器运行时..."
    mkdir -p /etc/systemd/system/kubelet.service.d/
    cat <<EOF > /etc/systemd/system/kubelet.service.d/20-containerd.conf
[Service]
ExecStart=
ExecStart=/usr/bin/kubelet --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --cgroup-driver=systemd
EOF
    
    # 启用kubelet
    systemctl daemon-reload
    systemctl enable kubelet
    
    # 安装bash-completion（如果未安装）
    if ! rpm -q bash-completion >/dev/null 2>&1; then
        log_info "安装bash-completion..."
        yum install -y bash-completion || log_warning "bash-completion安装失败，继续执行"
    else
        log_info "bash-completion已安装，跳过"
    fi
    
    check_ok "配置Kubernetes工具"
}

# 检查系统兼容性
check_system_compatibility() {
    log_info "检查系统兼容性..."
    
    # 检查内核版本
    local kernel_version=$(uname -r | cut -d. -f1-2)
    local kernel_major=$(echo $kernel_version | cut -d. -f1)
    local kernel_minor=$(echo $kernel_version | cut -d. -f2)
    
    log_info "当前内核版本: $(uname -r)"
    
    # 检查是否支持Kubernetes 1.32
    if [ $kernel_major -lt 4 ] || ([ $kernel_major -eq 4 ] && [ $kernel_minor -lt 15 ]); then
        log_warning "内核版本过低，不支持Kubernetes 1.32.9"
        log_warning "建议使用内核4.15+或5.x+版本"
        log_warning "将使用--ignore-preflight-errors参数继续安装"
        return 1
    fi
    
    return 0
}

# 初始化Master节点
init_master() {
    log_info "开始初始化Master节点..."
    
    # 停止kubelet服务
    systemctl stop kubelet 2>/dev/null || true
    
    # 检查系统兼容性
    local ignore_errors=""
    if ! check_system_compatibility; then
        ignore_errors="--ignore-preflight-errors=SystemVerification"
        log_warning "将忽略系统验证错误继续安装"
    fi
    
    # 初始化集群
    log_info "执行kubeadm init..."
    kubeadm init \
        --image-repository registry.aliyuncs.com/google_containers \
        --kubernetes-version=v${KUBERNETES_VERSION} \
        --pod-network-cidr=${POD_NETWORK_CIDR} \
        --apiserver-advertise-address=${APISERVER_ADVERTISE_ADDRESS} \
        --service-cidr=${SERVICE_CIDR} \
        --cri-socket=unix:///var/run/containerd/containerd.sock \
        ${ignore_errors}
    
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
    echo "*   使用containerd作为容器运行时                                                                         *"
    echo "*                                                                                                       *"
    echo "*   要加入工作节点，请在每个工作节点上运行以下命令：                                                    *"
    echo "*                                                                                                       *"
    echo "kubeadm join ${APISERVER_ADVERTISE_ADDRESS}:6443 \\"
    echo "    --token ${token} \\"
    echo "    --discovery-token-ca-cert-hash sha256:${ca_hash} \\"
    echo "    --cri-socket=unix:///var/run/containerd/containerd.sock"
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
    
    # 显示容器运行时信息
    log_info "容器运行时信息:"
    kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}'
    echo
    
    check_ok "验证集群状态"
}

# 主函数
main() {
    local config_file=$1
    
    log_info "开始Kubernetes Master节点配置（使用containerd）..."
    
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
    echo "容器运行时: containerd (通过Docker安装)"
    echo "*********************************************************************************************************"
    echo "确认继续? (y/n):"
    read -r answer
    
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_info "用户取消操作"
        exit 0
    fi
    
    # 执行配置步骤
    configure_yum_repos
    close_swap
    close_firewall
    configure_bridge
    disable_selinux
    configure_docker_containerd
    install_runc
    install_cni_plugins
    configure_kube_tools
    init_master
    configure_cluster_access
    configure_network
    verify_cluster
    show_join_command
    
    log_success "Kubernetes Master节点配置完成！使用containerd作为容器运行时"
}

# 脚本入口
if [[ $# -ne 1 ]]; then
    log_error "用法: $0 <配置文件路径>"
    exit 1
fi

main "$1"
