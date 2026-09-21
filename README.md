# Mandiri Bare Metal Workload Cluster

本项目继续完成已经启动的 `olvm-workloadcluster` 裸金属业务集群部署。

## 当前状态

版本以官方 OS 支持矩阵为准（ACP `v4.3.2`）：

```text
ACP:            v4.3.2
Kubernetes:     v1.34.5-3
etcd:           v3.5.28-260625
containerd:     2.2.1-5
coredns:        1.14.2-v4.3.11
pause:          3.10
kube-ovn chart: v4.3.11
OS image tag:   v4.3.2-1-1.34.5-3
```

已完成：

- 现有 Global 集群可用；
- Bare Metal Provider/Elemental 已用于生成 SeedImage；
- ACP 4.3.2 配套 Bare Metal OS 镜像已导入；
- 三台 Master 物理机已从 SeedImage 启动并注册为 `MachineInventory`：

```text
olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137
olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12
olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
```

磁盘规划（研发确认口径）：

```text
部署阶段只规划系统盘。
多盘主机用 /dev/elemental-install-target 固定系统盘 WWN。
额外数据盘不在 MachineInventory.spec.storage 里提前声明。
集群 Ready 后，再登录节点手工挂载数据盘。
后续 OS/集群升级不依赖这块数据盘规划。
```

> 重要：所有部署操作均按本文逐步手工执行，不依赖任何辅助脚本。现场真实 Registry 和 SSH 公钥必须先按本文命令取得，再直接编辑对应 YAML。External LB VIP 已确定为 `10.243.166.12`。未完成第 13 节检查前禁止 apply。

## 1. 执行位置和责任矩阵

本文所有命令都明确标注执行位置：

| 标记 | 在哪里执行 | 用途 |
|---|---|---|
| **[Global Master 01]** | `global-master01`，当前 `kubectl` 已连接 Global | 查询/修改 Kubernetes 资源、检查 MachineInventory、apply 集群 YAML |
| **[三台 Master 都执行]** | 三台已注册的裸金属 Master 本机/BMC Console | 核对 ISO 已弹出、从系统盘启动、系统盘挂载正常；集群 Ready 后再手工挂数据盘 |
| **[Worker BMC Console]** | 本集群默认 1 台 Worker 的 IPMI/串口，Live ISO 控制台 | 安装前在 eth0 上建 VLAN 329、配静态地址（参考 `10.243.166.6/26`，占用则换空闲地址）、DNS `10.243.132.38`、确认能 ping 网关 |
| **[LB 管理端]** | 客户负载均衡器管理界面 | 核对 External LB VIP `10.243.166.12`、TCP 6443 listener 和三台 Master 后端 |
| **[Workload kubeconfig]** | Global Master 01，但显式使用生成的 `workload-kubeconfig` | 检查业务集群 Node/Pod |

### 1.1 在 Global Master 01 执行

```bash
hostname
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide

export BM_NS=cpaas-system
export CLUSTER_NAME=olvm-workloadcluster
export ACP_VERSION=v4.3.2
export KUBERNETES_VERSION=v1.34.5-3
export ETCD_VERSION=v3.5.28-260625
export OS_IMAGE_TAG=v4.3.2-1-1.34.5-3
```

`hostname` 必须确认当前是 `global-master01`；`kubectl cluster-info` 必须指向现有 Global。本文不需要额外 kubeconfig 路径。

读取 Global Registry。现场已确认是 `10.243.166.5:11443`：

```bash
export GLOBAL_REGISTRY="$(kubectl -n cpaas-system get cluster global \
  -o jsonpath='{.metadata.annotations.cpaas\.io/registry-address}')"
export BASE_IMAGE=${GLOBAL_REGISTRY}/tkestack/baremetal-base-image:${OS_IMAGE_TAG}
export BASE_IMAGE_ISO=${GLOBAL_REGISTRY}/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG}
printf 'GLOBAL_REGISTRY=%s\n' "${GLOBAL_REGISTRY}"
```

输出必须是 `10.243.166.5:11443`。为空或不是这个地址，停止执行，先确认 Global 的实际 Registry 配置。

### 1.2 在 LB 管理端完成

本方案选择 **External LB**。现场已经配置 Workload API VIP `10.243.166.12` 和 TCP 6443 转发：

```text
Protocol: TCP passthrough
Frontend: 10.243.166.12:6443
Backends: 三台裸金属 Master 的节点 IP:6443
```

如果后续需要使用 FQDN，可另行创建 FQDN 到 `10.243.166.12` 的 DNS 解析；本次部署直接使用 VIP，不依赖 DNS。部署时在 Global Master 01 记录该入口：

```bash
export WORKLOAD_API_ENDPOINT='10.243.166.12'
```

后续 `BaremetalCluster` 和连通性检查均使用该 VIP。

### 1.3 Global Master 01 上的 SSH 公钥

使用已有公钥：

```bash
export SSH_PUBLIC_KEY_FILE="$(find /root/.ssh -maxdepth 1 -type f -name '*.pub' -print -quit)"
test -n "${SSH_PUBLIC_KEY_FILE}" || { echo '没有找到 /root/.ssh/*.pub'; exit 1; }
export SSH_PUBLIC_KEY="$(tr -d '\n' < "${SSH_PUBLIC_KEY_FILE}")"
printf 'SSH_PUBLIC_KEY_FILE=%s\n' "${SSH_PUBLIC_KEY_FILE}"
```

### 1.4 手工填写 YAML 的规则

本项目不使用渲染或部署脚本。所有修改都在 **Global Master 01** 上手工完成，并在 apply 前逐个检查。

先记录后续要写入 YAML 的现场值：

```bash
printf 'Global Registry: %s\n' "${GLOBAL_REGISTRY}"
printf 'SSH public key file: %s\n' "${SSH_PUBLIC_KEY_FILE}"
printf 'Workload API VIP: 10.243.166.12\n'
```

需要手工修改的文件和字段：

| 文件 | 要修改或确认的字段 | 值的来源 |
|---|---|---|
| `manifests/01-workload-registration-seedimage.yaml` | `SeedImage.spec.baseImage` | 已填写 `10.243.166.5:11443/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3`。现场资源名是 `olvm-workloadcluster-registration` / `olvm-workloadcluster-registration-iso` |
| `manifests/02-workload-control-plane-pool.yaml` | `spec.machineInventories[]` | 已填三台真实 Inventory、`hostname`（`cpw01`–`cpw03`）和 `networkDevice: eth0` |
| `manifests/03-workload-baremetal-cluster.yaml` | `spec.controlPlaneLoadBalancer.host` | 已填写 `10.243.166.12` |
| `manifests/03-workload-baremetal-cluster.yaml` | `spec.networkType` / `spec.networkDevice` | 已填写 `kube-ovn` / `eth0`。集群默认 CNI 网卡；只在全员都换网卡时改这里 |
| `manifests/04-workload-control-plane-machine-template.yaml` | `metadata.name` | 现场名 `olvm-workloadcluster-control-plane-template` |
| `manifests/05-workload-cluster.yaml` | `metadata.annotations.cpaas.io/registry-address` | 已填写 `10.243.166.5:11443` |
| `manifests/06-workload-control-plane.yaml` | `sshAuthorizedKeys` | `${SSH_PUBLIC_KEY}` 的实际完整输出 |
| `manifests/06-workload-control-plane.yaml` | `machineTemplate.infrastructureRef.name` | 已指向 `olvm-workloadcluster-control-plane-template` |
| `manifests/07-worker-registration-seedimage.yaml` | `SeedImage.spec.baseImage` | 已填写与 `01` 相同的 ISO 地址。Worker 必须用自己的 Registration/SeedImage，不要复用 Master 那套 |
| `manifests/08-worker-pool.yaml` | `spec.machineInventories[].name` | Worker 物理机注册后出现的真实 `MachineInventory` 名字 |
| `manifests/08-worker-pool.yaml` | `spec.machineInventories[].hostname` | 默认 `olvm-workloadcluster-worker01` |
| `manifests/08-worker-pool.yaml` | `spec.machineInventories[].networkDevice` | Worker 默认 `eth0.329`（VLAN 329 在 eth0 上，不是 bond）。现场 `observedNetwork` 名字不同时只改这一台 |
| `manifests/10-worker-kubeadm-config-template.yaml` | `sshAuthorizedKeys` | 与 KCP 相同的 `${SSH_PUBLIC_KEY}` |
| 多盘主机系统盘 | Live ISO 上的 `/dev/elemental-install-target` | 该主机系统盘的 `/dev/disk/by-id/wwn-*` |

在 Global Master 01 上使用 `vi` 或 `vim` 逐个编辑，例如：

```bash
vi manifests/05-workload-cluster.yaml
vi manifests/06-workload-control-plane.yaml
```

编辑时把实际文本写进 YAML，不要把 `${GLOBAL_REGISTRY}`、`${SSH_PUBLIC_KEY}` 这些 shell 变量名写进 YAML。保存后逐个检查：

```bash
kubectl apply --dry-run=server -f manifests/05-workload-cluster.yaml
kubectl apply --dry-run=server -f manifests/06-workload-control-plane.yaml
```

`01` 是已经完成注册时使用的定义；只有在现场需要重建 Registration/SeedImage 时才 apply。当前三台 Master 已注册，正常续接部署不重复 apply `01`。

## 2. 先确认 Image Catalog

```bash
kubectl \
  -n cpaas-system get configmap elemental-image-catalog -o yaml
```

应有：

```yaml
data:
  v1.34.5-3: 10.243.166.5:11443/tkestack/baremetal-base-image:v4.3.2-1-1.34.5-3
```

如果没有，使用 merge patch，保留已有版本：

```bash
kubectl \
  -n cpaas-system patch configmap elemental-image-catalog \
  --type merge \
  -p "{\"data\":{\"${KUBERNETES_VERSION}\":\"${BASE_IMAGE}\"}}"
```

`elemental-image-catalog` 使用 `base-image`；SeedImage 使用 `base-image-iso`。

## 3. SeedImage 安装后必须检查 OS 是否正常

三台 Master 已经从 SeedImage 安装并注册。加入 Pool 前，先确认每台机器已经离开 Live ISO，并从系统盘正常启动。

现场常见坑：ISO 没弹出、启动项仍指向虚拟光驱、或 Inventory 上看不到正常磁盘布局。这类主机不要加入 Pool。

### 3.1 [BMC] 安装触发重启后立即处理启动项

每台物理机安装完成后会 reboot。在 BMC/iDRAC/iLO 上逐台执行：

1. 弹出/卸载 SeedImage 虚拟介质（虚拟 CD/ISO）。
2. 把启动顺序改回 disk-first，不要继续从虚拟光驱启动。
3. 确认下一次启动进入已安装的 Alauda OS，而不是再次进入 Live ISO。

不要在仍挂着 ISO 的情况下检查 MachineInventory 是否 Ready。

### 3.2 [三台 Master 都执行] 确认已经不是 Live ISO

登录已安装系统，不要登录 Live ISO 控制台：

```bash
hostname
findmnt -n -o SOURCE,FSTYPE,TARGET /
findmnt /run/initramfs/live || echo NO_LIVE_ISO_ROOT
lsblk -e7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
```

必须同时满足：

- `/` 不是 `LiveOS_rootfs`。
- 没有 `/run/initramfs/live` 这类 Live ISO root。
- 虚拟光驱（常见 `/dev/sr0`）上不应再挂着 `COS_LIVE` 作为当前运行系统。
- 系统盘上能看到 Elemental 分区布局，例如 `COS_STATE` / `COS_OEM` / `COS_RECOVERY` / `COS_PERSISTENT`。
- 额外数据盘可以存在，但这一步不要格式化，也不要挂到业务路径。

如果 `/` 仍是 Live ISO，停止。回到 BMC 弹出 ISO，改启动项，再重启。

### 3.3 [Global Master 01] 检查 MachineInventory

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide

for inventory in \
  olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137 \
  olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12 \
  olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
do
  echo "===== ${inventory} ====="
  kubectl -n cpaas-system describe machineinventory.elemental.cattle.io "${inventory}"
done
```

每台都要满足：

- `Ready=True`
- 报告了预期网络/IP
- 只有一套当前 Elemental 磁盘布局
- allocation 为空或 `Available`
- owner 字段为空
- plan Secret 存在

```bash
for inventory in \
  olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137 \
  olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12 \
  olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
do
  kubectl -n "${BM_NS}" \
    get machineinventory.elemental.cattle.io "${inventory}" \
    -o jsonpath='name={.metadata.name}{"\n"}uid={.metadata.uid}{"\n"}allocation={.metadata.annotations.baremetal\.alauda\.io/allocation-state}{"\n"}baremetalMachine={.metadata.annotations.baremetal\.alauda\.io/owner-baremetalmachine}{"\n"}machine={.metadata.annotations.baremetal\.alauda\.io/owner-machine}{"\n"}cluster={.metadata.annotations.baremetal\.alauda\.io/owner-cluster}{"\n"}plan={.status.plan.secretRef.name}{"\n\n"}'
done
```

不要手动删除 owner annotation 或 finalizer。某些 Inventory 在 ISO 未卸载、仍从虚拟光驱启动时，会看不到正常磁盘挂载/布局。这类 Inventory 不要加入 Pool。

## 4. 多盘主机只固定系统盘

官方文档：<https://docs.alauda.cn/immutable-infra/1.0/how-to/configure-fixed-install-disk-bare-metal.html>

研发确认：部署阶段不单独规划额外数据盘。有多块磁盘、大小不同时，只需要用 WWN 把门禁指到系统盘。数据盘等集群起来后，再登录节点手工挂载；后续升级不受影响。

不要把 `MachineRegistration.spec.config.elemental.install.device` 留空，也不要用 `/dev/sda`。空 device 会让 Elemental 自动选盘；`/dev/sda` 在 Live ISO 和已安装系统之间可能互换。

共享 ISO 使用同一个不存在的路径：

```yaml
spec:
  config:
    elemental:
      install:
        device: /dev/elemental-install-target
        eject-cd: true
        reboot: true
```

Live ISO 启动后，该路径故意不存在，安装服务不会自动选盘。每台主机在 Live ISO 控制台里，把这个路径链到该主机系统盘的 WWN。

### 4.1 [三台 Master 都执行] 在 Live ISO 上创建安装目标

清理并确认目标整盘后：

```bash
ls -l /dev/disk/by-id/wwn-*
lsblk -d -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,HCTL

test ! -e /dev/elemental-install-target
test ! -L /dev/elemental-install-target

ln -s \
  /dev/disk/by-id/wwn-把这里换成该主机系统盘的实际WWN \
  /dev/elemental-install-target

readlink -f /dev/elemental-install-target
test -b /dev/elemental-install-target && echo TARGET_IS_BLOCK
lsblk -d -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,HCTL \
  "$(readlink -f /dev/elemental-install-target)"
```

确认输出的是系统盘，不是数据盘。这个符号链接只存在于当前 Live ISO 会话，重启后会消失；已安装系统正常启动不需要它。

当前三台 Master 如果已经完成安装并离开 Live ISO，不要再回 Live ISO 重建这个链接。本节只用于复查或重装。

## 5. 数据盘放到集群 Ready 之后

本方案部署阶段不使用 Storage v2 / `storagectl` 提前声明数据盘，也不把 `/var/cpaas` 作为加入 Pool 的前置条件。

原因：

- 系统盘由 `/dev/elemental-install-target` 固定即可。
- 额外数据盘可以等节点加入集群后再在节点上挂载。
- 研发确认这种后挂方式不影响后续升级。

`manifests/storage/` 仅保留作可选参考，不是当前部署必做步骤。

## 6. 加入 Pool 前的 Inventory 结论

三台都 `Ready=True`，且已确认从系统盘启动后，才能创建 Pool。不要等待 StoragePrepared。

## 7. 创建 Control Plane Pool

文件：`manifests/02-workload-control-plane-pool.yaml`。已经按现场填写三个真实 Inventory、`hostname` 和 `networkDevice`。官方字段是 `machineInventories`，不是 `inventoryRefs`。顺序与现场一致：`cpw01` → `cpw02` → `cpw03`。`networkDevice` 可选，用来覆盖集群默认 CNI 网卡；当前三台都按 `eth0` 写明。某台实际是 bond 或别的网卡名时，只改那一台：

```yaml
spec:
  clusterName: olvm-workloadcluster
  machineInventories:
    - name: olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
      hostname: olvm-workloadcluster-cpw01
      networkDevice: eth0
    - name: olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137
      hostname: olvm-workloadcluster-cpw02
      networkDevice: eth0
    - name: olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12
      hostname: olvm-workloadcluster-cpw03
      networkDevice: eth0
```

确认三台 Inventory Ready、ISO 已弹出、并从系统盘启动后执行：

```bash
kubectl apply \
  -f manifests/02-workload-control-plane-pool.yaml
kubectl -n cpaas-system \
  get machineinventorypool olvm-workloadcluster-control-plane-pool -o yaml
```

要求 Pool Ready/MembersValid，available 至少为 3。

## 8. 修改集群参数

### 8.1 API Endpoint 和 CNI 网卡

编辑 `manifests/03-workload-baremetal-cluster.yaml`：

```yaml
spec:
  networkType: kube-ovn
  networkDevice: eth0
  controlPlaneLoadBalancer:
    type: External
    host: 10.243.166.12
    port: 6443
```

External LB 必须已创建 TCP 6443 listener，后端会是三台 Master。若使用 Internal VIP，必须按照 ACP 4.3.2 CRD 修改字段并确认 L2、VRID、VRRP、IPVS；不要直接 apply External 示例。

`networkType: kube-ovn` 打开 provider 托管的 Kube-OVN。`networkDevice` 是集群默认的 CNI 网卡，**可选**，API 默认 `eth0`。本项目仍把它写进 YAML，避免现场默认成未声明的网卡。

覆盖规则：

- 全部节点都用同一块网卡：只改 `BaremetalCluster.spec.networkDevice`，例如改成 `eth1` 或 `bond1`。
- 只有某台名字不同（Worker VLAN、bond、或不是集群默认那块）：改对应 Pool 条目的 `machineInventories[].networkDevice`，不要改集群默认。Worker 默认覆盖是 `eth0.329`，Master 继续 `eth0`，已装好的 Master 不用重做。
- Overlay 时这块网卡必须有 IPv4（Geneve 源地址）。Underlay 时可以没有地址，但不能是带节点地址和默认路由的那块网卡。
- 地址由主机自己的 NetworkManager 提供，provider 不配 IP。
- 写成 bond 的 slave 名会报 `NetworkDeviceIsSlave`，要写聚合口。
- 现场网卡名以 `MachineInventory.spec.observedNetwork.interfaces` 为准，不要猜。

```bash
kubectl -n cpaas-system get machineinventory.elemental.cattle.io \
  olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137 \
  -o jsonpath='{range .spec.observedNetwork.interfaces[*]}{.name} kind={.kind} master={.master} {.addresses}{"\n"}{end}'
```

某台 Master 不是 `eth0` 时，在 `02` 里只改那一台的 `networkDevice`。Worker 默认写在 `08`，是 `eth0.329`，不要把集群默认改成 VLAN。

### 8.2 Registry 和 CIDR

编辑 `manifests/05-workload-cluster.yaml`：

```yaml
metadata:
  labels:
    cluster-type: ProviderBaremetal
  annotations:
    capi.cpaas.io/resource-group-version: infrastructure.cluster.x-k8s.io/v1beta1
    capi.cpaas.io/resource-kind: BaremetalCluster
    cpaas.io/sentry-deploy-type: Baremetal
    cpaas.io/alb-address-type: ClusterAddress
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

Registry 已按现场填写。三个 CIDR 不得与 Global、物理网络、管理网、存储网或其他 Workload 冲突。前四个 annotation 和 `cluster-type` 是官方必填，不要删。本次是 overlay，不要加 `kube-ovn.cpaas.io/transmit-type: underlay`。

### 8.3 KCP

文件：`manifests/06-workload-control-plane.yaml`。

这是官方 ACP 4.3.2 Bare Metal 全量 `KubeadmControlPlane`。已填入本项目固定值：

- `version: v1.34.5-3`
- `dns.imageTag: 1.14.2-v4.3.11`
- `etcd.local.imageTag: v3.5.28-260625`
- `machineTemplate.infrastructureRef.name: olvm-workloadcluster-control-plane-template`

apply 前只替换 SSH 公钥：

```yaml
sshAuthorizedKeys:
  - "<ssh-authorized-keys>"
```

把 Global Master 01 上 `/root/.ssh/*.pub` 的完整一行公钥写进去。官方这份 YAML 使用 `node-labels: kube-ovn/role=master`，不再使用自定义 `provider-id` 占位符。

不能把 `<ssh-authorized-keys>` 直接 apply。

官方“步骤 3：创建控制平面集群资源”对应本项目 4 个文件，必须按下面顺序创建：

| 官方资源 | 本项目文件 | 作用 |
|---|---|---|
| `BaremetalCluster` | `manifests/03-workload-baremetal-cluster.yaml` | 声明 Workload API 入口和 CNI 网卡。本方案用 `External` VIP `10.243.166.12:6443`，`networkType: kube-ovn`，`networkDevice: eth0` |
| `BaremetalMachineTemplate` | `manifests/04-workload-control-plane-machine-template.yaml` | 指向控制平面 Pool，决定从哪 3 台已注册 Inventory 分配 Master |
| `Cluster` | `manifests/05-workload-cluster.yaml` | CAPI 总对象，把 BaremetalCluster 和 KubeadmControlPlane 绑在一起 |
| `KubeadmControlPlane` | `manifests/06-workload-control-plane.yaml` | 声明 3 个 Master 副本、Kubernetes 版本和 kubeadm 配置 |

本方案选择 `External`，不是 `Internal`：

- `External`：provider 不部署 Alive，不接管 VIP。客户 LB 维护 `10.243.166.12:6443` 以及三台 Master 后端。
- `Internal`：provider 部署 Alive，并自己协调 VIP 和后端。本次不使用。

前置条件：`manifests/02-workload-control-plane-pool.yaml` 必须已经 apply，并且 Pool Ready。`02` 不是官方第 3 步里的 4 个资源之一，但没有它，`BaremetalMachineTemplate` 无法从 Pool 分配机器。

## 9. 创建 Workload Control Plane

顺序执行：

```bash
kubectl apply \
  -f manifests/03-workload-baremetal-cluster.yaml
kubectl apply \
  -f manifests/04-workload-control-plane-machine-template.yaml
kubectl apply \
  -f manifests/05-workload-cluster.yaml
kubectl apply \
  -f manifests/06-workload-control-plane.yaml
```

检查：

```bash
kubectl -n cpaas-system get \
  baremetalcluster,cluster,kubeadmcontrolplane,machine,baremetalmachine
kubectl -n cpaas-system \
  get events --sort-by=.lastTimestamp
kubectl -n cpaas-system get baremetalcluster olvm-workloadcluster \
  -o jsonpath='{.spec.networkType}{" "}{.spec.networkDevice}{"\n"}'
kubectl -n cpaas-system get baremetalmachines.infrastructure.cluster.x-k8s.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="NetworkDeviceReady")]}{.status} {.reason}: {.message}{"\n"}{end}{end}'
```

期待：

- BaremetalCluster Ready/EndpointReady；
- `NetworkConfigValid` 为 True；
- 每台 `BaremetalMachine` 的 `NetworkDeviceReady` 为 True；
- 三台 Inventory 被分配；
- reprovision plans Applied；
- KCP replicas=3；
- kubeconfig Secret 生成；
- 三台 Master Nodes Ready。

获取 Workload kubeconfig：

```bash
kubectl -n cpaas-system \
  get secret olvm-workloadcluster-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
```

## 10. 集群 Ready 后按需挂载数据盘

三台 Master Node Ready 后，如果业务需要使用额外磁盘，再登录节点手工挂载。这一步不是创建 Cluster/KCP 的前置条件，也不影响后续 OS 升级。

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
findmnt /
```

确认系统盘已经挂着 Elemental 分区。数据盘保持独立，按现场需求挂到业务路径。不要把数据盘重新做成系统盘。

## 11. 添加 Worker

按官方文档 [Managing Nodes on Bare Metal → Worker Node Deployment](https://docs.alauda.cn/immutable-infra/1.0/manage-nodes/bare-metal.html#worker-node-deployment)。

官方这一节默认 Control Plane 已经起来，并且 Worker Pool 里已经有足够的 `Available` Inventory。本项目 Worker 物理机还没注册，所以先完成注册和 Pool，再走官方 Step 1–4。

不要把 Worker YAML 和 Control Plane YAML 一起 apply。

| 阶段 | 官方步骤 | 本项目文件 | 资源 |
|---|---|---|---|
| 注册主机（官方 Create Cluster Step 1，本项目先做） | SeedImage ISO 启动 | `manifests/07-worker-registration-seedimage.yaml` | `MachineRegistration` + `SeedImage` |
| 写入 Pool（官方 Create Cluster Step 2） | 把真实 Inventory 放进 Worker Pool | `manifests/08-worker-pool.yaml` | `MachineInventoryPool` |
| 官方 Step 1 | 确认 Worker Pool `status.available ≥ replicas` | 已 apply 的 `08` | `olvm-workloadcluster-worker-pool` |
| 官方 Step 2 | Worker 基础设施模板 | `manifests/09-worker-machine-template.yaml` | `BaremetalMachineTemplate` |
| 官方 Step 3 | Worker bootstrap | `manifests/10-worker-kubeadm-config-template.yaml` | `KubeadmConfigTemplate` |
| 官方 Step 4 | 副本、版本、滚动策略 | `manifests/11-worker-machine-deployment.yaml` | `MachineDeployment` |

当前 `08` 里还是占位 Inventory 名字，`10` 的 SSH 公钥也还没替换。`07` 的 Registry 已写成 `10.243.166.5:11443`。没填完不要 apply。Worker 不要复用 Master 的 `olvm-workloadcluster-registration` ISO。

官方四个 Worker 对象对应本项目名字：

| 官方占位 | 本项目实际名字 |
|---|---|
| `<cluster-name>-worker-pool` | `olvm-workloadcluster-worker-pool` |
| `<cluster-name>-worker-template` | `olvm-workloadcluster-worker-template` |
| `<cluster-name>-worker-bootstrap` | `olvm-workloadcluster-worker-kubeadm-config` |
| `<cluster-name>-workers` | `olvm-workloadcluster-worker-deployment` |

### 11.1 前置条件

官方要求：

- Control Plane 已经运行。
- Worker Pool 的 `Available` Inventory 数量 ≥ `replicas`（本项目每个集群默认 1 台 Worker，`replicas: 1`）。
- `Machine.spec.version` 必须是 `elemental-image-catalog` 的 key。本项目用 `v1.34.5-3`。
- 只有改 `<>` 占位符。hostname、`provider-id`、`criSocket` 不要预填，provider 会在 reprovision plan 里写入。

本方案不在 Inventory 上声明 `spec.storage.volumes[]`，所以不需要等 `StoragePrepared`。

在 **[Global Master 01]** 确认 Control Plane：

```bash
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
kubectl -n cpaas-system get kubeadmcontrolplane olvm-workloadcluster-control-plane
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
```

要求：三台 Master Node Ready；KCP Ready；catalog 有 `v1.34.5-3`。

### 11.2 [Global Master 01] 创建 Worker SeedImage

编辑 `manifests/07-worker-registration-seedimage.yaml`。Registry 已写成现场 `10.243.166.5:11443`，不要改 `${System Information/UUID}` 这类 Elemental 表达式：

```yaml
spec:
  baseImage: 10.243.166.5:11443/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3
```

```bash
vi manifests/07-worker-registration-seedimage.yaml
grep -nE '<[^>]+>|填写实际' manifests/07-worker-registration-seedimage.yaml
kubectl apply --dry-run=server -f manifests/07-worker-registration-seedimage.yaml
kubectl apply -f manifests/07-worker-registration-seedimage.yaml
kubectl -n cpaas-system get machineregistration olvm-workloadcluster-worker-registration
kubectl -n cpaas-system describe seedimage olvm-workloadcluster-worker-registration-iso
```

等到 `SeedImageReady=True` 后再下载 ISO。不要用 Control Plane 那张 ISO 去装 Worker。

```bash
kubectl -n cpaas-system get seedimage olvm-workloadcluster-worker-registration-iso -o yaml
```

把生成的 Worker ISO 挂到这台 Worker 物理机的虚拟光驱。`install.device` 已经是 `/dev/elemental-install-target`。多盘主机按第 4 节在 Live ISO 上把该路径链到系统盘 WWN。本项目每个集群默认 1 台 Worker；要加第二台时再重复本节并提高 `11` 的 `replicas`。

### 11.3 [BMC + Worker] 从 Worker ISO 安装

这台 Worker 物理机：

1. BMC 挂上 Worker SeedImage ISO。
2. 本次启动从虚拟光驱进入 Live ISO。
3. 多盘主机按第 4.1 节创建 `/dev/elemental-install-target`，确认指向系统盘。
4. **先配 VLAN 329，再让主机注册。** 默认不是 bond：IP 配在 `eth0.329` 上，不要配在 `eth0` 上。VLAN 写在 Live ISO 控制台，不写进 Registration YAML。
5. 等 Elemental 安装并自动重启。
6. 安装触发重启后，立即弹出/卸载 ISO。
7. 把启动顺序改回 disk-first。
8. 确认下一次启动进入已安装 OS，不是再次进入 Live ISO。

VLAN 必须在安装前配完。Live ISO 上 NetworkManager 自动 DHCP 不会写进 `observedNetwork.connections`；安装后只回放注册时拍到的 keyfile。Master 已经按 `eth0` 跑了，不要改 `BaremetalCluster.spec.networkDevice`。

#### 默认写法：VLAN 329 在 eth0 上（不是 bond）

**[Worker BMC Console]**，Live ISO 起来后立刻做。`eth0` 不能是 bond slave。掩码、网关、DNS 按现场另一台节点的网络参数写；地址示例是 `10.243.166.6`，若该地址已被那台节点占用，换同网段空闲地址，不要用 VIP `10.243.166.12`：

| 项 | 默认值 |
|---|---|
| 节点地址 | `10.243.166.6/26`（占用则换空闲地址） |
| 网关 | `10.243.166.1` |
| DNS | `10.243.132.38` |
| VLAN | `329`，接口 `eth0.329` |

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
  ipv4.addresses 10.243.166.6/26 \
  ipv4.gateway 10.243.166.1 \
  ipv4.dns 10.243.132.38 \
  ipv6.method ignore

sudo nmcli con up vlan329
ping -c 3 10.243.166.1
ip -br addr show eth0.329
ls /etc/NetworkManager/system-connections/
nmcli -f NAME,UUID,TYPE,DEVICE,FILENAME connection show
```

必须能 ping 通网关，并且 `FILENAME` 指向磁盘上的 `*.nmconnection`，不能只在 `/run/NetworkManager/system-connections/`。

`networkDevice` 填 VLAN 接口名 `eth0.329`，不要填物理口 `eth0`，也不要填 connection 名 `vlan329`。

如果这样还不通：不是 nmcli 写错，是交换机把 `eth0`/`eth1` 绑成一组了。单口 `eth0` 交换机不放行，改用下面的备选 bond，或者让网络改端口。

#### 备选：交换机已把两口绑成一组时，用 bond + VLAN 329

客户现场常见是 **active-backup，不是 LACP**。IP 仍配在 VLAN 上，不要配在 `eth0` / `bond0`。

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

这时 `08` 里这一台改成 `networkDevice: bond0.329`。不要写 `eth0`、`eth1` 或 `bond0`：前两个是 slave，会报 `NetworkDeviceIsSlave`；`bond0` 没有节点地址。Master 的 `03` / `02` 仍然是 `eth0`。

登录已安装系统检查：

```bash
hostname
findmnt -n -o SOURCE,FSTYPE,TARGET /
findmnt /run/initramfs/live || echo NO_LIVE_ISO_ROOT
lsblk -e7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
timedatectl
chronyc tracking
```

必须同时满足：

- `/` 不是 `LiveOS_rootfs`
- 没有 `/run/initramfs/live`
- 能看到 `COS_STATE` / `COS_OEM` / `COS_RECOVERY` / `COS_PERSISTENT`
- 时区和 Master 一致，时间误差不超过 10 秒
- 额外数据盘这一步不要格式化、不要挂业务路径

如果还在 Live ISO，停止。回到 BMC 弹出 ISO，改启动项，再重启。

### 11.4 [Global Master 01] 检查 Worker Inventory 并写入 Pool

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
kubectl -n cpaas-system get machineinventories.elemental.cattle.io \
  -l cpaas.io/node-role=worker -o wide
```

Worker Inventory 名字由 Elemental 按 `olvm-workloadcluster-worker-${UUID}` 生成，现场才会出现。把这一台真实名字记下来。

必须满足：`Ready=True`；报告了预期网络/IP（Live ISO 上配的地址，参考 `10.243.166.6`）；只有一套当前 Elemental 磁盘布局；allocation 为空或 `Available`；owner 字段为空。

```bash
inventory=<actual-worker-inventory-1>
echo "===== ${inventory} ====="
kubectl -n cpaas-system describe machineinventory.elemental.cattle.io "${inventory}"
kubectl -n cpaas-system \
  get machineinventory.elemental.cattle.io "${inventory}" \
  -o jsonpath='name={.metadata.name}{"\n"}uid={.metadata.uid}{"\n"}allocation={.metadata.annotations.baremetal\.alauda\.io/allocation-state}{"\n"}baremetalMachine={.metadata.annotations.baremetal\.alauda\.io/owner-baremetalmachine}{"\n"}machine={.metadata.annotations.baremetal\.alauda\.io/owner-machine}{"\n"}cluster={.metadata.annotations.baremetal\.alauda\.io/owner-cluster}{"\n"}plan={.status.plan.secretRef.name}{"\n\n"}'
```

把 `<actual-worker-inventory-1>` 换成刚查到的真实名字。不是 `Ready=True`，或仍像 Live ISO 磁盘布局，不要加入 Worker Pool。

编辑 `manifests/08-worker-pool.yaml`。官方字段是 `machineInventories`。`networkDevice` 可选，覆盖 `BaremetalCluster.spec.networkDevice`。Worker 默认写成 `eth0.329`（VLAN 329 在 eth0 上，不是 bond）。先看 Inventory 的 `observedNetwork`，名字不是 `eth0.329` 时只改那一台；Master 不要动：

```bash
kubectl -n cpaas-system get machineinventory.elemental.cattle.io \
  <actual-worker-inventory-1> \
  -o jsonpath='{range .spec.observedNetwork.interfaces[*]}{.name} kind={.kind} master={.master} {.addresses}{"\n"}{end}'
```

```yaml
spec:
  clusterName: olvm-workloadcluster
  machineInventories:
    - name: <actual-worker-inventory-1>
      hostname: olvm-workloadcluster-worker01
      networkDevice: eth0.329
```

```bash
vi manifests/08-worker-pool.yaml
grep -nE '<[^>]+>|填写实际' manifests/08-worker-pool.yaml
kubectl apply --dry-run=server -f manifests/08-worker-pool.yaml
kubectl apply -f manifests/08-worker-pool.yaml
```

### 11.5 官方 Step 1：确认 Worker Pool 容量

```bash
kubectl -n cpaas-system get machineinventorypools.infrastructure.cluster.x-k8s.io \
  olvm-workloadcluster-worker-pool
kubectl -n cpaas-system get machineinventorypool olvm-workloadcluster-worker-pool -o yaml
```

成功标准：`status.available ≥ 1`，并且 Pool Ready/MembersValid。这台 Worker 的 CNI 网卡不是 `eth0.329` 时（例如交换机捆绑后变成 `bond0.329`），先看该 Inventory 的 `observedNetwork`，再改 `08` 里这一台的 `networkDevice`。不要改 `BaremetalCluster.spec.networkDevice`。

容量不够时，不要继续 Step 2。回去再注册主机、弹出 ISO、确认 Inventory Ready，再把名字写进 `08`。

### 11.6 官方 Step 2：Worker BaremetalMachineTemplate

文件：`manifests/09-worker-machine-template.yaml`。已经指向 `olvm-workloadcluster-worker-pool`，一般不用改。

官方这份 YAML 只要求 `machineInventoryPoolRef.name`。`allocationPolicy` 是预留字段，provider 当前把每个 Pool 都当成 `Ordered`：按声明顺序取第一台 `Available` Inventory。

```bash
kubectl apply --dry-run=server -f manifests/09-worker-machine-template.yaml
kubectl apply -f manifests/09-worker-machine-template.yaml
kubectl -n cpaas-system get baremetalmachinetemplate \
  olvm-workloadcluster-worker-template
```

这个模板创建后，pool 引用视为不可变。以后要换 Pool，必须新建一个模板名字，再改 MachineDeployment 的 `infrastructureRef.name`。原地改现有模板不会滚动节点。

### 11.7 官方 Step 3：Worker Bootstrap

文件：`manifests/10-worker-kubeadm-config-template.yaml`。

apply 前只替换 SSH 公钥，写成和第 1.3 节、KCP 相同的那一行：

```yaml
sshAuthorizedKeys:
  - "<ssh-authorized-keys>"
```

本项目 Kubernetes 是 `v1.34.5-3`，官方要求 1.34 及更早不要写 `imagePullCredentialsVerificationPolicy: NeverVerify`。当前 YAML 已按这个口径去掉该字段。研发给的 `preKubeadmCommands` 已保留。`node-labels: kube-ovn/role=worker` 也保留。

不要在这份模板里预填：

- hostname / FQDN：provider 从 Pool 的 hostname 或 Inventory 名字写入
- `kubeletExtraArgs.provider-id`：provider 写成 `baremetal:///<inventory-name>`
- `nodeRegistration.criSocket`：未设置时 provider 写成 `unix:///var/run/containerd/containerd.sock`

```bash
vi manifests/10-worker-kubeadm-config-template.yaml
grep -nE '<[^>]+>|填写实际|provider-id' manifests/10-worker-kubeadm-config-template.yaml
kubectl apply --dry-run=server -f manifests/10-worker-kubeadm-config-template.yaml
kubectl apply -f manifests/10-worker-kubeadm-config-template.yaml
kubectl -n cpaas-system get kubeadmconfigtemplate \
  olvm-workloadcluster-worker-kubeadm-config
```

还有 `<ssh-authorized-keys>` 就停止。

### 11.8 官方 Step 4：MachineDeployment

文件：`manifests/11-worker-machine-deployment.yaml`。已按官方字段填好：

- `replicas: 1`
- `version: v1.34.5-3`
- `strategy.rollingUpdate.maxSurge: 0`
- `strategy.rollingUpdate.maxUnavailable: 1`
- `nodeDrainTimeout: 5m`
- `nodeVolumeDetachTimeout: 5m`

裸金属不能超配。`maxSurge` 必须保持 `0`；`maxSurge=0` 时 `maxUnavailable` 必须 `> 0`。`replicas` 必须满足：

```text
replicas ≤ MachineInventoryPool.status.available + status.allocated
```

```bash
grep -nE '<[^>]+>|填写实际' manifests/11-worker-machine-deployment.yaml
kubectl apply --dry-run=server -f manifests/11-worker-machine-deployment.yaml
kubectl apply -f manifests/11-worker-machine-deployment.yaml
kubectl -n cpaas-system get machinedeployments.cluster.x-k8s.io
kubectl -n cpaas-system get baremetalmachines.infrastructure.cluster.x-k8s.io -w
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
```

成功标准：

- `MachineDeployment` `olvm-workloadcluster-worker-deployment` 存在，replicas=1
- `BaremetalMachine` 按 `Pending → Allocated → Reprovisioning → Running` 前进
- Workload 集群出现 1 台 Worker Node，并且 Ready
- 节点带 `kube-ovn/role=worker`
- Worker Pool 的 `available` 随绑定下降

### 11.9 Worker Ready 后按需挂数据盘

和 Master 一样，数据盘不是加入 Pool、也不是官方 Step 1–4 的前置条件。Worker Node Ready 后，再登录节点按现场需求挂载：

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
findmnt /
systemctl is-active kubelet
systemctl is-active containerd
```

不要把数据盘重新做成系统盘。后续 OS/集群升级不依赖这块后挂的数据盘。

## 12. 停止条件

出现以下任一情况停止，不继续 apply 后续资源：

- 主机仍从 SeedImage/ISO 启动，BMC 未弹出虚拟介质；
- `/` 仍是 Live ISO，或看不到 `COS_STATE` 等已安装系统布局；
- 任一 MachineInventory 不是 `Ready=True`，或看不到正常磁盘布局；
- 多盘重装时 `/dev/elemental-install-target` 未明确指向系统盘；
- server dry-run 失败；
- Control Plane Pool available 小于 3，或 Worker Pool available 小于 1；
- Registry、Image Catalog、LB、CIDR 或 SSH 公钥未确认；
- 要 apply 的 YAML 中仍存在 `<...>`、`填写实际` 或 `PROVIDER_ID` 占位内容；
- Worker 物理机尚未注册出真实 Inventory，就去 apply `08`；
- Worker SeedImage 还不是 `SeedImageReady=True`，就去给 Worker 挂 ISO；
- `networkDevice` 写成了 bond slave、物理口 `eth0`，或 Inventory `observedNetwork` 里没有这块网卡；
- Worker 还在 Live ISO 上、VLAN 329 还没通，就让 Elemental 安装。

## 13. Apply 前逐机与网络检查清单

### 13.1 [Global Master 01] 执行

```bash
hostname
kubectl cluster-info
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
kubectl -n cpaas-system get machineinventorypool -o wide
```

确认：当前是 Global Master 01；Image Catalog 有 `v1.34.5-3`；三台 Master Inventory 名字与 Pool YAML 完全一致；Inventory Ready、未分配，并且已经从系统盘启动。

检查 YAML 中仍未替换的值：

```bash
grep -nE '<[^>]+>|填写实际|PROVIDER_ID' \
  manifests/02-workload-control-plane-pool.yaml \
  manifests/03-workload-baremetal-cluster.yaml \
  manifests/04-workload-control-plane-machine-template.yaml \
  manifests/05-workload-cluster.yaml \
  manifests/06-workload-control-plane.yaml
```

有任何输出都停止 apply。逐个阅读将要 apply 的 YAML：

```bash
for file in \
  manifests/02-workload-control-plane-pool.yaml \
  manifests/03-workload-baremetal-cluster.yaml \
  manifests/04-workload-control-plane-machine-template.yaml \
  manifests/05-workload-cluster.yaml \
  manifests/06-workload-control-plane.yaml
do
  echo "===== ${file} ====="
  kubectl apply --dry-run=server -f "${file}"
done
```

### 13.2 [三台 Master 都执行]

分别登录每一台裸金属 Master，三台都执行：

```bash
hostname
findmnt -n -o SOURCE,FSTYPE,TARGET /
findmnt /run/initramfs/live || echo NO_LIVE_ISO_ROOT
lsblk -e7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
timedatectl
chronyc tracking
```

逐台确认：

- 当前不是 Live ISO，已经从系统盘启动；
- 能看到 Elemental 系统分区布局；
- ISO/虚拟光驱已卸载，启动项不是虚拟 CD；
- 时区一致，三台时间误差不超过 10 秒；
- 没有把数据盘误当成系统盘。

### 13.3 [LB 管理端] 执行

现场已完成转发配置，部署前重新核对：

```text
Frontend: 10.243.166.12:6443
Protocol: TCP passthrough
Backends: 三台 Master 节点 IP:6443
Health check: 根据客户 LB 能力使用 Kubernetes API TCP 检查策略
```

在 Global Master 01 验证 VIP：

```bash
nc -vz 10.243.166.12 6443
```

在 KCP 启动前，因为后端尚未监听，TCP 6443 检查可能失败；KCP 启动后必须成功。若配置了 FQDN，再额外用 `getent hosts <实际FQDN>` 确认其解析为 `10.243.166.12`。

### 13.4 [Global Master 01] 创建 CP 后执行

```bash
kubectl -n cpaas-system get baremetalcluster,cluster,kubeadmcontrolplane,machine,baremetalmachine -o wide
kubectl -n cpaas-system get events --sort-by=.lastTimestamp
kubectl -n cpaas-system get secret olvm-workloadcluster-kubeconfig
```

检查三台 Inventory 的 Ready/plan：

```bash
for inventory in \
  olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137 \
  olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12 \
  olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
do
  echo "===== ${inventory} ====="
  kubectl -n cpaas-system get machineinventory.elemental.cattle.io "${inventory}" -o json \
    | jq '{conditions:.status.conditions,plan:.status.plan}'
done
```

### 13.5 [三台 Master 都执行] CP Ready 后验证

```bash
hostname
findmnt -n -o SOURCE,FSTYPE,TARGET /
lsblk -f
systemctl is-active kubelet
systemctl is-active containerd
```

三台都必须从系统盘启动，kubelet/containerd active。数据盘不是这一步的成功标准。

### 13.6 [Global Master 01，使用 Workload kubeconfig] 最终验证

```bash
kubectl -n cpaas-system get secret olvm-workloadcluster-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
kubectl --kubeconfig workload-kubeconfig get pods -A
```

这一步先确认三台 Master Ready。Worker 还没加进来时，Node 列表只有 Control Plane 是正常的。

### 13.7 [Global Master 01] 添加 Worker 前执行

```bash
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
grep -nE '<[^>]+>|填写实际|provider-id' \
  manifests/07-worker-registration-seedimage.yaml \
  manifests/08-worker-pool.yaml \
  manifests/10-worker-kubeadm-config-template.yaml
```

`07` 的 Registry 已是 `10.243.166.5:11443`。`08` 必须等 Worker Inventory 真实出现后再替换名字，不要提前 apply。`08` 的 `hostname` 默认 `olvm-workloadcluster-worker01`，`networkDevice` 默认 `eth0.329`，必须和该 Inventory `observedNetwork` 里的 VLAN 接口名一致。`10` 的 SSH 公钥必须和第 1.3 节一致，且不要预填 `provider-id`。不要改 `03` 里 Master 的 `networkDevice: eth0`。

Worker Inventory Ready 并写入 Pool 后，先确认官方 Step 1 的容量，再 dry-run Step 2–4：

```bash
kubectl -n cpaas-system get machineinventorypools.infrastructure.cluster.x-k8s.io \
  olvm-workloadcluster-worker-pool
for file in \
  manifests/09-worker-machine-template.yaml \
  manifests/10-worker-kubeadm-config-template.yaml \
  manifests/11-worker-machine-deployment.yaml
do
  echo "===== ${file} ====="
  kubectl apply --dry-run=server -f "${file}"
done
```

## 14. 问题解决

### 14.1 物理服务器已存在操作系统

**现象：** 物理机硬盘上已经有旧系统（分区、`EFI` / `ROOT` / `COS_*` 标签还在）。从 SeedImage ISO 进入 Live 引导后，Elemental 安装选盘失败、装到错误设备，或旧分区标签干扰重装。

**适用：** 在 **Live ISO 控制台** 操作，还没有开始 Elemental 安装。Master 和 Worker 都可能遇到。本例是单盘主机，真实盘是 `sda`，数据在 `sda3`。

**可以做：**

- 确认后删/格式化 `sda`，不会把当前 Live installer 弄挂。
- 清掉之后，这块盘上的旧系统不可恢复。先确认没有还要保留的数据（日志、kube 数据、`/var/cpaas` 等）。

**不要做：**

- 不要对 `sr1`、`loop0` 做 wipe/format。那是 ISO 和 Live 根，清了 installer 会挂。
- 不要靠“第一块盘”这种默认值。安装目标必须明确指定要装的那块盘。
- `MachineRegistration` 里的 `install.device` 本项目仍用 `/dev/elemental-install-target`。这里的 `/dev/sda` 只是 Live ISO 上 `lsblk` 确认后的真实盘名，用来清旧分区。

**操作：**

先确认没有挂载：

```bash
lsblk
mount | grep sda || true
```

如果 `sda` 分区被挂上了，先卸载：

```bash
umount /dev/sda3 /dev/sda2 /dev/sda1 2>/dev/null || true
```

然后清签名和分区表（比单纯 mkfs 更干净，COS 重装也要求清掉残留标签）：

```bash
wipefs -a /dev/sda
sgdisk -Z /dev/sda
partprobe /dev/sda
lsblk
blkid
```

清完后 `sda` 应该没有分区，`blkid` 里也不该再看到 `EFI` / `ROOT` / `COS_*`。

然后再走安装。安装目标明确指定这块系统盘：多盘主机按第 4 节把 `/dev/elemental-install-target` 链到系统盘 WWN；本例只有一块真实盘时，确认 installer 选的是 `/dev/sda`，不要用“第一块盘”默认值。不要对 `sr1`、`loop0` 动手。
