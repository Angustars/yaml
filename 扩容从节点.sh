#!/bin/bash
# Redis Cluster 新增从节点脚本
# 使用方法：./redis-cluster-add-slave.sh <主节点序号>
# 示例：给 redis-0 新增从节点：./redis-cluster-add-slave.sh 0

# ========== 配置项 ==========
NAMESPACE="redis-cluster"
PASSWORD="Redis@123456"
SERVICE_DOMAIN="redis.${NAMESPACE}.svc.cluster.local"
ENTRY_POD="redis-0"

# ========== 参数校验 ==========
if [ $# -ne 1 ]; then
  echo "用法：$0 <主节点序号>"
  echo "示例：$0 0  （给 redis-0 新增一个从节点）"
  exit 1
fi

MASTER_ORDINAL=$1

# ========== 前置检查 ==========
echo "====== 1. 集群与目标节点检查 ======"
CLUSTER_STATE=$(kubectl exec -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli -a ${PASSWORD} --no-auth-warning cluster info | grep cluster_state | cut -d: -f2 | tr -d '\r')

if [ "${CLUSTER_STATE}" != "ok" ]; then
  echo "❌ 集群状态异常：${CLUSTER_STATE}"
  exit 1
fi
echo "✅ 集群状态正常"

# 验证目标节点是主节点
MASTER_ROLE=$(kubectl exec -n ${NAMESPACE} redis-${MASTER_ORDINAL} -- \
  redis-cli -a ${PASSWORD} --no-auth-warning role | head -n1 | tr -d '\r')

if [ "${MASTER_ROLE}" != "master" ]; then
  echo "❌ redis-${MASTER_ORDINAL} 不是主节点，无法添加从节点"
  exit 1
fi
echo "✅ 目标节点 redis-${MASTER_ORDINAL} 为主节点"

# 获取当前总节点数
CURRENT_REPLICAS=$(kubectl get statefulset redis -n ${NAMESPACE} -o jsonpath='{.spec.replicas}')
NEW_SLAVE_ORDINAL=${CURRENT_REPLICAS}

# ========== 扩容 StatefulSet ==========
echo ""
echo "====== 2. 扩容 StatefulSet ======"
echo "新增从节点：redis-${NEW_SLAVE_ORDINAL}"
kubectl scale statefulset redis --replicas=$((CURRENT_REPLICAS + 1)) -n ${NAMESPACE}

echo "等待新节点启动就绪..."
while true; do
  STATUS=$(kubectl get pod redis-${NEW_SLAVE_ORDINAL} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "${STATUS}" = "Running" ]; then
    PONG=$(kubectl exec -n ${NAMESPACE} redis-${NEW_SLAVE_ORDINAL} -- \
      redis-cli -a ${PASSWORD} --no-auth-warning ping 2>/dev/null | tr -d '\r')
    if [ "${PONG}" = "PONG" ]; then
      echo "✅ redis-${NEW_SLAVE_ORDINAL} 就绪"
      break
    fi
  fi
  sleep 3
done

# ========== 添加从节点并绑定主节点 ==========
echo ""
echo "====== 3. 从节点加入集群并绑定主节点 ======"
MASTER_ID=$(kubectl exec -n ${NAMESPACE} redis-${MASTER_ORDINAL} -- \
  redis-cli -a ${PASSWORD} --no-auth-warning cluster myid | tr -d '\r')

NEW_SLAVE_ADDR="redis-${NEW_SLAVE_ORDINAL}.${SERVICE_DOMAIN}:6379"
ENTRY_ADDR="${ENTRY_POD}.${SERVICE_DOMAIN}:6379"

kubectl exec -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli --cluster add-node ${NEW_SLAVE_ADDR} ${ENTRY_ADDR} \
  --cluster-slave \
  --cluster-master-id ${MASTER_ID} \
  -a ${PASSWORD} --no-auth-warning

if [ $? -eq 0 ]; then
  echo "✅ 从节点添加成功"
else
  echo "❌ 从节点添加失败"
  exit 1
fi

# ========== 校验结果 ==========
echo ""
echo "====== 4. 结果校验 ======"
kubectl exec -n ${NAMESPACE} ${ENTRY_POD} -- \
  redis-cli --cluster check ${ENTRY_ADDR} \
  -a ${PASSWORD} --no-auth-warning

echo ""
echo "🎉 从节点添加完成！"
echo "主节点 redis-${MASTER_ORDINAL} 已新增 1 个从节点 redis-${NEW_SLAVE_ORDINAL}"