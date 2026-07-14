#!/bin/bash
# Redis Cluster 扩容主分片脚本（新增1主1从）
# 适用环境：K8s StatefulSet 部署，命名空间 redis-cluster

# ========== 配置项 ==========
NAMESPACE="redis-cluster"
PASSWORD="Redis@123456"
SERVICE_DOMAIN="redis.${NAMESPACE}.svc.cluster.local"
ENTRY_POD="redis-0"

# ========== 前置检查 ==========
echo "====== 1. 集群健康检查 ======"
CLUSTER_STATE=$(kubectl exec -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli -a ${PASSWORD} --no-auth-warning cluster info | grep cluster_state | cut -d: -f2 | tr -d '\r')

if [ "${CLUSTER_STATE}" != "ok" ]; then
  echo "❌ 集群状态异常：${CLUSTER_STATE}，请先修复集群再扩容"
  exit 1
fi
echo "✅ 集群状态正常"

# 获取当前总节点数
CURRENT_REPLICAS=$(kubectl get statefulset redis -n ${NAMESPACE} -o jsonpath='{.spec.replicas}')
CURRENT_MASTERS=$(kubectl exec -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli -a ${PASSWORD} --no-auth-warning cluster nodes | grep master | grep -v slave | wc -l)

echo "当前主节点数：${CURRENT_MASTERS}，总节点数：${CURRENT_REPLICAS}"
NEW_REPLICAS=$((CURRENT_REPLICAS + 2))
NEW_MASTER_ORDINAL=$((CURRENT_REPLICAS))
NEW_SLAVE_ORDINAL=$((CURRENT_REPLICAS + 1))

# ========== 扩容 StatefulSet ==========
echo ""
echo "====== 2. 扩容 StatefulSet 副本数 ======"
echo "新增节点：redis-${NEW_MASTER_ORDINAL}（主）、redis-${NEW_SLAVE_ORDINAL}（从）"
echo "总副本数从 ${CURRENT_REPLICAS} 调整为 ${NEW_REPLICAS}"

kubectl scale statefulset redis --replicas=${NEW_REPLICAS} -n ${NAMESPACE}

echo "等待新节点启动就绪..."
for i in ${NEW_MASTER_ORDINAL} ${NEW_SLAVE_ORDINAL}; do
  while true; do
    STATUS=$(kubectl get pod redis-${i} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "${STATUS}" = "Running" ]; then
      # 验证redis服务可用
      PONG=$(kubectl exec -n ${NAMESPACE} redis-${i} -- \
        redis-cli -a ${PASSWORD} --no-auth-warning ping 2>/dev/null | tr -d '\r')
      if [ "${PONG}" = "PONG" ]; then
        echo "✅ redis-${i} 就绪"
        break
      fi
    fi
    sleep 3
  done
done

# ========== 加入新主节点 ==========
echo ""
echo "====== 3. 新主节点加入集群 ======"
NEW_MASTER_ADDR="redis-${NEW_MASTER_ORDINAL}.${SERVICE_DOMAIN}:6379"
ENTRY_ADDR="${ENTRY_POD}.${SERVICE_DOMAIN}:6379"

kubectl exec -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli --cluster add-node ${NEW_MASTER_ADDR} ${ENTRY_ADDR} \
  -a ${PASSWORD} --no-auth-warning

if [ $? -eq 0 ]; then
  echo "✅ 新主节点加入成功"
else
  echo "❌ 新主节点加入失败"
  exit 1
fi

# ========== 获取新主节点ID，绑定从节点 ==========
echo ""
echo "====== 4. 绑定从节点到新主节点 ======"
MASTER_ID=$(kubectl exec -n ${NAMESPACE} redis-${NEW_MASTER_ORDINAL} -- \
  redis-cli -a ${PASSWORD} --no-auth-warning cluster myid | tr -d '\r')

NEW_SLAVE_ADDR="redis-${NEW_SLAVE_ORDINAL}.${SERVICE_DOMAIN}:6379"

kubectl exec -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli --cluster add-node ${NEW_SLAVE_ADDR} ${ENTRY_ADDR} \
  --cluster-slave \
  --cluster-master-id ${MASTER_ID} \
  -a ${PASSWORD} --no-auth-warning

if [ $? -eq 0 ]; then
  echo "✅ 从节点绑定成功"
else
  echo "❌ 从节点绑定失败"
  exit 1
fi

# ========== 引导槽位迁移 ==========
echo ""
echo "====== 5. 哈希槽迁移引导 ======"
echo "⚠️  即将启动交互式槽位迁移，请按以下提示操作："
echo "1. How many slots do you want to move (from 1 to 16384)?"
echo "   输入：$((16384 / (CURRENT_MASTERS + 1)))  （均分槽位）"
echo "2. What is the receiving node ID?"
echo "   输入：${MASTER_ID}  （新主节点ID）"
echo "3. Please enter all the source node IDs."
echo "   输入：all  （从所有原有主节点平均抽取）"
echo "4. 确认迁移计划时输入：yes"
echo ""
echo "按回车键开始迁移..."
read -r

kubectl exec -it -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli --cluster reshard ${ENTRY_ADDR} \
  -a ${PASSWORD} --no-auth-warning

# ========== 最终校验 ==========
echo ""
echo "====== 6. 集群最终校验 ======"
kubectl exec -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli --cluster check ${ENTRY_ADDR} \
  -a ${PASSWORD} --no-auth-warning

echo ""
echo "🎉 扩容完成！"
echo "执行以下命令查看最终节点拓扑："
echo "kubectl exec -it redis-0 -n redis-cluster -- redis-cli -a Redis@123456 --no-auth-warning cluster nodes"