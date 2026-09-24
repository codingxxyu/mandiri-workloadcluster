# Mandiri Bare Metal Workload Cluster

本项目继续完成已经启动的 `olvm-workloadcluster` 裸金属业务集群。步骤按角色拆开，不要混 apply。

| 目录 | 做什么 | 文档 |
|---|---|---|
| [`control-plane/`](control-plane/README.md) | 控制面：Registration/ISO、三台 Master、Pool、Cluster、KCP | 逐步 README |
| [`worker/`](worker/README.md) | Worker：独立 Registration/ISO、VLAN 329、Pool、MachineDeployment | 逐步 README |

控制面 Ready 之后再做 Worker。Worker 不要复用控制面那张 ISO。

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

本仓库不包含存储配置。系统盘只走 ISO 通用路径。若要把独立磁盘挂到额外目录（例如 `/data`），按官方文档配置：<https://docs.alauda.cn/immutable-infra/1.0/how-to/manage-bare-metal-storage.html>

常见问题：Worker 默认网卡/IP 配不上、要配 VLAN → [`worker/README.md`](worker/README.md) 第 9 节；硬盘已有旧系统 → [`control-plane/README.md`](control-plane/README.md) 第 13 节。
