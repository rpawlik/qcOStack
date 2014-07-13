#!/bin/bash
#
#
#
# Script to QC RPC environment
set --

#check QC status
outputStatus() {
  if [[ ${1} = "y" ]]; then
    echo  "QC PASS: "${2}
  elif [[ ${1} = "n" ]]; then
    echo  "QC FAIL: "${2}
  else
    echo  "NOT TESTED: "$*
  fi
}

checkStatus() {
  echo -e '******************************************'
  outputStatus $rabbitStatus ' RabbitMQ'
# TODO (ramsey) secs behind master section in if block broken, needs further testing
  outputStatus $myRepl ' MySQL Replication'
# TODO (ramsey) test this:
  outputStatus $tenantUser ' User and Tenant Created'
# TODO (ramsey) add image checks:
#  outputStatus $glanceImages 'Glance Images Uploaded'
  outputStatus $instanceSuccess ' Instance Availability'
  echo -e '******************************************'
}

control_c()
# run if user hits control-c
{
  echo -en "\n*** Ouch! Exiting ***\n"
  checkStatus
  exit 1
}

# trap keyboard interrupt (control-c)
trap control_c SIGINT

# Output and verify rabbitMQ cluster status

/usr/sbin/rabbitmqctl cluster_status

while [ -z $rabbitStatus ]; do
  echo -e 'Is the RabbitMQ cluster status correct? (y/n)'
  read rabbitStatus
done

if [ $rabbitStatus != "y" ]; then
  echo 'Please correct RabbitMQ cluster then run the QC script again.'
  checkStatus
  exit 0
fi


# build instances on each network and each compute node
# then attempt to ping from each instance to 8.8.8.8

echo 'Building instances, this may take several minutes.'
for NET in $(nova net-list | awk '/[0-9]/ && !/GATEWAY/ {print $2}');
  do for COMPUTE in $(nova hypervisor-list | awk '/[0-9]/ {print $4}');
    do nova boot --image $(nova image-list | awk '/Ubuntu/ {print $2}' | tail -1) \
      --flavor 2 \
      --security-group rpc-support \
      --key-name controller-id_rsa \
      --nic net-id=$NET \
      --availability-zone nova:$COMPUTE \
      test-$COMPUTE-$NIC >/dev/null;
    done

  sleep 30


  for IP in $(nova list | sed 's/.*=//' | egrep -v "\+|ID" | sed 's/ *|//g');
    do echo "$IP"': Attempting to ping 8.8.8.8 three times';
    ip netns exec qdhcp-$NET ssh -n -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$IP "ping -c 3 8.8.8.8 | grep loss 2>/dev/null" ;
  done
  while [ -z $instanceSuccess ]; do
    /bin/echo -e 'Was instance ping test successful? (y/n)'
    read instanceSuccess
  done
  if [ $instanceSuccess = "y" ]; then
    echo 'Deleting instances from network '"$NET/n"
    for ID in $(nova list | awk '/[0-9]/ {print $2}');
      do nova delete $ID;
    done
  else
    echo 'Please correct issues and run QC script again.'
    checkStatus
    exit 0
  fi
done

#if replication is configured, test to make sure it's working

if mysql mysql -e 'SELECT User FROM user\G' | grep -q repl; then
  echo 'MySQL replication configured.'
  SLAVE=$(mysql -e "SHOW SLAVE STATUS\G" | awk '/Master_Host/ {print $2}')
  if ! mysql -e 'SHOW SLAVE STATUS\G' | grep -q "Slave_IO_Running: Yes"; then
    echo 'MySQL replication possibly broken (Slave IO not running)! Please investigate.'
    exit 0
  elif ! mysql -e 'SHOW SLAVE STATUS\G' | grep -q "Slave_SQL_Running: Yes"; then
    echo 'MySQL replication possibly broken (Slave SQL not running)! Please investigate.'
    exit 0
  elif [ $(mysql -e 'SHOW SLAVE STATUS\G' | awk '/Seconds_Behind_Master/ {print $2}') -lt 1 ]; then
    echo 'MySQL replication possibly broken! The slave is behind master!'
    exit 0
  elif ! ssh $SLAVE 'mysql -e "SHOW SLAVE STATUS\G" | grep -q "Slave_SQL_Running: Yes"'; then
    echo 'MySQL replication possibly broken (Slave SQL not running) on slave! Please investigate.'
    exit 0
  elif ! ssh $SLAVE 'mysql -e "SHOW SLAVE STATUS\G" | grep -q "Slave_SQL_Running: "Yes"'; then
    echo 'MySQL replication possibly broken (Slave SQL not running) on slave! Please investigate.'
    exit 0
  elif [ $(ssh $SLAVE "mysql -e 'SHOW SLAVE STATUS\G' | awk '/Seconds_Behind_Master/ {print $2}'") -lt 1 ]; then
    echo 'MySQL replication possibly broken! The slave is behind master on the slave!'
    exit 0
  else
    echo 'MySQL replication looks good!'
    myRepl=y
  fi
fi

echo '******************************************'
echo 'Keystone users:'
keystone user-list | egrep -v 'ceilometer|cinder|glance|monitoring|neutron|nova' | awk '/True/ {print $2, $4}'
echo '******************************************'
echo 'Keystone tenants:'
keystone tenant-list | egrep -v 'service' | awk '/True/ {print $2, $4}'
echo '******************************************'

while [ -z $tenantUser ]; do
  echo 'Is user/tenant created? (y/n)'
  read tenantUser
done

#print QC status output
checkStatus