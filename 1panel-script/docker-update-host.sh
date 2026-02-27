#!/bin/bash
# ===================== 核心配置（容器名用逗号分隔，无需引号）=====================
CONTAINER_NAMES=cloud-media-sync,emby  # 容器名字仅逗号分隔，无引号
# ================================================================================

# 固定配置
IPV4_URL="https://raw.githubusercontent.com/cnwikee/CheckTMDB/refs/heads/main/Tmdb_host_ipv4"
IPV6_URL="https://raw.githubusercontent.com/cnwikee/CheckTMDB/refs/heads/main/Tmdb_host_ipv6"
GITHUB_HOSTS_URL="https://raw.githubusercontent.com/maxiaof/github-hosts/refs/heads/master/hosts"
TEMP_HOST="/tmp/tmdb_hosts.tmp"
LOG_DIR="/opt/scripts"
LOG_FILE="$LOG_DIR/host_update.log"  # 日志文件名保持修改后的host_update.log

# 网络配置
CURL_TIMEOUT=3
CURL_RETRY=1

# 加速链接配置（先试指定4个，最后试原始链接）
PROXY_URLS=(
    "https://gh-proxy.org/"
    "https://hk.gh-proxy.org/"
    "https://cdn.gh-proxy.org/"
    "https://edgeone.gh-proxy.org/"
    ""  # 空字符串代表原始链接（最后兜底）
)

# 第一步：初始化环境
mkdir -p $LOG_DIR || { echo "创建日志目录失败！"; exit 1; }
> $TEMP_HOST
> $LOG_FILE
IFS=',' read -r -a CONTAINER_ARRAY <<< "$CONTAINER_NAMES"

# 日志函数（关键信息双输出）
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "===== 启动TMDB+GitHub Host自动更新脚本（原版）====="

# 第二步：拉取Host配置（包含IPv4+IPv6，先试加速链接，失败试原始链接）
log "1. 拉取Host配置（IPv4+IPv6）..."
pull_success=0
for PROXY in "${PROXY_URLS[@]}"; do
    > $TEMP_HOST
    curl_cmd="curl -sSLfk --connect-timeout $CURL_TIMEOUT --retry $CURL_RETRY"
    
    # 拼接链接（空PROXY=原始链接）
    if [ -n "$PROXY" ]; then
        log "尝试加速链接: $PROXY"
        $curl_cmd "${PROXY}${IPV4_URL}" >> $TEMP_HOST 2>> $LOG_FILE
        $curl_cmd "${PROXY}${IPV6_URL}" >> $TEMP_HOST 2>> $LOG_FILE  # 保留IPv6拉取
        $curl_cmd "${PROXY}${GITHUB_HOSTS_URL}" >> $TEMP_HOST 2>> $LOG_FILE
    else
        log "指定加速链接均失败，尝试原始GitHub链接..."
        $curl_cmd "$IPV4_URL" >> $TEMP_HOST 2>> $LOG_FILE
        $curl_cmd "$IPV6_URL" >> $TEMP_HOST 2>> $LOG_FILE  # 保留IPv6拉取
        $curl_cmd "$GITHUB_HOSTS_URL" >> $TEMP_HOST 2>> $LOG_FILE
    fi
    
    if [ -s $TEMP_HOST ]; then
        if [ -n "$PROXY" ]; then
            log "✅ 加速链接 $PROXY 拉取成功"
        else
            log "✅ 原始GitHub链接拉取成功"
        fi
        pull_success=1
        break
    fi
done

if [ $pull_success -eq 0 ]; then
    log "错误：所有链接（加速+原始）均拉取失败！"
    rm -f $TEMP_HOST
    exit 1
fi

# 第三步：过滤有效Host（保留IPv4+IPv6）
log "2. 提取有效Host配置（包含IPv4+IPv6）..."
# 正则同时匹配IPv4和IPv6格式，保留所有有效Host
VALID_HOSTS=$(grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}\s+[a-zA-Z0-9.-]+$|^([0-9a-fA-F:]+)\s+[a-zA-Z0-9.-]+$' $TEMP_HOST | awk '{print $1 " " $2}')
if [ -z "$VALID_HOSTS" ]; then
    log "错误：未提取到有效Host配置！"
    rm -f $TEMP_HOST
    exit 1
fi
VALID_COUNT=$(echo "$VALID_HOSTS" | wc -l)
log "成功提取到 $VALID_COUNT 条有效Host配置（含IPv4+IPv6）"

# 第四步：批量更新容器Hosts
log "3. 开始更新容器Hosts配置..."
for CONTAINER_NAME in "${CONTAINER_ARRAY[@]}"; do
    CONTAINER_NAME=$(echo "$CONTAINER_NAME" | xargs)
    [ -z "$CONTAINER_NAME" ] && continue

    # 检查容器是否运行
    if ! docker ps | grep -q "$CONTAINER_NAME"; then
        log "⚠️  跳过未运行容器：$CONTAINER_NAME"
        continue
    fi

    log "更新容器 [$CONTAINER_NAME] Hosts配置..."
    docker exec "$CONTAINER_NAME" sh -c "
        cp /etc/hosts /tmp/hosts.tmp
        # 清理旧的TMDB/GitHub相关配置
        sed -i '/tmdb.org/d; /themoviedb.org/d; /imdb.com/d; /fanart.tv/d; /github/d' /tmp/hosts.tmp
        # 覆盖原hosts文件
        cat /tmp/hosts.tmp > /etc/hosts
        rm -f /tmp/hosts.tmp
        # 确保文件可写
        chmod 644 /etc/hosts
    " 2>> $LOG_FILE

    # 写入新Host配置（包含IPv4+IPv6）
    echo "$VALID_HOSTS" | docker exec -i "$CONTAINER_NAME" sh -c "cat >> /etc/hosts" 2>> $LOG_FILE

    log "✅ 容器 [$CONTAINER_NAME] Host配置更新完成（含IPv4+IPv6）"
done

# 清理临时文件
rm -f $TEMP_HOST
log "===== 脚本执行完成 ====="
log "核心日志：$LOG_FILE"
echo "Host更新完成！详情可查看日志：$LOG_FILE"
