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

# 清理容器运行时
cleanup_container_runtime() {
    log_info "清理容器运行时..."
    
    # 停止容器服务
    stop_service "containerd"
    stop_service "docker"
    
    # 清理Docker相关
    log_info "清理Docker配置..."
    rm -rf /var/lib/docker
    rm -rf /etc/docker
    rm -rf /usr/bin/docker*
    rm -rf /usr/lib/systemd/system/docker.service
    rm -rf /usr/lib/systemd/system/containerd.service
    
    # 清理containerd相关
    log_info "清理containerd配置..."
    rm -rf /var/lib/containerd
    rm -rf /etc/containerd
    rm -rf /usr/bin/containerd*
    rm -rf /usr/bin/ctr
    rm -rf /usr/bin/runc
    rm -rf /opt/cni/bin/*
    
    # 清理容器镜像和容器
    log_info "清理容器镜像和容器..."
    # 注意：这里不执行docker命令，因为可能已经卸载
    rm -rf /var/lib/containerd/io.containerd.content.v1.content/blobs
    rm -rf /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs
}

# 卸载所有相关包
uninstall_all_packages() {
    log_info "卸载所有相关包..."
    
    # 卸载Kubernetes包
    yum remove -y kubelet kubectl kubeadm 2>/dev/null || log_warning "卸载Kubernetes包失败"
    
    # 卸载Docker包
    yum remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || log_warning "卸载Docker包失败"
    
    # 卸载其他相关包
    yum remove -y docker-ce-rootless-extras 2>/dev/null || true
    
    # 清理yum缓存
    yum clean all || log_warning "清理yum缓存失败"
}

# 清理系统配置
cleanup_system_config() {
    log_info "清理系统配置..."
    
    # 恢复系统配置
    log_info "恢复系统配置..."
    
    # 恢复swap
    if [ -f /etc/fstab ]; then
        sed -i '/swap/d' /etc/fstab || log_warning "清理swap配置失败"
    fi
    
    # 恢复内核参数
    if [ -f /etc/sysctl.d/k8s.conf ]; then
        rm -f /etc/sysctl.d/k8s.conf
        sysctl --system || log_warning "重新加载sysctl配置失败"
    fi
    
    # 恢复防火墙规则
    if systemctl is-active --quiet firewalld; then
        log_info "恢复防火墙规则..."
        firewall-cmd --reload || log_warning "重新加载防火墙规则失败"
    fi
    
    # 清理bash-completion
    yum remove -y bash-completion 2>/dev/null || log_warning "卸载bash-completion失败"
}

# 清理日志和临时文件
cleanup_logs_and_temp() {
    log_info "清理日志和临时文件..."
    
    # 清理系统日志
    journalctl --vacuum-time=1s || log_warning "清理系统日志失败"
    
    # 清理临时文件
    rm -rf /tmp/k8s-*
    rm -rf /tmp/docker-*
    rm -rf /tmp/containerd-*
    
    # 清理yum缓存
    rm -rf /var/cache/yum/*
}

echo "***************************************************************************************************"
echo "*                                                                                                 *"
echo "*    ⚠️  危险操作警告 ⚠️                                                                           *"
echo "*                                                                                                 *"
echo "*    此操作将完全清理所有Kubernetes和容器运行时配置！                                             *"
echo "*    包括：Kubernetes、Docker、containerd、所有容器镜像和数据                                     *"
echo "*                                                                                                 *"
echo "*    请确保您已经备份了重要数据！                                                                 *"
echo "*                                                                                                 *"
echo "***************************************************************************************************"
echo "Are you sure?  (yes/no):"
read answer
if [ "${answer}" = "yes" -o "${answer}" = "y" ];then
    echo "*********************************************************************************************************"
    echo "*   NOTE:                                                                                               *"
    echo "*        begin to clean all config                                                                      *"
    echo "*                                                                                                       *"
    echo "*********************************************************************************************************"

    # 执行清理步骤
    cleanup_k8s_config
    cleanup_container_runtime
    cleanup_network_interfaces
    uninstall_all_packages
    cleanup_system_config
    cleanup_logs_and_temp

    echo "*********************************************************************************************************"
    echo "*   NOTE:                                                                                               *"
    echo "*         finish clean all config                                                                       *"
    echo "*         所有Kubernetes和容器运行时组件已完全清理                                                    *"
    echo "*                                                                                                       *"
    echo "*********************************************************************************************************"
else
    echo "***************************************************************************************************"
    echo "*                            Yes,may be you're right!                                             *"
    echo "***************************************************************************************************"
    exit 1
fi
