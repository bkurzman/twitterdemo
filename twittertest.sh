#!/bin/bash

installUtils () {
	echo "*********************************Installing WGET..."
	yum install -y wget
	
	
	echo "*********************************Installing GIT..."
	yum install -y git
	

}

installNifi() {
	#change this to management packs code

	VERSION=`hdp-select status hadoop-client | sed 's/hadoop-client - \([0-9]\.[0-9]\).*/\1/'`
	rm -rf /var/lib/ambari-server/resources/stacks/HDP/$VERSION/services/NIFI
	sudo git clone https://github.com/abajwa-hw/ambari-nifi-service.git   /var/lib/ambari-server/resources/stacks/HDP/$VERSION/services/NIFI   
	#non sandbox
	service ambari-server restart
}

installSolr() {
	#change this to management packs code

	yum install -y lucidworks-hdpsearch
	sudo -u hdfs hadoop fs -mkdir /user/solr
	sudo -u hdfs hadoop fs -chown solr /user/solr
}

initializeSolr () {
	cd /opt/lucidworks-hdpsearch/solr/server/solr-webapp/webapp/banana/app/dashboards/
	mv default.json default.json.orig
	wget https://raw.githubusercontent.com/abajwa-hw/ambari-nifi-service/master/demofiles/default.json

	cd /opt/lucidworks-hdpsearch/solr/server/solr/configsets/data_driven_schema_configs/conf
 	mv -f solrconfig.xml solrconfig_bk.xml

  	wget https://raw.githubusercontent.com/sujithasankuhdp/nifi-templates/master/templates/solrconfig.xml
}

startSolr() {
  /opt/lucidworks-hdpsearch/solr/bin/solr start -c -z $AMBARI_HOST:2181
  /opt/lucidworks-hdpsearch/solr/bin/solr create -c tweets -d data_driven_schema_configs -s 1 -rf 1 
  yum install -y ntp
  service ntpd stop
  ntpdate pool.ntp.org
  service ntpd start
}

createHiveTables () {
  sudo -u hdfs hadoop fs -mkdir /tmp/tweets_staging
  sudo -u hdfs hadoop fs -chmod -R 777 /tmp/tweets_staging


  sudo -u hdfs hive -e 'create table if not exists tweets_text_partition(
    tweet_id bigint, 
    created_unixtime bigint, 
    created_time string, 
    displayname string, 
  msg string,
  fulltext string
  )
  row format delimited fields terminated by "|"
  location "/tmp/tweets_staging";'
}

deployTemplateToNifi () {
       	TEMPLATE_DIR=$1
       	TEMPLATE_NAME=$2
       	
       	echo "*********************************Importing NIFI Template..."
       	# Import NIFI Template HDF 3.x
       	# TEMPLATE_DIR should have been passed in by the caller install process
       	sleep 1
       	TEMPLATEID=$(curl -v -F template=@"$TEMPLATE_DIR" -X POST http://$NIFI_HOST:9090/nifi-api/process-groups/root/templates/upload | grep -Po '<id>([a-z0-9-]+)' | grep -Po '>([a-z0-9-]+)' | grep -Po '([a-z0-9-]+)')
       	sleep 1

       	# Instantiate NIFI Template 3.x
       	echo "*********************************Instantiating NIFI Flow..."
       	curl -u admin:admin -i -H "Content-Type:application/json" -d "{\"templateId\":\"$TEMPLATEID\",\"originX\":100,\"originY\":100}" -X POST http://$NIFI_HOST:9090/nifi-api/process-groups/root/template-instance
       	sleep 1

       	# Rename NIFI Root Group HDF 3.x
       	echo "*********************************Renaming Nifi Root Group..."
       	ROOT_GROUP_REVISION=$(curl -X GET http://$NIFI_HOST:9090/nifi-api/process-groups/root |grep -Po '\"version\":([0-9]+)'|grep -Po '([0-9]+)')

       	sleep 1
       	ROOT_GROUP_ID=$(curl -X GET http://$NIFI_HOST:9090/nifi-api/process-groups/root|grep -Po '("component":{"id":")([0-9a-zA-z\-]+)'| grep -Po '(:"[0-9a-zA-z\-]+)'| grep -Po '([0-9a-zA-z\-]+)')

       	PAYLOAD=$(echo "{\"id\":\"$ROOT_GROUP_ID\",\"revision\":{\"version\":$ROOT_GROUP_REVISION},\"component\":{\"id\":\"$ROOT_GROUP_ID\",\"name\":\"$TEMPLATE_NAME\"}}")

       	sleep 1
       	curl -d $PAYLOAD  -H "Content-Type: application/json" -X PUT http://$NIFI_HOST:9090/nifi-api/process-groups/$ROOT_GROUP_ID

}

configureNifiTempate () {
	GROUP_TARGETS=$(curl -u admin:admin -i -X GET http://$AMBARI_HOST:9090/nifi-api/process-groups/root/process-groups | grep -Po '\"uri\":\"([a-z0-9-://.]+)' | grep -Po '(?!.*\")([a-z0-9-://.]+)')
    length=${#GROUP_TARGETS[@]}
    echo $length
    echo ${GROUP_TARGETS[0]}

    #for ((i = 0; i < $length; i++))
    for GROUP in $GROUP_TARGETS
    do
       	#CURRENT_GROUP=${GROUP_TARGETS[i]}
       	CURRENT_GROUP=$GROUP
       	echo "***********************************************************calling handle ports with group $CURRENT_GROUP"
       	handleGroupPorts $CURRENT_GROUP
       	echo "***********************************************************calling handle processors with group $CURRENT_GROUP"
       	handleGroupProcessors $CURRENT_GROUP
       	echo "***********************************************************done handle processors"
    done

    ROOT_TARGET=$(curl -u admin:admin -i -X GET http://$AMBARI_HOST:9090/nifi-api/process-groups/root| grep -Po '\"uri\":\"([a-z0-9-://.]+)' | grep -Po '(?!.*\")([a-z0-9-://.]+)')

    handleGroupPorts $ROOT_TARGET

    handleGroupProcessors $ROOT_TARGET
}

export AMBARI_HOST=$(hostname -f)
echo "*********************************AMABRI HOST IS: $AMBARI_HOST"

export ROOT_PATH=~
echo "*********************************ROOT PATH IS: $ROOT_PATH"

echo "****************Installing Utilities"
installUtils
echo "****************Installing Nifi"
installNifi
echo "****************Installing Solr"
installSolr
echo "****************Initializing Solr"
initializeSolr
echo "****************Starting Solr"
startSolr
echo "****************Creative Hive Tables"
createHiveTables
echo "********************************* Deploying Nifi Template"
deployTemplateToNifi $ROOT_PATH/SE-demo/Twitter/Twitter_Dashboard.xml TWITTER-Demo
echo "********************************* Configuring Nifi Template"
configureNifiTempate
