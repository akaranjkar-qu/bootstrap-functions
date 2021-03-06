#!/bin/bash
#
# @file hadoop/util.sh
# @brief Provides Hadoop2 utility functions

source /usr/lib/hustler/bin/qubole-bash-lib.sh
export PROFILE_FILE=${PROFILE_FILE:-/etc/profile}
export HADOOP_ETC_DIR=${HADOOP_ETC_DIR:-/usr/lib/hadoop2/etc/hadoop}

al2=$([[ $(nodeinfo image_generation) -ge "2" ]] && echo "true" || echo "false")
dont_use_monit=$(nodeinfo_feature hadoop2.dont_use_monit)

if [[ -x "$(command -v initctl)" ]]; then
    ctl=initctl
else
    ctl=systemctl
fi

function _restart_master_services_monit() {
  monit unmonitor namenode
  monit unmonitor timelineserver
  monit unmonitor historyserver
  monit unmonitor resourcemanager

  /bin/su -s /bin/bash -c '/usr/lib/hadoop2/sbin/yarn-daemon.sh stop timelineserver' yarn
  /bin/su -s /bin/bash -c 'HADOOP_LIBEXEC_DIR=/usr/lib/hadoop2/libexec /usr/lib/hadoop2/sbin/mr-jobhistory-daemon.sh stop historyserver' mapred
  /bin/su -s /bin/bash -c '/usr/lib/hadoop2/sbin/yarn-daemon.sh stop resourcemanager' yarn
  /bin/su -s /bin/bash -c '/usr/lib/hadoop2/sbin/hadoop-daemon.sh stop namenode' hdfs

  /bin/su -s /bin/bash -c '/usr/lib/hadoop2/sbin/hadoop-daemon.sh start namenode' hdfs
  /bin/su -s /bin/bash -c '/usr/lib/hadoop2/sbin/yarn-daemon.sh start resourcemanager' yarn
  /bin/su -s /bin/bash -c 'HADOOP_LIBEXEC_DIR=/usr/lib/hadoop2/libexec /usr/lib/hadoop2/sbin/mr-jobhistory-daemon.sh start historyserver' mapred
  /bin/su -s /bin/bash -c '/usr/lib/hadoop2/sbin/yarn-daemon.sh start timelineserver' yarn

  monit monitor namenode
  monit monitor resourcemanager
  monit monitor historyserver
  monit monitor timelineserver
}

function _restart_master_services_ctl() {
    $ctl stop timelineserver
    $ctl stop historyserver
    $ctl stop resourcemanager
    $ctl stop namenode

    $ctl start namenode
    $ctl start resourcemanager
    $ctl start historyserver
    $ctl start timelineserver
}

function _restart_worker_services_monit() {
  monit unmonitor datanode
  /bin/su -s /bin/bash -c '/usr/lib/hadoop2/sbin/hadoop-daemon.sh stop datanode' hdfs
  /bin/su -s /bin/bash -c '/usr/lib/hadoop2/sbin/hadoop-daemon.sh start datanode' hdfs
  monit monitor datanode
  # No need to restart nodemanager since it starts only
  # after the bootstrap is finished
}

function _restart_worker_services_ctl() {
    $ctl stop datanode

    $ctl start datanode
  # No need to restart nodemanager since it starts only
  # after the bootstrap is finished
}

# @description Function to restart hadoop services on the cluster master
#
# This may be used if you're using a different version
# of Java, for example
#
# @example
#   restart_master_services
#
# @noargs
function restart_master_services() {
    if [[ ${al2} == "true" || ${dont_use_monit} == "true" ]]; then
        _restart_master_services_ctl
    else
        _restart_master_services_monit
    fi
}


# @description Function to restart hadoop services on the cluster workers
#
# This only restarts the datanode service since the
# nodemanager is started after the bootstrap is run
#
# @example
#   restart_worker_services
#
# @noargs
function restart_worker_services() {
    if [[ ${al2} == "true" || ${dont_use_monit} == "true" ]]; then
        _restart_worker_services_ctl
    else
        _restart_worker_services_monit
    fi
}

# @description Generic function to restart hadoop services
#
# @example
#   restart_hadoop_services
#
# @noargs
function restart_hadoop_services() {
    local is_master=$(nodeinfo is_master)
    if [[ ${is_master} == "1" ]]; then
        restart_master_services
    else
        restart_worker_services
    fi
}

# @description Use Java 8 for hadoop daemons and jobs
#
# By default, the hadoop daemons and jobs on Qubole
# clusters run on Java 7. Use this function if you would like
# to use Java 8. This is only required if your cluster:
# 1. is in AWS, and
# 2. is running Hive or Spark < 2.2
#
# @example
#   use_java8
#
# @noargs
function use_java8() {
 export JAVA_HOME=/usr/lib/jvm/java-1.8.0
 export PATH=$JAVA_HOME/bin:$PATH
 echo "export JAVA_HOME=/usr/lib/jvm/java-1.8.0" >> "$PROFILE_FILE"
 echo "export PATH=$JAVA_HOME/bin:$PATH" >> "$PROFILE_FILE"
 
 sed -i 's/java-1.7.0/java-1.8.0/' "$HADOOP_ETC_DIR/hadoop-env.sh"

 is_master=$(nodeinfo is_master)
 if [[ "$is_master" == "1" ]]; then
   restart_master_services
 else
   restart_worker_services
 fi
}

# @description Wait until namenode is out of safe mode
#
# @example
#   wait_until_namenode_running 25 5
#
# @arg $1 int Number of attempts function will make to get namenode out of safemode. Defaults to 50
# @arg $2 int Number of seconds each attempt will sleep for, waiting for namenode to come out of sleep mode. Defaults to 5
function wait_until_namenode_running() {
    n=0
    attempts=${1:-50}
    sleep_sec=${2:-5}
    
    nn_out_of_safe_mode=0
    until [ $n -ge $attempts ]
    do
        n=$[$n+1]
        safe_mode_stat=`hadoop dfsadmin -safemode get|awk '{print $4}'`
        if [[ $safe_mode_stat = "ON" ]]; then
            hdfs hadoop dfsadmin -safemode leave
            echo "Attempt $n/$attempts"
            sleep $sleep_sec
        else
            echo "NN is out of safemode..."
            nn_out_of_safe_mode=1
            break
        fi
    done
    if [[ $nn_out_of_safe_mode -eq 0 ]]; then
        safe_mode_stat=`hadoop dfsadmin -safemode get|awk '{print $4}'`
        if [[ $safe_mode_stat = "ON" ]]; then
                echo "Node still in safe mode after all attempts exhausted!"
        else
            echo "NN is out of safemode..."
        fi
    fi
    
}
