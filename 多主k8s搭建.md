# 三主六从k8s搭建-Rocky

## 一、机器配置

### 1、网络设置

```shell
vim /etc/NetworkManager/system-connections/ens160.nmconnection
```

```vim
[ipv4]
method=manual
address1=192.168.103.10/24,192.168.103.2
dns=114.114.114.114;8.8.8.8
```

### 2、替换阿里镜像源

#### 1）备份默认源

```shell
mkdir -p /etc/yum.repos.d/backup
cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/
```

#### 2）替换阿里镜像源

- 默认源

```shell
sed -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|g' \
    /etc/yum.repos.d/rocky*.repo
```

- 拓展源

```shell
dnf install -y https://mirrors.aliyun.com/epel/epel-release-latest-10.noarch.rpm
sed -i 's|^#baseurl=https://download.example/pub/epel|baseurl=https://mirrors.aliyun.com/epel|g' /etc/yum.repos.d/epel*.repo
sed -i 's|^metalink=|#metalink=|g' /etc/yum.repos.d/epel*.repo
```

- docker源

```shell
dnf config-manager --add-repo=https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
sed -i 's|download.docker.com|mirrors.aliyun.com/docker-ce|g' /etc/yum.repos.d/docker-ce.repo
```

#### 3）清理缓存

```shell
dnf clean all
dnf makecache
```

### 3、系统基本配置

#### 1）设置主机名

```shell
hostnamectl set-hostname k8s-master01
bash
```

#### 2）修改hosts

```shell
cat >> /etc/hosts << EOF
192.168.103.100 k8s-apiserver
192.168.103.10 k8s-master01
192.168.103.11 k8s-master02
192.168.103.12 k8s-master03
192.168.103.20 k8s-worker01
192.168.103.21 k8s-worker02
192.168.103.22 k8s-worker03
192.168.103.23 k8s-worker04
192.168.103.24 k8s-worker05
192.168.103.25 k8s-worker06
EOF
```

#### 3）关闭并禁用防火墙

```shell
systemctl stop firewalld
systemctl disable firewalld
systemctl mask firewalld
```

#### 4）关闭 SELinux

```shell
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
```

#### 5）永久关闭交换分区

```shell
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab
```

#### 6）启用时间同步

```shell
cp /etc/chrony.conf /etc/chrony.conf.bak && sed -i '/^pool 2.rocky.pool.ntp.org iburst/s/^/#/' /etc/chrony.conf && echo -e "server ntp.aliyun.com iburst\nserver ntp1.aliyun.com iburst\nserver ntp2.aliyun.com iburst" >> /etc/chrony.conf && systemctl restart chronyd
```

```shell
systemctl enable --now chronyd
chronyc sources -v
```

#### 7）安装依赖包

- Rocky

```shell
dnf install -y wget curl vim net-tools nmap-ncat conntrack-tools libseccomp ipvsadm
```

- Ubuntu

```shell
apt install -y wget curl vim net-tools ncat conntrack libseccomp-dev ipvsadm
```

### 4、内核参数与模块优化

#### 1）加载必须的内核模块

```shell
modprobe br_netfilter
modprobe overlay
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe ip_vs_sh
modprobe nf_conntrack
```

#### 2）配置开机自动加载模块

```shell
cat > /etc/modules-load.d/k8s.conf << EOF
br_netfilter
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
```

#### 3）优化内核参数

```shell
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1
net.ipv6.conf.all.forwarding        = 1
vm.swappiness                       = 0
vm.overcommit_memory                = 1
vm.panic_on_oom                     = 0
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 1048576
fs.file-max                         = 52706963
fs.nr_open                          = 52706963
net.netfilter.nf_conntrack_max      = 2310720
net.ipv4.tcp_syncookies            = 1
net.ipv4.tcp_fin_timeout           = 30
net.ipv4.tcp_keepalive_time        = 600
EOF
```

#### 4）生效配置

```shell
sysctl --system
```

## 二、docker安装

### 1、查看docker源

```shell
 dnf list docker-ce-cli --showduplicates | sort -r
```

### 2、下载安装docker

```shell
dnf install -y docker-ce-3:29.5.3-1.el10 docker-ce-cli-1:29.5.3-1.el10 containerd.io docker-compose-plugin
```

### 3、docker设置开机自启

```shell
systemctl daemon-reload
systemctl enable --now docker
systemctl status docker
```

### 4、下载安装cri-dockerd

```shell
wget https://github.com/Mirantis/cri-dockerd/releases/download/v0.4.3/cri-dockerd-0.4.3.amd64.tgz
tar -zxf cri-dockerd-0.4.3.amd64.tgz
install -o root -g root -m 0755 cri-dockerd/cri-dockerd /usr/local/bin/
```

### 5、创建cri-dockerd系统文件

```shell
cat > /etc/systemd/system/cri-dockerd.service <<EOF
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target docker.socket firewalld.service
Wants=network-online.target
Requires=docker.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd \
  --container-runtime-endpoint unix:///var/run/cri-dockerd.sock \
  --network-plugin=cni \
  --cni-conf-dir=/etc/cni/net.d \
  --cni-bin-dir=/opt/cni/bin \
  --pod-infra-container-image=registry.aliyuncs.com/google_containers/pause:3.10
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always

TasksMax=infinity
Delegate=yes
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
```

- Ubuntu

```shell
cat > /etc/systemd/system/cri-dockerd.service <<EOF
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target docker.socket
Wants=network-online.target
Requires=docker.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd \
  --container-runtime-endpoint unix:///var/run/cri-dockerd.sock \
  --network-plugin=cni \
  --cni-conf-dir=/etc/cni/net.d \
  --cni-bin-dir=/opt/cni/bin \
  --pod-infra-container-image=registry.aliyuncs.com/google_containers/pause:3.10
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always

TasksMax=infinity
Delegate=yes
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
```

### 6、写入cri-docker.socket

```shell
cat > /etc/systemd/system/cri-docker.socket <<EOF
[Unit]
Description=CRI Docker Socket for the API
PartOf=cri-dockerd.service

[Socket]
ListenStream=/var/run/cri-dockerd.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF
```

### 7、cri-dockerd设置开机自启

```shell
systemctl daemon-reload
systemctl enable --now cri-dockerd cri-docker.socket
systemctl status cri-dockerd
```

## 三、安装Kubernetes组件

### 1、添加阿里云镜像

```shell
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.36/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.36/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
```

- Ubuntu

```shell
apt-get update && apt-get install -y apt-transport-https
curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.36/deb/Release.key |
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.36/deb/ /" |
    tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
```

### 2、安装指定版本

```shell
dnf install -y kubelet-1.36.1 kubeadm-1.36.1 kubectl-1.36.1 --disableexcludes=kubernetes
```

- Ubuntu

```shell
apt install -y --allow-downgrades kubelet=1.36.1-1.1 kubeadm=1.36.1-1.1 kubectl=1.36.1-1.1
```

### 3、锁定版本

```shell
dnf install -y 'dnf-command(versionlock)'
dnf versionlock kubelet kubeadm kubectl
dnf versionlock list
```

- Ubuntu

```shell
apt-mark hold kubelet kubeadm kubectl
```

### 3、kubelet开机自启

```shell
systemctl enable kubelet
```

## 四、部署高可用负载均衡（Master节点安装）

### 1、下载安装HAProxy和Keepalived

```shell
dnf install -y haproxy keepalived
```

### 2、配置HAProxy（所有Master相同）

#### 1）备份文件

```shell
mv /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
```

#### 2）修改文件

```shell
cat > /etc/haproxy/haproxy.cfg << EOF
global
    log /dev/log local0 warning
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 10000

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5s
    timeout client 1m
    timeout server 1m
    maxconn 10000

frontend k8s-apiserver
    bind *:6443
    mode tcp
    default_backend k8s-apiserver-backend

backend k8s-apiserver-backend
    mode tcp
    balance roundrobin
    option tcp-check
    server k8s-master01 192.168.1.10:6443 check fall 3 rise 2
    server k8s-master02 192.168.1.11:6443 check fall 3 rise 2
    server k8s-master03 192.168.1.12:6443 check fall 3 rise 2

listen stats
    bind *:1080
    mode http
    stats enable
    stats uri /stats
    stats auth admin:Admin@123
    stats refresh 5s
EOF
```

#### 3）设置开机自启

```shell
systemctl enable --now haproxy
systemctl status haproxy
```

### 3、配置Keepalived

#### 1）写check_apiserver.sh健康检查文件

```shell
cat > /etc/keepalived/check_apiserver.sh << EOF
#!/bin/bash
if ! nc -z 127.0.0.1 6443; then
    exit 1
fi
exit 0
EOF
```

#### 2）赋予权限

```shell
chmod +x /etc/keepalived/check_apiserver.sh
```

#### 3）修改配置文件

- master01 - interface 后设置本机网卡名称

```shell
cat > /etc/keepalived/keepalived.conf << EOF
! Configuration File for keepalived
global_defs {
    router_id k8s-master01
    script_user root
    enable_script_security
}

vrrp_script check_apiserver {
    script "/etc/keepalived/check_apiserver.sh"
    interval 3
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface ens160
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass K8s@123456
    }
    virtual_ipaddress {
        192.168.103.100/24
    }
    track_script {
        check_apiserver
    }
}
EOF
```

- master02 - 修改 router_id、state 和 priority

```shell
cat > /etc/keepalived/keepalived.conf << EOF
! Configuration File for keepalived
global_defs {
    router_id k8s-master02
    script_user root
    enable_script_security
}

vrrp_script check_apiserver {
    script "/etc/keepalived/check_apiserver.sh"
    interval 3
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface ens160
    virtual_router_id 51
    priority 90
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass K8s@123456
    }
    virtual_ipaddress {
        192.168.103.100/24
    }
    track_script {
        check_apiserver
    }
}
EOF
```

- master03 - 修改 router_id、state 和 priority

```shell
cat > /etc/keepalived/keepalived.conf << EOF
! Configuration File for keepalived
global_defs {
    router_id k8s-master03
    script_user root
    enable_script_security
}

vrrp_script check_apiserver {
    script "/etc/keepalived/check_apiserver.sh"
    interval 3
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface ens160
    virtual_router_id 51
    priority 80
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass K8s@123456
    }
    virtual_ipaddress {
        192.168.103.100/24
    }
    track_script {
        check_apiserver
    }
}
EOF
```

#### 4）设置开启自启

```shell
systemctl enable --now keepalived
systemctl status keepalived
```

## 五、初始化Kubernetes（master01）

### 1、生成Kubeadm配置文件

```shell
cat > kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.103.10
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/cri-dockerd.sock
  kubeletExtraArgs:
    cgroup-driver: systemd
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.36.1
controlPlaneEndpoint: "192.168.103.100:6443"
imageRepository: registry.aliyuncs.com/google_containers
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"
etcd:
  local:
    dataDir: "/var/lib/etcd"
apiServer:
  certSANs:
  - "192.168.103.100"
  - "192.168.103.10"
  - "192.168.103.11"
  - "192.168.103.12"
  - "k8s-apiserver"
  - "k8s-master01"
  - "k8s-master02"
  - "k8s-master03"
  - "127.0.0.1"
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0"
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
maxPods: 110
EOF
```

### 2、预拉起镜像

```shell
kubeadm config images pull --config kubeadm-config.yaml
```

### 3、初始化核心命令

```shell
kubeadm init --config kubeadm-config.yaml --upload-certs
```

### 4、保存节点加入命令

- master

```shell
 kubeadm join 192.168.103.100:6443 --token c3k4n9.3xm9ccdi452a969s \
        --discovery-token-ca-cert-hash sha256:f5a4ccf2d4404d055e2f60a5e0d22f3380fa9b53f5f6687bc81f9c4fa9192db5 \
        --control-plane --certificate-key a23ad72bc592267b9f8a08e2e8200894b1bbf591b81caf0cf398934f5d496d15
```

- worker

```shell
kubeadm token create --print-join-command
```

```shell
kubeadm join 192.168.103.100:6443 --token c3k4n9.3xm9ccdi452a969s \
        --discovery-token-ca-cert-hash sha256:f5a4ccf2d4404d055e2f60a5e0d22f3380fa9b53f5f6687bc81f9c4fa9192db5
```

### 5、配置kubectl

```shell
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 6、安装 Calico 3.29.1 网络插件

```sheag-0-1jqibgmelag-1-1jqibgmel
wget https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml
```

- 修改镜像

```shell
kubectl apply -f calico.yaml
```

## 六、节点加入集群

### 1、清理残留

```shell
kubeadm reset -f --cri-socket unix:///var/run/cri-dockerd.sock
```

### 2、master加入集群

```shell
--cri-socket=unix:///var/run/cri-dockerd.sock
```

### 3、worker加入集群

```shell
--cri-socket=unix:///var/run/cri-dockerd.sock
```

### 4、移除master节点污点(可选)

```shell
kubectl taint nodes k8s-master01 node-role.kubernetes.io/control-plane-
kubectl taint nodes k8s-master02 node-role.kubernetes.io/control-plane-
kubectl taint nodes k8s-master03 node-role.kubernetes.io/control-plane-
```

### 5、指令补全

```shell
dnf install -y bash-completion
echo 'source <(kubectl completion bash)' >> /etc/bashrc
source /etc/bashrc
```

## 七、集群核心组件配置

### 1、安装 Metrics Server

#### 1）下载yaml

```shell
wget https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml
```

#### 2）修改配置-改镜像

```shell
sed -i '/args:/a \        - --kubelet-insecure-tls' components.yaml
```

#### 3）部署yaml

```shell
kubectl apply -f components.yaml
```

#### 4）验证

```shell
kubectl top nodes
kubectl top pods -A
```

### 2、Helm3 安装

```shell
 wget https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
 bash get-helm-3
 helm version
```

### 3、安装Headlamp-不好用

#### 1）下载yaml文件

```shell
wget  https://raw.githubusercontent.com/kubernetes-sigs/headlamp/main/kubernetes-headlamp.yaml
```

#### 2）修改yaml文件

```shell
apiVersion: v1
kind: Namespace
metadata:
  name: headlamp
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp-admin
  namespace: headlamp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: headlamp-admin
  namespace: headlamp
---
kind: Service
apiVersion: v1
metadata:
  name: headlamp
  namespace: headlamp
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: 4466
      nodePort: 30080
      name: http
    - port: 9090
      targetPort: 9090
      name: metrics
  selector:
    k8s-app: headlamp
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: headlamp
  namespace: headlamp
  labels:
    k8s-app: headlamp
spec:
  replicas: 3
  selector:
    matchLabels:
      k8s-app: headlamp
  template:
    metadata:
      labels:
        k8s-app: headlamp
    spec:
      serviceAccountName: headlamp-admin
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      nodeSelector:
        'kubernetes.io/os': linux
      containers:
        - name: headlamp
          image: ghcr.m.daocloud.io/headlamp-k8s/headlamp:v0.24.0
          args:
            - "-in-cluster"
            - "-plugins-dir=/headlamp/plugins"
          env:
            - name: HEADLAMP_CONFIG_METRICS_ENABLED
              value: "true"
            - name: HEADLAMP_CONFIG_SERVICE_NAME
              value: "headlamp"
            - name: HEADLAMP_CONFIG_SERVICE_VERSION
              value: "v0.24.0"
            - name: XDG_CONFIG_HOME
              value: /headlamp/plugins/.config
          ports:
            - containerPort: 4466
              name: http
            - containerPort: 9090
              name: metrics
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              scheme: HTTP
              path: /
              port: 4466
            initialDelaySeconds: 15
            timeoutSeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              scheme: HTTP
              path: /
              port: 4466
            initialDelaySeconds: 30
            timeoutSeconds: 5
            periodSeconds: 20
          volumeMounts:
            - name: plugins-storage
              mountPath: /headlamp/plugins
      volumes:
        - name: plugins-storage
          emptyDir: {}
```

#### 3）执行yaml

```yaml
kubectl apply -f kubernetes-headlamp.yaml
```

#### 5）生成token

```shell
kubectl create token headlamp-admin -n headlamp --duration=168h
```

### 4、安装Kuboard

#### 1）yaml部署-初始密码Kuboard123

```shell
# 1. 业务命名空间
apiVersion: v1
kind: Namespace
metadata:
  name: kuboard-v4
---
# 2. ConfigMap：数据库初始化建库脚本（修复SQL等号语法问题）
apiVersion: v1
kind: ConfigMap
metadata:
  name: mariadb-init-sql
  namespace: kuboard-v4
data:
  create_db.sql: |
    CREATE DATABASE kuboard DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;
    create user 'kuboard'@'%' identified by 'kuboardpwd';
    grant all privileges on kuboard.* to 'kuboard'@'%';
    FLUSH PRIVILEGES;
---
# 3. PVC 1：MariaDB 数据库数据持久存储
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-data-pvc
  namespace: kuboard-v4
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
# 4. PVC 2：Kuboard 日志持久存储
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kuboard-log-pvc
  namespace: kuboard-v4
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
# 5. MariaDB StatefulSet（清理冗余环境变量）
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
  namespace: kuboard-v4
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mariadb-db
  serviceName: db-headless
  template:
    metadata:
      labels:
        app: mariadb-db
    spec:
      containers:
      - name: mariadb
        image: swr.cn-east-2.myhuaweicloud.com/kuboard/mariadb:11.3.2-jammy
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "kuboardpwd"
        - name: TZ
          value: "Asia/Shanghai"
        ports:
        - containerPort: 3306
        volumeMounts:
        - name: init-sql-volume
          mountPath: /docker-entrypoint-initdb.d
        - name: data-volume
          mountPath: /var/lib/mysql
      volumes:
      - name: init-sql-volume
        configMap:
          name: mariadb-init-sql
      - name: data-volume
        persistentVolumeClaim:
          claimName: mariadb-data-pvc
---
# 6. 数据库 Headless Service
apiVersion: v1
kind: Service
metadata:
  name: db-headless
  namespace: kuboard-v4
spec:
  selector:
    app: mariadb-db
  ports:
  - port: 3306
    targetPort: 3306
  clusterIP: None
---
# 7. Kuboard Deployment（删除冗余 restartPolicy、重复JVM变量）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kuboard-v4
  namespace: kuboard-v4
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kuboard-web
  template:
    metadata:
      labels:
        app: kuboard-web
    spec:
      containers:
      - name: kuboard
        image: swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v4
        command: ["/bin/sh","-c"]
        args:
          - |
            echo "等待120秒，等待数据库就绪..."
            sleep 120
            echo "延时结束，启动 Kuboard 服务"
            java -Xmx2048M -jar /app/kuboard-server.jar
        env:
        - name: DB_DRIVER
          value: "org.mariadb.jdbc.Driver"
        - name: DB_URL
          value: "jdbc:mariadb://db-headless:3306/kuboard?serverTimezone=Asia/Shanghai"
        - name: DB_USERNAME
          value: "kuboard"
        - name: DB_PASSWORD
          value: "kuboardpwd"
        - name: TZ
          value: "Asia/Shanghai"
        ports:
        - containerPort: 80
        volumeMounts:
        - name: log-volume
          mountPath: /app/logs
      volumes:
      - name: log-volume
        persistentVolumeClaim:
          claimName: kuboard-log-pvc
---
# 8. Kuboard 外网访问 NodePort Service
apiVersion: v1
kind: Service
metadata:
  name: kuboard-svc
  namespace: kuboard-v4
spec:
  type: NodePort
  selector:
    app: kuboard-web
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
```

### 5、Kubernetes 动态持久化存储

#### 1）所有节点安装nfs客户端

```shell
dnf install -y nfs-utils
```

- nfs服务器搭建

```shell
mkdir -p /data/nfs
chmod 777 /data/nfs
echo "/data/nfs *(rw,sync,no_root_squash,no_subtree_check)" >> /etc/exports
systemctl enable --now rpcbind nfs-server
exportfs -a
```

#### 2）部署RBAC权限配置,StorageClass 存储类

- RBAC创建 K8s 权限控制资源，让 NFS 供应器有权限操作集群资源
- StorageClass定义一个名为 `nfs-client` 的存储类，告诉 K8s 什么样的 PVC 应该由这个 NFS 供应器处理

```shell
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/v4.0.2/deploy/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/v4.0.2/deploy/class.yaml
```

#### 3）下载并修改，替换nfs服务器，镜像

```shell
wget https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/v4.0.2/deploy/deployment.yaml
sed -i 's#server: 10.3.243.101#server: 192.168.103.11#' deployment.yaml
sed -i 's#value: 10.3.243.101#value: 192.168.103.11#' deployment.yaml  # 替换为你的 NFS 服务器 IP
sed -i 's#path: /ifs/kubernetes#path: /data/nfs#' deployment.yaml
sed -i 's#value: /ifs/kubernetes#value: /data/nfs#' deployment.yaml  # 替换为你的 NFS 共享路径
```

#### 4）部署

```shell
kubectl apply -f deployment.yaml
```

#### 5）设置存储类

```shell
kubectl patch storageclass managed-nfs-storage -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 6、Ingress Controller 高可用部署

#### 1）master节点打标签

```shell
kubectl label nodes k8s-master01 k8s-master02 k8s-master03 dedicated=ingress
```

#### 2）添加污点

```shell
kubectl taint nodes k8s-master01 k8s-master02 k8s-master03 dedicated=ingress:NoSchedule
```

#### 3）添加官方Helm仓库

```shell
# 添加 ingress-nginx 官方 Helm 仓库
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
# 更新仓库索引
helm repo update
```

#### 4）编写yaml文件 `values-ingress.yaml`

```yaml
# values-ingress.yaml
controller:
  # DaemonSet 模式：每个匹配标签的节点运行 1 个实例，天然实现多副本高可用
  kind: DaemonSet

  # 开启主机网络，直接占用节点 80/443 端口，性能更高，无需额外端口映射
  hostNetwork: true

  # hostNetwork 模式下必须配置，保证 Pod 可正常解析集群内部 DNS
  dnsPolicy: ClusterFirstWithHostNet

  # 节点选择器：仅调度到打了 dedicated=ingress 标签的 master 节点
  nodeSelector:
    dedicated: ingress

  # 污点容忍：匹配自定义污点 + master 节点默认控制平面污点
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "ingress"
      effect: "NoSchedule"
    # 兼容新版 K8s master 节点污点
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
    # 兼容旧版 K8s master 节点污点
    - key: "node-role.kubernetes.io/master"
      operator: "Exists"
      effect: "NoSchedule"

  # hostNetwork 模式下，Service 可设为 ClusterIP，直接通过节点 IP 访问
  service:
    type: ClusterIP
```

#### 5）创建命名空间

```shell
kubectl create namespace ingress-nginx
```

#### 6）Helm安装

- 能联网

```shell
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  -f values-ingress.yaml
```

- 不能联网

```shell
wget https://github.com/kubernetes/ingress-nginx/releases/download/helm-chart-4.15.1/ingress-nginx-4.15.1.tgz
```

- 改完镜像地址运行

```shell
helm install ingress-nginx ./ingress-nginx-4.15.1.tgz -n ingress-nginx -f values-ingress.yaml
```

#### 7）ingress样例

```shell
# =========================================================
# 文件名称：nginx-demo-ingress.yaml
# 功能说明：七层路由规则，将 demo.test.com 域名流量转发到 nginx-demo 服务
# 适用控制器：ingress-nginx
# =========================================================

apiVersion: networking.k8s.io/v1  # API版本：K8s 1.19+ 通用的 Ingress 稳定版API
kind: Ingress                     # 资源类型：Ingress 七层入口路由资源
metadata:                         # 元数据区块：定义资源的基础标识信息
  name: nginx-demo-ingress        # 资源名称：同命名空间内唯一，用于标识该路由规则
spec:                             # 规格区块：核心转发逻辑都定义在此处
  ingressClassName: nginx         # 控制器类：指定由 ingress-nginx 控制器处理该规则
  rules:                          # 路由规则列表：支持配置多组域名转发规则
    - host: demo.test.com         # 匹配域名：仅请求头 Host = demo.test.com 才命中此规则
      http:                       # 协议类型：该规则作用于 HTTP 协议
        paths:                    # 路径列表：同域名下可配置多个路径分流到不同后端
          - path: /               # 匹配路径：根路径，配合前缀匹配可覆盖所有请求
            pathType: Prefix      # 匹配类型：前缀匹配，按 / 分隔的路径元素做前缀匹配
            backend:              # 后端目标：路径匹配成功后，请求转发的目的地
              service:            # 后端类型：集群内部 Service 服务
                name: nginx-demo  # 服务名称：后端 Service 的名称，需与同命名空间下 Service 一致
                port:             # 端口配置：指定转发到 Service 的哪个端口
                  number: 80      # 端口号：后端 Service 暴露的具体端口号      number: 80
```

## 八、集群部署程序

### 1、harbor仓库

#### 1）Helm 部署-添加官方 Chart 源并拉取到本地

```shell
helm repo add harbor https://helm.goharbor.io
helm repo update
# 拉取chart包到本地，避免在线安装网络波动
helm pull harbor/harbor --untar
```

#### 2）修改values.yaml改镜像源

- 改镜像
  
- 改ingress
  

```yaml
31 core: k8s.harbor.com #改网页打开地址
121 externalURL: https://k8s.harbor.com 
41 className: "nginx" #改成ingress名称可用 kubectl get ingressclass 查看
```

- 改persistence

```shell
149/157/166/175/182 storageClass: "managed-nfs-storage" #添加sc名称
152/160/169/178/185 size: 1Gi #大小按实际情况修改
```

```shell
registry.size：5Gi → 50Gi（存镜像核心，给大一点）
jobservice.jobLog.size：1Gi → 10Gi
database.size：1Gi → 20Gi
redis.size：1Gi → 10Gi
trivy.size：5Gi → 10Gi
```

- harborAdminPassword - 查看密码，也可用修改
  
- trivy: - enabled: true改成enabled: false -关闭容器镜像漏洞扫描工具
  
- skipUpdate: false改成true - 关闭更新
  

#### 3）安装harbor

```shell
kubectl create ns harbor
helm install harbor . -n harbor -f values.yaml
```

#### 4）部署完成查看状态

```shell
# 查看所有Pod运行状态（全部Running即为正常）
watch kubectl get pods -n harbor

# 查看PVC自动绑定NFS存储
kubectl get pvc -n harbor

# 查看Ingress规则
kubectl get ingress -n harbor
```

#### 5）所有节点 Docker 信任 Harbor 自签证书

- 导出harbor证书

```shell
kubectl get secret harbor-ingress -n harbor -o jsonpath="{.data.tls\.crt}" | base64 -d > harbor.crt
```

- 分发证书

```shell
scp harbor.crt root@192.168.103.20:/root/
```

- 添加信任证书 - 注意替换到实际域名 每个节点都要执行

```shell
mkdir -p /etc/docker/certs.d/k8s.harbor.com
cp harbor.crt /etc/docker/certs.d/k8s.harbor.com/ca.crt
systemctl restart docker
```

#### 6）创建密钥

```shell
kubectl create secret docker-registry harbor-secret \
-n harbor \
--docker-server=k8s.harbor.com \
--docker-username=admin \
--docker-password=Wej.1234
```

## 九、普罗米修斯

1、下载git

```shell
dnf install -y git
```

2、拉取git仓库

```shell
git clone https://github.com/coreos/kube-prometheus.git
```

3、切换分支-根据实际情况切换-[GitHub - prometheus-operator/kube-prometheus: Use Prometheus to monitor Kubernetes and applications running on Kubernetes · GitHub](https://github.com/prometheus-operator/kube-prometheus)

```shell
git checkout main
```

4、修改镜像

![](file://D:\user\zm\AI学习资料\三主六从k8s搭建\2026-06-23-10-38-31-image.png?msec=1782698295088)

5、cat /var/lib/kubelet/config.yaml 确认环境正常

6、部署 CRD + monitoring 命名空间

```shell
kubectl apply --server-side -f manifests/setup
```

7、部署全套监控组件

```shell
kubectl apply -f manifests/
```

8、等待全部pod启动，创建Grafana的ingress
