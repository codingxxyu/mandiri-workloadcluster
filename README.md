# Mandiri Bare Metal Workload Cluster

本项目继续完成已经启动的 `olvm-workloadcluster` 裸金属业务集群。YAML 按角色分目录，步骤都在本文。控制面 Ready 之后再做 Worker。Worker 不要复用控制面那张 ISO。

| 目录 | 文件 |
|---|---|
| [`control-plane/manifests/`](control-plane/manifests/) | 控制面 Registration、Pool、BaremetalCluster、Cluster、KCP |
| [`worker/manifests/`](worker/manifests/) | Worker Registration、Pool、MachineTemplate、KubeadmConfigTemplate、MachineDeployment |

```text
ACP:            v4.3.2
Kubernetes:     v1.34.5-3
etcd:           v3.5.28-260625
containerd:     2.2.1-5
coredns:        1.14.2-v4.3.11
pause:          3.10
kube-ovn chart: v4.3.11
OS image tag:   v4.3.2-1-1.34.5-3
Registry:       10.243.166.5:11443
API VIP:        10.243.166.12:6443
namespace:      cpaas-system
```

所有命令在 **Global Master 01** 上执行（`kubectl` 已连 Global，不写 kubeconfig 路径），除非步骤标明 BMC / 物理机 / LB。不使用脚本或渲染。YAML 里还有 `<...>` 就不要 apply。

```bash
hostname
kubectl config current-context
kubectl cluster-info
export BM_NS=cpaas-system
export CLUSTER_NAME=olvm-workloadcluster
```

`hostname` 必须是 `global-master01`。

---

## 控制面

三台 Master 已从 SeedImage 注册。正常续接从第 4 步开始。`01` 只有重建 Registration/ISO 时才再 apply。

### 1. Image Catalog

```bash
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
```

需要有：

```yaml
data:
  v1.34.5-3: 10.243.166.5:11443/tkestack/baremetal-base-image:v4.3.2-1-1.34.5-3
```

没有就 merge patch，不要覆盖其它 key。

### 2. 控制面 Registration / SeedImage

文件：`control-plane/manifests/01-registration-seedimage.yaml`

现场已 apply，资源名：

```text
olvm-workloadcluster-registration
olvm-workloadcluster-registration-iso
```

`device` 推荐写成通用路径，做 ISO 时不要改成 `/dev/sda`：

```yaml
spec:
  config:
    elemental:
      install:
        device: /dev/elemental-install-target   # 推荐：通用路径，写进 ISO
        eject-cd: true
        reboot: true
```

真实盘符不要写进 YAML。每台节点 Live ISO 起来后，把本机系统盘软链接到这个路径，安装重启后再把 BMC 启动项改成从磁盘启动。见第 3 步。

只有重建 ISO 时才：

```bash
kubectl apply --dry-run=server -f control-plane/manifests/01-registration-seedimage.yaml
kubectl apply -f control-plane/manifests/01-registration-seedimage.yaml
kubectl -n cpaas-system describe seedimage olvm-workloadcluster-registration-iso
```

`SeedImageReady=True` 后再挂 ISO。不要用这张 ISO 装 Worker。

### 3. [每台 Master Live ISO] 指定系统盘并设定从磁盘启动

YAML 不写真实盘符。Live ISO 控制台：

```bash
lsblk -d -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,HCTL
ln -s /dev/sda /dev/elemental-install-target   # /dev/sda 换成 lsblk 确认的系统盘
readlink -f /dev/elemental-install-target
```

不要链到数据盘、`sr*`、`loop*`。盘序可能对调时，源改成 `/dev/disk/by-id/wwn-*`。链接只活在当前 Live 会话。

已装好并离开 Live ISO 的三台 Master 不要再回 Live 重建链接。硬盘已有旧系统时见第 9.2 节。

安装触发重启后，在 BMC 上：

1. 弹出/卸载 SeedImage 虚拟介质。
2. 把启动顺序改成 **disk-first**，不要继续从虚拟光驱启动。
3. 确认下一次进入已安装 OS，不是再次进入 Live ISO。

### 4. [三台 Master] 确认已从系统盘启动

```bash
hostname
findmnt -n -o SOURCE,FSTYPE,TARGET /
findmnt /run/initramfs/live || echo NO_LIVE_ISO_ROOT
lsblk -e7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
```

`/` 不能是 `LiveOS_rootfs`；要能看到 `COS_STATE` 等分区。仍是 Live ISO 就停止，不要加入 Pool。

### 5. 检查三台 Inventory

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
```

现场三台：

```text
olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62   # cpw01
olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137   # cpw02
olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12   # cpw03
```

每台：`Ready=True`，allocation 为空或 `Available`，owner 为空，已从系统盘启动。

### 6. Control Plane Pool

文件：`control-plane/manifests/02-control-plane-pool.yaml`

已按现场填好，一般不用改：

```yaml
spec:
  clusterName: olvm-workloadcluster
  machineInventories:
    - name: olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
      hostname: olvm-workloadcluster-cpw01
      networkDevice: eth0          # 某台不是 eth0 时只改那一台
    - name: olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137
      hostname: olvm-workloadcluster-cpw02
      networkDevice: eth0
    - name: olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12
      hostname: olvm-workloadcluster-cpw03
      networkDevice: eth0
```

```bash
grep -nE '<[^>]+>|填写实际' control-plane/manifests/02-control-plane-pool.yaml
kubectl apply --dry-run=server -f control-plane/manifests/02-control-plane-pool.yaml
kubectl apply -f control-plane/manifests/02-control-plane-pool.yaml
kubectl -n cpaas-system get machineinventorypool olvm-workloadcluster-control-plane-pool -o yaml
```

要求 Pool Ready/MembersValid，available ≥ 3。

### 7. BaremetalCluster

文件：`control-plane/manifests/03-baremetal-cluster.yaml`

已按现场填好：

```yaml
spec:
  networkType: kube-ovn
  networkDevice: eth0             # 集群默认 CNI；Worker VLAN 不要改这里
  controlPlaneLoadBalancer:
    type: External
    host: 10.243.166.12           # 客户 External LB VIP
    port: 6443
```

[LB 管理端] 核对：`10.243.166.12:6443` TCP passthrough → 三台 Master `:6443`。

```bash
kubectl apply --dry-run=server -f control-plane/manifests/03-baremetal-cluster.yaml
kubectl apply -f control-plane/manifests/03-baremetal-cluster.yaml
```

### 8. Control Plane MachineTemplate

文件：`control-plane/manifests/04-control-plane-machine-template.yaml`

已指向 `olvm-workloadcluster-control-plane-pool`，不用改。

```bash
kubectl apply --dry-run=server -f control-plane/manifests/04-control-plane-machine-template.yaml
kubectl apply -f control-plane/manifests/04-control-plane-machine-template.yaml
```

### 控制面 Cluster

文件：`control-plane/manifests/05-cluster.yaml`

已按现场填好，确认这几项即可：

```yaml
metadata:
  name: olvm-workloadcluster
  labels:
    cluster-type: ProviderBaremetal
  annotations:
    cpaas.io/kube-ovn-join-cidr: 100.15.0.0/16
    cpaas.io/kube-ovn-version: v4.3.11
    cpaas.io/registry-address: 10.243.166.5:11443
spec:
  clusterNetwork:
    pods:
      cidrBlocks: [100.13.0.0/16]
    services:
      cidrBlocks: [100.14.0.0/16]
```

三个 CIDR 不要和 Global / 其它 Workload 冲突。overlay，不要加 underlay annotation。

```bash
kubectl apply --dry-run=server -f control-plane/manifests/05-cluster.yaml
kubectl apply -f control-plane/manifests/05-cluster.yaml
```

### 控制面 KubeadmControlPlane

文件：`control-plane/manifests/06-control-plane.yaml`

只改这一处：

```yaml
sshAuthorizedKeys:
  - "<ssh-authorized-keys>"       # 换成真实公钥（Global Master 01 `/root/.ssh/*.pub` 完整一行）
```

版本已按 ACP 4.3.2 填好，不要改：

```yaml
spec:
  replicas: 3
  version: v1.34.5-3
  kubeadmConfigSpec:
    clusterConfiguration:
      dns:
        imageTag: 1.14.2-v4.3.11
      etcd:
        local:
          imageTag: v3.5.28-260625
```

```bash
grep -nE '<[^>]+>|填写实际' control-plane/manifests/06-control-plane.yaml
kubectl apply --dry-run=server -f control-plane/manifests/06-control-plane.yaml
kubectl apply -f control-plane/manifests/06-control-plane.yaml
```

还有 `<...>` 就停止。

### 等待控制面 Ready

```bash
kubectl -n cpaas-system get baremetalcluster,cluster,kubeadmcontrolplane,machine,baremetalmachine
kubectl -n cpaas-system get events --sort-by=.lastTimestamp
kubectl -n cpaas-system get secret olvm-workloadcluster-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
```

期待：BaremetalCluster Ready；三台 Inventory 已分配；KCP replicas=3；三台 Master Node Ready。此时 Node 列表只有控制面是正常的。然后再走下面的 Worker。

---

## Worker

官方：[Worker Node Deployment](https://docs.alauda.cn/immutable-infra/1.0/manage-nodes/bare-metal.html#worker-node-deployment)

每个集群默认 1 台 Worker。必须用 Worker 自己的 Registration/ISO。不要改 `BaremetalCluster.spec.networkDevice`（Master 继续 `eth0`）。

先确认控制面已经起来：

```bash
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
kubectl -n cpaas-system get kubeadmcontrolplane olvm-workloadcluster-control-plane
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
```

三台 Master Ready；catalog 有 `v1.34.5-3`。

### Worker 1. Registration / SeedImage

文件：`worker/manifests/01-registration-seedimage.yaml`

一般不用改。确认这两处即可：

```yaml
# MachineRegistration
spec:
  config:
    elemental:
      install:
        device: /dev/elemental-install-target   # 推荐：通用路径，写进 ISO
```

```yaml
# SeedImage
spec:
  baseImage: 10.243.166.5:11443/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3
```

真实盘符不要写进 YAML。每台 Worker Live ISO 起来后，把本机系统盘软链接到这个路径，安装重启后再把 BMC 启动项改成从磁盘启动。不要改 `${System Information/UUID}` 这类 Elemental 表达式。

```bash
grep -nE '<[^>]+>|填写实际' worker/manifests/01-registration-seedimage.yaml
kubectl apply --dry-run=server -f worker/manifests/01-registration-seedimage.yaml
kubectl apply -f worker/manifests/01-registration-seedimage.yaml
kubectl -n cpaas-system describe seedimage olvm-workloadcluster-worker-registration-iso
```

`SeedImageReady=True` 后再下载 ISO、挂到这台 Worker 的虚拟光驱。

### Worker 2. [BMC + Live ISO] 指定系统盘、VLAN、设定从磁盘启动

1. BMC 挂 Worker ISO，从虚拟光驱进 Live ISO。
2. 认盘并软链接（`/dev/sda` 换成 `lsblk` 确认的系统盘）：

```bash
lsblk -d -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,HCTL
ln -s /dev/sda /dev/elemental-install-target
readlink -f /dev/elemental-install-target
```

硬盘已有旧系统时见第 9.2 节。

3. **先配 VLAN，再让主机注册。** IP 配在 `eth0.329`，不要配在 `eth0`。不要用 VIP `10.243.166.12`。默认网卡/默认 IP 配不上见第 9.1 节。

```bash
sudo nmcli con add type vlan ifname eth0.329 con-name vlan329 \
  dev eth0 id 329
sudo nmcli con mod vlan329 \
  ipv4.method manual \
  ipv4.addresses 10.243.166.6/26 \     # 占用则换同网段空闲地址
  ipv4.gateway 10.243.166.1 \
  ipv4.dns 10.243.132.38 \
  ipv6.method ignore
sudo nmcli con up vlan329
ping -c 3 10.243.166.1
ip -br addr show eth0.329
```

`networkDevice` 填接口名 `eth0.329`，不要填 connection 名 `vlan329`。

4. 等安装自动重启后，在 BMC 上弹出 ISO，把启动顺序改成 **disk-first**。
5. 登录已安装系统确认不是 Live ISO，能看到 `COS_STATE` 等分区。

### Worker 3. 检查 Inventory

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
```

名字由 Elemental 生成，形如 `olvm-workloadcluster-worker-<UUID>`。必须 `Ready=True`、已从系统盘启动、allocation 为空或 `Available`。

把真实名字记下来，替换下面的 `<actual-worker-inventory-1>`。

### Worker 4. Pool

文件：`worker/manifests/02-worker-pool.yaml`

只改这一台的真实 Inventory 名；VLAN 接口名以 `observedNetwork` 为准：

```yaml
spec:
  clusterName: olvm-workloadcluster
  machineInventories:
    - name: <actual-worker-inventory-1>     # 换成上一步查到的真实名字
      hostname: olvm-workloadcluster-worker01
      networkDevice: eth0.329               # observedNetwork 不是这个名字时只改这一台
```

```bash
grep -nE '<[^>]+>|填写实际' worker/manifests/02-worker-pool.yaml
kubectl apply --dry-run=server -f worker/manifests/02-worker-pool.yaml
kubectl apply -f worker/manifests/02-worker-pool.yaml
kubectl -n cpaas-system get machineinventorypool olvm-workloadcluster-worker-pool
```

要求 `status.available ≥ 1`。名字还是占位就不要 apply。

### Worker 5. MachineTemplate

文件：`worker/manifests/03-worker-machine-template.yaml`

已指向 `olvm-workloadcluster-worker-pool`，不用改。

```bash
kubectl apply --dry-run=server -f worker/manifests/03-worker-machine-template.yaml
kubectl apply -f worker/manifests/03-worker-machine-template.yaml
```

这个模板创建后，pool 引用视为不可变。要换 Pool 必须新建模板名字。

### Worker 6. Bootstrap

文件：`worker/manifests/04-worker-kubeadm-config-template.yaml`

只改这一处：

```yaml
sshAuthorizedKeys:
  - "<ssh-authorized-keys>"       # 换成真实公钥（与控制面 KCP 同一把）
```

不要预填 hostname、`provider-id`、`criSocket`。`node-labels: kube-ovn/role=worker` 保留。

```bash
grep -nE '<[^>]+>|填写实际|provider-id' worker/manifests/04-worker-kubeadm-config-template.yaml
kubectl apply --dry-run=server -f worker/manifests/04-worker-kubeadm-config-template.yaml
kubectl apply -f worker/manifests/04-worker-kubeadm-config-template.yaml
```

还有 `<...>` 就停止。

### Worker 7. MachineDeployment

文件：`worker/manifests/05-worker-machine-deployment.yaml`

已按官方填好，一般不用改：

```yaml
spec:
  clusterName: olvm-workloadcluster
  replicas: 1                       # 加第二台时再提高，且 ≤ pool available+allocated
  version: v1.34.5-3
  strategy:
    rollingUpdate:
      maxSurge: 0                   # 裸金属不能超配
      maxUnavailable: 1
```

```bash
grep -nE '<[^>]+>|填写实际' worker/manifests/05-worker-machine-deployment.yaml
kubectl apply --dry-run=server -f worker/manifests/05-worker-machine-deployment.yaml
kubectl apply -f worker/manifests/05-worker-machine-deployment.yaml
kubectl -n cpaas-system get machinedeployments.cluster.x-k8s.io
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
```

期待：1 台 Worker Node Ready，带 `kube-ovn/role=worker`。

---

## 9. 常见问题

### 9.1 默认网卡 / 默认 IP 配不上，网卡要带 VLAN

**现象：** 客户给的不是裸 `eth0` 和普通静态 IP。Live ISO 上若把 IP 配在 `eth0`，或没建 VLAN 接口，注册后 `observedNetwork` 对不上，Pool 的 `networkDevice: eth0.329` 也无法作为 CNI 网卡。

**适用：** **[Worker BMC Console]**，Live ISO 起来后、Elemental 安装开始前。Master 已经按 `eth0` 跑了，不要改 `BaremetalCluster.spec.networkDevice`。VLAN 写在主机 NetworkManager 上，不写进 Registration YAML。

**可以做：** 只在物理口 `eth0` 上建 VLAN 329，接口名 `eth0.329`，静态 IPv4 配在这个 VLAN 口上。下面是现场跑通的参考；地址、DNS 按这台机器改，不要原样抄到另一台。

**不要做：**

- 不要把 IP 配在 `eth0` 上。
- 不要把 connection 名 `vlan329` 填进 Pool 的 `networkDevice`；填接口名 `eth0.329`。
- 不要用 VIP `10.243.166.12`。
- 交换机没有把 eth0/eth1 绑成一组时，不要走 `bond0.329`。
- 不要对 `sr*`、`loop*` 动手。

```bash
# 如果上次误建了 bond，先拆掉，再配单网卡 VLAN
sudo nmcli con down vlan329 2>/dev/null || true
sudo nmcli con down bond0 2>/dev/null || true
sudo nmcli con delete vlan329 bond0 bond0-port1 bond0-port2 2>/dev/null || true

# 只在 eth0 上做 VLAN 329；IP 必须在 eth0.329，不是 eth0
sudo nmcli con add type vlan ifname eth0.329 con-name vlan329 \
  dev eth0 id 329

sudo nmcli con mod vlan329 \
  ipv4.method manual \
  ipv4.addresses 10.243.166.31/26 \
  ipv4.gateway 10.243.166.1 \
  ipv4.dns 8.8.8.8 \
  ipv6.method ignore

sudo nmcli con up vlan329
ping -c 3 10.243.166.1
ip -br addr show eth0.329
ls /etc/NetworkManager/system-connections/
nmcli -f NAME,UUID,TYPE,DEVICE,FILENAME connection show
```

成功标准：`eth0.329` 有这台机器的地址；能 ping 通网关 `10.243.166.1`；`FILENAME` 指向磁盘上的 `*.nmconnection`，不能只在 `/run/NetworkManager/system-connections/`。然后再让主机注册。安装触发重启后弹出 ISO，启动顺序改成 disk-first。

Pool 写入时 `networkDevice` 填 `eth0.329`。先看 Inventory 的 `observedNetwork.interfaces` / `connections`，接口名不是 `eth0.329` 时只改那一台。

Worker 第 2 步默认地址是节点表上的 `10.243.166.6/26`、DNS `10.243.132.38`。上面这组 `10.243.166.31/26`、DNS `8.8.8.8` 是现场另一台跑通时的值，只作参考。

单口 `eth0` 交换机不放行、两口已被绑成一组时，改用 bond + VLAN（现场常见 **active-backup，不是 LACP**）。IP 仍配在 VLAN 上，不要配在 `eth0` / `bond0`：

```bash
sudo nmcli con add type bond ifname bond0 con-name bond0 \
  mode active-backup miimon 100
sudo nmcli con add type ethernet ifname eth0 con-name bond0-port1 master bond0
sudo nmcli con add type ethernet ifname eth1 con-name bond0-port2 master bond0
sudo nmcli con add type vlan ifname bond0.329 con-name vlan329 \
  dev bond0 id 329
sudo nmcli con mod vlan329 \
  ipv4.method manual \
  ipv4.addresses 10.243.166.6/26 \
  ipv4.gateway 10.243.166.1 \
  ipv4.dns 10.243.132.38 \
  ipv6.method ignore
sudo nmcli con up bond0
sudo nmcli con up vlan329
ping -c 3 10.243.166.1
```

这时 Worker Pool 这一台改成 `networkDevice: bond0.329`。不要写 `eth0`、`eth1` 或 `bond0`：前两个是 slave，会报 `NetworkDeviceIsSlave`；`bond0` 没有节点地址。Master 的 `BaremetalCluster` / 控制面 Pool 仍然是 `eth0`。

### 9.2 物理机硬盘上已有旧操作系统

**现象：** 硬盘上已经有旧系统（分区、`EFI` / `ROOT` / `COS_*` 标签还在）。Live ISO 里 Elemental 选盘失败、装到错误设备，或旧分区标签干扰重装。

**适用：** Live ISO 控制台，还没有开始 Elemental 安装。Master 和 Worker 都可能遇到。本例真实盘是 `sda`。

**不要做：** 不要对 `sr*`、`loop*` 做 wipe/format。`MachineRegistration` 里的 `install.device` 永远是 `/dev/elemental-install-target`，不要改成 `/dev/sda`。这里的 `/dev/sda` 只是这台 Live ISO 上 `lsblk` 确认后的真实盘名。

```bash
lsblk
mount | grep sda || true
umount /dev/sda3 /dev/sda2 /dev/sda1 2>/dev/null || true
wipefs -a /dev/sda
sgdisk -Z /dev/sda
partprobe /dev/sda
lsblk
blkid
```

清完后 `sda` 应该没有分区，`blkid` 里也不该再看到 `EFI` / `ROOT` / `COS_*`。然后再把本机系统盘软链接到 `/dev/elemental-install-target`。安装重启后弹出 ISO，启动顺序改成 disk-first。

### 9.3 需要单独规划磁盘（例如 `/data`）

本项目不包含存储 YAML。系统盘只走 ISO 通用路径 `/dev/elemental-install-target`，见第 2 步和第 3 步。

- **不需要**单独规划数据盘：什么都不用做。不要在 `MachineInventory.spec.storage` 里声明额外磁盘。
- **需要**把一块独立磁盘挂到额外目录（例如 `/data`，或根下其它路径）：按官方存储规划，在对应 `MachineInventory` 上配置：

<https://docs.alauda.cn/immutable-infra/1.0/how-to/manage-bare-metal-storage.html>
