#!/bin/bash

# 修复containerd CRI接口问题
# 适用于containerd 1.6.33与Kubernetes 1.28.2的兼容性问题

set -euo pipefail

log_info() {
    echo "[INFO] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1"
}

# 检查当前containerd版本
check_containerd_version() {
    log_info "检查containerd版本..."
    local version=$(containerd --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    log_info "当前containerd版本: $version"
    
    if [[ "$version" == "1.6.33" ]]; then
        log_warning "检测到containerd 1.6.33，与Kubernetes 1.28.2存在兼容性问题"
        return 1
    fi
    return 0
}

# 方案1：降级containerd到兼容版本
downgrade_containerd() {
    log_info "开始降级containerd到兼容版本..."
    
    # 停止服务
    systemctl stop containerd docker kubelet 2>/dev/null || true
    
    # 卸载当前版本
    log_info "卸载当前containerd版本..."
    yum remove -y containerd.io docker-ce-cli docker-ce
    
    # 安装兼容版本
    log_info "安装containerd 1.6.21（兼容版本）..."
    yum install -y containerd.io-1.6.21-3.1.el7 docker-ce-cli docker-ce
    
    # 重新配置containerd
    log_info "重新配置containerd..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    
    # 修改配置
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    
    # 启动服务
    log_info "启动containerd服务..."
    systemctl daemon-reload
    systemctl enable containerd
    systemctl start containerd
    
    # 验证修复
    log_info "验证containerd CRI接口..."
    if crictl --runtime-endpoint=unix:///var/run/containerd/containerd.sock version >/dev/null 2>&1; then
        log_info "✅ containerd CRI接口修复成功"
        return 0
    else
        log_error "❌ containerd CRI接口修复失败"
        return 1
    fi
}

# 方案2：使用Docker作为容器运行时
switch_to_docker() {
    log_info "切换到Docker作为容器运行时..."
    
    # 停止containerd
    systemctl stop containerd 2>/dev/null || true
    systemctl disable containerd 2>/dev/null || true
    
    # 确保Docker运行
    systemctl start docker
    systemctl enable docker
    
    # 修改kubelet配置
    log_info "修改kubelet配置使用Docker..."
    mkdir -p /etc/systemd/system/kubelet.service.d
    cat <<EOF > /etc/systemd/system/kubelet.service.d/20-docker.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime=docker --container-runtime-endpoint=unix:///var/run/dockershim.sock"
EOF
    
    systemctl daemon-reload
    systemctl restart kubelet
    
    log_info "✅ 已切换到Docker作为容器运行时"
}

# 方案3：修复containerd配置
fix_containerd_config() {
    log_info "尝试修复containerd配置..."
    
    # 停止服务
    systemctl stop containerd 2>/dev/null || true
    
    # 清理配置
    rm -rf /var/lib/containerd
    rm -rf /run/containerd
    
    # 重新生成配置
    log_info "重新生成containerd配置..."
    containerd config default > /etc/containerd/config.toml
    
    # 修改关键配置
    log_info "修改containerd配置..."
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    
    # 添加CRI插件配置
    cat <<EOF >> /etc/containerd/config.toml

# 确保CRI插件正确配置
[plugins."io.containerd.grpc.v1.cri"]
  disable_tcp_service = true
  stream_server_address = "127.0.0.1"
  stream_server_port = "0"
  enable_selinux = false
  systemd_cgroup = true
  sandbox_image = "registry.k8s.io/pause:3.9"
  
  [plugins."io.containerd.grpc.v1.cri".containerd]
    snapshotter = "overlayfs"
    default_runtime_name = "runc"
    
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
        runtime_type = "io.containerd.runc.v2"
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
          SystemdCgroup = true
EOF
    
    # 启动服务
    log_info "启动containerd服务..."
    systemctl daemon-reload
    systemctl start containerd
    
    # 验证
    sleep 3
    if crictl --runtime-endpoint=unix:///var/run/containerd/containerd.sock version >/dev/null 2>&1; then
        log_info "✅ containerd配置修复成功"
        return 0
    else
        log_error "❌ containerd配置修复失败"
        return 1
    fi
}

# 主函数
main() {
    log_info "开始修复containerd CRI接口问题..."
    
    # 检查当前状态
    if check_containerd_version; then
        log_info "containerd版本兼容，无需修复"
        exit 0
    fi
    
    echo "请选择修复方案："
    echo "1. 降级containerd到兼容版本（推荐）"
    echo "2. 切换到Docker作为容器运行时"
    echo "3. 尝试修复containerd配置"
    echo "4. 退出"
    
    read -p "请输入选择 (1-4): " choice
    
    case $choice in
        1)
            downgrade_containerd
            ;;
        2)
            switch_to_docker
            ;;
        3)
            fix_containerd_config
            ;;
        4)
            log_info "退出修复"
            exit 0
            ;;
        *)
            log_error "无效选择"
            exit 1
            ;;
    esac
}

main "$@"
