#!/bin/bash

function inspect_hours {
  cron_str=$1
  cron_hours=$(echo "$cron_str" | awk '{print $2}')
  echo "$cron_hours"
}

function inspect_next {
  cron_str=$1
  cron_str="${cron_str//\'/}"
  minute=$(TZ=UTC date '+%M')
  minute=$((10#$minute))
  hour=$(TZ=UTC date '+%H')
  hour=$((10#$hour))
  cron_minute=$(echo "$cron_str" | awk '{print $1}')
  cron_hours=$(echo "$cron_str" | awk '{print $2}')
  # echo "current $hour:$minute"
  # echo "cron hours: $cron_hours"
  next_exec_hour=$(echo "$cron_hours" | awk -v min="$minute" -v hour="$hour" -v cron_min="$cron_minute" -F ',' '{
    for (i=1;i<=NF;i++) {
      if ($i>hour || $i==hour && cron_min>min) {
         print $i
         break
      }
    }
  }')
  if test -z "$next_exec_hour"; then
    next_exec_hour=$(echo "$cron_hours" | awk -F ',' '{print $1}')
  fi
  echo "next exec time: UTC($next_exec_hour:$cron_minute) 北京时间($(((next_exec_hour + 8) % 24)):$cron_minute)"
}

function hours_except_now {
  cron_hours=$1
  hour=$(TZ=UTC date '+%H')
  hour=$((10#$hour))
  except_current_hours=$(echo "$cron_hours" | awk -v hour="$hour" -F ',' '{
    for (i=1;i<=NF;i++) {
      if ($i!=hour) {
        print $i
      }
    }
  }')
  result=""
  while IFS= read -r line; do
    if [ -z "$result" ]; then
      result="$line"
    else
      result="$result,$line"
    fi
  done <<< "$except_current_hours"
  if test -z "$result"; then
    # 只有一个小时，则直接返回当前值
    result=$cron_hours
  fi
  echo "$result"
}

# 在[min_hour, max_hour]（UTC）范围内随机抽取count个互不重复的小时，exclude_hour用于剔除当前小时
function random_hours {
  local count=$1
  local min_hour=$2
  local max_hour=$3
  local exclude_hour=$4
  local candidates=()
  local h
  for ((h = min_hour; h <= max_hour; h++)); do
    if [ "$h" != "$exclude_hour" ]; then
      candidates+=("$h")
    fi
  done
  local n=${#candidates[@]}
  if [ "$count" -gt "$n" ]; then
    count=$n
  fi
  # Fisher-Yates洗牌后取前count个
  local i j tmp
  for ((i = n - 1; i > 0; i--)); do
    j=$((RANDOM % (i + 1)))
    tmp=${candidates[i]}
    candidates[i]=${candidates[j]}
    candidates[j]=$tmp
  done
  local picked=("${candidates[@]:0:count}")
  printf '%s\n' "${picked[@]}" | sort -n | paste -sd ','
}

function convert_utc_to_shanghai {
  local cron_str=$1
  echo "UTC时间: ${cron_str}"
  minute=$(echo "$cron_str" | awk '{print $1}')
  hours=$(echo "$cron_str" | awk '{print $2}')
  lines=$(echo "$hours"|awk -F ',' '{for (i=1;i<=NF;i++) { print ($i+8)%24 }}')
  # echo $lines
  result=""
  while IFS= read -r line; do
    if [ -z "$result" ]; then
      result="$line"
    else
      result="$result,$line"
    fi
  done <<< "$lines"
  echo "北京时间: $minute $result * * *'"
}

function persist_execute_log {
  local event_name=$1
  local new_cron_hours=$2
  local random_count=${3:-6}
  echo "trigger by: ${event_name}" > cron_change_time
  {
    echo "current system time:"
    TZ='UTC' date "+%y-%m-%d %H:%M:%S" | xargs -I {} echo "UTC: {}"
    TZ='Asia/Shanghai' date "+%y-%m-%d %H:%M:%S" | xargs -I {} echo "北京时间: {}"
  } >> cron_change_time
  current_cron=$(< .github/workflows/run.yml grep -E "^[[:space:]]*- cron: '"|awk '{print substr($0, index($0,$3))}')
  {
    echo "current cron:"
    convert_utc_to_shanghai "$current_cron"
  } >> cron_change_time
  os=$(uname -s)
  sed_prefix=(sed -i)
  if [[ $os == "Darwin" ]]; then
    sed_prefix=(sed -i '')
  fi
  current_cron=$(< .github/workflows/run.yml grep -E "^[[:space:]]*- cron: '"|awk '{print substr($0, index($0,$3))}')
  cron_hours=$(inspect_hours "$current_cron")
  if test -n "$new_cron_hours"; then
    # 配置了CRON_HOURS时使用配置的小时，并剔除当前小时避免同小时重复执行
    cron_hours=$(hours_except_now "$new_cron_hours")
  else
    # 未配置CRON_HOURS时，每天在北京时间8-22点(UTC 0-14)窗口内随机抽取执行小时，执行时间不固定
    exclude_hour=$(TZ=UTC date '+%H')
    exclude_hour=$((10#$exclude_hour))
    cron_hours=$(random_hours "$random_count" 0 14 "$exclude_hour")
  fi
  "${sed_prefix[@]}" -E "s/(- cron: ')[0-9]+( [^[:space:]]+ \* \* \*')/\1$((RANDOM % 59)) ${cron_hours} * * *'/g" .github/workflows/run.yml
  current_cron=$(< .github/workflows/run.yml grep -E "^[[:space:]]*- cron: '"|awk '{print substr($0, index($0,$3))}')
  {
    echo "next cron:"
    convert_utc_to_shanghai "$current_cron"
    inspect_next "$current_cron"
  } >> cron_change_time

}

