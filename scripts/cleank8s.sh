#!/bin/bash

# 设置错误处理
set -euo pipefail

# 日志函数
log_info() {
    echo "[INFO] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1"
}

# 检查服务状态
check_service_status() {
    local service=$1
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        log_info "$service 服务正在运行"
        return 0
    else
        log_info "$service 服务未运行"
        return 1
    fi
}

# 优雅停止服务
stop_service() {
    local service=$1
    if check_service_status "$service"; then
        log_info "停止 $service 服务..."
        systemctl stop "$service" || log_warning "停止 $service 失败"
    fi
}

# 清理网络接口
cleanup_network_interfaces() {
    log_info "清理网络接口..."
    
    # 清理常见的CNI接口
    local interfaces=("cni0" "flannel.1" "docker0" "br-*")
    
    for interface in "${interfaces[@]}"; do
        if [[ "$interface" == "br-*" ]]; then
            # 处理bridge接口
            for br in $(ip link show | grep -E "br-[0-9a-f]+" | cut -d: -f2 | tr -d ' '); do
                if ip link show "$br" >/dev/null 2>&1; then
                    log_info "清理bridge接口: $br"
                    ip link set "$br" down 2>/dev/null || true
                    ip link delete "$br" 2>/dev/null || true
                fi
            done
        else
            if ip link show "$interface" >/dev/null 2>&1; then
                log_info "清理网络接口: $interface"
                ip link set "$interface" down 2>/dev/null || true
                ip link delete "$interface" 2>/dev/null || true
            fi
        fi
    done
}

# 清理Kubernetes配置
cleanup_k8s_config() {
    log_info "清理Kubernetes配置..."
    
    # 停止相关服务
    stop_service "kubelet"
    stop_service "containerd"
    stop_service "docker"
    
    # 重置kubeadm
    if command -v kubeadm >/dev/null 2>&1; then
        log_info "执行 kubeadm reset..."
        kubeadm reset --force || log_warning "kubeadm reset 失败"
    fi
    
    # 清理配置文件
    log_info "清理配置文件..."
    rm -rf ~/.kube
    rm -rf /var/lib/cni/
    rm -rf /etc/cni/
    rm -rf /var/lib/kubelet/*
    rm -rf /etc/kubernetes/
    rm -rf /var/lib/etcd/
    
    # 清理systemd服务文件
    rm -f /usr/lib/systemd/system/kubelet.service
    rm -f /etc/systemd/system/kubelet.service.d/
    
    # 重新加载systemd
    systemctl daemon-reload
}

# 卸载Kubernetes包
uninstall_k8s_packages() {
    log_info "卸载Kubernetes包..."
    
    # 卸载kubelet, kubectl, kubeadm
    yum remove -y kubelet kubectl kubeadm 2>/dev/null || log_warning "卸载Kubernetes包失败"
    
    # 清理yum缓存
    yum clean all || log_warning "清理yum缓存失败"
}

echo "***************************************************************************************************"
echo "*                                                                                                 *"
echo "*    Note:                                                                                        *"
echo "*        It's dangerous to do this !!!                                                            *"
echo "*        Do you know it will clean k8s right now?                                                 *"
echo "*        This will remove Kubernetes but keep container runtime (Docker/containerd)               *"
echo "*                                                                                                 *"
echo "***************************************************************************************************"
echo "Are you sure?  (yes/no):"
read answer
if [ "${answer}" = "yes" -o "${answer}" = "y" ];then
    echo "*********************************************************************************************************"
    echo "*   NOTE:                                                                                               *"
    echo "*        begin to clean k8s config                                                                      *"
    echo "*                                                                                                       *"
    echo "*********************************************************************************************************"

    # 执行清理步骤
    cleanup_k8s_config
    cleanup_network_interfaces
    uninstall_k8s_packages

    echo "*********************************************************************************************************"
    echo "*   NOTE:                                                                                               *"
    echo "*         finish clean k8s config                                                                       *"
    echo "*         Container runtime (Docker/containerd) is preserved                                            *"
    echo "*                                                                                                       *"
    echo "*********************************************************************************************************"
else
    echo "***************************************************************************************************"
    echo "*                            Yes,may be you're right!                                             *"
    echo "***************************************************************************************************"
    exit 1
fi
