# 控制面

三台 Master 已从 SeedImage 注册。正常续接从第 4 步开始。`01` 只有重建 Registration/ISO 时才再 apply。

```bash
hostname
kubectl config current-context
kubectl cluster-info
export BM_NS=cpaas-system
export CLUSTER_NAME=olvm-workloadcluster
```

`hostname` 必须是 `global-master01`。

现场固定值：

```text
Registry:     10.243.166.5:11443
OS ISO:       10.243.166.5:11443/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3
Catalog key:  v1.34.5-3
VIP:          10.243.166.12:6443
CNI NIC:      eth0
```

---

## 1. Image Catalog

```bash
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
```

需要有：

```yaml
data:
  v1.34.5-3: 10.243.166.5:11443/tkestack/baremetal-base-image:v4.3.2-1-1.34.5-3
```

没有就 merge patch，不要覆盖其它 key。

---

## 2. 控制面 Registration / SeedImage

文件：`control-plane/manifests/01-registration-seedimage.yaml`

现场已 apply，资源名：

```text
olvm-workloadcluster-registration
olvm-workloadcluster-registration-iso
```

磁盘字段已经是通用路径，做 ISO 时不要改成 `/dev/sda`：

```yaml
spec:
  config:
    elemental:
      install:
        device: /dev/elemental-install-target   # 通用参数，写进 ISO
        eject-cd: true
        reboot: true
```

只有重建 ISO 时才：

```bash
kubectl apply --dry-run=server -f control-plane/manifests/01-registration-seedimage.yaml
kubectl apply -f control-plane/manifests/01-registration-seedimage.yaml
kubectl -n cpaas-system describe seedimage olvm-workloadcluster-registration-iso
```

`SeedImageReady=True` 后再挂 ISO。不要用这张 ISO 装 Worker。

---

## 3. [每台 Master Live ISO] 系统盘软链接

YAML 不写真实盘符。Live ISO 控制台：

```bash
lsblk -d -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,HCTL
ln -s /dev/sda /dev/elemental-install-target   # /dev/sda 换成 lsblk 确认的系统盘
readlink -f /dev/elemental-install-target
```

不要链到数据盘、`sr*`、`loop*`。盘序可能对调时，源改成 `/dev/disk/by-id/wwn-*`。链接只活在当前 Live 会话。

已装好并离开 Live ISO 的三台 Master 不要再回 Live 重建链接。

有旧系统分区时，先对系统盘 `wipefs -a` / `sgdisk -Z`，不要动 `sr*` / `loop*`。然后再做软链接。

安装触发重启后：BMC 弹出 ISO，启动项改回 disk-first。

---

## 4. [三台 Master] 确认已从系统盘启动

```bash
hostname
findmnt -n -o SOURCE,FSTYPE,TARGET /
findmnt /run/initramfs/live || echo NO_LIVE_ISO_ROOT
lsblk -e7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
```

`/` 不能是 `LiveOS_rootfs`；要能看到 `COS_STATE` 等分区。仍是 Live ISO 就停止，不要加入 Pool。

---

## 5. 检查三台 Inventory

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

---

## 6. Control Plane Pool

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

---

## 7. BaremetalCluster

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

---

## 8. Control Plane MachineTemplate

文件：`control-plane/manifests/04-control-plane-machine-template.yaml`

已指向 `olvm-workloadcluster-control-plane-pool`，不用改。

```bash
kubectl apply --dry-run=server -f control-plane/manifests/04-control-plane-machine-template.yaml
kubectl apply -f control-plane/manifests/04-control-plane-machine-template.yaml
```

---

## 9. Cluster

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

---

## 10. KubeadmControlPlane

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

---

## 11. 等待控制面 Ready

```bash
kubectl -n cpaas-system get baremetalcluster,cluster,kubeadmcontrolplane,machine,baremetalmachine
kubectl -n cpaas-system get events --sort-by=.lastTimestamp
kubectl -n cpaas-system get secret olvm-workloadcluster-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
```

期待：BaremetalCluster Ready；三台 Inventory 已分配；KCP replicas=3；三台 Master Node Ready。此时 Node 列表只有控制面是正常的。

控制面 Ready 后，再按 [`../worker/README.md`](../worker/README.md) 加 Worker。

---

## 12. 额外目录需要单独挂载时

本项目不包含存储 YAML。系统盘只走 ISO 通用路径 `/dev/elemental-install-target`。

如果业务还要把一块独立磁盘挂到额外目录（例如 `/data`，或根下其它路径），不要在本仓库里加存储文件，按官方文档在对应 `MachineInventory` 上配置：

<https://docs.alauda.cn/immutable-infra/1.0/how-to/manage-bare-metal-storage.html>
